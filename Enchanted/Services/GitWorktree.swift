//
//  GitWorktree.swift
//  Enchanted
//
//  Creates git worktrees so a conversation can be "forked to a new worktree" —
//  a parallel branch checkout an agent can work in without touching the
//  original tree. macOS only (relies on Process + a git binary on PATH).
//

import Foundation

#if os(macOS)
enum GitWorktree {
    /// Create a new worktree (on a fresh branch) rooted at the repository that
    /// contains `directory`. Returns the absolute worktree path, or nil if
    /// `directory` isn't in a git repo or the worktree couldn't be created.
    static func create(from directory: String, name: String) -> String? {
        guard let repoRoot = run(["-C", directory, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            return nil
        }

        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let parent = URL(fileURLWithPath: repoRoot).deletingLastPathComponent()
        let container = parent.appendingPathComponent("\(repoName).worktrees")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let slug = branchSlug(from: name)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let branch = "enchanted/\(slug)-\(suffix)"
        let worktreePath = container.appendingPathComponent("\(slug)-\(suffix)").path

        let result = run(["-C", repoRoot, "worktree", "add", "-b", branch, worktreePath])
        guard result != nil, FileManager.default.fileExists(atPath: worktreePath) else {
            AgentBackendConfig.debugLog("GitWorktree.create failed for \(repoRoot) branch=\(branch)")
            return nil
        }
        AgentBackendConfig.debugLog("GitWorktree.create -> \(worktreePath) (branch \(branch))")
        return worktreePath
    }

    /// Turn a conversation name into a safe branch segment.
    private static func branchSlug(from name: String) -> String {
        let lowered = name.lowercased()
        let cleaned = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let slug = String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(slug.prefix(40))
        return trimmed.isEmpty ? "fork" : trimmed
    }

    /// Run `git <args>` and return stdout on success (exit 0), nil otherwise.
    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let proc = Process()
        // Route through a login shell so git is found on the user's PATH even
        // when the app was launched from Finder with a bare environment.
        let quoted = args.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "git \(quoted)"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            AgentBackendConfig.debugLog("GitWorktree.run failed to launch: \(error)")
            return nil
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            AgentBackendConfig.debugLog("git \(quoted) exited \(proc.terminationStatus): \(err)")
            return nil
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
#endif
