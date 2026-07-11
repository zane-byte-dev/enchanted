//
//  AgentBackendConfig.swift
//  Enchanted
//
//  One place to configure the pi RPC backend.
//

import Foundation

enum AgentBackendConfig {
    static let piExecutableDefaultsKey = "piExecutable"
    static let piDefaultProviderDefaultsKey = "piDefaultProvider"

    static var piAgentDirectory: String {
        ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
            ?? NSHomeDirectory() + "/.pi/agent"
    }

    static var piModelsConfigURL: URL {
        URL(fileURLWithPath: piAgentDirectory).appendingPathComponent("models.json")
    }

    /// pi launch settings. Environment overrides win so command-line launches
    /// remain reproducible; the Settings value is used for normal GUI launches.
    static var piExecutable: String {
        if let override = ProcessInfo.processInfo.environment["PI_EXECUTABLE"], !override.isEmpty {
            return override
        }
        if let stored = UserDefaults.standard.string(forKey: piExecutableDefaultsKey), !stored.isEmpty {
            return stored
        }
        return detectedPiExecutable() ?? NSHomeDirectory() + "/.local/bin/pi"
    }

    static var piExecutableIsEnvironmentOverridden: Bool {
        !(ProcessInfo.processInfo.environment["PI_EXECUTABLE"] ?? "").isEmpty
    }

    static var piWorkingDirectoryIsEnvironmentOverridden: Bool {
        !(ProcessInfo.processInfo.environment["PI_CWD"] ?? "").isEmpty
    }

    /// Find pi in the common locations available to a macOS GUI app, whose
    /// process PATH is usually much smaller than an interactive shell's PATH.
    static func detectedPiExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
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
        if let override = ProcessInfo.processInfo.environment["PI_CWD"], !override.isEmpty {
            return override
        }
        return UserDefaults.standard.string(forKey: "piWorkingDirectory") ?? defaultWorkingDirectory
    }

    static func makeBackend() -> AgentBackend {
        makeChatBackend(workingDirectory: piWorkingDirectory)
    }

    /// Build a backend bound to a specific working directory (one per conversation).
    /// `resumeSessionPath` restores an existing pi session's context on spawn.
    static func makeChatBackend(workingDirectory: String, resumeSessionPath: String? = nil) -> AgentBackend {
        // Launch through a login shell so pi inherits the user's PATH (node)
        // and API keys (e.g. IDEALAB_API_KEY) from ~/.zshrc. GUI apps started
        // via `open` otherwise get a bare environment.
        return makePiConnector(
            executable: piExecutable,
            workingDirectory: workingDirectory,
            resumeSessionPath: resumeSessionPath
        )
    }

    /// Build a temporary or conversation-scoped connector from explicit
    /// settings. Used by the Settings connection test without persisting drafts.
    static func makePiConnector(
        executable: String,
        workingDirectory: String,
        resumeSessionPath: String? = nil
    ) -> PiConnector {
        PiConnector(config: .init(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", "exec \(shellQuote(executable)) --mode rpc"],
            workingDirectory: workingDirectory,
            resumeSessionPath: resumeSessionPath
        ))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Call once at app startup.
    @MainActor
    static func configure() {
        let backend = makeBackend()
        ConversationStore.shared.backend = backend
        debugLog("configure() -> backend=\(type(of: backend)), exec=\(piExecutable), cwd=\(piWorkingDirectory)")
    }

    /// Rebuild the backend after the working directory changes: kill the old pi
    /// process (if any) so the next turn respawns in the new cwd.
    @MainActor
    static func reconfigure() {
        (ConversationStore.shared.backend as? PiConnector)?.terminate()
        ConversationStore.shared.invalidateAgentBackends()
        configure()
    }

    /// Persist validated Settings drafts and apply them to future agent work.
    /// Active turns are allowed to finish; their connector is replaced before
    /// the next prompt by ConversationStore's configuration generation check.
    @MainActor
    static func applyPiSettings(executable: String, workingDirectory: String) {
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedExecutable, forKey: piExecutableDefaultsKey)
        WorkspaceStore.shared.setDirectory(trimmedDirectory, reconfigureBackend: false)
        reconfigure()
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
