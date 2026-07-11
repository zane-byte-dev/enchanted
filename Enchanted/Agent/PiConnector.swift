//
//  PiConnector.swift
//  Enchanted
//
//  Drives a `pi --mode rpc` subprocess over JSONL stdio and adapts it to
//  `AgentBackend`. This is the reference connector for the "one native GUI,
//  many agent CLIs" architecture (aligned with pi RPC / Zed's ACP).
//
//  NOTE: pi's RPC session is *stateful* — one process owns the whole
//  conversation and its own transcript. PiConnector therefore forwards only
//  the latest user turn on each `chat()`
//  call and lets pi keep history. (For a first spike that's fine; syncing the
//  two transcripts is a later step.)
//

import Foundation
import Combine

/// Token / cost / context usage for a pi session (from `get_session_stats`).
struct PiSessionStats: Equatable {
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double
    var contextTokens: Int?
    var contextWindow: Int?
    var contextPercent: Double?

    init?(_ data: [String: Any]) {
        let tokens = data["tokens"] as? [String: Any] ?? [:]
        totalTokens = (tokens["total"] as? NSNumber)?.intValue ?? 0
        inputTokens = (tokens["input"] as? NSNumber)?.intValue ?? 0
        outputTokens = (tokens["output"] as? NSNumber)?.intValue ?? 0
        cost = (data["cost"] as? NSNumber)?.doubleValue ?? 0
        if let ctx = data["contextUsage"] as? [String: Any] {
            contextTokens = (ctx["tokens"] as? NSNumber)?.intValue
            contextWindow = (ctx["contextWindow"] as? NSNumber)?.intValue
            contextPercent = (ctx["percent"] as? NSNumber)?.doubleValue
        }
    }
}

struct PiCompactionResult: Equatable {
    let summary: String
    let tokensBefore: Int
    let estimatedTokensAfter: Int

    init(_ data: [String: Any]) {
        summary = data["summary"] as? String ?? ""
        tokensBefore = (data["tokensBefore"] as? NSNumber)?.intValue ?? 0
        estimatedTokensAfter = (data["estimatedTokensAfter"] as? NSNumber)?.intValue ?? 0
    }
}

/// The last user turn reconstructed from pi's persisted transcript. Used when
/// Enchanted restarts after creating a local assistant placeholder but before
/// receiving the run's terminal event.
struct PiRecoveredTurn {
    let blocks: [MessageBlock]
    let stopReason: String?
    let errorMessage: String?

    var completedSuccessfully: Bool {
        stopReason == "stop" || stopReason == "length"
    }
}

/// Full provider/model metadata returned by pi's `get_available_models` RPC.
/// Settings uses this directly so custom provider ids and endpoints are not
/// flattened into the app's small built-in provider enum.
struct PiModelDescriptor: Identifiable, Equatable, Sendable {
    var id: String { "\(provider)/\(modelID)" }
    let modelID: String
    let name: String
    let provider: String
    let api: String
    let baseURL: String
    let reasoning: Bool
    let input: [String]
    let contextWindow: Int?

    init(
        modelID: String,
        name: String,
        provider: String,
        api: String = "",
        baseURL: String = "",
        reasoning: Bool = false,
        input: [String] = ["text"],
        contextWindow: Int? = nil
    ) {
        self.modelID = modelID
        self.name = name
        self.provider = provider
        self.api = api
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.contextWindow = contextWindow
    }

    init?(record: [String: Any]) {
        guard let modelID = record["id"] as? String,
              let provider = record["provider"] as? String else { return nil }
        self.modelID = modelID
        self.name = record["name"] as? String ?? modelID
        self.provider = provider
        self.api = record["api"] as? String ?? ""
        self.baseURL = record["baseUrl"] as? String ?? ""
        self.reasoning = record["reasoning"] as? Bool ?? false
        self.input = record["input"] as? [String] ?? ["text"]
        self.contextWindow = (record["contextWindow"] as? NSNumber)?.intValue
    }
}

final class PiConnector: AgentBackend, @unchecked Sendable {
    /// Foundation JSON containers are immutable after parsing in this connector,
    /// but `[String: Any]` cannot express that to Swift's Sendable checker.
    private struct RPCResponse: @unchecked Sendable {
        let object: [String: Any]?
    }

    /// Thread-safe one-shot continuation shared by the reply and timeout paths.
    private final class ResponseLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RPCResponse, Never>?

        init(_ continuation: CheckedContinuation<RPCResponse, Never>) {
            self.continuation = continuation
        }

        func finish(_ object: [String: Any]?) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: RPCResponse(object: object))
        }
    }

    struct Config {
        /// Absolute path to the `pi` executable (or a launcher that runs it).
        var executable: String
        /// Extra arguments. Must put pi into RPC mode, e.g. ["--mode", "rpc"].
        var arguments: [String]
        /// Project root pi should operate in.
        var workingDirectory: String
        /// Optional environment overrides (inherits process env when nil).
        var environment: [String: String]?
        /// If set, `switch_session` to this pi session file on spawn to restore context.
        var resumeSessionPath: String?

        init(
            executable: String,
            arguments: [String] = ["--mode", "rpc"],
            workingDirectory: String,
            environment: [String: String]? = nil,
            resumeSessionPath: String? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.resumeSessionPath = resumeSessionPath
        }
    }

    private let config: Config
    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var subject: PassthroughSubject<AgentEvent, Error>?
    private var commandCounter = 0
    private(set) var lastForkError: String?
    /// One-shot response continuations keyed by command id (for request/reply
    /// commands like get_available_models).
    private var pending: [String: ([String: Any]) -> Void] = [:]
    /// Set when a fresh process was spawned with a `resumeSessionPath`; cleared
    /// once `switch_session` has completed. Guards the first prompt so it never
    /// races the (async) session restore.
    private var needsResume = false
    /// Maps a pi model id → its provider string (e.g. "qwen3.7-max" →
    /// "opencode-go"). Populated from `get_available_models` so `chat()` can
    /// issue a `set_model` (which requires both provider and modelId).
    private var providersByModelId: [String: [String]] = [:]
    /// The model id currently applied to the live pi session. Tracked so we only
    /// send `set_model` when the user actually switches models, and re-send it
    /// after a respawn (reset to nil in `ensureProcess`).
    private var appliedModelId: String?
    private var queuedInjectedTexts: [String] = []

    init(config: Config) {
        self.config = config
    }

    private func request(
        id: String,
        command: [String: Any],
        timeout: TimeInterval,
        errorCode: Bool = false
    ) async -> [String: Any]? {
        let response = await withCheckedContinuation { continuation in
            let latch = ResponseLatch(continuation)
            lock.withLock { pending[id] = { latch.finish($0) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self, latch] in
                lock.withLock { pending[id] = nil }
                latch.finish(nil)
            }
            do {
                try send(command)
            } catch {
                lock.withLock { pending[id] = nil }
                latch.finish(errorCode ? [
                    "success": false,
                    "error": error.localizedDescription,
                ] : nil)
            }
        }
        return response.object
    }

    // MARK: - AgentBackend

    func chat(model: String, messages: [AgentChatMessage]) -> AnyPublisher<AgentEvent, Error> {
        let subject = PassthroughSubject<AgentEvent, Error>()

        lock.withLock { self.subject = subject }

        // pi keeps history itself → only forward the newest user turn.
        let lastUserMessage = messages.last(where: { $0.role == .user })
        let lastUser = lastUserMessage?.content ?? ""
        let images = (lastUserMessage?.imagesBase64 ?? [])
            .filter { !$0.isEmpty }
            .map { data in
                [
                    "type": "image",
                    "data": data,
                    // ConversationStore normalizes SwiftUI images to JPEG.
                    "mimeType": "image/jpeg",
                ]
            }

        Task { [self] in
            do {
                try ensureProcess()
                // Restore prior context BEFORE prompting. pi handles stdin lines
                // concurrently and `switch_session` rebuilds the session runtime
                // asynchronously, so we must await its response — otherwise the
                // prompt hits a half-torn-down session and is silently lost
                // (the "can't continue after restart" bug).
                await resumeSessionIfNeeded()
                // Apply the user-selected model before prompting. pi's RPC
                // session keeps its own "current model"; switching models in the
                // UI is a no-op unless we tell pi via `set_model`.
                await applyModelIfNeeded(model)
                // Apply the user-selected reasoning level before prompting.
                if let level = UserDefaults.standard.string(forKey: "piThinkingLevel"), !level.isEmpty {
                    try? send(["id": nextId(), "type": "set_thinking_level", "level": level])
                }
                let autoCompact = UserDefaults.standard.object(forKey: "piAutoCompaction") as? Bool ?? true
                try? await setAutoCompaction(autoCompact)
                var promptCommand: [String: Any] = [
                    "id": nextId(),
                    "type": "prompt",
                    "message": lastUser,
                ]
                if !images.isEmpty {
                    promptCommand["images"] = images
                }
                try send(promptCommand)
            } catch {
                lock.withLock { self.subject }?.send(completion: .failure(error))
            }
        }

        return subject.eraseToAnyPublisher()
    }

    /// If the process was just spawned for a resumed conversation, send
    /// `switch_session` and wait for its response before continuing.
    private func resumeSessionIfNeeded() async {
        let (shouldResume, resume) = lock.withLock {
            let value = (needsResume, config.resumeSessionPath)
            if needsResume { needsResume = false }
            return value
        }

        guard shouldResume, let resume, !resume.isEmpty else { return }

        let id = nextId()
        _ = await request(
            id: id,
            command: ["id": id, "type": "switch_session", "sessionPath": resume],
            timeout: 12
        )
        AgentBackendConfig.debugLog("PiConnector: switch_session -> \(resume)")
    }

    /// Ensure pi's live session is using `modelId`. No-op if already applied.
    /// Sends `set_model` (which needs the provider too) and awaits its response
    /// so the following prompt runs on the intended model.
    private func applyModelIfNeeded(_ modelId: String) async {
        guard !modelId.isEmpty else { return }

        let initial = lock.withLock { (appliedModelId == modelId, providersByModelId[modelId] ?? []) }
        let already = initial.0
        var providers = initial.1

        let preferredProvider = UserDefaults.standard.string(
            forKey: AgentBackendConfig.piDefaultProviderDefaultsKey
        )
        var provider = preferredProvider.flatMap { providers.contains($0) ? $0 : nil }
            ?? providers.first

        if already { return }

        // Cache miss (e.g. models() not called yet): refresh the model list so
        // we can resolve the provider required by set_model.
        if provider == nil {
            _ = try? await models()
            providers = lock.withLock { providersByModelId[modelId] ?? [] }
            provider = preferredProvider.flatMap { providers.contains($0) ? $0 : nil }
                ?? providers.first
        }

        guard let provider else {
            AgentBackendConfig.debugLog("PiConnector: set_model skipped, unknown provider for \(modelId)")
            return
        }

        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "set_model", "provider": provider, "modelId": modelId],
            timeout: 8
        )
        AgentBackendConfig.debugLog("PiConnector: set_model -> \(provider)/\(modelId)")

        if let success = response?["success"] as? Bool, success {
            lock.withLock { appliedModelId = modelId }
        } else {
            let err = (response?["error"] as? String) ?? "no response"
            AgentBackendConfig.debugLog("PiConnector: set_model failed for \(provider)/\(modelId): \(err)")
        }
    }

    func models() async throws -> [LanguageModel] {
        try ensureProcess()
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_available_models"],
            timeout: 12
        )

        guard
            let data = response?["data"] as? [String: Any],
            let models = data["models"] as? [[String: Any]],
            !models.isEmpty
        else {
            return [LanguageModel(name: "pi", provider: .unknown, imageSupport: false)]
        }
        return models.compactMap { record in
            guard let descriptor = PiModelDescriptor(record: record) else { return nil }
            lock.withLock {
                var providers = providersByModelId[descriptor.modelID] ?? []
                if !providers.contains(descriptor.provider) { providers.append(descriptor.provider) }
                providersByModelId[descriptor.modelID] = providers
            }
            let provider = ModelProvider(rawValue: descriptor.provider.lowercased()) ?? .unknown
            return LanguageModel(
                name: descriptor.modelID,
                provider: provider,
                providerID: descriptor.provider,
                imageSupport: descriptor.input.contains("image")
            )
        }
    }

    /// Strict RPC health probe used by Settings. Unlike `models()`, this does
    /// not return the compatibility fallback when pi starts but never answers.
    /// A non-nil count proves that JSONL RPC is alive and understood.
    func diagnosticModels() async -> [PiModelDescriptor]? {
        guard (try? ensureProcess()) != nil else { return nil }
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_available_models"],
            timeout: 8
        )
        guard
            let data = response?["data"] as? [String: Any],
            let models = data["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap(PiModelDescriptor.init(record:))
    }

    /// Ask pi to abort the in-flight turn (real stop, not just local unsubscribe).
    func abort() {
        try? send(["id": nextId(), "type": "abort"])
    }

    /// Send a steering message into an in-flight turn (adjust course mid-run).
    func steer(_ message: String) {
        lock.withLock { queuedInjectedTexts.append(message) }
        do {
            try send(["id": nextId(), "type": "steer", "message": message])
        } catch {
            lock.withLock {
                if let index = queuedInjectedTexts.lastIndex(of: message) {
                    queuedInjectedTexts.remove(at: index)
                }
            }
        }
    }

    /// Fetch token/cost/context stats for the current session.
    func sessionStats() async -> PiSessionStats? {
        guard process?.isRunning == true else { return nil }
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_session_stats"],
            timeout: 8
        )
        guard let data = response?["data"] as? [String: Any] else { return nil }
        return PiSessionStats(data)
    }

    /// Manually compact the active pi context. The RPC response arrives only
    /// after summary generation has completed; compaction lifecycle events are
    /// intentionally left out of AgentEvent because this is a control action,
    /// not an assistant turn rendered into the local transcript.
    func compact(customInstructions: String? = nil) async throws -> PiCompactionResult {
        try ensureProcess()
        await resumeSessionIfNeeded()

        let id = nextId()
        var command: [String: Any] = ["id": id, "type": "compact"]
        if let customInstructions, !customInstructions.isEmpty {
            command["customInstructions"] = customInstructions
        }
        let response = await request(
            id: id,
            command: command,
            timeout: 120,
            errorCode: true
        )

        guard let response else {
            throw NSError(
                domain: "PiConnector",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Compaction timed out"]
            )
        }
        guard response["success"] as? Bool == true,
              let data = response["data"] as? [String: Any] else {
            let message = response["error"] as? String ?? "pi could not compact this session"
            throw NSError(
                domain: "PiConnector",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return PiCompactionResult(data)
    }

    func setAutoCompaction(_ enabled: Bool) async throws {
        try ensureProcess()
        await resumeSessionIfNeeded()
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "set_auto_compaction", "enabled": enabled],
            timeout: 8,
            errorCode: true
        )
        guard let response else {
            throw NSError(domain: "PiConnector", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Updating auto compaction timed out"])
        }
        guard response["success"] as? Bool == true else {
            throw NSError(domain: "PiConnector", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? "Could not update auto compaction"])
        }
    }

    func respondToUIRequest(id: String, confirmed: Bool? = nil, value: String? = nil) {
        var response: [String: Any] = ["type": "extension_ui_response", "id": id]
        if let confirmed { response["confirmed"] = confirmed }
        else if let value { response["value"] = value }
        else { response["cancelled"] = true }
        try? send(response)
    }

    func forkableUserMessageTexts() async -> [String]? {
        guard (try? ensureProcess()) != nil else { return nil }
        await resumeSessionIfNeeded()
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_fork_messages"],
            timeout: 8
        )
        guard let data = response?["data"] as? [String: Any],
              let messages = data["messages"] as? [[String: Any]] else { return nil }
        return messages.compactMap { $0["text"] as? String }
    }

    /// Fetch skills available to the current session (pi `get_commands`,
    /// filtered to `source == "skill"`).
    func skills() async -> [PiSkill] {
        guard (try? ensureProcess()) != nil else { return [] }
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_commands"],
            timeout: 8
        )
        guard
            let data = response?["data"] as? [String: Any],
            let commands = data["commands"] as? [[String: Any]]
        else { return [] }
        return commands.compactMap(PiSkill.init(command:))
    }

    func reachable() async -> Bool {
        (try? ensureProcess()) != nil
    }

    // MARK: - Process lifecycle

    private func ensureProcess() throws {
        try lock.withLock {

            if let existing = process, existing.isRunning { return }

        AgentBackendConfig.debugLog("PiConnector.ensureProcess: spawning \(config.executable) \(config.arguments) cwd=\(config.workingDirectory)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.executable)
        proc.arguments = config.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        if let env = config.environment { proc.environment = env }

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe

        // Log pi's stderr to a file for debugging (GUI apps have no console).
        let logPath = NSTemporaryDirectory() + "pi-connector.err.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let errHandle = FileHandle(forWritingAtPath: logPath) {
            proc.standardError = errHandle
        } else {
            proc.standardError = Pipe()
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        proc.terminationHandler = { p in
            AgentBackendConfig.debugLog("pi process terminated: status=\(p.terminationStatus) reason=\(p.terminationReason.rawValue)")
        }
        try proc.run()
        AgentBackendConfig.debugLog("PiConnector.ensureProcess: pi started pid=\(proc.processIdentifier)")

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutBuffer.removeAll()

        // Mark that context must be restored before the first prompt. The actual
        // (awaited) `switch_session` happens in `resumeSessionIfNeeded()` so it
        // never races the prompt — see `chat(...)`.
        if let resume = config.resumeSessionPath, !resume.isEmpty {
            needsResume = true
        }
        // Fresh process → pi is back on its default model, so force the next
        // chat() to re-apply the user's selection.
            appliedModelId = nil
        }
    }

    /// Restore this connector's context (if resuming) and duplicate the active
    /// branch into a brand-new pi session file, returning its path. Used to
    /// "fork" a conversation: the returned session is independent, so the
    /// original conversation is untouched. Returns nil if the clone was
    /// cancelled or no new session file could be resolved.
    func cloneSession() async -> String? {
        guard (try? ensureProcess()) != nil else { return nil }
        await resumeSessionIfNeeded()
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "clone"],
            timeout: 12
        )
        AgentBackendConfig.debugLog("PiConnector: clone")
        if let data = response?["data"] as? [String: Any], (data["cancelled"] as? Bool) == true {
            return nil
        }
        // After a successful clone the process is switched onto the new session.
        return await currentSessionPath()
    }

    /// Fork the resumed session immediately before the user message at
    /// `userMessageIndex`. pi owns the durable entry ids, so callers address a
    /// turn by its stable ordinal in the visible transcript and this connector
    /// resolves the corresponding RPC entry before issuing `fork`.
    func forkSession(beforeUserMessageAt userMessageIndex: Int, expectedText: String) async -> String? {
        lastForkError = nil
        guard userMessageIndex >= 0 else {
            lastForkError = "The selected turn is not forkable"
            return nil
        }
        guard (try? ensureProcess()) != nil else {
            lastForkError = "Could not start pi to create the branch"
            return nil
        }
        await resumeSessionIfNeeded()

        let messagesID = nextId()
        let messagesResponse = await request(
            id: messagesID,
            command: ["id": messagesID, "type": "get_fork_messages"],
            timeout: 8
        )

        guard
            let data = messagesResponse?["data"] as? [String: Any],
            let messages = data["messages"] as? [[String: Any]]
        else {
            lastForkError = "Could not read forkable turns from pi"
            return nil
        }
        guard messages.indices.contains(userMessageIndex) else {
            lastForkError = "Local history has more turns than the pi session"
            return nil
        }
        guard messages[userMessageIndex]["text"] as? String == expectedText else {
            lastForkError = "Local history no longer matches the pi session at this turn"
            return nil
        }
        guard let entryID = messages[userMessageIndex]["entryId"] as? String else {
            lastForkError = "pi did not return an entry id for this turn"
            return nil
        }

        let forkID = nextId()
        let forkResponse = await request(
            id: forkID,
            command: ["id": forkID, "type": "fork", "entryId": entryID],
            timeout: 12
        )
        AgentBackendConfig.debugLog("PiConnector: fork before user message \(userMessageIndex)")

        guard
            forkResponse?["success"] as? Bool == true,
            let forkData = forkResponse?["data"] as? [String: Any],
            (forkData["cancelled"] as? Bool) != true
        else {
            lastForkError = "pi rejected or cancelled the branch operation"
            return nil
        }
        guard let path = await currentSessionPath() else {
            lastForkError = "pi created the branch but did not return its session path"
            return nil
        }
        return path
    }

    /// Query pi for the current session file path (for persistence).
    func currentSessionPath() async -> String? {
        try? ensureProcess()
        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_state"],
            timeout: 8
        )
        let data = response?["data"] as? [String: Any]
        return data?["sessionFile"] as? String
    }

    /// Restore the configured session and reconstruct the most recent user
    /// turn from pi's durable transcript. This deliberately does not submit a
    /// new prompt: replaying an interrupted run could execute mutating tools a
    /// second time.
    func recoverLatestTurn() async -> PiRecoveredTurn? {
        guard (try? ensureProcess()) != nil else { return nil }
        await resumeSessionIfNeeded()

        let id = nextId()
        let response = await request(
            id: id,
            command: ["id": id, "type": "get_messages"],
            timeout: 12
        )

        guard
            let data = response?["data"] as? [String: Any],
            let messages = data["messages"] as? [[String: Any]]
        else { return nil }
        return Self.recoveredTurn(from: messages)
    }

    private static func recoveredTurn(from messages: [[String: Any]]) -> PiRecoveredTurn? {
        guard let lastUserIndex = messages.lastIndex(where: { $0["role"] as? String == "user" }) else {
            return nil
        }

        var blocks: [MessageBlock] = []
        var toolIndices: [String: Int] = [:]
        var stopReason: String?
        var errorMessage: String?

        func appendText(_ text: String, thinking: Bool = false) {
            guard !text.isEmpty else { return }
            if thinking, case .thinking(let existing) = blocks.last {
                blocks[blocks.count - 1] = .thinking(existing + text)
            } else if !thinking, case .text(let existing) = blocks.last {
                blocks[blocks.count - 1] = .text(existing + text)
            } else {
                blocks.append(thinking ? .thinking(text) : .text(text))
            }
        }

        for message in messages.suffix(from: messages.index(after: lastUserIndex)) {
            switch message["role"] as? String {
            case "assistant":
                stopReason = message["stopReason"] as? String ?? stopReason
                errorMessage = message["errorMessage"] as? String ?? errorMessage
                if let text = message["content"] as? String {
                    appendText(text)
                    continue
                }
                for item in message["content"] as? [[String: Any]] ?? [] {
                    switch item["type"] as? String {
                    case "text":
                        appendText(item["text"] as? String ?? "")
                    case "thinking":
                        appendText(item["thinking"] as? String ?? "", thinking: true)
                    case "toolCall":
                        let callID = item["id"] as? String ?? UUID().uuidString
                        let name = item["name"] as? String ?? "tool"
                        let arguments = jsonStringForRecovery(item["arguments"])
                        toolIndices[callID] = blocks.count
                        blocks.append(.tool(ToolCall(
                            callId: callID,
                            name: name,
                            argsJSON: arguments
                        )))
                    default:
                        continue
                    }
                }

            case "toolResult":
                guard let callID = message["toolCallId"] as? String,
                      let index = toolIndices[callID],
                      case .tool(var tool) = blocks[index] else { continue }
                tool.isError = message["isError"] as? Bool ?? false
                tool.running = false
                if !tool.isReadOnly {
                    let text = (message["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                    tool.resultText = text.isEmpty ? nil : text
                }
                blocks[index] = .tool(tool)

            default:
                continue
            }
        }

        guard !blocks.isEmpty else { return nil }
        // A recovered process cannot still own these tool executions. Never
        // leave a permanent spinner in history when a result was not flushed.
        for index in blocks.indices {
            if case .tool(var tool) = blocks[index], tool.running {
                tool.running = false
                blocks[index] = .tool(tool)
            }
        }
        return PiRecoveredTurn(
            blocks: blocks,
            stopReason: stopReason,
            errorMessage: errorMessage
        )
    }

    private static func jsonStringForRecovery(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    private func nextId() -> String {
        lock.withLock {
            commandCounter += 1
            return "c\(commandCounter)"
        }
    }

    private func send(_ command: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A) // newline-delimited JSON

        let pipe = lock.withLock { stdinPipe }

        pipe?.fileHandleForWriting.write(line)
    }

    // MARK: - stdout parsing (JSONL)

    private func ingest(_ data: Data) {
        let (lines, subj): ([Data], PassthroughSubject<AgentEvent, Error>?) = lock.withLock {
            stdoutBuffer.append(data)
            var lines: [Data] = []
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
                lines.append(line)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            }
            return (lines, self.subject)
        }

        for line in lines where !line.isEmpty {
            handleLine(line, subject: subj)
        }
    }

    private func handleLine(_ line: Data, subject: PassthroughSubject<AgentEvent, Error>?) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        switch type {
        case "message_update":
            guard
                let event = obj["assistantMessageEvent"] as? [String: Any],
                let eventType = event["type"] as? String
            else { return }

            if eventType == "text_delta", let delta = event["delta"] as? String {
                subject?.send(.messageDelta(delta))
            } else if eventType == "thinking_delta", let delta = event["delta"] as? String {
                subject?.send(.thinkingDelta(delta))
            } else if eventType == "error", event["reason"] as? String != "aborted" {
                let message = Self.assistantErrorMessage(in: obj) ?? "Agent request failed"
                subject?.send(completion: .failure(
                    NSError(
                        domain: "PiConnector",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                ))
            }

        case "message_end":
            guard let message = Self.assistantErrorMessage(in: obj) else { break }
            subject?.send(completion: .failure(
                NSError(
                    domain: "PiConnector",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            ))

        case "tool_execution_start":
            let callId = obj["toolCallId"] as? String ?? UUID().uuidString
            let name = obj["toolName"] as? String ?? "tool"
            if name == "update_plan", let args = obj["args"] as? [String: Any] {
                let items = (args["plan"] as? [[String: Any]] ?? []).compactMap { item -> AgentPlanItem? in
                    guard let step = item["step"] as? String,
                          let status = item["status"] as? String else { return nil }
                    return AgentPlanItem(step: step, status: status)
                }
                subject?.send(.planUpdate(explanation: args["explanation"] as? String, items: items))
                break
            }
            let args = jsonString(obj["args"])
            subject?.send(.toolStart(callId: callId, name: name, args: args))

        case "tool_execution_end":
            let callId = obj["toolCallId"] as? String ?? ""
            let name = obj["toolName"] as? String ?? "tool"
            if name == "update_plan" { break }
            let isError = obj["isError"] as? Bool ?? false
            subject?.send(.toolEnd(callId: callId, name: name, result: toolResultText(obj["result"]), isError: isError))

        case "queue_update":
            let steering = obj["steering"] as? [String] ?? []
            let followUps = obj["followUp"] as? [String] ?? []
            subject?.send(.queueUpdate(steering: steering, followUps: followUps))

        case "compaction_start":
            subject?.send(.compactionStarted(reason: obj["reason"] as? String ?? "manual"))

        case "compaction_end":
            let result = obj["result"] as? [String: Any]
            subject?.send(.compactionFinished(
                reason: obj["reason"] as? String ?? "manual",
                tokensBefore: result?["tokensBefore"] as? Int,
                estimatedTokensAfter: result?["estimatedTokensAfter"] as? Int,
                error: obj["errorMessage"] as? String
            ))

        case "extension_ui_request":
            let method = obj["method"] as? String ?? "notify"
            if method == "confirm" || method == "select" {
                subject?.send(.uiRequest(AgentUIRequest(
                    id: obj["id"] as? String ?? UUID().uuidString,
                    method: method,
                    title: obj["title"] as? String ?? "Agent request",
                    message: obj["message"] as? String,
                    options: obj["options"] as? [String] ?? []
                )))
            } else if method == "notify" {
                let message = obj["message"] as? String ?? "Agent notification"
                subject?.send(.uiRequest(AgentUIRequest(
                    id: obj["id"] as? String ?? UUID().uuidString,
                    method: method,
                    title: message,
                    message: nil,
                    options: []
                )))
            }

        case "message_start":
            guard let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "user" else { break }
            let text = messageText(message)
            let queuedIndex = lock.withLock {
                let index = queuedInjectedTexts.firstIndex(of: text)
                if let index { queuedInjectedTexts.remove(at: index) }
                return index
            }
            if queuedIndex != nil { subject?.send(.queuedTurnStarted(text)) }

        case "agent_end":
            break

        case "agent_settled":
            subject?.send(.done)
            subject?.send(completion: .finished)

        case "response":
            // Fulfil any awaiting request/reply continuation first.
            if let id = obj["id"] as? String {
                let cont = lock.withLock { pending.removeValue(forKey: id) }
                cont?(obj)
            }
            if let success = obj["success"] as? Bool, success == false {
                let message = obj["error"] as? String ?? "pi rpc error"
                subject?.send(completion: .failure(
                    NSError(domain: "PiConnector", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
                ))
            }

        default:
            break
        }
    }

    /// Extract the final provider error carried by pi's assistant lifecycle
    /// events. pi still emits `agent_settled` after a failed model request, so
    /// callers must recognize this payload before treating settlement as a
    /// successful completion.
    static func assistantErrorMessage(in object: [String: Any]) -> String? {
        let event = object["assistantMessageEvent"] as? [String: Any]
        let eventType = event?["type"] as? String
        let eventReason = event?["reason"] as? String

        let eventError = event?["error"]
        let message = (eventError as? [String: Any])
            ?? (object["message"] as? [String: Any])

        let stopReason = message?["stopReason"] as? String
        guard (eventType == "error" && eventReason != "aborted") || stopReason == "error" else {
            return nil
        }

        if let errorMessage = message?["errorMessage"] as? String, !errorMessage.isEmpty {
            return errorMessage
        }
        if let errorMessage = eventError as? String, !errorMessage.isEmpty {
            return errorMessage
        }
        return nil
    }

    /// Extract human-readable text from a pi tool result.
    /// Results follow the MCP shape `{ content: [{ type, text }], details, isError }`.
    /// We join the text blocks; fall back to common keys, then pretty JSON.
    private func toolResultText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let dict = value as? [String: Any] {
            if let content = dict["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                if !text.isEmpty { return text }
            }
            if let output = dict["output"] as? String { return output }
            if let text = dict["text"] as? String { return text }
        }
        return jsonString(value)
    }

    private func messageText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        if let content = message["content"] as? [[String: Any]] {
            return content.compactMap { part in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined()
        }
        return ""
    }

    private func jsonString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard
            let data = try? JSONSerialization.data(withJSONObject: value),
            let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    // MARK: - Shutdown

    func terminate() {
        let proc = lock.withLock {
            let current = process
            process = nil
            stdinPipe = nil
            return current
        }
        proc?.terminate()
    }
}
