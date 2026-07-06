//
//  ChatsStore.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData
import Combine
import SwiftUI

/// State for one in-flight generation. Each conversation can have its own,
/// so multiple agents can run in parallel.
final class AgentRun: @unchecked Sendable {
    let conversationID: UUID
    let assistantMessage: MessageSD
    var cancellable: AnyCancellable?
    let throttler = Throttler(delay: 0.1)

    /// Ordered render blocks for this turn.
    var blocks: [MessageBlock] = []

    init(conversationID: UUID, assistantMessage: MessageSD) {
        self.conversationID = conversationID
        self.assistantMessage = assistantMessage
    }

    /// Append streaming text to the trailing text block (or open a new one).
    func appendText(_ text: String) {
        if case .text(let existing) = blocks.last {
            blocks[blocks.count - 1] = .text(existing + text)
        } else {
            blocks.append(.text(text))
        }
    }

    /// Append reasoning text to the trailing thinking block (or open a new one).
    func appendThinking(_ text: String) {
        if case .thinking(let existing) = blocks.last {
            blocks[blocks.count - 1] = .thinking(existing + text)
        } else {
            blocks.append(.thinking(text))
        }
    }

    func startTool(callId: String, name: String, args: String) {
        blocks.append(.tool(ToolCall(callId: callId, name: name, argsJSON: args)))
    }

    func endTool(callId: String, result: String, isError: Bool) {
        guard let idx = blocks.lastIndex(where: {
            if case .tool(let t) = $0 { return t.callId == callId && t.running } else { return false }
        }) else { return }
        if case .tool(var t) = blocks[idx] {
            t.resultText = result
            t.isError = isError
            t.running = false
            blocks[idx] = .tool(t)
        }
    }

    /// Serialize blocks + plain-text mirror into the message for rendering/persist.
    func flush() {
        if let data = try? JSONEncoder().encode(blocks),
           let json = String(data: data, encoding: .utf8) {
            assistantMessage.blocksJSON = json
        }
        // Keep `content` as a plain-text mirror for copy / TTS / legacy views.
        assistantMessage.content = blocks.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined()
    }
}

@Observable
final class ConversationStore: Sendable {
    static let shared = ConversationStore(swiftDataService: SwiftDataService.shared)

    /// Default / control backend used for model listing + reachability.
    /// Per-conversation chat uses the dedicated connectors below.
    var backend: AgentBackend = OllamaBackend()

    private var swiftDataService: SwiftDataService

    /// One backend (e.g. a pi RPC process) per conversation, keyed by id.
    @MainActor private var connectors: [UUID: AgentBackend] = [:]
    /// Active generations, keyed by conversation id — enables parallel runs.
    @MainActor private var runs: [UUID: AgentRun] = [:]
    /// Per-conversation UI state.
    @MainActor private var states: [UUID: ConversationState] = [:]
    /// Per-conversation token/cost/context stats.
    @MainActor private var stats: [UUID: PiSessionStats] = [:]

    @MainActor var conversations: [ConversationSD] = []
    @MainActor var selectedConversation: ConversationSD?
    @MainActor var messages: [MessageSD] = []

    /// State of the currently selected conversation (for existing UI bindings).
    @MainActor var conversationState: ConversationState {
        guard let id = selectedConversation?.id else { return .completed }
        return states[id] ?? .completed
    }

    /// State for any conversation — used by the sidebar status badges.
    @MainActor func state(for id: UUID) -> ConversationState {
        states[id] ?? .completed
    }

    @MainActor var isRunning: Bool { !runs.isEmpty }

    /// Stats for the currently selected conversation (for the composer stats bar).
    @MainActor var currentStats: PiSessionStats? {
        guard let id = selectedConversation?.id else { return nil }
        return stats[id]
    }

    /// Refresh stats for a conversation from its pi process (best-effort).
    @MainActor
    func refreshStats(for conversationID: UUID) {
        guard let connector = connectors[conversationID] as? PiConnector else { return }
        Task {
            if let s = await connector.sessionStats() {
                await MainActor.run { self.stats[conversationID] = s }
            }
        }
    }

    /// Steer the in-flight turn if one is running; returns true if steered.
    @MainActor
    func steerIfRunning(_ message: String) -> Bool {
        guard let id = selectedConversation?.id, runs[id] != nil,
              let connector = connectors[id] as? PiConnector else { return false }
        connector.steer(message)
        return true
    }

    init(swiftDataService: SwiftDataService) {
        self.swiftDataService = swiftDataService
    }

    // MARK: - Conversation list / selection

    func loadConversations() async throws {
        let fetchedConversations = try await swiftDataService.fetchConversations()
        DispatchQueue.main.async {
            self.conversations = fetchedConversations
        }
    }

    @MainActor private var isSyncing = false
    /// Last mtime we processed per session file — kills repeated re-sync churn.
    @MainActor private var syncedMtimes: [String: Date] = [:]

    /// Sync pi sessions created/updated elsewhere (VS Code extension, CLI/TUI):
    /// import new sessions and refresh ones whose file changed on disk. Safe to
    /// call repeatedly (polled). Skips conversations the GUI is actively running.
    func syncPiSessions() async {
        guard AgentBackendConfig.currentKind == .pi else { return }
        let alreadySyncing = await MainActor.run { () -> Bool in
            if isSyncing { return true }
            isSyncing = true
            return false
        }
        if alreadySyncing { return }
        defer { Task { @MainActor in self.isSyncing = false } }

        let existing = (try? await swiftDataService.fetchConversations()) ?? []
        var byPath: [String: ConversationSD] = [:]
        for c in existing { if let p = c.piSessionPath { byPath[p] = c } }
        // Conversations the GUI owns a live connector for — pi is writing these,
        // so never touch them from the sync path (would corrupt an active run).
        let ownedIDs = await MainActor.run { Set(self.connectors.keys) }

        let files = await Task.detached(priority: .utility) { PiSessionImporter.listFiles() }.value

        var newCount = 0
        var changedCount = 0

        for file in files {
            if let conv = byPath[file.path] {
                // Existing conversation: refresh only if the file changed since we
                // last processed it, the GUI doesn't own it, and it's idle.
                let lastSeen = await MainActor.run { self.syncedMtimes[file.path] }
                guard lastSeen != file.mtime,
                      !ownedIDs.contains(conv.id),
                      file.mtime.timeIntervalSince(conv.updatedAt) > 2
                else { continue }
                // Re-check right before the destructive rewrite: skip if a run
                // started or a connector was created in the meantime.
                let raceOwned = await MainActor.run {
                    self.runs[conv.id] != nil || self.connectors[conv.id] != nil
                }
                if raceOwned { continue }
                guard let session = await Task.detached(priority: .utility, operation: {
                    PiSessionImporter.parse(path: file.path)
                }).value else { continue }
                try? await swiftDataService.deleteMessages(forConversation: conv.id)
                await MainActor.run {
                    conv.name = session.name
                    conv.updatedAt = session.updatedAt
                    self.syncedMtimes[file.path] = file.mtime
                }
                try? await swiftDataService.updateConversation(conv)
                await insertMessages(session, into: conv)
                changedCount += 1
            } else {
                // New session on disk → import.
                guard let session = await Task.detached(priority: .utility, operation: {
                    PiSessionImporter.parse(path: file.path)
                }).value else { continue }
                let conversation = await MainActor.run { () -> ConversationSD in
                    let c = ConversationSD(name: session.name, updatedAt: session.updatedAt)
                    c.createdAt = session.createdAt
                    c.workingDirectory = session.cwd
                    c.piSessionPath = session.path
                    return c
                }
                try? await swiftDataService.createConversation(conversation)
                await insertMessages(session, into: conversation)
                await MainActor.run { self.syncedMtimes[file.path] = file.mtime }
                newCount += 1
            }
        }

        if newCount > 0 || changedCount > 0 {
            AgentBackendConfig.debugLog("syncPiSessions: +\(newCount) new, \(changedCount) updated")
            try? await loadConversations()
            await refreshSelectedIfNeeded()
        }
    }

    private func insertMessages(_ session: ImportedSession, into conversation: ConversationSD) async {
        for m in session.messages.sorted(by: { $0.order < $1.order }) {
            let msg = await MainActor.run { () -> MessageSD in
                let msg = MessageSD(content: m.content, role: m.role, done: true)
                msg.blocksJSON = m.blocksJSON
                msg.createdAt = session.createdAt.addingTimeInterval(Double(m.order))
                msg.conversation = conversation
                return msg
            }
            try? await swiftDataService.createMessage(msg)
        }
    }

    /// If the currently-open conversation was refreshed, reload its messages.
    @MainActor
    private func refreshSelectedIfNeeded() async {
        guard let selected = selectedConversation else { return }
        try? await reloadConversation(selected)
    }

    func deleteAllConversations() {
        Task {
            DispatchQueue.main.async { [weak self] in
                self?.messages = []
                self?.selectedConversation = nil
            }
            try? await swiftDataService.deleteConversations()
            try? await swiftDataService.deleteMessages()
            try? await loadConversations()
        }
    }

    func deleteDailyConversations(_ date: Date) {
        Task {
            DispatchQueue.main.async { [self] in
                selectedConversation = nil
                messages = []
            }
            try? await swiftDataService.deleteConversations()
            try? await loadConversations()
        }
    }

    func create(_ conversation: ConversationSD) async throws {
        try await swiftDataService.createConversation(conversation)
    }

    func reloadConversation(_ conversation: ConversationSD) async throws {
        let (messages, selectedConversation) = try await (
            swiftDataService.fetchMessages(conversation.id),
            swiftDataService.getConversation(conversation.id)
        )

        DispatchQueue.main.async {
            self.messages = messages
            self.selectedConversation = selectedConversation
        }
    }

    func selectConversation(_ conversation: ConversationSD) async throws {
        try await reloadConversation(conversation)
        await MainActor.run { self.refreshStats(for: conversation.id) }
    }

    func delete(_ conversation: ConversationSD) async throws {
        await teardownConnector(conversation.id)
        try await swiftDataService.deleteConversation(conversation)
        let fetchedConversations = try await swiftDataService.fetchConversations()
        DispatchQueue.main.async {
            self.selectedConversation = nil
            self.conversations = fetchedConversations
        }
    }

    // MARK: - Working directory (per conversation)

    /// Effective working directory for a conversation.
    @MainActor
    func workingDirectory(for conversation: ConversationSD?) -> String {
        conversation?.workingDirectory ?? WorkspaceStore.shared.currentDirectory
    }

    /// Change a conversation's working directory and restart its backend so the
    /// next turn runs in the new cwd.
    @MainActor
    func setWorkingDirectory(_ path: String, for conversation: ConversationSD) {
        conversation.workingDirectory = path
        Task { try? await swiftDataService.updateConversation(conversation) }
        (connectors[conversation.id] as? PiConnector)?.terminate()
        connectors[conversation.id] = nil
    }

    @MainActor
    private func connector(for conversation: ConversationSD) -> AgentBackend {
        if let existing = connectors[conversation.id] { return existing }
        let cwd = workingDirectory(for: conversation)
        let backend = AgentBackendConfig.makeChatBackend(
            workingDirectory: cwd,
            resumeSessionPath: conversation.piSessionPath
        )
        connectors[conversation.id] = backend
        return backend
    }

    private func teardownConnector(_ id: UUID) async {
        await MainActor.run {
            runs[id]?.cancellable?.cancel()
            runs[id] = nil
            (connectors[id] as? PiConnector)?.terminate()
            connectors[id] = nil
            states[id] = nil
        }
    }

    // MARK: - Generation control

    @MainActor func stopGenerate() {
        guard let id = selectedConversation?.id else { return }
        // Tell pi to actually stop generating, then drop the local subscription.
        (connectors[id] as? PiConnector)?.abort()
        runs[id]?.cancellable?.cancel()
        finishRun(id)
    }

    @MainActor
    func sendPrompt(userPrompt: String, model: LanguageModelSD, image: Image? = nil, systemPrompt: String = "", trimmingMessageId: String? = nil) {
        guard userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

        let conversation = selectedConversation ?? ConversationSD(name: userPrompt)
        conversation.updatedAt = Date.now
        conversation.model = model
        // New conversation inherits the current default working directory.
        if conversation.workingDirectory == nil {
            conversation.workingDirectory = WorkspaceStore.shared.currentDirectory
        }

        /// trim conversation if on edit mode
        if let trimmingMessageId = trimmingMessageId {
            conversation.messages = conversation.messages
                .sorted{$0.createdAt < $1.createdAt}
                .prefix(while: {$0.id.uuidString != trimmingMessageId})
        }

        /// add system prompt to very first message in the conversation
        if !systemPrompt.isEmpty && conversation.messages.isEmpty {
            let systemMessage = MessageSD(content: systemPrompt, role: "system")
            systemMessage.conversation = conversation
        }

        /// construct new user message
        let userMessage = MessageSD(content: userPrompt, role: "user", image: image?.render()?.compressImageData())
        userMessage.conversation = conversation

        /// prepare neutral message history for the active backend
        var messageHistory = conversation.messages
            .sorted{$0.createdAt < $1.createdAt}
            .map{AgentChatMessage(role: AgentChatMessage.Role(rawValue: $0.role) ?? .assistant, content: $0.content)}

        /// attach selected image to the last message
        if let image = image?.render() {
            if let lastMessage = messageHistory.popLast() {
                let imagesBase64: [String] = [image.convertImageToBase64String()]
                messageHistory.append(AgentChatMessage(role: lastMessage.role, content: lastMessage.content, imagesBase64: imagesBase64))
            }
        }

        let assistantMessage = MessageSD(content: "", role: "assistant")
        assistantMessage.conversation = conversation

        let convID = conversation.id
        states[convID] = .loading

        let run = AgentRun(conversationID: convID, assistantMessage: assistantMessage)
        runs[convID] = run

        let backend = connector(for: conversation)

        Task {
            try await swiftDataService.updateConversation(conversation)
            try await swiftDataService.createMessage(userMessage)
            try await swiftDataService.createMessage(assistantMessage)
            try await reloadConversation(conversation)
            try? await loadConversations()

            let ok = await backend.reachable()
            guard ok else {
                await MainActor.run { self.handleError("Backend unreachable", convID: convID) }
                return
            }

            await MainActor.run {
                run.cancellable = backend.chat(model: model.name, messages: messageHistory)
                    .receive(on: DispatchQueue.main)
                    .sink(receiveCompletion: { [weak self] completion in
                        switch completion {
                        case .finished:
                            self?.handleComplete(convID)
                        case .failure(let error):
                            self?.handleError(error.localizedDescription, convID: convID)
                        }
                    }, receiveValue: { [weak self] event in
                        self?.handleEvent(event, convID: convID)
                    })
            }
        }
    }

    // MARK: - Event handling (per conversation)

    @MainActor
    private func handleEvent(_ event: AgentEvent, convID: UUID) {
        guard let run = runs[convID] else { return }

        switch event {
        case .messageDelta(let text):
            run.appendText(text)
            run.throttler.throttle { [weak run] in run?.flush() }

        case .thinkingDelta(let text):
            run.appendThinking(text)
            run.throttler.throttle { [weak run] in run?.flush() }

        case .toolStart(let callId, let name, let args):
            run.startTool(callId: callId, name: name, args: args)
            run.flush()

        case .toolEnd(let callId, _, let result, let isError):
            run.endTool(callId: callId, result: result, isError: isError)
            run.flush()

        case .done:
            run.flush()
        }
    }

    @MainActor
    private func handleError(_ errorMessage: String, convID: UUID) {
        if let message = runs[convID]?.assistantMessage {
            message.error = true
            message.done = false
            Task(priority: .background) { try? await self.swiftDataService.updateMessage(message) }
        }
        runs[convID] = nil
        withAnimation { states[convID] = .error(message: errorMessage) }
    }

    @MainActor
    private func handleComplete(_ convID: UUID) {
        finishRun(convID)
    }

    @MainActor
    private func finishRun(_ convID: UUID) {
        if let run = runs[convID] {
            run.flush()
            let message = run.assistantMessage
            message.error = false
            message.done = true
            Task(priority: .background) { try? await self.swiftDataService.updateMessage(message) }
        }
        runs[convID] = nil
        withAnimation { states[convID] = .completed }
        persistSessionPath(convID)
        refreshStats(for: convID)
    }

    /// After a turn, capture pi's session file path so the conversation can be
    /// resumed (context restored) after a restart.
    @MainActor
    private func persistSessionPath(_ convID: UUID) {
        guard
            let connector = connectors[convID] as? PiConnector,
            let conversation = conversations.first(where: { $0.id == convID }),
            conversation.piSessionPath == nil
        else { return }
        Task {
            guard let path = await connector.currentSessionPath() else { return }
            await MainActor.run {
                conversation.piSessionPath = path
            }
            try? await swiftDataService.updateConversation(conversation)
        }
    }
}
