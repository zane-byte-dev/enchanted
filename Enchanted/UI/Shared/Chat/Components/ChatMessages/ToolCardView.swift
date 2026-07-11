//
//  ToolCardView.swift
//  Enchanted
//
//  Codex-style collapsible card for a single tool call.
//

import SwiftUI
import MarkdownUI
#if os(macOS)
import AppKit
import QuickLookUI
#endif

/// Codex-style collapsible group wrapping a run of thinking + tool blocks.
/// Expanded while the turn is streaming, auto-collapses once complete.
struct ActivityGroupView: View {
    let blocks: [MessageBlock]
    // Always start collapsed and leave expand/collapse entirely to the user:
    // no auto-expand while streaming, no auto-collapse on completion (that
    // round-trip caused a visible flash). The header still shows a live
    // spinner + tool count so progress is visible without expanding.
    @State private var expanded = false

    private var tools: [ToolCall] {
        blocks.compactMap { if case .tool(let t) = $0 { return t } else { return nil } }
    }
    private var toolCount: Int { tools.count }

    private var hasThinking: Bool {
        blocks.contains { if case .thinking = $0 { return true } else { return false } }
    }

    private var anyToolRunning: Bool {
        blocks.contains { if case .tool(let t) = $0 { return t.running } else { return false } }
    }

    private var title: String {
        var parts: [String] = []
        if hasThinking { parts.append("Reasoning") }
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount > 1 ? "s" : "")") }
        return parts.isEmpty ? "Activity" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    if anyToolRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        switch block {
                        case .thinking(let text):
                            Markdown(text)
#if os(macOS)
                                .textSelection(.enabled)
#endif
                                .markdownTextStyle { ForegroundColor(.secondary) }
                        case .tool(let tool):
                            ToolCardView(tool: tool)
                        case .text:
                            EmptyView()
                        }
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.gray.opacity(0.25)).frame(width: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct ToolCardView: View {
    let tool: ToolCall
    @State private var expanded = false
    @State private var bodyContentHeight: CGFloat = 0
    @State private var conversationStore = ConversationStore.shared
    @State private var previewURL: URL?

    /// Max height of the expanded body before it becomes scrollable.
    private let maxBodyHeight: CGFloat = 320

    private var statusColor: Color {
        if tool.isError { return .red }
        if tool.running { return .orange }
        return .green
    }

    /// Whether the card has anything to show when expanded. Read-only tools
    /// (read/grep/glob/…) have their result payload stripped at write time, so
    /// they render as a header-only card — no chevron, no expand.
    private var hasBody: Bool {
        !tool.editHunks.isEmpty
            || tool.writeContent != nil
            || (tool.resultText.map { !$0.isEmpty } ?? false)
    }

#if os(macOS)
    private var artifactURL: URL? {
        guard !tool.running, !tool.isError, let path = tool.artifactPath else { return nil }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            let root = conversationStore.selectedConversation?.workingDirectory
                ?? WorkspaceStore.shared.currentDirectory
            url = URL(fileURLWithPath: root).appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: {
                guard hasBody else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .fixedSize()
                    if let subtitle = tool.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if tool.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                    }
                    if hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

#if os(macOS)
            if let artifactURL {
                HStack(spacing: 10) {
                    Spacer()
                    Button(action: { previewURL = artifactURL }) {
                        Label("Preview", systemImage: "eye")
                    }
                    Button("Open") { NSWorkspace.shared.open(artifactURL) }
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([artifactURL])
                    }) {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
#endif

            // Body
            if expanded && hasBody {
                Divider()
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        if !tool.editHunks.isEmpty {
                            DiffView(hunks: tool.editHunks)
                        } else if let content = tool.writeContent {
                            CodeBlock(text: content, added: true)
                        } else if let result = tool.resultText, !result.isEmpty {
                            LabeledSection(title: tool.isError ? "error" : "result", text: result)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: BodyHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
                }
                .frame(height: min(bodyContentHeight, maxBodyHeight))
                .onPreferenceChange(BodyHeightPreferenceKey.self) { bodyContentHeight = $0 }
            }
        }
        .background(Color.gray.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
#if os(macOS)
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let previewURL {
                ArtifactPreviewSheet(url: previewURL)
            }
        }
#endif
    }
}

#if os(macOS)
private struct ArtifactPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc")
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            QuickLookArtifactView(url: url)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

private struct QuickLookArtifactView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}
#endif

private struct BodyHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LabeledSection: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodeBlock: View {
    let text: String
    var added: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(added ? Color.green : Color.primary)
    }
}

/// Simple +/- diff for edit hunks.
struct DiffView: View {
    let hunks: [(old: String, new: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunk.old.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        DiffLine(sign: "-", text: String(line), color: .red)
                    }
                    ForEach(Array(hunk.new.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        DiffLine(sign: "+", text: String(line), color: .green)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffLine: View {
    let sign: String
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(color.opacity(0.10))
    }
}
