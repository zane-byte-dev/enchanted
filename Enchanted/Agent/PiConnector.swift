//
//  PiConnector.swift
//  Enchanted
//
//  Drives a `pi --mode rpc` subprocess over JSONL stdio and adapts it to
//  `AgentBackend`. This is the reference connector for the "one native GUI,
//  many agent CLIs" architecture (aligned with pi RPC / Zed's ACP).
//
//  NOTE: pi's RPC session is *stateful* — one process owns the whole
//  conversation and its own transcript. So, unlike the stateless Ollama
//  backend, PiConnector forwards only the latest user turn on each `chat()`
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

final class PiConnector: AgentBackend, @unchecked Sendable {
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
    /// One-shot response continuations keyed by command id (for request/reply
    /// commands like get_available_models).
    private var pending: [String: ([String: Any]) -> Void] = [:]

    init(config: Config) {
        self.config = config
    }

    // MARK: - AgentBackend

    func chat(model: String, messages: [AgentChatMessage]) -> AnyPublisher<AgentEvent, Error> {
        let subject = PassthroughSubject<AgentEvent, Error>()

        lock.lock()
        self.subject = subject
        lock.unlock()

        do {
            try ensureProcess()
            // Apply the user-selected reasoning level before prompting.
            if let level = UserDefaults.standard.string(forKey: "piThinkingLevel"), !level.isEmpty {
                try? send(["id": nextId(), "type": "set_thinking_level", "level": level])
            }
            // pi keeps history itself → only forward the newest user turn.
            let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
            let command: [String: Any] = [
                "id": nextId(),
                "type": "prompt",
                "message": lastUser,
            ]
            try send(command)
        } catch {
            subject.send(completion: .failure(error))
        }

        return subject.eraseToAnyPublisher()
    }

    func models() async throws -> [LanguageModel] {
        try ensureProcess()
        let id = nextId()
        let response: [String: Any]? = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ([String: Any]?) -> Void = { obj in
                if resumed { return }; resumed = true
                continuation.resume(returning: obj)
            }
            lock.lock()
            pending[id] = { obj in finish(obj) }
            lock.unlock()
            // Timeout guard so startup hiccups don't hang the UI.
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                self.lock.lock(); self.pending[id] = nil; self.lock.unlock()
                finish(nil)
            }
            try? send(["id": id, "type": "get_available_models"])
        }

        guard
            let data = response?["data"] as? [String: Any],
            let models = data["models"] as? [[String: Any]],
            !models.isEmpty
        else {
            return [LanguageModel(name: "pi", provider: .ollama, imageSupport: false)]
        }
        return models.compactMap { m in
            guard let mid = m["id"] as? String else { return nil }
            return LanguageModel(name: mid, provider: .ollama, imageSupport: false)
        }
    }

    /// Ask pi to abort the in-flight turn (real stop, not just local unsubscribe).
    func abort() {
        try? send(["id": nextId(), "type": "abort"])
    }

    /// Send a steering message into an in-flight turn (adjust course mid-run).
    func steer(_ message: String) {
        try? send(["id": nextId(), "type": "steer", "message": message])
    }

    /// Fetch token/cost/context stats for the current session.
    func sessionStats() async -> PiSessionStats? {
        guard process?.isRunning == true else { return nil }
        let id = nextId()
        let response: [String: Any]? = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ([String: Any]?) -> Void = { obj in
                if resumed { return }; resumed = true
                continuation.resume(returning: obj)
            }
            lock.lock()
            pending[id] = { obj in finish(obj) }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                self.lock.lock(); self.pending[id] = nil; self.lock.unlock()
                finish(nil)
            }
            try? send(["id": id, "type": "get_session_stats"])
        }
        guard let data = response?["data"] as? [String: Any] else { return nil }
        return PiSessionStats(data)
    }

    func reachable() async -> Bool {
        (try? ensureProcess()) != nil
    }

    // MARK: - Process lifecycle

    private func ensureProcess() throws {
        lock.lock()
        defer { lock.unlock() }

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

        // Restore prior context if resuming an existing conversation.
        if let resume = config.resumeSessionPath, !resume.isEmpty {
            commandCounter += 1
            let restoreId = "c\(commandCounter)"
            var line = try JSONSerialization.data(withJSONObject: [
                "id": restoreId, "type": "switch_session", "sessionPath": resume,
            ])
            line.append(0x0A)
            inPipe.fileHandleForWriting.write(line)
            AgentBackendConfig.debugLog("PiConnector: switch_session -> \(resume)")
        }
    }

    /// Query pi for the current session file path (for persistence).
    func currentSessionPath() async -> String? {
        try? ensureProcess()
        let id = nextId()
        let response: [String: Any]? = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ([String: Any]?) -> Void = { obj in
                if resumed { return }; resumed = true
                continuation.resume(returning: obj)
            }
            lock.lock()
            pending[id] = { obj in finish(obj) }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                self.lock.lock(); self.pending[id] = nil; self.lock.unlock()
                finish(nil)
            }
            try? send(["id": id, "type": "get_state"])
        }
        let data = response?["data"] as? [String: Any]
        return data?["sessionFile"] as? String
    }

    private func nextId() -> String {
        lock.lock()
        defer { lock.unlock() }
        commandCounter += 1
        return "c\(commandCounter)"
    }

    private func send(_ command: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A) // newline-delimited JSON

        lock.lock()
        let pipe = stdinPipe
        lock.unlock()

        pipe?.fileHandleForWriting.write(line)
    }

    // MARK: - stdout parsing (JSONL)

    private func ingest(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)

        var lines: [Data] = []
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
            lines.append(line)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
        }
        let subj = self.subject
        lock.unlock()

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
            }

        case "tool_execution_start":
            let callId = obj["toolCallId"] as? String ?? UUID().uuidString
            let name = obj["toolName"] as? String ?? "tool"
            let args = jsonString(obj["args"])
            subject?.send(.toolStart(callId: callId, name: name, args: args))

        case "tool_execution_end":
            let callId = obj["toolCallId"] as? String ?? ""
            let name = obj["toolName"] as? String ?? "tool"
            let isError = obj["isError"] as? Bool ?? false
            subject?.send(.toolEnd(callId: callId, name: name, result: jsonString(obj["result"]), isError: isError))

        case "agent_end":
            subject?.send(.done)
            subject?.send(completion: .finished)

        case "response":
            // Fulfil any awaiting request/reply continuation first.
            if let id = obj["id"] as? String {
                lock.lock()
                let cont = pending.removeValue(forKey: id)
                lock.unlock()
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
        lock.lock()
        let proc = process
        process = nil
        stdinPipe = nil
        lock.unlock()
        proc?.terminate()
    }
}
