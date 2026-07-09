//
//  ConversationHistoryList.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI
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
    let path: String
    var conversations: [ConversationSD]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var mostRecent: Date { conversations.map(\.updatedAt).max() ?? .distantPast }

    static func == (lhs: ProjectGroup, rhs: ProjectGroup) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Small status badge reflecting a conversation's live agent state.
struct ConversationStatusBadge: View {
    let conversationID: UUID
    @State private var store = ConversationStore.shared

    var body: some View {
        switch store.state(for: conversationID) {
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .transition(.opacity)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .transition(.opacity)
        case .completed:
            EmptyView()
        }
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
    @State private var renamingConversation: ConversationSD?
    @State private var renameText: String = ""

    /// Reveal a conversation's working directory in Finder (macOS only).
    private func revealInFinder(_ conversation: ConversationSD) {
#if os(macOS)
        let path = conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
#endif
    }

    func groupConversationsByProject(_ conversations: [ConversationSD]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: conversations) { conversation in
            conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        }
        return grouped.map { (path, convs) in
            let sorted = convs.sorted {
                // Pinned conversations float to the top, then by recency.
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.updatedAt > $1.updatedAt
            }
            return ProjectGroup(path: path, conversations: sorted)
        }.sorted { $0.mostRecent > $1.mostRecent }
    }

    var projectGroups: [ProjectGroup] {
        groupConversationsByProject(conversations.filter { !$0.isArchived })
    }

    var archivedConversations: [ConversationSD] {
        conversations.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    @State private var hoveredProject: String?
    @State private var archivedCollapsed = true

    /// A single conversation row with its full context menu. Shared between the
    /// project groups and the Archived section.
    @ViewBuilder
    private func conversationRow(_ conversation: ConversationSD) -> some View {
        Button(action: { onTap(conversation) }) {
            HStack(spacing: 6) {
                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(.systemGray))
                        .rotationEffect(.degrees(45))
                }
                Text(conversation.name)
                    .lineLimit(1)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.primary)
                Spacer(minLength: 4)
                ConversationStatusBadge(conversationID: conversation.id)
                Text(conversation.updatedAt.shortAgoString())
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "9CA3AF"))
            }
            .padding(.leading, 8)
        }
        .buttonStyle(SidebarRowStyle(isSelected: selectedConversation == conversation))
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PROJECTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(.systemGray))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)

            ForEach(projectGroups) { group in
                let isCollapsed = collapsed.contains(group.path)

                // Project header
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isCollapsed { collapsed.remove(group.path) } else { collapsed.insert(group.path) }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .frame(width: 16, height: 16)
                            .foregroundColor(Color(.systemGray))
                        Text(group.name)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { onNewConversationInProject(group.path) }) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(.systemGray))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New chat in this project")
                        .opacity(hoveredProject == group.path ? 1 : 0)
                        .allowsHitTesting(hoveredProject == group.path)
                        Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(.systemGray))
                    }
                }
                .buttonStyle(SidebarRowStyle())
                .help(group.path)
                .onHover { hovering in
                    if hovering {
                        hoveredProject = group.path
                    } else if hoveredProject == group.path {
                        hoveredProject = nil
                    }
                }
                .contextMenu {
                    Button(action: { onNewConversationInProject(group.path) }) {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }

                // Conversations under this project
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.conversations, id:\.self) { conversation in
                            conversationRow(conversation)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .frame(width: 1)
                            .padding(.vertical, 3)
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
                            .foregroundColor(Color(.systemGray))
                        Text("Archived")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("\(archivedConversations.count)")
                            .font(.system(size: 12))
                            .foregroundColor(Color(.systemGray))
                        Spacer()
                        Image(systemName: archivedCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(.systemGray))
                    }
                }
                .buttonStyle(SidebarRowStyle())
                .padding(.top, 6)

                if !archivedCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(archivedConversations, id:\.self) { conversation in
                            conversationRow(conversation)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .frame(width: 1)
                            .padding(.vertical, 3)
                    }
                }
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
    }
}


#Preview {
    ConversationHistoryList(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onTap: {_ in}, onDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
