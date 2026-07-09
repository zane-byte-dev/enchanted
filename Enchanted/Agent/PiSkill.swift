//
//  PiSkill.swift
//  Enchanted
//
//  Skill descriptor surfaced from a pi RPC session (`get_commands`, filtered to
//  `source == "skill"`). Powers the native Skills management page.
//

import Foundation

/// A pi skill available to the current session.
struct PiSkill: Identifiable, Hashable, Sendable {
    /// Skill name without the `skill:` command prefix (e.g. "daily-report").
    let name: String
    /// One-line description from the skill's frontmatter.
    let description: String
    /// Where the skill was loaded from.
    let scope: Scope
    /// Source metadata (e.g. "top-level" or an owning package name).
    let source: String
    /// Absolute path to the skill's SKILL.md (or .md file).
    let path: String

    var id: String { name }

    /// Human-friendly title: "daily-report" → "Daily Report".
    var title: String {
        name
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    enum Scope: String, Sendable {
        /// Global skills: `~/.agents/skills/`, `~/.pi/agent/skills/`.
        case user
        /// Project-local skills: `.agents/skills/`, `.pi/skills/`.
        case project
        /// One-off skills (e.g. `--skill` on the CLI) or unknown.
        case temporary
        case unknown

        var localizedLabel: String {
            switch self {
            case .user: return String(localized: "Personal")
            case .project: return String(localized: "Project")
            case .temporary, .unknown: return String(localized: "Other")
            }
        }
    }

    init(name: String, description: String, scope: Scope, source: String, path: String) {
        self.name = name
        self.description = description
        self.scope = scope
        self.source = source
        self.path = path
    }

    /// Build from a pi `get_commands` entry (already filtered to skills).
    init?(command: [String: Any]) {
        guard
            let source = command["source"] as? String, source == "skill",
            let rawName = command["name"] as? String
        else { return nil }

        self.name = rawName.hasPrefix("skill:") ? String(rawName.dropFirst("skill:".count)) : rawName
        self.description = command["description"] as? String ?? ""

        let info = command["sourceInfo"] as? [String: Any]
        self.path = info?["path"] as? String ?? ""
        self.source = info?["source"] as? String ?? ""
        self.scope = Scope(rawValue: (info?["scope"] as? String) ?? "") ?? .unknown
    }
}
