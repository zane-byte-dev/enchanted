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
    var onRefresh: () -> () = {}
    @State private var isRefreshing = false
    @State var showSettings = false
    @State private var showUserMenu = false
    @State private var searchText = ""
    @AppStorage("appUserInitials") private var appUserInitials: String = ""

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
    
    private var initialsLabel: String {
        let s = appUserInitials.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "?" : String(s.prefix(2)).uppercased()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top actions
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    SidebarButton(title: String(localized: "New Chat"), image: "square.and.pencil", onClick: onNewConversation)
                    Button(action: {
                        isRefreshing = true
                        onRefresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { isRefreshing = false }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(.systemGray))
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Sync pi sessions")
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color(.systemGray))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(.systemGray))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
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
            
            // Bottom: avatar button → popover menu
            Button {
                showUserMenu.toggle()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Text(initialsLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    Text("Enchanted")
                        .font(.system(size: 13))
                        .foregroundColor(Color(.label))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showUserMenu, arrowEdge: .top) {
                SidebarUserMenu(
                    onSettings: {
                        showUserMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showSettings = true
                        }
                    }
                )
            }
            
        }
        .padding()
#if os(macOS)
        .focusedSceneValue(\.showSettings, $showSettings)
#endif
        .sheet(isPresented: $showSettings) {
#if os(macOS)
            SettingsMacOS()
#else
            Settings()
#endif
        }
    }
}

#Preview {
    SidebarView(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onConversationTap: {_ in}, onConversationDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
