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
import Combine
import WebKit

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
        case .review:   return String(localized: "Review")
        case .terminal: return String(localized: "Terminal")
        case .browser:  return String(localized: "Browser")
        case .sideChat: return String(localized: "Side Chat")
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

    /// The `ShortcutStore` command id backing this tool.
    var shortcutCommandID: String {
        switch self {
        case .review:   return "review"
        case .terminal: return "terminal"
        case .browser:  return "browser"
        case .sideChat: return "sideChat"
        }
    }

    /// Human-readable shortcut hint shown right-aligned in each row. Reads the
    /// live binding from `ShortcutStore` so custom keys are reflected here too.
    @MainActor
    var shortcutHint: String {
        ShortcutStore.shared.effective(shortcutCommandID)?.displayKeys.joined() ?? ""
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
    static let defaultWidth: CGFloat = 280
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
            Text(String(localized: "Tools"))
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
                    .foregroundStyle(CodexTheme.primaryText)
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

    @ViewBuilder
    var body: some View {
        switch tool {
        case .review:
            GitChangesView()
        case .browser:
            ProjectBrowserView()
        case .sideChat:
            SideChatView()
        case .terminal:
            EmptyView()
        }
    }
}

// MARK: - Project browser

@Observable
@MainActor
private final class ProjectBrowserModel: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: .zero)
    var address = "http://localhost:3000"
    var title = "Browser"
    var isLoading = false

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    func loadAddress() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if URL(string: value)?.scheme == nil { value = "http://" + value }
        guard let url = URL(string: value) else { return }
        address = value
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        address = webView.url?.absoluteString ?? address
        title = webView.title ?? "Browser"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

private struct ProjectWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ProjectBrowserView: View {
    @State private var model = ProjectBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: { model.webView.goBack() }) { Image(systemName: "chevron.left") }
                    .disabled(!model.webView.canGoBack)
                Button(action: { model.webView.goForward() }) { Image(systemName: "chevron.right") }
                    .disabled(!model.webView.canGoForward)
                Button(action: {
                    if model.isLoading {
                        model.webView.stopLoading()
                    } else {
                        model.webView.reload()
                    }
                }) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                TextField("http://localhost:3000", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.loadAddress() }
                Button(action: model.loadAddress) { Image(systemName: "arrow.right") }
            }
            .buttonStyle(.plain)
            .padding(8)
            Divider()
            ProjectWebView(webView: model.webView)
        }
        .onAppear {
            if model.webView.url == nil { model.loadAddress() }
        }
    }
}

// MARK: - Side chat

private struct SideChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

@Observable
@MainActor
private final class SideChatModel {
    var messages: [SideChatMessage] = []
    var input = ""
    var isRunning = false
    private var connector: PiConnector?
    private var cancellable: AnyCancellable?

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning,
              let conversation = ConversationStore.shared.selectedConversation,
              let model = conversation.model ?? LanguageModelStore.shared.selectedModel else { return }
        input = ""
        messages.append(SideChatMessage(role: "user", text: prompt))
        messages.append(SideChatMessage(role: "assistant", text: ""))
        isRunning = true

        if connector == nil {
            connector = AgentBackendConfig.makeChatBackend(
                workingDirectory: ConversationStore.shared.workingDirectory(for: conversation)
            ) as? PiConnector
        }
        guard let connector else { isRunning = false; return }
        let history = messages.filter { !$0.text.isEmpty }.map {
            AgentChatMessage(
                role: $0.role == "user" ? .user : .assistant,
                content: $0.text
            )
        }
        cancellable = connector.chat(model: model.name, messages: history)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isRunning = false
            } receiveValue: { [weak self, weak connector] event in
                guard let self else { return }
                switch event {
                case .messageDelta(let text):
                    guard let index = messages.indices.last else { return }
                    messages[index].text += text
                case .uiRequest(let request):
                    connector?.respondToUIRequest(id: request.id, confirmed: false)
                case .done:
                    isRunning = false
                default:
                    break
                }
            }
    }

    func stop() {
        connector?.abort()
        cancellable?.cancel()
        isRunning = false
    }
}

private struct SideChatView: View {
    @State private var model = SideChatModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty {
                ContentUnavailableView(
                    "Side Chat",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Ask a temporary question without changing the main task context.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            Text(message.text.isEmpty ? "…" : message.text)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                .background(
                                    message.role == "user" ? CodexTheme.surfaceSubtle : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                    }
                    .padding(10)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask in side chat", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { model.send() }
                Button(action: { model.isRunning ? model.stop() : model.send() }) {
                    Image(systemName: model.isRunning ? "stop.fill" : "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(!model.isRunning && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }
}

// MARK: - Git changes

private struct GitChange: Identifiable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int

    var id: String { path }
    var isUntracked: Bool { status.contains("?") }
    var hasStagedChanges: Bool {
        guard let first = status.first else { return false }
        return first != " " && first != "?"
    }
    var hasWorkingTreeChanges: Bool {
        guard status.count > 1 else { return isUntracked }
        return status[status.index(after: status.startIndex)] != " " || isUntracked
    }
    var statusColor: Color {
        if status.contains("?") || status.contains("A") { return .green }
        if status.contains("D") { return .red }
        return .orange
    }
}

private struct GitChangesSnapshot: Sendable {
    let root: String?
    let changes: [GitChange]
    let error: String?
}

@Observable
@MainActor
private final class GitChangesStore {
    var root: String?
    var changes: [GitChange] = []
    var selected: GitChange?
    var diff = ""
    var isLoading = false
    var error: String?

    func refresh() async {
        guard let conversation = ConversationStore.shared.selectedConversation else {
            root = nil; changes = []; error = "No conversation selected"
            return
        }
        let directory = ConversationStore.shared.workingDirectory(for: conversation)
        isLoading = true
        selected = nil
        diff = ""
        let snapshot = await Task.detached {
            GitChangesReader.snapshot(at: directory)
        }.value
        root = snapshot.root
        changes = snapshot.changes
        error = snapshot.error
        isLoading = false
    }

    func select(_ change: GitChange) async {
        guard let root else { return }
        selected = change
        diff = "Loading diff…"
        diff = await Task.detached {
            GitChangesReader.diff(at: root, path: change.path, isUntracked: change.status.contains("?"))
        }.value
    }

    func stage(_ change: GitChange) async {
        await mutate(.stage, change: change)
    }

    func unstage(_ change: GitChange) async {
        await mutate(.unstage, change: change)
    }

    func discard(_ change: GitChange) async {
        await mutate(.discard, change: change)
    }

    private func mutate(_ operation: GitChangesReader.Operation, change: GitChange) async {
        guard let root else { return }
        isLoading = true
        let result = await Task.detached {
            GitChangesReader.mutate(operation, at: root, change: change)
        }.value
        if let result { error = result }
        await refresh()
    }
}

private enum GitChangesReader {
    enum Operation: Sendable { case stage, unstage, discard }

    static func snapshot(at directory: String) -> GitChangesSnapshot {
        let rootResult = run(["-C", directory, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else {
            return GitChangesSnapshot(root: nil, changes: [], error: "This project is not a Git repository")
        }
        let root = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusResult = run(["-C", root, "status", "--porcelain=v1", "--untracked-files=all"])
        guard statusResult.status == 0 else {
            return GitChangesSnapshot(root: root, changes: [], error: statusResult.output)
        }

        var counts: [String: (Int, Int)] = [:]
        for args in [
            ["-C", root, "diff", "--numstat"],
            ["-C", root, "diff", "--cached", "--numstat"],
        ] {
            let result = run(args)
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                let old = counts[parts[2]] ?? (0, 0)
                counts[parts[2]] = (old.0 + (Int(parts[0]) ?? 0), old.1 + (Int(parts[1]) ?? 0))
            }
        }

        let changes = statusResult.output.split(separator: "\n").compactMap { raw -> GitChange? in
            let line = String(raw)
            guard line.count >= 4 else { return nil }
            let status = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let count = counts[path] ?? (0, 0)
            return GitChange(path: path, status: status, additions: count.0, deletions: count.1)
        }
        return GitChangesSnapshot(root: root, changes: changes, error: nil)
    }

    static func diff(at root: String, path: String, isUntracked: Bool) -> String {
        if isUntracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "Binary or unreadable untracked file"
        }
        let unstaged = run(["-C", root, "diff", "--no-ext-diff", "--unified=3", "--", path]).output
        let staged = run(["-C", root, "diff", "--cached", "--no-ext-diff", "--unified=3", "--", path]).output
        let value = [staged, unstaged].filter { !$0.isEmpty }.joined(separator: "\n")
        return value.isEmpty ? "No textual diff available" : value
    }

    /// Returns an error message, or nil on success.
    static func mutate(_ operation: Operation, at root: String, change: GitChange) -> String? {
        let result: (status: Int32, output: String)
        switch operation {
        case .stage:
            result = run(["-C", root, "add", "--", change.path])
        case .unstage:
            result = run(["-C", root, "restore", "--staged", "--", change.path])
        case .discard:
            if change.isUntracked {
                let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
                let fileURL = rootURL.appendingPathComponent(change.path).standardizedFileURL
                guard fileURL.path.hasPrefix(rootURL.path + "/") else { return "Refusing to remove a path outside the repository" }
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            result = run(["-C", root, "restore", "--worktree", "--", change.path])
        }
        return result.status == 0 ? nil : (result.output.isEmpty ? "Git operation failed" : result.output)
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

private struct GitChangesView: View {
    @State private var store = GitChangesStore()
    @State private var conversationStore = ConversationStore.shared
    @State private var discardCandidate: GitChange?

    var body: some View {
        Group {
            if let selected = store.selected {
                diffView(selected)
            } else {
                changesList
            }
        }
        .task { await store.refresh() }
        .onChange(of: conversationStore.selectedConversation?.id) {
            Task { await store.refresh() }
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            presenting: discardCandidate
        ) { change in
            Button("Discard \(change.path)", role: .destructive) {
                Task { await store.discard(change) }
                discardCandidate = nil
            }
            Button("Cancel", role: .cancel) { discardCandidate = nil }
        } message: { change in
            Text(change.isUntracked
                 ? "This permanently deletes the untracked file."
                 : "This permanently discards working tree changes in this file. Staged changes are preserved.")
        }
    }

    private var changesList: some View {
        VStack(spacing: 0) {
            HStack {
                Group {
                    if store.changes.isEmpty {
                        Text("Changes")
                    } else {
                        Text("Changes · \(store.changes.count)")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if !store.changes.isEmpty {
                    Button(action: { conversationStore.startCodeReview() }) {
                        Image(systemName: "checklist.checked")
                    }
                    .buttonStyle(.plain)
                    .help("Review changes in a new task")
                    .disabled(conversationStore.conversationState == .loading)
                }
                Button(action: { Task { await store.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if let error = store.error {
                ContentUnavailableView("Git unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !store.isLoading && store.changes.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.changes) { change in
                            Button(action: { Task { await store.select(change) } }) {
                                HStack(spacing: 8) {
                                    Text(change.status.trimmingCharacters(in: .whitespaces))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(change.statusColor)
                                        .frame(width: 20)
                                    Text(change.path)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                                    if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func diffView(_ change: GitChange) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { store.selected = nil; store.diff = "" }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(change.path)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let root = store.root {
                    Button(action: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(change.path))
                    }) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .help("Open file")
                }
                if change.hasStagedChanges {
                    Button(action: { Task { await store.unstage(change) } }) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Unstage")
                }
                if change.hasWorkingTreeChanges {
                    Button(action: { Task { await store.stage(change) } }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Stage")
                    Button(action: { discardCandidate = change }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Discard changes")
                }
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                        let line = String(raw)
                        Text(line.isEmpty ? " " : line)
                            .foregroundStyle(diffColor(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
        }
    }

    private func diffColor(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .secondary }
        return .primary
    }
}
#endif
