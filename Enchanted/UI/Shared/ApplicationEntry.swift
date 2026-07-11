//
//  ApplicationEntry.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/02/2024.
//

import SwiftUI
import SwiftData

#if os(macOS)
/// Sets the host NSWindow's background color once, so every detail area
/// (chat, skills, settings) shares one white base while the sidebar keeps its
/// own vibrant material. Unified alternative to per-page `.background(...)`.
private struct WindowBackgroundSetter: NSViewRepresentable {
    var color: NSColor
    var revision: Int
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.backgroundColor = color }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.backgroundColor = color }
    }
}
#endif

struct ApplicationEntry: View {
    @AppStorage("colorScheme") private var colorScheme: AppColorScheme = .system
#if os(macOS)
    @AppStorage(ThemePreferences.revisionKey) private var themeRevision = 0
#endif
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
#if os(macOS)
        .background(
            WindowBackgroundSetter(
                color: NSColor(CodexTheme.appBackground),
                revision: themeRevision
            )
        )
        .tint(CodexTheme.accent)
        .foregroundStyle(CodexTheme.primaryText)
#endif
        .task {
            
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                print("Bundle Identifier: \(bundleIdentifier)")
            } else {
                print("Bundle Identifier not found.")
            }
            
            // Reclaim idle pi processes to free memory (context restored on
            // next use via switch_session).
            conversationStore.startIdleReaper()
            NotificationService.shared.prepare()

            // One-time migration: strip whole-file `read`/`grep` results from
            // existing message blocks so old conversations don't carry the
            // megabyte payloads that caused the return-from-background white
            // screen. New turns already drop them at write time.
            Task.detached {
                try? await SwiftDataService.shared.migrateReadOnlyToolResults()
            }

            // Installation diagnostics and model discovery both start a short-lived
            // pi RPC process. Sequence them so a cold launch cannot leave the model
            // picker empty because the two handshakes raced each other.
            await appStore.refreshReachability()

            do {
                try await languageModelStore.loadModels()
            } catch {
                // pi can need a moment to release its startup/session resources after
                // diagnostics. Retry once before surfacing an empty model list.
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    try await languageModelStore.loadModels()
                } catch {
                    print("Unable to load models after retry: \(error).")
                }
            }

            do {
                try await conversationStore.loadConversations()
                // One-time: shorten pre-existing over-long titles.
                await conversationStore.migrateLongTitlesIfNeeded()
            } catch {
                print("Unable to load conversations: \(error).")
            }

            ScheduledTaskStore.shared.start()
        }
        .preferredColorScheme(colorScheme.toiOSFormat)
    }
}
