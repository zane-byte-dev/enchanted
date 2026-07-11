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
    static let piPermissionGateDefaultsKey = "piPermissionGate"
    static let piApprovalModeDefaultsKey = "piApprovalMode"
    static let piNetworkPolicyDefaultsKey = "piNetworkPolicy"

    static var permissionGateEnabled: Bool {
        if UserDefaults.standard.object(forKey: piPermissionGateDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: piPermissionGateDefaultsKey)
    }

    static var approvalMode: String {
        if let value = UserDefaults.standard.string(forKey: piApprovalModeDefaultsKey) {
            return value
        }
        return permissionGateEnabled ? "dangerous" : "off"
    }

    static var networkPolicy: String {
        UserDefaults.standard.string(forKey: piNetworkPolicyDefaultsKey) ?? "allow"
    }

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
        var command = "exec \(shellQuote(executable)) --mode rpc"
        // Always load the app extension because it also supplies update_plan.
        // Approval behavior itself can be disabled inside the extension.
        if let extensionPath = ensurePermissionGateExtension() {
            command += " --extension \(shellQuote(extensionPath))"
        }
        return PiConnector(config: .init(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", command],
            workingDirectory: workingDirectory,
            resumeSessionPath: resumeSessionPath
        ))
    }

    /// A tiny bundled-at-runtime pi extension that asks the RPC client before
    /// destructive shell commands or writes outside the active workspace.
    /// Keeping it generated beside the app's debug log avoids adding a build
    /// resource phase to the legacy Xcode project.
    private static func ensurePermissionGateExtension() -> String? {
        let directory = NSHomeDirectory() + "/.enchanted-pi"
        let path = directory + "/permission-gate.ts"
        let selectedApprovalMode = approvalMode
        let selectedNetworkPolicy = networkPolicy
        let source = #"""
        import { Type } from "@sinclair/typebox";
        import { StringEnum } from "@earendil-works/pi-ai";

        export default function (pi) {
          const approvalMode = "\#(selectedApprovalMode)";
          const networkPolicy = "\#(selectedNetworkPolicy)";
          const readOnlyTools = new Set(["read", "grep", "find", "ls", "search", "glob", "update_plan"]);
          const destructive = [
            /\brm\s+[^\n]*(?:-r|-f|--recursive|--force)/i,
            /\bsudo\b/i,
            /\b(?:chmod|chown)\b/i,
            /\bgit\s+(?:reset\s+--hard|clean\s+-|push\s+[^\n]*--force)/i,
            /\b(?:dd|mkfs|shutdown|reboot)\b/i,
            /(?:curl|wget)[^\n|]*\|\s*(?:sh|bash|zsh)\b/i
          ];
          const networkCommand = /\b(?:curl|wget|ssh|scp|rsync|npm|pnpm|yarn|pip|pip3)\b|\bgit\s+(?:clone|fetch|pull|push)\b/i;
          pi.on("tool_call", async (event, ctx) => {
            let detail = JSON.stringify(event.input || {}, null, 2);
            let title = "Allow operation?";
            if (event.toolName === "bash") {
              const command = String(event.input.command || "");
              detail = command;
              if (networkCommand.test(command)) {
                if (networkPolicy === "block") return { block: true, reason: "Blocked by Enchanted network policy" };
                if (networkPolicy === "ask") title = "Allow network command?";
              }
              if (title === "Allow operation?" && approvalMode === "dangerous" && !destructive.some((pattern) => pattern.test(command))) return;
            } else if (event.toolName === "write" || event.toolName === "edit") {
              const path = String(event.input.path || "");
              detail = path;
              if (approvalMode === "dangerous" && (!path.startsWith("/") || path === ctx.cwd || path.startsWith(ctx.cwd + "/"))) return;
            } else {
              if (approvalMode !== "mutations" || readOnlyTools.has(event.toolName)) return;
            }
            if (approvalMode === "off" && title === "Allow operation?") return;
            const allowed = await ctx.ui.confirm(title, detail);
            if (!allowed) return { block: true, reason: "Blocked by user" };
          });

          const PlanItem = Type.Object({
            step: Type.String({ description: "Concrete task step" }),
            status: StringEnum(["pending", "in_progress", "completed"])
          });
          pi.registerTool({
            name: "update_plan",
            label: "Update plan",
            description: "Publish or update the task plan shown to the user. Keep exactly one item in_progress while work remains.",
            parameters: Type.Object({
              explanation: Type.Optional(Type.String()),
              plan: Type.Array(PlanItem, { minItems: 1 })
            }),
            async execute(_toolCallId, params) {
              return {
                content: [{ type: "text", text: "Plan updated" }],
                details: params
              };
            }
          });
        }
        """#
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try source.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            debugLog("permission gate: \(error.localizedDescription)")
            return nil
        }
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
