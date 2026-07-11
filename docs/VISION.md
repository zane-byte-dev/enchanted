# VISION — 项目定位

## 一句话

给自建 agent 生态（pi / neo / wanda）做一个**能打的原生 macOS 桌面 GUI**，
体验对标 Codex 的 Mac App，而不是从零搭一套 UI。

## 为什么是 fork enchanted，而不是从零做

走过的弯路（见 atm session `019f32bd`，2026-07-05）：

1. 最初想法：为 pi/neo/wanda 做**统一 web GUI**（共享 React 组件 + 统一协议）。
2. 结论：三家样式系统对不上（Tailwind vs CSS Modules）、领域差异大、web 从零成本高，
   性价比低。
3. 换策略：**拿 enchanted 这个已经很精致的原生 SwiftUI 壳直接改，接 pi 后端。**
   省掉从零做 UI 的成本 —— 符合"最低成本解决问题"。

`enchanted` 原本就是一个成熟的、遵循 Apple 平台规范的原生聊天客户端
（macOS/iOS/visionOS，原接 Ollama）。壳好、可白嫖，只需换心脏。

## 目标（Goals）

- 原生 macOS 体验，性能与观感对齐 Codex Mac App。
- 一套 UI，通过 `AgentBackend` 抽象驱动多个 agent（pi 为主，neo/wanda 预留）。
- coding agent 该有的能力：项目工作区、流式对话、工具调用可视化、内嵌终端、
  技能管理、快捷键、通知、语音输入、Git worktree。

## 非目标（Non-goals）

- ❌ 不做 web 版（已论证性价比低）。
- ❌ 不追求 iOS/visionOS 特性同步 —— 重心是 macOS coding 场景；iOS 代码保留但不优先。
- ❌ 不保留 Ollama 运行后端 —— 产品直接以 pi 为当前唯一实现，`AgentBackend` 抽象继续为 neo/wanda 预留。
- ❌ 不上 App Store。走 **Developer ID 直分发**（官网/DMG + 公证），同 Codex。
  App Store 不允许下载/执行代码，与 coding agent 形态冲突。见 DECISIONS ADR-007。

## 成功标准

| 维度 | 标准 |
|------|------|
| 体验 | 长会话流式渲染不抖动、切换会话不白屏 |
| 架构 | 接入第二个后端（neo）时 UI 层零改动，只加一个 connector |
| 完整度 | 一个真实 coding 任务全程可在 GUI 里完成，不用回终端 |
| 可维护 | 新人/新 agent 读 `docs/` 能在半天内上手改代码 |

## 与相邻项目的关系

| 项目 | 形态 | 与本项目关系 |
|------|------|-------------|
| **pi** | coding agent（TUI + RPC） | 本项目的主后端；GUI 消费其 RPC 事件流 |
| **neo** | agent + React web UI | 候选后端（HTTP+SSE），抽象层已留位 |
| **wanda** | agent + React web UI（内网） | 候选后端（WS），抽象层已留位 |
| **atm** | 多 agent 会话监控 CLI | 观测本项目的开发过程（session/todo/report） |
