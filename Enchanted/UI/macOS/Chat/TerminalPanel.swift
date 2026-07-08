//
//  TerminalPanel.swift
//  Enchanted
//
//  VS Code-style embedded terminal panel: a resizable bottom panel with a
//  tab bar of real PTY terminals backed by SwiftTerm's LocalProcessTerminalView.
//

#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Model

/// A single terminal instance. Owns its `LocalProcessTerminalView` (a real PTY
/// running the user's login shell) so terminal state survives tab switches and
/// SwiftUI redraws.
@Observable
final class TerminalTab: Identifiable {
    let id = UUID()
    var title: String
    /// Set to true when the underlying shell process exits.
    var terminated = false

    /// Held outside of observation — it's an NSView we hand to the representable.
    @ObservationIgnored let terminalView: LocalProcessTerminalView

    private let coordinator = Coordinator()

    init(index: Int, workingDirectory: String?) {
        let shell = TerminalTab.userShell()
        title = (shell as NSString).lastPathComponent

        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Use macOS system text colors so the terminal tracks light/dark mode.
        tv.configureNativeColors()
        self.terminalView = tv
        coordinator.owner = self
        tv.processDelegate = coordinator

        // Spawn the shell in the requested directory. posix_spawn inherits the
        // parent's cwd, so temporarily switch it around the launch.
        let fm = FileManager.default
        let previous = fm.currentDirectoryPath
        if let wd = workingDirectory, fm.fileExists(atPath: wd) {
            fm.changeCurrentDirectoryPath(wd)
        }
        let shellName = (shell as NSString).lastPathComponent
        tv.startProcess(executable: shell, args: [], environment: nil, execName: "-\(shellName)")
        fm.changeCurrentDirectoryPath(previous)
    }

    static func userShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    /// Bridges SwiftTerm's delegate callbacks back into the observable tab.
    private final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: TerminalTab?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory else { return }
            let name = (directory as NSString).lastPathComponent
            DispatchQueue.main.async { self.owner?.title = name.isEmpty ? "/" : name }
        }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard !title.isEmpty else { return }
            DispatchQueue.main.async { self.owner?.title = title }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                guard let owner = self.owner else { return }
                owner.terminated = true
                TerminalStore.shared.close(owner)
            }
        }
    }
}

// MARK: - Store

/// Per-conversation terminal state: its own tabs, active tab and visibility.
/// Terminals are "session-level" — switching conversations swaps the whole set.
@Observable
@MainActor
final class TerminalSession {
    var tabs: [TerminalTab] = []
    var activeTabID: TerminalTab.ID?
    var isVisible = false
}

@Observable
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()

    /// Sessions keyed by conversation id (or "new" for the empty state).
    private var sessions: [String: TerminalSession] = [:]
    /// Key of the conversation currently shown in the UI.
    private(set) var currentKey: String = TerminalStore.newKey
    /// Panel height in points — a global UI preference, shared across sessions.
    var panelHeight: CGFloat = 260

    private var counter = 0
    private static let newKey = "new"

    private func session(_ key: String) -> TerminalSession {
        if let s = sessions[key] { return s }
        let s = TerminalSession()
        sessions[key] = s
        return s
    }

    /// The session for the conversation being displayed.
    private var current: TerminalSession { session(currentKey) }

    var tabs: [TerminalTab] { current.tabs }

    var activeTab: TerminalTab? {
        current.tabs.first { $0.id == current.activeTabID } ?? current.tabs.first
    }

    /// Whether the panel is visible for the *current* conversation.
    var isVisible: Bool {
        get { current.isVisible }
        set { current.isVisible = newValue }
    }

    /// Point the store at a conversation. The panel automatically reflects that
    /// conversation's own terminals and visibility.
    func setConversation(_ id: UUID?) {
        currentKey = id?.uuidString ?? TerminalStore.newKey
    }

    /// Toggle the panel for the current conversation. Opening with no tabs
    /// creates the first one.
    func toggle() {
        let s = current
        if s.isVisible {
            s.isVisible = false
        } else {
            if s.tabs.isEmpty { newTab() }
            s.isVisible = true
        }
    }

    @discardableResult
    func newTab() -> TerminalTab {
        counter += 1
        let s = current
        let tab = TerminalTab(index: counter, workingDirectory: workingDirectory())
        s.tabs.append(tab)
        s.activeTabID = tab.id
        s.isVisible = true
        return tab
    }

    func close(_ tab: TerminalTab) {
        tab.terminalView.processDelegate = nil
        // The tab may belong to a session the user has since switched away from.
        for s in sessions.values where s.tabs.contains(where: { $0.id == tab.id }) {
            s.tabs.removeAll { $0.id == tab.id }
            if s.activeTabID == tab.id { s.activeTabID = s.tabs.last?.id }
            // Auto-hide the panel once this session's last tab is gone.
            if s.tabs.isEmpty { s.isVisible = false }
        }
    }

    func select(_ tab: TerminalTab) {
        current.activeTabID = tab.id
    }

    /// Working directory for a new terminal: the current conversation's project
    /// directory when available, otherwise the workspace default.
    private func workingDirectory() -> String {
        if let conv = ConversationStore.shared.selectedConversation {
            return conv.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        }
        return WorkspaceStore.shared.currentDirectory
    }
}

// MARK: - PTY view wrapper

private struct TerminalViewWrapper: NSViewRepresentable {
    let tab: TerminalTab
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        tab.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Match the app's light/dark appearance and re-resolve system colors so
        // the terminal background/foreground track the theme.
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if nsView.appearance != appearance {
            nsView.appearance = appearance
            appearance?.performAsCurrentDrawingAppearance {
                nsView.configureNativeColors()
            }
            nsView.getTerminal().updateFullScreen()
            nsView.needsDisplay = true
        }
        // Grab keyboard focus when this tab becomes the visible one.
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

// MARK: - Panel UI

struct TerminalPanelView: View {
    @State private var store = TerminalStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var panelBackground: SwiftUI.Color {
        colorScheme == .dark ? SwiftUI.Color(nsColor: .init(white: 0.11, alpha: 1)) : SwiftUI.Color(nsColor: .textBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            tabBar
            Divider()
            terminalContent
        }
        .background(panelBackground)
        .overlay(alignment: .top) {
            Divider()
        }
        .frame(height: store.panelHeight)
        .transition(.move(edge: .bottom))
    }

    // Draggable top edge to resize the panel height.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let new = store.panelHeight - value.translation.height
                        store.panelHeight = min(max(new, 120), 700)
                    }
            )
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            Button(action: { store.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New terminal")

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { store.isVisible = false } }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide terminal")
            .padding(.trailing, 4)
        }
        .frame(height: 30)
    }

    private func tabButton(_ tab: TerminalTab) -> some View {
        let isActive = tab.id == store.activeTab?.id
        return HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { store.close(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Close terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
        )
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
    }

    @ViewBuilder private var terminalContent: some View {
        ZStack {
            ForEach(store.tabs) { tab in
                TerminalViewWrapper(tab: tab, colorScheme: colorScheme)
                    .opacity(tab.id == store.activeTab?.id ? 1 : 0)
                    .allowsHitTesting(tab.id == store.activeTab?.id)
            }
        }
    }
}
#endif
