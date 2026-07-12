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
- [x] macOS 单元测试 Target：版本诊断、Plan、任务产物、Scheduled Task 持久化
- [x] 冷启动 UI 冒烟：旧数据迁移、模型加载、设置/任务/扩展/Browser/Side Chat 导航
- [x] `AgentBackend` 抽象 + `PiConnector`（流式文本/thinking/tool/恢复/stats）
- [x] 技能管理页（`get_commands` → `PiSkill` → `SkillsMacOS`）
- [x] 真实模型列表（`get_available_models` → `PiModelDescriptor`）+ 模型选择
- [x] 内嵌终端面板（SwiftTerm PTY，VS Code 风格）
- [x] 右侧工具侧边栏（可拖拽宽度）
- [x] Git worktree + 项目文件夹菜单（对齐 Codex）
- [x] 快捷键自定义（录制/冲突/恢复默认）+ 第一批聊天快捷键
- [x] 任务完成通知（`NotificationService`）
- [x] 简中本地化（String Catalog）
- [x] Codex 风格收口：中性窗口强调色、三栏紧凑输入区、中文工具导航与带主操作的空状态
- [x] 语音输入（SenseVoice + Apple Speech 双引擎）
- [x] 移除 Ollama 运行链路与 OllamaKit 依赖，当前直接使用 pi

### 待办
- [x] 品牌轻量更名：用户可见名称从 `Enchanted` 改为 `Mox`（App 显示名称、窗口/About/设置文案、图标、README 与本地化）；保留 Xcode 工程名、Target、Swift module、Bundle Identifier、源码目录和仓库名
- [x] PiConnector 图片输入（支持多图、粘贴与历史展示）
- [x] PiConnector steer + abort
- [x] PiConnector compact（context stats 菜单手动触发，完成后刷新 token/context）
- [x] Auto Compact（设置持久化并同步到当前 pi session）
- [x] Follow-up Queue（客户端可查看、删除、调整顺序；当前任务结束后按独立 turn 自动续跑）
- [x] 搜索快捷键（聊天 / 项目）
- [x] 会话内搜索（⌘F，全量加载后高亮与上下跳转）
- [x] SwiftMath 原生渲染 `$...$` / `$$...$$`，支持行内混排、块公式居中和长公式横向滚动
- [x] Mermaid 11.15.0 离线生成 SVG，前端按图片展示；深浅色缓存、严格模式、失败回退源码
- [x] 项目 Agent 指引状态：按 pi 实际顺序显示全局/祖先/cwd 的 AGENTS.md/CLAUDE.md，支持打开、创建、重扫和重载
- [x] 对话操作对齐：从消息处分支、Retry/Regenerate、消息复制、标题栏统一菜单、Markdown/JSON 导出
- [x] 对话操作安全收口：消息链接精确定位、Retry 副作用确认、分支 loading/防重、删除确认与 10 秒 Undo
- [x] Changes 侧栏：Git 状态、增删统计、Diff 着色、打开文件、Stage/Unstage 与确认式 Discard
- [x] Diff 行内评审：解析 unified diff 新旧行号、按任务保留草稿、批量发送给当前 Agent、清空前确认
- [x] Changes 逐 hunk Stage/Unstage/Revert：标准 patch、过期上下文安全失败、Revert 二次确认
- [x] Changes Commit/Push/Create PR：仅提交 staged、首次 Push 自动 upstream、PR 支持标题/描述/draft 与 gh 路径探测
- [x] 高风险操作确认：pi Extension UI 请求在聊天内渲染确认卡，默认拦截危险命令和工作区外写入
- [x] 新任务环境：发送前选择 Local / Worktree；Worktree 创建失败时不降级执行
- [x] 现有任务 Local ↔ Worktree 安全 handoff：迁移 staged/unstaged/untracked 状态、复制 `.worktreeinclude` 文件，以 pi session fork 保持上下文
- [x] Handoff 基线合并：保留目标已有的非冲突 staged/unstaged/untracked 改动；重叠 hunk 或路径冲突时精确恢复目标并保留源端，UI 显示 Git 冲突位置
- [x] 独立 Code Review：从 Changes 一键创建只读审查任务
- [x] Browser / Side Chat：内嵌网页调试与不污染主会话的临时 pi 对话
- [x] 结构化 Plan/TODO：`update_plan` 扩展工具、会话持久化、分支与删除 Undo 保留
- [x] 长期目标与后台续跑基础：目标/状态持久化、切任务继续运行、暂停/恢复、Plan 完成条件、最多 12 轮自动续跑
- [x] 启动时恢复入口：侧栏标记 active/paused 目标，进入任务后由用户恢复；不自动重放工具
- [x] 任务产物入口：write/edit 工具卡直接打开文件或在 Finder 定位
- [x] 内嵌产物预览：工具卡内 Quick Look 检查图片、PDF、文档、表格与 HTML
- [x] Scheduled Tasks：创建/编辑/启停/立即运行、小时/日/周周期、错过策略、最近 50 次运行历史
- [x] pi Extensions：原生 package manager 的安装、更新、移除、用户/项目作用域与命令诊断
- [ ] 统一 MCP 管理：等待 pi 暴露 server registry/授权/工具发现协议，当前由 extension package 自行提供
- [x] Extension 审批策略：关闭/仅高风险/所有变更，严格档覆盖第三方非只读工具
- [x] 命令级网络策略：常见下载、远程 Git、SSH 与包管理命令支持允许/询问/阻止
- [ ] 进程级网络隔离与审计：依赖内置同签名 pi + macOS Sandbox

---

## M2 · 稳（优先级最高，别被 M1 铺功能盖过）

### 🔴 性能（见 PERFORMANCE.md）
- [x] 流式渲染抖动：0.1s flush + 稳定 Markdown 前缀缓存 + live tail 轻量文本
- [x] 切换会话白屏：尾部分页、30 条渲染窗口、最近 8 会话热缓存与后台刷新
- [x] pi 历史导入去重：稳定 entry id + active branch 重建，连续 assistant/tool 片段合并
- [x] 长会话滚动：尾部 30 条有界窗口、分页加载与稳定 bottom anchor

### 🔴 会话历史同步
- [x] 历史权威策略：pi active branch 是 agent 上下文权威；SwiftData 是显示投影与本地 UI 元数据，默认从 pi 原子重建，反向重建仅作有损应急恢复
- [x] 软件重启后恢复历史会话上下文
- [x] 在途任务安全恢复（补拉 pi transcript；未完成时标记中断，不自动重跑工具）
- [x] 历史漂移探测（比较本地与 pi 的 user turn 序列，任务结束后自动检查并支持手动复查）
- [x] 历史漂移修复（逐轮差异预览；可用 pi 分支替换本地，或从本地可见对话重建 pi v3 session）

### 🟡 分发（路线已定：Developer ID 直分发，见 ADR-007）
- [x] 外部 pi 正式支持模式：自动探测/手选路径、最低 0.80.6、工作目录与 RPC/模型诊断
- [x] pi 打包进 bundle：实测选择精简 Node runtime（约 266MB、约 1 秒启动），Bun 单体保留可选；Release 缺 runtime 硬失败
- [x] 内置 pi 同 Team 签名 + hardened runtime：Node 仅 JIT/unsigned executable memory 例外，native modules 分别签名，`codesign --deep --strict` 与 bundle RPC 通过
- [ ] Developer ID Release 签名 + DMG + notarization/staple 流水线
- [ ] 开沙盒：security-scoped bookmark 接用户选目录；pi 子进程受限验证

> 内置 pi 已成为 Release 的开箱即用默认；外部 pi 保留为开发/fallback。剩余分发门槛是
> Developer ID Release/公证和 security-scoped bookmark + App Sandbox 验证。

---

## M3 · 多后端（验证抽象层）

- [ ] `NeoConnector`（HTTP + SSE），事件映射到 `AgentEvent`
- [ ] 事件模型对齐 ACP schema（对齐 Zed 生态，降低后续适配成本）
- [ ] 验收标准：**接 neo 时 UI 层零改动**，只新增 connector + 配置项
- [ ] 后端切换 UI（接入 neo 后在 Settings 里选 pi / neo）

---

## M4 · 完整

- [ ] `WandaConnector`（WS），处理内网 registry / 鉴权
- [ ] wanda 重业务 toolCard 的可插拔渲染
- [ ] 语音/技能体验打磨
- [ ] 面向"给别人用"的文档与打包

---

## 决策待拍（回撤成本高，需 mj 定）

1. **事件协议**：自定义 `AgentEvent` 演进，还是直接对齐 ACP？
2. **iOS 去留**：继续保留还是砍掉聚焦 macOS？

> ✅ 分发形态已拍：Developer ID 直分发（ADR-007）。

> 决策一旦拍定，记录进 [DECISIONS.md](DECISIONS.md)。
