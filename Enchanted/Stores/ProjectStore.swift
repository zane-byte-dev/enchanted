//
//  ProjectStore.swift
//  Enchanted
//
//  Projects are derived from conversations' working directories rather than
//  stored entities, so per-project UI metadata (pin state, custom display
//  name) lives here, persisted in UserDefaults keyed by directory path.
//

import Foundation

enum ProjectNavigationLayout: String, CaseIterable {
    case grouped
    case flat
}

enum ProjectSortOrder: String, CaseIterable {
    case priority
    case recent
    case manual
}

@Observable
@MainActor
final class ProjectStore {
    static let shared = ProjectStore()

    private static let pinnedKey = "pinnedProjectPaths"
    private static let namesKey = "projectDisplayNames"
    private static let layoutKey = "projectNavigationLayout"
    private static let sortKey = "projectSortOrder"
    private static let manualOrderKey = "manualProjectPaths"
    private static let conversationOrderKey = "manualConversationIDsByProject"

    private let defaults: UserDefaults

    /// Directory paths pinned to the top of the sidebar.
    private(set) var pinnedPaths: Set<String>
    /// Custom display names, keyed by directory path.
    private(set) var displayNames: [String: String]
    private(set) var navigationLayout: ProjectNavigationLayout
    private(set) var sortOrder: ProjectSortOrder
    private(set) var manualProjectPaths: [String]
    private(set) var manualConversationIDsByProject: [String: [String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedPaths = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        displayNames = (defaults.dictionary(forKey: Self.namesKey) as? [String: String]) ?? [:]
        navigationLayout = ProjectNavigationLayout(rawValue: defaults.string(forKey: Self.layoutKey) ?? "") ?? .grouped
        sortOrder = ProjectSortOrder(rawValue: defaults.string(forKey: Self.sortKey) ?? "") ?? .priority
        manualProjectPaths = defaults.stringArray(forKey: Self.manualOrderKey) ?? []
        manualConversationIDsByProject = defaults.dictionary(forKey: Self.conversationOrderKey) as? [String: [String]] ?? [:]
    }

    // MARK: - Pin

    func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    func togglePin(_ path: String) {
        if pinnedPaths.contains(path) {
            pinnedPaths.remove(path)
        } else {
            pinnedPaths.insert(path)
        }
        defaults.set(Array(pinnedPaths), forKey: Self.pinnedKey)
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
        defaults.set(displayNames, forKey: Self.namesKey)
    }

    // MARK: - Navigation layout and ordering

    func setNavigationLayout(_ layout: ProjectNavigationLayout) {
        navigationLayout = layout
        defaults.set(layout.rawValue, forKey: Self.layoutKey)
    }

    func setSortOrder(_ order: ProjectSortOrder, currentPaths: [String]) {
        if order == .manual { normalizeManualOrder(currentPaths) }
        sortOrder = order
        defaults.set(order.rawValue, forKey: Self.sortKey)
    }

    func manualRank(for path: String) -> Int {
        manualProjectPaths.firstIndex(of: path) ?? Int.max
    }

    func moveProject(
        _ path: String,
        relativeTo targetPath: String,
        placeAfter: Bool,
        currentPaths: [String]
    ) {
        normalizeManualOrder(currentPaths)
        guard path != targetPath,
              let source = manualProjectPaths.firstIndex(of: path) else { return }
        manualProjectPaths.remove(at: source)
        guard let target = manualProjectPaths.firstIndex(of: targetPath) else { return }
        let destination = min(target + (placeAfter ? 1 : 0), manualProjectPaths.count)
        manualProjectPaths.insert(path, at: destination)
        defaults.set(manualProjectPaths, forKey: Self.manualOrderKey)
    }

    func manualConversationRank(_ id: UUID, in path: String) -> Int? {
        manualConversationIDsByProject[path]?.firstIndex(of: id.uuidString)
    }

    func moveConversation(
        _ id: UUID,
        relativeTo targetID: UUID,
        placeAfter: Bool,
        in path: String,
        currentIDs: [UUID]
    ) {
        guard id != targetID else { return }
        let current = currentIDs.map(\.uuidString)
        let known = Set(current)
        var order = (manualConversationIDsByProject[path] ?? []).filter(known.contains)
        order.append(contentsOf: current.filter { !order.contains($0) })
        guard let source = order.firstIndex(of: id.uuidString) else { return }
        order.remove(at: source)
        guard let target = order.firstIndex(of: targetID.uuidString) else { return }
        order.insert(id.uuidString, at: min(target + (placeAfter ? 1 : 0), order.count))
        manualConversationIDsByProject[path] = order
        defaults.set(manualConversationIDsByProject, forKey: Self.conversationOrderKey)
    }

    private func normalizeManualOrder(_ currentPaths: [String]) {
        let known = Set(currentPaths)
        var normalized = manualProjectPaths.filter(known.contains)
        normalized.append(contentsOf: currentPaths.filter { !normalized.contains($0) })
        guard normalized != manualProjectPaths else { return }
        manualProjectPaths = normalized
        defaults.set(manualProjectPaths, forKey: Self.manualOrderKey)
    }

    /// Forget all metadata for a path (used when a project is removed).
    func forget(_ path: String) {
        pinnedPaths.remove(path)
        displayNames[path] = nil
        manualProjectPaths.removeAll { $0 == path }
        manualConversationIDsByProject[path] = nil
        defaults.set(Array(pinnedPaths), forKey: Self.pinnedKey)
        defaults.set(displayNames, forKey: Self.namesKey)
        defaults.set(manualProjectPaths, forKey: Self.manualOrderKey)
        defaults.set(manualConversationIDsByProject, forKey: Self.conversationOrderKey)
    }
}
