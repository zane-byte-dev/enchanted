//
//  ApplicationEntry.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/02/2024.
//

import SwiftUI
import SwiftData

struct ApplicationEntry: View {
    @AppStorage("colorScheme") private var colorScheme: AppColorScheme = .system
    @State private var languageModelStore = LanguageModelStore.shared
    @State private var conversationStore = ConversationStore.shared
    @State private var appStore = AppStore.shared
    
    var body: some View {
        VStack {
            switch appStore.appState {
            case .chat:
                Chat(languageModelStore: languageModelStore, conversationStore: conversationStore, appStore: appStore)
            case .voice:
                Voice(languageModelStore: languageModelStore, conversationStore: conversationStore, appStore: appStore)
            }
        }
        .task {
            
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                print("Bundle Identifier: \(bundleIdentifier)")
            } else {
                print("Bundle Identifier not found.")
            }
            
            Task.detached {
                async let loadModels: () = languageModelStore.loadModels()
                async let loadConversations: () = conversationStore.loadConversations()
                
                do {
                    _ = try await loadModels
                    _ = try await loadConversations
                    // Surface pi sessions created elsewhere (VS Code / CLI).
                    await conversationStore.syncPiSessions()
                } catch {
                    print("Unexpected error: \(error).")
                }
            }

            // Poll for external pi session changes (new tasks / new messages).
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await conversationStore.syncPiSessions()
                }
            }
        }
        .preferredColorScheme(colorScheme.toiOSFormat)
    }
}

