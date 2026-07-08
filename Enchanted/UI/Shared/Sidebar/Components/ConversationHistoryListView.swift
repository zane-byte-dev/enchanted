//
//  ConversationHistoryList.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI

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
    
    @State private var collapsed: Set<String> = []

    func groupConversationsByProject(_ conversations: [ConversationSD]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: conversations) { conversation in
            conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        }
        return grouped.map { (path, convs) in
            ProjectGroup(path: path, conversations: convs.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { $0.mostRecent > $1.mostRecent }
    }

    var projectGroups: [ProjectGroup] {
        groupConversationsByProject(conversations)
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
                        Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(.systemGray))
                    }
                }
                .buttonStyle(SidebarRowStyle())
                .help(group.path)

                // Conversations under this project
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.conversations, id:\.self) { conversation in
                            Button(action: { onTap(conversation) }) {
                                HStack(spacing: 6) {
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
                                Button(role: .destructive, action: { onDelete(conversation) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            })
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
    }
}


#Preview {
    ConversationHistoryList(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onTap: {_ in}, onDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
