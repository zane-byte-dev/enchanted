//
//  MessageListVIew.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

struct MessageListView: View {
    private static let bottomAnchorID = "bottomAnchor"
    private static let initialRenderWindow = 30
    private static let renderWindowStep = 30
    var conversationID: UUID?
    var messages: [MessageSD]
    var conversationState: ConversationState
    var userInitials: String
    @Binding var editMessage: MessageSD?
    @State private var messageSelected: MessageSD?
    @State private var conversationStore = ConversationStore.shared
    @State private var visibleMessageLimit = Self.initialRenderWindow
    @State private var hoveredTurnID: UUID?
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared

    private var contentBackground: Color {
        CodexTheme.appBackground
    }

    private var displayedMessages: ArraySlice<MessageSD> {
        messages.suffix(visibleMessageLimit)
    }

    private var hiddenLoadedMessageCount: Int {
        max(0, messages.count - displayedMessages.count)
    }

    private var canShowEarlierMessages: Bool {
        hiddenLoadedMessageCount > 0 || conversationStore.hasEarlierMessages
    }

#if os(macOS)
    fileprivate struct TurnPreview: Identifiable {
        let id: UUID
        let userMessage: MessageSD
        let response: MessageSD?
    }

    /// A turn starts with a user message and includes the first response before
    /// the next user message. Keeping this derived from the already-rendered
    /// window means the navigator never forces older SwiftData pages to mount.
    private var turnPreviews: [TurnPreview] {
        let visible = Array(displayedMessages)
        return visible.indices.compactMap { index in
            let message = visible[index]
            guard message.role == "user" else { return nil }
            let response = visible[(index + 1)...]
                .prefix { $0.role != "user" }
                .first
            return TurnPreview(id: message.id, userMessage: message, response: response)
        }
    }
#endif

    func onEditMessageTap() -> (MessageSD) -> Void {
        return { message in
            editMessage = message
        }
    }
    
    func onReadAloud(_ message: String) {
        Task {
            await speechSynthesizer.speak(text: message)
        }
    }
    
    func stopReadingAloud() {
        Task {
            await speechSynthesizer.stopSpeaking()
        }
    }

    /// Pin to the stable bottom marker once on the next runloop, after SwiftUI
    /// has installed the newly-selected transcript.
    private func pinToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            if let conversationID, !messages.isEmpty {
                conversationStore.markConversationRendered(conversationID)
            }
        }
    }

    private func showEarlierMessages() {
        if hiddenLoadedMessageCount > 0 {
            visibleMessageLimit += Self.renderWindowStep
            return
        }

        Task {
            let previousCount = messages.count
            await conversationStore.loadEarlierMessages()
            let loadedCount = max(0, conversationStore.messages.count - previousCount)
            if loadedCount > 0 {
                visibleMessageLimit += min(Self.renderWindowStep, loadedCount)
            }
        }
    }

    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { scrollViewProxy in
                GeometryReader { geo in
                ScrollView {
                    // Keep eager layout for reliable Markdown measurement, but
                    // mount only a small tail window even when older database
                    // pages are already cached.
                    VStack(spacing: 0) {
                        VStack {
                        if canShowEarlierMessages {
                            Button(action: showEarlierMessages) {
                                HStack(spacing: 7) {
                                    if conversationStore.isLoadingEarlierMessages {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "clock.arrow.circlepath")
                                    }
                                    Text("Show earlier messages")
                                }
                                .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                            .disabled(conversationStore.isLoadingEarlierMessages)
                        }
                        Group {
                        ForEach(displayedMessages) { message in
                            let contextMenu = ContextMenu(menuItems: {
                                Button(action: {Clipboard.shared.setString(message.content)}) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                
#if os(iOS) || os(visionOS)
                                Button(action: { messageSelected = message }) {
                                    Label("Select Text", systemImage: "selection.pin.in.out")
                                }
                                
                                Button(action: {
                                    onReadAloud(message.content)
                                }) {
                                    Label("Read Aloud", systemImage: "speaker.wave.3.fill")
                                }
#endif
                                
                                if message.role == "user" {
                                    Button(action: {
                                        withAnimation { editMessage = message }
                                    }) {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                }
                                
                                if editMessage?.id == message.id {
                                    Button(action: {
                                        withAnimation { editMessage = nil }
                                    }) {
                                        Label("Unselect", systemImage: "pencil")
                                    }
                                }
                            })
                            
                            ChatMessageView(
                                message: message,
                                showLoader: conversationState == .loading && messages.last == message,
                                userInitials: userInitials,
                                editMessage: $editMessage
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                            .contextMenu(contextMenu)
                            .runningBorder(animated: message.id == editMessage?.id)
                            .id(message.id)
                        }
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        }
                        // Pin content to the top when it doesn't fill the
                        // viewport (short conversations), so it starts under the
                        // header rather than being pushed down by
                        // `defaultScrollAnchor`. The spacer collapses once the
                        // content is tall enough to scroll and stick to bottom.
                        Spacer(minLength: 0)
                        // Stable zero-height bottom marker. We always scroll to
                        // this instead of the growing last message, which keeps
                        // streaming follow smooth (no jitter).
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                // Native chat-style "stick to bottom" behaviour: the scroll
                // view starts at the bottom and stays pinned there as content
                // is added, without needing to lay out/measure every row in
                // between (which is what made manual `scrollTo` calls slow or
                // land short on long conversations — the exact "blank until I
                // scroll" symptom). Requires macOS 14 / iOS 17, which is
                // already our deployment target.
                .defaultScrollAnchor(.bottom)
                // Cover the initial mount, where no tail-id change is emitted.
                // The helper performs one next-runloop positioning pass.
                .onAppear {
                    pinToBottom(scrollViewProxy)
                }
                // A changed tail means a conversation was loaded or a new turn
                // was appended. Prepending an older page keeps the same tail,
                // so it deliberately does not jump the reader back to bottom.
                .onChange(of: messages.last?.id) {
                    pinToBottom(scrollViewProxy)
                }
                // Follow the stream as the last message grows.
                .onChange(of: messages.last?.content) {
                    scrollViewProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: conversationID) {
                    visibleMessageLimit = Self.initialRenderWindow
                    hoveredTurnID = nil
                }
#if os(macOS)
                .overlay(alignment: .leading) {
                    if turnPreviews.count > 1 {
                        TurnNavigatorRail(
                            turns: turnPreviews,
                            hoveredTurnID: $hoveredTurnID,
                            onSelect: { turn in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scrollViewProxy.scrollTo(turn.userMessage.id, anchor: .top)
                                }
                            }
                        )
                        .padding(.leading, 18)
                    }
                }
#endif
#if os(iOS) || os(visionOS)
                .sheet(item: $messageSelected) { message in
                    SelectTextSheet(message: message)
                }
#endif
                }
            }
            
            ReadingAloudView(onStopTap: stopReadingAloud)
                .frame(maxWidth: 400)
                .showIf(speechSynthesizer.isSpeaking)
                .transition(.asymmetric(
                    insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.7, anchor: .top)),
                    removal: AnyTransition.opacity.combined(with: .scale(scale: 0.7, anchor: .top)))
                )
        }
        .background(contentBackground)
    }
}

#if os(macOS)
private struct TurnNavigatorRail: View {
    let turns: [MessageListView.TurnPreview]
    @Binding var hoveredTurnID: UUID?
    let onSelect: (MessageListView.TurnPreview) -> Void

    private var hoveredTurn: MessageListView.TurnPreview? {
        turns.first { $0.id == hoveredTurnID }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(turns) { turn in
                    Button {
                        onSelect(turn)
                    } label: {
                        Capsule(style: .continuous)
                            .fill(turn.id == hoveredTurnID ? Color.primary : CodexTheme.border)
                            .frame(width: turn.id == hoveredTurnID ? 38 : 12, height: 3)
                            .frame(width: 42, height: 8, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Hovering a marker must not move keyboard focus away from
                    // the composer or change a keyboard-selected menu item.
                    .focusable(false)
                    .onHover { hovering in
                        if hovering {
                            hoveredTurnID = turn.id
                        } else if hoveredTurnID == turn.id {
                            hoveredTurnID = nil
                        }
                    }
                    .accessibilityLabel("Jump to: \(turn.userMessage.content)")
                }
            }
            .padding(.vertical, 10)

            if let hoveredTurn {
                TurnPreviewCard(turn: hoveredTurn)
                    .offset(x: 70)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredTurnID)
        .frame(maxHeight: 360)
    }
}

private struct TurnPreviewCard: View {
    let turn: MessageListView.TurnPreview

    private func summary(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary(turn.userMessage.content, limit: 72))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CodexTheme.primaryText)
                .lineLimit(2)

            if let response = turn.response {
                Text(summary(response.realContent ?? response.content, limit: 150))
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.mutedText)
                    .lineLimit(3)
            } else {
                Text("等待回复…")
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.faintText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CodexTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CodexTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.13), radius: 22, x: 0, y: 10)
    }
}
#endif

#Preview {
    MessageListView(
        conversationID: nil,
        messages: MessageSD.sample,
        conversationState: .loading,
        userInitials: "AM",
        editMessage: .constant(MessageSD.sample[0])
    )
}
