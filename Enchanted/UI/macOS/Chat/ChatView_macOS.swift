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
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ image: Image?, _ trimmingMessageId: String?) -> ()
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
    var onRefresh: () -> () = {}
    
    @State private var message = ""
    @State private var editMessage: MessageSD?
    @State var isRecording = false
    @FocusState private var isFocusedInput: Bool

    @ViewBuilder private var composer: some View {
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
            editMessage: $editMessage
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedConversation: selectedConversation,
                conversations: conversations,
                onConversationTap: onConversationTap,
                onConversationDelete: onConversationDelete,
                onDeleteDailyConversations: onDeleteDailyConversations,
                onNewConversation: onNewConversationTap,
                onRefresh: onRefresh
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
            VStack(alignment: .center) {
                if selectedConversation != nil {
                    MessageListView(
                        messages: messages,
                        conversationState: conversationState,
                        userInitials: userInitials,
                        editMessage: $editMessage
                    )

                    if !reachable {
                        UnreachableAPIView()
                    }

                    composer
                        .padding()
                        .frame(maxWidth: 800)
                } else {
                    // Codex-style new-conversation empty state
                    Spacer()
                    Text("What should we do?")
                        .font(.system(size: 32, weight: .semibold))
                        .padding(.bottom, 28)

                    if !reachable {
                        UnreachableAPIView()
                    }

                    VStack(spacing: 2) {
                        composer
                        HStack {
                            ChooseProjectRow()
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal)

                    Spacer()
                    Spacer()
                }
            }
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
                ToolbarItem(placement: .navigation) {
                    Text("Enchanted")
                }
                #endif

                
                ToolbarItemGroup(placement: .automatic) {
                    ToolbarView(
                        modelsList: modelsList,
                        selectedModel: selectedModel,
                        onSelectModel: onSelectModel,
                        onNewConversationTap: onNewConversationTap,
                        copyChat: copyChat
                    )
                }
            }
        }
        .navigationTitle("")
        .onChange(of: editMessage, initial: false) { _, newMessage in
            if let newMessage = newMessage {
                message = newMessage.content
                isFocusedInput = true
            }
        }
    }
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
