//
//  ToolCardView.swift
//  Enchanted
//
//  Codex-style collapsible card for a single tool call.
//

import SwiftUI
import MarkdownUI

/// Collapsible reasoning/thinking block.
struct ThinkingBlockView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                    Text("Reasoning")
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
                Markdown(text)
#if os(macOS)
                    .textSelection(.enabled)
#endif
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 2)
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

    private var statusColor: Color {
        if tool.isError { return .red }
        if tool.running { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if let subtitle = tool.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if tool.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Body
            if expanded {
                Divider()
                Group {
                    if !tool.editHunks.isEmpty {
                        DiffView(hunks: tool.editHunks)
                    } else if let content = tool.writeContent {
                        CodeBlock(text: content, added: true)
                    } else {
                        if !tool.argsJSON.isEmpty, tool.argsJSON != "{}" {
                            LabeledSection(title: "args", text: tool.argsJSON)
                        }
                        if let result = tool.resultText, !result.isEmpty {
                            LabeledSection(title: tool.isError ? "error" : "result", text: result)
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color.gray.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
