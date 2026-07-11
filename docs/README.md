# Enchanted 知识库

> Enchanted（本 fork）= 一套原生 macOS GUI，驱动多个 coding agent CLI（pi / neo / wanda），
> 体验对标 Codex Mac App。这里是项目的单一事实来源（single source of truth）。

## 导航

| 文档 | 内容 | 什么时候看 |
|------|------|-----------|
| [VISION.md](VISION.md) | 项目定位、动机、非目标、成功标准 | 想搞清"为什么做这个"、对外介绍 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 分层架构、模块地图、数据流、后端抽象、沙盒约束 | 动代码前、接新后端 |
| [ROADMAP.md](ROADMAP.md) | 分阶段完整计划 + 里程碑 + 待办 | 规划、决定下一步做什么 |
| [PERFORMANCE.md](PERFORMANCE.md) | 卡顿/白屏/抖动/重复渲染的成因与对策 | 改聊天渲染、Store 前 |
| [DECISIONS.md](DECISIONS.md) | 关键技术决策记录（ADR） | 想知道"为什么当初这么选" |
| [../AGENTS.md](../AGENTS.md) | 给 AI agent 的速览 + 协作准则 | 每次开工 |

### 历史提案（保留归档）

- [large_text_input_design.md](large_text_input_design.md) — 防卡顿的大段文本输入（Codex 风格）
- [folder_quick_create_proposal.md](folder_quick_create_proposal.md) — 文件夹快速创建

### 模块内文档

- [../Enchanted/Agent/README.md](../Enchanted/Agent/README.md) — Agent 后端抽象层实现细节

## 现状速览（截至 2026-07-10）

- ✅ pi RPC 后端跑通（流式文本 / thinking / tool call / 会话恢复 / stats）
- ✅ 移除旧 Ollama 运行链路与 OllamaKit 依赖，当前直接使用 pi
- ✅ 技能管理页、Git worktree、项目文件夹菜单、快捷键自定义、任务通知
- ✅ 内嵌终端（SwiftTerm PTY）、右侧工具侧边栏、简中本地化
- ✅ SenseVoice / Apple Speech 语音输入
- 🚧 性能（流式渲染抖动/白屏）
- ⬜ NeoConnector / WandaConnector（抽象层已留位，未实现）
- ⬜ 本地 SwiftData 历史 ↔ pi 会话历史 的同步策略
- ⬜ 分发路径（非沙盒 vs App Store / XPC helper）

## 维护约定

改动涉及架构 / 决策 / 计划时，**同一个 commit 里更新对应文档**。
知识库过期比没有更糟。
