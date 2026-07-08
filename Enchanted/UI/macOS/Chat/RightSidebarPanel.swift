//
//  RightSidebarPanel.swift
//  Enchanted
//
//  A multi-purpose right sidebar tool panel. It slides in from the trailing
//  edge and hosts a vertical tool navigation list (review, terminal, browser,
//  side chat). Each row shows an icon, a label and a right-aligned
//  keyboard-shortcut hint. Selecting a tool activates the matching feature
//  panel (e.g. the bottom terminal) or shows the tool's inline view.
//

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Tool model

/// A single feature exposed in the right sidebar. Metadata (label, icon and
/// the human-readable shortcut hint) lives here so the list UI and the global
/// keyboard-shortcut menu stay in sync.
enum RightSidebarTool: String, CaseIterable, Identifiable {
    case review
    case terminal
    case browser
    case sideChat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review:   return "Review"
        case .terminal: return "Terminal"
        case .browser:  return "Browser"
        case .sideChat: return "Side Chat"
        }
    }

    /// SF Symbol used as the category icon.
    var icon: String {
        switch self {
        case .review:   return "checklist"
        case .terminal: return "terminal"
        case .browser:  return "globe"
        case .sideChat: return "bubble.left.and.bubble.right"
        }
    }

    /// Human-readable shortcut hint shown right-aligned in each row. Keep this
    /// in sync with `ToolsCommands` where the shortcuts are actually bound.
    var shortcutHint: String {
        switch self {
        case .review:   return "⌃⇧G"
        case .terminal: return "⌃`"
        case .browser:  return "⌘T"
        case .sideChat: return "⌥⌘S"
        }
    }
}

// MARK: - Store

/// Per-conversation right sidebar state: its own visibility and active tool.
/// Like the terminal, switching conversations swaps the whole set.
@Observable
@MainActor
final class RightSidebarSession {
    var isVisible = false
    /// The tool whose inline view is being shown. `nil` shows the tool list.
    var activeInlineTool: RightSidebarTool? = nil
    /// This conversation's own sidebar width (points).
    var width: CGFloat = RightSidebarStore.defaultWidth
}

/// State for the right sidebar, shared by the toolbar toggle, the app-level
/// keyboard-shortcut menu, and the panel itself.
///
/// Visibility and the active inline tool are tracked *per conversation* (in
/// memory, mirroring `TerminalStore`) so each chat remembers whether its
/// sidebar was open and which tool it was showing. Switching conversations
/// swaps the whole set. The native `.inspector` binds to `isVisibleBinding`.
@Observable
@MainActor
final class RightSidebarStore {
    static let shared = RightSidebarStore()

    /// Width bounds (shared) and per-conversation default.
    static let defaultWidth: CGFloat = 300
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 520

    /// Sessions keyed by conversation id (or "new" for the empty state).
    private var sessions: [String: RightSidebarSession] = [:]
    /// Key of the conversation currently shown in the UI.
    private(set) var currentKey: String = RightSidebarStore.newKey

    private static let newKey = "new"
    private static let animation = Animation.easeInOut(duration: 0.25)

    private func session(_ key: String) -> RightSidebarSession {
        if let s = sessions[key] { return s }
        let s = RightSidebarSession()
        sessions[key] = s
        return s
    }

    /// The session for the conversation being displayed.
    private var current: RightSidebarSession { session(currentKey) }

    /// Whether the sidebar is shown for the current conversation.
    var isVisible: Bool {
        get { current.isVisible }
        set { current.isVisible = newValue }
    }

    /// The inline tool shown for the current conversation (`nil` = tool list).
    var activeInlineTool: RightSidebarTool? {
        get { current.activeInlineTool }
        set { current.activeInlineTool = newValue }
    }

    /// This conversation's sidebar width, clamped to the shared bounds.
    var width: CGFloat {
        get { current.width }
        set { current.width = min(max(newValue, Self.minWidth), Self.maxWidth) }
    }

    /// Point the store at a conversation so the panel reflects its own state.
    func setConversation(_ id: UUID?) {
        currentKey = id?.uuidString ?? Self.newKey
    }

    /// Toggle the whole sidebar (title-bar button / ⌥⌘B).
    func toggle() {
        withAnimation(Self.animation) {
            isVisible.toggle()
            if !isVisible { activeInlineTool = nil }
        }
    }

    /// Activate a tool. Terminal reveals + focuses the bottom terminal panel
    /// (independent of the sidebar); every other tool opens the sidebar and
    /// shows its inline view. Works identically whether triggered from a list
    /// row tap or from a global keyboard shortcut.
    func activate(_ tool: RightSidebarTool) {
        switch tool {
        case .terminal:
            TerminalStore.shared.reveal()
        default:
            withAnimation(Self.animation) {
                isVisible = true
                activeInlineTool = tool
            }
        }
    }

    /// Return from a tool's inline view back to the tool list.
    func backToList() {
        withAnimation(Self.animation) { activeInlineTool = nil }
    }
}

// MARK: - Panel UI

struct RightSidebarPanelView: View {
    @State private var store = RightSidebarStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var panelBackground: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(nsColor: .init(white: 0.13, alpha: 1))
            : SwiftUI.Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            VStack(spacing: 0) {
                if let tool = store.activeInlineTool {
                    inlineHeader(tool)
                    Divider()
                    RightSidebarToolContent(tool: tool)
                } else {
                    listHeader
                    Divider()
                    toolList
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: store.width)
        .background(panelBackground)
        .overlay(alignment: .leading) { Divider() }
    }

    /// Draggable leading edge to resize the panel width. AppKit-style: shows the
    /// resizeLeftRight cursor on hover and writes the new width straight into the
    /// current conversation's state (which clamps it to the allowed bounds), so
    /// each chat remembers its own width. Mirrors `TerminalPanelView`.
    private var resizeHandle: some View {
        SwiftUI.Color.clear
            .frame(width: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Dragging left (negative translation) widens the panel.
                        store.width -= value.translation.width
                    }
            )
    }

    // MARK: List mode

    private var listHeader: some View {
        HStack {
            Text("Tools")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { store.toggle() }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var toolList: some View {
        VStack(spacing: 2) {
            ForEach(RightSidebarTool.allCases) { tool in
                RightSidebarToolRow(tool: tool) { store.activate(tool) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: Inline tool mode

    private func inlineHeader(_ tool: RightSidebarTool) -> some View {
        HStack(spacing: 8) {
            Button(action: { store.backToList() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to tools")

            Image(systemName: tool.icon)
                .font(.system(size: 12))
            Text(tool.label)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { store.toggle() }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

/// A single tappable row: icon + label + right-aligned shortcut hint, with a
/// hover background highlight.
private struct RightSidebarToolRow: View {
    let tool: RightSidebarTool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(.primary)
                Text(tool.label)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text(tool.shortcutHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Placeholder content for tools that render inside the sidebar. Terminal is
/// handled separately (it reveals the bottom panel), so it is not shown here.
private struct RightSidebarToolContent: View {
    let tool: RightSidebarTool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: tool.icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(tool.label)
                .font(.system(size: 16, weight: .semibold))
            Text("This panel is coming soon.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
