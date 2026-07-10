# Agent 后端抽象层

> 📚 项目级知识库在 [`../../docs/README.md`](../../docs/README.md)（定位/架构/计划/性能/决策）。
> 本文件只讲 Agent 层的实现细节；跨模块的计划与决策以 `docs/` 为准。

把 Enchanted 从"只会连 Ollama"改造成"一套原生 GUI 驱动多个 agent CLI"
（pi / neo / wanda）。对齐 pi 的 RPC 协议 / Zed 的 ACP。

## 文件

| 文件 | 作用 |
|---|---|
| `AgentBackend.swift` | 统一协议：`AgentChatMessage` / `AgentEvent` / `AgentBackend` |
| `OllamaBackend.swift` | 默认后端，包一层现有 OllamaKit，行为不变 |
| `PiConnector.swift` | 参考连接器：spawn `pi --mode rpc`，JSONL over stdio → `AgentEvent` |
| `PiSkill.swift` | 技能描述模型 + 从 pi `get_commands`（`source=="skill"`）解析 |

## 唯一的接入点

`Stores/ConversationStore.swift` 里新增了一个属性：

```swift
var backend: AgentBackend = OllamaBackend()
```

`sendPrompt` 里所有对 OllamaKit 的直接调用都换成了 `backend.chat(...)`，
事件通过 `handleEvent(_:)` 映射到 UI（`messageDelta` / `thinkingDelta` /
`toolStart` / `done`）。

## 切到 pi

在启动处（如 AppStore / 某个设置项）替换后端即可：

```swift
ConversationStore.shared.backend = PiConnector(
    config: .init(
        executable: "/absolute/path/to/pi",   // 或 node 启动脚本
        arguments: ["--mode", "rpc"],
        workingDirectory: "/your/project/root"
    )
)
```

之后正常发消息，token 就从 pi 的 RPC 流式回来。

### 注意：pi 是有状态会话

pi 的 RPC 进程自己维护整段对话历史。所以 `PiConnector.chat()` **只发最新一条
user 消息**，历史由 pi 侧保存。Enchanted 自己的 SwiftData 历史与 pi 会话历史
目前是两份、可能漂移——先跑通 spike，双向同步是后续步骤。

## ⚠️ 沙盒约束（重要）

沙盒 app **不能 spawn 外部进程**，也写不了容器外目录。所以：
- `PiConnector`（spawn `pi --mode rpc`）**要求非沙盒**。Debug 已在
  `EnchantedDebug.entitlements` 关掉 `com.apple.security.app-sandbox`。
- 分发 / 上架 App Store 不能这么做，需 XPC helper，或改走
  **网络连接**（neo/wanda 的 HTTP/WS server 天然绕开 spawn，只要
  `com.apple.security.network.client` 即可，可保持沙盒）。
- 结论：**pi 走 spawn（非沙盒）；neo/wanda 走网络（可沙盒）**。

启动时通过登录 shell 拉起 pi，以继承用户的 PATH（node）和 API key
（如 `IDEALAB_API_KEY`）——见 `AgentBackendConfig.swift`。

## 技能管理页（Skills）

仿 Codex「技能」面板的原生页面：
- `PiConnector.skills()` 发 `get_commands`，过滤 `source == "skill"`，映射成 `PiSkill`（name / description / scope / path）。
- `Stores/SkillStore.swift` 从控制后端拉取技能列表。
- `UI/macOS/SkillsMacOS.swift` 全页展示：标题 + 搜索 + scope 标签（全部/个人/项目）+ Installed 卡片网格。
- 入口：侧边栏「Skills」按钮 → `AppStore.shared.showSkills`，在 `Chat.swift` 里替换主窗口内容（与 Settings 同机制）。

## 待办（下一步）

- [ ] SwiftMath 接入 `ChatMessageView`，渲染 `$...$` 公式（纯原生）
- [ ] mermaid → 后端出 SVG/PNG，前端当图片
- [ ] PiConnector：`get_available_models` 真实模型列表；图片/steer/abort/compact
- [ ] NeoConnector（HTTP+SSE）/ WandaConnector（WS）
- [ ] 事件模型对齐 ACP schema
- [ ] pi/neo 会话历史与本地 SwiftData 的同步策略

## ⚠️ 加入 Xcode 工程

本工程是老式逐文件引用（objectVersion 56），不会自动纳入新文件。
装好 Xcode 后，把 `Enchanted/Agent` 文件夹拖进 Xcode 左侧目录树，
**Target 勾选 Enchanted**（"Copy items if needed" 不用勾，文件已在原位）。
或用 Xcode 菜单 File ▸ Add Files to "Enchanted"… 选中该文件夹。
