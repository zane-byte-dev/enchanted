//
//  ToolbarView_macOS.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

#if os(macOS) || os(visionOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ToolbarView: View {
    var modelsList: [LanguageModelSD]
    var selectedModel: LanguageModelSD?
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    var copyChat: (_ json: Bool) -> ()

    var body: some View {
        MoreOptionsMenuView(copyChat: copyChat)
    }
}

/// "Choose project" row shown under the composer on the new-conversation
/// empty state. Opens a project picker popover (search + existing projects +
/// new project) and sets the default working directory for the next conversation.
struct ChooseProjectRow: View {
    var compact: Bool = false
    @State private var workspace = WorkspaceStore.shared
    @State private var store = ConversationStore.shared
    @State private var showPicker = false
    @State private var search = ""

    private var isDefault: Bool {
        workspace.currentDirectory == AgentBackendConfig.defaultWorkingDirectory
    }

    /// Distinct project paths across all conversations (most recent first).
    private var projects: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for c in store.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let p = c.workingDirectory ?? workspace.currentDirectory
            if seen.insert(p).inserted { result.append(p) }
        }
        if !isDefault, seen.insert(workspace.currentDirectory).inserted {
            result.insert(workspace.currentDirectory, at: 0)
        }
        return result
    }

    private var filteredProjects: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Button(action: { showPicker.toggle() }) {
            if compact {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(isDefault ? "Project" : workspace.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isDefault ? Color.secondary : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                    Text(isDefault ? "Choose project" : workspace.displayName)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(isDefault ? Color.secondary : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(workspace.currentDirectory)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            projectPicker
        }
    }

    // Shared row metrics so every icon + label lines up.
    private let iconWidth: CGFloat = 18
    private let rowHPad: CGFloat = 10
    private let rowVPad: CGFloat = 8

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: iconWidth, alignment: .center)
                TextField("Search projects", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
            }
            .padding(.horizontal, rowHPad)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredProjects, id: \.self) { path in
                        Button(action: { select(path) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: iconWidth, alignment: .center)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 15))
                                Spacer(minLength: 4)
                                if path == workspace.currentDirectory {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, rowHPad)
                            .padding(.vertical, rowVPad)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                        .help(path)
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()
                .padding(.vertical, 4)

            Menu {
                Button("New blank project…", action: newBlank)
                Button("Use existing folder…", action: useExisting)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .frame(width: iconWidth, alignment: .center)
                    Text("New project")
                        .font(.system(size: 15))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, rowHPad)
                .padding(.vertical, rowVPad)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .frame(width: 320)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func select(_ path: String) {
        workspace.setDirectory(path)
        showPicker = false
    }

    private func useExisting() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose an existing project folder"
        panel.directoryURL = URL(fileURLWithPath: workspace.currentDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            select(url.path)
        }
#endif
    }

    private func newBlank() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create"
        panel.message = "Create a new folder for a blank project"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            select(url.path)
        }
#endif
    }
}

/// Subtle hover highlight for popover rows.
private struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }
}

/// Folder picker showing the working directory of the selected conversation
/// (or the default for new conversations when none is selected).
struct WorkingDirectoryButton: View {
    @Bindable var workspace: WorkspaceStore
    @State private var conversationStore = ConversationStore.shared

    private var currentPath: String {
        conversationStore.selectedConversation?.workingDirectory ?? workspace.currentDirectory
    }

    var body: some View {
        Button(action: pickDirectory) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(currentPath)
    }

    private func pickDirectory() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the project directory the agent works in"
        panel.directoryURL = URL(fileURLWithPath: currentPath)
        if panel.runModal() == .OK, let url = panel.url {
            if let conversation = conversationStore.selectedConversation {
                conversationStore.setWorkingDirectory(url.path, for: conversation)
            } else {
                // No conversation selected → set the default for new ones.
                workspace.setDirectory(url.path)
            }
        }
#endif
    }
}

/// Compact project/working-directory badge shown inside the composer.
/// Picks the per-conversation directory when a conversation is selected,
/// otherwise the workspace default (rich project picker) for new chats.
struct ComposerContextBadge: View {
    @State private var conversationStore = ConversationStore.shared
    @State private var workspace = WorkspaceStore.shared

    var body: some View {
        if conversationStore.selectedConversation != nil {
            WorkingDirectoryButton(workspace: workspace)
        } else {
            ChooseProjectRow(compact: true)
        }
    }
}

#Preview {
    ToolbarView(
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0],
        onSelectModel: {_ in},
        copyChat: {_ in}
    )
}

#endif
