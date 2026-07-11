# Agent 后端抽象层

> 📚 项目级知识库在 [`../../docs/README.md`](../../docs/README.md)（定位/架构/计划/性能/决策）。
> 本文件只讲 Agent 层的实现细节；跨模块的计划与决策以 `docs/` 为准。

当前以 pi 作为唯一运行后端，并通过统一抽象为 neo / wanda 预留接入位。
事件模型对齐 pi 的 RPC 协议，并计划向 Zed ACP 靠拢。

## 文件

| 文件 | 作用 |
|---|---|
| `AgentBackend.swift` | 统一协议：`AgentChatMessage` / `AgentEvent` / `AgentBackend` |
| `PiConnector.swift` | 当前连接器：spawn `pi --mode rpc`，JSONL over stdio → `AgentEvent` |
| `PiSkill.swift` | 技能描述模型 + 从 pi `get_commands`（`source=="skill"`）解析 |

## 唯一的接入点

`Stores/ConversationStore.swift` 里新增了一个属性：

```swift
var backend: AgentBackend = AgentBackendConfig.makeBackend()
```

`sendPrompt` 只通过 `backend.chat(...)` 发起调用，
事件通过 `handleEvent(_:)` 映射到 UI（`messageDelta` / `thinkingDelta` /
`toolStart` / `done`）。

## 创建 pi 连接器

默认由 `AgentBackendConfig` 创建；需要显式配置时可直接构造：

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

沙盒 app 可以 spawn 子进程，但子进程会继承父进程沙盒；hardened runtime 下，
内置可执行体还需要同 Team 签名。当前 Debug 调用系统 PATH 中的外部 pi，因此暂时
关闭 `com.apple.security.app-sandbox`。目标分发形态是把 pi 打入 bundle、同 Team
签名，并通过 security-scoped bookmark 授权项目目录。详见 `docs/ARCHITECTURE.md`。

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
