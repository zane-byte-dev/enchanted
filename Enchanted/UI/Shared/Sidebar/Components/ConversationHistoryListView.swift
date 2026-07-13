//
//  ConversationHistoryList.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ConversationGroup: Hashable {
    let date: Date
    var conversations: [ConversationSD]
    
    // Implementing the Hashable protocol
    static func == (lhs: ConversationGroup, rhs: ConversationGroup) -> Bool {
        lhs.date == rhs.date
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}

/// Conversations grouped by their working directory (project).
struct ProjectGroup: Identifiable, Hashable {
    static let defaultVisibleConversationLimit = 5

    let path: String
    var conversations: [ConversationSD]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var mostRecent: Date { conversations.map(\.updatedAt).max() ?? .distantPast }

    static func == (lhs: ProjectGroup, rhs: ProjectGroup) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    func visibleConversations(isExpanded: Bool, selectedID: UUID? = nil) -> [ConversationSD] {
        guard !isExpanded else { return conversations }
        var visible = Array(conversations.prefix(Self.defaultVisibleConversationLimit))
        guard let selectedID,
              !visible.contains(where: { $0.id == selectedID }),
              let selected = conversations.first(where: { $0.id == selectedID }) else { return visible }
        if visible.count == Self.defaultVisibleConversationLimit { visible.removeLast() }
        visible.append(selected)
        return visible
    }

    var hiddenConversationCount: Int {
        max(0, conversations.count - Self.defaultVisibleConversationLimit)
    }
}

/// Small status badge reflecting a conversation's live agent state.
struct ConversationStatusBadge: View {
    let conversationID: UUID
    @State private var store = ConversationStore.shared

    var body: some View {
        Group {
            if store.needsUserInput(for: conversationID) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .help("等待确认或输入")
            } else if store.isUnread(conversationID) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .help("未读更新")
            } else {
                switch store.state(for: conversationID) {
                case .loading:
                    ProgressView()
                        .controlSize(.mini)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                case .completed:
                    EmptyView()
                }
            }
        }
        .transition(.opacity)
    }
}

struct ConversationHistoryList: View {
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var onTap: (_ conversation: ConversationSD) -> ()
    var onDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()
    var onNewConversationInProject: (_ path: String) -> () = { _ in }
    
    @State private var collapsed: Set<String> = []
    /// Projects whose conversation overflow is expanded beyond the default five.
    @State private var expandedConversationProjects: Set<String> = []
    @State private var projectDropTarget: String?
    @State private var conversationDropTarget: UUID?
    @State private var draggedConversationID: UUID?
    @State private var renamingConversation: ConversationSD?
    @State private var renameText: String = ""
    @State private var projectStore = ProjectStore.shared
    @State private var conversationStore = ConversationStore.shared
    @State private var renamingProject: String?
    @State private var projectRenameText: String = ""
    @State private var removingProject: String?
    /// Immediate visual selection owned by the sidebar. This bridges the gap
    /// between mouse-up and the async conversation load updating the store.
    @State private var optimisticSelectedConversationID: UUID?

    private var effectiveSelectedConversationID: UUID? {
        optimisticSelectedConversationID ?? selectedConversation?.id
    }

    /// Reveal a conversation's working directory in Finder (macOS only).
    private func revealInFinder(_ conversation: ConversationSD) {
#if os(macOS)
        let path = conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
#endif
    }

    /// Reveal an arbitrary directory path in Finder (macOS only).
    private func revealInFinder(path: String) {
#if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
#endif
    }

    /// The Codex-aligned project (folder) menu, shared between the header's
    /// "…" button and its right-click context menu.
    @ViewBuilder
    private func projectMenuItems(_ group: ProjectGroup) -> some View {
        Button(action: { onNewConversationInProject(group.path) }) {
            Label("New Chat", systemImage: "square.and.pencil")
        }

        Divider()

        Button(action: { projectStore.togglePin(group.path) }) {
            Label(projectStore.isPinned(group.path) ? "Unpin Project" : "Pin Project",
                  systemImage: projectStore.isPinned(group.path) ? "pin.slash" : "pin")
        }
#if os(macOS)
        Button(action: { revealInFinder(path: group.path) }) {
            Label("Show in Finder", systemImage: "folder")
        }
        Button(action: {
            Task {
                if let worktreePath = await ConversationStore.shared.createPermanentWorktree(from: group.path) {
                    await MainActor.run { onNewConversationInProject(worktreePath) }
                }
            }
        }) {
            Label("Create Worktree", systemImage: "arrow.triangle.branch")
        }
#endif
        Button(action: {
            projectRenameText = projectStore.displayName(for: group.path)
            renamingProject = group.path
        }) {
            Label("Rename Project", systemImage: "pencil")
        }
        Button(action: { ConversationStore.shared.archiveProject(path: group.path) }) {
            Label("Archive Conversations", systemImage: "archivebox")
        }

        Divider()

        Button(role: .destructive, action: { removingProject = group.path }) {
            Label("Remove Project", systemImage: "xmark")
        }
    }

    func groupConversationsByProject(_ conversations: [ConversationSD]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: conversations) { conversation in
            conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        }
        return grouped.map { (path, convs) in
            let sorted = convs.sorted {
                if projectStore.sortOrder == .priority {
                    let lhsPriority = conversationPriority($0)
                    let rhsPriority = conversationPriority($1)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                }
                let lhsRank = projectStore.manualConversationRank($0.id, in: path)
                let rhsRank = projectStore.manualConversationRank($1.id, in: path)
                if lhsRank != rhsRank {
                    // New conversations that are not in a saved manual order
                    // still appear first instead of becoming hidden at the end.
                    guard let lhsRank else { return true }
                    guard let rhsRank else { return false }
                    return lhsRank < rhsRank
                }
                // Before the first manual reorder, preserve the familiar
                // pinned-then-recent ordering.
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.updatedAt > $1.updatedAt
            }
            return ProjectGroup(path: path, conversations: sorted)
        }.sorted { lhs, rhs in
            switch projectStore.sortOrder {
            case .priority:
                let lAttention = lhs.conversations.map(conversationPriority).min() ?? Int.max
                let rAttention = rhs.conversations.map(conversationPriority).min() ?? Int.max
                if lAttention != rAttention { return lAttention < rAttention }
                let lPinned = projectStore.isPinned(lhs.path)
                let rPinned = projectStore.isPinned(rhs.path)
                if lPinned != rPinned { return lPinned }
                return lhs.mostRecent > rhs.mostRecent
            case .recent:
                return lhs.mostRecent > rhs.mostRecent
            case .manual:
                let lRank = projectStore.manualRank(for: lhs.path)
                let rRank = projectStore.manualRank(for: rhs.path)
                if lRank != rRank { return lRank < rRank }
                return lhs.mostRecent > rhs.mostRecent
            }
        }
    }

    var projectGroups: [ProjectGroup] {
        groupConversationsByProject(conversations.filter { !$0.isArchived })
    }

    var archivedConversations: [ConversationSD] {
        conversations.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    var flatConversations: [ConversationSD] {
        conversations.filter { !$0.isArchived }.sorted { lhs, rhs in
            let lhsPath = lhs.workingDirectory ?? WorkspaceStore.shared.currentDirectory
            let rhsPath = rhs.workingDirectory ?? WorkspaceStore.shared.currentDirectory
            switch projectStore.sortOrder {
            case .priority:
                let lhsPriority = conversationPriority(lhs)
                let rhsPriority = conversationPriority(rhs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                let lhsProjectPinned = projectStore.isPinned(lhsPath)
                let rhsProjectPinned = projectStore.isPinned(rhsPath)
                if lhsProjectPinned != rhsProjectPinned { return lhsProjectPinned }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            case .recent:
                return lhs.updatedAt > rhs.updatedAt
            case .manual:
                let lhsRank = projectStore.manualRank(for: lhsPath)
                let rhsRank = projectStore.manualRank(for: rhsPath)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    /// Codex-style attention order: actionable tasks first, then unseen
    /// background completions, explicit pins, live runs, and ordinary history.
    private func conversationPriority(_ conversation: ConversationSD) -> Int {
        if conversationStore.needsUserInput(for: conversation.id) { return 0 }
        if conversationStore.isUnread(conversation.id) { return 1 }
        if conversation.isPinned { return 2 }
        if conversationStore.state(for: conversation.id) == .loading { return 3 }
        return 4
    }

    @State private var hoveredProject: String?
    @State private var archivedCollapsed = true
    @State private var hoveredConversation: UUID?
    @State private var conversationInfoPopover: UUID?
    @State private var conversationHoverTask: Task<Void, Never>?

    private func updateConversationHover(_ conversationID: UUID, hovering: Bool) {
        conversationHoverTask?.cancel()
        if hovering {
            hoveredConversation = conversationID
            conversationHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, hoveredConversation == conversationID else { return }
                conversationInfoPopover = conversationID
            }
        } else if hoveredConversation == conversationID {
            hoveredConversation = nil
            conversationInfoPopover = nil
        }
    }

    /// A single conversation row with its full context menu. Shared between the
    /// project groups and the Archived section.
    @ViewBuilder
    private func conversationRow(
        _ conversation: ConversationSD,
        reorderProjectPath: String? = nil,
        currentProjectConversationIDs: [UUID] = []
    ) -> some View {
        let isSelected = effectiveSelectedConversationID == conversation.id
        let showsActions = hoveredConversation == conversation.id

        ZStack(alignment: .trailing) {
            Button(action: {
            // Highlight synchronously; transcript loading and Markdown layout
            // must never gate the sidebar's click feedback.
            optimisticSelectedConversationID = conversation.id
            onTap(conversation)
        }) {
            HStack(spacing: 6) {
                Text(conversation.name)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(CodexTheme.primaryText)
                Spacer(minLength: 4)
                if conversation.goalStatus == "active" || conversation.goalStatus == "paused" {
                    Image(systemName: conversation.goalStatus == "active" ? "target" : "pause.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(conversation.goalStatus == "active" ? Color.accentColor : Color.secondary)
                        .help(conversation.goalStatus == "active" ? "Active long-running goal" : "Paused long-running goal")
                }
                ConversationStatusBadge(conversationID: conversation.id)
                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.mutedText)
                        .rotationEffect(.degrees(45))
                        .opacity(showsActions || isSelected ? 0 : 1)
                }
            }
            .padding(.leading, 8)
            }
            .buttonStyle(SidebarRowStyle(
                isSelected: isSelected
            ))
            .onHover { updateConversationHover(conversation.id, hovering: $0) }

            if showsActions {
                HStack(spacing: 1) {
                    Button {
                        ConversationStore.shared.togglePin(conversation)
                    } label: {
                        Image(systemName: conversation.isPinned ? "pin.fill" : "pin")
                            .rotationEffect(.degrees(conversation.isPinned ? 45 : 0))
                            .frame(width: 20, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CodexTheme.mutedText)
                    .help(conversation.isPinned ? "取消置顶" : "置顶")

                    if !conversation.isArchived {
                        Button {
                            ConversationStore.shared.toggleArchive(conversation)
                        } label: {
                            Image(systemName: "archivebox")
                                .frame(width: 20, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CodexTheme.mutedText)
                        .help("归档")
                    }

                    if reorderProjectPath != nil, hoveredConversation == conversation.id {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CodexTheme.faintText)
                            .frame(width: 20, height: 24)
                            .contentShape(Rectangle())
                            .modifier(ConversationDragSourceModifier(
                                enabled: true,
                                conversation: conversation,
                                draggedConversationID: $draggedConversationID
                            ))
                            .help("拖拽调整对话顺序")
                    }
                }
                .padding(.trailing, 8)
                .padding(.leading, 4)
                .background(isSelected ? CodexTheme.rowSelected : CodexTheme.rowHover)
                .onHover { updateConversationHover(conversation.id, hovering: $0) }
            }
        }
        .popover(isPresented: Binding(
            get: { conversationInfoPopover == conversation.id },
            set: { if !$0, conversationInfoPopover == conversation.id { conversationInfoPopover = nil } }
        ), attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            ConversationInfoPopover(
                conversation: conversation,
                projectName: projectStore.displayName(for:
                    conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
                )
            )
        }
        .contextMenu(menuItems: {
            if !conversation.isArchived {
                Button(action: { ConversationStore.shared.togglePin(conversation) }) {
                    Label(conversation.isPinned ? "Unpin" : "Pin",
                          systemImage: conversation.isPinned ? "pin.slash" : "pin")
                }
            }
            Button(action: {
                renameText = conversation.name
                renamingConversation = conversation
            }) {
                Label("Rename", systemImage: "pencil")
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
#if os(macOS)
            Button(action: {
                Task { await ConversationStore.shared.forkToWorktree(conversation) }
            }) {
                Label("Fork to New Worktree", systemImage: "arrow.triangle.branch")
            }
#endif

            Divider()

#if os(macOS)
            Button(action: { revealInFinder(conversation) }) {
                Label("Show in Finder", systemImage: "folder")
            }
            Button(action: {
                let path = conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
                Clipboard.shared.setString(path)
            }) {
                Label("Copy Working Directory", systemImage: "folder.badge.gearshape")
            }
#endif
            Button(action: {
                Clipboard.shared.setString(conversation.id.uuidString)
            }) {
                Label("Copy Session ID", systemImage: "number")
            }
            Button(action: {
                Clipboard.shared.setString(ConversationStore.deepLink(for: conversation))
            }) {
                Label("Copy Deep Link", systemImage: "link")
            }

            Divider()

            Button(role: .destructive, action: { onDelete(conversation) }) {
                Label("Delete", systemImage: "trash")
            }
        })
        .modifier(ConversationReorderModifier(
            enabled: reorderProjectPath != nil,
            conversation: conversation,
            projectPath: reorderProjectPath ?? "",
            currentIDs: currentProjectConversationIDs,
            dropTarget: $conversationDropTarget,
            draggedConversationID: $draggedConversationID
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(projectStore.navigationLayout == .grouped ? "PROJECTS" : "CHATS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(CodexTheme.mutedText)
                Spacer()
                Menu {
                    Section("整理") {
                        Button {
                            projectStore.setNavigationLayout(.grouped)
                        } label: {
                            Label("按项目", systemImage: projectStore.navigationLayout == .grouped ? "checkmark" : "folder")
                        }
                        Button {
                            projectStore.setNavigationLayout(.flat)
                        } label: {
                            Label("在一个列表中", systemImage: projectStore.navigationLayout == .flat ? "checkmark" : "list.bullet")
                        }
                    }
                    Section("排序方式") {
                        sortButton("优先级", order: .priority)
                        sortButton("最近更新", order: .recent)
                        sortButton("手动排序", order: .manual)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("项目视图与排序")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)

            if projectStore.navigationLayout == .grouped {
            ForEach(projectGroups) { group in
                let isCollapsed = collapsed.contains(group.path)
                let conversationsExpanded = expandedConversationProjects.contains(group.path)

                // Project header
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isCollapsed { collapsed.remove(group.path) } else { collapsed.insert(group.path) }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: projectStore.isPinned(group.path) ? "pin.fill" : "folder")
                            .font(.system(size: 13))
                            .frame(width: 16, height: 16)
                            .foregroundColor(CodexTheme.mutedText)
                            .rotationEffect(.degrees(projectStore.isPinned(group.path) ? 45 : 0))
                        Text(projectStore.displayName(for: group.path))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(CodexTheme.primaryText)
                            .lineLimit(1)
                        Spacer()
                        if hoveredProject == group.path {
                            HStack(spacing: 0) {
                                Button(action: { onNewConversationInProject(group.path) }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(CodexTheme.mutedText)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("New chat in this project")
                                Menu {
                                    projectMenuItems(group)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(CodexTheme.mutedText)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                            .frame(width: 36)
                        } else {
                            Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(CodexTheme.faintText)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .buttonStyle(SidebarRowStyle())
                .help(projectStore.sortOrder == .manual ? "\(group.path)\n拖拽调整项目顺序" : group.path)
                .onHover { hovering in
                    if hovering {
                        hoveredProject = group.path
                    } else if hoveredProject == group.path {
                        hoveredProject = nil
                    }
                }
                .contextMenu {
                    projectMenuItems(group)
                }
                .modifier(ProjectReorderModifier(
                    enabled: projectStore.sortOrder == .manual,
                    path: group.path,
                    currentPaths: projectGroups.map(\.path),
                    dropTarget: $projectDropTarget
                ))

                // Conversations under this project
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.visibleConversations(
                            isExpanded: conversationsExpanded,
                            selectedID: effectiveSelectedConversationID
                        )) { conversation in
                            conversationRow(
                                conversation,
                                reorderProjectPath: group.path,
                                currentProjectConversationIDs: group.conversations.map(\.id)
                            )
                        }
                        if group.hiddenConversationCount > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if conversationsExpanded {
                                        expandedConversationProjects.remove(group.path)
                                    } else {
                                        expandedConversationProjects.insert(group.path)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: conversationsExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(conversationsExpanded ? "收起" : "展开另外 \(group.hiddenConversationCount) 个对话")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                }
                                .foregroundStyle(CodexTheme.mutedText)
                                .padding(.leading, 8)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(CodexTheme.divider)
                            .frame(width: 1)
                            .padding(.vertical, 3)
                    }
                }
            }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(flatConversations) { conversation in
                        conversationRow(conversation)
                    }
                }
            }

            // Archived section
            if !archivedConversations.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) { archivedCollapsed.toggle() }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 13))
                            .frame(width: 16, height: 16)
                            .foregroundColor(CodexTheme.mutedText)
                        Text("Archived")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(CodexTheme.primaryText)
                            .lineLimit(1)
                        Text("\(archivedConversations.count)")
                            .font(.system(size: 12))
                            .foregroundColor(CodexTheme.faintText)
                        Spacer()
                        Image(systemName: archivedCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(CodexTheme.faintText)
                    }
                }
                .buttonStyle(SidebarRowStyle())
                .padding(.top, 6)

                if !archivedCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(archivedConversations) { conversation in
                            conversationRow(conversation)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(CodexTheme.divider)
                            .frame(width: 1)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
        .onChange(of: selectedConversation?.id) { _, selectedID in
            // Hand ownership back to the store once it acknowledges the same
            // selection. If an older cancelled request reports first, retain
            // the latest optimistic row instead of flashing backwards.
            if selectedID == optimisticSelectedConversationID {
                optimisticSelectedConversationID = nil
            }
        }
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Rename") {
                if let conversation = renamingConversation {
                    ConversationStore.shared.rename(conversation, to: renameText)
                }
                renamingConversation = nil
            }
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Name", text: $projectRenameText)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename") {
                if let path = renamingProject {
                    projectStore.setDisplayName(projectRenameText, for: path)
                }
                renamingProject = nil
            }
        }
        .alert("Remove Project", isPresented: Binding(
            get: { removingProject != nil },
            set: { if !$0 { removingProject = nil } }
        )) {
            Button("Cancel", role: .cancel) { removingProject = nil }
            Button("Remove", role: .destructive) {
                if let path = removingProject {
                    ConversationStore.shared.deleteProject(path: path)
                }
                removingProject = nil
            }
        } message: {
            Text("This deletes all conversations in this project. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func sortButton(_ title: String, order: ProjectSortOrder) -> some View {
        Button {
            if order == .manual { projectStore.setNavigationLayout(.grouped) }
            projectStore.setSortOrder(order, currentPaths: projectGroups.map(\.path))
        } label: {
            Label(title, systemImage: projectStore.sortOrder == order ? "checkmark" : sortIcon(order))
        }
    }

    private func sortIcon(_ order: ProjectSortOrder) -> String {
        switch order {
        case .priority: "pin"
        case .recent: "clock"
        case .manual: "arrow.up.arrow.down"
        }
    }
}

private struct ProjectReorderModifier: ViewModifier {
    private static let payloadPrefix = "mox-project:"
    let enabled: Bool
    let path: String
    let currentPaths: [String]
    @Binding var dropTarget: String?
    @State private var projectStore = ProjectStore.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(Self.payloadPrefix + path) {
                    Label(projectStore.displayName(for: path), systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .dropDestination(for: String.self) { items, location in
                    guard let payload = items.first,
                          payload.hasPrefix(Self.payloadPrefix) else { return false }
                    let source = String(payload.dropFirst(Self.payloadPrefix.count))
                    guard source != path else { return false }
                    projectStore.moveProject(
                        source,
                        relativeTo: path,
                        placeAfter: location.y > 14,
                        currentPaths: currentPaths
                    )
                    dropTarget = nil
                    return true
                } isTargeted: { targeted in
                    dropTarget = targeted ? path : (dropTarget == path ? nil : dropTarget)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            dropTarget == path ? Color.accentColor : Color.clear,
                            lineWidth: 1
                        )
                }
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(dropTarget == path ? Color.accentColor.opacity(0.08) : Color.clear)
                }
        } else {
            content
        }
    }
}

private struct ConversationReorderModifier: ViewModifier {
    let enabled: Bool
    let conversation: ConversationSD
    let projectPath: String
    let currentIDs: [UUID]
    @Binding var dropTarget: UUID?
    @Binding var draggedConversationID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrop(of: [UTType.text], delegate: ConversationDropDelegate(
                    targetID: conversation.id,
                    projectPath: projectPath,
                    currentIDs: currentIDs,
                    draggedConversationID: $draggedConversationID,
                    dropTarget: $dropTarget
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(dropTarget == conversation.id ? Color.accentColor : Color.clear, lineWidth: 1)
                }
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(dropTarget == conversation.id ? Color.accentColor.opacity(0.08) : Color.clear)
                }
        } else {
            content
        }
    }
}

private struct ConversationDragSourceModifier: ViewModifier {
    let enabled: Bool
    let conversation: ConversationSD
    @Binding var draggedConversationID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggedConversationID = conversation.id
                    return NSItemProvider(object: conversation.id.uuidString as NSString)
                }
        } else {
            content
        }
    }
}

private struct ConversationInfoPopover: View {
    let conversation: ConversationSD
    let projectName: String
    @State private var branch: String?

    private var workingDirectory: String {
        conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(conversation.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(conversation.updatedAt.shortAgoString())
                    .font(.system(size: 14))
                    .foregroundStyle(CodexTheme.mutedText)
            }

            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .frame(width: 18)
                    .foregroundStyle(CodexTheme.mutedText)
                Text(projectName)
                    .font(.system(size: 14))
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(1)
            }

            if let branch {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 15))
                        .frame(width: 18)
                        .foregroundStyle(CodexTheme.mutedText)
                    Text(branch)
                        .font(.system(size: 14))
                        .foregroundStyle(CodexTheme.primaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .task(id: workingDirectory) {
#if os(macOS)
            let directory = workingDirectory
            branch = await Task.detached {
                GitRepositoryActions.currentBranch(at: directory)
            }.value
#endif
        }
        .presentationCompactAdaptation(.popover)
    }
}

private struct ConversationDropDelegate: DropDelegate {
    let targetID: UUID
    let projectPath: String
    let currentIDs: [UUID]
    let draggedConversationID: Binding<UUID?>
    let dropTarget: Binding<UUID?>

    func validateDrop(info: DropInfo) -> Bool {
        guard let sourceID = draggedConversationID.wrappedValue else { return false }
        return sourceID != targetID && currentIDs.contains(sourceID)
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedConversationID.wrappedValue,
              sourceID != targetID,
              currentIDs.contains(sourceID) else { return }
        dropTarget.wrappedValue = targetID
        ProjectStore.shared.moveConversation(
            sourceID,
            relativeTo: targetID,
            placeAfter: info.location.y > 13,
            in: projectPath,
            currentIDs: currentIDs
        )
    }

    func dropExited(info: DropInfo) {
        if dropTarget.wrappedValue == targetID { dropTarget.wrappedValue = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget.wrappedValue = nil
        draggedConversationID.wrappedValue = nil
        return true
    }
}


#Preview {
    ConversationHistoryList(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onTap: {_ in}, onDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
