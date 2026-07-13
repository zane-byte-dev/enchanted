//
//  GitRepositoryActions.swift
//  Enchanted
//
//  Non-shell Git publishing actions used by the Changes sidebar.
//

import Foundation

#if os(macOS)
struct GitRepositoryInfo: Equatable, Sendable {
    let root: String
    let branch: String
    let upstream: String?
    let remotes: [String]
    let hasStagedChanges: Bool
    let ahead: Int
    let behind: Int
}

struct GitActionResult: Equatable, Sendable {
    let success: Bool
    let message: String
    let url: URL?

    static func failure(_ message: String) -> GitActionResult {
        .init(success: false, message: message, url: nil)
    }
}

struct GitRepositoryInspectionError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum GitRepositoryActions {
    static func currentBranch(at directory: String) -> String? {
        let result = runGit(["-C", directory, "branch", "--show-current"])
        guard result.status == 0 else { return nil }
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    static func inspect(
        at directory: String
    ) -> Result<GitRepositoryInfo, GitRepositoryInspectionError> {
        let rootResult = runGit(["-C", directory, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else {
            return .failure(.init(message: cleanMessage(
                rootResult.output,
                fallback: "This project is not a Git repository"
            )))
        }
        let root = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchResult = runGit(["-C", root, "branch", "--show-current"])
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchResult.status == 0, !branch.isEmpty else {
            return .failure(.init(message: "The repository is in detached HEAD state."))
        }

        let upstreamResult = runGit([
            "-C", root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
        ])
        let upstream = upstreamResult.status == 0
            ? upstreamResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let remotes = runGit(["-C", root, "remote"]).output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        let stagedResult = runGit(["-C", root, "diff", "--cached", "--quiet"])
        guard stagedResult.status == 0 || stagedResult.status == 1 else {
            return .failure(.init(message: cleanMessage(
                stagedResult.output,
                fallback: "Could not inspect staged changes."
            )))
        }
        let hasStagedChanges = stagedResult.status == 1

        var ahead = 0
        var behind = 0
        if upstream != nil {
            let counts = runGit([
                "-C", root, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"
            ])
            if counts.status == 0 {
                let values = counts.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                if values.count >= 2 {
                    ahead = values[0]
                    behind = values[1]
                }
            }
        }

        return .success(.init(
            root: root,
            branch: branch,
            upstream: upstream,
            remotes: remotes,
            hasStagedChanges: hasStagedChanges,
            ahead: ahead,
            behind: behind
        ))
    }

    static func commit(at root: String, message: String) -> GitActionResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Commit message is required.") }
        let staged = runGit(["-C", root, "diff", "--cached", "--quiet"])
        guard staged.status == 1 else {
            return .failure(staged.status == 0
                ? "Stage changes before committing."
                : cleanMessage(staged.output, fallback: "Could not inspect staged changes."))
        }
        let result = runGit(["-C", root, "commit", "-m", trimmed])
        return .init(
            success: result.status == 0,
            message: cleanMessage(result.output, fallback: result.status == 0 ? "Commit created." : "Commit failed."),
            url: nil
        )
    }

    static func push(at root: String) -> GitActionResult {
        let info: GitRepositoryInfo
        switch inspect(at: root) {
        case .success(let value): info = value
        case .failure(let error): return .failure(error.message)
        }

        let arguments: [String]
        if info.upstream != nil {
            arguments = ["-C", info.root, "push"]
        } else if let remote = info.remotes.first(where: { $0 == "origin" }) ?? info.remotes.first {
            arguments = ["-C", info.root, "push", "--set-upstream", remote, info.branch]
        } else {
            return .failure("Add a Git remote before pushing.")
        }

        let result = runGit(arguments, extraEnvironment: ["GIT_TERMINAL_PROMPT": "0"])
        return .init(
            success: result.status == 0,
            message: cleanMessage(result.output, fallback: result.status == 0 ? "Push completed." : "Push failed."),
            url: nil
        )
    }

    static func createPullRequest(
        at root: String,
        title: String,
        body: String,
        isDraft: Bool
    ) -> GitActionResult {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure("Pull request title is required.") }
        guard let executable = githubCLIPath() else {
            return .failure("GitHub CLI (`gh`) was not found. Install it and authenticate before creating a pull request.")
        }
        let arguments = pullRequestArguments(title: title, body: body, isDraft: isDraft)
        let result = run(
            executable: executable,
            arguments: arguments,
            directory: root,
            extraEnvironment: ["GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0"]
        )
        let message = cleanMessage(result.output, fallback: result.status == 0
            ? "Pull request created."
            : "Could not create a pull request. Install and authenticate GitHub CLI (`gh`).")
        let url = result.output
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first(where: { $0.hasPrefix("https://") || $0.hasPrefix("http://") })
            .flatMap(URL.init(string:))
        return .init(success: result.status == 0, message: message, url: url)
    }

    static func pullRequestArguments(title: String, body: String, isDraft: Bool) -> [String] {
        var arguments = ["pr", "create", "--title", title, "--body", body]
        if isDraft { arguments.append("--draft") }
        return arguments
    }

    static func githubCLIPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/gh" }
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            homeDirectory + "/.local/bin/gh"
        ]
        var seen = Set<String>()
        return candidates.first {
            seen.insert($0).inserted && fileManager.isExecutableFile(atPath: $0)
        }
    }

    private static func runGit(
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> (status: Int32, output: String) {
        run(
            executable: "/usr/bin/git",
            arguments: arguments,
            directory: nil,
            extraEnvironment: extraEnvironment
        )
    }

    private static func run(
        executable: String,
        arguments: [String],
        directory: String?,
        extraEnvironment: [String: String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func cleanMessage(_ output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
#endif
