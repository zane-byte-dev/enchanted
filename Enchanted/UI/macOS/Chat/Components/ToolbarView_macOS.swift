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
    var onNewConversationTap: () -> ()
    var copyChat: (_ json: Bool) -> ()
    
    @State private var workspace = WorkspaceStore.shared

    var body: some View {
        WorkingDirectoryButton(workspace: workspace)
            .frame(height: 20)

        ModelSelectorView(
            modelsList: modelsList,
            selectedModel: selectedModel,
            onSelectModel: onSelectModel,
            showChevron: false
        )
        .frame(height: 20)
        
        MoreOptionsMenuView(copyChat: copyChat)
        
        Button(action: onNewConversationTap) {
            Image(systemName: "square.and.pencil")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .padding(5)
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(KeyEquivalent("n"), modifiers: .command)
    }
}

/// Folder picker showing the working directory of the selected conversation
/// (or the default for new conversations when none is selected).
struct WorkingDirectoryButton: View {
    @Bindable var workspace: WorkspaceStore
    @State private var conversationStore = ConversationStore.shared

    private var currentPath: String {
        conversationStore.selectedConversation?.workingDirectory ?? workspace.currentDirectory
    }

    var body: some View {
        Button(action: pickDirectory) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .help(currentPath)
    }

    private func pickDirectory() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the project directory the agent works in"
        panel.directoryURL = URL(fileURLWithPath: currentPath)
        if panel.runModal() == .OK, let url = panel.url {
            if let conversation = conversationStore.selectedConversation {
                conversationStore.setWorkingDirectory(url.path, for: conversation)
            } else {
                // No conversation selected → set the default for new ones.
                workspace.setDirectory(url.path)
            }
        }
#endif
    }
}

#Preview {
    ToolbarView(
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0],
        onSelectModel: {_ in},
        onNewConversationTap: {}, 
        copyChat: {_ in}
    )
}

#endif
