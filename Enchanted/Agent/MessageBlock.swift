//
//  MessageBlock.swift
//  Enchanted
//
//  Structured pieces of an assistant turn, rendered as interleaved blocks
//  (text / thinking / tool call) — the foundation for Codex-style rendering.
//

import Foundation

enum MessageBlock: Codable, Identifiable, Equatable {
    case text(String)
    case thinking(String)
    case tool(ToolCall)

    var id: String {
        switch self {
        case .text(let s): return "text-\(s.hashValue)"
        case .thinking(let s): return "think-\(s.hashValue)"
        case .tool(let t): return "tool-\(t.callId)"
        }
    }
}

struct ToolCall: Codable, Equatable, Identifiable {
    var callId: String
    var name: String
    /// Raw JSON string of the tool arguments.
    var argsJSON: String
    /// Rendered result text (nil while running).
    var resultText: String?
    var isError: Bool = false
    var running: Bool = true

    var id: String { callId }

    // MARK: - Presentation helpers

    private var args: [String: Any] {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// One-line subtitle for the card header (command / file path).
    var subtitle: String? {
        switch name {
        case "bash":
            return args["command"] as? String
        case "read", "write", "edit":
            return args["path"] as? String
        default:
            if let path = args["path"] as? String { return path }
            if let cmd = args["command"] as? String { return cmd }
            return nil
        }
    }

    var icon: String {
        switch name {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil.and.outline"
        case "search", "grep", "glob": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    /// For edit tools: list of (old, new) hunks to render as a diff.
    var editHunks: [(old: String, new: String)] {
        guard name == "edit", let edits = args["edits"] as? [[String: Any]] else { return [] }
        return edits.compactMap { e in
            guard let old = e["oldText"] as? String, let new = e["newText"] as? String else { return nil }
            return (old, new)
        }
    }

    /// For write tool: full new file content.
    var writeContent: String? {
        guard name == "write" else { return nil }
        return args["content"] as? String
    }
}
