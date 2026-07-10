# AGENTS.md — Enchanted（pi 原生 GUI 客户端）

> 给在这个仓库里干活的 AI agent（codex / pi / copilot）看的速览 + 协作准则。
> 人看的完整知识库在 [`docs/`](docs/README.md)。

## 这是什么

`gluonfield/enchanted` 的 fork。原项目是 Ollama 的原生 SwiftUI 聊天客户端
（macOS/iOS/visionOS）。**我们在把它改造成「一套原生 macOS GUI 驱动多个
coding agent CLI」的桌面客户端，体验标杆是 Codex 的 Mac App。**

- 后端从 Ollama 换成 **pi**（`pi --mode rpc`，JSONL over stdio）。
- 抽象层 `AgentBackend` 预留了 neo（HTTP+SSE）/ wanda（WS）的接入位。
- 语言：Swift + SwiftUI，Xcode 工程（objectVersion 56，老式逐文件引用）。

## 一分钟架构

```
UI (SwiftUI, UI/macOS)
   ↕ 唯一接入点
Stores/ConversationStore.swift  ── var backend: AgentBackend
   ↕ 统一事件流 AgentEvent
Agent/{OllamaBackend, PiConnector, NeoConnector*, WandaConnector*}
   ↕
外部 agent 进程 / 服务
```

- 统一协议：`Agent/AgentBackend.swift`（`AgentChatMessage` / `AgentEvent`）
- pi 连接器：`Agent/PiConnector.swift`（有状态会话，只发最新 user turn）
- 后端选择：`Agent/AgentBackendConfig.swift`（默认 `.pi`，可用 env 覆盖）
- 详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## 干活前必读的约束

1. **沙盒 & 分发**：本项目**走 Developer ID 直分发**（官网/DMG 下载 + 公证），
   **不上 App Store**。沙盒**不禁止** spawn 子进程——参考 Codex（`ChatGPT.app`
   实测：开沙盒 + 内置同 Team 签名的 `codex` 二进制 + 直分发）。当前 `PiConnector`
   调系统 PATH 里的外部 pi（非同签名）→ Debug 暂时关了 `app-sandbox`；目标形态是
   把 pi 打进 bundle 同 Team 签名后开启沙盒。详见 `docs/DECISIONS.md` ADR-003/007。
2. **新增 .swift 文件不会自动进 Xcode 工程**（objectVersion 56）。加文件后
   需在 Xcode 里 Add Files 并勾 Target Enchanted，否则编译不到。
3. **性能是老大难**：流式 markdown + SwiftData 会抖动/白屏/重复渲染。改
   `ConversationStore` / `ChatMessageView` 前先读 [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md)。
4. **只读工具结果不落库**：read/grep/glob 的大 payload 会撑爆 `blocksJSON`，
   `AgentRun.endTool` 里已丢弃，别改回去。

## 工作准则（对齐仓库主人 mj 的偏好）

- 默认最小改动，不主动扩大重构范围。
- 每个状态变更留一行反馈，别静默。
- 改完代码顺手更新关联文档（本文件 / `docs/`）。
- UI 对 Codex：够用就停，别陷进像素级抠图。
- 提交信息用中文 `feat/fix/style/i18n/refactor` 前缀（跟现有 git log 一致）。

## 常用

```bash
# 指定后端 / 项目目录（env 覆盖 Settings）
AGENT_BACKEND=pi PI_EXECUTABLE=~/.local/bin/pi PI_CWD=/path/to/proj open Enchanted.app
# 看这个项目的 AI 会话历史
atm session list --days 14 | grep -i enchant
```
