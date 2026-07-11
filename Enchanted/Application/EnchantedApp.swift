//
//  EnchantedApp.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

import AppIntents
import SwiftData
import SwiftUI

#if os(macOS)
import KeyboardShortcuts
import OSLog
extension KeyboardShortcuts.Name {
    static let togglePanelMode = Self("togglePanelMode1", default: .init(.k, modifiers: [.command, .option]))
    static let voiceInput = Self("voiceInput", default: .init(.space, modifiers: [.option]))
}
#endif

@main
struct EnchantedApp: App {
    @State private var appStore = AppStore.shared
#if os(macOS)
    @NSApplicationDelegateAdaptor(PanelManager.self) var panelManager
#endif

    init() {
        AgentBackendConfig.configure()
#if os(macOS)
        // Register outside the window hierarchy so voice input still works when
        // every Enchanted window is closed and the app is running in background.
        KeyboardShortcuts.onKeyDown(for: .voiceInput) {
            Task { @MainActor in
                VoiceInputCoordinator.shared.shortcutKeyDown()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .voiceInput) {
            Task { @MainActor in
                VoiceInputCoordinator.shared.shortcutKeyUp()
            }
        }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "subj.Enchanted", category: "VoiceInput")
            .info("Global voice shortcut registered")
        Task { @MainActor in
            await VoiceInputCoordinator.shared.prewarm()
        }
#endif
    }
    
    var body: some Scene {
        WindowGroup {
            ApplicationEntry()
                .onOpenURL { url in
                    ConversationStore.shared.handleDeepLink(url)
                }
#if os(macOS)
                .onKeyboardShortcut(KeyboardShortcuts.Name.togglePanelMode, type: .keyDown) {
                    print("heya")
                    panelManager.togglePanel()
                }
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
#endif
        }
#if os(macOS)
        .commands {
            Menus()
            ToolsCommands()
            ChatCommands()
        }
#endif
#if os(macOS)
        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsDemo()
        }
#endif
        
#if os(macOS)
#if false
        MenuBarExtra {
            MenuBarControl()
        } label: {
            if let iconName = appStore.menuBarIcon {
                Image(systemName: iconName)
            } else {
                MenuBarControlView.icon
            }
        }
        .menuBarExtraStyle(.window)
#endif
#endif
    }
}
