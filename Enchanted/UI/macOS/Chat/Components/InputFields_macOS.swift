//
//  InputFields_macOS.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

#if os(macOS) || os(visionOS)
import SwiftUI

struct InputFieldsView: View {
    @Binding var message: String
    var conversationState: ConversationState
    var onStopGenerateTap: @MainActor () -> Void
    var selectedModel: LanguageModelSD?
    var modelsList: [LanguageModelSD] = []
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> () = { _ in }
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ image: Image?, _ trimmingMessageId: String?) -> ()
    var stats: PiSessionStats? = nil
    var onSteer: @MainActor (_ message: String) -> Void = { _ in }
    @Binding var editMessage: MessageSD?
    @State var isRecording = false
    
    @State private var selectedImage: Image?
    @State private var fileDropActive: Bool = false
    @State private var fileSelectingActive: Bool = false
    @State private var attachments: [TextAttachment] = []
    @State private var inputHeight: CGFloat = 32
    @State private var isInputFocused: Bool = false
    @State private var previewAttachment: TextAttachment?
    @FocusState private var isFocusedInput: Bool

    /// Combines any large-text attachments with the short instruction typed in
    /// the field into a single prompt, separated by blank lines.
    private func composedPrompt() -> String {
        let parts = attachments.map(\.rawContent) + [message]
        return parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
    
    @MainActor private func sendMessage() {
        // While a turn is running, Enter steers the in-flight run instead of
        // starting a new one (the stop button still aborts).
        if conversationState == .loading {
            let trimmed = composedPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSteer(trimmed)
            withAnimation {
                message = ""
                attachments = []
            }
            return
        }

        guard let selectedModel = selectedModel else { return }

        let prompt = composedPrompt()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        onSendMessageTap(
            prompt,
            selectedModel,
            selectedImage,
            editMessage?.id.uuidString
        )
        withAnimation {
            isRecording = false
            isFocusedInput = false
            isInputFocused = false
            editMessage = nil
            selectedImage = nil
            attachments = []
            message = ""
        }
    }
    
    private func updateSelectedImage(_ image: Image) {
        selectedImage = image
    }

    /// Whether there is something worth sending: a typed instruction or at
    /// least one large-text attachment.
    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    
    @ViewBuilder
    private var sendButton: some View {
        switch conversationState {
        case .loading:
            Button(action: onStopGenerateTap) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        default:
            Button(action: { Task { sendMessage() } }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.gray))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = selectedImage {
                RemovableImage(
                    image: image,
                    onClick: {selectedImage = nil},
                    height: 70
                )
                .padding(.horizontal, 6)
            }

            // Large-text attachment chips (Codex-style)
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            AttachmentChipView(
                                attachment: item,
                                onRemove: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        attachments.removeAll { $0.id == item.id }
                                    }
                                },
                                onTap: { previewAttachment = item }
                            )
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Text input
#if os(macOS)
            CustomPasteTextView(
                text: $message,
                isFocused: $isInputFocused,
                calculatedHeight: $inputHeight,
                onSubmit: { Task { sendMessage() } },
                onLargePaste: { pasted in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        attachments.append(TextAttachment(rawContent: pasted))
                    }
                },
                onImagePaste: { nsImage in
                    updateSelectedImage(Image(nsImage: nsImage))
                }
            )
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .allowsHitTesting(!fileDropActive)
#else
            TextField("Message", text: $message.animation(.easeOut(duration: 0.3)), axis: .vertical)
                .focused($isFocusedInput)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .lineLimit(1...12)
                .textFieldStyle(.plain)
                .allowsHitTesting(!fileDropActive)
#endif

            // Bottom control row (Codex-style)
            HStack(spacing: 10) {
                // Attach image
                SimpleFloatingButton(systemImage: "plus", onClick: { fileSelectingActive.toggle() })
                    .showIf(selectedModel?.supportsImages ?? false)
                    .fileImporter(isPresented: $fileSelectingActive,
                                  allowedContentTypes: [.png, .jpeg, .tiff],
                                  onCompletion: { result in
                        switch result {
                        case .success(let url):
                            guard url.startAccessingSecurityScopedResource() else { return }
                            if let imageData = try? Data(contentsOf: url) {
                                selectedImage = Image(data: imageData)
                            }
                            url.stopAccessingSecurityScopedResource()
                        case .failure(let error):
                            print(error)
                        }
                    })

                // Project / working-directory context badge
                ComposerContextBadge()

                // Model selector
                ModelSelectorView(
                    modelsList: modelsList,
                    selectedModel: selectedModel,
                    onSelectModel: onSelectModel,
                    showChevron: false
                )
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                // Reasoning level
                ThinkingLevelMenu()

                if let stats {
                    SessionStatsBadge(stats: stats)
                }

                Spacer()

                RecordingView(isRecording: $isRecording.animation()) { transcription in
                    withAnimation(.easeIn(duration: 0.3)) {
                        self.message = transcription
                    }
                }

                sendButton
            }
        }
        .transition(.slide)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.gray2Custom.opacity(0.6), lineWidth: 1)
        )
        .overlay {
            if fileDropActive {
                DragAndDrop(cornerRadius: 10)
            }
        }
        .animation(.default, value: fileDropActive)
        .onDrop(of: [.image], isTargeted: $fileDropActive.animation(), perform: { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if error == nil, let data {
                    selectedImage = Image(data: data)
                }
            }
            
            return true
        })
        .contentShape(Rectangle())
        .onTapGesture {
            // allow focusing text area on greater tap area
            isFocusedInput = true
#if os(macOS)
            isInputFocused = true
#endif
        }
#if os(macOS)
        .sheet(item: $previewAttachment) { item in
            AttachmentPreviewView(
                attachment: item,
                onClose: { previewAttachment = nil }
            )
        }
#endif
    }
}

/// Compact token / cost / context indicator for the composer (Codex-style).
struct SessionStatsBadge: View {
    let stats: PiSessionStats

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private var contextColor: Color {
        guard let p = stats.contextPercent else { return .secondary }
        if p >= 85 { return .red }
        if p >= 60 { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            if let p = stats.contextPercent {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10))
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(contextColor)
            }
            Text(fmt(stats.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if stats.cost > 0 {
                Text(String(format: "$%.3f", stats.cost))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .help(contextTooltip)
    }

    private var contextTooltip: String {
        var parts = ["Tokens: \(stats.totalTokens) (in \(stats.inputTokens) / out \(stats.outputTokens))"]
        if let t = stats.contextTokens, let w = stats.contextWindow {
            parts.append("Context: \(t) / \(w)")
        }
        if stats.cost > 0 { parts.append(String(format: "Cost: $%.4f", stats.cost)) }
        return parts.joined(separator: "\n")
    }
}

/// Codex-style reasoning-level selector (off → xhigh), wired to pi's
/// `set_thinking_level` via UserDefaults("piThinkingLevel").
struct ThinkingLevelMenu: View {
    @AppStorage("piThinkingLevel") private var level: String = "medium"

    private let levels: [(id: String, label: String)] = [
        ("off", "Off"),
        ("minimal", "Minimal"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Max"),
    ]

    private var currentLabel: String {
        levels.first(where: { $0.id == level })?.label ?? "Medium"
    }

    var body: some View {
        Menu {
            ForEach(levels, id: \.id) { item in
                Button(action: { level = item.id }) {
                    HStack {
                        Text(item.label)
                        if item.id == level { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                Text(currentLabel)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Large-text paste → attachment

/// Threshold used to decide whether pasted text should collapse into an
/// attachment chip instead of flooding the input field.
enum PasteThreshold {
    static let maxChars = 2000
    static let maxLines = 15

    static func isLarge(_ text: String) -> Bool {
        if text.count > maxChars { return true }
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return lines > maxLines
    }
}

/// A chunk of large pasted text held out of the live text field.
struct TextAttachment: Identifiable, Equatable {
    let id = UUID()
    let rawContent: String

    var lineCount: Int {
        rawContent.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    var charCount: Int { rawContent.count }

    /// First non-empty line, trimmed and truncated, used as the chip title.
    var previewTitle: String {
        let firstMeaningful = rawContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let base = firstMeaningful.isEmpty
            ? rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            : firstMeaningful
        return String(base.prefix(24))
    }
}

/// Codex-style attachment chip: icon + two-line preview + remove badge.
struct AttachmentChipView: View {
    let attachment: TextAttachment
    let onRemove: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.previewTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text("\(attachment.lineCount) lines · \(attachment.charCount) chars")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 180, height: 46, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.65)))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
    }
}

/// Read/edit popover for the full contents of an attachment.
struct AttachmentPreviewView: View {
    let attachment: TextAttachment
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(attachment.previewTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(attachment.lineCount) lines · \(attachment.charCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(attachment.rawContent)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.08))
            )
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }
}

#if os(macOS)
/// `NSTextView` subclass that intercepts paste to divert images and oversized
/// text before they reach the (expensive) text layout path.
final class PasteInterceptingTextView: NSTextView {
    /// Return `true` if the paste was handled and `super.paste` should be skipped.
    var onPaste: ((NSPasteboard) -> Bool)?
    /// Placeholder drawn natively when the buffer is empty and no IME
    /// composition is in progress.
    var placeholderString: String?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              !hasMarkedText(),
              let placeholder = placeholderString,
              !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let point = NSPoint(x: textContainerInset.width + padding,
                            y: textContainerInset.height)
        placeholder.draw(at: point, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        // Keep the self-drawn placeholder in sync with the empty state.
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if let onPaste, onPaste(NSPasteboard.general) {
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let onPaste, onPaste(NSPasteboard.general) {
            return
        }
        super.pasteAsPlainText(sender)
    }
}

/// SwiftUI bridge around `PasteInterceptingTextView` with self-sizing height,
/// Enter-to-send (Shift+Enter for newline) and large-paste interception.
struct CustomPasteTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var calculatedHeight: CGFloat
    var placeholder: String = "Message"
    var minHeight: CGFloat = 32
    var maxHeight: CGFloat = 240
    var onSubmit: () -> Void
    var onLargePaste: (String) -> Void
    var onImagePaste: (NSImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = PasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.placeholderString = placeholder
        textView.onPaste = { pasteboard in
            context.coordinator.handlePaste(pasteboard)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteInterceptingTextView else { return }

        // Never overwrite the buffer while an IME composition is in progress,
        // otherwise the marked (composing) text gets torn down.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }

        if isFocused, textView.window != nil, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomPasteTextView
        weak var textView: PasteInterceptingTextView?

        init(_ parent: CustomPasteTextView) {
            self.parent = parent
        }

        func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
            // Images take priority (mirrors previous Cmd+V behaviour).
            if pasteboard.canReadItem(withDataConformingToTypes: [
                NSPasteboard.PasteboardType.tiff.rawValue,
                NSPasteboard.PasteboardType.png.rawValue
            ]), let image = NSImage(pasteboard: pasteboard) {
                DispatchQueue.main.async { self.parent.onImagePaste(image) }
                return true
            }
            if let string = pasteboard.string(forType: .string),
               PasteThreshold.isLarge(string) {
                DispatchQueue.main.async { self.parent.onLargePaste(string) }
                return true
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Ignore in-progress IME marked text; only commit real content so
            // the bound string never transiently holds composing pinyin.
            if textView.hasMarkedText() {
                recalculateHeight()
                return
            }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
            recalculateHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                if self.parent.isFocused == false {
                    self.parent.isFocused = true
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftPressed {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let newHeight = min(max(used + inset, parent.minHeight), parent.maxHeight)
            if abs(newHeight - parent.calculatedHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.calculatedHeight = newHeight
                }
            }
        }
    }
}
#endif

#Preview {
    @State var message = ""
    return InputFieldsView(
        message: $message,
        conversationState: .completed,
        onStopGenerateTap: {},
        onSendMessageTap: {_, _, _, _  in},
        editMessage: .constant(nil)
    )
}
#endif
