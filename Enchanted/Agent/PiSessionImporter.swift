//
//  PiSessionImporter.swift
//  Enchanted
//
//  Reads pi's on-disk session files (~/.pi/agent/sessions/<cwd-slug>/*.jsonl)
//  and turns them into plain data so the GUI can surface conversations created
//  elsewhere (e.g. the pi VS Code extension or the pi CLI/TUI).
//
//  Pure parsing only — no SwiftData. ConversationStore maps the result onto
//  ConversationSD / MessageSD and reuses the normal resume path
//  (piSessionPath → switch_session) to restore context on open.
//

import Foundation

struct ImportedMessage {
    let role: String          // "user" | "assistant"
    let content: String       // plain-text mirror (copy/TTS/search)
    let blocksJSON: String?   // structured blocks for assistant turns
    let order: Int
}

struct ImportedSession {
    let path: String          // absolute .jsonl path (used as piSessionPath)
    let cwd: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let messages: [ImportedMessage]
}

enum PiSessionImporter {
    /// Root directory pi writes sessions to.
    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    /// Cap individual tool-result payloads so huge reads don't bloat the store.
    private static let maxResultChars = 8_000

    /// Scan every session file on disk, skipping those already known.
    static func scan(skipping knownPaths: Set<String>) -> [ImportedSession] {
        listFiles().compactMap { file in
            knownPaths.contains(file.path) ? nil : parse(URL(fileURLWithPath: file.path))
        }
    }

    /// Cheap stat pass: every session file with its modification time. No parsing.
    static func listFiles() -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(String, Date)] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            for file in files {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                out.append((file.path, mtime))
            }
        }
        return out
    }

    /// Parse a single session file (nil for empty/probe-only sessions).
    static func parse(path: String) -> ImportedSession? {
        parse(URL(fileURLWithPath: path))
    }

    private static func parse(_ url: URL) -> ImportedSession? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        var cwd = ""
        var explicitName: String?
        var messages: [ImportedMessage] = []
        var order = 0

        // Current assistant turn being assembled from consecutive entries.
        var pendingBlocks: [MessageBlock] = []
        var toolIndex: [String: Int] = [:]

        func flushAssistant() {
            guard !pendingBlocks.isEmpty else { return }
            let text = pendingBlocks.compactMap { block -> String? in
                if case .text(let s) = block { return s }; return nil
            }.joined(separator: "\n\n")
            let json = try? JSONEncoder().encode(pendingBlocks)
            messages.append(ImportedMessage(
                role: "assistant",
                content: text,
                blocksJSON: json.flatMap { String(data: $0, encoding: .utf8) },
                order: order
            ))
            order += 1
            pendingBlocks = []
            toolIndex = [:]
        }

        for line in lines {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }

            switch type {
            case "session":
                cwd = obj["cwd"] as? String ?? cwd
            case "session_info":
                if let n = obj["name"] as? String, !n.isEmpty { explicitName = n }
            case "message":
                guard let m = obj["message"] as? [String: Any], let role = m["role"] as? String else { continue }
                switch role {
                case "user":
                    flushAssistant()
                    let text = textItems(m["content"])
                    guard !text.isEmpty else { continue }
                    messages.append(ImportedMessage(role: "user", content: text, blocksJSON: nil, order: order))
                    order += 1
                case "assistant":
                    if let items = m["content"] as? [[String: Any]] {
                        for it in items {
                            switch it["type"] as? String {
                            case "thinking":
                                if let t = it["thinking"] as? String, !t.isEmpty {
                                    pendingBlocks.append(.thinking(t))
                                }
                            case "text":
                                if let t = it["text"] as? String, !t.isEmpty {
                                    pendingBlocks.append(.text(t))
                                }
                            case "toolCall":
                                let callId = it["id"] as? String ?? UUID().uuidString
                                let name = it["name"] as? String ?? "tool"
                                let args = jsonString(it["arguments"])
                                toolIndex[callId] = pendingBlocks.count
                                pendingBlocks.append(.tool(ToolCall(callId: callId, name: name, argsJSON: args, running: false)))
                            default:
                                break
                            }
                        }
                    }
                case "toolResult":
                    let callId = m["toolCallId"] as? String ?? ""
                    guard let idx = toolIndex[callId], idx < pendingBlocks.count,
                          case .tool(var call) = pendingBlocks[idx] else { continue }
                    var result = textItems(m["content"])
                    if result.count > maxResultChars {
                        result = String(result.prefix(maxResultChars)) + "\n… (truncated)"
                    }
                    call.resultText = result
                    call.isError = m["isError"] as? Bool ?? false
                    call.running = false
                    pendingBlocks[idx] = .tool(call)
                default:
                    break
                }
            default:
                break
            }
        }
        flushAssistant()

        // Ignore empty / probe-only sessions.
        guard messages.contains(where: { $0.role == "user" }) else { return nil }

        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let updatedAt = attrs?.contentModificationDate ?? Date()
        let createdAt = parseTimestampFromName(url) ?? updatedAt

        let name = explicitName ?? deriveName(from: messages) ?? URL(fileURLWithPath: cwd).lastPathComponent
        return ImportedSession(path: url.path, cwd: cwd, name: name,
                               createdAt: createdAt, updatedAt: updatedAt, messages: messages)
    }

    // MARK: - Helpers

    /// Join the text items of a content array (ignoring images).
    private static func textItems(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else {
            return content as? String ?? ""
        }
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func deriveName(from messages: [ImportedMessage]) -> String? {
        guard let first = messages.first(where: { $0.role == "user" })?.content else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return String(firstLine.prefix(60))
    }

    /// Session filenames start with an ISO timestamp, e.g.
    /// `2026-07-05T14-44-55-835Z_<uuid>.jsonl`.
    private static func parseTimestampFromName(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        var stamp = String(name[..<underscore])  // 2026-07-05T14-44-55-835Z
        // Convert back to ISO8601: date part keeps '-', time part uses ':' + '.'
        guard let tIdx = stamp.firstIndex(of: "T") else { return nil }
        let datePart = String(stamp[..<tIdx])
        var timePart = String(stamp[stamp.index(after: tIdx)...]) // 14-44-55-835Z
        timePart = timePart.replacingOccurrences(of: "Z", with: "")
        let comps = timePart.split(separator: "-")
        guard comps.count >= 4 else { return nil }
        stamp = "\(datePart)T\(comps[0]):\(comps[1]):\(comps[2]).\(comps[3])Z"
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: stamp)
    }
}
