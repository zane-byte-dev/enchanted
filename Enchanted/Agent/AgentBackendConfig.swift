//
//  AgentBackendConfig.swift
//  Enchanted
//
//  One place to choose which agent backend the app talks to.
//  Flip `Kind` (or set the `AGENT_BACKEND` env var) to switch between
//  Ollama and the pi RPC connector.
//

import Foundation

enum AgentBackendConfig {
    enum Kind: String {
        case ollama
        case pi
    }

    /// Default backend for this spike. Override with env `AGENT_BACKEND=ollama|pi`.
    static let defaultKind: Kind = .pi

    /// pi launch settings (this machine). Override via env if needed.
    static let piExecutable = ProcessInfo.processInfo.environment["PI_EXECUTABLE"]
        ?? "/Users/mj/.local/bin/pi"
    /// Fallback scratch root when the user hasn't picked a project dir yet.
    static var defaultWorkingDirectory: String {
        if let override = ProcessInfo.processInfo.environment["PI_CWD"] { return override }
        let dir = NSHomeDirectory() + "/.enchanted-pi"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Project root pi operates in. Sourced from the user-picked working dir
    /// (persisted in UserDefaults) so it can change at runtime.
    static var piWorkingDirectory: String {
        UserDefaults.standard.string(forKey: "piWorkingDirectory") ?? defaultWorkingDirectory
    }

    static var currentKind: Kind {
        ProcessInfo.processInfo.environment["AGENT_BACKEND"]
            .flatMap(Kind.init(rawValue:)) ?? defaultKind
    }

    static func makeBackend() -> AgentBackend {
        makeChatBackend(workingDirectory: piWorkingDirectory)
    }

    /// Build a backend bound to a specific working directory (one per conversation).
    /// `resumeSessionPath` restores an existing pi session's context on spawn.
    static func makeChatBackend(workingDirectory: String, resumeSessionPath: String? = nil) -> AgentBackend {
        switch currentKind {
        case .ollama:
            return OllamaBackend()
        case .pi:
            // Launch through a login shell so pi inherits the user's PATH (node)
            // and API keys (e.g. IDEALAB_API_KEY) from ~/.zshrc. GUI apps started
            // via `open` otherwise get a bare environment.
            return PiConnector(config: .init(
                executable: "/bin/zsh",
                arguments: ["-l", "-c", "exec '\(piExecutable)' --mode rpc"],
                workingDirectory: workingDirectory,
                resumeSessionPath: resumeSessionPath
            ))
        }
    }

    /// Call once at app startup.
    static func configure() {
        let backend = makeBackend()
        ConversationStore.shared.backend = backend
        debugLog("configure() -> backend=\(type(of: backend)), exec=\(piExecutable), cwd=\(piWorkingDirectory)")
    }

    /// Rebuild the backend after the working directory changes: kill the old pi
    /// process (if any) so the next turn respawns in the new cwd.
    static func reconfigure() {
        (ConversationStore.shared.backend as? PiConnector)?.terminate()
        configure()
    }

    static func debugLog(_ message: String) {
        let path = NSHomeDirectory() + "/.enchanted-pi/debug.log"
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.enchanted-pi", withIntermediateDirectories: true)
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
