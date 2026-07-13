//
//  InputFields_macOS.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

#if os(macOS) || os(visionOS)
import SwiftUI
#if os(macOS)
import UniformTypeIdentifiers
@preconcurrency import AppKit
#endif

struct InputFieldsView: View {
    @Binding var message: String
    var conversationState: ConversationState
    var onStopGenerateTap: @MainActor () -> Void
    var selectedModel: LanguageModelSD?
    var modelsList: [LanguageModelSD] = []
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> () = { _ in }
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ images: [Image], _ trimmingMessageId: String?) -> ()
    var stats: PiSessionStats? = nil
    var onSteer: @MainActor (_ message: String) -> Void = { _ in }
    var onFollowUp: @MainActor (_ message: String, _ images: [Image]) -> Void = { _, _ in }
    var focusTrigger: Int = 0
    var slashPalettePlacement: SlashPalettePlacement = .above
    var compactControls = false
    @Binding var editMessage: MessageSD?
    @State private var selectedImages: [ComposerImageAttachment] = []
    @State private var fileDropActive: Bool = false
    @State private var addMenuPresented: Bool = false
    @State private var attachments: [TextAttachment] = []
    @State private var inputHeight: CGFloat = 32
    @State private var isInputFocused: Bool = false
    @State private var previewAttachment: TextAttachment?
    @State private var showGoalEditor = false
    @State private var goalDraft = ""
    @State private var goalAutoContinue = false
    @State private var conversationStore = ConversationStore.shared
    @AppStorage("piRunningMessageMode") private var runningMessageMode = "steer"
    @AppStorage("newTaskEnvironment") private var newTaskEnvironment = "local"
#if os(macOS)
    @State private var skillStore = SkillStore.shared
    @State private var appStore = AppStore.shared
    @State private var slashSelection = 0
    @State private var slashDismissedText: String?
    @State private var slashSubmenu: ComposerSlashSubmenu?
    @State private var showStatusPanel = false
    @State private var inputFocusGeneration = 0
#endif
    @FocusState private var isFocusedInput: Bool

#if os(macOS)
    private var slashQuery: String? {
        guard message.hasPrefix("/") else { return nil }
        guard slashDismissedText != message else { return nil }
        let query = String(message.dropFirst())
        guard !query.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return query
    }

    private var slashCommands: [ComposerSlashCommandItem] {
        guard let slashQuery else { return [] }
        let query = slashQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if slashSubmenu == .models {
            let items = modelsList.map { model in
                ComposerSlashCommandItem(
                    id: "model-\(model.name)",
                    title: model.name,
                    detail: model.name == selectedModel?.name ? "当前模型" : model.providerDisplayName,
                    icon: model.modelProvider?.iconName ?? "cpu",
                    keywords: ["model", "模型", model.name, model.providerDisplayName],
                    kind: .selectModel(model)
                )
            }
            return Array(items.filter { $0.matches(query) }.prefix(14))
        }

        if slashSubmenu == .thinking {
            let current = UserDefaults.standard.string(forKey: "piThinkingLevel") ?? "medium"
            let levels = [
                ("off", "关闭"), ("minimal", "最少"), ("low", "低"),
                ("medium", "中"), ("high", "高"), ("xhigh", "最高"),
            ]
            let items = levels.map { id, label in
                ComposerSlashCommandItem(
                    id: "thinking-\(id)",
                    title: label,
                    detail: id == current ? "当前推理强度" : "设置后续请求的推理强度",
                    icon: "brain",
                    keywords: ["reasoning", "thinking", "推理", id, label],
                    kind: .setThinkingLevel(id)
                )
            }
            return Array(items.filter { $0.matches(query) }.prefix(14))
        }

        var items: [ComposerSlashCommandItem] = [
            .init(
                id: "initialize",
                title: "初始化",
                detail: "准备创建项目 AGENTS.md 的提示",
                icon: "doc.badge.plus",
                keywords: ["init", "initialize", "agents", "初始化"],
                kind: .insertText("分析当前项目并创建或完善 AGENTS.md，记录架构、常用命令和协作约束。")
            ),
            .init(
                id: "side-task",
                title: "副任务",
                detail: "打开不污染主会话的临时侧边对话",
                icon: "bubble.left.and.bubble.right",
                keywords: ["side", "subtask", "副任务"],
                kind: .sideTask
            ),
            .init(
                id: "compact",
                title: "压缩",
                detail: stats.flatMap { $0.contextPercent }.map { "压缩当前上下文（已占用 \(Int($0.rounded()))%）" } ?? "压缩当前任务的上下文",
                icon: "arrow.down.right.and.arrow.up.left",
                keywords: ["compact", "compress", "压缩"],
                kind: .compact
            ),
            .init(
                id: "continue-task",
                title: "在新任务中继续",
                detail: "复制上下文并在当前工作目录创建新任务",
                icon: "arrow.triangle.branch",
                keywords: ["continue", "fork", "new task", "继续", "新任务"],
                kind: .continueInNewTask
            ),
            .init(
                id: "reasoning",
                title: "推理",
                detail: "当前：\(thinkingLevelLabel)",
                icon: "brain",
                keywords: ["reasoning", "thinking", "推理"],
                kind: .showThinkingLevels
            ),
            .init(
                id: "model",
                title: "模型",
                detail: selectedModel?.name ?? "选择模型",
                icon: "cube",
                keywords: ["model", "模型"],
                kind: .showModels
            ),
            .init(
                id: "status",
                title: "状态",
                detail: "显示任务 ID、上下文用量和后端统计",
                icon: "gauge.with.dots.needle.33percent",
                keywords: ["status", "stats", "usage", "状态", "用量"],
                kind: .showStatus
            ),
            .init(
                id: "goal",
                title: "目标",
                detail: "设置要持续追求的长期目标",
                icon: "target",
                keywords: ["goal", "目标"],
                kind: .goal
            ),
            .init(
                id: "show-skills",
                title: "技能",
                detail: "浏览和管理可用 Skills",
                icon: "sparkles",
                keywords: ["skill", "skills"],
                kind: .showSkills
            ),
            .init(
                id: "mcp",
                title: "MCP",
                detail: "发送 MCP 状态查询命令",
                icon: "paperclip",
                keywords: ["mcp"],
                kind: .insertText("/mcp ")
            )
        ]

        items += skillStore.skills.map { skill in
            ComposerSlashCommandItem(
                id: "skill-\(skill.name)",
                title: skill.title,
                detail: skill.description.isEmpty ? "插入 /skill:\(skill.name)" : skill.description,
                icon: "wand.and.stars",
                keywords: ["skill", skill.name, skill.scope.localizedLabel],
                kind: .skill(skill)
            )
        }

        if query.isEmpty {
            return Array(items.prefix(14))
        }
        return Array(items.filter { $0.matches(query) }.prefix(14))
    }

    private var slashMenuIsVisible: Bool {
        slashQuery != nil
    }

    @MainActor
    private func focusComposerInput() {
        isFocusedInput = true
        isInputFocused = true
        inputFocusGeneration += 1
        DispatchQueue.main.async {
            isFocusedInput = true
            isInputFocused = true
            inputFocusGeneration += 1
        }
    }

    @MainActor
    private func ensureSkillsLoadedForSlashMenu() {
        guard slashMenuIsVisible, skillStore.skills.isEmpty, !skillStore.isLoading else { return }
        Task { await skillStore.load() }
    }

    @MainActor
    private func clampSlashSelection() {
        if !slashMenuIsVisible {
            slashSelection = 0
            return
        }
        slashSelection = min(max(slashSelection, 0), max(slashCommands.count - 1, 0))
    }

    @MainActor
    private func performSlashCommand(_ item: ComposerSlashCommandItem) {
        slashDismissedText = nil
        switch item.kind {
        case .insertText(let text):
            message = text
        case .skill(let skill):
            message = "/skill:\(skill.name) "
        case .showSkills:
            appStore.showSettings = false
            appStore.showSkills = true
            message = ""
        case .showModels:
            slashSubmenu = .models
            slashSelection = 0
            message = "/"
        case .selectModel(let model):
            onSelectModel(model)
            closeSlashMenu()
        case .showThinkingLevels:
            slashSubmenu = .thinking
            slashSelection = 0
            message = "/"
        case .setThinkingLevel(let level):
            UserDefaults.standard.set(level, forKey: "piThinkingLevel")
            closeSlashMenu()
        case .showStatus:
            showStatusPanel = true
            if let id = conversationStore.selectedConversation?.id {
                conversationStore.refreshStats(for: id)
            }
            closeSlashMenu()
        case .compact:
            closeSlashMenu()
            Task { await conversationStore.compactSelectedConversation() }
        case .sideTask:
            closeSlashMenu()
            RightSidebarStore.shared.activate(.sideChat)
        case .continueInNewTask:
            guard let conversation = conversationStore.selectedConversation else {
                closeSlashMenu()
                appStore.uiLog(message: "请先开始一个任务", status: .error)
                return
            }
            closeSlashMenu()
            Task { await conversationStore.forkToLocal(conversation) }
        case .goal:
            closeSlashMenu()
            openGoalEditor()
        }
        focusComposerInput()
    }

    private var thinkingLevelLabel: String {
        switch UserDefaults.standard.string(forKey: "piThinkingLevel") ?? "medium" {
        case "off": "关闭"
        case "minimal": "最少"
        case "low": "低"
        case "high": "高"
        case "xhigh": "最高"
        default: "中"
        }
    }

    @MainActor
    private func closeSlashMenu() {
        message = ""
        slashSubmenu = nil
        slashSelection = 0
    }

    @MainActor
    private func dismissSlashMenu() {
        guard slashMenuIsVisible else { return }
        slashDismissedText = message
        slashSubmenu = nil
    }

    @MainActor
    private func handleComposerCommandKey(_ key: ComposerCommandKey) -> Bool {
        guard slashMenuIsVisible else { return false }
        let commands = slashCommands

        switch key {
        case .up:
            guard !commands.isEmpty else { return true }
            slashSelection = (slashSelection + commands.count - 1) % commands.count
            return true
        case .down:
            guard !commands.isEmpty else { return true }
            slashSelection = (slashSelection + 1) % commands.count
            return true
        case .accept:
            guard commands.indices.contains(slashSelection) else { return true }
            performSlashCommand(commands[slashSelection])
            return true
        case .cancel:
            dismissSlashMenu()
            return true
        }
    }
#endif

    /// Combines any large-text attachments with the short instruction typed in
    /// the field into a single prompt, separated by blank lines.
    private func composedPrompt() -> String {
        let parts = attachments.map(\.rawContent) + [message]
        let prompt = parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        // The backend needs a textual turn even when the user pastes only an
        // image. Keep the placeholder short and visible in conversation history.
        if prompt.isEmpty, !selectedImages.isEmpty { return "请查看附件图片。" }
        return prompt
    }
    
    @MainActor private func sendMessage() {
        // While a turn is running, Enter steers the in-flight run instead of
        // starting a new one (the stop button still aborts).
        if conversationState == .loading {
            let trimmed = composedPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if runningMessageMode == "followUp" {
                onFollowUp(trimmed, selectedImages.map(\.image))
            } else {
                onSteer(trimmed)
            }
            withAnimation {
                message = ""
                attachments = []
                selectedImages = []
            }
            return
        }

        guard let selectedModel = selectedModel else { return }

        let prompt = composedPrompt()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        onSendMessageTap(
            prompt,
            selectedModel,
            selectedImages.map(\.image),
            editMessage?.id.uuidString
        )
        withAnimation {
            isFocusedInput = false
            isInputFocused = false
            editMessage = nil
            selectedImages = []
            attachments = []
            message = ""
        }
    }
    
    private func updateSelectedImage(_ image: Image) {
        selectedImages.append(ComposerImageAttachment(image: image))
    }

    /// Whether there is something worth sending: a typed instruction or at
    /// least one large-text attachment.
    private var canSend: Bool {
        !conversationStore.isPreparingNewTaskEnvironment
            && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !selectedImages.isEmpty)
    }
    
    @ViewBuilder
    private var sendButton: some View {
        if conversationStore.isPreparingNewTaskEnvironment {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
        switch conversationState {
        case .loading:
            Button(action: onStopGenerateTap) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        default:
            Button(action: { Task { sendMessage() } }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.gray))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        }
    }

    private func inputCard(framed: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
#if os(macOS)
            if showStatusPanel {
                ComposerStatusCard(
                    conversation: conversationStore.selectedConversation,
                    stats: stats,
                    onRefresh: {
                        if let id = conversationStore.selectedConversation?.id {
                            conversationStore.refreshStats(for: id)
                        }
                    },
                    onClose: { showStatusPanel = false }
                )
            }
#endif
            if let goal = conversationStore.currentGoalText {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                        Text("Long-running goal")
                            .fontWeight(.semibold)
                        Text(goalStatusLabel)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if conversationStore.currentGoalStatus == "active" {
                            Button("Pause") { conversationStore.pauseCurrentGoal() }
                        } else if conversationStore.currentGoalStatus == "paused" {
                            Button("Resume") { conversationStore.resumeCurrentGoal() }
                        }
                        Button("Edit") { openGoalEditor() }
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)

                    Text(goal)
                        .font(.system(size: 11))
                        .lineLimit(3)
                    if conversationStore.currentGoalAutoContinues {
                        Label("Auto-continues while the plan has unfinished steps", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }

            if let plan = conversationStore.currentPlan, !plan.items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text("Plan")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(verbatim: "\(completedPlanCount(plan))/\(plan.items.count)")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 10))

                    if let explanation = plan.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    ForEach(plan.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: planIcon(for: item.status))
                                .foregroundStyle(planColor(for: item.status))
                                .frame(width: 12)
                            Text(item.step)
                                .font(.system(size: 11))
                                .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                                .strikethrough(item.status == "completed")
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(CodexTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            }

            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedImages) { item in
                            RemovableImage(
                                image: item.image,
                                onClick: {
                                    selectedImages.removeAll { $0.id == item.id }
                                },
                                height: 84
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }

            // Large-text attachment chips (Codex-style)
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            AttachmentChipView(
                                attachment: item,
                                onRemove: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        attachments.removeAll { $0.id == item.id }
                                    }
                                },
                                onTap: { previewAttachment = item }
                            )
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Text input
#if os(macOS)
            CustomPasteTextView(
                text: $message,
                isFocused: $isInputFocused,
                calculatedHeight: $inputHeight,
                onSubmit: { Task { sendMessage() } },
                onLargePaste: { pasted in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        attachments.append(TextAttachment(rawContent: pasted))
                    }
                },
                onImagePaste: { nsImage in
                    updateSelectedImage(Image(nsImage: nsImage))
                },
                focusGeneration: inputFocusGeneration,
                onCommandKey: { key in
                    handleComposerCommandKey(key)
                }
            )
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .allowsHitTesting(!fileDropActive)
#else
            TextField("Message", text: $message.animation(.easeOut(duration: 0.3)), axis: .vertical)
                .focused($isFocusedInput)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .lineLimit(1...12)
                .textFieldStyle(.plain)
                .allowsHitTesting(!fileDropActive)
#endif

            if let request = conversationStore.currentUIRequest {
                VStack(alignment: .leading, spacing: 8) {
                    Label(request.title, systemImage: "exclamationmark.shield")
                        .font(.system(size: 12, weight: .semibold))
                    if let detail = request.message, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                    HStack {
                        if request.method == "select" {
                            ForEach(request.options, id: \.self) { option in
                                Button(option) {
                                    conversationStore.respondToCurrentUIRequest(value: option)
                                }
                            }
                        } else {
                            Button("Block", role: .destructive) {
                                conversationStore.respondToCurrentUIRequest(confirmed: false)
                            }
                            Button("Allow") {
                                conversationStore.respondToCurrentUIRequest(confirmed: true)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
            }

            if conversationState == .loading && !conversationStore.currentFollowUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Queued follow-ups", systemImage: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("\(conversationStore.currentFollowUps.count)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    ForEach(Array(conversationStore.currentFollowUps.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .frame(width: 14)
                            Text(item.text)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            if !item.imageData.isEmpty {
                                Label("\(item.imageData.count)", systemImage: "photo")
                                    .font(.system(size: 9))
                            }
                            Button(action: { conversationStore.moveFollowUp(item.id, by: -1) }) {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            Button(action: { conversationStore.moveFollowUp(item.id, by: 1) }) {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == conversationStore.currentFollowUps.count - 1)
                            Button(action: { conversationStore.removeFollowUp(item.id) }) {
                                Image(systemName: "xmark")
                            }
                            .help("Remove from queue")
                        }
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(CodexTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }

            // Bottom control row (Codex-style)
            HStack(spacing: compactControls ? 6 : 10) {
                ComposerAddButton(
                    isPresented: $addMenuPresented,
                    addFilesAndFolders: openAttachmentPanel
                )

                // Project / working-directory context badge
                ComposerContextBadge()

                if !compactControls, conversationStore.selectedConversation != nil {
                    Button(action: openGoalEditor) {
                        Image(systemName: "target")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Set long-running goal")
                }

                if conversationStore.selectedConversation == nil {
                    Menu {
                        Button(action: { newTaskEnvironment = "local" }) {
                            Label("Local", systemImage: newTaskEnvironment == "local" ? "checkmark" : "folder")
                        }
                        Button(action: { newTaskEnvironment = "worktree" }) {
                            Label("Worktree", systemImage: newTaskEnvironment == "worktree" ? "checkmark" : "arrow.triangle.branch")
                        }
                        Divider()
                        Button(action: {}) {
                            Label("Cloud requires a remote runner", systemImage: "cloud")
                        }
                        .disabled(true)
                    } label: {
                        Label(
                            newTaskEnvironment == "worktree" ? "Worktree" : "Local",
                            systemImage: newTaskEnvironment == "worktree" ? "arrow.triangle.branch" : "laptopcomputer"
                        )
                        .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                // Model + reasoning settings (Codex-style hierarchical menu)
                ComposerModelSettingsMenu(
                    modelsList: modelsList,
                    selectedModel: selectedModel,
                    onSelectModel: onSelectModel,
                    compact: compactControls
                )

                if !compactControls, let stats {
                    SessionStatsBadge(stats: stats)
                }

                if conversationState == .loading {
                    Menu {
                        Button(action: { runningMessageMode = "steer" }) {
                            Label("Steer current run", systemImage: runningMessageMode == "steer" ? "checkmark" : "arrow.turn.up.right")
                        }
                        Button(action: { runningMessageMode = "followUp" }) {
                            Label("Queue follow-up", systemImage: runningMessageMode == "followUp" ? "checkmark" : "clock")
                        }
                    } label: {
                        Label(
                            runningMessageMode == "followUp"
                                ? "Queue · \(conversationStore.currentFollowUps.count)"
                                : "Steer",
                            systemImage: runningMessageMode == "followUp" ? "clock" : "arrow.turn.up.right"
                        )
                        .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer()

                sendButton
            }
        }
        .transition(.slide)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(framed ? CodexTheme.surface : Color.clear)
                .shadow(color: Color.black.opacity(framed ? 0.04 : 0), radius: 7, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CodexTheme.border.opacity(framed ? 1 : 0), lineWidth: 1)
        )
        .overlay {
            if fileDropActive {
                DragAndDrop(cornerRadius: 8)
            }
        }
#if os(macOS)
        .overlay(alignment: .topLeading) {
            if slashMenuIsVisible, slashPalettePlacement == .above {
                SlashCommandPalette(
                    items: slashCommands,
                    selectedIndex: slashSelection,
                    isLoading: skillStore.isLoading,
                    onHover: { slashSelection = $0 },
                    onSelect: { performSlashCommand($0) }
                )
                .padding(.horizontal, 10)
                .offset(y: -(SlashCommandPalette.height(for: slashCommands, isLoading: skillStore.isLoading) + 10))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(10)
            }
        }
#endif
        .animation(.default, value: fileDropActive)
        .onDrop(of: [.image], isTargeted: $fileDropActive.animation(), perform: { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if error == nil, let data {
                    if let image = Image(data: data) {
                        DispatchQueue.main.async { updateSelectedImage(image) }
                    }
                }
            }
            
            return true
        })
        .contentShape(Rectangle())
        .onChange(of: focusTrigger) { _, _ in
#if os(macOS)
            focusComposerInput()
#else
            isFocusedInput = true
#endif
        }
        .onTapGesture {
            // allow focusing text area on greater tap area
#if os(macOS)
            focusComposerInput()
#else
            isFocusedInput = true
#endif
        }
#if os(macOS)
        .onChange(of: message) { _, newValue in
            if !newValue.hasPrefix("/") { slashSubmenu = nil }
            if slashDismissedText != newValue {
                slashDismissedText = nil
            }
            ensureSkillsLoadedForSlashMenu()
            clampSlashSelection()
        }
        .onChange(of: slashCommands.map(\.id)) { _, _ in
            clampSlashSelection()
        }
#endif
#if os(macOS)
        .sheet(item: $previewAttachment) { item in
            AttachmentPreviewView(
                attachment: item,
                onClose: { previewAttachment = nil }
            )
        }
        .sheet(isPresented: $showGoalEditor) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Long-running goal")
                    .font(.headline)
                TextEditor(text: $goalDraft)
                    .font(.system(size: 12))
                    .frame(width: 420, height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(CodexTheme.border))
                Toggle("Automatically continue while the plan has unfinished steps", isOn: $goalAutoContinue)
                Text("Automatic continuation requires the agent to maintain a structured Plan and pauses after 12 rounds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if conversationStore.currentGoalText != nil {
                        Button("Clear", role: .destructive) {
                            conversationStore.setCurrentGoal("", autoContinue: false)
                            showGoalEditor = false
                        }
                    }
                    Spacer()
                    Button("Cancel") { showGoalEditor = false }
                    Button("Save") {
                        conversationStore.setCurrentGoal(goalDraft, autoContinue: goalAutoContinue)
                        showGoalEditor = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
#endif
    }

    private var goalStatusLabel: String {
        switch conversationStore.currentGoalStatus {
        case "active": String(localized: "Active")
        case "paused": String(localized: "Paused")
        case "completed": String(localized: "Completed")
        default: ""
        }
    }

    private func openGoalEditor() {
        goalDraft = conversationStore.currentGoalText ?? ""
        goalAutoContinue = conversationStore.currentGoalAutoContinues
        showGoalEditor = true
    }

    private func openAttachmentPanel() {
#if os(macOS)
        addMenuPresented = false
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.resolvesAliases = true
            panel.prompt = "添加"
            panel.message = "选择要提供给 Agent 的文件或文件夹"

            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                attach(url)
            }
        }
#endif
    }

#if os(macOS)
    private func attach(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory == true
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true

        if isImage, selectedModel?.supportsImages == true {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                if let image = Image(data: data) {
                    updateSelectedImage(image)
                    return
                }
            }
        }

        let kind = isDirectory ? "文件夹" : "文件"
        let detail = isDirectory
            ? "文件夹"
            : (url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased())
        attachments.append(
            TextAttachment(
                rawContent: "用户附加了\(kind)：\(url.path)",
                displayName: url.lastPathComponent,
                detail: detail
            )
        )
    }
#endif

#if os(macOS)
    private var belowSlashPalette: some View {
        SlashCommandPalette(
            items: slashCommands,
            selectedIndex: slashSelection,
            isLoading: skillStore.isLoading,
            framed: false,
            allowsHoverSelection: false,
            onHover: { slashSelection = $0 },
            onSelect: { performSlashCommand($0) }
        )
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 7)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .zIndex(10)
    }
#endif

    var body: some View {
        Group {
#if os(macOS)
            if slashPalettePlacement == .below {
                VStack(alignment: .leading, spacing: 0) {
                    inputCard(framed: !slashMenuIsVisible)
                    if slashMenuIsVisible {
                        belowSlashPalette
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(slashMenuIsVisible ? CodexTheme.surface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CodexTheme.border.opacity(slashMenuIsVisible ? 1 : 0), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(slashMenuIsVisible ? 0.08 : 0), radius: 18, x: 0, y: 8)
            } else {
                inputCard()
            }
#else
            inputCard()
#endif
        }
#if os(macOS)
        .background {
            SlashOutsideClickMonitor(isActive: slashMenuIsVisible) {
                dismissSlashMenu()
            }
        }
#endif
    }

    private func completedPlanCount(_ plan: AgentPlanSnapshot) -> Int {
        plan.items.reduce(into: 0) { count, item in
            if item.status == "completed" { count += 1 }
        }
    }

    private func planIcon(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.inset.filled"
        default: "circle"
        }
    }

    private func planColor(for status: String) -> Color {
        switch status {
        case "completed": .green
        case "in_progress": .accentColor
        default: .secondary
        }
    }
}

/// Compact token / cost / context indicator for the composer (Codex-style).
private struct ComposerStatusCard: View {
    let conversation: ConversationSD?
    let stats: PiSessionStats?
    let onRefresh: () -> Void
    let onClose: () -> Void

    private func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("状态")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新状态")
                Button("关闭", action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if let conversation {
                statusRow("任务", conversation.id.uuidString.lowercased(), monospaced: true)
                if let sessionPath = conversation.piSessionPath, !sessionPath.isEmpty {
                    statusRow("pi 会话", URL(fileURLWithPath: sessionPath).deletingPathExtension().lastPathComponent, monospaced: true)
                }

                if let stats {
                    if let used = stats.contextPercent,
                       let tokens = stats.contextTokens,
                       let window = stats.contextWindow {
                        let remaining = max(0, 100 - used)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("上下文")
                                    .foregroundStyle(.secondary)
                                Text("剩余 \(Int(remaining.rounded()))%")
                                Spacer()
                                Text("已使用 \(formatted(tokens)) / 共 \(formatted(window))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                            ProgressView(value: min(max(used / 100, 0), 1))
                                .progressViewStyle(.linear)
                        }
                    } else {
                        statusRow("上下文", "pi 未返回上下文窗口")
                    }
                    statusRow(
                        "Tokens",
                        "\(formatted(stats.totalTokens))（输入 \(formatted(stats.inputTokens)) / 输出 \(formatted(stats.outputTokens))）"
                    )
                    if stats.cost > 0 {
                        statusRow("费用", String(format: "$%.4f", stats.cost))
                    }
                } else {
                    statusRow("上下文", "等待 pi 会话统计；可点击刷新")
                }
                statusRow("速率限制", "pi RPC 未提供配额数据")
            } else {
                Label("发送第一条消息后会创建任务并显示会话统计。", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(CodexTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CodexTheme.border, lineWidth: 1)
        }
    }

    private func statusRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title + "：")
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .fontDesign(monospaced ? .monospaced : .default)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }
}

struct SessionStatsBadge: View {
    let stats: PiSessionStats
    @State private var conversationStore = ConversationStore.shared

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private var contextColor: Color {
        guard let p = stats.contextPercent else { return .secondary }
        if p >= 85 { return .red }
        if p >= 60 { return .orange }
        return .secondary
    }

    var body: some View {
        Menu {
            Button(action: {}) {
                Label(contextTooltip, systemImage: "info.circle")
            }
            .disabled(true)

            Divider()

            Button(action: {
                Task { await conversationStore.compactSelectedConversation() }
            }) {
                if conversationStore.isCompactingSelectedConversation {
                    Label("Compacting Context…", systemImage: "hourglass")
                } else {
                    Label("Compact Context", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            .disabled(
                conversationStore.isCompactingSelectedConversation
                    || conversationStore.conversationState == .loading
            )
        } label: {
            statsLabel
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
#endif
        .menuIndicator(.hidden)
        .fixedSize()
        .help(contextTooltip)
    }

    private var statsLabel: some View {
        HStack(spacing: 8) {
            if conversationStore.isCompactingSelectedConversation {
                ProgressView()
                    .controlSize(.mini)
            }
            if let p = stats.contextPercent {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10))
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(contextColor)
            }
            Text(fmt(stats.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if stats.cost > 0 {
                Text(String(format: "$%.3f", stats.cost))
                    .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var contextTooltip: String {
        var parts = ["Tokens: \(stats.totalTokens) (in \(stats.inputTokens) / out \(stats.outputTokens))"]
        if let t = stats.contextTokens, let w = stats.contextWindow {
            parts.append("Context: \(t) / \(w)")
        }
        if stats.cost > 0 { parts.append(String(format: "Cost: $%.4f", stats.cost)) }
        return parts.joined(separator: "\n")
    }
}

/// Extensible composer add menu. New context providers can be added as rows
/// without changing the compact control strip.
struct ComposerAddButton: View {
    @Binding var isPresented: Bool
    let addFilesAndFolders: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(CodexTheme.primaryText.opacity(0.82))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? CodexTheme.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("添加")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CodexTheme.mutedText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                ComposerAddMenuRow(
                    icon: "paperclip",
                    title: "文件和文件夹",
                    action: addFilesAndFolders
                )
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 7)
            .frame(width: 280, alignment: .leading)
            .background(CodexTheme.surface)
        }
    }

}

private struct ComposerAddMenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(CodexTheme.mutedText)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? CodexTheme.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// One compact entry for the settings that affect the next pi turn. Nested
/// native menus keep the first level scannable while model/reasoning choices
/// open horizontally, matching Codex's composer interaction.
struct ComposerModelSettingsMenu: View {
    let modelsList: [LanguageModelSD]
    let selectedModel: LanguageModelSD?
    let onSelectModel: @MainActor (LanguageModelSD?) -> Void
    var compact = false
    @AppStorage("piThinkingLevel") private var level: String = "medium"

    private let levels: [(id: String, label: String)] = [
        ("off", "关闭"),
        ("minimal", "最少"),
        ("low", "低"),
        ("medium", "中"),
        ("high", "高"),
        ("xhigh", "最高"),
    ]

    private var currentLabel: String {
        levels.first(where: { $0.id == level })?.label ?? "中"
    }

    var body: some View {
        Menu {
            Section("高级") {
                Menu {
                    ForEach(modelsList, id: \.self) { model in
                        Button {
                            withAnimation(.easeOut) { onSelectModel(model) }
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.name == selectedModel?.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if modelsList.isEmpty {
                        Text("暂无可用模型")
                    }
                } label: {
                    settingsRow(
                        title: "模型",
                        value: selectedModel?.name ?? "未选择",
                        icon: "cpu"
                    )
                }

                Menu {
                    ForEach(levels, id: \.id) { item in
                        Button(action: { level = item.id }) {
                            HStack {
                                Text(item.label)
                                if item.id == level { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    settingsRow(title: "推理强度", value: currentLabel, icon: "brain")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let selectedModel {
                    Text(selectedModel.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: compact ? 104 : 180)
                } else {
                    Text(modelsList.isEmpty ? "暂无模型" : "选择模型")
                }
                Text(currentLabel)
                    .foregroundStyle(CodexTheme.mutedText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CodexTheme.faintText)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(CodexTheme.primaryText)
            .padding(.horizontal, compact ? 9 : 14)
            .frame(height: 28)
            .background(CodexTheme.rowHover, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(CodexTheme.primaryText)
        .fixedSize()
        .help("模型与推理设置")
    }

    private func settingsRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

enum SlashPalettePlacement: Equatable {
    case above
    case below
}

#if os(macOS)
enum ComposerCommandKey {
    case up
    case down
    case accept
    case cancel
}

enum ComposerSlashSubmenu {
    case models
    case thinking
}

struct ComposerSlashCommandItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let keywords: [String]
    let kind: Kind

    enum Kind {
        case insertText(String)
        case skill(PiSkill)
        case showSkills
        case showModels
        case selectModel(LanguageModelSD)
        case showThinkingLevels
        case setThinkingLevel(String)
        case showStatus
        case compact
        case sideTask
        case continueInNewTask
        case goal
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.lowercased()
        guard !normalized.isEmpty else { return true }
        let haystacks = [title, detail] + keywords
        return haystacks.contains { $0.lowercased().contains(normalized) }
    }
}

private struct SlashCommandPalette: View {
    static let rowHeight: CGFloat = 30
    static let emptyHeight: CGFloat = 42
    static let verticalPadding: CGFloat = 10
    static let maxHeight: CGFloat = 320

    static func height(for items: [ComposerSlashCommandItem], isLoading: Bool) -> CGFloat {
        guard !items.isEmpty else { return emptyHeight }
        let rowTotal = CGFloat(items.count) * rowHeight
        return min(rowTotal + verticalPadding, maxHeight)
    }

    let items: [ComposerSlashCommandItem]
    let selectedIndex: Int
    let isLoading: Bool
    var framed: Bool = true
    var allowsHoverSelection: Bool = true
    let onHover: (Int) -> Void
    let onSelect: (ComposerSlashCommandItem) -> Void

    @State private var hoveredIndex: Int?

    var body: some View {
        Group {
            if items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isLoading ? 1 : 0)
                    Text(isLoading ? "正在加载命令…" : "没有匹配的命令")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CodexTheme.mutedText)
                    Spacer()
                }
                .frame(height: 28)
                .padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(items.indices, id: \.self) { index in
                                SlashCommandRow(
                                    item: items[index],
                                    isSelected: index == selectedIndex,
                                    isHovered: index == hoveredIndex,
                                    onSelect: { onSelect(items[index]) }
                                )
                                .id(index)
                                .onHover { hovering in
                                    hoveredIndex = hovering ? index : nil
                                    if hovering, allowsHoverSelection { onHover(index) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(5)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.height(for: items, isLoading: isLoading),
            maxHeight: Self.height(for: items, isLoading: isLoading),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(framed ? CodexTheme.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CodexTheme.border.opacity(framed ? 1 : 0), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(framed ? 0.12 : 0), radius: 18, x: 0, y: 10)
    }
}

private struct SlashCommandRow: View {
    let item: ComposerSlashCommandItem
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CodexTheme.mutedText)
                    .frame(width: 16, height: 16)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodexTheme.primaryText)
                    .lineLimit(1)

                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.faintText)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 7)
            .frame(height: SlashCommandPalette.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var rowBackground: Color {
        if isSelected { return CodexTheme.rowSelected }
        if isHovered { return CodexTheme.rowSelected.opacity(0.55) }
        return .clear
    }
}

private struct SlashOutsideClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onOutsideClick = onOutsideClick
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    @MainActor
    final class Coordinator {
        private struct EventBox: @unchecked Sendable {
            let event: NSEvent
        }

        weak var hostView: NSView?
        var onOutsideClick: (@MainActor () -> Void)?
        nonisolated(unsafe) private var eventMonitor: Any?

        func setActive(_ active: Bool) {
            if active, eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
                    let box = EventBox(event: event)
                    MainActor.assumeIsolated {
                        guard let self,
                              let hostView = self.hostView,
                              let window = hostView.window,
                              box.event.window === window else { return }

                        let point = hostView.convert(box.event.locationInWindow, from: nil)
                        guard !hostView.bounds.contains(point) else { return }
                        self.onOutsideClick?()
                    }
                    return event
                }
            } else if !active, let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}
#endif

// MARK: - Large-text paste → attachment

struct ComposerImageAttachment: Identifiable {
    let id = UUID()
    let image: Image
}

/// Threshold used to decide whether pasted text should collapse into an
/// attachment chip instead of flooding the input field.
enum PasteThreshold {
    static let maxChars = 2000
    static let maxLines = 15

    static func isLarge(_ text: String) -> Bool {
        if text.count > maxChars { return true }
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return lines > maxLines
    }
}

/// A chunk of large pasted text held out of the live text field.
struct TextAttachment: Identifiable, Equatable {
    let id = UUID()
    let rawContent: String
    var displayName: String? = nil
    var detail: String? = nil

    var lineCount: Int {
        rawContent.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    var charCount: Int { rawContent.count }

    /// First non-empty line, trimmed and truncated, used as the chip title.
    var previewTitle: String {
        if let displayName, !displayName.isEmpty { return displayName }
        let firstMeaningful = rawContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let base = firstMeaningful.isEmpty
            ? rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            : firstMeaningful
        return String(base.prefix(24))
    }

    var previewDetail: String {
        detail ?? "\(lineCount) lines · \(charCount) chars"
    }
}

/// Codex-style attachment chip: icon + two-line preview + remove badge.
struct AttachmentChipView: View {
    let attachment: TextAttachment
    let onRemove: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(CodexTheme.surfaceSubtle)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.previewTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(CodexTheme.primaryText)
                    Text(attachment.previewDetail)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 180, height: 46, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CodexTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CodexTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.65)))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
    }
}

/// Read/edit popover for the full contents of an attachment.
struct AttachmentPreviewView: View {
    let attachment: TextAttachment
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(attachment.previewTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(attachment.lineCount) lines · \(attachment.charCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(attachment.rawContent)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.08))
            )
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }
}

#if os(macOS)
/// `NSTextView` subclass that intercepts paste to divert images and oversized
/// text before they reach the (expensive) text layout path.
final class PasteInterceptingTextView: NSTextView {
    /// Return `true` if the paste was handled and `super.paste` should be skipped.
    var onPaste: ((NSPasteboard) -> Bool)?
    /// Placeholder drawn natively when the buffer is empty and no IME
    /// composition is in progress.
    var placeholderString: String?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              !hasMarkedText(),
              let placeholder = placeholderString,
              !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let point = NSPoint(x: textContainerInset.width + padding,
                            y: textContainerInset.height)
        placeholder.draw(at: point, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        // Keep the self-drawn placeholder in sync with the empty state.
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if handleInterceptedPaste() { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if handleInterceptedPaste() { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if handleInterceptedPaste() { return }
        super.pasteAsRichText(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           modifiers.contains(.command),
           !modifiers.contains(.option),
           !modifiers.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           handleInterceptedPaste() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleInterceptedPaste() -> Bool {
        onPaste?(NSPasteboard.general) == true
    }
}

/// SwiftUI bridge around `PasteInterceptingTextView` with self-sizing height,
/// Enter-to-send (Shift+Enter for newline) and large-paste interception.
struct CustomPasteTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var calculatedHeight: CGFloat
    var placeholder: String = String(localized: "Message")
    var minHeight: CGFloat = 32
    var maxHeight: CGFloat = 240
    var onSubmit: () -> Void
    var onLargePaste: (String) -> Void
    var onImagePaste: (NSImage) -> Void
    var focusGeneration: Int = 0
    var onCommandKey: (ComposerCommandKey) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = PasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.placeholderString = placeholder
        textView.onPaste = { pasteboard in
            context.coordinator.handlePaste(pasteboard)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? PasteInterceptingTextView else { return }

        // Never overwrite the buffer while an IME composition is in progress,
        // otherwise the marked (composing) text gets torn down.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }

        let shouldForceFocus = context.coordinator.appliedFocusGeneration != focusGeneration
        if shouldForceFocus {
            context.coordinator.appliedFocusGeneration = focusGeneration
        }

        if (isFocused || shouldForceFocus), textView.window != nil, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                if textView.window?.firstResponder !== textView {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomPasteTextView
        weak var textView: PasteInterceptingTextView?
        var appliedFocusGeneration = 0

        init(_ parent: CustomPasteTextView) {
            self.parent = parent
        }

        func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
            // Images take priority. `NSImage(pasteboard:)` alone misses some
            // screenshot tools and Finder-copied image files, so decode all
            // common AppKit pasteboard representations.
            if let image = Self.image(from: pasteboard) {
                parent.onImagePaste(image)
                return true
            }
            if let string = pasteboard.string(forType: .string),
               PasteThreshold.isLarge(string) {
                parent.onLargePaste(string)
                return true
            }
            return false
        }

        private static func image(from pasteboard: NSPasteboard) -> NSImage? {
            if let image = NSImage(pasteboard: pasteboard) {
                return image
            }

            let readableTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
            for type in readableTypes {
                if let data = pasteboard.data(forType: type),
                   let image = NSImage(data: data) {
                    return image
                }
            }

            // Some apps publish only a concrete image UTI on each item (for
            // example JPEG, HEIC, WebP or a screenshot-tool-specific type).
            // Decode any representation that UniformTypeIdentifiers classifies
            // as an image instead of maintaining a fragile allow-list.
            for item in pasteboard.pasteboardItems ?? [] {
                for type in item.types {
                    guard let uniformType = UTType(type.rawValue),
                          uniformType.conforms(to: .image),
                          let data = item.data(forType: type),
                          let image = NSImage(data: data) else { continue }
                    return image
                }
            }

            if let images = pasteboard.readObjects(
                forClasses: [NSImage.self],
                options: nil
            ) as? [NSImage], let image = images.first {
                return image
            }

            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] {
                for url in urls {
                    if let type = UTType(filenameExtension: url.pathExtension),
                       type.conforms(to: .image),
                       let image = NSImage(contentsOf: url) {
                        return image
                    }
                }
            }

            return nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Ignore in-progress IME marked text; only commit real content so
            // the bound string never transiently holds composing pinyin.
            if textView.hasMarkedText() {
                recalculateHeight()
                return
            }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
            recalculateHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                if self.parent.isFocused == false {
                    self.parent.isFocused = true
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return parent.onCommandKey(.up)
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return parent.onCommandKey(.down)
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                return parent.onCommandKey(.cancel)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.onCommandKey(.accept)
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if parent.onCommandKey(.accept) {
                    return true
                }
                let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftPressed {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let newHeight = min(max(used + inset, parent.minHeight), parent.maxHeight)
            if abs(newHeight - parent.calculatedHeight) > 0.5 {
                parent.calculatedHeight = newHeight
            }
        }
    }
}
#endif

#Preview {
    @Previewable @State var message = ""
    return InputFieldsView(
        message: $message,
        conversationState: .completed,
        onStopGenerateTap: {},
        onSendMessageTap: {_, _, _, _  in},
        editMessage: .constant(nil)
    )
}
#endif
