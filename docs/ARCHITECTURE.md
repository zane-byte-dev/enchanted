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
- pi 会话有状态：`chat()` **只发最新一条 user turn**，历史由 pi 侧保存。
- RPC 能力：`get_commands`（技能，`source=="skill"`）、`get_available_models`
  （`PiModelDescriptor`）、`get_session_stats`（`PiSessionStats`：token/cost/context）、
  会话恢复。
- prompt 提交前持久化 `sessionFile`。若应用在生成中退出，重启后扫描未完成的
  assistant 占位消息，通过 `switch_session` + `get_messages` 补回 pi 已落盘的输出；
  未完整落盘的任务标记为中断并保留上下文，不自动重跑可能产生副作用的工具。
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
