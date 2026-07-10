//
//  ChatMessageView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

import SwiftUI
import MarkdownUI
import ActivityIndicatorView
import Splash

/// A code highlighter that switches between cheap plain text (used while the
/// streaming tail is still growing) and full Splash syntax highlighting (used
/// once the text is final) *without* changing the SwiftUI view identity.
///
/// Previously this was done with an `if/else` around two separate `Markdown`
/// views, which made SwiftUI tear down and rebuild the whole block the instant
/// streaming completed — a visible flash / relayout. Swapping only the
/// highlighter value keeps the same view identity, so no rebuild happens.
private struct StreamAwareCodeHighlighter: CodeSyntaxHighlighter {
    let plain: Bool
    let theme: Splash.Theme

    func highlightCode(_ content: String, language: String?) -> Text {
        if plain {
            return Text(content)
        }
        return SplashCodeSyntaxHighlighter(theme: theme).highlightCode(content, language: language)
    }
}

struct ChatMessageView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared
    var message: MessageSD
    var showLoader: Bool = false
    var userInitials: String
    @Binding var editMessage: MessageSD?
    @State private var mouseHover = false
    @State private var isSpeaking = false
    @State private var showThink = false
    
    var image: Image? {
        message.image != nil ? Image(data: message.image!) : nil
    }

    /// Only show the standalone "waiting" spinner before any content has
    /// arrived. Once text/blocks stream in, the streaming content itself (and
    /// the activity header) is the progress indicator. Keeping the spinner in
    /// the row for the whole turn shifted the content horizontally the moment
    /// it disappeared on completion — the end-of-turn flash.
    private var showWaitingLoader: Bool {
        showLoader && message.content.isEmpty && message.renderBlocks.isEmpty
    }
    
    private var codeHighlightColorScheme: Splash.Theme {
        switch colorScheme {
        case .dark:
            return .wwdc17(withFont: .init(size: 16))
        default:
            return .sunset(withFont: .init(size: 16))
        }
    }
    
    /// A rendered segment: either a text answer, or a group of consecutive
    /// thinking/tool blocks that collapse together under one button.
    private enum SegmentKind: Equatable {
        case text(String)
        case activity([MessageBlock])
    }
    private struct RenderSegment: Identifiable, Equatable {
        let id: Int
        let kind: SegmentKind
    }

    /// Renders a single segment.
    ///
    /// NOTE: this used to also conform to `Equatable` with a `.equatable()`
    /// call site so SwiftUI could skip re-evaluating unchanged segments, but
    /// that caused completed messages (esp. ones with code blocks) to
    /// sometimes lay out with extra blank space below them — looks like an
    /// interaction between `EquatableView` short-circuiting and the
    /// horizontal `ScrollView` inside `CodeBlockView` not getting re-measured.
    /// Dropped it; the streaming-tail plain-text optimization below is kept
    /// since it doesn't need `.equatable()` to be effective.
    private struct SegmentView: View {
        let segment: RenderSegment
        let isLast: Bool
        let messageDone: Bool
        let colorScheme: ColorScheme

        /// While the tail segment is still streaming, skip Splash syntax
        /// highlighting (which re-tokenizes the whole code block on every
        /// tick) and fall back to plain text. Once the message is done (or
        /// this isn't the tail anymore) it gets highlighted once, for good.
        private var isStreamingTail: Bool { isLast && !messageDone }

        private var codeHighlightColorScheme: Splash.Theme {
            switch colorScheme {
            case .dark:
                return .wwdc17(withFont: .init(size: 16))
            default:
                return .sunset(withFont: .init(size: 16))
            }
        }

        var body: some View {
            switch segment.kind {
            case .text(let text):
                Markdown(text)
#if os(macOS)
                    .textSelection(.enabled)
#endif
                    .markdownCodeSyntaxHighlighter(
                        StreamAwareCodeHighlighter(plain: isStreamingTail, theme: codeHighlightColorScheme)
                    )
                    .markdownTheme(MarkdownColours.enchantedTheme)
            case .activity(let items):
                ActivityGroupView(blocks: items)
            }
        }
    }

    /// Split blocks into text segments and grouped activity (thinking + tool)
    /// segments, preserving order.
    private func segments(_ blocks: [MessageBlock]) -> [RenderSegment] {
        var result: [RenderSegment] = []
        var activity: [MessageBlock] = []
        var idx = 0
        func flush() {
            guard !activity.isEmpty else { return }
            result.append(RenderSegment(id: idx, kind: .activity(activity)))
            idx += 1
            activity = []
        }
        for block in blocks {
            switch block {
            case .text(let text):
                flush()
                result.append(RenderSegment(id: idx, kind: .text(text)))
                idx += 1
            case .thinking, .tool:
                activity.append(block)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                if message.role == "user" {
                    Spacer()
                } else if showWaitingLoader {
                    ActivityIndicatorView(isVisible: .constant(true), type: .rotatingDots(count: 5))
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(90))
                        .offset(CGSize(width: 0, height: 6))
                }
                
                VStack(alignment: .leading) {
                    let blocks = message.renderBlocks
                    if message.role != "user", !blocks.isEmpty {
                        let segs = segments(blocks)
                        ForEach(segs) { segment in
                            SegmentView(
                                segment: segment,
                                isLast: segment.id == segs.last?.id,
                                messageDone: message.done,
                                colorScheme: colorScheme
                            )
                        }
                    } else {
                    if message.hasThink {
                        HStack(spacing: 10.0, content: {
                            Rectangle()
                                .fill(Color.secondary)
                                .frame(width: 10)
                            if showThink {
                                if let think = message.think {
                                    Markdown(think)
#if os(macOS)
                                        .textSelection(.enabled)
#endif
                                        .markdownCodeSyntaxHighlighter(.splash(theme: codeHighlightColorScheme))
                                        .markdownTheme(MarkdownColours.enchantedTheme)
                                }
                            } else {
                                if message.thinkComplete {
                                    Text("Thought for a few seconds.")
                                } else {
                                    Text("Thinking...")
                                }
                            }
                        }).fixedSize(horizontal: false, vertical: true)
                          .padding(.init(top: 0, leading: 0, bottom: 10, trailing: 0))
                          .onTapGesture {
                              showThink = !showThink
                          }
                    }
                    if let content = message.realContent {
                        Markdown(content)
    #if os(macOS)
                            .textSelection(.enabled)
    #endif
                            .markdownCodeSyntaxHighlighter(
                                StreamAwareCodeHighlighter(plain: !message.done, theme: codeHighlightColorScheme)
                            )
                            .markdownTheme(MarkdownColours.enchantedTheme)
                    }
                    
                    }
                    if let uiImage = image {
                        uiImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        
                    }
                }
                .if(message.role == "user", transform: { v in
                    v.padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(CodexTheme.surfaceSubtle)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CodexTheme.border.opacity(0.7), lineWidth: 1)
                        )
                })
                
                if message.role != "user" {
                    Spacer()
                }
            }
#if os(macOS)
            HStack(spacing: 0) {
                /// Copy button
                Button(action: {Clipboard.shared.setString(message.content)}) {
                    Image(systemName: "doc.on.doc")
                        .padding(8)
                }
                .buttonStyle(GrowingButton())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                /// Play button
                Button(action: {
                    Task {
                        await speechSynthesizer.stopSpeaking()
                        await speechSynthesizer.speak(text: message.content, onFinished: { isSpeaking = false })
                        DispatchQueue.main.asyncAfter(deadline: .now()+0.1) {
                            isSpeaking = true
                        }
                    }
                }) {
                    Image(systemName: "speaker.wave.2.fill")
                        .frame(width: 10)
                        .padding(8)
                }
                .buttonStyle(GrowingButton())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .showIf(!isSpeaking)
                
                /// Stop button
                Button(action: {
                    Task {
                        isSpeaking = false
                        await speechSynthesizer.stopSpeaking()
                    }
                }) {
                    Image(systemName: "speaker.slash.fill")
                        .frame(width: 10)
                        .padding(8)
                }
                .buttonStyle(GrowingButton())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .showIf(isSpeaking)
                
                /// Edit button
                Button(action: {editMessage = message}) {
                    Image(systemName: "pencil")
                        .padding(8)
                }
                .buttonStyle(GrowingButton())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .showIf(message.role == "user")
            }
            .opacity(mouseHover ? 1 : 0.0001)
            
#endif
        }
#if os(macOS)
        .onHover { over in
            withAnimation(.easeInOut(duration: 0.3)) {
                mouseHover = over
            }
        }
#endif
    }
}

#Preview {
    VStack {
        ChatMessageView(message: MessageSD.sample[0], userInitials: "AM", editMessage: .constant(nil))
            .previewLayout(.sizeThatFits)
        
        ChatMessageView(message: MessageSD.sample[1], userInitials: "AM", editMessage: .constant(nil))
            .previewLayout(.sizeThatFits)
        
        ChatMessageView(message: MessageSD(content: "```python \nprint(5+5)\n```", role: "ai"), showLoader: true, userInitials: "AM", editMessage: .constant(nil))
            .previewLayout(.sizeThatFits)
    }
}
