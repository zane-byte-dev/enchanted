# DECISIONS — 技术决策记录（ADR）

> 每条记录一个"回撤成本高"的决策：背景、选择、理由、状态。
> 新决策往下追加，别删旧的（改为标记 Superseded）。

---

## ADR-001 · fork enchanted 而非从零做 web GUI
- **日期**：2026-07-05
- **状态**：Accepted
- **背景**：想给 pi/neo/wanda 做统一 GUI。评估过共享 React web 组件 + 统一协议。
- **决策**：放弃 web，fork 原生 SwiftUI 项目 enchanted，换后端为 pi。
- **理由**：三家样式系统对不上、领域差异大、web 从零成本高；enchanted 壳成熟可白嫖。
- **代价**：绑定 Apple 生态；SwiftUI 流式渲染性能需自己啃。

## ADR-002 · 引入 AgentBackend 抽象层
- **日期**：2026-07-06 起
- **状态**：Accepted
- **决策**：UI 只依赖 `AgentBackend` 协议 + `AgentEvent` 事件流；`ConversationStore.backend`
  为唯一接入点。
- **理由**：接新 agent = 新写 connector，UI 零改动。
- **验收**：M3 接 neo 时 UI 不动即证明成立。

## ADR-003 · 沙盒与 spawn（已纠正）
- **日期**：2026-07-06，**2026-07-10 纠正**
- **状态**：Accepted（Superseded 旧表述）
- **旧（错误）表述**：“沙盒 app 不能 spawn 外部进程，pi 必须非沙盒”。
- **纠正（实测 Codex 后）**：沙盒**不禁止** spawn。真实规则：子进程继承沙盒；
  hardened runtime 下被 spawn 的二进制需**同 Team 签名**；文件访问靠 user-selected 授权。
- **证据**：`ChatGPT.app`（含 Codex）开沙盒 + 内置同 Team（2DC432GLL2）签名的 260MB
  单体 `codex` 二进制 + node-pty spawn + 无 MASReceipt（Developer ID 直分发）。
- **当前现状**：`PiConnector` 调外部 PATH 里的 pi（非同签名），Debug 暂关 app-sandbox。
  目标形态见 ADR-007。

## ADR-004 · pi 会话有状态，chat() 只发最新 turn
- **日期**：2026-07-06
- **状态**：Accepted
- **决策**：pi 进程持有整段 transcript，`PiConnector.chat()` 只发最新 user turn。
- **副作用**：本地 SwiftData 历史与 pi transcript 是两份，可能漂移（同步策略见 ROADMAP M2）。

## ADR-005 · 只读工具结果不落库
- **日期**：2026-07-08
- **状态**：Accepted
- **决策**：`AgentRun.endTool` 对 read/grep/glob 等只读工具丢弃 `resultText`。
- **理由**：整文件内容可达 MB 级，撑爆 `blocksJSON`，返回时长白屏。

## ADR-006 · 保留原生渲染，暂不改 WebView
- **日期**：2026-07-08
- **状态**：Accepted（可复议）
- **决策**：对话继续用原生 SwiftUI 渲染，先做增量渲染优化，不切 WebView。
- **理由**：WebView 丢原生质感、增桥接复杂度，与定位冲突。性能达标前不复议。

---

## ADR-007 · 走 Developer ID 直分发 + 内置 pi，开沙盒
- **日期**：2026-07-10
- **状态**：Accepted
- **决策**：**不上 App Store，走 Developer ID 签名 + 公证的直分发**（官网/DMG）。
  目标形态：把 pi（含 node runtime 或 SEA 单体可执行体）**打进 app bundle 并同 Team
  签名**，然后**开启沙盒**（照搬 Codex）。
- **理由**：App Store 几乎不允许下载/执行代码，与 coding agent 形态冲突；Developer ID
  直分发既能开沙盒又能 spawn 内置引擎，是 Codex 已验证的路。
- **待办**：pi 打包方案（bundle node vs bun/SEA 编单体）；security-scoped bookmark 接
  用户选目录；hardened runtime + 公证流程；pi 子进程（npm/git/编译）在沙盒下的受限验证。

---

## 待拍（见 ROADMAP「决策待拍」）

- ADR-008 · 会话历史权威方：pi transcript vs 本地 SwiftData
- ADR-009 · 事件协议：自定义 AgentEvent 演进 vs 对齐 ACP
- ADR-010 · iOS 去留
