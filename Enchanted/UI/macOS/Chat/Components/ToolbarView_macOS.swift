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
        .foregroundStyle(store.isVisible ? CodexTheme.primaryText : CodexTheme.mutedText)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(store.isVisible ? CodexTheme.rowHover : Color.clear)
        )
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
        .foregroundStyle(store.isVisible ? CodexTheme.primaryText : CodexTheme.mutedText)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(store.isVisible ? CodexTheme.rowHover : Color.clear)
        )
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
    @State private var operationError: String?
    @State private var guidanceSnapshot = AgentGuidanceSnapshot.empty
    @State private var guidanceReloaded = false
    @State private var isLocalCheckout = true
    @State private var confirmHandoff = false

    private var currentPath: String {
        conversationStore.selectedConversation?.workingDirectory ?? workspace.currentDirectory
    }

    private var hasCurrentDirectoryGuidance: Bool {
        guidanceSnapshot.files.contains { $0.scope == .workingDirectory }
    }

    var body: some View {
        Menu {
            Button("在 Finder 中打开") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
            }
            Button("在 VS Code 中打开") {
                openInVSCode()
            }

            if let conversation = conversationStore.selectedConversation {
                Divider()
                Button {
                    confirmHandoff = true
                } label: {
                    Label(
                        isLocalCheckout ? "Hand off to Worktree…" : "Hand off to Local…",
                        systemImage: isLocalCheckout ? "arrow.triangle.branch" : "laptopcomputer"
                    )
                }
                .disabled(
                    conversationStore.conversationState == .loading
                    || conversationStore.isHandingOff(conversation)
                )
            }

            Divider()

            Section("Agent 指引") {
                ForEach(guidanceSnapshot.files) { file in
                    Button {
                        openGuidance(file.url)
                    } label: {
                        Label(guidanceLabel(for: file), systemImage: "doc.text")
                    }
                }

                if !hasCurrentDirectoryGuidance {
                    Button {
                        createCurrentGuidance()
                    } label: {
                        Label("创建当前目录 AGENTS.md…", systemImage: "doc.badge.plus")
                    }
                }

                if !guidanceSnapshot.unreadablePaths.isEmpty {
                    Label(
                        "有 \(guidanceSnapshot.unreadablePaths.count) 个指引文件不可读",
                        systemImage: "exclamationmark.triangle"
                    )
                }

                Button {
                    AgentBackendConfig.reconfigure()
                    guidanceReloaded = true
                    refreshGuidance()
                } label: {
                    Label(
                        guidanceReloaded ? "已重新加载到 pi" : "重新加载到 pi",
                        systemImage: guidanceReloaded ? "checkmark" : "arrow.clockwise"
                    )
                }
                .disabled(guidanceSnapshot.files.isEmpty)

                Button("重新扫描", systemImage: "magnifyingglass") {
                    refreshGuidance()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !guidanceSnapshot.files.isEmpty {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.mutedText)
                }
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Working directory is neutral context, not an accent action.
        .tint(CodexTheme.primaryText)
        .fixedSize()
        .help(guidanceSnapshot.files.isEmpty
              ? currentPath
              : "\(currentPath)\n\(guidanceSnapshot.files.count) 个有效 Agent 指引")
        .task(id: currentPath) {
            guidanceReloaded = false
            refreshGuidance()
            let path = currentPath
            isLocalCheckout = await Task.detached {
                GitWorktree.isMainWorktree(path)
            }.value
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好") { operationError = nil }
        } message: {
            Text(operationError ?? "未知错误")
        }
        .confirmationDialog(
            isLocalCheckout ? "Hand off this task to Worktree?" : "Hand off this task to Local?",
            isPresented: $confirmHandoff
        ) {
            Button(isLocalCheckout ? "Hand off to Worktree" : "Hand off to Local") {
                guard let conversation = conversationStore.selectedConversation else { return }
                Task {
                    let result = await conversationStore.handoff(conversation)
                    if !result.success { operationError = result.message }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Mox will merge staged, unstaged, and untracked task changes into the destination. "
                + "Non-conflicting destination changes are preserved; conflicts restore both checkouts unchanged."
            )
        }
    }

    private func openInVSCode() {
        let workspace = NSWorkspace.shared
        let bundleIdentifiers = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        guard let applicationURL = bundleIdentifiers.lazy.compactMap({
            workspace.urlForApplication(withBundleIdentifier: $0)
        }).first else {
            operationError = "未找到 Visual Studio Code，请先安装后再试。"
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open(
            [URL(fileURLWithPath: currentPath, isDirectory: true)],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            if let error {
                DispatchQueue.main.async {
                    operationError = error.localizedDescription
                }
            }
        }
    }

    private func refreshGuidance() {
        guidanceSnapshot = AgentGuidanceScanner.scan(workingDirectory: currentPath)
    }

    private func guidanceLabel(for file: AgentGuidanceFile) -> String {
        switch file.scope {
        case .global:
            return "全局 · \(file.url.lastPathComponent)"
        case .workingDirectory:
            return "当前目录 · \(file.url.lastPathComponent)"
        case .ancestor:
            return "\(file.url.deletingLastPathComponent().lastPathComponent) · \(file.url.lastPathComponent)"
        }
    }

    private func openGuidance(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            operationError = "无法打开 \(url.path)"
            return
        }
    }

    private func createCurrentGuidance() {
        let url = URL(fileURLWithPath: currentPath, isDirectory: true)
            .appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: url.path) {
            refreshGuidance()
            openGuidance(url)
            return
        }

        let template = """
        # Project guidance

        <!-- Keep this file concise. Add durable commands, conventions, safety rules, and verification steps. -->
        """
        do {
            try Data(template.utf8).write(to: url, options: [.atomic, .withoutOverwriting])
            refreshGuidance()
            AgentBackendConfig.reconfigure()
            guidanceReloaded = true
            openGuidance(url)
        } catch {
            operationError = error.localizedDescription
        }
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
