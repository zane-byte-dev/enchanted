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

        init(
            executable: String,
            arguments: [String] = ["--mode", "rpc"],
            workingDirectory: String,
            environment: [String: String]? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    private let config: Config
    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var subject: PassthroughSubject<AgentEvent, Error>?
    private var commandCounter = 0

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
        // The spike surfaces a single logical "pi" model. Real model discovery
        // would issue a `get_available_models` RPC and await the response.
        [LanguageModel(name: "pi", provider: .ollama, imageSupport: false)]
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
