//
//  Chat.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

#if os(macOS) || os(visionOS)
import SwiftUI

struct ChatView: View {
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var messages: [MessageSD]
    var modelsList: [LanguageModelSD]
    var onMenuTap: () -> ()
    var onNewConversationTap: () -> ()
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ images: [Image], _ trimmingMessageId: String?) -> ()
    var onConversationTap: (_ conversation: ConversationSD) -> ()
    var conversationState: ConversationState
    var onStopGenerateTap: @MainActor () -> ()
    var reachable: Bool
    var modelSupportsImages: Bool
    var selectedModel: LanguageModelSD?
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    var onConversationDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()
    var userInitials: String
    var copyChat: (_ json: Bool) -> ()
    var stats: PiSessionStats? = nil
    var onSteer: @MainActor (_ message: String) -> Void = { _ in }
    var onFollowUp: @MainActor (_ message: String, _ images: [Image]) -> Void = { _, _ in }
    var onNewConversationInProject: (_ path: String) -> () = { _ in }
    var showSkills: Bool = false
    
    @State private var message = ""
    @State private var editMessage: MessageSD?
    @State private var appStore = AppStore.shared
    @State private var sharedConversationStore = ConversationStore.shared
    @State private var inputFocusTrigger = 0
    @State private var composerResetGeneration = 0
    @FocusState private var isFocusedInput: Bool
#if os(macOS)
    @State private var renamingCurrent: ConversationSD?
    @State private var renameText = ""
    @State private var selectedSkill: PiSkill?
    @State private var conversationPendingDeletion: ConversationSD?
#endif
#if os(macOS)
    @State private var terminalStore = TerminalStore.shared
    @State private var rightSidebarStore = RightSidebarStore.shared
#endif

    @ViewBuilder private func composer(slashPalettePlacement: SlashPalettePlacement = .above) -> some View {
        InputFieldsView(
            message: $message,
            conversationState: conversationState,
            onStopGenerateTap: onStopGenerateTap,
            selectedModel: selectedModel,
            modelsList: modelsList,
            onSelectModel: onSelectModel,
            onSendMessageTap: onSendMessageTap,
            stats: stats,
            onSteer: onSteer,
            onFollowUp: onFollowUp,
            focusTrigger: inputFocusTrigger,
            slashPalettePlacement: slashPalettePlacement,
            editMessage: $editMessage
        )
        .id(composerIdentity)
    }

    private var conversationIdentity: String {
        selectedConversation?.id.uuidString ?? "new"
    }

    private var composerIdentity: String {
        "\(conversationIdentity)-\(composerResetGeneration)"
    }

    private func resetComposerState(focusInput: Bool = false) {
        message = ""
        editMessage = nil
        composerResetGeneration += 1
        if focusInput {
            inputFocusTrigger += 1
        }
    }

    private func startNewConversation() {
        resetComposerState(focusInput: true)
        onNewConversationTap()
    }

    private func requestDelete(_ conversation: ConversationSD) {
#if os(macOS)
        conversationPendingDeletion = conversation
#else
        onConversationDelete(conversation)
#endif
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedConversation: selectedConversation,
                conversations: conversations,
                onConversationTap: onConversationTap,
                onConversationDelete: requestDelete,
                onDeleteDailyConversations: onDeleteDailyConversations,
                onNewConversation: startNewConversation,
                onNewConversationInProject: onNewConversationInProject
            )
            .toolbar {
#if os(visionOS)
                ToolbarItemGroup(placement:.navigationBarTrailing) {
                    Button(action: {
                        withAnimation(.easeIn(duration: 0.3)) {
                            columnVisibility = .detailOnly
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .showIf(columnVisibility != .detailOnly)
                }
                
#endif
            }
        } detail: {
            detailContent
        }
        .navigationTitle("")
#if os(macOS)
        .overlay(alignment: .bottom) {
            if sharedConversationStore.canUndoDeletion {
                HStack(spacing: 12) {
                    Text("Conversation deleted")
                        .font(.system(size: 13, weight: .medium))
                    Button("Undo") {
                        Task { await sharedConversationStore.undoLastDeletion() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(CodexTheme.border))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sharedConversationStore.canUndoDeletion)
#endif
        .overlay {
#if os(macOS) || os(visionOS)
            if appStore.showConversationSearch {
                conversationSearchOverlay
            }
#if os(macOS)
            if let selectedSkill {
                SkillDetailOverlay(
                    skill: selectedSkill,
                    onClose: {
                        self.selectedSkill = nil
                    },
                    onTryInChat: {
                        useSkillInChat(selectedSkill)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
#endif
#endif
        }
        .onChange(of: editMessage, initial: false) { _, newMessage in
            if let newMessage = newMessage {
                message = newMessage.content
                isFocusedInput = true
            }
        }
#if os(macOS)
        .onChange(of: selectedConversation?.id, initial: true) { _, newID in
            resetComposerState()
            terminalStore.setConversation(newID)
            rightSidebarStore.setConversation(newID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmdNewChat)) { _ in
            startNewConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmdToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = (columnVisibility == .detailOnly) ? .doubleColumn : .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmdRenameChat)) { _ in
            if let c = selectedConversation {
                renameText = c.name
                renamingCurrent = c
            }
        }
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingCurrent != nil },
            set: { if !$0 { renamingCurrent = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingCurrent = nil }
            Button("Rename") {
                if let c = renamingCurrent { ConversationStore.shared.rename(c, to: renameText) }
                renamingCurrent = nil
            }
        }
        .alert("Delete Conversation?", isPresented: Binding(
            get: { conversationPendingDeletion != nil },
            set: { if !$0 { conversationPendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { conversationPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let conversation = conversationPendingDeletion {
                    onConversationDelete(conversation)
                }
                conversationPendingDeletion = nil
            }
        } message: {
            Text("This removes the conversation and its local transcript. You can undo for 10 seconds.")
        }
#endif
    }

#if os(macOS) || os(visionOS)
    private var conversationSearchOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    appStore.showConversationSearch = false
                }

            ConversationSearchPanel(
                conversations: conversations,
                onConversationTap: { conversation in
                    appStore.showConversationSearch = false
                    onConversationTap(conversation)
                },
                onNewConversation: {
                    appStore.showConversationSearch = false
                    startNewConversation()
                },
                onDismiss: {
                    appStore.showConversationSearch = false
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CodexTheme.border.opacity(0.8), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 18)
            .onTapGesture {}
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.14), value: appStore.showConversationSearch)
    }
#endif

#if os(macOS)
    private func useSkillInChat(_ skill: PiSkill) {
        selectedSkill = nil
        appStore.showSkills = false
        let invocation = "/skill:\(skill.name)"
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.isEmpty {
            message = "\(invocation) "
        } else if !trimmedMessage.hasPrefix(invocation) {
            message = "\(invocation) \(message)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            inputFocusTrigger += 1
        }
    }
#endif

    @ViewBuilder private var detailContent: some View {
#if os(macOS)
        if showSkills {
            SkillsMacOS(selectedSkill: $selectedSkill)
        } else {
            chatWithPanels
        }
#else
        VStack(spacing: 0) {
            chatDetail
        }
#endif
    }

#if os(macOS)
    @ViewBuilder private var chatWithPanels: some View {
        // Manual width management (fixed frame + custom resize handle) is the
        // only way to make the width per-conversation: native HSplitView /
        // inspector keep a single divider position that ignores each chat's
        // stored width. The panel owns its resize handle (see RightSidebarPanelView).
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                chatDetail
                if terminalStore.isVisible {
                    TerminalPanelView()
                }
            }
            if rightSidebarStore.isVisible {
                RightSidebarPanelView()
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodexTheme.appBackground.ignoresSafeArea())
    }
#endif

    @ViewBuilder private var chatDetail: some View {
            VStack(alignment: .center, spacing: 0) {
                if selectedConversation != nil {
                    MessageListView(
                        conversationID: selectedConversation?.id,
                        messages: messages,
                        conversationState: conversationState,
                        userInitials: userInitials,
                        editMessage: $editMessage
                    )

                    if !reachable {
                        UnreachableAPIView()
                    }

                    VStack(spacing: 2) {
                        composer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 820)
                } else {
                    Spacer()
                    Text("What should we do?")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(CodexTheme.primaryText.opacity(0.9))
                        .padding(.bottom, 26)

                    if !reachable {
                        UnreachableAPIView()
                    }

                    VStack(spacing: 2) {
                        composer(slashPalettePlacement: .below)
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CodexTheme.appBackground)
            .toolbar {
                #if os(visionOS)
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(action: {
                        withAnimation {
                            columnVisibility = .automatic
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .showIf(columnVisibility == .detailOnly)
                    
                    Text("Enchanted")
                }
                #else
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        navigationTitleView
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        navigationTitleView
                    }
                }
                #endif

                if #available(macOS 26.0, *) {
                    ToolbarItemGroup(placement: .automatic) {
                        ToolbarView(
                            modelsList: modelsList,
                            selectedModel: selectedModel,
                            onSelectModel: onSelectModel,
                            copyChat: copyChat
                        )
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItemGroup(placement: .automatic) {
                        ToolbarView(
                            modelsList: modelsList,
                            selectedModel: selectedModel,
                            onSelectModel: onSelectModel,
                            copyChat: copyChat
                        )
                    }
                }
            }
    }

#if os(macOS)
    private var navigationTitleText: String {
        showSkills ? String(localized: "技能管理") : (selectedConversation?.name ?? "")
    }

    private var navigationTitleIcon: String {
        showSkills ? "puzzlepiece.extension" : "bubble.left"
    }

    private var shouldShowTitleMenu: Bool {
        !showSkills && selectedConversation != nil
    }

    private var navigationTitleView: some View {
        HStack(spacing: 8) {
            Image(systemName: navigationTitleIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CodexTheme.mutedText)
                .frame(width: 18, height: 18)

            Text(navigationTitleText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(CodexTheme.primaryText.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320, alignment: .leading)

            if shouldShowTitleMenu {
                MoreOptionsMenuView(
                    conversation: selectedConversation,
                    copyChat: copyChat,
                    onRename: {
                        guard let conversation = selectedConversation else { return }
                        renameText = conversation.name
                        renamingCurrent = conversation
                    },
                    onDelete: requestDelete
                )
            }
        }
        .padding(.leading, 10)
        .frame(maxWidth: 390, alignment: .leading)
    }
#endif
}

#Preview {
    ChatView(
        selectedConversation: ConversationSD.sample[0],
        conversations: ConversationSD.sample,
        messages: MessageSD.sample,
        modelsList: LanguageModelSD.sample,
        onMenuTap: {},
        onNewConversationTap: { },
        onSendMessageTap: {_,_,_,_    in},
        onConversationTap: {_ in},
        conversationState: .completed,
        onStopGenerateTap: {},
        reachable: true,
        modelSupportsImages: true,
        selectedModel: LanguageModelSD.sample[0], onSelectModel: {_ in},
        onConversationDelete: {_ in},
        onDeleteDailyConversations: {_ in},
        userInitials: "AM",
        copyChat: {_ in}
    )
}
#endif
