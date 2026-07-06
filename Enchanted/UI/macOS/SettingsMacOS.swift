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
    case general     = "General"
    case appearance  = "Appearance"
    case voice       = "Voice"
    case shortcuts   = "Shortcuts"
    case completions = "Completions"
    case advanced    = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .appearance:  return "paintbrush"
        case .voice:       return "waveform"
        case .shortcuts:   return "keyboard"
        case .completions: return "textformat.abc"
        case .advanced:    return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Root view

struct SettingsMacOS: View {
    @Environment(\.dismiss) private var dismiss

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
        }
        .frame(minWidth: 740, minHeight: 520)
        .preferredColorScheme(colorScheme.toiOSFormat)
        .onChange(of: defaultOllamaModel) { _, name in languageModelStore.setModel(modelName: name) }
        .onAppear {
            voiceCancellable = voiceTimer.sink { _ in speechSynthesiser.fetchVoices() }
        }
        .onDisappear {
            save()
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
            // Back button
            Button {
                save()
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回应用")
                        .font(.system(size: 13))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            List(SettingsCategory.allCases, selection: $selectedCategory) { cat in
                Label(cat.rawValue, systemImage: cat.icon)
                    .tag(cat)
            }
            .listStyle(.sidebar)
        }
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
        case .completions:
            CompletionsSettingsPane()
        case .advanced:
            AdvancedSettingsPane(
                deleteConversationsDialog: $deleteConversationsDialog
            )
        case nil:
            Text("Select a category")
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
            VStack(alignment: .leading, spacing: 28) {
                paneTitle("General")

                // Connection
                settingsGroup("Ollama 连接") {
                    row("服务器地址") {
                        HStack(spacing: 8) {
                            TextField("http://localhost:11434", text: $ollamaUri, onCommit: checkServer)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                            statusDot
                            Button("检查", action: checkServer)
                        }
                    }
                    Divider()
                    row("Bearer Token") {
                        TextField("可选", text: $ollamaBearerToken)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    Divider()
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
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("系统提示词")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 90, maxHeight: 160)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.25)))
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
            VStack(alignment: .leading, spacing: 28) {
                paneTitle("Appearance")

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
            VStack(alignment: .leading, spacing: 28) {
                paneTitle("Voice")

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
    private let shortcuts = [
        KeyboardShortcut(id: 1, keys: ["⌃", "⌘", "K"], description: "Open Panel Window"),
        KeyboardShortcut(id: 2, keys: ["⌘", "N"],       description: "New Conversation"),
        KeyboardShortcut(id: 3, keys: ["⌘", "⌥", "S"], description: "Hide/Show Sidebar"),
        KeyboardShortcut(id: 4, keys: ["⌘", "V"],       description: "Paste text or image from clipboard"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Shortcuts")
                .padding(28)
                .padding(.bottom, 0)

            Table(shortcuts) {
                TableColumn("快捷键") { s in
                    Text(s.keys.joined(separator: " + "))
                        .font(.system(size: 13, design: .monospaced))
                }
                .width(min: 130, ideal: 150)
                TableColumn("说明") { s in
                    Text(s.description)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Completions

private struct CompletionsSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Completions")
                .padding(28)
                .padding(.bottom, 0)
            CompletionsEditor()
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @Binding var deleteConversationsDialog: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                paneTitle("Advanced")

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
        .font(.system(size: 26, weight: .bold))
}

private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15)))
    }
    .frame(maxWidth: 580)
}

private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 13))
            .frame(width: 130, alignment: .leading)
        Spacer()
        content()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
}

#endif
