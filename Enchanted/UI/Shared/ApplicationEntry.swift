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
            
            // Reclaim idle pi processes to free memory (context restored on
            // next use via switch_session).
            conversationStore.startIdleReaper()

            // One-time migration: strip whole-file `read`/`grep` results from
            // existing message blocks so old conversations don't carry the
            // megabyte payloads that caused the return-from-background white
            // screen. New turns already drop them at write time.
            Task.detached {
                try? await SwiftDataService.shared.migrateReadOnlyToolResults()
            }

            Task.detached {
                async let loadModels: () = languageModelStore.loadModels()
                async let loadConversations: () = conversationStore.loadConversations()
                
                do {
                    _ = try await loadModels
                    _ = try await loadConversations
                } catch {
                    print("Unexpected error: \(error).")
                }
            }
        }
        .preferredColorScheme(colorScheme.toiOSFormat)
    }
}

