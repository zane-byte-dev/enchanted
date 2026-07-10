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
import KeyboardShortcuts

// MARK: - Category enum

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general     = "general"
    case pi          = "pi"
    case ollama      = "ollama"
    case appearance  = "appearance"
    case voice       = "voice"
    case shortcuts   = "shortcuts"
    case advanced    = "advanced"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "常规"
        case .pi:          return "Pi"
        case .ollama:      return "Ollama"
        case .appearance:  return "外观"
        case .voice:       return "语音"
        case .shortcuts:   return "快捷键"
        case .advanced:    return "高级"
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .pi:          return "terminal"
        case .ollama:      return "cube"
        case .appearance:  return "paintbrush"
        case .voice:       return "waveform"
        case .shortcuts:   return "keyboard"
        case .advanced:    return "wrench.and.screwdriver"
        }
    }
}

private enum PiSettingsStatus: Equatable {
    case checking
    case connected(models: [PiModelDescriptor])
    case failed(String)
}

// MARK: - Root view

struct SettingsMacOS: View {
    /// When provided, tapping "返回应用" calls this instead of SwiftUI dismiss.
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var envDismiss

    @State private var selectedCategory: SettingsCategory? = .pi

    // Shared stores
    private var languageModelStore = LanguageModelStore.shared
    private var conversationStore  = ConversationStore.shared

    // Persisted settings
    @AppStorage("ollamaUri")          private var ollamaUri: String          = ""
    @AppStorage("systemPrompt")       private var systemPrompt: String       = ""
    @AppStorage("vibrations")         private var vibrations: Bool           = true
    @AppStorage("colorScheme")        private var colorScheme: AppColorScheme = .system
    @AppStorage("defaultOllamaModel") private var defaultOllamaModel: String = ""
    @AppStorage("piDefaultModel")     private var piDefaultModel: String     = ""
    @AppStorage("ollamaBearerToken")  private var ollamaBearerToken: String  = ""
    @AppStorage("appUserInitials")    private var appUserInitials: String    = ""
    @AppStorage("pingInterval")       private var pingInterval: String       = "5"
    @AppStorage("voiceIdentifier")    private var voiceIdentifier: String    = ""

    // Pi drafts are intentionally kept out of AppStorage until the user leaves
    // Settings. This prevents an incomplete executable path from disrupting a
    // live connector while it is still being typed.
    @State private var piExecutable: String = AgentBackendConfig.piExecutable
    @State private var piWorkingDirectory: String = AgentBackendConfig.piWorkingDirectory
    @State private var piThinkingLevel: String = UserDefaults.standard.string(forKey: "piThinkingLevel") ?? "medium"
    @State private var piDefaultProvider: String = UserDefaults.standard.string(
        forKey: AgentBackendConfig.piDefaultProviderDefaultsKey
    ) ?? ""
    @State private var piStatus: PiSettingsStatus?

    @State private var appLanguage: AppLanguage = AppLanguage.current
    @State private var ollamaStatus: Bool?
    @State private var ollamaModels: [LanguageModel] = []
    @State private var deleteConversationsDialog = false
    @State private var languageRestartDialog      = false

    @StateObject private var speechSynthesiser = SpeechSynthesizer.shared
    private let voiceTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var voiceCancellable: AnyCancellable?

    // MARK: Actions

    private func save() {
        if ollamaUri.last == "/" { ollamaUri = String(ollamaUri.dropLast()) }
        OllamaService.shared.initEndpoint(url: ollamaUri, bearerToken: ollamaBearerToken)
        UserDefaults.standard.set(piThinkingLevel, forKey: "piThinkingLevel")
        let previousProvider = UserDefaults.standard.string(
            forKey: AgentBackendConfig.piDefaultProviderDefaultsKey
        ) ?? ""
        let providerChanged = previousProvider != piDefaultProvider
        UserDefaults.standard.set(
            piDefaultProvider,
            forKey: AgentBackendConfig.piDefaultProviderDefaultsKey
        )

        let launchConfigurationChanged = piExecutable != AgentBackendConfig.piExecutable
            || piWorkingDirectory != WorkspaceStore.shared.currentDirectory
        if piConfigurationIsValid, launchConfigurationChanged {
            AgentBackendConfig.applyPiSettings(
                executable: piExecutable,
                workingDirectory: piWorkingDirectory
            )
        } else if providerChanged {
            AgentBackendConfig.reconfigure()
        }
        Task { try? await languageModelStore.loadModels() }
    }

    private var piConfigurationIsValid: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.isExecutableFile(atPath: piExecutable)
            && FileManager.default.fileExists(atPath: piWorkingDirectory, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func handleDismiss() {
        save()
        AppStore.shared.showSettings = false
    }

    private func checkServer() {
        Task {
            OllamaService.shared.initEndpoint(url: ollamaUri)
            ollamaStatus = await OllamaService.shared.reachable()
            if ollamaStatus == true {
                ollamaModels = (try? await OllamaService.shared.getModels()) ?? []
            } else {
                ollamaModels = []
            }
        }
    }

    private func checkPi() {
        let executable = piExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = piWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            piStatus = .failed("Pi 可执行文件不存在或不可执行")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            piStatus = .failed("默认工作目录不存在")
            return
        }

        piStatus = .checking
        Task {
            let connector = AgentBackendConfig.makePiConnector(
                executable: executable,
                workingDirectory: directory
            )
            guard await connector.reachable() else {
                connector.terminate()
                await MainActor.run { piStatus = .failed("无法启动 Pi RPC 进程") }
                return
            }
            let detectedModels = await connector.diagnosticModels()
            connector.terminate()
            await MainActor.run {
                if let detectedModels {
                    piStatus = .connected(models: detectedModels)
                } else {
                    piStatus = .failed("Pi 已启动，但 RPC 没有响应")
                }
            }
        }
    }

    private func choosePiExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: piExecutable).deletingLastPathComponent()
        if panel.runModal() == .OK, let path = panel.url?.path {
            piExecutable = path
            piStatus = nil
        }
    }

    private func choosePiWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: piWorkingDirectory)
        if panel.runModal() == .OK, let path = panel.url?.path {
            piWorkingDirectory = path
            piStatus = nil
        }
    }

    private func openPiModelsConfig() {
        let url = AgentBackendConfig.piModelsConfigURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                let template = "{\n  \"providers\": {}\n}\n"
                try template.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(url)
        } catch {
            piStatus = .failed("无法打开 models.json：\(error.localizedDescription)")
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
        .onChange(of: defaultOllamaModel) { _, name in
            if AgentBackendConfig.currentKind == .ollama {
                languageModelStore.setModel(modelName: name)
            }
        }
        .onChange(of: piDefaultModel) { _, name in
            if AgentBackendConfig.currentKind == .pi {
                languageModelStore.setModel(modelName: name)
            }
        }
        .onAppear {
            if piDefaultModel.isEmpty, AgentBackendConfig.currentKind == .pi {
                piDefaultModel = defaultOllamaModel
            }
            voiceCancellable = voiceTimer.sink { _ in speechSynthesiser.fetchVoices() }
            if piStatus == nil { checkPi() }
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
                pingInterval: $pingInterval,
                appUserInitials: $appUserInitials
            )
        case .ollama:
            OllamaSettingsPane(
                ollamaUri: $ollamaUri,
                systemPrompt: $systemPrompt,
                defaultModel: $defaultOllamaModel,
                bearerToken: $ollamaBearerToken,
                ollamaStatus: $ollamaStatus,
                models: ollamaModels,
                checkServer: checkServer
            )
        case .pi:
            PiSettingsPane(
                executable: $piExecutable,
                workingDirectory: $piWorkingDirectory,
                defaultProvider: $piDefaultProvider,
                defaultModel: $piDefaultModel,
                thinkingLevel: $piThinkingLevel,
                status: piStatus,
                models: languageModelStore.models,
                executableIsOverridden: AgentBackendConfig.piExecutableIsEnvironmentOverridden,
                workingDirectoryIsOverridden: AgentBackendConfig.piWorkingDirectoryIsEnvironmentOverridden,
                chooseExecutable: choosePiExecutable,
                chooseWorkingDirectory: choosePiWorkingDirectory,
                detectExecutable: {
                    if let detected = AgentBackendConfig.detectedPiExecutable() {
                        piExecutable = detected
                        piStatus = nil
                    } else {
                        piStatus = .failed("未在常用安装位置找到 Pi")
                    }
                },
                openModelsConfig: openPiModelsConfig,
                checkConnection: checkPi
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

// MARK: - Pi

private struct PiSettingsPane: View {
    @Binding var executable: String
    @Binding var workingDirectory: String
    @Binding var defaultProvider: String
    @Binding var defaultModel: String
    @Binding var thinkingLevel: String
    let status: PiSettingsStatus?
    let models: [LanguageModelSD]
    let executableIsOverridden: Bool
    let workingDirectoryIsOverridden: Bool
    let chooseExecutable: () -> Void
    let chooseWorkingDirectory: () -> Void
    let detectExecutable: () -> Void
    let openModelsConfig: () -> Void
    let checkConnection: () -> Void

    private let thinkingLevels: [(id: String, label: String)] = [
        ("off", "关闭"),
        ("minimal", "最少"),
        ("low", "低"),
        ("medium", "中"),
        ("high", "高"),
        ("xhigh", "最高"),
    ]

    private var isChecking: Bool {
        status == .checking
    }

    private var availableModels: [PiModelDescriptor] {
        if case .connected(let detected) = status, !detected.isEmpty {
            return detected
        }
        return models.map { model in
            PiModelDescriptor(
                modelID: model.name,
                name: model.name,
                provider: model.providerID ?? model.modelProvider?.rawValue ?? "unknown",
                reasoning: false,
                input: model.supportsImages ? ["text", "image"] : ["text"]
            )
        }
    }

    private var availableProviderIDs: [String] {
        Array(Set(availableModels.map(\.provider))).sorted()
    }

    private var providerModels: [PiModelDescriptor] {
        let effectiveProvider = defaultProvider.isEmpty ? availableProviderIDs.first : defaultProvider
        return availableModels.filter { $0.provider == effectiveProvider }
    }

    private var selectedProviderModel: PiModelDescriptor? {
        providerModels.first { $0.modelID == defaultModel } ?? providerModels.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    paneTitle("Pi")
                    Spacer()
                    connectionStatus
                }

                settingsGroup("运行环境") {
                    row("可执行文件") {
                        HStack(spacing: 8) {
                            TextField("/path/to/pi", text: $executable)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .disabled(executableIsOverridden)
                            Button("选择…", action: chooseExecutable)
                                .buttonStyle(.bordered)
                                .disabled(executableIsOverridden)
                            Button("自动检测", action: detectExecutable)
                                .buttonStyle(.bordered)
                                .disabled(executableIsOverridden)
                        }
                    }
                    if executableIsOverridden {
                        overrideNotice("PI_EXECUTABLE")
                    }

                    settingsDivider

                    row("默认工作目录") {
                        HStack(spacing: 8) {
                            TextField("选择新对话使用的项目目录", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .disabled(workingDirectoryIsOverridden)
                            Button("选择…", action: chooseWorkingDirectory)
                                .buttonStyle(.bordered)
                                .disabled(workingDirectoryIsOverridden)
                        }
                    }
                    if workingDirectoryIsOverridden {
                        overrideNotice("PI_CWD")
                    }

                    settingsDivider

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("连接测试")
                                .font(.system(size: 13))
                            Text("启动临时 RPC 进程并读取可用模型，不会修改当前会话。")
                                .font(.system(size: 11))
                                .foregroundColor(CodexTheme.mutedText)
                        }
                        Spacer()
                        Button(action: checkConnection) {
                            HStack(spacing: 6) {
                                if isChecking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isChecking ? "正在检测…" : "检测连接")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isChecking)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                settingsGroup("Provider 与模型") {
                    row("默认 Provider") {
                        if availableProviderIDs.isEmpty {
                            Text("暂无可用 Provider")
                                .font(.system(size: 12))
                                .foregroundColor(CodexTheme.mutedText)
                        } else {
                            Picker("", selection: $defaultProvider) {
                                ForEach(availableProviderIDs, id: \.self) { provider in
                                    Text(providerDisplayName(provider)).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
                        }
                    }
                    settingsDivider
                    row("默认模型") {
                        if providerModels.isEmpty {
                            Text("暂无可用模型")
                                .font(.system(size: 12))
                                .foregroundColor(CodexTheme.mutedText)
                        } else {
                            Picker("", selection: $defaultModel) {
                                ForEach(providerModels) { model in
                                    Text(model.modelID).tag(model.modelID)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
                        }
                    }
                    if let model = selectedProviderModel {
                        settingsDivider
                        providerDetail(model)
                    }
                }

                settingsGroup("推理") {
                    row("Thinking Level") {
                        Picker("", selection: $thinkingLevel) {
                            ForEach(thinkingLevels, id: \.id) { level in
                                Text(level.label).tag(level.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 390)
                    }
                }

                settingsGroup("自定义 Provider") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pi models.json")
                                .font(.system(size: 13, weight: .medium))
                            Text(AgentBackendConfig.piModelsConfigURL.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(CodexTheme.mutedText)
                                .lineLimit(1)
                            Text("可配置 baseUrl、API 类型、环境变量密钥引用和模型列表。")
                                .font(.system(size: 11))
                                .foregroundColor(CodexTheme.mutedText)
                        }
                        Spacer()
                        Button("打开配置文件", action: openModelsConfig)
                            .buttonStyle(.bordered)
                        Button("重新加载", action: checkConnection)
                            .buttonStyle(.bordered)
                            .disabled(isChecking)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                settingsGroup("配置说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("工作目录只作为新对话的默认目录；已有对话继续使用各自绑定的项目。", systemImage: "folder")
                        Label("设置保存后，空闲 Pi 连接会立即重建；正在执行的任务会先正常完成。", systemImage: "arrow.triangle.2.circlepath")
                        Label("当前“系统提示词”仍属于 Ollama 配置，尚未映射到 Pi RPC。", systemImage: "info.circle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(CodexTheme.mutedText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .padding(28)
        }
        .onChange(of: availableProviderIDs, initial: true) { _, providers in
            guard !providers.isEmpty else { return }
            if !providers.contains(defaultProvider) {
                defaultProvider = providers[0]
            }
            selectFirstModelIfNeeded()
        }
        .onChange(of: defaultProvider) { _, _ in
            selectFirstModelIfNeeded(force: true)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch status {
        case .checking:
            Label("正在检测", systemImage: "circle.dotted")
                .foregroundColor(CodexTheme.mutedText)
        case .connected(let models):
            Label("已连接 · \(models.count) 个模型", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .lineLimit(1)
        case nil:
            Label("尚未检测", systemImage: "circle")
                .foregroundColor(CodexTheme.mutedText)
        }
    }

    private func overrideNotice(_ variable: String) -> some View {
        Text("当前值由环境变量 \(variable) 覆盖，设置页中的修改不会生效。")
            .font(.system(size: 11))
            .foregroundColor(.orange)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    private func selectFirstModelIfNeeded(force: Bool = false) {
        guard let first = providerModels.first else { return }
        if force || !providerModels.contains(where: { $0.modelID == defaultModel }) {
            defaultModel = first.modelID
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        provider.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func providerDetail(_ model: PiModelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                providerMetadata("Provider ID", model.provider)
                if !model.api.isEmpty { providerMetadata("API", model.api) }
                providerMetadata("模型数", "\(providerModels.count)")
                providerMetadata("推理", model.reasoning ? "支持" : "不支持")
                providerMetadata("图像", model.input.contains("image") ? "支持" : "不支持")
            }
            if !model.baseURL.isEmpty {
                Text(model.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(CodexTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func providerMetadata(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(CodexTheme.faintText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Binding var pingInterval: String
    @Binding var appUserInitials: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("常规")

                settingsGroup("用户") {
                    row("姓名首字母") {
                        TextField("AM", text: $appUserInitials)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                settingsGroup("后台状态") {
                    row("检查间隔（秒）") {
                        HStack(spacing: 8) {
                            TextField("5", text: $pingInterval)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("设为 0 可关闭；重启应用后生效")
                                .font(.system(size: 11))
                                .foregroundColor(CodexTheme.mutedText)
                        }
                    }
                }
            }
            .padding(28)
        }
    }

}

// MARK: - Ollama

private struct OllamaSettingsPane: View {
    @Binding var ollamaUri: String
    @Binding var systemPrompt: String
    @Binding var defaultModel: String
    @Binding var bearerToken: String
    @Binding var ollamaStatus: Bool?
    var models: [LanguageModel]
    var checkServer: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("Ollama")

                settingsGroup("连接") {
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
                        SecureField("可选", text: $bearerToken)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                }

                settingsGroup("模型") {
                    row("默认模型") {
                        if models.isEmpty {
                            Text(defaultModel.isEmpty ? "连接后读取模型" : defaultModel)
                                .font(.system(size: 12))
                                .foregroundColor(CodexTheme.mutedText)
                        } else {
                            Picker("", selection: $defaultModel) {
                                ForEach(models, id: \.name) { model in
                                    Text(model.name).tag(model.name)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }
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

                settingsGroup("说明") {
                    Text("这些配置仅在后端切换为 Ollama 时使用，不影响 Pi 会话。")
                        .font(.system(size: 12))
                        .foregroundColor(CodexTheme.mutedText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
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
    @ObservedObject private var voiceInput = VoiceInputCoordinator.shared
    @ObservedObject private var senseVoiceModel = SenseVoiceModelManager.shared
    @AppStorage(VoiceInputPreferences.engineKey) private var recognitionEngine = VoiceRecognitionEngine.senseVoice.rawValue
    @AppStorage(VoiceInputPreferences.localeKey) private var inputLocale = "auto"
    @AppStorage(VoiceInputPreferences.onDeviceOnlyKey) private var onDeviceOnly = false
    @AppStorage(VoiceInputPreferences.aiCorrectionKey) private var aiCorrection = false
    @AppStorage(VoiceInputPreferences.removeTrailingPeriodKey) private var removeTrailingPeriod = false
    @AppStorage(VoiceInputPreferences.dictionaryKey) private var voiceDictionary = ""

    private let inputLanguages: [(id: String, name: String)] = [
        ("auto", "跟随系统"),
        ("zh-CN", "普通话（简体中文）"),
        ("zh-TW", "普通话（繁体中文）"),
        ("yue-Hant-HK", "粤语"),
        ("en-US", "英语（美国）"),
        ("ja-JP", "日语"),
        ("ko-KR", "韩语"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneTitle("语音")

                settingsGroup("语音输入") {
                    row("按住说话") {
                        KeyboardShortcuts.Recorder(for: .voiceInput)
                    }
                    settingsDivider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按住快捷键开始录音，松开后会把识别结果粘贴到录音前正在使用的应用。按 Esc 可取消。")
                            .font(.system(size: 12))
                            .foregroundColor(CodexTheme.mutedText)
                        HStack(spacing: 8) {
                            Button(voiceInput.state.isActive ? "结束测试" : "测试语音输入") {
                                voiceInput.toggleRecording()
                            }
                            .buttonStyle(.bordered)
                            if case .failed(let message) = voiceInput.state {
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                settingsGroup("识别与整理") {
                    row("识别模型") {
                        Picker("", selection: $recognitionEngine) {
                            Text("SenseVoice Small（本地）")
                                .tag(VoiceRecognitionEngine.senseVoice.rawValue)
                            Text("Apple Speech")
                                .tag(VoiceRecognitionEngine.appleSpeech.rawValue)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: recognitionEngine) { _, engine in
                            Task {
                                if engine == VoiceRecognitionEngine.senseVoice.rawValue {
                                    await voiceInput.prewarm()
                                } else {
                                    await SenseVoiceInferenceEngine.shared.unload()
                                }
                            }
                        }
                    }
                    settingsDivider
                    row("识别语言") {
                        Picker("", selection: $inputLocale) {
                            ForEach(inputLanguages, id: \.id) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: inputLocale) { _, _ in
                            guard recognitionEngine == VoiceRecognitionEngine.senseVoice.rawValue else { return }
                            Task { await voiceInput.prewarm() }
                        }
                    }
                    settingsDivider
                    if recognitionEngine == VoiceRecognitionEngine.appleSpeech.rawValue {
                        row("仅使用本地识别") {
                            Toggle("", isOn: $onDeviceOnly)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        settingsDivider
                    }
                    row("AI 润色") {
                        Toggle("", isOn: $aiCorrection)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsDivider
                    row("移除句末句号") {
                        Toggle("", isOn: $removeTrailingPeriod)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsDivider
                    VStack(alignment: .leading, spacing: 7) {
                        Text("个人词典")
                            .font(.system(size: 12, weight: .medium))
                        TextEditor(text: $voiceDictionary)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 76, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(settingsCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(settingsLightBorder, lineWidth: 1)
                            }
                        Text("每行一条，例如：错误词 => 正确词。AI 润色失败或超时会自动使用词典处理后的原始转写。")
                            .font(.system(size: 11))
                            .foregroundColor(CodexTheme.mutedText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                settingsGroup("SenseVoice Small") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: senseVoiceModel.isModelReady ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
                                .foregroundColor(senseVoiceModel.isModelReady ? .green : CodexTheme.mutedText)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(senseVoiceModel.isModelReady ? "本地模型已安装" : "本地模型未安装")
                                    .font(.system(size: 12, weight: .medium))
                                Text("INT8 模型；下载约 155 MB，安装后约 228 MB。识别过程不上传录音。")
                                    .font(.system(size: 11))
                                    .foregroundColor(CodexTheme.mutedText)
                            }
                            Spacer()
                            modelActionButton
                        }

                        if case .downloading(let progress) = senseVoiceModel.state {
                            ProgressView(value: progress)
                            Text("正在下载… \(Int(progress * 100))%")
                                .font(.system(size: 10))
                                .foregroundColor(CodexTheme.mutedText)
                        } else if case .installing = senseVoiceModel.state {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在校验并安装模型…")
                                .font(.system(size: 10))
                                .foregroundColor(CodexTheme.mutedText)
                        } else if case .failed(let message) = senseVoiceModel.state {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }

                        if recognitionEngine == VoiceRecognitionEngine.senseVoice.rawValue,
                           !senseVoiceModel.isModelReady {
                            Text("模型安装前，语音输入会自动使用 Apple Speech。")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

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
        .onAppear { senseVoiceModel.refreshState() }
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch senseVoiceModel.state {
        case .downloading, .installing:
            Button("取消") { senseVoiceModel.cancelDownload() }
                .buttonStyle(.bordered)
        case .ready:
            Button("删除") { senseVoiceModel.deleteModel() }
                .buttonStyle(.bordered)
        case .missing, .failed:
            Button("下载模型") { senseVoiceModel.downloadModel() }
                .buttonStyle(.borderedProminent)
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
