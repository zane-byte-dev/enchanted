//
//  ConversationSD.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData

@Model
final class ConversationSD: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Whether the conversation is pinned to the top of its project group.
    var isPinned: Bool = false
    /// Whether the conversation is archived (hidden from the main list).
    var isArchived: Bool = false
    /// Per-conversation working directory the agent operates in.
    /// nil → fall back to the global default.
    var workingDirectory: String?

    /// Absolute path of the pi session file backing this conversation, so pi's
    /// context can be restored (`switch_session`) after the app/process restarts.
    var piSessionPath: String?

    @Relationship(deleteRule: .nullify)
    var model: LanguageModelSD?

    @Relationship(deleteRule: .cascade, inverse: \MessageSD.conversation)
    var messages: [MessageSD] = []
    
    init(name: String, updatedAt: Date = Date.now) {
        self.name = name
        self.updatedAt = updatedAt
        self.createdAt = updatedAt
    }
}

// MARK: - Sample data
extension ConversationSD {
    static let sample = [
        ConversationSD(name: String(localized: "New Chat"), updatedAt: Date.now),
        ConversationSD(name: "Presidential", updatedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!),
        ConversationSD(name: "What is QFT?", updatedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date.now)!)
    ]
}

// MARK: - @unchecked Sendable
extension ConversationSD: @unchecked Sendable {
    /// We hide compiler warnings for concurency. We have to make sure to modify the data only via SwiftDataManager to ensure concurrent operations.
}
