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
import UniformTypeIdentifiers

// MARK: - Category enum

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general     = "general"
    case pi          = "pi"
    case automations = "automations"
    case extensions  = "extensions"
    case appearance  = "appearance"
    case voice       = "voice"
    case shortcuts   = "shortcuts"
    case advanced    = "advanced"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return String(localized: "常规")
        case .pi:          return "Pi"
        case .automations: return String(localized: "Scheduled Tasks")
        case .extensions:  return String(localized: "Extensions")
        case .appearance:  return String(localized: "外观")
        case .voice:       return String(localized: "语音")
        case .shortcuts:   return String(localized: "快捷键")
        case .advanced:    return String(localized: "高级")
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .pi:          return "terminal"
        case .automations: return "calendar.badge.clock"
        case .extensions:  return "puzzlepiece.extension"
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
    @AppStorage("vibrations")         private var vibrations: Bool           = true
    @AppStorage("colorScheme")        private var colorScheme: AppColorScheme = .system
    @AppStorage("piDefaultModel")     private var piDefaultModel: String     = ""
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
    @State private var deleteConversationsDialog = false
    @State private var languageRestartDialog      = false

    @StateObject private var speechSynthesiser = SpeechSynthesizer.shared
    private let voiceTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var voiceCancellable: AnyCancellable?

    // MARK: Actions

    private func save() {
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
            conversationStore.deleteAllConversations()
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
                .background(CodexTheme.appBackground)
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(CodexTheme.appBackground)
        .tint(CodexTheme.primaryText)
        .preferredColorScheme(colorScheme.toiOSFormat)
        .onChange(of: piDefaultModel) { _, name in
            languageModelStore.setModel(modelName: name)
        }
        .onAppear {
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
        case .automations:
            ScheduledTasksSettingsPane()
        case .extensions:
            PiExtensionsSettingsPane()
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

// MARK: - Scheduled Tasks

private struct ScheduledTasksSettingsPane: View {
    @State private var store = ScheduledTaskStore.shared
    @State private var showEditor = false
    @State private var editingTaskID: UUID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var workingDirectory = WorkspaceStore.shared.currentDirectory
    @State private var modelName = ""
    @State private var intervalSeconds = 86_400.0
    @State private var nextRunAt = Date.now.addingTimeInterval(3600)
    @State private var missedPolicy = "run_once"

    private let intervals: [(String, Double)] = [
        ("Every hour", 3_600),
        ("Every day", 86_400),
        ("Every week", 604_800)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    paneTitle("Scheduled Tasks")
                    Spacer()
                    if store.isLoaded && !store.tasks.isEmpty {
                        Button(action: { openEditor(nil) }) {
                            Label("New Schedule", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("Schedules run only while Mox is open. Each run creates a normal task with visible permissions, history, and notifications.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !store.isLoaded {
                    ProgressView()
                } else if store.tasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No Scheduled Tasks")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Create a recurring coding task such as a daily review or test run.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button(action: { openEditor(nil) }) {
                            Label("New Schedule", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.tasks) { task in
                            scheduledTaskRow(task)
                        }
                    }
                }
            }
            .padding(28)
        }
        .task { await store.reload() }
        .sheet(isPresented: $showEditor) { editorSheet }
    }

    @ViewBuilder
    private func scheduledTaskRow(_ task: ScheduledTaskSD) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { value in
                        task.isEnabled = value
                        Task { await store.save(task) }
                    }
                ))
                .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.system(size: 13, weight: .semibold))
                    Text(task.prompt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Run Now") { Task { await store.runNow(task) } }
                Button("Edit") { openEditor(task) }
                Menu {
                    Button("Delete", role: .destructive) {
                        Task { await store.delete(task) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 12) {
                Label(task.nextRunAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                Text(intervalLabel(task.intervalSeconds))
                Text(URL(fileURLWithPath: task.workingDirectory).lastPathComponent)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            let history = store.history(for: task)
            if !history.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(history.prefix(8)) { record in
                            HStack {
                                Image(systemName: historyIcon(record.status))
                                Text(record.launchedAt.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(historyLabel(record.status))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("\(localizedSettingsString("Run History")) (\(history.count))")
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CodexTheme.border))
    }

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localizedSettingsString(
                editingTaskID == nil ? "New Scheduled Task" : "Edit Scheduled Task"
            ))
                .font(.headline)
            TextField("Name", text: $name)
            Text("Task instructions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CodexTheme.border))
            HStack {
                TextField("Working directory", text: $workingDirectory)
                Button("Choose…", action: chooseDirectory)
            }
            Picker("Model", selection: $modelName) {
                Text("Default model").tag("")
                ForEach(LanguageModelStore.shared.models) { model in
                    Text(model.name).tag(model.name)
                }
            }
            Picker("Repeat", selection: $intervalSeconds) {
                ForEach(intervals, id: \.1) { label, seconds in
                    Text(localizedSettingsString(label)).tag(seconds)
                }
            }
            DatePicker("Next run", selection: $nextRunAt)
            Picker("If a run was missed", selection: $missedPolicy) {
                Text("Run once when the app opens").tag("run_once")
                Text("Skip to the next occurrence").tag("skip")
            }
            HStack {
                Spacer()
                Button("Cancel") { showEditor = false }
                Button("Save") { saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workingDirectory.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 500)
    }

    private func openEditor(_ task: ScheduledTaskSD?) {
        editingTaskID = task?.id
        name = task?.name ?? ""
        prompt = task?.prompt ?? ""
        workingDirectory = task?.workingDirectory ?? WorkspaceStore.shared.currentDirectory
        modelName = task?.modelName ?? ""
        intervalSeconds = task?.intervalSeconds ?? 86_400
        nextRunAt = task?.nextRunAt ?? Date.now.addingTimeInterval(3600)
        missedPolicy = task?.missedPolicy ?? "run_once"
        showEditor = true
    }

    private func saveEditor() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = editingTaskID, let task = store.tasks.first(where: { $0.id == id }) {
                task.name = trimmedName
                task.prompt = trimmedPrompt
                task.workingDirectory = workingDirectory
                task.modelName = modelName.isEmpty ? nil : modelName
                task.intervalSeconds = intervalSeconds
                task.nextRunAt = nextRunAt
                task.missedPolicy = missedPolicy
                await store.save(task)
            } else {
                await store.create(
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    workingDirectory: workingDirectory,
                    modelName: modelName.isEmpty ? nil : modelName,
                    intervalSeconds: intervalSeconds,
                    nextRunAt: nextRunAt,
                    missedPolicy: missedPolicy
                )
            }
            showEditor = false
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path { workingDirectory = path }
    }

    private func intervalLabel(_ seconds: Double) -> String {
        localizedSettingsString(intervals.first(where: { $0.1 == seconds })?.0 ?? "Custom")
    }

    private func historyIcon(_ status: String) -> String {
        status == "skipped" || status == "failed_no_model" ? "exclamationmark.circle" : "checkmark.circle"
    }

    private func historyLabel(_ status: String) -> String {
        let key = switch status {
        case "manual": "Manual"
        case "scheduled": "Scheduled"
        case "missed_run": "Recovered missed run"
        case "completed": "Completed"
        case "skipped": "Skipped"
        case "failed": "Failed"
        default: "Failed"
        }
        return localizedSettingsString(key)
    }
}

// MARK: - Pi Extensions / Packages

private struct PiInstalledPackage: Identifiable, Hashable {
    let source: String
    let scope: String
    var id: String { "\(scope):\(source)" }
}

@MainActor
@Observable
private final class PiPackageManager {
    var packages: [PiInstalledPackage] = []
    var isBusy = false
    var lastOutput = ""
    var lastError: String?

    func reload() {
        let userURL = URL(fileURLWithPath: AgentBackendConfig.piAgentDirectory)
            .appendingPathComponent("settings.json")
        let projectURL = URL(fileURLWithPath: WorkspaceStore.shared.currentDirectory)
            .appendingPathComponent(".pi/settings.json")
        packages = Self.readPackages(at: userURL, scope: "user")
            + Self.readPackages(at: projectURL, scope: "project")
        packages.sort { ($0.scope, $0.source) < ($1.scope, $1.source) }
    }

    func install(source: String, local: Bool) async {
        var arguments = ["install", source]
        if local { arguments.append("--local") }
        arguments.append("--approve")
        await run(arguments)
    }

    func remove(_ package: PiInstalledPackage) async {
        var arguments = ["remove", package.source]
        if package.scope == "project" { arguments.append("--local") }
        arguments.append("--approve")
        await run(arguments)
    }

    func update(_ package: PiInstalledPackage) async {
        await run(["update", package.source, "--approve"])
    }

    func updateAll() async {
        await run(["update", "--extensions", "--approve"])
    }

    private func run(_ arguments: [String]) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        lastOutput = ""
        let executable = AgentBackendConfig.piExecutable
        let cwd = WorkspaceStore.shared.currentDirectory
        let result = await Task.detached {
            Self.execute(executable: executable, arguments: arguments, cwd: cwd)
        }.value
        lastOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            reload()
            AgentBackendConfig.reconfigure()
        } else {
            lastError = lastOutput.isEmpty ? "pi command failed (\(result.exitCode))" : lastOutput
        }
        isBusy = false
    }

    nonisolated private static func execute(
        executable: String,
        arguments: [String],
        cwd: String
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        let usefulPath = [
            NSHomeDirectory() + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")
        environment["PATH"] = usefulPath + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    nonisolated private static func readPackages(
        at url: URL,
        scope: String
    ) -> [PiInstalledPackage] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPackages = object["packages"] as? [Any] else { return [] }
        return rawPackages.compactMap { item in
            if let source = item as? String {
                return PiInstalledPackage(source: source, scope: scope)
            }
            if let dictionary = item as? [String: Any],
               let source = dictionary["source"] as? String {
                return PiInstalledPackage(source: source, scope: scope)
            }
            return nil
        }
    }
}

private struct PiExtensionsSettingsPane: View {
    @State private var manager = PiPackageManager()
    @State private var showInstaller = false
    @State private var source = ""
    @State private var installLocally = false
    @State private var pendingRemoval: PiInstalledPackage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    paneTitle("Extensions")
                    Spacer()
                    if !manager.packages.isEmpty {
                        Button("Update All") { Task { await manager.updateAll() } }
                            .disabled(manager.isBusy)
                        Button(action: { showInstaller = true }) {
                            Label("Install Extension", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isBusy)
                    }
                }

                Text("Uses pi's native package manager. Sources may be npm packages, Git repositories, URLs, or local paths. Changes apply to new agent processes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if manager.isBusy {
                    HStack { ProgressView().controlSize(.small); Text("Running pi package command…") }
                        .font(.system(size: 12))
                }

                if manager.packages.isEmpty && !manager.isBusy {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No Extensions Installed")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Install a pi package to add tools, commands, themes, or integrations.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button(action: { showInstaller = true }) {
                            Label("Install Extension", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    VStack(spacing: 8) {
                        ForEach(manager.packages) { package in
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(package.source)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(package.scope == "project" ? "Project" : "User")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Update") { Task { await manager.update(package) } }
                                Button("Remove", role: .destructive) { pendingRemoval = package }
                            }
                            .padding(11)
                            .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CodexTheme.border))
                        }
                    }
                }

                if let error = manager.lastError {
                    LabeledContent("Error") {
                        Text(error).textSelection(.enabled)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                } else if !manager.lastOutput.isEmpty {
                    DisclosureGroup("Last command output") {
                        Text(manager.lastOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(28)
        }
        .onAppear { manager.reload() }
        .sheet(isPresented: $showInstaller) { installerSheet }
        .confirmationDialog(
            "Remove extension?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let package = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await manager.remove(package) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.source ?? "")
        }
    }

    private var installerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install pi Extension").font(.headline)
            TextField("npm:@scope/package, Git URL, or local path", text: $source)
                .textFieldStyle(.roundedBorder)
                .frame(width: 460)
            Picker("Install scope", selection: $installLocally) {
                Text("User — available in every project").tag(false)
                Text("Project — only this working directory").tag(true)
            }
            Text("Package code runs inside pi and can register tools. Install only sources you trust.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showInstaller = false }
                Button("Install") {
                    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    showInstaller = false
                    source = ""
                    Task { await manager.install(source: trimmed, local: installLocally) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
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
    @AppStorage("piAutoCompaction") private var autoCompaction = true
    @AppStorage("piApprovalMode") private var approvalMode = AgentBackendConfig.approvalMode
    @AppStorage("piNetworkPolicy") private var networkPolicy = AgentBackendConfig.networkPolicy
    @State private var conversationStore = ConversationStore.shared

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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        paneTitle("Pi")
                        Spacer()
                        connectionStatus
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        paneTitle("Pi")
                        connectionStatus
                    }
                }

                settingsGroup("运行环境") {
                    row("可执行文件") {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                executableField
                                executableButtons
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                executableField
                                executableButtons
                            }
                        }
                    }
                    if executableIsOverridden {
                        overrideNotice("PI_EXECUTABLE")
                    } else if AgentBackendConfig.isBundledPiExecutable(executable) {
                        HStack(spacing: 5) {
                            Image(systemName: "shippingbox.fill")
                            Text("内置 pi · 随 Mox 签名和更新")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 16)
                    }

                    settingsDivider

                    row("默认工作目录") {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                workingDirectoryField
                                workingDirectoryButton
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                workingDirectoryField
                                workingDirectoryButton
                            }
                        }
                    }
                    if workingDirectoryIsOverridden {
                        overrideNotice("PI_CWD")
                    }

                    settingsDivider

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            connectionTestDescription
                            Spacer()
                            connectionTestButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            connectionTestDescription
                            connectionTestButton
                        }
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
                        .frame(maxWidth: 390)
                    }
                    settingsDivider
                    row("自动压缩上下文") {
                        Toggle("上下文接近上限时由 pi 自动 Compact", isOn: $autoCompaction)
                            .toggleStyle(.switch)
                            .onChange(of: autoCompaction) { _, enabled in
                                Task { await conversationStore.applyAutoCompactionSetting(enabled) }
                            }
                    }
                }

                settingsGroup("安全") {
                    row("操作审批") {
                        Picker("", selection: $approvalMode) {
                            Text("关闭").tag("off")
                            Text("仅高风险").tag("dangerous")
                            Text("所有变更操作").tag("mutations")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 390)
                        .onChange(of: approvalMode) { _, _ in
                            AgentBackendConfig.reconfigure()
                        }
                    }
                    settingsDivider
                    row("网络命令策略") {
                        Picker("", selection: $networkPolicy) {
                            Text("允许").tag("allow")
                            Text("每次询问").tag("ask")
                            Text("阻止").tag("block")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 390)
                        .onChange(of: networkPolicy) { _, _ in
                                AgentBackendConfig.reconfigure()
                        }
                    }
                }

                settingsGroup("自定义 Provider") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            modelsConfigDescription
                            Spacer()
                            modelsConfigButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            modelsConfigDescription
                            modelsConfigButtons
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                settingsGroup("配置说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("工作目录只作为新对话的默认目录；已有对话继续使用各自绑定的项目。", systemImage: "folder")
                        Label("设置保存后，空闲 Pi 连接会立即重建；正在执行的任务会先正常完成。", systemImage: "arrow.triangle.2.circlepath")
                        Label("模型与 Provider 配置由 Pi RPC 读取并应用到新会话。", systemImage: "info.circle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(CodexTheme.mutedText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var modelsConfigDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pi models.json")
                .font(.system(size: 13, weight: .medium))
            Text(AgentBackendConfig.piModelsConfigURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(CodexTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("可配置 baseUrl、API 类型、环境变量密钥引用和模型列表。")
                .font(.system(size: 11))
                .foregroundColor(CodexTheme.mutedText)
        }
    }

    private var executableField: some View {
        TextField("/path/to/pi", text: $executable)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .disabled(executableIsOverridden)
    }

    private var executableButtons: some View {
        HStack(spacing: 8) {
            Button("选择…", action: chooseExecutable)
                .buttonStyle(.bordered)
                .disabled(executableIsOverridden)
            Button("自动检测", action: detectExecutable)
                .buttonStyle(.bordered)
                .disabled(executableIsOverridden)
        }
    }

    private var workingDirectoryField: some View {
        TextField("选择新对话使用的项目目录", text: $workingDirectory)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .disabled(workingDirectoryIsOverridden)
    }

    private var workingDirectoryButton: some View {
        Button("选择…", action: chooseWorkingDirectory)
            .buttonStyle(.bordered)
            .disabled(workingDirectoryIsOverridden)
    }

    private var connectionTestDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("连接测试")
                .font(.system(size: 13))
            Text("启动临时 RPC 进程并读取可用模型，不会修改当前会话。")
                .font(.system(size: 11))
                .foregroundColor(CodexTheme.mutedText)
        }
    }

    private var connectionTestButton: some View {
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

    private var modelsConfigButtons: some View {
        HStack(spacing: 8) {
            Button("打开配置文件", action: openModelsConfig)
                .buttonStyle(.bordered)
            Button("重新加载", action: checkConnection)
                .buttonStyle(.bordered)
                .disabled(isChecking)
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
                .foregroundColor(CodexTheme.primaryText)
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

// MARK: - Appearance

private struct AppearanceSettingsPane: View {
    @Binding var colorScheme: AppColorScheme
    @Binding var appLanguage: AppLanguage
    @Binding var languageRestartDialog: Bool

    @AppStorage(ThemePreferences.lightAccentKey) private var lightAccent = ThemePreferences.lightAccentDefault
    @AppStorage(ThemePreferences.lightBackgroundKey) private var lightBackground = ThemePreferences.lightBackgroundDefault
    @AppStorage(ThemePreferences.lightForegroundKey) private var lightForeground = ThemePreferences.lightForegroundDefault
    @AppStorage(ThemePreferences.darkAccentKey) private var darkAccent = ThemePreferences.darkAccentDefault
    @AppStorage(ThemePreferences.darkBackgroundKey) private var darkBackground = ThemePreferences.darkBackgroundDefault
    @AppStorage(ThemePreferences.darkForegroundKey) private var darkForeground = ThemePreferences.darkForegroundDefault
    @AppStorage(ThemePreferences.translucentSidebarKey) private var translucentSidebar = true
    @AppStorage(ThemePreferences.contrastKey) private var contrast = 50.0
    @AppStorage(ThemePreferences.bodyFontSizeKey) private var bodyFontSize = 14.0
    @AppStorage(ThemePreferences.codeFontSizeKey) private var codeFontSize = 12.0

    @State private var importError: String?

    private var themeSignature: String {
        [
            lightAccent, lightBackground, lightForeground,
            darkAccent, darkBackground, darkForeground,
            String(translucentSidebar), String(contrast),
            String(bodyFontSize), String(codeFontSize),
        ].joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                paneTitle("外观")

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("主题")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CodexTheme.primaryText)
                        Spacer()
                        Button("导入", action: importTheme)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button("导出", action: exportTheme)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button("恢复默认", action: resetTheme)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        ForEach([AppColorScheme.system, .light, .dark], id: \.self) { scheme in
                            AppearanceThemeButton(
                                scheme: scheme,
                                isSelected: colorScheme == scheme
                            ) {
                                colorScheme = scheme
                            }
                        }
                    }
                }
                .frame(maxWidth: 764, alignment: .leading)

                themeEditor(
                    title: "浅色主题",
                    isDark: false,
                    accent: $lightAccent,
                    background: $lightBackground,
                    foreground: $lightForeground
                )

                themeEditor(
                    title: "深色主题",
                    isDark: true,
                    accent: $darkAccent,
                    background: $darkBackground,
                    foreground: $darkForeground
                )

                settingsGroup("显示") {
                    row("半透明侧边栏", detail: "让侧边栏轻微透出窗口背景") {
                        Toggle("", isOn: $translucentSidebar)
                            .labelsHidden()
                    }
                    settingsDivider
                    sliderRow("对比度", value: $contrast, range: 0...100, suffix: "")
                    settingsDivider
                    sliderRow("正文字号", value: $bodyFontSize, range: 12...18, suffix: " pt")
                    settingsDivider
                    sliderRow("代码字号", value: $codeFontSize, range: 10...16, suffix: " pt")
                }

                settingsGroup("偏好设置") {
                    row("界面语言", detail: "更改菜单、按钮和设置中使用的语言") {
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
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: themeSignature) { _, _ in
            ThemePreferences.bumpRevision()
        }
        .alert("主题操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "主题文件无效")
        }
    }

    private func themeEditor(
        title: String,
        isDark: Bool,
        accent: Binding<String>,
        background: Binding<String>,
        foreground: Binding<String>
    ) -> some View {
        settingsGroup(title) {
            HStack {
                Text("颜色")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Menu("预设") {
                    Section("内置") {
                        presetButton(.codex, isDark: isDark)
                        presetButton(.warm, isDark: isDark)
                        presetButton(.highContrast, isDark: isDark)
                    }
                    Section("开源主题") {
                        presetButton(.github, isDark: isDark)
                        presetButton(.catppuccin, isDark: isDark)
                        presetButton(.rosePine, isDark: isDark)
                        presetButton(.dracula, isDark: isDark)
                        presetButton(.nord, isDark: isDark)
                        presetButton(.solarized, isDark: isDark)
                        presetButton(.gruvbox, isDark: isDark)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            settingsDivider

            themeColorRow("强调色", hex: accent)
            settingsDivider
            themeColorRow("背景", hex: background)
            settingsDivider
            themeColorRow("前景", hex: foreground)
        }
    }

    private func themeColorRow(_ title: String, hex: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(CodexTheme.primaryText)
            Spacer()
            ThemeColorControl(hex: hex)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func presetButton(_ preset: ThemePreset, isDark: Bool) -> some View {
        Button {
            applyPreset(preset, isDark: isDark)
        } label: {
            Text(preset.title)
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Slider(value: value, in: range, step: 1)
                .frame(width: 210)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func resetTheme() {
        lightAccent = ThemePreferences.lightAccentDefault
        lightBackground = ThemePreferences.lightBackgroundDefault
        lightForeground = ThemePreferences.lightForegroundDefault
        darkAccent = ThemePreferences.darkAccentDefault
        darkBackground = ThemePreferences.darkBackgroundDefault
        darkForeground = ThemePreferences.darkForegroundDefault
        translucentSidebar = true
        contrast = 50
        bodyFontSize = 14
        codeFontSize = 12
    }

    private func applyPreset(_ preset: ThemePreset, isDark: Bool) {
        let colors = preset.colors(isDark: isDark)
        if isDark {
            darkAccent = colors.accent
            darkBackground = colors.background
            darkForeground = colors.foreground
        } else {
            lightAccent = colors.accent
            lightBackground = colors.background
            lightForeground = colors.foreground
        }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Mox Theme.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = ThemeDocument(
                light: .init(accent: lightAccent, background: lightBackground, foreground: lightForeground),
                dark: .init(accent: darkAccent, background: darkBackground, foreground: darkForeground),
                translucentSidebar: translucentSidebar,
                contrast: contrast,
                bodyFontSize: bodyFontSize,
                codeFontSize: codeFontSize
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try JSONDecoder().decode(ThemeDocument.self, from: Data(contentsOf: url))
            guard document.version == 1,
                  document.allHexColors.allSatisfy(ThemeDocument.isValidHex) else {
                throw ThemeDocumentError.invalidFormat
            }
            lightAccent = document.light.accent
            lightBackground = document.light.background
            lightForeground = document.light.foreground
            darkAccent = document.dark.accent
            darkBackground = document.dark.background
            darkForeground = document.dark.foreground
            translucentSidebar = document.translucentSidebar
            contrast = min(max(document.contrast, 0), 100)
            bodyFontSize = min(max(document.bodyFontSize, 12), 18)
            codeFontSize = min(max(document.codeFontSize, 10), 16)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ThemeColorControl: View {
    @Binding var hex: String
    @State private var showsPicker = false
    @State private var red = 0
    @State private var green = 0
    @State private var blue = 0

    private static let swatches = [
        "FFFFFF", "F5F5F3", "E8E5DE", "B9B5AC", "6F6C66", "1A1C1F",
        "000000", "EA4335", "F2994A", "F2C94C", "27AE60", "2D9CDB",
        "339CFF", "2563EB", "5856D6", "9B51E0", "D946EF", "EB5757",
    ]

    private var normalizedHex: String {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        return ThemeDocument.isValidHex(cleaned) ? cleaned : "000000"
    }

    private var fillColor: Color { Color(hex: normalizedHex) }

    private var labelColor: Color {
        let color = NSColor(fillColor).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.58 ? Color.black.opacity(0.82) : Color.white
    }

    var body: some View {
        Button {
            syncRGBFromHex()
            showsPicker.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(fillColor)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(labelColor.opacity(0.3), lineWidth: 1))
                Text("#\(normalizedHex)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 11)
            .frame(width: 146)
            .frame(height: 32)
            .background(fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPicker, arrowEdge: .trailing) {
            pickerPopover
        }
        .accessibilityLabel("颜色 #\(normalizedHex)")
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择颜色")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("#\(normalizedHex)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fillColor)
                .frame(height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.swatches, id: \.self) { swatch in
                    Button {
                        hex = swatch
                        syncRGBFromHex()
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: swatch))
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(normalizedHex == swatch ? CodexTheme.accent : Color.primary.opacity(0.13),
                                            lineWidth: normalizedHex == swatch ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("#")
                    .foregroundStyle(.secondary)
                TextField("000000", text: $hex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: hex) { _, value in
                        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
                        if ThemeDocument.isValidHex(cleaned), cleaned != value {
                            hex = cleaned
                        }
                        if ThemeDocument.isValidHex(cleaned) { syncRGBFromHex() }
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(CodexTheme.surfaceSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(CodexTheme.border))

            RGBSlider(label: "R", value: $red, tint: .red, onChange: updateHexFromRGB)
            RGBSlider(label: "G", value: $green, tint: .green, onChange: updateHexFromRGB)
            RGBSlider(label: "B", value: $blue, tint: .blue, onChange: updateHexFromRGB)
        }
        .padding(16)
        .frame(width: 250)
        .background(CodexTheme.surface)
        .onAppear(perform: syncRGBFromHex)
    }

    private func syncRGBFromHex() {
        guard let value = UInt64(normalizedHex, radix: 16) else { return }
        red = Int((value >> 16) & 0xFF)
        green = Int((value >> 8) & 0xFF)
        blue = Int(value & 0xFF)
    }

    private func updateHexFromRGB() {
        hex = String(format: "%02X%02X%02X", red, green, blue)
    }
}

private struct RGBSlider: View {
    let label: String
    @Binding var value: Int
    let tint: Color
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: {
                        value = Int($0.rounded())
                        onChange()
                    }
                ),
                in: 0...255,
                step: 1
            )
            .tint(tint)
            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

private enum ThemePreset {
    case codex
    case warm
    case highContrast
    case github
    case catppuccin
    case rosePine
    case dracula
    case nord
    case solarized
    case gruvbox

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .warm: return "暖灰"
        case .highContrast: return "高对比"
        case .github: return "GitHub"
        case .catppuccin: return "Catppuccin"
        case .rosePine: return "Rosé Pine"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .solarized: return "Solarized"
        case .gruvbox: return "Gruvbox"
        }
    }

    func colors(isDark: Bool) -> ThemePaletteDocument {
        switch (self, isDark) {
        case (.codex, false): return .init(accent: "339CFF", background: "FBFAF7", foreground: "1A1C1F")
        case (.codex, true): return .init(accent: "5EA7FF", background: "171717", foreground: "F5F5F5")
        case (.warm, false): return .init(accent: "C56A3A", background: "F7F2E9", foreground: "29251F")
        case (.warm, true): return .init(accent: "E39A6D", background: "201C18", foreground: "F2EAE0")
        case (.highContrast, false): return .init(accent: "0066FF", background: "FFFFFF", foreground: "000000")
        case (.highContrast, true): return .init(accent: "66B2FF", background: "000000", foreground: "FFFFFF")
        case (.github, false): return .init(accent: "0969DA", background: "FFFFFF", foreground: "1F2328")
        case (.github, true): return .init(accent: "2F81F7", background: "0D1117", foreground: "E6EDF3")
        case (.catppuccin, false): return .init(accent: "1E66F5", background: "EFF1F5", foreground: "4C4F69")
        case (.catppuccin, true): return .init(accent: "89B4FA", background: "1E1E2E", foreground: "CDD6F4")
        case (.rosePine, false): return .init(accent: "907AA9", background: "FAF4ED", foreground: "575279")
        case (.rosePine, true): return .init(accent: "C4A7E7", background: "191724", foreground: "E0DEF4")
        case (.dracula, false): return .init(accent: "644AC9", background: "FFFBEB", foreground: "1F1F1F")
        case (.dracula, true): return .init(accent: "BD93F9", background: "282A36", foreground: "F8F8F2")
        case (.nord, false): return .init(accent: "5E81AC", background: "ECEFF4", foreground: "2E3440")
        case (.nord, true): return .init(accent: "88C0D0", background: "2E3440", foreground: "D8DEE9")
        case (.solarized, false): return .init(accent: "268BD2", background: "FDF6E3", foreground: "657B83")
        case (.solarized, true): return .init(accent: "268BD2", background: "002B36", foreground: "839496")
        case (.gruvbox, false): return .init(accent: "076678", background: "FBF1C7", foreground: "3C3836")
        case (.gruvbox, true): return .init(accent: "83A598", background: "282828", foreground: "EBDBB2")
        }
    }
}

private struct ThemePaletteDocument: Codable {
    let accent: String
    let background: String
    let foreground: String
}

private struct ThemeDocument: Codable {
    var version = 1
    let light: ThemePaletteDocument
    let dark: ThemePaletteDocument
    let translucentSidebar: Bool
    let contrast: Double
    let bodyFontSize: Double
    let codeFontSize: Double

    var allHexColors: [String] {
        [light.accent, light.background, light.foreground,
         dark.accent, dark.background, dark.foreground]
    }

    static func isValidHex(_ value: String) -> Bool {
        value.count == 6 && UInt64(value, radix: 16) != nil
    }
}

private enum ThemeDocumentError: LocalizedError {
    case invalidFormat

    var errorDescription: String? { "主题文件格式或颜色值无效。" }
}

private struct AppearanceThemeButton: View {
    let scheme: AppColorScheme
    let isSelected: Bool
    let action: () -> Void

    private var title: String {
        switch scheme {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ThemePreview(scheme: scheme)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : settingsLightBorder,
                                    lineWidth: isSelected ? 2 : 1)
                    }

                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .foregroundStyle(CodexTheme.primaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)主题")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ThemePreview: View {
    let scheme: AppColorScheme

    var body: some View {
        HStack(spacing: 0) {
            if scheme == .system {
                previewHalf(isDark: false)
                previewHalf(isDark: true)
            } else {
                previewHalf(isDark: scheme == .dark)
            }
        }
        .frame(width: 184, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func previewHalf(isDark: Bool) -> some View {
        let palette = ThemePreferences.palette(isDark: isDark)
        let background = Color(nsColor: palette.background)
        let sidebar = Color(nsColor: palette.mix(palette.background, palette.foreground, amount: 0.035))
        let surface = Color(nsColor: palette.mix(palette.background, palette.foreground, amount: 0.025))
        let line = Color(nsColor: palette.mix(palette.background, palette.foreground, amount: 0.25))

        return HStack(spacing: 0) {
            sidebar
                .frame(width: scheme == .system ? 21 : 40)
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(line).frame(width: 45, height: 5)
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(line.opacity(0.75)).frame(width: 35, height: 5)
                    Capsule().fill(line.opacity(0.55)).frame(maxWidth: .infinity).frame(height: 4)
                    Capsule().fill(line.opacity(0.55)).frame(width: 54, height: 4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(10)
            .background(background)
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
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundColor(CodexTheme.primaryText)
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
            .foregroundColor(CodexTheme.primaryText)
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
    Text(localizedSettingsString(title))
        .font(.system(size: 25, weight: .semibold))
        .foregroundColor(CodexTheme.primaryText.opacity(0.92))
}

private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(localizedSettingsString(title))
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
    }
    .frame(maxWidth: 764, alignment: .leading)
}

private var settingsCardBackground: Color {
    CodexTheme.surface
}

private var settingsKeycapBackground: Color {
    CodexTheme.surfaceSubtle
}

private var settingsLightBorder: Color {
    CodexTheme.border
}

private var settingsDivider: some View {
    Rectangle()
        .fill(CodexTheme.divider)
        .frame(height: 1)
}

private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack {
            Text(localizedSettingsString(label))
                .font(.system(size: 13))
                .foregroundColor(CodexTheme.primaryText.opacity(0.86))
                .frame(width: 130, alignment: .leading)
            Spacer()
            content()
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedSettingsString(label))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(CodexTheme.primaryText.opacity(0.86))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}

private func row<Content: View>(
    _ label: String,
    detail: String,
    @ViewBuilder content: () -> Content
) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
            settingsRowLabel(label, detail: detail)
            Spacer()
            content()
        }
        VStack(alignment: .leading, spacing: 8) {
            settingsRowLabel(label, detail: detail)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}

private func settingsRowLabel(_ label: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(localizedSettingsString(label))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(CodexTheme.primaryText)
        Text(localizedSettingsString(detail))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

private func localizedSettingsString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
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
