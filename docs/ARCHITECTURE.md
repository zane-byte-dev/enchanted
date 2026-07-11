# ARCHITECTURE — 架构

## 分层

```
┌─────────────────────────────────────────────────────────┐
│ UI  (SwiftUI)                                            │
│  UI/macOS  ── Chat / TerminalPanel / RightSidebarPanel   │
│              SettingsMacOS / SkillsMacOS / Menus         │
│  UI/Shared ── Chat 组件 / Sidebar / Voice / Settings     │
└───────────────┬─────────────────────────────────────────┘
                │ 观察 @Observable / 调用
┌───────────────▼─────────────────────────────────────────┐
│ Stores  (状态中枢)                                        │
│  ConversationStore ★唯一后端接入点  var backend           │
│  AppStore / ProjectStore / SkillStore / ShortcutStore    │
│  LanguageModelStore                                      │
└───────────────┬─────────────────────────────────────────┘
                │ backend.chat() → AnyPublisher<AgentEvent>
┌───────────────▼─────────────────────────────────────────┐
│ Agent  (后端抽象)                                         │
│  AgentBackend(协议) / AgentEvent / AgentChatMessage      │
│  PiConnector │ NeoConnector* │ WandaConnector*             │
│  AgentBackendConfig(pi 配置) / PiSkill / MessageBlock      │
└───────────────┬─────────────────────────────────────────┘
                │ stdio JSONL / HTTP+SSE / WS
        ┌───────▼───────┐
        │ pi / neo /    │   外部 agent 进程或服务
        │ wanda         │
        └───────────────┘

旁路服务 Services: GitWorktree / Notification / Hotkey / Clipboard /
                   SwiftData / Speech / Haptics / Throttler
持久化 SwiftData: 对话 / 消息（本地历史）
                   ScheduledTaskSD（本地调度定义与有界运行历史）
```

## 核心抽象：AgentBackend

`Agent/AgentBackend.swift` —— 让 UI 与具体 agent 解耦的关键。

```swift
protocol AgentBackend: Sendable {
    func chat(model:messages:) -> AnyPublisher<AgentEvent, Error>
    func models() async throws -> [LanguageModel]
    func reachable() async -> Bool
    func skills() async -> [PiSkill]      // 默认空
}

enum AgentEvent {
    case messageDelta(String)             // 增量正文
    case thinkingDelta(String)            // 增量推理
    case toolStart(callId:name:args:)
    case toolEnd(callId:name:result:isError:)
    case planUpdate(explanation:items:)   // 结构化任务计划
    case done
}
```

**唯一接入点**：`ConversationStore` 里 `var backend: AgentBackend`。
`sendPrompt` 只调用 `backend.chat(...)`，事件经
`handleEvent(_:)` 映射到 UI。**接新后端 = 新写一个 connector，UI 层不动。**

## 后端实现对照

| 后端 | 传输 | 会话状态 | 沙盒 | 状态 |
|------|------|---------|------|------|
| PiConnector | spawn + JSONL stdio | **有状态**，pi 进程持有历史 | ✅（需内置同签名） | 主力 |
| NeoConnector* | HTTP + SSE | 服务端会话 | ✅ | 未实现 |
| WandaConnector* | WebSocket | 服务端会话 | ✅ | 未实现 |

## PiConnector 要点

- spawn `pi --mode rpc`，通过**登录 shell** 拉起以继承 PATH（node）和 API key
  （如 `IDEALAB_API_KEY`）。可执行文件探测见 `AgentBackendConfig.detectedPiExecutable()`。
- 外部 pi 是正式支持的运行模式。启动诊断依次检查可执行权限、工作目录、最低版本 0.80.6、
  RPC 可达性和模型响应；失败页支持重新探测或手动选择。诊断结果缓存一分钟，普通 5 秒心跳
  继续使用轻量 `reachable()`。内置 pi 仅是未来强沙盒/开箱即用方案，不是当前功能前置。
- pi 会话有状态：`chat()` **只发最新一条 user turn**，历史由 pi 侧保存。
- RPC 能力：`get_commands`（技能，`source=="skill"`）、`get_available_models`
  （`PiModelDescriptor`）、`get_session_stats`（`PiSessionStats`：token/cost/context）、
  `compact`（手动上下文压缩）、`set_auto_compaction`（设置持久化并应用到 active
  session）、会话恢复。
- prompt 提交前持久化 `sessionFile`。若应用在生成中退出，重启后扫描未完成的
  assistant 占位消息，通过 `switch_session` + `get_messages` 补回 pi 已落盘的输出；
  未完整落盘的任务标记为中断并保留上下文，不自动重跑可能产生副作用的工具。
- 编辑旧 user turn、Retry、Regenerate 不原地改写有状态会话：先用
  `get_fork_messages` 校验本地 turn 与 pi entry，再调用 `fork(entryId)` 创建独立
  session，复制对应的 SwiftData 历史前缀后发送新 turn。原会话保持不变；若原回复
  包含非只读工具，Retry 前由 UI 明示可能重复副作用并二次确认。
- 消息 deep link 使用 `enchanted://conversation/<conversation-id>#<message-id>`；打开后
  显式加载完整本地 transcript、滚动到目标消息并短暂高亮。删除操作保留 10 秒内存
  快照，允许将会话及消息以原 UUID 恢复。
- 手动与自动 Compact 都监听完整 lifecycle，并在 transcript 中插入轻量状态消息，展示压缩前后
  token；SwiftData 继续保留完整可读 transcript，不插入 pi summary 正文，完成后刷新 stats。
- 运行中输入支持两种语义：`steer` 立即引导当前任务；Queue 使用客户端队列，允许单条删除、
  调整顺序和携带图片，当前任务 settle 后作为普通独立 turn 自动续跑。之所以不直接依赖 pi
  `follow_up`，是因为其 RPC 没有单条删除或重排能力。
- 一次任务以 pi 的 `agent_settled` 作为真正完成边界，而不是较早出现的 `agent_end`；
  到达该边界后，客户端 Queue 才会安全启动下一条普通 turn 和新的事件流。
- Changes 侧栏读取 Git status/numstat/diff，并提供打开文件、Stage、Unstage；Discard 必须二次
  确认，未跟踪文件删除前还会校验规范化路径没有逃出仓库根目录。
- 每次任务结束后比较本地 SwiftData 与 pi `get_fork_messages` 返回的 user turn 序列；
  发现数量或内容不一致时标记 history drift。差异页可选择用 pi 活跃 JSONL 分支重建本地，
  或把本地可见 user/assistant 文本写成新的 pi v3 session（明确不复制隐藏 thinking/tool traces）。
- 启动 pi 时始终加载运行时生成的 Enchanted extension（因为它同时提供 Plan）。审批策略可选关闭、
  仅高风险或所有变更；严格档会确认 bash/write/edit 及第三方非只读工具。常见网络命令另有
  allow/ask/block 策略。确认通过 `extension_ui_request` / `extension_ui_response` 在输入区完成。
  这仍是 Enchanted 策略层，不是 pi 原生权限系统，也不等价于进程级网络沙盒。
- 同一个运行时 extension 注册 `update_plan` 工具；`PiConnector` 将调用转换为 `planUpdate`，
  `ConversationStore` 把快照独立写入 `ConversationSD.planJSON`，因此不膨胀消息 blocks，并能随分支
  和删除 Undo 保留。Plan 面板持续展示完成数、进行中与待办步骤。
- 新任务可在首发前选 Local 或 Git Worktree；Worktree 准备完成后才创建 pi 任务。Changes 侧栏可
  创建独立只读 Code Review。Browser 使用任务侧栏 WKWebView；Side Chat 使用独立临时 connector，
  不写入主任务 SwiftData/pi session。
- 长期目标保存在会话模型中。切到别的任务不会停止当前 connector；目标可暂停/恢复。开启自动续跑后，
  普通用户 Queue 总是优先，随后仅在结构化 Plan 仍有未完成步骤时发起下一轮；最多连续 12 轮，全部
  Plan 完成时自动完成目标。应用重启只恢复目标状态，不自动重放可能有副作用的工具。
- `ScheduledTaskStore` 在模型与会话加载后启动，每 30 秒检查 SwiftData 中到期的定义。到期项创建普通
  可见会话，因此继续经过相同的权限确认、通知和中断恢复；支持错过后补跑一次或跳过，运行历史最多
  保存 50 条，并由 `ConversationStore` 在对应任务完成/失败时回写最终状态。应用退出时不承诺执行。
- Settings 的 Extensions 页直接调用配置中的 pi 可执行文件（不经过 shell），封装
  `install/remove/update`，读取用户与项目 `.pi/settings.json` 中的 packages。操作明确展示作用域和
  第三方代码信任提示，完成后递增 backend generation，使活动任务自然结束、下一轮加载新 package。
  pi 0.80.6 没有统一 MCP registry API，因此 MCP server 的配置仍属于具体 extension package。
- write/edit 工具块从参数解析产物路径；成功后提供内嵌 `QLPreviewView`、默认应用打开和 Finder 定位。
  Quick Look 复用系统对图片、PDF、Office/iWork 文档、表格和 HTML 等类型的预览能力。
- `PiConnector` 的共享状态统一经 `NSLock.withLock` 访问，避免在 async context 直接调用
  `lock()` / `unlock()`；真实 RPC 集成检查见 `Scripts/verify-pi-rpc.mjs`。
- ⚠️ **本地 SwiftData 历史 与 pi 会话历史是两份，可能漂移** —— 同步策略未定，见 ROADMAP。

## 数据流：一次发送

```
用户输入
 → ConversationStore.sendPrompt
 → backend.chat(model, [最新 user turn])
 → AgentEvent 流:
     messageDelta  → AgentRun.appendText   → 尾部 text block 累加
     thinkingDelta → AgentRun.appendThinking
     toolStart     → AgentRun.startTool    → 新 tool block
     toolEnd       → AgentRun.endTool      → 只读工具丢弃 result（防膨胀）
     planUpdate    → Conversation.planJSON → 输入区 Plan 面板
     done          → 落库 + NotificationService.notifyConversationFinished
 → Throttler(0.1s) 节流刷 UI（防抖动）
```

`AgentRun`（每会话一个）承载在途生成，支持多会话并行。

## 模块地图

| 目录 | 职责 |
|------|------|
| `Agent/` | 后端抽象、pi 连接器、技能模型、渲染块模型、后端配置 |
| `Stores/` | `@Observable` 状态中枢，桥接 UI ↔ Agent ↔ SwiftData |
| `Services/` | 无状态系统能力：Git worktree、通知、全局热键、剪贴板、语音、持久化 |
| `VoiceInput/` | SenseVoice + Apple Speech 双引擎、录音协调、文本注入、悬浮层 |
| `UI/macOS/` | macOS 专属：聊天、终端面板、右侧栏、设置页、技能页、菜单/命令 |
| `UI/Shared/` | 跨平台组件：聊天消息、侧边栏、语音、设置 |
| `UI/iOS/` | iOS 专属（保留，不优先） |
| `SwiftData/` | 本地对话/消息持久化模型 |
| `Models/` | 值类型：语言模型、会话状态、通知消息、配色、语言 |

## 关键约束

1. **沙盒 & spawn（纠正旧认知）**：沙盒**不禁止** spawn 子进程。真实规则：
   - 子进程**继承父进程的沙盒**（pi 及它再起的 shell 命令都被关在同一沙盒里）。
   - hardened runtime + library validation 下，被 spawn 的可执行体必须**同 Team 签名**。
   - 访问任意目录靠 `files.user-selected.read-write` + security-scoped bookmark。

   **Codex 实测参考**（`ChatGPT.app`）：开沙盒 + 把 260MB 单体 `codex`（Rust）二进制
   内置 bundle 并同 Team 签名 + node-pty spawn + **Developer ID 直分发（非 App Store）**。

   本项目结论：**走 Developer ID 直分发**。目标形态是把 pi（含 node runtime 或
   SEA 单体）打进 bundle、同 Team 签名后**开启沙盒**。当前 Debug 因为调外部 PATH 里的
   pi（非同签名），暂在 `EnchantedDebug.entitlements` 关了 `app-sandbox`。
2. **Xcode 老工程（objectVersion 56）**：新增 `.swift` 不自动纳入 target，需手动
   Add Files 勾 Enchanted。
3. **只读工具结果不落库**：`AgentRun.endTool` 丢弃 read/grep/glob 的大 payload，
   避免 `blocksJSON` 膨胀导致返回时长白屏。
