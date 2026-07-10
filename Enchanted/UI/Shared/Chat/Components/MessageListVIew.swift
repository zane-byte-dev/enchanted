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
    var messages: [MessageSD]
    var conversationState: ConversationState
    var userInitials: String
    @Binding var editMessage: MessageSD?
    @State private var messageSelected: MessageSD?
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared

    private var contentBackground: Color {
#if os(macOS)
        Color(NSColor.textBackgroundColor)
#else
        CodexTheme.appBackground
#endif
    }
    
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

    /// Pin the scroll view to the stable bottom marker, retried across a few
    /// runloop hops.
    ///
    /// `onChange(of: messages)` does not fire for the initial value, so a
    /// freshly-entered conversation relies on `defaultScrollAnchor` alone;
    /// the retries here guarantee we land at the bottom even if the anchor
    /// resolves before Markdown finishes its first measurement.
    private func pinToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { scrollViewProxy in
                GeometryReader { geo in
                ScrollView {
                    // Plain (non-lazy) VStack: renders every row eagerly so all
                    // heights are known at layout time. `LazyVStack` only
                    // materialised visible rows and measured Markdown/code
                    // heights asynchronously, which lost the race with
                    // `defaultScrollAnchor`/`scrollTo` and parked the viewport
                    // in empty space (the intermittent "blank on enter" bug).
                    // Turns are small now (read-tool dumps are stripped from
                    // `blocksJSON`), so eager layout is cheap and reliable.
                    VStack(spacing: 0) {
                        VStack {
                        Group {
                        ForEach(messages) { message in
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
                // First entry into a conversation: `onChange(of: messages)`
                // does NOT fire for the initial value, so the freshly-mounted
                // list relies solely on `defaultScrollAnchor` — which loses the
                // race against lazy Markdown measurement and lands blank. Pin
                // explicitly once the view appears (with retries) to fix it.
                .onAppear {
                    pinToBottom(scrollViewProxy)
                }
                // Fires when the messages array is replaced (switching
                // conversations / new message) — extra safety net in case the
                // anchor doesn't re-trigger on its own for a brand new list.
                .onChange(of: messages) {
                    pinToBottom(scrollViewProxy)
                }
                // Follow the stream as the last message grows.
                .onChange(of: messages.last?.content) {
                    scrollViewProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
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

#Preview {
    MessageListView(
        messages: MessageSD.sample,
        conversationState: .loading,
        userInitials: "AM",
        editMessage: .constant(MessageSD.sample[0])
    )
}
