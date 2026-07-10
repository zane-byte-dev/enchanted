//
//  SidebarView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI

struct SidebarView: View {
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var onConversationTap: (_ conversation: ConversationSD) -> ()
    var onConversationDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()
    var onNewConversation: () -> () = {}
    var onNewConversationInProject: (_ path: String) -> () = { _ in }
    @State var showSettings = false   // iOS sheet / ⌘, focus binding
#if !os(macOS) && !os(visionOS)
    @State private var showSearch = false
#endif
    @AppStorage("appUserInitials") private var appUserInitials: String = ""
    
    private func onSkillsTap() {
        Task { await Haptics.shared.mediumTap() }
#if os(macOS)
        AppStore.shared.showSkills.toggle()
#endif
    }

    private func onSettingsTap() {
        Task { await Haptics.shared.mediumTap() }
#if os(macOS)
        AppStore.shared.showSettings = true
#else
        showSettings.toggle()
#endif
    }
    
    private var initialsLabel: String {
        let s = appUserInitials.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "?" : String(s.prefix(2)).uppercased()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top actions
            VStack(spacing: 2) {
                SidebarButton(title: String(localized: "New Chat"), image: "square.and.pencil", shortcutCommandID: "newChat", onClick: onNewConversation)

                SidebarButton(title: String(localized: "Search"), image: "magnifyingglass", shortcutCommandID: "searchChats") {
#if os(macOS) || os(visionOS)
                    AppStore.shared.showConversationSearch = true
#else
                    showSearch = true
#endif
                }

#if os(macOS)
                SidebarButton(title: "技能", image: "puzzlepiece.extension", onClick: onSkillsTap)
                    .padding(.top, 2)
#endif
            }
            .padding(.bottom, 8)

            ScrollView() {
                ConversationHistoryList(
                    selectedConversation: selectedConversation,
                    conversations: conversations,
                    onTap: onConversationTap,
                    onDelete: onConversationDelete,
                    onDeleteDailyConversations: onDeleteDailyConversations,
                    onNewConversationInProject: onNewConversationInProject
                )
            }
            .scrollIndicators(.never)
            
            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
            
            // Bottom: avatar button → open settings
            Button {
                onSettingsTap()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 28, height: 28)
                        Text(initialsLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    Text("Enchanted")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.86))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
        }
        .padding(12)
        .background(CodexTheme.sidebarBackground)
#if !os(macOS) && !os(visionOS)
        .sheet(isPresented: $showSearch) {
            ConversationSearchPanel(
                conversations: conversations,
                onConversationTap: { conversation in
                    showSearch = false
                    onConversationTap(conversation)
                },
                onNewConversation: {
                    showSearch = false
                    onNewConversation()
                },
                onDismiss: {
                    showSearch = false
                }
            )
        }
#endif
        .focusedSceneValue(\.showSettings, $showSettings)
        .onChange(of: showSettings) { _, newVal in
#if os(macOS)
            if newVal {
                showSettings = false
                AppStore.shared.showSettings = true
            }
#endif
        }
#if !os(macOS)
        .sheet(isPresented: $showSettings) {
            Settings()
        }
#endif
    }
}

#Preview {
    SidebarView(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onConversationTap: {_ in}, onConversationDelete: {_ in}, onDeleteDailyConversations: {_ in})
}

struct ConversationSearchPanel: View {
    let conversations: [ConversationSD]
    let onConversationTap: (_ conversation: ConversationSD) -> ()
    let onNewConversation: () -> ()
    let onDismiss: () -> ()

    @State private var searchText = ""
    @State private var projectStore = ProjectStore.shared
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private let panelWidth: CGFloat = 520
    private let panelHeight: CGFloat = 500
    private let resultsHeight: CGFloat = 388

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [ConversationSD] {
        let sorted = conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }

        guard !trimmedSearchText.isEmpty else {
            return Array(sorted.prefix(10))
        }

        return sorted.filter { conversation in
            let projectPath = conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
            let projectName = projectStore.displayName(for: projectPath)
            return conversation.name.localizedCaseInsensitiveContains(trimmedSearchText)
                || projectName.localizedCaseInsensitiveContains(trimmedSearchText)
                || projectPath.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private var selectedResultID: UUID? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader

            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if results.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, conversation in
                                resultRow(conversation, isSelected: index == selectedIndex)
                                    .id(conversation.id)
                                    .onHover { hovering in
                                        if hovering { selectedIndex = index }
                                    }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(height: resultsHeight)
                .onChange(of: selectedResultID) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }

            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)

            Button(action: onNewConversation) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                        .frame(width: 18, height: 18)
                    Text("New Chat")
                        .font(.system(size: 14))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(CodexTheme.surface)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: results.map(\.id)) { _, _ in
            clampSelectedIndex()
        }
        .onSubmit {
            selectCurrentResult()
        }
        .onKeyPress(.downArrow) {
            moveSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.return) {
            selectCurrentResult()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(CodexTheme.mutedText)
                .frame(width: 18, height: 18)
            TextField("Search chats or projects", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(CodexTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No chats found")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
            Text("Try another chat title or project name.")
                .font(.system(size: 12))
                .foregroundColor(CodexTheme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: resultsHeight - 20)
    }

    private func resultRow(_ conversation: ConversationSD, isSelected: Bool) -> some View {
        let projectPath = conversation.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        let projectName = projectStore.displayName(for: projectPath)

        return Button(action: { onConversationTap(conversation) }) {
            HStack(spacing: 10) {
                Image(systemName: conversation.isArchived ? "archivebox" : "bubble.left")
                    .font(.system(size: 14))
                    .foregroundColor(CodexTheme.mutedText)
                    .frame(width: 18, height: 18)
                Text(conversation.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(projectName)
                    .font(.system(size: 13))
                    .foregroundColor(CodexTheme.faintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
                Text(conversation.updatedAt.shortAgoString())
                    .font(.system(size: 12))
                    .foregroundColor(CodexTheme.faintText)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchResultRowStyle(isSelected: isSelected))
        .help(projectPath)
    }

    private func clampSelectedIndex() {
        if results.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= results.count {
            selectedIndex = results.count - 1
        }
    }

    private func moveSelection(delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    private func selectCurrentResult() {
        guard results.indices.contains(selectedIndex) else { return }
        onConversationTap(results[selectedIndex])
    }
}

private struct SearchResultRowStyle: ButtonStyle {
    var isSelected: Bool
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fillColor(configuration))
            )
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover || isSelected)
    }

    private func fillColor(_ configuration: Configuration) -> Color {
        if isSelected {
            return CodexTheme.rowSelected
        }
        if hover || configuration.isPressed {
            return CodexTheme.rowHover
        }
        return .clear
    }
}
