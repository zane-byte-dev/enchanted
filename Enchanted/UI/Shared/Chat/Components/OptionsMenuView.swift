//
//  OptionsMenuView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/05/2024.
//

import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct MoreOptionsMenuView: View {
    var conversation: ConversationSD? = nil
    var copyChat: (_ json: Bool) -> ()
    var onRename: () -> Void = {}
    var onDelete: (ConversationSD) -> Void = { _ in }
    @State private var conversationStore = ConversationStore.shared
    @State private var showHistorySyncReport = false

    var body: some View {
        Menu {
            if let conversation {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                Button(action: { ConversationStore.shared.togglePin(conversation) }) {
                    Label(conversation.isPinned ? "Unpin" : "Pin",
                          systemImage: conversation.isPinned ? "pin.slash" : "pin")
                }
                Button(action: { ConversationStore.shared.toggleArchive(conversation) }) {
                    Label(conversation.isArchived ? "Unarchive" : "Archive",
                          systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox")
                }

                Divider()

                Button(action: {
                    Task { await ConversationStore.shared.forkToLocal(conversation) }
                }) {
                    Label("Fork to Local", systemImage: "arrow.branch")
                }
                Button(action: {
                    Task { await conversationStore.compactSelectedConversation() }
                }) {
                    Label(
                        conversationStore.isCompactingSelectedConversation
                            ? "Compacting Context…"
                            : "Compact Context",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .disabled(
                    conversationStore.isCompactingSelectedConversation
                        || conversationStore.conversationState == .loading
                )
                Button(action: {
                    Task { await conversationStore.checkSelectedHistorySync() }
                }) {
                    Label(historySyncLabel, systemImage: historySyncIcon)
                }
                .disabled(conversationStore.currentHistorySyncStatus == .checking)
                if case .drift = conversationStore.currentHistorySyncStatus {
                    Button(action: { showHistorySyncReport = true }) {
                        Label("Review History Drift…", systemImage: "list.bullet.rectangle")
                    }
                }
#if os(macOS)
                Button(action: {
                    Task { await ConversationStore.shared.forkToWorktree(conversation) }
                }) {
                    Label("Fork to New Worktree", systemImage: "arrow.triangle.branch")
                }
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: ConversationStore.shared.workingDirectory(for: conversation))
                    ])
                }) {
                    Label("Show Project in Finder", systemImage: "folder")
                }
#endif

                Divider()
            }

            Button(action: {copyChat(false)}) {
                Label("Copy Chat", systemImage: "doc.on.doc")
            }
            Button(action: {copyChat(true)}) {
                Label("Copy Chat as JSON", systemImage: "curlybraces")
            }
#if os(macOS)
            Button(action: { exportChat(json: false) }) {
                Label("Export as Markdown…", systemImage: "square.and.arrow.down")
            }
            Button(action: { exportChat(json: true) }) {
                Label("Export as JSON…", systemImage: "square.and.arrow.down")
            }
#endif

            if let conversation {
                Divider()
                Button(role: .destructive, action: { onDelete(conversation) }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CodexTheme.mutedText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
#endif
        .menuIndicator(.hidden)
        .fixedSize()
        .sheet(isPresented: $showHistorySyncReport) {
            HistorySyncReportView()
        }
    }

    private var historySyncLabel: String {
        switch conversationStore.currentHistorySyncStatus {
        case .unknown: return String(localized: "Check History Sync")
        case .checking: return String(localized: "Checking History…")
        case .inSync(let turns): return String(localized: "History in Sync · \(turns) turns")
        case .drift(let local, let pi): return String(localized: "History Drift · local \(local) / pi \(pi)")
        case .unavailable: return String(localized: "History Sync Unavailable")
        }
    }

    private var historySyncIcon: String {
        switch conversationStore.currentHistorySyncStatus {
        case .inSync: return "checkmark.circle"
        case .drift: return "exclamationmark.triangle"
        case .checking: return "hourglass"
        default: return "arrow.triangle.2.circlepath"
        }
    }

#if os(macOS)
    private func exportChat(json: Bool) {
        Task {
            let messages = await ConversationStore.shared.allMessagesForSelectedConversation()
            guard !messages.isEmpty else { return }

            let content: String
            if json {
                let rows: [[String: String]] = messages.map {
                    ["role": $0.role, "content": $0.content]
                }
                guard
                    let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
                    let string = String(data: data, encoding: .utf8)
                else { return }
                content = string
            } else {
                content = messages.map {
                    "## \($0.role.capitalized)\n\n\($0.content)"
                }.joined(separator: "\n\n")
            }

            await MainActor.run {
                let panel = NSSavePanel()
                panel.allowedContentTypes = json ? [.json] : [.plainText]
                panel.nameFieldStringValue = "\(safeFilename(conversation?.name ?? "conversation")).\(json ? "json" : "md")"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    AppStore.shared.uiLog(message: "Exported chat to \(url.lastPathComponent)", status: .info)
                } catch {
                    AppStore.shared.uiLog(message: "Export failed: \(error.localizedDescription)", status: .error)
                }
            }
        }
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
    }
#endif
}

private struct HistorySyncReportView: View {
    private enum Resolution { case pi, local }

    @Environment(\.dismiss) private var dismiss
    @State private var store = ConversationStore.shared
    @State private var resolution: Resolution?
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("History Drift", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Local and pi user turns differ. Review the mismatched turns, then choose which history should become authoritative.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let report = store.currentHistorySyncReport {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(report.rows.filter { !$0.matches }) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Turn \(row.index + 1)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                comparisonRow("Local", value: row.local)
                                comparisonRow("pi", value: row.pi)
                            }
                            .padding(10)
                            .background(CodexTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Use pi History…", role: .destructive) { resolution = .pi }
                Button("Use Local History…") { resolution = .local }
                Spacer()
                if isResolving { ProgressView().controlSize(.small) }
            }
            .disabled(isResolving)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .confirmationDialog(
            resolution == .pi ? "Replace local history?" : "Rebuild pi context?",
            isPresented: Binding(
                get: { resolution != nil },
                set: { if !$0 { resolution = nil } }
            )
        ) {
            if resolution == .pi {
                Button("Replace Local History", role: .destructive) { resolve(.pi) }
            } else {
                Button("Rebuild pi from Local History") { resolve(.local) }
            }
            Button("Cancel", role: .cancel) { resolution = nil }
        } message: {
            if resolution == .pi {
                Text("The local transcript will be replaced by the active pi branch. This cannot be undone.")
            } else {
                Text("A new pi session will be created from visible user and assistant text. Tool traces and hidden thinking are not copied into model context.")
            }
        }
    }

    @ViewBuilder
    private func comparisonRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 34, alignment: .leading)
            Text(value ?? "Missing")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(value == nil ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resolve(_ choice: Resolution) {
        resolution = nil
        isResolving = true
        Task { @MainActor in
            switch choice {
            case .pi: await store.resolveHistoryDriftUsingPi()
            case .local: await store.resolveHistoryDriftUsingLocal()
            }
            isResolving = false
            if case .inSync = store.currentHistorySyncStatus { dismiss() }
        }
    }
}

#Preview {
    MoreOptionsMenuView(copyChat: {_ in})
}
