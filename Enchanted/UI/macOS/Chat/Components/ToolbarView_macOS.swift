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
        TerminalToggleButton()
        SidebarToggleButton()
    }
}

/// Top-right title-bar toggle that shows/hides the native inspector sidebar for
/// the current conversation.
struct SidebarToggleButton: View {
    @State private var store = RightSidebarStore.shared

    var body: some View {
        Button(action: { store.toggle() }) {
            Image(systemName: "sidebar.right")
                .symbolVariant(store.isVisible ? .fill : .none)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle tool sidebar (\u{2325}\u{2318}B)")
        .foregroundStyle(store.isVisible ? Color.accentColor : CodexTheme.mutedText)
    }
}

/// Top-right toolbar toggle that shows/hides the embedded bottom terminal panel.
struct TerminalToggleButton: View {
    @State private var store = TerminalStore.shared

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) { store.toggle() }
        }) {
            Image(systemName: "terminal")
                .symbolVariant(store.isVisible ? .fill : .none)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle terminal")
        .foregroundStyle(store.isVisible ? Color.accentColor : CodexTheme.mutedText)
    }
}

/// "Choose project" row shown under the composer on the new-conversation
/// empty state. Opens a project picker popover (search + existing projects +
/// new project) and sets the default working directory for the next conversation.
struct ChooseProjectRow: View {
    var compact: Bool = false
    @State private var workspace = WorkspaceStore.shared
    @State private var store = ConversationStore.shared

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


    var body: some View {
        Menu {
            ForEach(projects, id: \.self) { path in
                Button(action: { select(path) }) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                    if path == workspace.currentDirectory {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            Menu("New project") {
                Button("New blank project…", action: newBlank)
                Button("Use existing folder…", action: useExisting)
            }
        } label: {
            if compact {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(isDefault ? "Project" : workspace.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isDefault ? CodexTheme.mutedText : CodexTheme.primaryText)
                .padding(.horizontal, 10)
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
        .menuStyle(.borderlessButton)
        .tint(CodexTheme.primaryText)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(workspace.currentDirectory)
    }

    private func select(_ path: String) {
        workspace.setDirectory(path)
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



/// Folder picker showing the working directory of the selected conversation
/// (or the default for new conversations when none is selected).
struct WorkingDirectoryButton: View {
    @Bindable var workspace: WorkspaceStore
    @State private var conversationStore = ConversationStore.shared

    private var currentPath: String {
        conversationStore.selectedConversation?.workingDirectory ?? workspace.currentDirectory
    }

    var body: some View {
        Menu {
            Button("在 Finder 中打开") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
            }
            Button("在编辑器中打开") {
                NSWorkspace.shared.open(URL(fileURLWithPath: currentPath))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(currentPath)
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
