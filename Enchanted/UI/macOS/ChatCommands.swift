//
//  ChatCommands.swift
//  Enchanted
//
//  App-level menu commands operating on the *current* chat (new/archive/pin/
//  rename/fork/copy) plus opening a project folder and toggling the sidebar.
//  Key equivalents come from `ShortcutStore` so they're user-rebindable.
//
//  View-dependent actions (new chat, toggle sidebar, rename) are dispatched via
//  NotificationCenter and handled in `ChatView`; the rest act directly on the
//  shared stores.
//

#if os(macOS)
import SwiftUI
import AppKit

extension Notification.Name {
    static let cmdNewChat       = Notification.Name("enchanted.cmd.newChat")
    static let cmdToggleSidebar = Notification.Name("enchanted.cmd.toggleSidebar")
    static let cmdRenameChat    = Notification.Name("enchanted.cmd.renameChat")
}

struct ChatCommands: Commands {
    // Observe the store so rebinding a shortcut updates the menu key equivalents.
    @ObservedObject private var store = ShortcutStore.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Chat") {
                NotificationCenter.default.post(name: .cmdNewChat, object: nil)
            }
            .shortcut(store.effective("newChat"))

            Button("Search Chats…") {
                AppStore.shared.showConversationSearch = true
            }
            .shortcut(store.effective("searchChats"))

            Button("Open Folder…") { openFolder() }
                .shortcut(store.effective("openFolder"))
        }

        CommandMenu("Chat") {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .cmdToggleSidebar, object: nil)
            }
            .shortcut(store.effective("toggleSidebar"))

            Button("Rename Chat…") {
                NotificationCenter.default.post(name: .cmdRenameChat, object: nil)
            }
            .shortcut(store.effective("renameChat"))

            Button("Archive Chat") {
                currentChat { ConversationStore.shared.toggleArchive($0) }
            }
            .shortcut(store.effective("archiveChat"))

            Button("Pin or Unpin Chat") {
                currentChat { ConversationStore.shared.togglePin($0) }
            }
            .shortcut(store.effective("pinChat"))

            Button("Fork Chat") {
                currentChat { c in Task { await ConversationStore.shared.forkToLocal(c) } }
            }
            .shortcut(store.effective("forkChat"))

            Divider()

            Button("Copy Working Directory") {
                currentChat { Clipboard.shared.setString(ConversationStore.shared.workingDirectory(for: $0)) }
            }
            .shortcut(store.effective("copyWorkingDir"))

            Button("Copy Session ID") {
                currentChat { Clipboard.shared.setString($0.id.uuidString) }
            }
            .shortcut(store.effective("copySessionId"))

            Button("Copy Deeplink") {
                currentChat { Clipboard.shared.setString(ConversationStore.deepLink(for: $0)) }
            }
            .shortcut(store.effective("copyDeeplink"))
        }
    }

    /// Run `body` with the currently selected conversation, on the main actor.
    private func currentChat(_ body: @escaping @MainActor (ConversationSD) -> Void) {
        Task { @MainActor in
            guard let c = ConversationStore.shared.selectedConversation else { return }
            body(c)
        }
    }

    /// Prompt for a project folder and point the workspace at it.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a project folder"
        panel.directoryURL = URL(fileURLWithPath: WorkspaceStore.shared.currentDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in WorkspaceStore.shared.setDirectory(url.path) }
        }
    }
}
#endif
