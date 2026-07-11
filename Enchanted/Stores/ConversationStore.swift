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
import os
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

enum ConversationPerformance {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Enchanted",
        category: "ConversationPerformance"
    )
    static let signposter = OSSignposter(logger: logger)
}

enum ConversationHistorySyncStatus: Equatable {
    case unknown
    case checking
    case inSync(turns: Int)
    case drift(localTurns: Int, piTurns: Int)
    case unavailable
}

struct ConversationHistorySyncReport: Equatable {
    let localTurns: [String]
    let piTurns: [String]

    var rows: [Row] {
        let count = max(localTurns.count, piTurns.count)
        return (0..<count).map { index in
            Row(
                index: index,
                local: localTurns.indices.contains(index) ? localTurns[index] : nil,
                pi: piTurns.indices.contains(index) ? piTurns[index] : nil
            )
        }
    }

    struct Row: Identifiable, Equatable {
        let index: Int
        let local: String?
        let pi: String?
        var id: Int { index }
        var matches: Bool { local == pi }
    }
}

private struct PiTranscriptMessage: Sendable {
    var role: String
    var content: String
    var blocks: [MessageBlock]
    var createdAt: Date
}

private struct PiSessionSeedMessage: Sendable {
    let role: String
    let content: String
    let createdAt: Date
}

struct QueuedFollowUp: Identifiable, Equatable {
    let id: UUID
    var text: String
    var imageData: [Data]

    init(id: UUID = UUID(), text: String, imageData: [Data] = []) {
        self.id = id
        self.text = text
        self.imageData = imageData
    }
}

struct ScheduledTaskRunRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let launchedAt: Date
    var status: String
    let conversationID: UUID?
}

/// State for one in-flight generation. Each conversation can have its own,
/// so multiple agents can run in parallel.
final class AgentRun: @unchecked Sendable {
    let conversationID: UUID
    var assistantMessage: MessageSD
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
            // Read-only tools (read/grep/glob/…) can return whole-file contents
            // — megabytes that bloat `blocksJSON` and cause long white-screen
            // relayouts on return. We never render their result, so drop the
            // payload here; keep only the call metadata for the summary line.
            t.resultText = t.isReadOnly ? nil : result
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

    func beginAssistantMessage(_ message: MessageSD) {
        assistantMessage = message
        blocks = []
    }
}

@Observable
final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore(swiftDataService: SwiftDataService.shared)
    nonisolated private static let messagePageSize = 60
    nonisolated private static let cacheRefreshTTL: TimeInterval = 15

    private struct CachedTranscript {
        var messages: [MessageSD]
        var hasEarlierMessages: Bool
        var refreshedAt: Date
    }

    private struct DeletedMessageSnapshot: @unchecked Sendable {
        let id: UUID
        let content: String
        let role: String
        let blocksJSON: String?
        let done: Bool
        let error: Bool
        let createdAt: Date
        let image: Data?
    }

    private struct DeletedConversationSnapshot: @unchecked Sendable {
        let id: UUID
        let name: String
        let createdAt: Date
        let updatedAt: Date
        let isPinned: Bool
        let isArchived: Bool
        let workingDirectory: String?
        let piSessionPath: String?
        let planJSON: String?
        let goalText: String?
        let goalStatus: String
        let goalAutoContinue: Bool
        let goalContinuationCount: Int
        let model: LanguageModelSD?
        let messages: [DeletedMessageSnapshot]
    }

    /// Default / control backend used for model listing + reachability.
    /// Per-conversation chat uses the dedicated connectors below.
    var backend: AgentBackend = AgentBackendConfig.makeBackend()

    private var swiftDataService: SwiftDataService

    /// One backend (e.g. a pi RPC process) per conversation, keyed by id.
    @MainActor private var connectors: [UUID: AgentBackend] = [:]
    /// Connector instances are tagged with the backend configuration that
    /// created them. A Settings change bumps the generation; active runs finish
    /// on their old connector and the next prompt transparently rebuilds it.
    @MainActor private var connectorGenerations: [UUID: Int] = [:]
    @MainActor private var backendConfigurationGeneration = 0
    /// Last time each connector was used — drives idle reclamation.
    @MainActor private var lastActivity: [UUID: Date] = [:]
    /// Idle pi processes are terminated after this long to free memory; context
    /// is restored on next use via `switch_session`. Set 0 to disable.
    @MainActor private let idleTimeout: TimeInterval = 10 * 60
    @MainActor private var idleReaperStarted = false
    @MainActor private var didRecoverInterruptedRuns = false
    /// Active generations, keyed by conversation id — enables parallel runs.
    @MainActor private var runs: [UUID: AgentRun] = [:]
    /// Per-conversation UI state.
    @MainActor private var states: [UUID: ConversationState] = [:]
    /// Per-conversation token/cost/context stats.
    @MainActor private var stats: [UUID: PiSessionStats] = [:]
    @MainActor private var compactingConversationIDs: Set<UUID> = []
    @MainActor private var compactionStatusMessages: [UUID: MessageSD] = [:]
    /// Editable client-side queue. pi's native follow-up queue has no RPC for
    /// removing or reordering individual items, so UI-managed follow-ups are
    /// dispatched as ordinary turns after the current run settles.
    @MainActor private var followUps: [UUID: [QueuedFollowUp]] = [:]
    @MainActor private var historySyncStatuses: [UUID: ConversationHistorySyncStatus] = [:]
    @MainActor private var historySyncReports: [UUID: ConversationHistorySyncReport] = [:]
    @MainActor private var uiRequests: [UUID: [AgentUIRequest]] = [:]

    /// Recently opened transcripts. Switching back to one of these can paint
    /// immediately while SwiftData refreshes it in the background.
    @MainActor private var messageCache: [UUID: CachedTranscript] = [:]
    @MainActor private var messageCacheRecency: [UUID] = []
    @MainActor private let messageCacheLimit = 8
    @MainActor private var prefetchingConversationIDs: Set<UUID> = []
    @MainActor private var refreshingConversationIDs: Set<UUID> = []
    /// Identifies the newest selection request so a slow, older fetch can
    /// never overwrite a conversation selected afterwards.
    @MainActor private var activeSelectionRequestID: UUID?
    @MainActor private var activeSwitchInterval: (
        conversationID: UUID,
        state: OSSignpostIntervalState
    )?
    @MainActor private var lastDeletedConversation: DeletedConversationSnapshot?
    @MainActor private var deleteUndoExpiryTask: Task<Void, Never>?

    @MainActor var conversations: [ConversationSD] = []
    @MainActor var selectedConversation: ConversationSD?
    @MainActor var messages: [MessageSD] = []
    @MainActor var hasEarlierMessages = false
    @MainActor var isLoadingEarlierMessages = false
    /// One-shot navigation target consumed by MessageListView after a message
    /// deep link has loaded the complete transcript.
    @MainActor var pendingMessageFocusID: UUID?
    /// Message ids currently creating a pi branch. Exposed so rows can disable
    /// duplicate actions and show progress.
    @MainActor private(set) var branchingMessageIDs: Set<UUID> = []
    @MainActor private(set) var isPreparingNewTaskEnvironment = false

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
    @MainActor var canUndoDeletion: Bool { lastDeletedConversation != nil }
    @MainActor var isCompactingSelectedConversation: Bool {
        guard let id = selectedConversation?.id else { return false }
        return compactingConversationIDs.contains(id)
    }
    @MainActor var currentFollowUps: [QueuedFollowUp] {
        guard let id = selectedConversation?.id else { return [] }
        return followUps[id] ?? []
    }
    @MainActor var currentHistorySyncStatus: ConversationHistorySyncStatus {
        guard let id = selectedConversation?.id else { return .unknown }
        return historySyncStatuses[id] ?? .unknown
    }
    @MainActor var currentHistorySyncReport: ConversationHistorySyncReport? {
        guard let id = selectedConversation?.id else { return nil }
        return historySyncReports[id]
    }
    @MainActor var currentUIRequest: AgentUIRequest? {
        guard let id = selectedConversation?.id else { return nil }
        return uiRequests[id]?.first
    }

    @MainActor var currentPlan: AgentPlanSnapshot? {
        guard let json = selectedConversation?.planJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentPlanSnapshot.self, from: data)
    }

    @MainActor var currentGoalText: String? {
        let value = selectedConversation?.goalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    @MainActor var currentGoalStatus: String {
        selectedConversation?.goalStatus ?? "inactive"
    }

    @MainActor var currentGoalAutoContinues: Bool {
        selectedConversation?.goalAutoContinue ?? false
    }

    @MainActor
    func setCurrentGoal(_ text: String, autoContinue: Bool) {
        guard let conversation = selectedConversation else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.goalText = trimmed.isEmpty ? nil : trimmed
        conversation.goalStatus = trimmed.isEmpty ? "inactive" : "active"
        conversation.goalAutoContinue = autoContinue && !trimmed.isEmpty
        conversation.goalContinuationCount = 0
        persistGoalState(conversation)
    }

    @MainActor
    func pauseCurrentGoal() {
        guard let conversation = selectedConversation, currentGoalText != nil else { return }
        conversation.goalStatus = "paused"
        persistGoalState(conversation)
    }

    @MainActor
    func resumeCurrentGoal() {
        guard let conversation = selectedConversation, currentGoalText != nil else { return }
        conversation.goalStatus = "active"
        conversation.goalContinuationCount = 0
        persistGoalState(conversation)
    }

    @MainActor
    private func persistGoalState(_ conversation: ConversationSD) {
        Task(priority: .background) {
            try? await self.swiftDataService.updateConversation(conversation)
        }
    }

    @MainActor
    func respondToCurrentUIRequest(confirmed: Bool? = nil, value: String? = nil) {
        guard let conversationID = selectedConversation?.id,
              let request = uiRequests[conversationID]?.first,
              let connector = connectors[conversationID] as? PiConnector else { return }
        connector.respondToUIRequest(id: request.id, confirmed: confirmed, value: value)
        uiRequests[conversationID]?.removeFirst()
    }

    @MainActor
    func isBranching(messageID: UUID) -> Bool {
        branchingMessageIDs.contains(messageID)
    }

    /// Full transcript for explicit whole-conversation actions such as Copy.
    /// Normal display stays paged; this intentionally pays the full fetch cost
    /// only when the user requests all content.
    func allMessagesForSelectedConversation() async -> [MessageSD] {
        guard let conversationID = await MainActor.run(body: {
            self.selectedConversation?.id
        }) else { return [] }
        return (try? await swiftDataService.fetchMessages(conversationID)) ?? []
    }

    /// Explicitly load the full selected transcript for user-initiated search.
    /// Normal rendering remains paged; this path runs only while Find is open.
    @MainActor
    func loadAllMessagesForSearch() async {
        guard let conversationID = selectedConversation?.id else { return }
        guard let all = try? await swiftDataService.fetchMessages(conversationID) else { return }
        messages = all
        hasEarlierMessages = false
        cacheMessages(all, for: conversationID, hasEarlierMessages: false)
    }

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

    /// Compact the selected stateful pi session without adding a visible chat
    /// turn. pi appends its summary entry to the session; SwiftData keeps the
    /// full human-readable transcript while only the model context shrinks.
    @MainActor
    func compactSelectedConversation() async {
        guard let conversation = selectedConversation else { return }
        let conversationID = conversation.id
        guard runs[conversationID] == nil else {
            AppStore.shared.uiLog(message: "Stop the current run before compacting", status: .error)
            return
        }
        guard compactingConversationIDs.insert(conversationID).inserted else { return }
        defer { compactingConversationIDs.remove(conversationID) }

        showCompactionStarted(reason: "manual", conversationID: conversationID)

        guard let connector = connector(for: conversation) as? PiConnector else {
            AppStore.shared.uiLog(message: "The current backend does not support compaction", status: .error)
            return
        }

        do {
            let result = try await connector.compact()
            lastActivity[conversationID] = .now
            refreshStats(for: conversationID)
            let before = Self.shortTokenCount(result.tokensBefore)
            let after = Self.shortTokenCount(result.estimatedTokensAfter)
            showCompactionFinished(
                reason: "manual",
                tokensBefore: result.tokensBefore,
                estimatedTokensAfter: result.estimatedTokensAfter,
                error: nil,
                conversationID: conversationID
            )
            AppStore.shared.uiLog(message: "Context compacted: \(before) → ~\(after) tokens", status: .info)
        } catch {
            showCompactionFinished(
                reason: "manual",
                tokensBefore: nil,
                estimatedTokensAfter: nil,
                error: error.localizedDescription,
                conversationID: conversationID
            )
            AppStore.shared.uiLog(message: "Compaction failed: \(error.localizedDescription)", status: .error)
        }
    }

    @MainActor
    func applyAutoCompactionSetting(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: "piAutoCompaction")
        let active = connectors.values.compactMap { $0 as? PiConnector }
        for connector in active {
            try? await connector.setAutoCompaction(enabled)
        }
        AppStore.shared.uiLog(
            message: enabled ? "Automatic context compaction enabled" : "Automatic context compaction disabled",
            status: .info
        )
    }

    @MainActor
    func followUpIfRunning(_ message: String, images: [Image] = []) async -> Bool {
        guard let conversationID = selectedConversation?.id,
              runs[conversationID] != nil else { return false }
        let imageData = images.compactMap { $0.render()?.compressImageData() }
        followUps[conversationID, default: []].append(
            QueuedFollowUp(text: message, imageData: imageData)
        )
        AppStore.shared.uiLog(message: "Follow-up queued", status: .info)
        return true
    }

    @MainActor
    func removeFollowUp(_ id: UUID) {
        guard let conversationID = selectedConversation?.id else { return }
        followUps[conversationID]?.removeAll { $0.id == id }
    }

    @MainActor
    func moveFollowUp(_ id: UUID, by offset: Int) {
        guard let conversationID = selectedConversation?.id,
              var queue = followUps[conversationID],
              let source = queue.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(source + offset, 0), queue.count - 1)
        guard source != destination else { return }
        let item = queue.remove(at: source)
        queue.insert(item, at: destination)
        followUps[conversationID] = queue
    }

    @MainActor
    func checkSelectedHistorySync(notify: Bool = true) async {
        guard let conversation = selectedConversation else { return }
        let id = conversation.id
        historySyncStatuses[id] = .checking
        let connector = connector(for: conversation) as? PiConnector
        async let localMessages = swiftDataService.fetchMessages(id)
        let piMessages = await connector?.forkableUserMessageTexts()
        guard let piMessages else {
            historySyncStatuses[id] = .unavailable
            if notify { AppStore.shared.uiLog(message: "Could not read pi history", status: .error) }
            return
        }
        let local = ((try? await localMessages) ?? []).filter { $0.role == "user" }.map(\.content)
        historySyncReports[id] = ConversationHistorySyncReport(localTurns: local, piTurns: piMessages)
        if local == piMessages {
            historySyncStatuses[id] = .inSync(turns: local.count)
            if notify { AppStore.shared.uiLog(message: "Local and pi history are in sync", status: .info) }
        } else {
            historySyncStatuses[id] = .drift(localTurns: local.count, piTurns: piMessages.count)
            AppStore.shared.uiLog(
                message: "History drift detected: local \(local.count) turns, pi \(piMessages.count) turns",
                status: .error
            )
        }
    }

    /// Replace the local readable transcript with the active branch stored in
    /// pi's durable JSONL session. Callers present a destructive confirmation.
    @MainActor
    func resolveHistoryDriftUsingPi() async {
        guard let conversation = selectedConversation,
              runs[conversation.id] == nil,
              let path = conversation.piSessionPath else { return }
        let transcript = await Task.detached { Self.readPiTranscript(at: path) }.value
        guard let transcript, !transcript.isEmpty else {
            AppStore.shared.uiLog(message: "Could not read the pi transcript", status: .error)
            return
        }
        do {
            try await swiftDataService.deleteMessages(forConversation: conversation.id)
            for snapshot in transcript {
                let message = MessageSD(content: snapshot.content, role: snapshot.role, done: true)
                if !snapshot.blocks.isEmpty,
                   let data = try? JSONEncoder().encode(snapshot.blocks) {
                    message.blocksJSON = String(data: data, encoding: .utf8)
                }
                message.createdAt = snapshot.createdAt
                message.conversation = conversation
                try await swiftDataService.createMessage(message)
            }
            try await reloadConversation(conversation)
            await checkSelectedHistorySync()
            AppStore.shared.uiLog(message: "Local history replaced from pi", status: .info)
        } catch {
            AppStore.shared.uiLog(message: "Could not replace local history: \(error.localizedDescription)", status: .error)
        }
    }

    /// Make the local user/assistant transcript authoritative by writing a new
    /// pi v3 session containing the readable conversation, then resume that
    /// session on the next turn. Tool traces and hidden thinking are omitted;
    /// visible conversational context is preserved.
    @MainActor
    func resolveHistoryDriftUsingLocal() async {
        guard let conversation = selectedConversation, runs[conversation.id] == nil else { return }
        let local = (try? await swiftDataService.fetchMessages(conversation.id)) ?? []
        let seed = local.compactMap { message -> PiSessionSeedMessage? in
            guard message.role == "user" || message.role == "assistant",
                  !message.content.isEmpty else { return nil }
            return PiSessionSeedMessage(role: message.role, content: message.content, createdAt: message.createdAt)
        }
        let cwd = workingDirectory(for: conversation)
        let provider = conversation.model?.providerID ?? conversation.model?.modelProvider?.rawValue ?? "unknown"
        let modelID = conversation.model?.name ?? ""
        let path = await Task.detached {
            try? Self.writePiSession(messages: seed, cwd: cwd, provider: provider, modelID: modelID)
        }.value
        guard let path else {
            AppStore.shared.uiLog(message: "Could not create a pi session from local history", status: .error)
            return
        }
        (connectors[conversation.id] as? PiConnector)?.terminate()
        connectors[conversation.id] = nil
        connectorGenerations[conversation.id] = nil
        conversation.piSessionPath = path
        try? await swiftDataService.updateConversation(conversation)
        _ = connector(for: conversation)
        await checkSelectedHistorySync()
        AppStore.shared.uiLog(message: "pi context rebuilt from local history", status: .info)
    }

    nonisolated private static func readPiTranscript(at path: String) -> [PiTranscriptMessage]? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var entries: [String: [String: Any]] = [:]
        var orderedIDs: [String] = []
        for line in source.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            entries[id] = object
            orderedIDs.append(id)
        }
        guard var cursor = orderedIDs.last else { return [] }
        var branch: [[String: Any]] = []
        var visited = Set<String>()
        while !visited.contains(cursor), let entry = entries[cursor] {
            visited.insert(cursor)
            branch.append(entry)
            guard let parent = entry["parentId"] as? String else { break }
            cursor = parent
        }
        branch.reverse()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [PiTranscriptMessage] = []

        func contentText(_ value: Any?) -> String {
            if let text = value as? String { return text }
            return (value as? [[String: Any]] ?? []).compactMap { item in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }.joined()
        }

        for entry in branch where entry["type"] as? String == "message" {
            guard let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let date = (entry["timestamp"] as? String).flatMap(formatter.date(from:)) ?? .now
            switch role {
            case "user":
                result.append(PiTranscriptMessage(
                    role: "user",
                    content: contentText(message["content"]),
                    blocks: [],
                    createdAt: date
                ))
            case "assistant":
                var blocks: [MessageBlock] = []
                if let text = message["content"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                } else {
                    for item in message["content"] as? [[String: Any]] ?? [] {
                        switch item["type"] as? String {
                        case "text":
                            if let text = item["text"] as? String, !text.isEmpty { blocks.append(.text(text)) }
                        case "thinking":
                            if let text = item["thinking"] as? String, !text.isEmpty { blocks.append(.thinking(text)) }
                        case "toolCall":
                            blocks.append(.tool(ToolCall(
                                callId: item["id"] as? String ?? UUID().uuidString,
                                name: item["name"] as? String ?? "tool",
                                argsJSON: jsonString(item["arguments"])
                            )))
                        default:
                            break
                        }
                    }
                }
                let plain = blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
                if let last = result.indices.last, result[last].role == "assistant" {
                    result[last].blocks.append(contentsOf: blocks)
                    result[last].content += plain
                } else {
                    result.append(PiTranscriptMessage(role: "assistant", content: plain, blocks: blocks, createdAt: date))
                }
            case "toolResult":
                guard let callID = message["toolCallId"] as? String,
                      let assistantIndex = result.lastIndex(where: { $0.role == "assistant" }),
                      let blockIndex = result[assistantIndex].blocks.lastIndex(where: {
                          if case .tool(let tool) = $0 { return tool.callId == callID }
                          return false
                      }),
                      case .tool(var tool) = result[assistantIndex].blocks[blockIndex] else { continue }
                tool.running = false
                tool.isError = message["isError"] as? Bool ?? false
                if !tool.isReadOnly {
                    let text = contentText(message["content"])
                    tool.resultText = text.isEmpty ? nil : text
                }
                result[assistantIndex].blocks[blockIndex] = .tool(tool)
            default:
                break
            }
        }
        for messageIndex in result.indices where result[messageIndex].role == "assistant" {
            for blockIndex in result[messageIndex].blocks.indices {
                if case .tool(var tool) = result[messageIndex].blocks[blockIndex], tool.running {
                    tool.running = false
                    result[messageIndex].blocks[blockIndex] = .tool(tool)
                }
            }
        }
        return result
    }

    nonisolated private static func writePiSession(
        messages: [PiSessionSeedMessage],
        cwd: String,
        provider: String,
        modelID: String
    ) throws -> String {
        let directory = NSHomeDirectory() + "/.enchanted-pi/synced-sessions"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString.lowercased()
        let path = directory + "/\(sessionID).jsonl"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var records: [[String: Any]] = [[
            "type": "session", "version": 3, "id": sessionID,
            "timestamp": formatter.string(from: .now), "cwd": cwd,
        ]]
        var parentID: String? = nil
        if !modelID.isEmpty {
            let id = UUID().uuidString.lowercased()
            records.append([
                "type": "model_change", "id": id, "parentId": NSNull(),
                "timestamp": formatter.string(from: .now), "provider": provider, "modelId": modelID,
            ])
            parentID = id
        }
        for item in messages {
            let id = UUID().uuidString.lowercased()
            let content: [[String: Any]] = [["type": "text", "text": item.content]]
            var record: [String: Any] = [
                "type": "message", "id": id,
                "timestamp": formatter.string(from: item.createdAt),
                "message": [
                    "role": item.role,
                    "content": content,
                    "timestamp": Int(item.createdAt.timeIntervalSince1970 * 1000),
                ],
            ]
            record["parentId"] = parentID ?? NSNull()
            records.append(record)
            parentID = id
        }
        let data = try records.map { record -> Data in
            var line = try JSONSerialization.data(withJSONObject: record)
            line.append(0x0A)
            return line
        }.reduce(into: Data()) { $0.append($1) }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    nonisolated private static func jsonString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func shortTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
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
        let shouldRecoverInterruptedRuns = await MainActor.run {
            self.conversations = fetchedConversations
            guard !self.didRecoverInterruptedRuns else { return false }
            self.didRecoverInterruptedRuns = true
            return true
        }
        Task(priority: .utility) { [weak self] in
            await self?.prefetchRecentConversations(from: fetchedConversations)
        }
        if shouldRecoverInterruptedRuns {
            Task(priority: .utility) { [weak self] in
                await self?.recoverInterruptedRuns(from: fetchedConversations)
            }
        }
    }

    /// Reconcile assistant placeholders left behind by an app/process exit.
    /// Pi's persisted transcript is authoritative only for that unfinished
    /// final turn. We never re-submit the prompt because doing so could repeat
    /// shell commands, edits, or other mutating tools.
    private func recoverInterruptedRuns(from conversations: [ConversationSD]) async {
        guard let interrupted = try? await swiftDataService.fetchInterruptedAssistantMessages(),
              !interrupted.isEmpty else { return }

        var recoveredConversationIDs = Set<UUID>()
        for message in interrupted {
            guard let conversationID = message.conversation?.id,
                  !recoveredConversationIDs.contains(conversationID),
                  let conversation = conversations.first(where: { $0.id == conversationID })
            else { continue }
            recoveredConversationIDs.insert(conversationID)

            let connector: PiConnector? = await MainActor.run {
                guard self.runs[conversationID] == nil,
                      let sessionPath = conversation.piSessionPath,
                      !sessionPath.isEmpty else { return nil }
                return self.connector(for: conversation) as? PiConnector
            }
            let recoveredTurn = await connector?.recoverLatestTurn()
            await applyRecoveredTurn(
                recoveredTurn,
                to: message,
                conversation: conversation
            )
        }
    }

    private func applyRecoveredTurn(
        _ recoveredTurn: PiRecoveredTurn?,
        to message: MessageSD,
        conversation: ConversationSD
    ) async {
        let interruptedNotice = String(localized:
            "The previous task was interrupted when the app exited. Recovered output and session context were preserved; send a message to continue."
        )
        let completedSuccessfully = recoveredTurn?.completedSuccessfully == true

        await MainActor.run {
            var blocks = recoveredTurn?.blocks ?? message.renderBlocks
            if completedSuccessfully {
                message.error = false
            } else {
                if !blocks.contains(where: {
                    if case .text(let text) = $0 { return text.contains(interruptedNotice) }
                    return false
                }) {
                    blocks.append(.text("\n\n> \(interruptedNotice)"))
                }
                message.error = true
            }

            if let data = try? JSONEncoder().encode(blocks),
               let json = String(data: data, encoding: .utf8) {
                message.blocksJSON = json
            }
            message.content = blocks.compactMap {
                if case .text(let text) = $0 { return text }
                return nil
            }.joined()
            // There is no live publisher after relaunch. Mark rendering as
            // terminal even when the recovered turn itself was interrupted.
            message.done = true
            self.states[conversation.id] = completedSuccessfully
                ? .completed
                : .error(message: interruptedNotice)
        }

        try? await swiftDataService.updateMessage(message)
        try? await reloadConversation(conversation)
        AgentBackendConfig.debugLog(
            "recoverInterruptedRuns: \(conversation.id) " +
            (completedSuccessfully ? "completed from pi transcript" : "marked interrupted")
        )
    }

    /// Warm the last page of the two most recent active conversations. This is
    /// deliberately bounded and low-priority so startup work remains small.
    private func prefetchRecentConversations(from conversations: [ConversationSD]) async {
        let candidates = Array(conversations.lazy.filter { !$0.isArchived }.prefix(2))
        for conversation in candidates {
            let conversationID = conversation.id
            let shouldPrefetch = await MainActor.run {
                guard self.messageCache[conversationID] == nil,
                      !self.prefetchingConversationIDs.contains(conversationID) else {
                    return false
                }
                self.prefetchingConversationIDs.insert(conversationID)
                return true
            }
            guard shouldPrefetch else { continue }

            let interval = ConversationPerformance.signposter
                .beginInterval("PrefetchConversation")
            let page = try? await swiftDataService.fetchMessagePage(
                conversationID,
                limit: Self.messagePageSize
            )
            ConversationPerformance.signposter.endInterval(
                "PrefetchConversation",
                interval
            )

            await MainActor.run {
                self.prefetchingConversationIDs.remove(conversationID)
                guard let page, self.messageCache[conversationID] == nil else { return }
                self.cacheMessages(
                    page.messages,
                    for: conversationID,
                    hasEarlierMessages: page.hasMore
                )
            }
        }
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

    @MainActor
    private func cacheMessages(
        _ messages: [MessageSD],
        for conversationID: UUID,
        hasEarlierMessages: Bool? = nil,
        refreshedAt: Date = .now
    ) {
        let hasEarlier = hasEarlierMessages
            ?? messageCache[conversationID]?.hasEarlierMessages
            ?? false
        messageCache[conversationID] = CachedTranscript(
            messages: messages,
            hasEarlierMessages: hasEarlier,
            refreshedAt: refreshedAt
        )
        messageCacheRecency.removeAll { $0 == conversationID }
        messageCacheRecency.append(conversationID)

        while messageCacheRecency.count > messageCacheLimit {
            let evictedID = messageCacheRecency.removeFirst()
            messageCache[evictedID] = nil
        }
    }

    /// Refresh a transcript without changing the current selection. This is
    /// also used after persisting a newly-sent turn.
    func reloadConversation(_ conversation: ConversationSD) async throws {
        let displayLimit = await MainActor.run {
            max(Self.messagePageSize, self.messageCache[conversation.id]?.messages.count ?? 0)
        }
        let page = try await swiftDataService.fetchMessagePage(
            conversation.id,
            limit: displayLimit
        )
        await MainActor.run {
            self.cacheMessages(
                page.messages,
                for: conversation.id,
                hasEarlierMessages: page.hasMore
            )
            guard self.selectedConversation?.id == conversation.id else { return }
            self.messages = page.messages
            self.hasEarlierMessages = page.hasMore
        }
    }

    @MainActor
    func selectConversation(_ conversation: ConversationSD) async throws {
        let conversationID = conversation.id
        guard selectedConversation?.id != conversationID else {
            refreshStats(for: conversationID)
            return
        }

        let requestID = UUID()
        activeSelectionRequestID = requestID

        if let previous = activeSwitchInterval {
            ConversationPerformance.signposter.endInterval(
                "ConversationSwitch",
                previous.state
            )
        }
        let switchState = ConversationPerformance.signposter
            .beginInterval("ConversationSwitch")
        activeSwitchInterval = (conversationID, switchState)

        // Paint the selection immediately. A cached transcript avoids both an
        // empty flash and repeated Markdown layout when switching back.
        selectedConversation = conversation
        isLoadingEarlierMessages = false
        if let cachedTranscript = messageCache[conversationID] {
            ConversationPerformance.signposter.emitEvent("ConversationCacheHit")
            messages = cachedTranscript.messages
            hasEarlierMessages = cachedTranscript.hasEarlierMessages
            messageCacheRecency.removeAll { $0 == conversationID }
            messageCacheRecency.append(conversationID)
            refreshStats(for: conversationID)
            scheduleCachedRefreshIfNeeded(
                conversationID,
                cachedTranscript: cachedTranscript
            )
            if cachedTranscript.messages.isEmpty {
                markConversationRendered(conversationID)
            }
            // Critical fast path: let the selection task return so SwiftUI can
            // commit the cached transcript before any database refresh.
            return
        } else {
            ConversationPerformance.signposter.emitEvent("ConversationCacheMiss")
            messages = []
            hasEarlierMessages = false
        }

        let refreshLimit = max(Self.messagePageSize, messages.count)
        let fetchState = ConversationPerformance.signposter
            .beginInterval("FetchMessagePage")
        let page: MessagePage
        do {
            page = try await swiftDataService.fetchMessagePage(
                conversationID,
                limit: refreshLimit
            )
            ConversationPerformance.signposter.endInterval(
                "FetchMessagePage",
                fetchState
            )
        } catch {
            ConversationPerformance.signposter.endInterval(
                "FetchMessagePage",
                fetchState
            )
            markConversationRendered(conversationID)
            throw error
        }
        try Task.checkCancellation()
        guard activeSelectionRequestID == requestID,
              selectedConversation?.id == conversationID else { return }

        cacheMessages(
            page.messages,
            for: conversationID,
            hasEarlierMessages: page.hasMore
        )
        messages = page.messages
        hasEarlierMessages = page.hasMore
        refreshStats(for: conversationID)
        if page.messages.isEmpty {
            markConversationRendered(conversationID)
        }
    }

    /// Refresh a stale cached page without delaying selection. Rapid switching
    /// coalesces to at most one refresh per conversation.
    @MainActor
    private func scheduleCachedRefreshIfNeeded(
        _ conversationID: UUID,
        cachedTranscript: CachedTranscript
    ) {
        guard Date.now.timeIntervalSince(cachedTranscript.refreshedAt) >= Self.cacheRefreshTTL,
              !refreshingConversationIDs.contains(conversationID),
              !prefetchingConversationIDs.contains(conversationID),
              runs[conversationID] == nil else { return }

        refreshingConversationIDs.insert(conversationID)
        let displayLimit = max(Self.messagePageSize, cachedTranscript.messages.count)
        Task(priority: .utility) { [weak self] in
            await self?.refreshCachedConversation(
                conversationID,
                displayLimit: displayLimit
            )
        }
    }

    private func refreshCachedConversation(
        _ conversationID: UUID,
        displayLimit: Int
    ) async {
        let fetchState = ConversationPerformance.signposter
            .beginInterval("FetchMessagePage")
        let page = try? await swiftDataService.fetchMessagePage(
            conversationID,
            limit: displayLimit
        )
        ConversationPerformance.signposter.endInterval(
            "FetchMessagePage",
            fetchState
        )

        await MainActor.run {
            self.refreshingConversationIDs.remove(conversationID)
            guard let page,
                  let cachedTranscript = self.messageCache[conversationID] else { return }

            let changed = !self.transcriptsMatch(
                cachedTranscript.messages,
                page.messages
            )
            if changed {
                self.cacheMessages(
                    page.messages,
                    for: conversationID,
                    hasEarlierMessages: page.hasMore
                )
                if self.selectedConversation?.id == conversationID {
                    self.messages = page.messages
                    self.hasEarlierMessages = page.hasMore
                }
            } else {
                var refreshed = cachedTranscript
                refreshed.hasEarlierMessages = page.hasMore
                refreshed.refreshedAt = .now
                self.messageCache[conversationID] = refreshed
                if self.selectedConversation?.id == conversationID {
                    self.hasEarlierMessages = page.hasMore
                }
            }
        }
    }

    @MainActor
    private func transcriptsMatch(_ lhs: [MessageSD], _ rhs: [MessageSD]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { old, new in
            old.id == new.id
                && old.role == new.role
                && old.content == new.content
                && old.blocksJSON == new.blocksJSON
                && old.done == new.done
                && old.error == new.error
        }
    }

    /// Called by the message list after its first bottom positioning pass. The
    /// interval measures tap-to-first-render rather than only database latency.
    @MainActor
    func markConversationRendered(_ conversationID: UUID) {
        guard let active = activeSwitchInterval,
              active.conversationID == conversationID else { return }
        ConversationPerformance.signposter.endInterval(
            "ConversationSwitch",
            active.state
        )
        activeSwitchInterval = nil
    }

    /// Prepend one older page while leaving the newest message unchanged. The
    /// message list uses that stable tail identity to preserve scroll position.
    @MainActor
    func loadEarlierMessages() async {
        guard let conversationID = selectedConversation?.id,
              hasEarlierMessages,
              !isLoadingEarlierMessages else { return }

        isLoadingEarlierMessages = true
        let offset = messages.count
        let fetchState = ConversationPerformance.signposter
            .beginInterval("FetchEarlierMessages")
        do {
            let page = try await swiftDataService.fetchMessagePage(
                conversationID,
                offset: offset,
                limit: Self.messagePageSize
            )
            ConversationPerformance.signposter.endInterval(
                "FetchEarlierMessages",
                fetchState
            )
            guard selectedConversation?.id == conversationID else { return }

            let existingIDs = Set(messages.map(\.id))
            let olderMessages = page.messages.filter { !existingIDs.contains($0.id) }
            messages = olderMessages + messages
            hasEarlierMessages = page.hasMore
            isLoadingEarlierMessages = false
            cacheMessages(
                messages,
                for: conversationID,
                hasEarlierMessages: page.hasMore
            )
        } catch {
            ConversationPerformance.signposter.endInterval(
                "FetchEarlierMessages",
                fetchState
            )
            guard selectedConversation?.id == conversationID else { return }
            isLoadingEarlierMessages = false
        }
    }

    @MainActor
    func delete(_ conversation: ConversationSD) async throws {
        let storedMessages = (try? await swiftDataService.fetchMessages(conversation.id)) ?? []
        lastDeletedConversation = DeletedConversationSnapshot(
            id: conversation.id,
            name: conversation.name,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            isPinned: conversation.isPinned,
            isArchived: conversation.isArchived,
            workingDirectory: conversation.workingDirectory,
            piSessionPath: conversation.piSessionPath,
            planJSON: conversation.planJSON,
            goalText: conversation.goalText,
            goalStatus: conversation.goalStatus,
            goalAutoContinue: conversation.goalAutoContinue,
            goalContinuationCount: conversation.goalContinuationCount,
            model: conversation.model,
            messages: storedMessages.map {
                DeletedMessageSnapshot(
                    id: $0.id,
                    content: $0.content,
                    role: $0.role,
                    blocksJSON: $0.blocksJSON,
                    done: $0.done,
                    error: $0.error,
                    createdAt: $0.createdAt,
                    image: $0.image
                )
            }
        )
        await teardownConnector(conversation.id)
        do {
            try await swiftDataService.deleteConversation(conversation)
        } catch {
            lastDeletedConversation = nil
            throw error
        }
        let fetchedConversations = try await swiftDataService.fetchConversations()
        messageCache[conversation.id] = nil
        messageCacheRecency.removeAll { $0 == conversation.id }
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            messages = []
        }
        conversations = fetchedConversations

        deleteUndoExpiryTask?.cancel()
        deleteUndoExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.lastDeletedConversation = nil
        }
        AppStore.shared.uiLog(message: "Conversation deleted — Undo is available for 10 seconds", status: .info)
    }

    @MainActor
    func undoLastDeletion() async {
        guard let snapshot = lastDeletedConversation else { return }
        lastDeletedConversation = nil
        deleteUndoExpiryTask?.cancel()
        deleteUndoExpiryTask = nil

        let restored = ConversationSD(name: snapshot.name, updatedAt: snapshot.updatedAt)
        restored.id = snapshot.id
        restored.createdAt = snapshot.createdAt
        restored.isPinned = snapshot.isPinned
        restored.isArchived = snapshot.isArchived
        restored.workingDirectory = snapshot.workingDirectory
        restored.piSessionPath = snapshot.piSessionPath
        restored.planJSON = snapshot.planJSON
        restored.goalText = snapshot.goalText
        restored.goalStatus = snapshot.goalStatus
        restored.goalAutoContinue = snapshot.goalAutoContinue
        restored.goalContinuationCount = snapshot.goalContinuationCount
        restored.model = snapshot.model

        do {
            try await swiftDataService.createConversation(restored)
            for item in snapshot.messages {
                let message = MessageSD(
                    content: item.content,
                    role: item.role,
                    done: item.done,
                    error: item.error,
                    image: item.image
                )
                message.id = item.id
                message.blocksJSON = item.blocksJSON
                message.createdAt = item.createdAt
                message.conversation = restored
                try await swiftDataService.createMessage(message)
            }
            conversations = try await swiftDataService.fetchConversations()
            try await selectConversation(restored)
            AppStore.shared.uiLog(message: "Conversation restored", status: .info)
        } catch {
            AppStore.shared.uiLog(message: "Could not restore conversation: \(error.localizedDescription)", status: .error)
        }
    }

    /// Rename a conversation and persist it, then refresh the list so the
    /// sidebar reflects the new title immediately.
    @MainActor
    func rename(_ conversation: ConversationSD, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.name else { return }
        conversation.name = trimmed
        Task {
            try? await swiftDataService.updateConversation(conversation)
            let fetched = try? await swiftDataService.fetchConversations()
            if let fetched {
                await MainActor.run { self.conversations = fetched }
            }
        }
    }

    /// Toggle a conversation's pinned state and persist it, refreshing the list
    /// so pinned items reorder to the top of their project group.
    @MainActor
    func togglePin(_ conversation: ConversationSD) {
        conversation.isPinned.toggle()
        Task {
            try? await swiftDataService.updateConversation(conversation)
            let fetched = try? await swiftDataService.fetchConversations()
            if let fetched {
                await MainActor.run { self.conversations = fetched }
            }
        }
    }

    /// Toggle a conversation's archived state and persist it, refreshing the
    /// list so archived items move in/out of the Archived section.
    @MainActor
    func toggleArchive(_ conversation: ConversationSD) {
        conversation.isArchived.toggle()
        // Archiving a conversation also unpins it to avoid a pinned-but-hidden item.
        if conversation.isArchived { conversation.isPinned = false }
        // Archiving the open conversation clears the detail view (new-chat state).
        if conversation.isArchived, selectedConversation?.id == conversation.id {
            selectedConversation = nil
            messages = []
        }
        Task {
            try? await swiftDataService.updateConversation(conversation)
            let fetched = try? await swiftDataService.fetchConversations()
            if let fetched {
                await MainActor.run { self.conversations = fetched }
            }
        }
    }

    /// Build a concise conversation title from a prompt: first non-empty line,
    /// whitespace-collapsed, capped to a reasonable length with an ellipsis.
    static func title(from prompt: String, maxLength: Int = 60) -> String {
        let firstLine = prompt
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? prompt
        let collapsed = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= maxLength { return collapsed.isEmpty ? "New Chat" : collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One-time migration: shorten existing over-long conversation titles that
    /// predate `title(from:)`. Preserves `updatedAt` (uses renameConversation,
    /// not updateConversation) so the sidebar order doesn't get reshuffled.
    func migrateLongTitlesIfNeeded() async {
        let key = "didMigrateLongTitles_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let all = (try? await swiftDataService.fetchConversations()) ?? []
        var changed = false
        for c in all {
            let newTitle = Self.title(from: c.name)
            if newTitle != c.name {
                c.name = newTitle
                try? await swiftDataService.renameConversation(c)
                changed = true
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        if changed {
            let fetched = try? await swiftDataService.fetchConversations()
            await MainActor.run { if let fetched { self.conversations = fetched } }
        }
    }

    // MARK: - Deep links

    /// URL scheme used for `enchanted://conversation/<uuid>` deep links.
    static let deepLinkScheme = "enchanted"

    /// Deep link that opens a specific conversation.
    static func deepLink(for conversation: ConversationSD) -> String {
        "\(deepLinkScheme)://conversation/\(conversation.id.uuidString)"
    }

    static func deepLink(for conversationID: UUID, messageID: UUID) -> String {
        "\(deepLinkScheme)://conversation/\(conversationID.uuidString)#\(messageID.uuidString)"
    }

    /// Open a conversation by id (e.g. from a deep link), selecting it if found.
    @MainActor
    func openConversation(id: UUID, messageID: UUID? = nil) {
        Task {
            if let conversation = try? await swiftDataService.getConversation(id) {
                try? await selectConversation(conversation)
                if let messageID {
                    await loadAllMessagesForSearch()
                    guard messages.contains(where: { $0.id == messageID }) else {
                        AppStore.shared.uiLog(message: "The linked message is no longer available", status: .error)
                        return
                    }
                    pendingMessageFocusID = messageID
                }
            }
        }
    }

    /// Handle an incoming `enchanted://` URL. Returns true if it was recognized.
    @MainActor
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == Self.deepLinkScheme, url.host == "conversation",
              let id = UUID(uuidString: url.lastPathComponent) else {
            return false
        }
        let messageID = url.fragment.flatMap(UUID.init(uuidString:))
        openConversation(id: id, messageID: messageID)
        return true
    }

    // MARK: - Fork

    private func copyGoal(from source: ConversationSD, to destination: ConversationSD) {
        destination.goalText = source.goalText
        destination.goalStatus = source.goalStatus
        destination.goalAutoContinue = source.goalAutoContinue
        destination.goalContinuationCount = 0
    }

    /// Duplicate a conversation (transcript + pi session context) into a new
    /// conversation that runs in the same working directory.
    @MainActor
    func forkToLocal(_ conversation: ConversationSD) async {
        await fork(conversation,
                   workingDirectory: workingDirectory(for: conversation),
                   nameSuffix: "(fork)")
    }

    /// Create a new git worktree from the conversation's working directory and
    /// fork the conversation into it, so an agent can work on a parallel branch
    /// without disturbing the original checkout. Returns the worktree path.
    @MainActor
    @discardableResult
    func forkToWorktree(_ conversation: ConversationSD) async -> String? {
        let cwd = workingDirectory(for: conversation)
        let name = conversation.name
        // Run git off the main actor so `worktree add` never freezes the UI.
        let worktreePath = await Task.detached { GitWorktree.create(from: cwd, name: name) }.value
        guard let worktreePath else {
            AgentBackendConfig.debugLog("forkToWorktree: failed to create worktree from \(cwd)")
            return nil
        }
        await fork(conversation, workingDirectory: worktreePath, nameSuffix: "(worktree)")
        return worktreePath
    }

    /// Shared fork implementation: clones the pi session (when present), copies
    /// the transcript, then selects the new conversation.
    @MainActor
    private func fork(_ source: ConversationSD, workingDirectory: String, nameSuffix: String) async {
        // Clone the pi session so the fork carries the original context but
        // writes to its own independent session file.
        var newSessionPath: String? = nil
        if let sessionPath = source.piSessionPath, !sessionPath.isEmpty,
           let temp = AgentBackendConfig.makeChatBackend(
               workingDirectory: workingDirectory,
               resumeSessionPath: sessionPath) as? PiConnector {
            newSessionPath = await temp.cloneSession()
            temp.terminate()
        }

        let forked = ConversationSD(name: "\(source.name) \(nameSuffix)")
        forked.workingDirectory = workingDirectory
        forked.piSessionPath = newSessionPath
        forked.planJSON = source.planJSON
        copyGoal(from: source, to: forked)
        forked.model = source.model
        try? await swiftDataService.createConversation(forked)

        // Copy the visible transcript, preserving order via createdAt.
        let sourceMessages = (try? await swiftDataService.fetchMessages(source.id)) ?? []
        for m in sourceMessages {
            let copy = MessageSD(content: m.content, role: m.role, done: m.done, error: m.error, image: m.image)
            copy.blocksJSON = m.blocksJSON
            copy.createdAt = m.createdAt
            copy.conversation = forked
            try? await swiftDataService.createMessage(copy)
        }

        let fetched = try? await swiftDataService.fetchConversations()
        if let fetched { self.conversations = fetched }
        try? await selectConversation(forked)
    }

    /// Create an independent pi branch immediately before `target`, copy only
    /// the matching local transcript prefix, and select the new conversation.
    /// This is the safe primitive behind editing and regenerating old turns:
    /// the source conversation and its stateful pi session remain untouched.
    @MainActor
    private func forkBeforeUserMessage(
        _ target: MessageSD,
        in source: ConversationSD
    ) async -> ConversationSD? {
        let sourceMessages = (try? await swiftDataService.fetchMessages(source.id)) ?? []
        guard
            target.role == "user",
            let targetIndex = sourceMessages.firstIndex(where: { $0.id == target.id })
        else { return nil }
        guard branchingMessageIDs.insert(target.id).inserted else { return nil }
        defer { branchingMessageIDs.remove(target.id) }

        let userIndex = sourceMessages[...targetIndex]
            .filter { $0.role == "user" }
            .count - 1
        guard
            userIndex >= 0,
            let sessionPath = source.piSessionPath,
            !sessionPath.isEmpty,
            let connector = AgentBackendConfig.makeChatBackend(
                workingDirectory: workingDirectory(for: source),
                resumeSessionPath: sessionPath
            ) as? PiConnector
        else {
            AppStore.shared.uiLog(message: "Cannot fork: pi session is unavailable", status: .error)
            return nil
        }

        let newSessionPath = await connector.forkSession(
            beforeUserMessageAt: userIndex,
            expectedText: target.content
        )
        let forkError = connector.lastForkError
        connector.terminate()
        guard let newSessionPath else {
            AppStore.shared.uiLog(
                message: forkError ?? "Could not create a pi branch for this turn",
                status: .error
            )
            return nil
        }

        let forked = ConversationSD(name: "\(source.name) (fork)")
        forked.workingDirectory = workingDirectory(for: source)
        forked.piSessionPath = newSessionPath
        forked.planJSON = source.planJSON
        copyGoal(from: source, to: forked)
        forked.model = source.model
        try? await swiftDataService.createConversation(forked)

        for message in sourceMessages.prefix(upTo: targetIndex) {
            let copy = copyMessage(message, to: forked)
            try? await swiftDataService.createMessage(copy)
        }

        let fetched = try? await swiftDataService.fetchConversations()
        if let fetched { conversations = fetched }
        try? await selectConversation(forked)
        AppStore.shared.uiLog(message: "Created a new branch from the selected turn", status: .info)
        return forked
    }

    /// Fork a completed transcript at the end of the turn containing
    /// `message`. If another user turn follows we fork immediately before it;
    /// otherwise cloning the current leaf preserves the complete active branch.
    @MainActor
    func forkFromHere(_ message: MessageSD) async {
        guard let source = selectedConversation else { return }
        let sourceMessages = (try? await swiftDataService.fetchMessages(source.id)) ?? []
        guard let selectedIndex = sourceMessages.firstIndex(where: { $0.id == message.id }) else { return }
        guard branchingMessageIDs.insert(message.id).inserted else { return }
        defer { branchingMessageIDs.remove(message.id) }

        let nextUserIndex = sourceMessages.indices.first {
            $0 > selectedIndex && sourceMessages[$0].role == "user"
        }
        let prefixEnd = nextUserIndex ?? sourceMessages.endIndex
        let userIndex = nextUserIndex.map {
            sourceMessages[...$0].filter { $0.role == "user" }.count - 1
        }

        guard
            let sessionPath = source.piSessionPath,
            !sessionPath.isEmpty,
            let connector = AgentBackendConfig.makeChatBackend(
                workingDirectory: workingDirectory(for: source),
                resumeSessionPath: sessionPath
            ) as? PiConnector
        else {
            AppStore.shared.uiLog(message: "Cannot fork: pi session is unavailable", status: .error)
            return
        }

        let newSessionPath: String?
        if let userIndex, let nextUserIndex {
            newSessionPath = await connector.forkSession(
                beforeUserMessageAt: userIndex,
                expectedText: sourceMessages[nextUserIndex].content
            )
        } else {
            newSessionPath = await connector.cloneSession()
        }
        let forkError = connector.lastForkError
        connector.terminate()
        guard let newSessionPath else {
            AppStore.shared.uiLog(
                message: forkError ?? "Could not create a pi branch here",
                status: .error
            )
            return
        }

        let forked = ConversationSD(name: "\(source.name) (fork)")
        forked.workingDirectory = workingDirectory(for: source)
        forked.piSessionPath = newSessionPath
        forked.planJSON = source.planJSON
        copyGoal(from: source, to: forked)
        forked.model = source.model
        try? await swiftDataService.createConversation(forked)
        for sourceMessage in sourceMessages.prefix(upTo: prefixEnd) {
            try? await swiftDataService.createMessage(copyMessage(sourceMessage, to: forked))
        }
        if let fetched = try? await swiftDataService.fetchConversations() { conversations = fetched }
        try? await selectConversation(forked)
        AppStore.shared.uiLog(message: "Created a new branch here", status: .info)
    }

    /// Regenerate the response to a user turn in a new conversation branch.
    @MainActor
    func regenerateResponse(after userMessage: MessageSD) async {
        guard
            let source = selectedConversation,
            let model = source.model,
            await forkBeforeUserMessage(userMessage, in: source) != nil
        else { return }

        let images: [Image] = userMessage.imageItems.compactMap { data in
#if os(macOS)
            guard let image = NSImage(data: data) else { return nil }
            return Image(nsImage: image)
#elseif os(iOS) || os(visionOS)
            guard let image = UIImage(data: data) else { return nil }
            return Image(uiImage: image)
#else
            return nil
#endif
        }
        sendPrompt(userPrompt: userMessage.content, model: model, images: images)
    }

    private func copyMessage(_ source: MessageSD, to conversation: ConversationSD) -> MessageSD {
        let copy = MessageSD(
            content: source.content,
            role: source.role,
            done: source.done,
            error: source.error,
            image: source.image
        )
        copy.blocksJSON = source.blocksJSON
        copy.createdAt = source.createdAt
        copy.conversation = conversation
        return copy
    }

    // MARK: - Project-level operations

    /// Archive every non-archived conversation in a project (working directory).
    @MainActor
    func archiveProject(path: String) {
        let targets = conversations.filter {
            !$0.isArchived && ($0.workingDirectory ?? WorkspaceStore.shared.currentDirectory) == path
        }
        guard !targets.isEmpty else { return }
        for conversation in targets {
            conversation.isArchived = true
            conversation.isPinned = false
            if selectedConversation?.id == conversation.id {
                selectedConversation = nil
                messages = []
            }
        }
        Task {
            for conversation in targets {
                try? await swiftDataService.updateConversation(conversation)
            }
            let fetched = try? await swiftDataService.fetchConversations()
            if let fetched { await MainActor.run { self.conversations = fetched } }
        }
    }

    /// Remove a project: delete all its conversations and forget its metadata.
    @MainActor
    func deleteProject(path: String) {
        let targets = conversations.filter {
            ($0.workingDirectory ?? WorkspaceStore.shared.currentDirectory) == path
        }
        ProjectStore.shared.forget(path)
        guard !targets.isEmpty else { return }
        if let selected = selectedConversation,
           targets.contains(where: { $0.id == selected.id }) {
            selectedConversation = nil
            messages = []
        }
        Task {
            for conversation in targets {
                await teardownConnector(conversation.id)
                try? await swiftDataService.deleteConversation(conversation)
            }
            let fetched = try? await swiftDataService.fetchConversations()
            if let fetched { await MainActor.run { self.conversations = fetched } }
        }
    }

    /// Create a permanent git worktree from a project's directory. Returns the
    /// new worktree path so the caller can start a chat there. Unlike
    /// `forkToWorktree`, this doesn't copy any conversation — it just spins up a
    /// fresh parallel checkout the user can adopt as its own project.
    @MainActor
    @discardableResult
    func createPermanentWorktree(from path: String) async -> String? {
        let name = ProjectStore.shared.displayName(for: path)
        let worktreePath = await Task.detached { GitWorktree.create(from: path, name: name) }.value
        if worktreePath == nil {
            AgentBackendConfig.debugLog("createPermanentWorktree: failed for \(path)")
        }
        return worktreePath
    }

    /// Start a dedicated, read-only review task for the selected project's
    /// uncommitted changes. Keeping it in a separate conversation mirrors
    /// Codex review workflow and avoids mixing findings into an implementation
    /// thread's stateful pi context.
    @MainActor
    func startCodeReview() {
        guard let source = selectedConversation,
              runs[source.id] == nil,
              let model = source.model ?? LanguageModelStore.shared.selectedModel else { return }
        let review = ConversationSD(name: "Review: \(source.name)")
        review.workingDirectory = workingDirectory(for: source)
        review.model = model
        let prompt = """
        Review the current uncommitted changes in this Git working tree. This is a read-only review: do not edit files, run formatters, stage changes, or create commits. Inspect both staged and unstaged changes and relevant surrounding code. Report only actionable correctness, security, regression, or test-coverage findings, ordered by severity. For every finding include an exact file path and line number. If there are no actionable findings, say so clearly.
        """
        beginPrompt(
            userPrompt: prompt,
            model: model,
            images: [],
            systemPrompt: "",
            conversation: review,
            isNewConversation: true
        )
    }

    /// Launch a schedule as a normal visible conversation. Scheduled work uses
    /// the same permission cards, notifications and interrupted-run recovery as
    /// an ordinary task instead of bypassing the app's safety boundary.
    @MainActor
    func startScheduledTask(_ task: ScheduledTaskSD) -> UUID? {
        let model = LanguageModelStore.shared.models.first(where: { $0.name == task.modelName })
            ?? LanguageModelStore.shared.selectedModel
        guard let model else {
            AppStore.shared.uiLog(message: "Scheduled task skipped: no model is available", status: .error)
            return nil
        }
        let conversation = ConversationSD(name: "Scheduled: \(task.name)")
        conversation.workingDirectory = task.workingDirectory
        conversation.model = model
        conversation.scheduledTaskID = task.id
        beginPrompt(
            userPrompt: task.prompt,
            model: model,
            images: [],
            systemPrompt: UserDefaults.standard.string(forKey: "systemPrompt") ?? "",
            conversation: conversation,
            isNewConversation: true
        )
        return conversation.id
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
        connectorGenerations[conversation.id] = nil
    }

    /// Invalidate all per-conversation agent processes after a Settings change.
    /// Idle connectors are reclaimed immediately. Running turns are deliberately
    /// left alone and become stale, so `connector(for:)` replaces them safely on
    /// the next send.
    @MainActor
    func invalidateAgentBackends() {
        backendConfigurationGeneration += 1
        let idleIDs = connectors.keys.filter { runs[$0] == nil }
        for id in idleIDs {
            (connectors[id] as? PiConnector)?.terminate()
            connectors[id] = nil
            connectorGenerations[id] = nil
            stats[id] = nil
            lastActivity[id] = nil
        }
    }

    @MainActor
    private func connector(for conversation: ConversationSD) -> AgentBackend {
        lastActivity[conversation.id] = .now
        if let existing = connectors[conversation.id],
           connectorGenerations[conversation.id] == backendConfigurationGeneration {
            return existing
        }
        if let stale = connectors[conversation.id] as? PiConnector {
            stale.terminate()
        }
        let cwd = workingDirectory(for: conversation)
        let backend = AgentBackendConfig.makeChatBackend(
            workingDirectory: cwd,
            resumeSessionPath: conversation.piSessionPath
        )
        connectors[conversation.id] = backend
        connectorGenerations[conversation.id] = backendConfigurationGeneration
        return backend
    }

    // MARK: - Idle reclamation

    /// Start a periodic sweep that terminates pi processes for conversations
    /// that have been idle too long. Safe to call more than once (no-ops after
    /// the first). Context is restored on next use via `switch_session`.
    @MainActor
    func startIdleReaper() {
        guard !idleReaperStarted, idleTimeout > 0 else { return }
        idleReaperStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.reapIdleConnectors()
            }
        }
    }

    @MainActor
    private func reapIdleConnectors() {
        let now = Date()
        for (id, backend) in connectors {
            guard let connector = backend as? PiConnector else { continue }
            // Never reap a conversation with a live run.
            if runs[id] != nil { continue }
            // Only reap if context can be restored next time (needs a session file).
            guard
                let conv = conversations.first(where: { $0.id == id }),
                conv.piSessionPath != nil
            else { continue }
            let last = lastActivity[id] ?? .distantPast
            guard now.timeIntervalSince(last) > idleTimeout else { continue }
            connector.terminate()
            connectors[id] = nil
            connectorGenerations[id] = nil
            stats[id] = nil
            lastActivity[id] = nil
            AgentBackendConfig.debugLog("reapIdleConnectors: terminated idle pi for conversation \(id)")
        }
    }

    private func teardownConnector(_ id: UUID) async {
        await MainActor.run {
            runs[id]?.cancellable?.cancel()
            runs[id] = nil
            (connectors[id] as? PiConnector)?.terminate()
            connectors[id] = nil
            connectorGenerations[id] = nil
            states[id] = nil
        }
    }

    // MARK: - Generation control

    @MainActor func stopGenerate() {
        guard let id = selectedConversation?.id else { return }
        // Tell pi to actually stop generating, then drop the local subscription.
        (connectors[id] as? PiConnector)?.abort()
        runs[id]?.cancellable?.cancel()
        followUps[id] = []
        finishRun(id, notify: false)
    }

    @MainActor
    func sendPrompt(userPrompt: String, model: LanguageModelSD, image: Image? = nil, systemPrompt: String = "", trimmingMessageId: String? = nil) {
        sendPrompt(
            userPrompt: userPrompt,
            model: model,
            images: image.map { [$0] } ?? [],
            systemPrompt: systemPrompt,
            trimmingMessageId: trimmingMessageId
        )
    }

    @MainActor
    func sendPrompt(userPrompt: String, model: LanguageModelSD, images: [Image], systemPrompt: String = "", trimmingMessageId: String? = nil) {
        guard userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

#if os(macOS)
        if selectedConversation == nil,
           UserDefaults.standard.string(forKey: "newTaskEnvironment") == "worktree" {
            guard !isPreparingNewTaskEnvironment else { return }
            isPreparingNewTaskEnvironment = true
            let base = WorkspaceStore.shared.currentDirectory
            let name = Self.title(from: userPrompt)
            Task { @MainActor in
                let path = await Task.detached { GitWorktree.create(from: base, name: name) }.value
                isPreparingNewTaskEnvironment = false
                guard let path else {
                    AppStore.shared.uiLog(
                        message: "Could not create a worktree. The selected folder must be inside a Git repository.",
                        status: .error
                    )
                    return
                }
                let conversation = ConversationSD(name: name)
                conversation.workingDirectory = path
                beginPrompt(
                    userPrompt: userPrompt,
                    model: model,
                    images: images,
                    systemPrompt: systemPrompt,
                    conversation: conversation,
                    isNewConversation: true
                )
            }
            return
        }
#endif

        // Editing an old turn must also rewind pi's stateful transcript. Route
        // it through a real session fork instead of trimming SwiftData only.
        if let trimmingMessageId,
           let source = selectedConversation {
            Task { @MainActor in
                let allMessages = (try? await swiftDataService.fetchMessages(source.id)) ?? []
                guard
                    let target = allMessages.first(where: { $0.id.uuidString == trimmingMessageId }),
                    await forkBeforeUserMessage(target, in: source) != nil
                else { return }
                sendPrompt(
                    userPrompt: userPrompt,
                    model: model,
                    images: images,
                    systemPrompt: systemPrompt,
                    trimmingMessageId: nil
                )
            }
            return
        }

        beginPrompt(
            userPrompt: userPrompt,
            model: model,
            images: images,
            systemPrompt: systemPrompt,
            conversation: selectedConversation
        )
    }

    @MainActor
    private func beginPrompt(
        userPrompt: String,
        model: LanguageModelSD,
        images: [Image],
        systemPrompt: String,
        conversation existingConversation: ConversationSD?,
        isNewConversation explicitIsNewConversation: Bool? = nil
    ) {
        guard userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

        let renderedImages = images.compactMap { $0.render() }

        let isNewConversation = explicitIsNewConversation ?? (existingConversation == nil)
        let conversation = existingConversation ?? ConversationSD(name: Self.title(from: userPrompt))
        conversation.updatedAt = Date.now
        conversation.model = model
        // New conversation inherits the current default working directory.
        if conversation.workingDirectory == nil {
            conversation.workingDirectory = WorkspaceStore.shared.currentDirectory
        }

        /// add system prompt to very first message in the conversation
        if !systemPrompt.isEmpty && conversation.messages.isEmpty {
            let systemMessage = MessageSD(content: systemPrompt, role: "system")
            systemMessage.conversation = conversation
        }

        /// construct new user message
        let storedImageData = renderedImages.compactMap { $0.compressImageData() }
        let userMessage = MessageSD(
            content: userPrompt,
            role: "user",
            image: MessageSD.storeImages(storedImageData)
        )
        userMessage.conversation = conversation

        /// prepare neutral message history for the active backend
        var messageHistory = conversation.messages
            .sorted{$0.createdAt < $1.createdAt}
            .map{AgentChatMessage(role: AgentChatMessage.Role(rawValue: $0.role) ?? .assistant, content: $0.content)}

        /// attach selected image to the last message
        if !renderedImages.isEmpty {
            if let lastMessage = messageHistory.popLast() {
                let imagesBase64 = renderedImages
                    .map { $0.convertImageToBase64String() }
                    .filter { !$0.isEmpty }
                messageHistory.append(AgentChatMessage(role: lastMessage.role, content: lastMessage.content, imagesBase64: imagesBase64))
            }
        }

        let assistantMessage = MessageSD(content: "", role: "assistant")
        assistantMessage.conversation = conversation

        // Do not wait for persistence + a refetch before showing a newly sent
        // turn. Keep the currently-loaded page instead of touching the full
        // relationship, then let the later paged reload reconcile SwiftData.
        if isNewConversation || selectedConversation?.id == conversation.id {
            selectedConversation = conversation
            var visibleMessages = isNewConversation ? [] : messages
            visibleMessages.append(userMessage)
            visibleMessages.append(assistantMessage)
            messages = visibleMessages
            if isNewConversation { hasEarlierMessages = false }
            cacheMessages(
                messages,
                for: conversation.id,
                hasEarlierMessages: isNewConversation ? false : hasEarlierMessages
            )
        } else {
            var cached = messageCache[conversation.id]?.messages ?? []
            cached.append(userMessage)
            cached.append(assistantMessage)
            cacheMessages(cached, for: conversation.id)
        }

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

            // Persist the session identity before submitting the prompt. If the
            // app exits during this very first turn, startup recovery can still
            // reopen the correct pi transcript.
            if let connector = backend as? PiConnector {
                await persistSessionPath(for: conversation, using: connector)
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

        case .queueUpdate:
            // Steering updates remain pi-owned. UI follow-ups are deliberately
            // client-owned so individual items can be reordered or removed.
            break

        case .queuedTurnStarted(let text):
            run.flush()
            run.assistantMessage.done = true
            let previousAssistant = run.assistantMessage
            guard let conversation = selectedConversation?.id == convID
                    ? selectedConversation
                    : conversations.first(where: { $0.id == convID }) else { return }
            let userMessage = MessageSD(content: text, role: "user", done: true)
            userMessage.conversation = conversation
            let assistantMessage = MessageSD(content: "", role: "assistant")
            assistantMessage.createdAt = userMessage.createdAt.addingTimeInterval(0.001)
            assistantMessage.conversation = conversation
            run.beginAssistantMessage(assistantMessage)
            if selectedConversation?.id == convID {
                messages.append(userMessage)
                messages.append(assistantMessage)
                cacheMessages(messages, for: convID, hasEarlierMessages: hasEarlierMessages)
            }
            Task(priority: .background) {
                try? await self.swiftDataService.updateMessage(previousAssistant)
                try? await self.swiftDataService.createMessage(userMessage)
                try? await self.swiftDataService.createMessage(assistantMessage)
            }

        case .compactionStarted(let reason):
            showCompactionStarted(reason: reason, conversationID: convID)

        case .compactionFinished(let reason, let tokensBefore, let estimatedTokensAfter, let error):
            showCompactionFinished(
                reason: reason,
                tokensBefore: tokensBefore,
                estimatedTokensAfter: estimatedTokensAfter,
                error: error,
                conversationID: convID
            )

        case .uiRequest(let request):
            if request.method == "notify" {
                AppStore.shared.uiLog(message: request.title, status: .info)
            } else {
                uiRequests[convID, default: []].append(request)
            }

        case .planUpdate(let explanation, let items):
            guard let conversation = selectedConversation?.id == convID
                    ? selectedConversation
                    : conversations.first(where: { $0.id == convID }),
                  let data = try? JSONEncoder().encode(
                    AgentPlanSnapshot(explanation: explanation, items: items)
                  ),
                  let json = String(data: data, encoding: .utf8) else { break }
            conversation.planJSON = json
            Task(priority: .background) {
                try? await self.swiftDataService.updateConversation(conversation)
            }

        case .done:
            run.flush()
        }
    }

    @MainActor
    private func showCompactionStarted(reason: String, conversationID: UUID) {
        guard compactionStatusMessages[conversationID] == nil,
              let conversation = (selectedConversation?.id == conversationID
                  ? selectedConversation
                  : conversations.first(where: { $0.id == conversationID })) else { return }
        let label = reason == "manual"
            ? String(localized: "Compacting context…")
            : String(localized: "Automatically compacting context…")
        let message = MessageSD(content: label, role: "status", done: true)
        message.conversation = conversation
        compactionStatusMessages[conversationID] = message
        if selectedConversation?.id == conversationID {
            messages.append(message)
            cacheMessages(messages, for: conversationID, hasEarlierMessages: hasEarlierMessages)
        }
        Task(priority: .background) { try? await self.swiftDataService.createMessage(message) }
    }

    @MainActor
    private func showCompactionFinished(
        reason: String,
        tokensBefore: Int?,
        estimatedTokensAfter: Int?,
        error: String?,
        conversationID: UUID
    ) {
        if compactionStatusMessages[conversationID] == nil {
            showCompactionStarted(reason: reason, conversationID: conversationID)
        }
        guard let message = compactionStatusMessages.removeValue(forKey: conversationID) else { return }
        if let error {
            message.content = String(localized: "Context compaction failed: \(error)")
            message.error = true
        } else if let tokensBefore, let estimatedTokensAfter {
            message.content = String(localized: "Context compacted · \(Self.shortTokenCount(tokensBefore)) → ~\(Self.shortTokenCount(estimatedTokensAfter)) tokens")
        } else {
            message.content = String(localized: "Context compacted")
        }
        if selectedConversation?.id == conversationID {
            cacheMessages(messages, for: conversationID, hasEarlierMessages: hasEarlierMessages)
        }
        Task(priority: .background) { try? await self.swiftDataService.updateMessage(message) }
        refreshStats(for: conversationID)
    }

    @MainActor
    private func handleError(_ errorMessage: String, convID: UUID) {
        if let message = runs[convID]?.assistantMessage {
            message.error = true
            message.done = false
            Task(priority: .background) { try? await self.swiftDataService.updateMessage(message) }
        }
        runs[convID] = nil
        uiRequests[convID] = []
        withAnimation { states[convID] = .error(message: errorMessage) }
        let title = conversationTitle(for: convID)
        AppStore.shared.uiLog(message: "\(title) failed: \(errorMessage)", status: .error)
        NotificationService.shared.notifyConversationFinished(conversationID: convID, title: title, failed: true)
        ScheduledTaskStore.shared.recordCompletion(conversationID: convID, failed: true)
    }

    @MainActor
    private func handleComplete(_ convID: UUID) {
        finishRun(convID)
    }

    @MainActor
    private func finishRun(_ convID: UUID, notify: Bool = true) {
        if let run = runs[convID] {
            run.flush()
            let message = run.assistantMessage
            message.error = false
            message.done = true
            Task(priority: .background) { try? await self.swiftDataService.updateMessage(message) }
        }
        runs[convID] = nil
        lastActivity[convID] = .now
        withAnimation { states[convID] = .completed }
        persistSessionPath(convID)
        refreshStats(for: convID)
        if dispatchNextFollowUp(for: convID) {
            return
        }
        if dispatchGoalContinuation(for: convID) {
            return
        }
        Task { @MainActor [weak self] in
            guard self?.selectedConversation?.id == convID else { return }
            await self?.checkSelectedHistorySync(notify: false)
        }

        if notify {
            let title = conversationTitle(for: convID)
            AppStore.shared.uiLog(message: "\(title) completed", status: .info)
            NotificationService.shared.notifyConversationFinished(conversationID: convID, title: title, failed: false)
            ScheduledTaskStore.shared.recordCompletion(conversationID: convID, failed: false)
        }
    }

    @MainActor
    @discardableResult
    private func dispatchNextFollowUp(for convID: UUID) -> Bool {
        guard let item = followUps[convID]?.first,
              let conversation = (selectedConversation?.id == convID
                  ? selectedConversation
                  : conversations.first(where: { $0.id == convID })),
              let model = conversation.model ?? LanguageModelStore.shared.selectedModel else {
            return false
        }
        followUps[convID]?.removeFirst()
        if followUps[convID]?.isEmpty == true { followUps[convID] = [] }
        let images = item.imageData.compactMap(Image.init(data:))
        beginPrompt(
            userPrompt: item.text,
            model: model,
            images: images,
            systemPrompt: UserDefaults.standard.string(forKey: "systemPrompt") ?? "",
            conversation: conversation
        )
        return true
    }

    /// Continue a pinned long-running objective only when the agent has
    /// published a structured plan with unfinished work. The hard cap keeps a
    /// bad plan or model loop from running forever without renewed consent.
    @MainActor
    @discardableResult
    private func dispatchGoalContinuation(for convID: UUID) -> Bool {
        guard let conversation = (selectedConversation?.id == convID
                  ? selectedConversation
                  : conversations.first(where: { $0.id == convID })),
              conversation.goalStatus == "active",
              conversation.goalAutoContinue,
              let goal = conversation.goalText,
              !goal.isEmpty,
              let json = conversation.planJSON,
              let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AgentPlanSnapshot.self, from: data),
              !plan.items.isEmpty else { return false }

        if plan.items.allSatisfy({ $0.status == "completed" }) {
            conversation.goalStatus = "completed"
            persistGoalState(conversation)
            AppStore.shared.uiLog(message: "Long-running goal completed", status: .info)
            return false
        }

        guard conversation.goalContinuationCount < 12 else {
            conversation.goalStatus = "paused"
            persistGoalState(conversation)
            AppStore.shared.uiLog(
                message: "Long-running goal paused after 12 automatic continuations",
                status: .info
            )
            return false
        }
        guard let model = conversation.model ?? LanguageModelStore.shared.selectedModel else {
            return false
        }

        conversation.goalContinuationCount += 1
        persistGoalState(conversation)
        beginPrompt(
            userPrompt: "Continue working autonomously toward this pinned goal: \(goal). Use update_plan to keep progress current, and only mark every step completed when the goal is genuinely finished.",
            model: model,
            images: [],
            systemPrompt: UserDefaults.standard.string(forKey: "systemPrompt") ?? "",
            conversation: conversation
        )
        return true
    }

    @MainActor
    private func conversationTitle(for convID: UUID) -> String {
        if let conversation = conversations.first(where: { $0.id == convID }) {
            return conversation.name
        }
        if selectedConversation?.id == convID, let name = selectedConversation?.name {
            return name
        }
        return String(localized: "Conversation")
    }

    /// After a turn, capture pi's session file path so the conversation can be
    /// resumed (context restored) after a restart.
    @MainActor
    private func persistSessionPath(_ convID: UUID) {
        guard
            let connector = connectors[convID] as? PiConnector,
            let conversation = conversations.first(where: { $0.id == convID })
        else { return }
        Task {
            await persistSessionPath(for: conversation, using: connector)
        }
    }

    private func persistSessionPath(
        for conversation: ConversationSD,
        using connector: PiConnector
    ) async {
        let alreadyPersisted = await MainActor.run {
            !(conversation.piSessionPath?.isEmpty ?? true)
        }
        guard !alreadyPersisted,
              let path = await connector.currentSessionPath(),
              !path.isEmpty else { return }

        let shouldSave = await MainActor.run {
            guard conversation.piSessionPath?.isEmpty ?? true else { return false }
            conversation.piSessionPath = path
            return true
        }
        if shouldSave {
            try? await swiftDataService.updateConversation(conversation)
        }
    }
}

// MARK: - Scheduled task orchestration

@MainActor
@Observable
final class ScheduledTaskStore {
    static let shared = ScheduledTaskStore()

    private let service = SwiftDataService.shared
    private var schedulerTask: Task<Void, Never>?
    private(set) var tasks: [ScheduledTaskSD] = []
    private(set) var isLoaded = false

    func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled {
                await self?.processDueTasks()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func reload() async {
        tasks = (try? await service.fetchScheduledTasks()) ?? []
        isLoaded = true
    }

    func create(
        name: String,
        prompt: String,
        workingDirectory: String,
        modelName: String?,
        intervalSeconds: Double,
        nextRunAt: Date,
        missedPolicy: String
    ) async {
        let task = ScheduledTaskSD(
            name: name,
            prompt: prompt,
            workingDirectory: workingDirectory,
            modelName: modelName,
            intervalSeconds: max(300, intervalSeconds),
            nextRunAt: nextRunAt,
            missedPolicy: missedPolicy
        )
        try? await service.createScheduledTask(task)
        await reload()
    }

    func save(_ task: ScheduledTaskSD) async {
        task.intervalSeconds = max(300, task.intervalSeconds)
        try? await service.updateScheduledTask(task)
        await reload()
    }

    func delete(_ task: ScheduledTaskSD) async {
        try? await service.deleteScheduledTask(task)
        await reload()
    }

    func runNow(_ task: ScheduledTaskSD) async {
        launch(task, status: "manual")
        advanceNextRun(task, from: .now)
        try? await service.updateScheduledTask(task)
        await reload()
    }

    func history(for task: ScheduledTaskSD) -> [ScheduledTaskRunRecord] {
        guard let json = task.runHistoryJSON,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTaskRunRecord].self, from: data)) ?? []
    }

    func recordCompletion(conversationID: UUID, failed: Bool) {
        guard let task = tasks.first(where: { task in
            history(for: task).contains { $0.conversationID == conversationID }
        }) else { return }
        var records = history(for: task)
        guard let index = records.firstIndex(where: { $0.conversationID == conversationID }),
              records[index].status != "completed",
              records[index].status != "failed" else { return }
        records[index].status = failed ? "failed" : "completed"
        if let data = try? JSONEncoder().encode(records) {
            task.runHistoryJSON = String(data: data, encoding: .utf8)
            Task { try? await service.updateScheduledTask(task) }
        }
    }

    private func processDueTasks() async {
        let now = Date.now
        for task in tasks where task.isEnabled && task.nextRunAt <= now {
            let isMissed = now.timeIntervalSince(task.nextRunAt) > 60
            if isMissed && task.missedPolicy == "skip" {
                appendHistory(to: task, status: "skipped", conversationID: nil)
            } else {
                launch(task, status: isMissed ? "missed_run" : "scheduled")
            }
            advanceNextRun(task, from: now)
            try? await service.updateScheduledTask(task)
        }
        tasks.sort { $0.nextRunAt < $1.nextRunAt }
    }

    private func launch(_ task: ScheduledTaskSD, status: String) {
        task.lastRunAt = .now
        let conversationID = ConversationStore.shared.startScheduledTask(task)
        appendHistory(
            to: task,
            status: conversationID == nil ? "failed_no_model" : status,
            conversationID: conversationID
        )
        if conversationID != nil {
            AppStore.shared.uiLog(message: "Scheduled task launched: \(task.name)", status: .info)
        }
    }

    private func appendHistory(
        to task: ScheduledTaskSD,
        status: String,
        conversationID: UUID?
    ) {
        var records = history(for: task)
        records.insert(
            ScheduledTaskRunRecord(
                id: UUID(),
                launchedAt: .now,
                status: status,
                conversationID: conversationID
            ),
            at: 0
        )
        records = Array(records.prefix(50))
        if let data = try? JSONEncoder().encode(records) {
            task.runHistoryJSON = String(data: data, encoding: .utf8)
        }
    }

    private func advanceNextRun(_ task: ScheduledTaskSD, from now: Date) {
        let interval = max(300, task.intervalSeconds)
        repeat {
            task.nextRunAt = task.nextRunAt.addingTimeInterval(interval)
        } while task.nextRunAt <= now
    }
}
