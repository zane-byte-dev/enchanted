//
//  DiffReview.swift
//  Enchanted
//
//  Structured unified-diff lines and per-conversation inline review drafts.
//

import Foundation

enum DiffLineKind: Equatable, Sendable {
    case metadata
    case hunk
    case context
    case addition
    case deletion
}

enum GitDiffSectionKind: String, Sendable {
    case staged
    case unstaged
    case untracked

    var label: String {
        switch self {
        case .staged: return "Staged"
        case .unstaged: return "Working tree"
        case .untracked: return "Untracked"
        }
    }
}

struct GitDiffSection: Identifiable, Sendable {
    let kind: GitDiffSectionKind
    let text: String

    var id: String { kind.rawValue }
}

struct UnifiedDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let patch: String
}

enum GitHunkOperation: Sendable {
    case stage
    case unstage
    case revert
}

#if os(macOS)
enum GitHunkMutator {
    /// Applies one complete unified-diff hunk through stdin. Git validates the
    /// context before mutating, so a stale diff fails instead of touching the
    /// wrong lines.
    static func apply(
        _ operation: GitHunkOperation,
        repositoryRoot: String,
        patch: String
    ) -> String? {
        let flags: [String]
        switch operation {
        case .stage:
            flags = ["--cached"]
        case .unstage:
            flags = ["--cached", "--reverse"]
        case .revert:
            flags = ["--reverse"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot, "apply"]
            + flags
            + ["--whitespace=nowarn", "-"]
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(patch.utf8))
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return process.terminationStatus == 0
                ? nil
                : (output.isEmpty ? "Git hunk operation failed" : output)
        } catch {
            return error.localizedDescription
        }
    }
}
#endif

struct DiffLineReference: Hashable, Sendable {
    let oldLine: Int?
    let newLine: Int?

    var displayLabel: String {
        if let newLine { return "L\(newLine)" }
        if let oldLine { return "旧 L\(oldLine)" }
        return ""
    }
}

struct DiffDisplayLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let kind: DiffLineKind
    let reference: DiffLineReference?
}

enum UnifiedDiffParser {
    static func parse(_ source: String, isUntracked: Bool = false) -> [DiffDisplayLine] {
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if isUntracked {
            return rawLines.enumerated().map { offset, text in
                DiffDisplayLine(
                    id: offset,
                    text: text,
                    kind: .addition,
                    reference: DiffLineReference(oldLine: nil, newLine: offset + 1)
                )
            }
        }

        var oldLine: Int?
        var newLine: Int?
        var result: [DiffDisplayLine] = []

        for (offset, text) in rawLines.enumerated() {
            if text.hasPrefix("@@"), let starts = hunkStarts(text) {
                oldLine = starts.old
                newLine = starts.new
                result.append(.init(id: offset, text: text, kind: .hunk, reference: nil))
                continue
            }

            guard let currentOld = oldLine, let currentNew = newLine else {
                result.append(.init(id: offset, text: text, kind: .metadata, reference: nil))
                continue
            }

            if text.hasPrefix("+") && !text.hasPrefix("+++") {
                result.append(.init(
                    id: offset,
                    text: text,
                    kind: .addition,
                    reference: .init(oldLine: nil, newLine: currentNew)
                ))
                newLine = currentNew + 1
            } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                result.append(.init(
                    id: offset,
                    text: text,
                    kind: .deletion,
                    reference: .init(oldLine: currentOld, newLine: nil)
                ))
                oldLine = currentOld + 1
            } else if text.hasPrefix("\\ No newline") {
                result.append(.init(id: offset, text: text, kind: .metadata, reference: nil))
            } else {
                result.append(.init(
                    id: offset,
                    text: text,
                    kind: .context,
                    reference: .init(oldLine: currentOld, newLine: currentNew)
                ))
                oldLine = currentOld + 1
                newLine = currentNew + 1
            }
        }
        return result
    }

    static func hunks(in source: String) -> [UnifiedDiffHunk] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstHunk = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return [] }
        let preamble = Array(lines[..<firstHunk])
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard !starts.isEmpty else { return [] }

        var result: [UnifiedDiffHunk] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : lines.endIndex
            let patchLines = preamble + Array(lines[start..<end])
            let patch = patchLines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
            result.append(UnifiedDiffHunk(id: start, header: lines[start], patch: patch))
        }
        return result
    }

    private static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        let fields = line.split(separator: " ")
        guard let oldField = fields.first(where: { $0.hasPrefix("-") }),
              let newField = fields.first(where: { $0.hasPrefix("+") }),
              let old = Int(oldField.dropFirst().split(separator: ",", maxSplits: 1)[0]),
              let new = Int(newField.dropFirst().split(separator: ",", maxSplits: 1)[0]) else {
            return nil
        }
        return (old, new)
    }
}

struct DiffReviewComment: Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String
    let reference: DiffLineReference
    let sourceLine: String
    var body: String

    init(
        id: UUID = UUID(),
        filePath: String,
        reference: DiffLineReference,
        sourceLine: String,
        body: String
    ) {
        self.id = id
        self.filePath = filePath
        self.reference = reference
        self.sourceLine = sourceLine
        self.body = body
    }
}

@Observable
@MainActor
final class GitReviewDraftStore {
    static let shared = GitReviewDraftStore()

    private var commentsByConversation: [UUID: [DiffReviewComment]] = [:]

    func comments(for conversationID: UUID?) -> [DiffReviewComment] {
        guard let conversationID else { return [] }
        return commentsByConversation[conversationID] ?? []
    }

    func comment(
        for conversationID: UUID?,
        filePath: String,
        reference: DiffLineReference
    ) -> DiffReviewComment? {
        comments(for: conversationID).first {
            $0.filePath == filePath && $0.reference == reference
        }
    }

    func save(_ comment: DiffReviewComment, for conversationID: UUID) {
        var comments = commentsByConversation[conversationID] ?? []
        comments.removeAll {
            $0.filePath == comment.filePath && $0.reference == comment.reference
        }
        comments.append(comment)
        commentsByConversation[conversationID] = comments
    }

    func remove(_ comment: DiffReviewComment, from conversationID: UUID) {
        commentsByConversation[conversationID]?.removeAll { $0.id == comment.id }
    }

    func clear(_ conversationID: UUID) {
        commentsByConversation[conversationID] = nil
    }
}

enum DiffReviewPrompt {
    static func make(comments: [DiffReviewComment]) -> String {
        let ordered = comments.sorted {
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            return ($0.reference.newLine ?? $0.reference.oldLine ?? 0)
                < ($1.reference.newLine ?? $1.reference.oldLine ?? 0)
        }
        let items = ordered.map { comment in
            let line = comment.reference.displayLabel
            let quotedSource = comment.sourceLine.trimmingCharacters(in: .whitespaces)
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- `\(comment.filePath):\(line)`\n  > \(quotedSource)\n  \(body)"
        }
        return """
        请处理以下行内代码评审意见。逐项修改并运行相关验证；如果某条不适用，请说明原因。

        \(items.joined(separator: "\n\n"))
        """
    }
}
