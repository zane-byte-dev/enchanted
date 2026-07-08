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
    var body: some Commands {
        CommandMenu("Tools") {
            Button("Review") {
                RightSidebarStore.shared.activate(.review)
            }
            .keyboardShortcut("g", modifiers: [.control, .shift]) // ⌃⇧G

            Button("Browser") {
                RightSidebarStore.shared.activate(.browser)
            }
            .keyboardShortcut("t", modifiers: .command) // ⌘T

            Button("Side Chat") {
                RightSidebarStore.shared.activate(.sideChat)
            }
            .keyboardShortcut("s", modifiers: [.option, .command]) // ⌥⌘S

            Divider()

            Button("Terminal") {
                TerminalStore.shared.reveal()
            }
            .keyboardShortcut("`", modifiers: .control) // ⌃`

            Button("Toggle Tool Sidebar") {
                RightSidebarStore.shared.toggle()
            }
            .keyboardShortcut("b", modifiers: [.option, .command]) // ⌥⌘B
        }
    }
}
#endif
