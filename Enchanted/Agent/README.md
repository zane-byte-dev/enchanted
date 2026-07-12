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
user 消息**，历史由 pi 侧保存。pi active branch 是 agent 上下文权威，SwiftData
是可原子重建的显示投影；漂移会暂停发送和自动续跑，详见 ADR-008。

## ⚠️ 沙盒约束（重要）

沙盒 app 可以 spawn 子进程，但子进程会继承父进程沙盒；hardened runtime 下，
内置可执行体还需要同 Team 签名。Release 通过 `Scripts/prepare-pi-runtime.sh` 生成精简
Node runtime，Xcode 把 Node 放进 `Contents/Helpers/pi-node`、JS 放进 Resources，
并用 App 的签名身份签 Node；
Debug 缺 runtime 时仍可调用外部 pi。当前尚未开启 App Sandbox，下一步是用
security-scoped bookmark 授权项目目录。详见 `docs/DISTRIBUTION.md`。

内置 runtime 自带 Node，不依赖登录 shell 或系统 PATH；API key 与 provider 配置仍从
Mox 进程环境和 `~/.pi/agent` 读取。外部 pi 模式继续补全常用 GUI PATH。

## 技能管理页（Skills）

仿 Codex「技能」面板的原生页面：
- `PiConnector.skills()` 发 `get_commands`，过滤 `source == "skill"`，映射成 `PiSkill`（name / description / scope / path）。
- `Stores/SkillStore.swift` 从控制后端拉取技能列表。
- `UI/macOS/SkillsMacOS.swift` 全页展示：标题 + 搜索 + scope 标签（全部/个人/项目）+ Installed 卡片网格。
- 入口：侧边栏「Skills」按钮 → `AppStore.shared.showSkills`，在 `Chat.swift` 里替换主窗口内容（与 Settings 同机制）。

## 待办（下一步）

- [ ] security-scoped bookmark + App Sandbox 子进程验证
- [ ] NeoConnector（HTTP+SSE）/ WandaConnector（WS）
- [ ] 事件模型对齐 ACP schema

## ⚠️ 加入 Xcode 工程

本工程是老式逐文件引用（objectVersion 56），不会自动纳入新文件。
装好 Xcode 后，把 `Enchanted/Agent` 文件夹拖进 Xcode 左侧目录树，
**Target 勾选 Enchanted**（"Copy items if needed" 不用勾，文件已在原位）。
或用 Xcode 菜单 File ▸ Add Files to "Enchanted"… 选中该文件夹。
