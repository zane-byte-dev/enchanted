//
//  AgentGuidanceScanner.swift
//  Enchanted
//
//  Mirrors the context-file discovery order used by the bundled pi backend:
//  global agent guidance first, then ancestor directories from root to cwd.
//

import Foundation

struct AgentGuidanceFile: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case global
        case ancestor
        case workingDirectory
    }

    let url: URL
    let scope: Scope
    let byteCount: Int

    var id: String { url.path }
}

struct AgentGuidanceSnapshot: Equatable, Sendable {
    let files: [AgentGuidanceFile]
    let unreadablePaths: [String]

    static let empty = AgentGuidanceSnapshot(files: [], unreadablePaths: [])
}

enum AgentGuidanceScanner {
    /// This order intentionally matches pi's `DefaultResourceLoader`.
    static let candidateNames = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]

    static func scan(
        workingDirectory: String,
        agentDirectory: String = NSHomeDirectory() + "/.pi/agent",
        stopDirectory: String = "/",
        fileManager: FileManager = .default
    ) -> AgentGuidanceSnapshot {
        let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
        let stop = URL(fileURLWithPath: stopDirectory, isDirectory: true)
            .standardizedFileURL
        let agentDir = URL(fileURLWithPath: agentDirectory, isDirectory: true)
            .standardizedFileURL

        var result: [AgentGuidanceFile] = []
        var unreadablePaths: [String] = []
        var seen = Set<String>()

        if let global = firstContextFile(
            in: agentDir,
            scope: .global,
            fileManager: fileManager,
            unreadablePaths: &unreadablePaths
        ) {
            result.append(global)
            seen.insert(global.url.path)
        }

        var directories: [URL] = []
        var cursor = cwd
        while true {
            directories.append(cursor)
            if cursor.path == stop.path || cursor.path == "/" { break }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent.path == cursor.path { break }
            cursor = parent
        }

        for directory in directories.reversed() {
            let scope: AgentGuidanceFile.Scope = directory.path == cwd.path
                ? .workingDirectory
                : .ancestor
            if let file = firstContextFile(
                in: directory,
                scope: scope,
                fileManager: fileManager,
                unreadablePaths: &unreadablePaths
            ), seen.insert(file.url.path).inserted {
                result.append(file)
            }
        }

        return AgentGuidanceSnapshot(files: result, unreadablePaths: unreadablePaths)
    }

    private static func firstContextFile(
        in directory: URL,
        scope: AgentGuidanceFile.Scope,
        fileManager: FileManager,
        unreadablePaths: inout [String]
    ) -> AgentGuidanceFile? {
        for name in candidateNames {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            guard fileManager.isReadableFile(atPath: url.path) else {
                unreadablePaths.append(url.path)
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return AgentGuidanceFile(url: url, scope: scope, byteCount: byteCount)
        }
        return nil
    }
}
