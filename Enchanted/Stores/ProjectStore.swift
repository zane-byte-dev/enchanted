//
//  ProjectStore.swift
//  Enchanted
//
//  Projects are derived from conversations' working directories rather than
//  stored entities, so per-project UI metadata (pin state, custom display
//  name) lives here, persisted in UserDefaults keyed by directory path.
//

import Foundation

@Observable
@MainActor
final class ProjectStore {
    static let shared = ProjectStore()

    private static let pinnedKey = "pinnedProjectPaths"
    private static let namesKey = "projectDisplayNames"

    /// Directory paths pinned to the top of the sidebar.
    private(set) var pinnedPaths: Set<String>
    /// Custom display names, keyed by directory path.
    private(set) var displayNames: [String: String]

    init() {
        pinnedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
        displayNames = (UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String]) ?? [:]
    }

    // MARK: - Pin

    func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    func togglePin(_ path: String) {
        if pinnedPaths.contains(path) {
            pinnedPaths.remove(path)
        } else {
            pinnedPaths.insert(path)
        }
        UserDefaults.standard.set(Array(pinnedPaths), forKey: Self.pinnedKey)
    }

    // MARK: - Display name

    /// Custom name if set, otherwise the directory's last path component.
    func displayName(for path: String) -> String {
        if let custom = displayNames[path], !custom.isEmpty { return custom }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func hasCustomName(_ path: String) -> Bool { displayNames[path]?.isEmpty == false }

    func setDisplayName(_ name: String, for path: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == URL(fileURLWithPath: path).lastPathComponent {
            displayNames[path] = nil
        } else {
            displayNames[path] = trimmed
        }
        UserDefaults.standard.set(displayNames, forKey: Self.namesKey)
    }

    /// Forget all metadata for a path (used when a project is removed).
    func forget(_ path: String) {
        pinnedPaths.remove(path)
        displayNames[path] = nil
        UserDefaults.standard.set(Array(pinnedPaths), forKey: Self.pinnedKey)
        UserDefaults.standard.set(displayNames, forKey: Self.namesKey)
    }
}
