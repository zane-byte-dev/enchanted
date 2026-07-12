//
//  GitWorktree.swift
//  Enchanted
//
//  Managed detached worktrees plus verified Local ↔ Worktree state transfer.
//

import Foundation

struct GitHandoffResult: Equatable, Sendable {
    let success: Bool
    let message: String
}

#if os(macOS)
enum GitWorktree {
    private struct RunResult {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var output: String {
            let data = stdout + stderr
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private enum FileContent: Equatable {
        case regular(Data, executable: Bool)
    }

    private struct FilePayload: Equatable {
        let path: String
        let content: FileContent
    }

    private struct StateSnapshot: Equatable {
        let sourceHead: String
        let destinationHead: String
        let stagedPatch: Data
        let workingPatch: Data
        let aggregatePatch: Data
        let trackedPaths: [String]
        let untrackedFiles: [FilePayload]
        let includedIgnoredFiles: [FilePayload]
    }

    /// Creates a detached managed worktree and copies the source checkout's
    /// staged, unstaged, untracked, and `.worktreeinclude` state into it.
    static func create(from directory: String, name: String) -> String? {
        guard let created = createDetached(from: directory, name: name) else { return nil }
        let sourceRoot = created.sourceRoot
        let sourceHead = created.sourceHead
        let worktreePath = created.path

        let copied = copyState(
            from: sourceRoot,
            to: worktreePath,
            moveSource: false,
            includeIgnoredSetup: true
        )
        guard copied.success else {
            removeManaged(worktreePath, from: sourceRoot)
            AgentBackendConfig.debugLog("GitWorktree.create state copy failed: \(copied.message)")
            return nil
        }
        AgentBackendConfig.debugLog("GitWorktree.create -> \(worktreePath) (detached \(sourceHead))")
        return worktreePath
    }

    /// Creates an empty detached destination for a move operation. Unlike a
    /// new independent Worktree task, handoff applies state exactly once.
    static func createForHandoff(from directory: String, name: String) -> String? {
        createDetached(from: directory, name: name)?.path
    }

    static func removeManaged(_ worktreePath: String, from directory: String) {
        guard let root = repositoryRoot(for: directory) else { return }
        _ = run(["-C", root, "worktree", "remove", "--force", worktreePath])
    }

    private static func createDetached(
        from directory: String,
        name: String
    ) -> (path: String, sourceRoot: String, sourceHead: String)? {
        guard let sourceRoot = repositoryRoot(for: directory),
              let mainRoot = mainWorktree(from: sourceRoot),
              let sourceHead = value(["-C", sourceRoot, "rev-parse", "HEAD"]) else {
            return nil
        }

        let repoName = URL(fileURLWithPath: mainRoot).lastPathComponent
        let parent = URL(fileURLWithPath: mainRoot).deletingLastPathComponent()
        let container = parent.appendingPathComponent("\(repoName).worktrees", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            AgentBackendConfig.debugLog("GitWorktree.create container failed: \(error)")
            return nil
        }

        let slug = branchSlug(from: name)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let worktreePath = container.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true).path
        let add = run(["-C", sourceRoot, "worktree", "add", "--detach", worktreePath, sourceHead])
        guard add.status == 0 else {
            AgentBackendConfig.debugLog("GitWorktree.create add failed: \(add.output)")
            return nil
        }
        return (worktreePath, sourceRoot, sourceHead)
    }

    /// Moves task code state only after the destination has been proven clean,
    /// the copied files match, and the source has not changed during transfer.
    static func handoff(from source: String, to destination: String) -> GitHandoffResult {
        copyState(
            from: source,
            to: destination,
            moveSource: true,
            includeIgnoredSetup: true
        )
    }

    static func repositoryRoot(for directory: String) -> String? {
        value(["-C", directory, "rev-parse", "--show-toplevel"])
    }

    static func mainWorktree(from directory: String) -> String? {
        guard let root = repositoryRoot(for: directory) else { return nil }
        let result = run(["-C", root, "worktree", "list", "--porcelain"])
        guard result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .first(where: { $0.hasPrefix("worktree ") })
            .map { String($0.dropFirst("worktree ".count)) }
    }

    static func isMainWorktree(_ directory: String) -> Bool {
        guard let root = repositoryRoot(for: directory),
              let main = mainWorktree(from: root) else { return true }
        return URL(fileURLWithPath: root).standardizedFileURL.path
            == URL(fileURLWithPath: main).standardizedFileURL.path
    }

    private static func copyState(
        from sourceDirectory: String,
        to destinationDirectory: String,
        moveSource: Bool,
        includeIgnoredSetup: Bool
    ) -> GitHandoffResult {
        guard let sourceRoot = repositoryRoot(for: sourceDirectory),
              let destinationRoot = repositoryRoot(for: destinationDirectory) else {
            return .init(success: false, message: "Both locations must be Git worktrees.")
        }
        guard sourceRoot != destinationRoot else {
            return .init(success: false, message: "Source and destination are the same checkout.")
        }
        guard commonDirectory(for: sourceRoot) == commonDirectory(for: destinationRoot) else {
            return .init(success: false, message: "Source and destination do not belong to the same repository.")
        }
        let destinationStatus = run([
            "-C", destinationRoot, "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ])
        guard destinationStatus.status == 0 else {
            return .init(success: false, message: "Could not inspect the destination checkout.")
        }
        guard let destinationHead = value(["-C", destinationRoot, "rev-parse", "HEAD"]) else {
            return .init(success: false, message: "Could not resolve the destination commit.")
        }

        let snapshot: StateSnapshot
        let destinationSnapshot: StateSnapshot?
        do {
            snapshot = try captureState(
                at: sourceRoot,
                relativeTo: destinationHead,
                includeIgnoredSetup: includeIgnoredSetup
            )
            destinationSnapshot = destinationStatus.stdout.isEmpty ? nil : try captureState(
                at: destinationRoot,
                relativeTo: destinationHead,
                includeIgnoredSetup: includeIgnoredSetup
            )
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }

        var createdFiles: [String] = []
        do {
            if let destinationSnapshot {
                let currentDestination = try captureState(
                    at: destinationRoot,
                    relativeTo: destinationHead,
                    includeIgnoredSetup: includeIgnoredSetup
                )
                guard currentDestination == destinationSnapshot else {
                    return .init(
                        success: false,
                        message: "Destination changed while preparing handoff. Both checkouts were preserved; try again."
                    )
                }
                try resetAndRemoveUntracked(at: destinationRoot)
                try applyMerged(
                    source: snapshot,
                    destination: destinationSnapshot,
                    to: destinationRoot,
                    createdFiles: &createdFiles
                )
                try verifyNonOverlappingPaths(
                    source: snapshot,
                    destination: destinationSnapshot,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot
                )
            } else {
                try apply(snapshot: snapshot, to: destinationRoot, createdFiles: &createdFiles)
                try verify(snapshot: snapshot, sourceRoot: sourceRoot, destinationRoot: destinationRoot)
            }
            let appliedDestination = try captureState(
                at: destinationRoot,
                relativeTo: destinationHead,
                includeIgnoredSetup: includeIgnoredSetup
            )

            if moveSource {
                let currentSource = try captureState(
                    at: sourceRoot,
                    relativeTo: destinationHead,
                    includeIgnoredSetup: includeIgnoredSetup
                )
                let currentDestination = try captureState(
                    at: destinationRoot,
                    relativeTo: destinationHead,
                    includeIgnoredSetup: includeIgnoredSetup
                )
                guard currentDestination == appliedDestination else {
                    return .init(
                        success: false,
                        message: "Destination changed during handoff. Source was preserved; review the destination before retrying."
                    )
                }
                guard currentSource == snapshot else {
                    let recoveryError: String?
                    if let destinationSnapshot {
                        recoveryError = restore(
                            snapshot: destinationSnapshot,
                            at: destinationRoot,
                            createdFiles: createdFiles
                        )
                    } else {
                        rollback(snapshot: snapshot, at: destinationRoot, createdFiles: createdFiles)
                        recoveryError = nil
                    }
                    if let recoveryError {
                        return .init(
                            success: false,
                            message: "Source changed during handoff and destination recovery failed: \(recoveryError). Source was preserved."
                        )
                    }
                    return .init(
                        success: false,
                        message: "Source changed during handoff. Destination was rolled back; source was preserved."
                    )
                }
                let cleanup = cleanSource(snapshot: snapshot, at: sourceRoot)
                if let cleanup {
                    return .init(
                        success: true,
                        message: "Handoff completed, but source cleanup was incomplete: \(cleanup)"
                    )
                }
            }
            return .init(success: true, message: moveSource ? "Task handed off successfully." : "Worktree created.")
        } catch {
            if let destinationSnapshot {
                let restored = restore(
                    snapshot: destinationSnapshot,
                    at: destinationRoot,
                    createdFiles: createdFiles
                )
                let detail = error.localizedDescription
                if let restored {
                    return .init(
                        success: false,
                        message: "Handoff could not merge the checkout changes, and destination recovery failed: \(restored). Source was preserved. Original error: \(detail)"
                    )
                }
                return .init(
                    success: false,
                    message: "Handoff conflicts with destination changes. Destination was restored and source was preserved. \(detail)"
                )
            }
            rollback(snapshot: snapshot, at: destinationRoot, createdFiles: createdFiles)
            return .init(success: false, message: error.localizedDescription)
        }
    }

    private static func captureState(
        at root: String,
        relativeTo destinationHead: String,
        includeIgnoredSetup: Bool
    ) throws -> StateSnapshot {
        guard let sourceHead = value(["-C", root, "rev-parse", "HEAD"]) else {
            throw HandoffError("Could not resolve source HEAD.")
        }
        let sameHead = sourceHead == destinationHead
        let staged = sameHead
            ? try successfulData(["-C", root, "diff", "--cached", "--binary", "--full-index", "HEAD", "--"])
            : Data()
        let working = sameHead
            ? try successfulData(["-C", root, "diff", "--binary", "--full-index", "--"])
            : Data()
        let aggregate = sameHead
            ? Data()
            : try successfulData(["-C", root, "diff", "--binary", "--full-index", destinationHead, "--"])
        let trackedPaths = try nullSeparatedPaths([
            "-C", root, "diff", "--name-only", "-z", destinationHead, "--"
        ])
        let untrackedPaths = try nullSeparatedPaths([
            "-C", root, "ls-files", "--others", "--exclude-standard", "-z"
        ])
        let untracked = try payloads(for: untrackedPaths, root: root, skipSymlinks: false)

        var ignored: [FilePayload] = []
        let includeFile = URL(fileURLWithPath: root).appendingPathComponent(".worktreeinclude")
        if includeIgnoredSetup, FileManager.default.fileExists(atPath: includeFile.path) {
            let ignoredPaths = try nullSeparatedPaths([
                "-C", root, "ls-files", "--others", "--ignored", "-z",
                "--exclude-from=.worktreeinclude"
            ])
            ignored = try payloads(for: ignoredPaths, root: root, skipSymlinks: true)
        }
        return .init(
            sourceHead: sourceHead,
            destinationHead: destinationHead,
            stagedPatch: staged,
            workingPatch: working,
            aggregatePatch: aggregate,
            trackedPaths: trackedPaths,
            untrackedFiles: untracked,
            includedIgnoredFiles: ignored
        )
    }

    private static func apply(
        snapshot: StateSnapshot,
        to root: String,
        createdFiles: inout [String]
    ) throws {
        if !snapshot.aggregatePatch.isEmpty {
            try applyPatch(snapshot.aggregatePatch, arguments: ["-C", root, "apply", "--binary", "-"])
        } else {
            if !snapshot.stagedPatch.isEmpty {
                try applyPatch(
                    snapshot.stagedPatch,
                    arguments: ["-C", root, "apply", "--index", "--binary", "-"]
                )
            }
            if !snapshot.workingPatch.isEmpty {
                try applyPatch(snapshot.workingPatch, arguments: ["-C", root, "apply", "--binary", "-"])
            }
        }
        try copy(snapshot.untrackedFiles, to: root, overwrite: false, createdFiles: &createdFiles)
        try copy(snapshot.includedIgnoredFiles, to: root, overwrite: false, createdFiles: &createdFiles, skipExisting: true)
    }

    /// Replays both checkout states in index/working-tree order. Git applies
    /// non-overlapping hunks normally and rejects overlapping hunks before the
    /// source is cleaned; the caller then restores the destination snapshot.
    private static func applyMerged(
        source: StateSnapshot,
        destination: StateSnapshot,
        to root: String,
        createdFiles: inout [String]
    ) throws {
        if !source.aggregatePatch.isEmpty {
            try applyPatch(source.aggregatePatch, arguments: ["-C", root, "apply", "--binary", "-"])
            try applyTrackedLayers(destination, to: root)
        } else {
            if !destination.stagedPatch.isEmpty {
                try applyPatch(destination.stagedPatch, arguments: ["-C", root, "apply", "--index", "--binary", "-"])
            }
            if !source.stagedPatch.isEmpty {
                try applyPatch(source.stagedPatch, arguments: ["-C", root, "apply", "--index", "--binary", "-"])
            }
            if !destination.workingPatch.isEmpty {
                try applyPatch(destination.workingPatch, arguments: ["-C", root, "apply", "--binary", "-"])
            }
            if !source.workingPatch.isEmpty {
                try applyPatch(source.workingPatch, arguments: ["-C", root, "apply", "--binary", "-"])
            }
        }
        try copy(destination.untrackedFiles, to: root, overwrite: false, createdFiles: &createdFiles)
        try copy(source.untrackedFiles, to: root, overwrite: false, createdFiles: &createdFiles)
        // Ignored setup files are copied only when absent, matching
        // `.worktreeinclude` semantics without overwriting destination secrets.
        try copy(source.includedIgnoredFiles, to: root, overwrite: false, createdFiles: &createdFiles, skipExisting: true)
    }

    private static func applyTrackedLayers(_ snapshot: StateSnapshot, to root: String) throws {
        if !snapshot.stagedPatch.isEmpty {
            try applyPatch(snapshot.stagedPatch, arguments: ["-C", root, "apply", "--index", "--binary", "-"])
        }
        if !snapshot.workingPatch.isEmpty {
            try applyPatch(snapshot.workingPatch, arguments: ["-C", root, "apply", "--binary", "-"])
        }
    }

    private static func verify(
        snapshot: StateSnapshot,
        sourceRoot: String,
        destinationRoot: String
    ) throws {
        let paths = Set(snapshot.trackedPaths + snapshot.untrackedFiles.map(\.path))
        for path in paths {
            let source = try fileState(at: path, root: sourceRoot)
            let destination = try fileState(at: path, root: destinationRoot)
            guard source == destination else {
                throw HandoffError("Verification failed for \(path).")
            }
        }
    }

    private static func verifyNonOverlappingPaths(
        source: StateSnapshot,
        destination: StateSnapshot,
        sourceRoot: String,
        destinationRoot: String
    ) throws {
        let sourcePaths = Set(source.trackedPaths + source.untrackedFiles.map(\.path))
        let destinationPaths = Set(destination.trackedPaths + destination.untrackedFiles.map(\.path))
        for path in sourcePaths.subtracting(destinationPaths) {
            guard try fileState(at: path, root: sourceRoot) == fileState(at: path, root: destinationRoot) else {
                throw HandoffError("Verification failed for source path \(path).")
            }
        }
    }

    private static func cleanSource(snapshot: StateSnapshot, at root: String) -> String? {
        let reset = run(["-C", root, "reset", "--hard", "HEAD"])
        guard reset.status == 0 else { return reset.output }
        var errors: [String] = []
        for file in snapshot.untrackedFiles {
            let url = safeURL(for: file.path, root: root)
            guard let url else {
                errors.append("unsafe path \(file.path)")
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                errors.append("\(file.path): \(error.localizedDescription)")
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    private static func rollback(
        snapshot: StateSnapshot,
        at root: String,
        createdFiles: [String]
    ) {
        _ = run(["-C", root, "reset", "--hard", "HEAD"])
        for path in createdFiles {
            if let url = safeURL(for: path, root: root) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // A patch-added path can become untracked after reset; remove it only
        // when it did not exist in destination HEAD.
        for path in snapshot.trackedPaths {
            let existsInHead = run(["-C", root, "cat-file", "-e", "HEAD:\(path)"]).status == 0
            if !existsInHead, let url = safeURL(for: path, root: root) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Restores a dirty destination after a rejected merge. Ignored files that
    /// existed before handoff were never removed; only files created by the
    /// attempted source replay are cleaned.
    private static func restore(
        snapshot: StateSnapshot,
        at root: String,
        createdFiles: [String]
    ) -> String? {
        do {
            try resetAndRemoveUntracked(at: root)
            for path in createdFiles where snapshot.includedIgnoredFiles.contains(where: { $0.path == path }) == false {
                if let url = safeURL(for: path, root: root), FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            var restoredFiles: [String] = []
            try apply(snapshot: snapshot, to: root, createdFiles: &restoredFiles)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func resetAndRemoveUntracked(at root: String) throws {
        let reset = run(["-C", root, "reset", "--hard", "HEAD"])
        guard reset.status == 0 else { throw HandoffError(reset.output) }
        let paths = try nullSeparatedPaths([
            "-C", root, "ls-files", "--others", "--exclude-standard", "-z"
        ])
        for path in paths {
            guard let url = safeURL(for: path, root: root) else {
                throw HandoffError("Unsafe path while restoring destination: \(path)")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func copy(
        _ files: [FilePayload],
        to root: String,
        overwrite: Bool,
        createdFiles: inout [String],
        skipExisting: Bool = false
    ) throws {
        for file in files {
            guard let url = safeURL(for: file.path, root: root) else {
                throw HandoffError("Unsafe path: \(file.path)")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                if skipExisting { continue }
                if !overwrite { throw HandoffError("Destination already contains \(file.path).") }
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch file.content {
            case .regular(let data, let executable):
                try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
                if executable {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
            createdFiles.append(file.path)
        }
    }

    private enum ComparableFileState: Equatable {
        case missing
        case regular(Data, executable: Bool)
        case symlink(String)
    }

    private static func fileState(at path: String, root: String) throws -> ComparableFileState {
        guard let url = safeURL(for: path, root: root) else {
            throw HandoffError("Unsafe path: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return .symlink(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        guard !isDirectory.boolValue else { throw HandoffError("Directory payload is unsupported: \(path)") }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return .regular(try Data(contentsOf: url), executable: permissions & 0o111 != 0)
    }

    private static func payloads(
        for paths: [String],
        root: String,
        skipSymlinks: Bool
    ) throws -> [FilePayload] {
        try paths.compactMap { path in
            switch try fileState(at: path, root: root) {
            case .regular(let data, let executable):
                return FilePayload(path: path, content: .regular(data, executable: executable))
            case .symlink:
                if skipSymlinks { return nil }
                throw HandoffError("Untracked symlinks are not moved automatically: \(path)")
            case .missing:
                throw HandoffError("File changed while creating snapshot: \(path)")
            }
        }
    }

    private static func safeURL(for relativePath: String, root: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        return url.path.hasPrefix(rootURL.path + "/") ? url : nil
    }

    private static func commonDirectory(for root: String) -> String? {
        guard let raw = value(["-C", root, "rev-parse", "--git-common-dir"]) else { return nil }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(raw)
        return url.standardizedFileURL.path
    }

    private static func applyPatch(_ patch: Data, arguments: [String]) throws {
        let result = run(arguments, standardInput: patch)
        guard result.status == 0 else {
            throw HandoffError(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func nullSeparatedPaths(_ arguments: [String]) throws -> [String] {
        let data = try successfulData(arguments)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HandoffError("Git returned a non-UTF-8 path.")
        }
        return string.split(separator: "\0").map(String.init)
    }

    private static func successfulData(_ arguments: [String]) throws -> Data {
        let result = run(arguments)
        guard result.status == 0 else {
            throw HandoffError(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    private static func value(_ arguments: [String]) -> String? {
        let result = run(arguments)
        guard result.status == 0 else { return nil }
        let value = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func run(_ arguments: [String], standardInput: Data? = nil) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        do {
            try process.run()
            if let standardInput, let inputPipe {
                inputPipe.fileHandleForWriting.write(standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }
            let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            return .init(
                status: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8)
            )
        }
    }

    private static func branchSlug(from name: String) -> String {
        let cleaned = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(slug.prefix(40))
        return trimmed.isEmpty ? "task" : trimmed
    }

    private struct HandoffError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message.isEmpty ? "Git handoff failed." : message }
        var errorDescription: String? { message }
    }
}
#endif
