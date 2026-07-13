//
//  RightSidebarPanel.swift
//  Enchanted
//
//  A multi-purpose right sidebar tool panel. It slides in from the trailing
//  edge and hosts a vertical tool navigation list (files, review, terminal,
//  browser, side chat). Each row shows an icon, a label and a right-aligned
//  keyboard-shortcut hint. Selecting a tool activates the matching feature
//  panel (e.g. the bottom terminal) or shows the tool's inline view.
//

#if os(macOS)
import SwiftUI
import AppKit
import Combine
import QuickLookUI
import WebKit

// MARK: - Tool model

/// A single feature exposed in the right sidebar. Metadata (label, icon and
/// the human-readable shortcut hint) lives here so the list UI and the global
/// keyboard-shortcut menu stay in sync.
enum RightSidebarTool: String, CaseIterable, Identifiable {
    case files
    case review
    case terminal
    case browser
    case sideChat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files:    return String(localized: "Files")
        case .review:   return String(localized: "Review")
        case .terminal: return String(localized: "Terminal")
        case .browser:  return String(localized: "Browser")
        case .sideChat: return String(localized: "Side Chat")
        }
    }

    /// SF Symbol used as the category icon.
    var icon: String {
        switch self {
        case .files:    return "folder"
        case .review:   return "checklist"
        case .terminal: return "terminal"
        case .browser:  return "globe"
        case .sideChat: return "bubble.left.and.bubble.right"
        }
    }

    /// The `ShortcutStore` command id backing this tool.
    var shortcutCommandID: String {
        switch self {
        case .files:    return "files"
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
    /// File shown in the main workspace while the Files tool stays visible.
    var selectedProjectFile: ProjectFileEntry?
    /// Root associated with `selectedProjectFile`, used to invalidate stale selections.
    var selectedProjectRootPath: String?
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

    /// The file preview belongs to the current conversation, like panel width.
    var selectedProjectFile: ProjectFileEntry? {
        get { current.selectedProjectFile }
        set { current.selectedProjectFile = newValue }
    }

    var selectedProjectRootPath: String? {
        get { current.selectedProjectRootPath }
        set { current.selectedProjectRootPath = newValue }
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
        case .files:
            ProjectFilesView()
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

// MARK: - Project files

struct ProjectFileEntry: Identifiable, Equatable, Sendable {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool

    var id: String { relativePath }
}

struct ProjectDirectorySnapshot: Equatable, Sendable {
    let entries: [ProjectFileEntry]
    let isTruncated: Bool
    let error: String?
}

enum ProjectFileSystemReader {
    static let maximumDirectoryEntries = 2_000
    static let maximumPreviewBytes = 1_000_000

    static func safeURL(rootPath: String, relativePath: String) -> URL? {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard !relativePath.hasPrefix("/") else { return nil }
        let candidate = relativePath.isEmpty
            ? root
            : root.appendingPathComponent(relativePath)
                .resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    static func listChildren(
        rootPath: String,
        relativePath: String,
        includeHidden: Bool
    ) -> ProjectDirectorySnapshot {
        guard let directory = safeURL(rootPath: rootPath, relativePath: relativePath) else {
            return .init(entries: [], isTruncated: false, error: "Path is outside the project.")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: options
            )
            var entries: [ProjectFileEntry] = []
            entries.reserveCapacity(min(urls.count, maximumDirectoryEntries))
            for url in urls.prefix(maximumDirectoryEntries) {
                let values = try? url.resourceValues(forKeys: keys)
                if !includeHidden, values?.isHidden == true { continue }
                let isLink = values?.isSymbolicLink == true
                let childPath = relativePath.isEmpty ? url.lastPathComponent : relativePath + "/" + url.lastPathComponent
                guard safeURL(rootPath: rootPath, relativePath: childPath) != nil else { continue }
                entries.append(.init(
                    relativePath: childPath,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory == true && !isLink,
                    isSymbolicLink: isLink
                ))
            }
            entries.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return .init(entries: entries, isTruncated: urls.count > maximumDirectoryEntries, error: nil)
        } catch {
            return .init(entries: [], isTruncated: false, error: error.localizedDescription)
        }
    }

    static func readPreview(rootPath: String, relativePath: String) -> String? {
        guard let url = safeURL(rootPath: rootPath, relativePath: relativePath),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumPreviewBytes + 1),
              data.count <= maximumPreviewBytes,
              !data.prefix(8_192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@Observable
@MainActor
private final class ProjectFilesModel {
    var entries: [ProjectFileEntry] = []
    var includeHidden = false
    var isLoading = false
    var error: String?
    var isTruncated = false
    var refreshID = UUID()

    func reload(rootPath: String) {
        isLoading = true
        error = nil
        refreshID = UUID()
        let includeHidden = includeHidden
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                ProjectFileSystemReader.listChildren(
                    rootPath: rootPath,
                    relativePath: "",
                    includeHidden: includeHidden
                )
            }.value
            entries = snapshot.entries
            isTruncated = snapshot.isTruncated
            error = snapshot.error
            isLoading = false
        }
    }
}

private struct ProjectFilesView: View {
    @State private var model = ProjectFilesModel()
    @State private var conversationStore = ConversationStore.shared
    @State private var sidebarStore = RightSidebarStore.shared

    private var rootPath: String {
        conversationStore.workingDirectory(for: conversationStore.selectedConversation)
    }

    var body: some View {
        VStack(spacing: 0) {
            filesToolbar
            Divider()
            if model.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = model.error {
                ContentUnavailableView("Can't read this folder", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            ProjectFileTreeNodeView(
                                rootPath: rootPath,
                                entry: entry,
                                includeHidden: model.includeHidden,
                                selectedPath: sidebarStore.selectedProjectFile?.relativePath,
                                onSelect: { sidebarStore.selectedProjectFile = $0 }
                            )
                        }
                        if model.isTruncated {
                            Text("Showing the first \(ProjectFileSystemReader.maximumDirectoryEntries) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 5)
                    .id(model.refreshID)
                }
            }
        }
        .task(id: rootPath) {
            if sidebarStore.selectedProjectRootPath != rootPath {
                sidebarStore.selectedProjectFile = nil
                sidebarStore.selectedProjectRootPath = rootPath
            }
            model.reload(rootPath: rootPath)
        }
    }

    private var filesToolbar: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.includeHidden.toggle()
                model.reload(rootPath: rootPath)
            } label: {
                Image(systemName: model.includeHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(model.includeHidden ? "Hide hidden files" : "Show hidden files")
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: rootPath)) } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(.plain)
            .help("Open in Finder")
            Button { model.reload(rootPath: rootPath) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

private struct ProjectFileTreeNodeView: View {
    let rootPath: String
    let entry: ProjectFileEntry
    let includeHidden: Bool
    let selectedPath: String?
    let onSelect: (ProjectFileEntry) -> Void

    @State private var isExpanded = false
    @State private var isLoading = false
    @State private var snapshot: ProjectDirectorySnapshot?

    var body: some View {
        Group {
            if entry.isDirectory {
                DisclosureGroup(isExpanded: $isExpanded) {
                    if isLoading {
                        ProgressView().controlSize(.small).padding(.leading, 18).padding(.vertical, 4)
                    } else if let error = snapshot?.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                    } else {
                        ForEach(snapshot?.entries ?? []) { child in
                            ProjectFileTreeNodeView(
                                rootPath: rootPath,
                                entry: child,
                                includeHidden: includeHidden,
                                selectedPath: selectedPath,
                                onSelect: onSelect
                            )
                        }
                        if snapshot?.isTruncated == true {
                            Text("Folder truncated").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                        }
                    }
                } label: {
                    ProjectFileRow(entry: entry, isSelected: false, action: { isExpanded.toggle() })
                }
                .onChange(of: isExpanded) { _, expanded in
                    if expanded, snapshot == nil { loadChildren() }
                }
                .onChange(of: includeHidden) { _, _ in
                    snapshot = nil
                    if isExpanded { loadChildren() }
                }
            } else {
                ProjectFileRow(
                    entry: entry,
                    isSelected: selectedPath == entry.relativePath,
                    action: { onSelect(entry) }
                )
            }
        }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open") { NSWorkspace.shared.open(fileURL) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        Divider()
        Button("Copy Relative Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.relativePath, forType: .string) }
        Button("Copy Full Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fileURL.path, forType: .string) }
    }

    private var fileURL: URL {
        ProjectFileSystemReader.safeURL(rootPath: rootPath, relativePath: entry.relativePath)
            ?? URL(fileURLWithPath: rootPath)
    }

    private func loadChildren() {
        isLoading = true
        let includeHidden = includeHidden
        Task {
            snapshot = await Task.detached(priority: .userInitiated) {
                ProjectFileSystemReader.listChildren(
                    rootPath: rootPath,
                    relativePath: entry.relativePath,
                    includeHidden: includeHidden
                )
            }.value
            isLoading = false
        }
    }
}

private struct ProjectFileRow: View {
    let entry: ProjectFileEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 15)
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.isSymbolicLink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
            .frame(height: 24)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        if entry.isDirectory { return isPackage ? "shippingbox" : "folder" }
        if entry.isSymbolicLink { return "link" }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "json", "yaml", "yml", "toml": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private var isPackage: Bool {
        ["app", "xcodeproj", "xcworkspace", "playground"].contains(URL(fileURLWithPath: entry.name).pathExtension.lowercased())
    }
}

struct ProjectFileWorkspaceView: View {
    let rootPath: String
    let entry: ProjectFileEntry
    let onBack: () -> Void
    @State private var text: String?
    @State private var didLoad = false

    private var fileURL: URL {
        ProjectFileSystemReader.safeURL(rootPath: rootPath, relativePath: entry.relativePath)
            ?? URL(fileURLWithPath: rootPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(entry.relativePath)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { NSWorkspace.shared.open(fileURL) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain)
                    .help("Open")
                Button(action: onBack) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Close file")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            if let text {
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            } else if didLoad {
                ProjectQuickLookView(url: fileURL)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .task(id: entry.id) {
            didLoad = false
            text = await Task.detached(priority: .userInitiated) {
                ProjectFileSystemReader.readPreview(rootPath: rootPath, relativePath: entry.relativePath)
            }.value
            didLoad = true
        }
    }
}

private struct ProjectQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
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
    var diffSections: [GitDiffSection] = []
    var diffStatus = ""
    var isLoading = false
    var error: String?
    var repositoryInfo: GitRepositoryInfo?
    var gitActionResult: GitActionResult?
    var isGitActionRunning = false

    func refresh() async {
        guard let conversation = ConversationStore.shared.selectedConversation else {
            root = nil; changes = []; repositoryInfo = nil; error = "No conversation selected"
            return
        }
        let directory = ConversationStore.shared.workingDirectory(for: conversation)
        isLoading = true
        selected = nil
        diffSections = []
        diffStatus = ""
        let loaded = await Task.detached {
            (
                GitChangesReader.snapshot(at: directory),
                GitRepositoryActions.inspect(at: directory)
            )
        }.value
        let snapshot = loaded.0
        root = snapshot.root
        changes = snapshot.changes
        error = snapshot.error
        if case .success(let info) = loaded.1 { repositoryInfo = info } else { repositoryInfo = nil }
        isLoading = false
    }

    func select(_ change: GitChange) async {
        guard let root else { return }
        selected = change
        diffStatus = "Loading diff…"
        diffSections = await Task.detached {
            GitChangesReader.diffSections(
                at: root,
                path: change.path,
                isUntracked: change.status.contains("?")
            )
        }.value
        diffStatus = diffSections.isEmpty ? "No textual diff available" : ""
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

    func mutateHunk(
        _ operation: GitHunkOperation,
        hunk: UnifiedDiffHunk,
        change: GitChange
    ) async {
        guard let root else { return }
        isLoading = true
        let mutationError = await Task.detached {
            GitChangesReader.mutateHunk(operation, at: root, patch: hunk.patch)
        }.value
        if let mutationError {
            error = mutationError
            isLoading = false
            return
        }

        let snapshot = await Task.detached { GitChangesReader.snapshot(at: root) }.value
        self.root = snapshot.root
        changes = snapshot.changes
        error = snapshot.error
        if case .success(let info) = await Task.detached(operation: {
            GitRepositoryActions.inspect(at: root)
        }).value {
            repositoryInfo = info
        }
        if let updated = changes.first(where: { $0.path == change.path }) {
            selected = updated
            diffSections = await Task.detached {
                GitChangesReader.diffSections(
                    at: root,
                    path: updated.path,
                    isUntracked: updated.isUntracked
                )
            }.value
            diffStatus = diffSections.isEmpty ? "No textual diff available" : ""
        } else {
            selected = nil
            diffSections = []
            diffStatus = ""
        }
        isLoading = false
    }

    func commit(message: String) async {
        guard let root else { return }
        await performGitAction {
            GitRepositoryActions.commit(at: root, message: message)
        }
    }

    func push() async {
        guard let root else { return }
        await performGitAction { GitRepositoryActions.push(at: root) }
    }

    func createPullRequest(title: String, body: String, isDraft: Bool) async {
        guard let root else { return }
        await performGitAction {
            GitRepositoryActions.createPullRequest(
                at: root,
                title: title,
                body: body,
                isDraft: isDraft
            )
        }
    }

    private func performGitAction(
        _ action: @escaping @Sendable () -> GitActionResult
    ) async {
        guard !isGitActionRunning else { return }
        isGitActionRunning = true
        let result = await Task.detached(operation: action).value
        gitActionResult = result
        isGitActionRunning = false
        await refresh()
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

    static func diffSections(at root: String, path: String, isUntracked: Bool) -> [GitDiffSection] {
        if isUntracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return [GitDiffSection(kind: .untracked, text: text)]
        }
        let unstaged = run(["-C", root, "diff", "--no-ext-diff", "--unified=3", "--", path]).output
        let staged = run(["-C", root, "diff", "--cached", "--no-ext-diff", "--unified=3", "--", path]).output
        var sections: [GitDiffSection] = []
        if !staged.isEmpty { sections.append(.init(kind: .staged, text: staged)) }
        if !unstaged.isEmpty { sections.append(.init(kind: .unstaged, text: unstaged)) }
        return sections
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

    static func mutateHunk(_ operation: GitHunkOperation, at root: String, patch: String) -> String? {
        GitHunkMutator.apply(operation, repositoryRoot: root, patch: patch)
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
    @State private var reviewDrafts = GitReviewDraftStore.shared
    @State private var discardCandidate: GitChange?
    @State private var commentingLineID: Int?
    @State private var commentText = ""
    @State private var submissionError: String?
    @State private var confirmClearComments = false
    @State private var revertHunkCandidate: UnifiedDiffHunk?
    @State private var showCommitSheet = false
    @State private var showPullRequestSheet = false
    @State private var confirmPush = false
    @State private var commitMessage = ""
    @State private var pullRequestTitle = ""
    @State private var pullRequestBody = ""
    @State private var pullRequestIsDraft = false

    private var conversationID: UUID? {
        conversationStore.selectedConversation?.id
    }

    private var draftComments: [DiffReviewComment] {
        reviewDrafts.comments(for: conversationID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let result = store.gitActionResult {
                gitActionFeedback(result)
                Divider()
            }
            if let selected = store.selected {
                diffView(selected)
            } else {
                changesList
            }
        }
        .task { await store.refresh() }
        .onChange(of: conversationStore.selectedConversation?.id) {
            commentingLineID = nil
            commentText = ""
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
        .alert("无法发送评审意见", isPresented: Binding(
            get: { submissionError != nil },
            set: { if !$0 { submissionError = nil } }
        )) {
            Button("好") { submissionError = nil }
        } message: {
            Text(submissionError ?? "未知错误")
        }
        .confirmationDialog(
            "清空所有行内意见？",
            isPresented: $confirmClearComments
        ) {
            Button("清空 \(draftComments.count) 条意见", role: .destructive) {
                if let conversationID { reviewDrafts.clear(conversationID) }
                cancelCommenting()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些尚未发送给 Agent 的评审草稿将被删除。")
        }
        .confirmationDialog(
            "Revert this hunk?",
            isPresented: Binding(
                get: { revertHunkCandidate != nil },
                set: { if !$0 { revertHunkCandidate = nil } }
            ),
            presenting: revertHunkCandidate
        ) { hunk in
            Button("Revert hunk", role: .destructive) {
                if let change = store.selected {
                    Task { await store.mutateHunk(.revert, hunk: hunk, change: change) }
                }
                revertHunkCandidate = nil
            }
            Button("Cancel", role: .cancel) { revertHunkCandidate = nil }
        } message: { _ in
            Text("This permanently discards the working-tree changes in this hunk.")
        }
        .confirmationDialog(
            "Push \(store.repositoryInfo?.branch ?? "current branch")?",
            isPresented: $confirmPush
        ) {
            Button("Push") {
                Task { await store.push() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let info = store.repositoryInfo, info.upstream == nil {
                Text("The first available remote will be set as this branch's upstream.")
            } else {
                Text("Local commits will be sent to the configured upstream remote.")
            }
        }
        .sheet(isPresented: $showCommitSheet) {
            GitCommitSheet(
                branch: store.repositoryInfo?.branch ?? "",
                message: $commitMessage,
                onCancel: { showCommitSheet = false },
                onCommit: {
                    let message = commitMessage
                    showCommitSheet = false
                    Task { await store.commit(message: message) }
                }
            )
        }
        .sheet(isPresented: $showPullRequestSheet) {
            GitPullRequestSheet(
                branch: store.repositoryInfo?.branch ?? "",
                title: $pullRequestTitle,
                descriptionText: $pullRequestBody,
                isDraft: $pullRequestIsDraft,
                onCancel: { showPullRequestSheet = false },
                onCreate: {
                    let title = pullRequestTitle
                    let body = pullRequestBody
                    let draft = pullRequestIsDraft
                    showPullRequestSheet = false
                    Task {
                        await store.createPullRequest(title: title, body: body, isDraft: draft)
                    }
                }
            )
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
                if !draftComments.isEmpty {
                    Label("\(draftComments.count)", systemImage: "text.bubble")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CodexTheme.mutedText)
                }
                Spacer()
                if store.isLoading || store.isGitActionRunning {
                    ProgressView().controlSize(.small)
                }
                if let info = store.repositoryInfo {
                    Menu {
                        Section {
                            Label(info.branch, systemImage: "arrow.triangle.branch")
                            if let upstream = info.upstream {
                                Text("\(upstream) · ↑\(info.ahead) ↓\(info.behind)")
                            } else {
                                Text("No upstream")
                            }
                        }
                        Divider()
                        Button {
                            commitMessage = ""
                            showCommitSheet = true
                        } label: {
                            Label("Commit staged changes…", systemImage: "checkmark.circle")
                        }
                        .disabled(!info.hasStagedChanges || store.isGitActionRunning)
                        Button {
                            confirmPush = true
                        } label: {
                            Label("Push…", systemImage: "arrow.up.circle")
                        }
                        .disabled(store.isGitActionRunning || info.remotes.isEmpty)
                        Button {
                            pullRequestTitle = conversationStore.selectedConversation?.name ?? info.branch
                            pullRequestBody = ""
                            pullRequestIsDraft = false
                            showPullRequestSheet = true
                        } label: {
                            Label("Create pull request…", systemImage: "arrow.triangle.pull")
                        }
                        .disabled(store.isGitActionRunning || info.remotes.isEmpty)
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(info.branch) · Git actions")
                }
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

    private func gitActionFeedback(_ result: GitActionResult) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.success ? .green : .orange)
            Text(result.message)
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.mutedText)
                .lineLimit(4)
            Spacer(minLength: 4)
            if let url = result.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
            }
            Button {
                store.gitActionResult = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(CodexTheme.surfaceSubtle)
    }

    private func diffView(_ change: GitChange) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: {
                    store.selected = nil
                    store.diffSections = []
                    store.diffStatus = ""
                }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(change.path)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
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
            if let error = store.error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.mutedText)
                    Spacer(minLength: 4)
                    Button {
                        store.error = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(CodexTheme.surfaceSubtle)
                Divider()
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.diffStatus.isEmpty {
                        Text(store.diffStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(CodexTheme.mutedText)
                            .padding(10)
                    }
                    ForEach(store.diffSections) { section in
                        let lines = UnifiedDiffParser.parse(
                            section.text,
                            isUntracked: section.kind == .untracked
                        )
                        let hunks = UnifiedDiffParser.hunks(in: section.text)
                        HStack {
                            Text(section.kind.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CodexTheme.mutedText)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(CodexTheme.surfaceSubtle)

                        ForEach(lines) { line in
                            let hunk = hunks.first(where: { $0.id == line.id })
                            DiffReviewLineRow(
                                line: line,
                                comment: comment(for: line, change: change),
                                isEditing: commentingLineID == line.id,
                                commentText: $commentText,
                                color: diffColor(for: line.text),
                                hunkKind: hunk == nil ? nil : section.kind,
                                onStartComment: { startCommenting(line, change: change) },
                                onSaveComment: { saveComment(line, change: change) },
                                onCancelComment: cancelCommenting,
                                onRemoveComment: { comment in removeComment(comment) },
                                onPrimaryHunk: {
                                    guard let hunk else { return }
                                    let operation: GitHunkOperation = section.kind == .staged
                                        ? .unstage
                                        : .stage
                                    Task { await store.mutateHunk(operation, hunk: hunk, change: change) }
                                },
                                onRevertHunk: { revertHunkCandidate = hunk }
                            )
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }

            if !draftComments.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Label("\(draftComments.count) 条行内意见", systemImage: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("清空") {
                        confirmClearComments = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CodexTheme.mutedText)
                    Button("发送给 Agent") {
                        submitReviewComments()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(conversationStore.conversationState == .loading)
                }
                .padding(10)
            }
        }
    }

    private func comment(for line: DiffDisplayLine, change: GitChange) -> DiffReviewComment? {
        guard let reference = line.reference else { return nil }
        return reviewDrafts.comment(
            for: conversationID,
            filePath: change.path,
            reference: reference
        )
    }

    private func startCommenting(_ line: DiffDisplayLine, change: GitChange) {
        guard line.reference != nil else { return }
        commentingLineID = line.id
        commentText = comment(for: line, change: change)?.body ?? ""
    }

    private func saveComment(_ line: DiffDisplayLine, change: GitChange) {
        guard let conversationID,
              let reference = line.reference else { return }
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let existingID = comment(for: line, change: change)?.id ?? UUID()
        reviewDrafts.save(
            DiffReviewComment(
                id: existingID,
                filePath: change.path,
                reference: reference,
                sourceLine: line.text,
                body: body
            ),
            for: conversationID
        )
        cancelCommenting()
    }

    private func cancelCommenting() {
        commentingLineID = nil
        commentText = ""
    }

    private func removeComment(_ comment: DiffReviewComment) {
        guard let conversationID else { return }
        reviewDrafts.remove(comment, from: conversationID)
        if commentingLineID != nil { cancelCommenting() }
    }

    private func submitReviewComments() {
        guard let conversation = conversationStore.selectedConversation,
              let model = LanguageModelStore.shared.selectedModel ?? conversation.model else {
            submissionError = "当前任务没有可用模型。"
            return
        }
        let comments = reviewDrafts.comments(for: conversation.id)
        guard !comments.isEmpty else { return }
        conversationStore.sendPrompt(
            userPrompt: DiffReviewPrompt.make(comments: comments),
            model: model
        )
        reviewDrafts.clear(conversation.id)
        cancelCommenting()
    }

    private func diffColor(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .secondary }
        return .primary
    }
}

private struct DiffReviewLineRow: View {
    let line: DiffDisplayLine
    let comment: DiffReviewComment?
    let isEditing: Bool
    @Binding var commentText: String
    let color: Color
    let hunkKind: GitDiffSectionKind?
    let onStartComment: () -> Void
    let onSaveComment: () -> Void
    let onCancelComment: () -> Void
    let onRemoveComment: (DiffReviewComment) -> Void
    let onPrimaryHunk: () -> Void
    let onRevertHunk: () -> Void
    @State private var hovering = false

    private var oldLine: String {
        line.reference?.oldLine.map(String.init) ?? ""
    }

    private var newLine: String {
        line.reference?.newLine.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(oldLine)
                    .frame(width: 34, alignment: .trailing)
                Text(newLine)
                    .frame(width: 34, alignment: .trailing)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(color)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hunkKind == .staged {
                    Button(action: onPrimaryHunk) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Unstage hunk")
                    .padding(.horizontal, 3)
                } else if hunkKind == .unstaged {
                    Button(action: onPrimaryHunk) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Stage hunk")
                    .padding(.horizontal, 3)
                    Button(action: onRevertHunk) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Revert hunk")
                    .padding(.horizontal, 3)
                }
                if line.reference != nil {
                    Button(action: onStartComment) {
                        Image(systemName: comment == nil ? "text.bubble" : "text.bubble.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(comment == nil ? "添加行内意见" : "编辑行内意见")
                    .opacity(hovering || comment != nil || isEditing ? 1 : 0.35)
                    .padding(.horizontal, 6)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(line.reference == nil ? CodexTheme.mutedText : CodexTheme.faintText)
            .padding(.vertical, 2)
            .background(rowBackground)
            .onHover { hovering = $0 }

            if let comment, !isEditing {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.accent)
                    Text(comment.body)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.primaryText)
                    Spacer(minLength: 8)
                    Button(action: { onRemoveComment(comment) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("删除意见")
                }
                .padding(8)
                .background(CodexTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 76)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
            }

            if isEditing {
                VStack(alignment: .trailing, spacing: 7) {
                    TextField("添加行内意见", text: $commentText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...6)
                        .padding(7)
                        .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(CodexTheme.border, lineWidth: 1)
                        }
                        .onSubmit(onSaveComment)
                    HStack(spacing: 8) {
                        Button("取消", action: onCancelComment)
                            .buttonStyle(.plain)
                        Button(comment == nil ? "添加" : "更新", action: onSaveComment)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.leading, 76)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
            }
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: return .green.opacity(0.07)
        case .deletion: return .red.opacity(0.07)
        case .hunk: return .blue.opacity(0.06)
        default: return .clear
        }
    }
}

private struct GitCommitSheet: View {
    let branch: String
    @Binding var message: String
    let onCancel: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit staged changes")
                .font(.headline)
            Label(branch, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.mutedText)
            TextField("Commit message", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit(onCommit)
            Text("Only staged changes will be included.")
                .font(.caption)
                .foregroundStyle(CodexTheme.mutedText)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Commit", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct GitPullRequestSheet: View {
    let branch: String
    @Binding var title: String
    @Binding var descriptionText: String
    @Binding var isDraft: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create pull request")
                .font(.headline)
            Label(branch, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.mutedText)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Description")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $descriptionText)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 130)
                .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CodexTheme.border, lineWidth: 1)
                }
            Toggle("Create as draft", isOn: $isDraft)
                .toggleStyle(.checkbox)
            Text("Uses GitHub CLI (`gh`) and its current authentication.")
                .font(.caption)
                .foregroundStyle(CodexTheme.mutedText)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
#endif
