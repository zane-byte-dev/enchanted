//
//  SwiftDataService.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData

final actor SwiftDataService: ModelActor {
    let modelContainer: ModelContainer
    let modelExecutor: ModelExecutor
    private let modelContext: ModelContext
    
    static let shared = SwiftDataService()
    
    init() {
        let sharedModelContainer: ModelContainer = {
            let schema = Schema([
                LanguageModelSD.self,
                ConversationSD.self,
                MessageSD.self
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }()
        
        self.modelContext = ModelContext(sharedModelContainer)
        self.modelContext.autosaveEnabled = false
        modelContainer = sharedModelContainer
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
    }
}

// MARK: - Language Models
extension SwiftDataService {
    func fetchModels() throws -> [LanguageModelSD] {
        let sortDescriptor = SortDescriptor(\LanguageModelSD.name)
        let fetchDescriptor = FetchDescriptor<LanguageModelSD>(sortBy: [sortDescriptor])
        let models = try modelContext.fetch(fetchDescriptor)
        
        return models
    }
    
    func saveModels(models: [LanguageModelSD]) throws {
        for model in models {
            modelContext.insert(model)
        }
        
        try modelContext.saveChanges()
    }
    
    func deleteModels() throws {
        try modelContext.delete(model: LanguageModelSD.self)
        try modelContext.saveChanges()
    }
}

// MARK: - Conversations
extension SwiftDataService {
    func createConversation(_ conversation: ConversationSD) throws {
        self.modelContext.insert(conversation)
        try modelContext.saveChanges()
    }
    
    func renameConversation(_ conversation: ConversationSD) throws {
        try modelContext.saveChanges()
    }
    
    func deleteConversation(_ conversation: ConversationSD) throws {
        self.modelContext.delete(conversation)
        try modelContext.saveChanges()
    }
    
    func updateConversation(_ conversation: ConversationSD) throws {
        conversation.updatedAt = .now
        try modelContext.saveChanges()
    }
    
    func fetchConversations() throws -> [ConversationSD] {
        let sortDescriptor = SortDescriptor(\ConversationSD.updatedAt, order: .reverse)
        let fetchDescriptor = FetchDescriptor<ConversationSD>(sortBy: [sortDescriptor])
        return try modelContext.fetch(fetchDescriptor)
    }
    
    func getConversation(_ conversationId: UUID) throws -> ConversationSD? {
        let predicate = #Predicate<ConversationSD>{ $0.id == conversationId }
        let fetchDescriptor = FetchDescriptor<ConversationSD>(predicate: predicate)
        let conversations = try modelContext.fetch(fetchDescriptor)
        return conversations.first
    }
    
    func deleteConversations() throws {
        try modelContext.delete(model: ConversationSD.self)
        try modelContext.saveChanges()
    }
    
    func deleteMessages() throws {
        try modelContext.delete(model: MessageSD.self)
        try modelContext.saveChanges()
    }
    
    func deleteConversations(_ date: Date) throws {
        let predicate = #Predicate<ConversationSD>{ $0.createdAt >=  date && $0.createdAt <= date}
        try modelContext.delete(model: ConversationSD.self, where: predicate)
    }
}


// MARK: - Messages
extension SwiftDataService {
    func fetchMessages(_ conversationId: UUID) throws -> [MessageSD] {
        let predicate = #Predicate<MessageSD>{ $0.conversation?.id == conversationId }
        let sortDescriptor = SortDescriptor(\MessageSD.createdAt)
        let fetchDescriptor = FetchDescriptor<MessageSD>(predicate: predicate, sortBy: [sortDescriptor])
        return try modelContext.fetch(fetchDescriptor)
    }
    
    func updateMessage(_ message: MessageSD) throws {
        try modelContext.saveChanges()
    }
    
    func createMessage(_ mesasge: MessageSD) throws {
        self.modelContext.insert(mesasge)
        try modelContext.saveChanges()
    }

    /// Delete all messages belonging to a conversation (used when re-syncing an
    /// externally-updated pi session).
    func deleteMessages(forConversation conversationId: UUID) throws {
        let predicate = #Predicate<MessageSD>{ $0.conversation?.id == conversationId }
        try modelContext.delete(model: MessageSD.self, where: predicate)
        try modelContext.saveChanges()
    }
}

// MARK: - Read-only tool result migration

extension SwiftDataService {
    /// One-time migration: strip the `resultText` payload from read-only tool
    /// blocks (read/grep/glob/…) in every persisted message. Those results used
    /// to embed whole-file contents — megabytes that bloat `blocksJSON` and
    /// cause long white-screen relayouts when SwiftUI re-evaluates
    /// `renderBlocks` on return. New turns already drop them at write time
    /// (see `AgentRun.endTool`); this rewrites existing history.
    ///
    /// Idempotent and guarded by a `UserDefaults` flag so it runs exactly once.
    func migrateReadOnlyToolResults() throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migrated.readOnlyToolResults.v1") else { return }

        let descriptor = FetchDescriptor<MessageSD>()
        let messages = try modelContext.fetch(descriptor)
        var changed = 0
        for message in messages {
            guard let json = message.blocksJSON,
                  let data = json.data(using: .utf8),
                  var blocks = try? JSONDecoder().decode([MessageBlock].self, from: data)
            else { continue }

            var mutated = false
            for i in blocks.indices {
                guard case .tool(var t) = blocks[i], t.isReadOnly, t.resultText != nil else { continue }
                t.resultText = nil
                blocks[i] = .tool(t)
                mutated = true
            }
            guard mutated,
                  let rewritten = try? JSONEncoder().encode(blocks),
                  let rewrittenJSON = String(data: rewritten, encoding: .utf8)
            else { continue }
            message.blocksJSON = rewrittenJSON
            changed += 1
        }
        try modelContext.saveChanges()
        defaults.set(true, forKey: "migrated.readOnlyToolResults.v1")
        if changed > 0 {
            AgentBackendConfig.debugLog("migrateReadOnlyToolResults: trimmed \(changed) messages")
        }
    }
}

// MARK: - General
extension SwiftDataService {
    func deleteEverything() throws {
        try modelContext.delete(model: ConversationSD.self)
        try modelContext.delete(model: LanguageModelSD.self)
        try modelContext.delete(model: MessageSD.self)
        try modelContext.saveChanges()
    }
}
