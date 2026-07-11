# ROADMAP — 计划

> 原则：先性能与架构收口，再谈铺功能。UI 对 Codex 已到边际收益递减，够用即停。

## 里程碑

| 阶段 | 目标 | 状态 |
|------|------|------|
| **M0 Spike** | pi RPC 跑通，能在 GUI 里完成一次对话 | ✅ 完成 |
| **M1 单后端可用** | pi 全能力 + Codex 级 UX，日常 coding 可用 | 🚧 进行中 |
| **M2 稳** | 性能达标 + 会话历史同步 + 分发路径确定 | ⬜ |
| **M3 多后端** | 接入 neo，验证抽象层；UI 层零改动 | ⬜ |
| **M4 完整** | wanda + 语音/技能打磨 + 对外可用 | ⬜ |

---

## M1 · 单后端可用（当前）

### 已完成
- [x] `AgentBackend` 抽象 + `PiConnector`（流式文本/thinking/tool/恢复/stats）
- [x] 技能管理页（`get_commands` → `PiSkill` → `SkillsMacOS`）
- [x] 真实模型列表（`get_available_models` → `PiModelDescriptor`）+ 模型选择
- [x] 内嵌终端面板（SwiftTerm PTY，VS Code 风格）
- [x] 右侧工具侧边栏（可拖拽宽度）
- [x] Git worktree + 项目文件夹菜单（对齐 Codex）
- [x] 快捷键自定义（录制/冲突/恢复默认）+ 第一批聊天快捷键
- [x] 任务完成通知（`NotificationService`）
- [x] 简中本地化（String Catalog）
- [x] 语音输入（SenseVoice + Apple Speech 双引擎）

### 待办
- [x] PiConnector 图片输入（支持多图、粘贴与历史展示）
- [x] PiConnector steer + abort
- [ ] PiConnector compact
- [x] 搜索快捷键（聊天 / 项目）
- [ ] 会话内搜索
- [ ] SwiftMath 渲染 `$...$` 公式（纯原生）
- [ ] mermaid → 后端出 SVG/PNG，前端当图片
- [ ] 右键菜单继续对齐 Codex（够用即停）

---

## M2 · 稳（优先级最高，别被 M1 铺功能盖过）

### 🔴 性能（见 PERFORMANCE.md）
- [ ] 流式渲染抖动根治（当前靠 Throttler 0.1s 缓解）
- [ ] 切换会话白屏（大 `blocksJSON` 反序列化 + relayout）
- [ ] pi 历史导入重复渲染
- [ ] 长会话滚动性能

### 🔴 会话历史同步
- [ ] 定策略：本地 SwiftData 历史 ↔ pi 会话 transcript（谁是权威 / 如何对齐）
- [ ] 软件重启后恢复在途/历史任务（曾报"重启无法继续"）

### 🟡 分发（路线已定：Developer ID 直分发，见 ADR-007）
- [ ] pi 打包进 bundle：bundle node vs bun/SEA 编单体可执行体
- [ ] 内置 pi 同 Team 签名 + hardened runtime + 公证流程
- [ ] 开沙盒：security-scoped bookmark 接用户选目录；pi 子进程受限验证

---

## M3 · 多后端（验证抽象层）

- [ ] `NeoConnector`（HTTP + SSE），事件映射到 `AgentEvent`
- [ ] 事件模型对齐 ACP schema（对齐 Zed 生态，降低后续适配成本）
- [ ] 验收标准：**接 neo 时 UI 层零改动**，只新增 connector + 配置项
- [ ] 后端切换 UI（Settings 里选 pi / neo / ollama）

---

## M4 · 完整

- [ ] `WandaConnector`（WS），处理内网 registry / 鉴权
- [ ] wanda 重业务 toolCard 的可插拔渲染
- [ ] 语音/技能体验打磨
- [ ] 面向"给别人用"的文档与打包

---

## 决策待拍（回撤成本高，需 mj 定）

1. **会话历史权威方**：pi transcript 为准，还是本地 SwiftData 为准？
2. **事件协议**：自定义 `AgentEvent` 演进，还是直接对齐 ACP？
3. **iOS 去留**：继续保留还是砍掉聚焦 macOS？

> ✅ 分发形态已拍：Developer ID 直分发（ADR-007）。

> 决策一旦拍定，记录进 [DECISIONS.md](DECISIONS.md)。
