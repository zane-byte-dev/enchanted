//
//  SidebarView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI

struct SidebarView: View {
    @Environment(\.openWindow) var openWindow
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var onConversationTap: (_ conversation: ConversationSD) -> ()
    var onConversationDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()
    var onNewConversation: () -> () = {}
    @State var showSettings = false
    @State var showCompletions = false
    @State var showKeyboardShortcutas = false
    @State private var searchText = ""

    private var filteredConversations: [ConversationSD] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return conversations }
        return conversations.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    
    private func onSettingsTap() {
        Task {
            showSettings.toggle()
            await Haptics.shared.mediumTap()
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top actions
            VStack(spacing: 2) {
                SidebarButton(title: "New Chat", image: "square.and.pencil", onClick: onNewConversation)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(Color(.systemGray))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(.systemGray))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .padding(.bottom, 8)

            ScrollView() {
                ConversationHistoryList(
                    selectedConversation: selectedConversation,
                    conversations: filteredConversations,
                    onTap: onConversationTap,
                    onDelete: onConversationDelete,
                    onDeleteDailyConversations: onDeleteDailyConversations
                )
            }
            .scrollIndicators(.never)
            
            Divider()
            
#if os(macOS)
            SidebarButton(title: "Completions", image: "textformat.abc", onClick: {showCompletions.toggle()})
            
            SidebarButton(title: "Shortcuts", image: "keyboard.fill", onClick: {showKeyboardShortcutas.toggle()})
#endif
            
            SidebarButton(title: "Settings", image: "gearshape.fill", onClick: onSettingsTap)
            
        }
        .padding()
#if os(macOS)
        .focusedSceneValue(\.showSettings, $showSettings)
#endif
        .sheet(isPresented: $showSettings) {
            Settings()
        }
#if os(macOS)
        .sheet(isPresented: $showCompletions) {
            CompletionsEditor()
        }
        .sheet(isPresented: $showKeyboardShortcutas) {
            KeyboardShortcutsDemo()
        }
#endif
        
    }
}

#Preview {
    SidebarView(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onConversationTap: {_ in}, onConversationDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
