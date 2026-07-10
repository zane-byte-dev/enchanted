//
//  SettingsMacOS.swift
//  Enchanted
//
//  Full-page macOS settings with sidebar navigation, mirroring the Codex style.
//

#if os(macOS)
import SwiftUI
import AVFoundation
import Combine

// MARK: - Category enum

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general     = "general"
    case appearance  = "appearance"
    case voice       = "voice"
    case shortcuts   = "shortcuts"
    case advanced    = "advanced"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "常规"
        case .appearance:  return "外观"
        case .voice:       return "语音"
        case .shortcuts:   return "快捷键"
        case .advanced:    return "高级"
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .appearance:  return "paintbrush"
        case .voice:       return "waveform"
        case .shortcuts:   return "keyboard"
        case .advanced:    return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Root view

struct SettingsMacOS: View {
    /// When provided, tapping "返回应用" calls this instead of SwiftUI dismiss.
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var envDismiss

    @State private var selectedCategory: SettingsCategory? = .general

    // Shared stores
    private var languageModelStore = LanguageModelStore.shared
    private var conversationStore  = ConversationStore.shared

    // Persisted settings
    @AppStorage("ollamaUri")          private var ollamaUri: String          = ""
    @AppStorage("systemPrompt")       private var systemPrompt: String       = ""
    @AppStorage("vibrations")         private var vibrations: Bool           = true
    @AppStorage("colorScheme")        private var colorScheme: AppColorScheme = .system
    @AppStorage("defaultOllamaModel") private var defaultOllamaModel: String = ""
    @AppStorage("ollamaBearerToken")  private var ollamaBearerToken: String  = ""
    @AppStorage("appUserInitials")    private var appUserInitials: String    = ""
    @AppStorage("pingInterval")       private var pingInterval: String       = "5"
    @AppStorage("voiceIdentifier")    private var voiceIdentifier: String    = ""

    @State private var appLanguage: AppLanguage = AppLanguage.current
    @State private var ollamaStatus: Bool?
    @State private var deleteConversationsDialog = false
    @State private var languageRestartDialog      = false

    @StateObject private var speechSynthesiser = SpeechSynthesizer.shared
    private let voiceTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var voiceCancellable: AnyCancellable?

    // MARK: Actions

    private func save() {
        if ollamaUri.last == "/" { ollamaUri = String(ollamaUri.dropLast()) }
        OllamaService.shared.initEndpoint(url: ollamaUri, bearerToken: ollamaBearerToken)
        Task { try? await languageModelStore.loadModels() }
    }

    private func handleDismiss() {
        save()
        AppStore.shared.showSettings = false
    }

    private func checkServer() {
        Task {
            OllamaService.shared.initEndpoint(url: ollamaUri)
            ollamaStatus = await OllamaService.shared.reachable()
            try? await languageModelStore.loadModels()
        }
    }

    private func deleteAll() {
        Task {
            try? await conversationStore.deleteAllConversations()
            try? await languageModelStore.deleteAllModels()
        }
    }

    // MARK: Body

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(NSColor.textBackgroundColor))
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(Color(NSColor.textBackgroundColor))
        .preferredColorScheme(colorScheme.toiOSFormat)
        .onChange(of: defaultOllamaModel) { _, name in languageModelStore.setModel(modelName: name) }
        .onAppear {
            voiceCancellable = voiceTimer.sink { _ in speechSynthesiser.fetchVoices() }
        }
        .onDisappear {
            voiceCancellable?.cancel()
        }
        .confirmationDialog("Delete All Conversations?", isPresented: $deleteConversationsDialog) {
            Button("Delete", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Restart required", isPresented: $languageRestartDialog) {
            Button("Quit Now", role: .destructive) { NSApplication.shared.terminate(nil) }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The language change takes effect after restarting the app.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                handleDismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回应用")
                        .font(.system(size: 13))
                }
                .foregroundColor(CodexTheme.mutedText)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    Button {
                        selectedCategory = cat
                    } label: {
                        Label(cat.title, systemImage: cat.icon)
                            .font(.system(size: 13))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsSidebarRowStyle(isSelected: selectedCategory == cat))
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(CodexTheme.sidebarBackground)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsPane(
                ollamaUri: $ollamaUri,
                systemPrompt: $systemPrompt,
                defaultOllamaModel: $defaultOllamaModel,
                ollamaBearerToken: $ollamaBearerToken,
                pingInterval: $pingInterval,
                appUserInitials: $appUserInitials,
                ollamaStatus: $ollamaStatus,
                ollamaLanguageModels: languageModelStore.models,
                checkServer: checkServer
            )
        case .appearance:
            AppearanceSettingsPane(
                colorScheme: $colorScheme,
                appLanguage: $appLanguage,
                languageRestartDialog: $languageRestartDialog
            )
        case .voice:
            VoiceSettingsPane(
                voiceIdentifier: $voiceIdentifier,
                voices: speechSynthesiser.voices
            )
        case .shortcuts:
            ShortcutsSettingsPane()
        case .advanced:
            AdvancedSettingsPane(
                deleteConversationsDialog: $deleteConversationsDialog
            )
        case nil:
            Text("请选择一个分类")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Binding var ollamaUri: String
    @Binding var systemPrompt: String
    @Binding var defaultOllamaModel: String
    @Binding var ollamaBearerToken: String
    @Binding var pingInterval: String
    @Binding var appUserInitials: String
    @Binding var ollamaStatus: Bool?
    var ollamaLanguageModels: [LanguageModelSD]
    var checkServer: () -> ()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("常规")

                // Connection
                settingsGroup("Ollama 连接") {
                    row("服务器地址") {
                        HStack(spacing: 8) {
                            TextField("http://localhost:11434", text: $ollamaUri, onCommit: checkServer)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                            statusDot
                            Button("检查", action: checkServer)
                                .buttonStyle(.bordered)
                        }
                    }
                    settingsDivider
                    row("Bearer Token") {
                        TextField("可选", text: $ollamaBearerToken)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    settingsDivider
                    row("Ping 间隔（秒）") {
                        TextField("5", text: $pingInterval)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                }

                // Model
                settingsGroup("模型") {
                    row("默认模型") {
                        Picker("", selection: $defaultOllamaModel) {
                            ForEach(ollamaLanguageModels, id: \.self) { m in
                                Text(m.name).tag(m.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                    settingsDivider
                    VStack(alignment: .leading, spacing: 6) {
                        Text("系统提示词")
                            .font(.system(size: 12))
                            .foregroundColor(CodexTheme.mutedText)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 90, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .background(settingsCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(CodexTheme.border, lineWidth: 1)
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // User
                settingsGroup("用户") {
                    row("姓名首字母") {
                        TextField("AM", text: $appUserInitials)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if let ok = ollamaStatus {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPane: View {
    @Binding var colorScheme: AppColorScheme
    @Binding var appLanguage: AppLanguage
    @Binding var languageRestartDialog: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("外观")

                settingsGroup("主题") {
                    row("配色方案") {
                        Picker("", selection: $colorScheme) {
                            ForEach(AppColorScheme.allCases, id: \.self) { s in
                                Text(s.toString).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                }

                settingsGroup("语言") {
                    row("界面语言") {
                        Picker("", selection: $appLanguage) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.toString).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        .onChange(of: appLanguage) { _, val in
                            val.apply()
                            languageRestartDialog = true
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Voice

private struct VoiceSettingsPane: View {
    @Binding var voiceIdentifier: String
    var voices: [AVSpeechSynthesisVoice]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("语音")

                settingsGroup("朗读语音") {
                    row("语音") {
                        Picker("", selection: $voiceIdentifier) {
                            ForEach(voices, id: \.identifier) { v in
                                Text(v.prettyName).tag(v.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("前往 系统设置 > 辅助功能 > 朗读内容 > 系统语音 > 管理语音 可下载更多语音。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("打开辅助功能设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPane: View {
    @ObservedObject private var store = ShortcutStore.shared
    @State private var query: String = ""
    @State private var recordingId: String?
    @State private var monitor: Any?
    @State private var conflictMessage: String?

    private var filtered: [ShortcutCommandMeta] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ShortcutStore.all }
        return ShortcutStore.all.filter {
            $0.title.lowercased().contains(q)
                || $0.subtitle.lowercased().contains(q)
                || (store.effective($0.id)?.displayKeys.joined().lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                paneTitle("键盘快捷键")
                Spacer()
                Button {
                    stopRecording()
                    store.resetAll()
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12))
                }
                .help("将所有快捷键恢复为默认值")
            }

            // Search box
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(CodexTheme.mutedText)
                TextField("搜索快捷键", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(CodexTheme.surfaceSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(settingsLightBorder))
            .environment(\.colorScheme, .light)

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            // Table
            VStack(spacing: 0) {
                HStack {
                    Text("命令")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("按键绑定")
                        .frame(width: 260, alignment: .leading)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(CodexTheme.mutedText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                settingsDivider

                if filtered.isEmpty {
                    Text("无匹配的快捷键")
                        .font(.system(size: 13))
                        .foregroundColor(CodexTheme.mutedText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        shortcutRow(item)
                        if index < filtered.count - 1 { settingsDivider }
                    }
                }
            }
            .background(settingsCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(settingsLightBorder))
            .environment(\.colorScheme, .light)

        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func shortcutRow(_ item: ShortcutCommandMeta) -> some View {
        let binding = store.effective(item.id)
        let isRecording = recordingId == item.id

        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(CodexTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if isRecording {
                    Text("按下快捷键… (Esc 取消)")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                } else if let binding {
                    ForEach(Array(binding.displayKeys.enumerated()), id: \.offset) { _, key in
                        keycap(key)
                    }
                } else {
                    Text("未指定")
                        .font(.system(size: 13))
                        .foregroundColor(CodexTheme.mutedText)
                }

                Spacer(minLength: 8)

                Button {
                    if isRecording { stopRecording() } else { startRecording(item.id) }
                } label: {
                    Image(systemName: isRecording ? "xmark.circle" : "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(CodexTheme.mutedText)
                }
                .buttonStyle(.plain)
                .help(isRecording ? "取消录制" : "修改快捷键")

                Button {
                    stopRecording()
                    store.clear(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(CodexTheme.mutedText)
                }
                .buttonStyle(.plain)
                .disabled(binding == nil)
                .help("清除快捷键")

                if store.isCustomized(item.id) {
                    Button {
                        stopRecording()
                        store.reset(item.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(CodexTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .help("恢复默认")
                }
            }
            .frame(width: 260, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isRecording ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.primary)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, 6)
            .background(settingsKeycapBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(settingsLightBorder))
    }

    // MARK: Key recording

    private func startRecording(_ id: String) {
        stopRecording()
        conflictMessage = nil
        recordingId = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleRecordingEvent(event)
            return nil // swallow the event so it doesn't trigger anything else
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recordingId = nil
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        guard let id = recordingId else { return }
        // Esc cancels.
        if event.keyCode == 53 { stopRecording(); return }
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else { return }

        let flags = event.modifierFlags
        var s = Shortcut(key: String(ch).lowercased())
        s.command = flags.contains(.command)
        s.option  = flags.contains(.option)
        s.control = flags.contains(.control)
        s.shift   = flags.contains(.shift)

        // Require at least one non-shift modifier so plain typing can't bind.
        guard s.command || s.option || s.control else { return }

        if let other = store.conflict(with: s, excluding: id) {
            conflictMessage = "“\(s.displayKeys.joined())” 已用于“\(other.title)”，已重新分配。"
            store.clear(other.id)
        } else {
            conflictMessage = nil
        }
        store.setShortcut(s, for: id)
        stopRecording()
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @Binding var deleteConversationsDialog: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("高级")

                settingsGroup("数据管理") {
                    HStack {
                        Text("清除所有对话和模型数据")
                            .font(.system(size: 13))
                        Spacer()
                        Button(role: .destructive) {
                            deleteConversationsDialog = true
                        } label: {
                            Text("清除所有数据")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Shared helpers (file-private)

private func paneTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 25, weight: .semibold))
        .foregroundColor(.primary.opacity(0.92))
}

private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(CodexTheme.mutedText)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(settingsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(settingsLightBorder))
        .environment(\.colorScheme, .light)
    }
    .frame(maxWidth: 764, alignment: .leading)
}

private var settingsCardBackground: Color {
    Color.white
}

private var settingsKeycapBackground: Color {
    Color(hex: "F7F6F3")
}

private var settingsLightBorder: Color {
    Color(hex: "DEDAD1")
}

private var settingsDivider: some View {
    Rectangle()
        .fill(Color(hex: "E8E4DB"))
        .frame(height: 1)
}

private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 13))
            .foregroundColor(.primary.opacity(0.86))
            .frame(width: 130, alignment: .leading)
        Spacer()
        content()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}

private struct SettingsSidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor(configuration))
            )
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }

    private func fillColor(_ configuration: Configuration) -> Color {
        if isSelected { return CodexTheme.rowSelected }
        if hover || configuration.isPressed { return CodexTheme.rowHover }
        return .clear
    }
}

#endif
