//
//  ToolsCommands.swift
//  Enchanted
//
//  App-level keyboard shortcuts for the right sidebar tools. Implemented as a
//  native `CommandMenu` so the shortcuts:
//    • appear in the menu bar with their key hints,
//    • are handled at the application level (single source of truth),
//    • only fire with their modifier combos — so typing plain text in the
//      composer or a terminal never triggers them accidentally.
//
//  Keep the key equivalents here in sync with `RightSidebarTool.shortcutHint`.
//

#if os(macOS)
import SwiftUI

struct ToolsCommands: Commands {
    // Observe the store so rebinding a shortcut in Settings updates the menu.
    @ObservedObject private var store = ShortcutStore.shared

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Review") {
                RightSidebarStore.shared.activate(.review)
            }
            .shortcut(store.effective("review"))

            Button("Browser") {
                RightSidebarStore.shared.activate(.browser)
            }
            .shortcut(store.effective("browser"))

            Button("Side Chat") {
                RightSidebarStore.shared.activate(.sideChat)
            }
            .shortcut(store.effective("sideChat"))

            Divider()

            Button("Terminal") {
                TerminalStore.shared.reveal()
            }
            .shortcut(store.effective("terminal"))

            Button("Toggle Tool Sidebar") {
                RightSidebarStore.shared.toggle()
            }
            .shortcut(store.effective("toolSidebar"))
        }
    }
}
#endif
