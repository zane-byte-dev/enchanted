//
//  SkillStore.swift
//  Enchanted
//
//  Loads the pi skills available to the app and exposes them to the Skills page.
//

import Foundation

@Observable
@MainActor
final class SkillStore {
    static let shared = SkillStore()

    var skills: [PiSkill] = []
    var isLoading = false
    var lastError: String?

    private init() {}

    /// Fetch skills from the control backend (the default pi RPC process).
    func load() async {
        isLoading = true
        lastError = nil
        let backend = ConversationStore.shared.backend
        let loaded = await backend.skills()
        skills = loaded.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        if loaded.isEmpty {
            lastError = String(localized: "No skills found. Make sure pi is running.")
        }
        isLoading = false
    }
}
