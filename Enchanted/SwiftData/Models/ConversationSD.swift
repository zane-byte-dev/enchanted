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
    /// Structured agent plan, persisted independently from chat messages.
    var planJSON: String?
    /// Optional long-running objective and its continuation policy.
    var goalText: String?
    var goalStatus: String = "inactive"
    var goalAutoContinue: Bool = false
    var goalContinuationCount: Int = 0
    /// Origin schedule for completion-history callbacks; not copied on forks.
    var scheduledTaskID: UUID?

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
    @MainActor static let sample = [
        ConversationSD(name: String(localized: "New Chat"), updatedAt: Date.now),
        ConversationSD(name: "Presidential", updatedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!),
        ConversationSD(name: "What is QFT?", updatedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date.now)!)
    ]
}

// See MessageSD's Sendable note. Model instances are serialized through the
// shared ModelActor even though the SDK macro doesn't expose that fact cleanly
// to strict-concurrency diagnostics yet.

@Model
final class ScheduledTaskSD: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var prompt: String
    var workingDirectory: String
    var modelName: String?
    var intervalSeconds: Double
    var nextRunAt: Date
    var lastRunAt: Date?
    var isEnabled: Bool = true
    /// `run_once` or `skip` when the app was not running at the due time.
    var missedPolicy: String = "run_once"
    /// JSON-encoded bounded list of launch records.
    var runHistoryJSON: String?
    var createdAt: Date = Date.now

    init(
        name: String,
        prompt: String,
        workingDirectory: String,
        modelName: String?,
        intervalSeconds: Double,
        nextRunAt: Date,
        missedPolicy: String = "run_once"
    ) {
        self.name = name
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.modelName = modelName
        self.intervalSeconds = intervalSeconds
        self.nextRunAt = nextRunAt
        self.missedPolicy = missedPolicy
    }
}
