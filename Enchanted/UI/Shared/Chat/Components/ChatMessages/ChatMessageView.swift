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
import SwiftMath
import WrappingHStack
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum FormulaInlineToken: Equatable, Sendable {
    case text(String)
    case formula(String)
}

enum FormulaMarkdownSegment: Equatable, Sendable {
    case markdown(String)
    case inline([FormulaInlineToken])
    case display(String)
    case mermaid(String)
}

/// Conservative `$…$` / `$$…$$` extraction for chat Markdown. Formulas are
/// recognized only outside fenced and inline code. Unclosed or invalid LaTeX
/// remains ordinary Markdown, which is safer than hiding user-visible text.
enum FormulaMarkdownParser {
    static func parse(_ source: String) -> [FormulaMarkdownSegment] {
        let mayContainMermaid = source.range(
            of: "mermaid",
            options: [.caseInsensitive]
        ) != nil
        guard source.contains("$") || mayContainMermaid else { return [.markdown(source)] }

        var result: [FormulaMarkdownSegment] = []
        var normalBuffer = ""
        var displayBuffer = ""
        var inDisplay = false
        var fenceMarker: Character?

        func appendSegment(_ segment: FormulaMarkdownSegment) {
            guard segment != .markdown("") else { return }
            if case .markdown(let next) = segment,
               case .markdown(let existing) = result.last {
                result[result.count - 1] = .markdown(existing + next)
            } else {
                result.append(segment)
            }
        }

        func flushNormal() {
            guard !normalBuffer.isEmpty else { return }
            for block in markdownBlocks(normalBuffer) {
                if let source = mermaidSource(in: block) {
                    appendSegment(.mermaid(source))
                } else if let tokens = inlineTokens(block) {
                    appendSegment(.inline(tokens))
                } else {
                    appendSegment(.markdown(block))
                }
            }
            normalBuffer = ""
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, substring) in lines.enumerated() {
            let hasNewline = offset < lines.count - 1
            let line = String(substring)
            let terminator = hasNewline ? "\n" : ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineFence: Character? = trimmed.hasPrefix("```") ? "`"
                : (trimmed.hasPrefix("~~~") ? "~" : nil)

            if !inDisplay, let lineFence {
                if fenceMarker == nil {
                    fenceMarker = lineFence
                } else if fenceMarker == lineFence {
                    fenceMarker = nil
                }
                normalBuffer += line + terminator
                continue
            }
            if fenceMarker != nil {
                normalBuffer += line + terminator
                continue
            }

            if inDisplay {
                if let close = unescapedRange(of: "$$", in: line) {
                    displayBuffer += String(line[..<close.lowerBound])
                    let latex = displayBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidLatex(latex) {
                        appendSegment(.display(latex))
                    } else {
                        normalBuffer += "$$" + displayBuffer + "$$"
                    }
                    displayBuffer = ""
                    inDisplay = false
                    normalBuffer += String(line[close.upperBound...]) + terminator
                } else {
                    displayBuffer += line + terminator
                }
                continue
            }

            if let open = unescapedRange(of: "$$", in: line) {
                normalBuffer += String(line[..<open.lowerBound])
                flushNormal()
                let remainder = String(line[open.upperBound...])
                if let close = unescapedRange(of: "$$", in: remainder) {
                    let latex = String(remainder[..<close.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidLatex(latex) {
                        appendSegment(.display(latex))
                    } else {
                        normalBuffer += "$$" + String(remainder[..<close.upperBound])
                    }
                    normalBuffer += String(remainder[close.upperBound...]) + terminator
                } else {
                    inDisplay = true
                    displayBuffer = remainder + terminator
                }
            } else {
                normalBuffer += line + terminator
            }
        }

        if inDisplay {
            normalBuffer += "$$" + displayBuffer
        }
        flushNormal()
        return result.isEmpty ? [.markdown(source)] : result
    }

    private static func markdownBlocks(_ source: String) -> [String] {
        var blocks: [String] = []
        var buffer = ""
        var fenceMarker: Character?
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (offset, substring) in lines.enumerated() {
            let line = String(substring)
            let hasNewline = offset < lines.count - 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker: Character? = trimmed.hasPrefix("```") ? "`"
                : (trimmed.hasPrefix("~~~") ? "~" : nil)
            if let marker {
                if fenceMarker == nil {
                    if !buffer.isEmpty {
                        blocks.append(buffer)
                        buffer = ""
                    }
                    fenceMarker = marker
                } else if fenceMarker == marker {
                    fenceMarker = nil
                }
            }
            buffer += line + (hasNewline ? "\n" : "")
            if marker != nil, fenceMarker == nil, !buffer.isEmpty {
                blocks.append(buffer)
                buffer = ""
            } else if fenceMarker == nil, trimmed.isEmpty, !buffer.isEmpty {
                blocks.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { blocks.append(buffer) }
        return blocks
    }

    private static func mermaidSource(in block: String) -> String? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }

        let opening = String(lines[0]).trimmingCharacters(in: .whitespaces)
        let marker: String
        if opening.caseInsensitiveCompare("```mermaid") == .orderedSame {
            marker = "```"
        } else if opening.caseInsensitiveCompare("~~~mermaid") == .orderedSame {
            marker = "~~~"
        } else {
            return nil
        }

        guard let closingIndex = lines.indices.dropFirst().last(where: {
            String(lines[$0]).trimmingCharacters(in: .whitespaces) == marker
        }) else { return nil }
        guard lines.indices.filter({ $0 > closingIndex }).allSatisfy({
            String(lines[$0]).trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }

        let source = lines[1..<closingIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : source
    }

    private static func inlineTokens(_ block: String) -> [FormulaInlineToken]? {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~") else { return nil }

        var tokens: [FormulaInlineToken] = []
        var textStart = block.startIndex
        var cursor = block.startIndex
        var inlineCodeFenceLength: Int?
        var formulaCount = 0

        while cursor < block.endIndex {
            if block[cursor] == "`", !isEscaped(cursor, in: block) {
                let run = repeatedCharacterCount(from: cursor, character: "`", in: block)
                if inlineCodeFenceLength == nil {
                    inlineCodeFenceLength = run
                } else if inlineCodeFenceLength == run {
                    inlineCodeFenceLength = nil
                }
                cursor = block.index(cursor, offsetBy: run)
                continue
            }

            guard block[cursor] == "$",
                  inlineCodeFenceLength == nil,
                  !isEscaped(cursor, in: block),
                  block.index(after: cursor) < block.endIndex,
                  block[block.index(after: cursor)] != "$" else {
                cursor = block.index(after: cursor)
                continue
            }

            var close = block.index(after: cursor)
            while close < block.endIndex {
                if block[close] == "\n" { break }
                if block[close] == "$", !isEscaped(close, in: block) { break }
                close = block.index(after: close)
            }
            guard close < block.endIndex, block[close] == "$" else {
                cursor = block.index(after: cursor)
                continue
            }

            let latex = String(block[block.index(after: cursor)..<close])
            guard let first = latex.first, let last = latex.last,
                  !first.isWhitespace, !last.isWhitespace,
                  isValidLatex(latex) else {
                cursor = block.index(after: cursor)
                continue
            }

            if textStart < cursor {
                tokens.append(.text(String(block[textStart..<cursor])))
            }
            tokens.append(.formula(latex))
            formulaCount += 1
            cursor = block.index(after: close)
            textStart = cursor
        }

        guard formulaCount > 0 else { return nil }
        if textStart < block.endIndex {
            tokens.append(.text(String(block[textStart...])))
        }
        return tokens
    }

    private static func unescapedRange(of marker: String, in source: String) -> Range<String.Index>? {
        var cursor = source.startIndex
        var inlineCodeFenceLength: Int?
        while cursor < source.endIndex {
            if source[cursor] == "`", !isEscaped(cursor, in: source) {
                let run = repeatedCharacterCount(from: cursor, character: "`", in: source)
                if inlineCodeFenceLength == nil {
                    inlineCodeFenceLength = run
                } else if inlineCodeFenceLength == run {
                    inlineCodeFenceLength = nil
                }
                cursor = source.index(cursor, offsetBy: run)
                continue
            }
            if inlineCodeFenceLength == nil,
               !isEscaped(cursor, in: source),
               source[cursor...].hasPrefix(marker) {
                return cursor..<source.index(cursor, offsetBy: marker.count)
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashes += 1
            cursor = previous
        }
        return slashes % 2 == 1
    }

    private static func repeatedCharacterCount(
        from index: String.Index,
        character: Character,
        in source: String
    ) -> Int {
        var count = 0
        var cursor = index
        while cursor < source.endIndex, source[cursor] == character {
            count += 1
            cursor = source.index(after: cursor)
        }
        return count
    }

    private static func isValidLatex(_ latex: String) -> Bool {
        guard !latex.isEmpty else { return false }
        return MTMathListBuilder.build(fromString: latex) != nil
    }
}

/// Parsed Markdown and completed syntax-highlight output are pure functions of
/// their source. Keeping them in bounded process caches avoids repeating both
/// parsers whenever a cached conversation is shown again.
private enum ChatRenderCache {
    final class CachedMarkdown {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
    }

    final class CachedHighlight {
        let text: Text
        init(_ text: Text) { self.text = text }
    }

    final class CachedFormulaSegments {
        let segments: [FormulaMarkdownSegment]
        init(_ segments: [FormulaMarkdownSegment]) { self.segments = segments }
    }

    /// NSCache is internally synchronized but isn't declared Sendable. Keep it
    /// behind one explicitly audited wrapper instead of exposing shared cache
    /// instances as static non-Sendable state.
    final class Storage: @unchecked Sendable {
        let markdown: NSCache<NSString, CachedMarkdown>
        let highlights: NSCache<NSString, CachedHighlight>
        let formulaSegments: NSCache<NSString, CachedFormulaSegments>

        init() {
            markdown = NSCache<NSString, CachedMarkdown>()
            markdown.countLimit = 512
            markdown.totalCostLimit = 16 * 1024 * 1024

            highlights = NSCache<NSString, CachedHighlight>()
            highlights.countLimit = 256
            highlights.totalCostLimit = 16 * 1024 * 1024

            formulaSegments = NSCache<NSString, CachedFormulaSegments>()
            formulaSegments.countLimit = 512
            formulaSegments.totalCostLimit = 8 * 1024 * 1024
        }
    }

    static func formulaSegments(for source: String) -> [FormulaMarkdownSegment] {
        let key = source as NSString
        if let cached = storage.formulaSegments.object(forKey: key) { return cached.segments }
        let parseState = ConversationPerformance.signposter.beginInterval("FormulaParse")
        let parsed = FormulaMarkdownParser.parse(source)
        ConversationPerformance.signposter.endInterval("FormulaParse", parseState)
        storage.formulaSegments.setObject(
            CachedFormulaSegments(parsed),
            forKey: key,
            cost: source.utf8.count
        )
        return parsed
    }

    static let storage = Storage()

    static func markdownContent(for source: String) -> MarkdownContent {
        let key = source as NSString
        if let cached = storage.markdown.object(forKey: key) { return cached.content }
        let parseState = ConversationPerformance.signposter
            .beginInterval("MarkdownParse")
        let parsed = MarkdownContent(source)
        ConversationPerformance.signposter.endInterval(
            "MarkdownParse",
            parseState
        )
        storage.markdown.setObject(CachedMarkdown(parsed), forKey: key, cost: source.utf8.count)
        return parsed
    }

    static func highlightedText(
        for source: String,
        language: String?,
        namespace: String,
        theme: Splash.Theme
    ) -> Text {
        let key = "\(namespace)|\(language ?? "")|\(source)" as NSString
        if let cached = storage.highlights.object(forKey: key) { return cached.text }
        let highlightState = ConversationPerformance.signposter
            .beginInterval("SyntaxHighlight")
        let highlighted = SplashCodeSyntaxHighlighter(theme: theme)
            .highlightCode(source, language: language)
        ConversationPerformance.signposter.endInterval(
            "SyntaxHighlight",
            highlightState
        )
        storage.highlights.setObject(
            CachedHighlight(highlighted),
            forKey: key,
            cost: source.utf8.count
        )
        return highlighted
    }
}

/// Completed Markdown prefixes are immutable, so syntax highlighting can be
/// cached by source and theme just like the parsed Markdown tree.
private struct CachedCodeHighlighter: CodeSyntaxHighlighter {
    let theme: Splash.Theme
    let cacheNamespace: String

    func highlightCode(_ content: String, language: String?) -> Text {
        return ChatRenderCache.highlightedText(
            for: content,
            language: language,
            namespace: cacheNamespace,
            theme: theme
        )
    }
}

/// Stable Markdown prefix plus the still-changing tail paragraph. The split
/// only advances across a blank line outside fenced code, so a streaming code
/// block is never cut into invalid Markdown fragments.
struct IncrementalMarkdownRenderParts: Equatable {
    let stablePrefix: String
    let liveTail: String

    static func split(_ source: String) -> Self {
        guard !source.isEmpty else { return .init(stablePrefix: "", liveTail: "") }

        var lineStart = source.startIndex
        var lastSafeBoundary: String.Index?
        var fenceMarker: Character?

        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? source.endIndex
            let nextLine = newline.map { source.index(after: $0) } ?? source.endIndex
            let trimmed = source[lineStart..<lineEnd]
                .trimmingCharacters(in: .whitespaces)

            let marker: Character? = trimmed.hasPrefix("```") ? "`"
                : (trimmed.hasPrefix("~~~") ? "~" : nil)
            if let marker {
                fenceMarker = fenceMarker == marker ? nil : (fenceMarker ?? marker)
            } else if fenceMarker == nil, trimmed.isEmpty {
                lastSafeBoundary = nextLine
            }
            lineStart = nextLine
        }

        guard let boundary = lastSafeBoundary else {
            return .init(stablePrefix: "", liveTail: source)
        }
        return .init(
            stablePrefix: String(source[..<boundary]),
            liveTail: String(source[boundary...])
        )
    }
}

private func configureMathLabel(
    _ label: MTMathUILabel,
    latex: String,
    display: Bool,
    fontSize: CGFloat
) {
    label.fontSize = fontSize
    label.labelMode = display ? .display : .text
    label.textAlignment = display ? .center : .left
    label.displayErrorInline = true
#if os(macOS)
    label.textColor = NSColor.labelColor
#else
    label.textColor = UIColor.label
#endif
    label.latex = latex
    label.invalidateIntrinsicContentSize()
}

#if os(macOS)
private struct NativeMathFormulaView: NSViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel(frame: .zero)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configureMathLabel(label, latex: latex, display: display, fontSize: fontSize)
        label.setAccessibilityLabel(latex)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        let size = nsView.fittingSize
        return CGSize(
            width: max(1, ceil(size.width)),
            height: max(ceil(fontSize * 1.25), ceil(size.height))
        )
    }
}
#else
private struct NativeMathFormulaView: UIViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel(frame: .zero)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configureMathLabel(label, latex: latex, display: display, fontSize: fontSize)
        label.accessibilityLabel = latex
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(
            width: max(1, ceil(size.width)),
            height: max(ceil(fontSize * 1.25), ceil(size.height))
        )
    }
}
#endif

#if os(macOS)
private struct MermaidDiagramView: View {
    private enum Phase {
        case loading
        case rendered(image: NSImage, svg: String)
        case failed(String)
    }

    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: Phase = .loading

    private var renderID: String {
        "\(colorScheme == .dark ? "dark" : "light")|\(source)"
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Rendering diagram…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)

            case .rendered(let image, let svg):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .accessibilityLabel("Mermaid diagram")
                    .contextMenu {
                        Button {
                            Clipboard.shared.setString(svg)
                        } label: {
                            Label("Copy SVG", systemImage: "doc.on.doc")
                        }
                    }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Diagram could not be rendered", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(source)
                            .font(.system(size: ThemePreferences.codeFontSize, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(CodexTheme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(CodexTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .task(id: renderID) {
            phase = .loading
            do {
                let svg = try await MermaidRenderer.shared.render(
                    source: source,
                    darkMode: colorScheme == .dark
                )
                guard let image = NSImage(data: Data(svg.utf8)) else {
                    throw MermaidRendererError.invalidResult("image decoding failed")
                }
                phase = .rendered(image: image, svg: svg)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
#endif

private struct FormulaAwareMarkdownView: View {
    let source: String
    let colorScheme: ColorScheme

    private var codeHighlightColorScheme: Splash.Theme {
        switch colorScheme {
        case .dark:
            return .wwdc17(withFont: .init(size: ThemePreferences.codeFontSize))
        default:
            return .sunset(withFont: .init(size: ThemePreferences.codeFontSize))
        }
    }

    private func attributedText(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    var body: some View {
        let segments = ChatRenderCache.formulaSegments(for: source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    Markdown(ChatRenderCache.markdownContent(for: markdown))
                        .markdownCodeSyntaxHighlighter(
                            CachedCodeHighlighter(
                                theme: codeHighlightColorScheme,
                                cacheNamespace: colorScheme == .dark ? "dark" : "light"
                            )
                        )
                        .markdownTheme(MarkdownColours.enchantedTheme)

                case .inline(let tokens):
                    WrappingHStack(
                        alignment: .center,
                        horizontalSpacing: 0,
                        verticalSpacing: 3
                    ) {
                        ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                            switch token {
                            case .text(let text):
                                Text(attributedText(text))
                                    .font(.system(size: ThemePreferences.bodyFontSize))
                                    .foregroundStyle(CodexTheme.primaryText)
                            case .formula(let latex):
                                NativeMathFormulaView(
                                    latex: latex,
                                    display: false,
                                    fontSize: ThemePreferences.bodyFontSize + 1
                                )
                                .fixedSize()
                                .accessibilityLabel(Text(latex))
                            }
                        }
                    }

                case .display(let latex):
                    ScrollView(.horizontal, showsIndicators: false) {
                        NativeMathFormulaView(
                            latex: latex,
                            display: true,
                            fontSize: ThemePreferences.bodyFontSize + 4
                        )
                        .fixedSize()
                        .containerRelativeFrame(.horizontal, alignment: .center)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .accessibilityLabel(Text(latex))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                case .mermaid(let source):
#if os(macOS)
                    MermaidDiagramView(source: source)
#else
                    Markdown("```mermaid\n\(source)\n```")
                        .markdownTheme(MarkdownColours.enchantedTheme)
#endif
                }
            }
        }
    }
}

/// Incremental chat Markdown: immutable completed paragraphs keep the same
/// cached Markdown tree while only a cheap Text tail changes per stream tick.
private struct ChatMarkdownView: View {
    let source: String
    let isStreaming: Bool
    let colorScheme: ColorScheme

    private var parts: IncrementalMarkdownRenderParts {
        isStreaming
            ? .split(source)
            : .init(stablePrefix: source, liveTail: "")
    }

    var body: some View {
        let renderParts = parts
        VStack(alignment: .leading, spacing: 0) {
            if !renderParts.stablePrefix.isEmpty {
                FormulaAwareMarkdownView(
                    source: renderParts.stablePrefix,
                    colorScheme: colorScheme
                )
            }
            if !renderParts.liveTail.isEmpty {
                Text(renderParts.liveTail)
                    .font(.system(size: ThemePreferences.bodyFontSize))
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineSpacing(3)
            }
        }
#if os(macOS)
        .textSelection(.enabled)
#endif
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
    
    var images: [Image] {
        message.imageItems.enumerated().compactMap { index, data in
            Image.cached(data: data, key: "\(message.id.uuidString)-\(index)")
        }
    }

    /// Only show the standalone "waiting" spinner before any content has
    /// arrived. Once text/blocks stream in, the streaming content itself (and
    /// the activity header) is the progress indicator. Keeping the spinner in
    /// the row for the whole turn shifted the content horizontally the moment
    /// it disappeared on completion — the end-of-turn flash.
    private var showWaitingLoader: Bool {
        showLoader && message.content.isEmpty && message.renderBlocks.isEmpty
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

        /// Only the final text segment can still be changing.
        private var isStreamingTail: Bool { isLast && !messageDone }

        var body: some View {
            switch segment.kind {
            case .text(let text):
                ChatMarkdownView(
                    source: text,
                    isStreaming: isStreamingTail,
                    colorScheme: colorScheme
                )
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
                    if message.role == "status" {
                        Label(message.content, systemImage: message.error ? "exclamationmark.triangle" : "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(message.error ? Color.red : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(CodexTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 7))
                    } else if message.role != "user", !blocks.isEmpty {
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
                                    ChatMarkdownView(
                                        source: think,
                                        isStreaming: !message.thinkComplete,
                                        colorScheme: colorScheme
                                    )
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
                        ChatMarkdownView(
                            source: content,
                            isStreaming: !message.done,
                            colorScheme: colorScheme
                        )
                    }
                    
                    }
                    if !images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(images.enumerated()), id: \.offset) { _, uiImage in
                                    ImageThumbnail(image: uiImage, size: 100)
                                }
                            }
                        }
                    }
                }
                .if(message.role == "user", transform: { v in
                    v.padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CodexTheme.surfaceSubtle.opacity(0.72))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(CodexTheme.border.opacity(0.45), lineWidth: 1)
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
            .showIf(message.role != "status")
            
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

#Preview(traits: .sizeThatFitsLayout) {
    VStack {
        ChatMessageView(message: MessageSD.sample[0], userInitials: "AM", editMessage: .constant(nil))
        
        ChatMessageView(message: MessageSD.sample[1], userInitials: "AM", editMessage: .constant(nil))
        
        ChatMessageView(message: MessageSD(content: "```python \nprint(5+5)\n```", role: "ai"), showLoader: true, userInitials: "AM", editMessage: .constant(nil))
    }
}
