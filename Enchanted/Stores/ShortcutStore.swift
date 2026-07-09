//
//  ShortcutStore.swift
//  Enchanted
//
//  User-customizable keyboard shortcuts. Commands (menu items) read their key
//  equivalents from here, so rebinding in Settings takes effect live. Custom
//  bindings and explicit "unassigned" states are persisted in UserDefaults.
//

import SwiftUI
import Combine

/// A single key combination. `key` is the base character (e.g. "g", ",", "`");
/// the booleans are its modifier flags.
struct Shortcut: Codable, Equatable {
    var key: String
    var command: Bool = false
    var option: Bool = false
    var control: Bool = false
    var shift: Bool = false

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key.isEmpty ? " " : key))
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if option  { m.insert(.option) }
        if control { m.insert(.control) }
        if shift   { m.insert(.shift) }
        return m
    }

    /// Individual keycap symbols in macOS display order (⌃⌥⇧⌘ then the key).
    var displayKeys: [String] {
        var a: [String] = []
        if control { a.append("⌃") }
        if option  { a.append("⌥") }
        if shift   { a.append("⇧") }
        if command { a.append("⌘") }
        a.append(key.uppercased())
        return a
    }

    var hasModifier: Bool { command || option || control || shift }
}

/// Static metadata for one bindable command.
struct ShortcutCommandMeta: Identifiable {
    let id: String
    let title: String        // Chinese command name
    let subtitle: String     // English description
    let defaultShortcut: Shortcut?
}

final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// All bindable commands, in display order. Keep the ids in sync with
    /// `Menus.swift` / `ToolsCommands.swift`.
    static let all: [ShortcutCommandMeta] = [
        // Chat / conversation
        .init(id: "newChat",       title: "新对话",       subtitle: "Start a new chat",
              defaultShortcut: Shortcut(key: "n", command: true)),
        .init(id: "toggleSidebar", title: "切换边栏",     subtitle: "Show or hide the sidebar",
              defaultShortcut: Shortcut(key: "b", command: true)),
        .init(id: "archiveChat",   title: "归档聊天",     subtitle: "Archive the current chat",
              defaultShortcut: Shortcut(key: "a", command: true, shift: true)),
        .init(id: "pinChat",       title: "切换置顶状态", subtitle: "Pin or unpin the current chat",
              defaultShortcut: Shortcut(key: "p", command: true, option: true)),
        .init(id: "renameChat",    title: "重命名聊天",   subtitle: "Rename the current chat",
              defaultShortcut: Shortcut(key: "r", command: true, option: true)),
        .init(id: "forkChat",      title: "分叉聊天",     subtitle: "Fork the current chat",
              defaultShortcut: nil),
        .init(id: "openFolder",    title: "打开文件夹",   subtitle: "Add a local project",
              defaultShortcut: Shortcut(key: "o", command: true)),
        .init(id: "copyWorkingDir",title: "复制工作目录", subtitle: "Copy the current chat working directory",
              defaultShortcut: Shortcut(key: "c", command: true, shift: true)),
        .init(id: "copySessionId", title: "复制 Session ID", subtitle: "Copy the current chat session ID",
              defaultShortcut: Shortcut(key: "c", command: true, option: true)),
        .init(id: "copyDeeplink",  title: "复制 Deeplink",  subtitle: "Copy a deeplink to the current chat",
              defaultShortcut: Shortcut(key: "l", command: true, option: true)),

        // Tools
        .init(id: "review",      title: "代码评审",     subtitle: "Open code review",
              defaultShortcut: Shortcut(key: "g", control: true, shift: true)),
        .init(id: "browser",     title: "浏览器",       subtitle: "Open the in-app browser",
              defaultShortcut: Shortcut(key: "t", command: true)),
        .init(id: "sideChat",    title: "侧边聊天",     subtitle: "Open the side chat",
              defaultShortcut: Shortcut(key: "s", command: true, option: true)),
        .init(id: "terminal",    title: "终端",         subtitle: "Toggle the terminal",
              defaultShortcut: Shortcut(key: "`", control: true)),
        .init(id: "toolSidebar", title: "切换工具侧栏", subtitle: "Toggle the tools sidebar",
              defaultShortcut: Shortcut(key: "b", command: true, option: true)),

        // App
        .init(id: "settings",    title: "打开设置",     subtitle: "Open app settings",
              defaultShortcut: Shortcut(key: ",", command: true)),
    ]

    @Published private var custom: [String: Shortcut]
    @Published private var cleared: Set<String>

    private static let customKey = "shortcutCustomBindings"
    private static let clearedKey = "shortcutClearedBindings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            custom = decoded
        } else {
            custom = [:]
        }
        cleared = Set(UserDefaults.standard.stringArray(forKey: Self.clearedKey) ?? [])
    }

    func meta(_ id: String) -> ShortcutCommandMeta? { Self.all.first { $0.id == id } }

    /// The binding currently in effect: custom → default, unless explicitly cleared.
    func effective(_ id: String) -> Shortcut? {
        if cleared.contains(id) { return nil }
        if let c = custom[id] { return c }
        return meta(id)?.defaultShortcut
    }

    /// Whether this command differs from its factory default.
    func isCustomized(_ id: String) -> Bool {
        custom[id] != nil || cleared.contains(id)
    }

    /// The command (if any) already bound to this shortcut, excluding `excluding`.
    func conflict(with shortcut: Shortcut, excluding id: String) -> ShortcutCommandMeta? {
        Self.all.first { $0.id != id && effective($0.id) == shortcut }
    }

    func setShortcut(_ s: Shortcut, for id: String) {
        cleared.remove(id)
        custom[id] = s
        persist()
    }

    /// Explicitly unassign a command's shortcut.
    func clear(_ id: String) {
        custom[id] = nil
        cleared.insert(id)
        persist()
    }

    /// Restore a single command to its factory default.
    func reset(_ id: String) {
        custom[id] = nil
        cleared.remove(id)
        persist()
    }

    /// Restore all commands to their factory defaults.
    func resetAll() {
        custom = [:]
        cleared = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
        UserDefaults.standard.set(Array(cleared), forKey: Self.clearedKey)
    }
}

// MARK: - View helper

extension View {
    /// Bind an optional `Shortcut` to this view. Applies SwiftUI's built-in
    /// `keyboardShortcut(_:)` directly (not via a custom `ViewModifier`) so the
    /// menu/command builder reliably picks up the key equivalent. `nil` clears
    /// the shortcut (unassigned command). `SwiftUI.KeyboardShortcut` is fully
    /// qualified because a legacy type of the same name shadows it in this module.
    func shortcut(_ shortcut: Shortcut?) -> some View {
        keyboardShortcut(shortcut.map {
            SwiftUI.KeyboardShortcut($0.keyEquivalent, modifiers: $0.eventModifiers)
        })
    }
}
