# Codex 对齐矩阵

> 目标不是“长得像”，而是 coding workflow 可替代。基线来自当前官方文档的
> Projects / Tasks、Environments、Code Review、Integrated Terminal、Long-running Work、
> Scheduled Tasks、Browser、Plugins、Permissions 等功能面。

状态定义：✅ 可日用；🟡 已有基础但未完全对齐；⬜ 未实现；🚫 需要 pi/远端服务新增能力。

## 项目、任务与环境

| Codex 能力 | 当前状态 | Mox 验收标准 |
|---|---:|---|
| 本地项目与多任务 | ✅ | 按工作目录分组；任务可并行运行、切换与恢复 |
| Local 环境 | ✅ | 直接在绑定目录运行 |
| 外部 pi 安装 | ✅ | 自动探测/手动选择、最低版本校验、目录与 RPC/模型诊断；不要求打包进 App |
| 内置 Agent runtime | ✅ | Release 优先使用同 Team 签名的精简 Node + pi；缺 runtime 构建失败，Debug 可回退外部 pi |
| Git Worktree 环境 | ✅ | 新任务首发前可直接选择 Local / Worktree；创建失败不会静默退回本地 |
| Local ↔ Worktree handoff | ✅ | 双向合并 staged/unstaged/untracked 状态、复制 `.worktreeinclude` 文件并通过 pi session fork 延续上下文；非冲突目标改动保留，冲突时恢复双端且明确报错 |
| Cloud 环境 | 🚫 | 需要远端 runner、鉴权、日志与产物协议，不用本地假按钮冒充 |
| 任务 pin/archive/rename/delete | ✅ | 含删除确认与 10 秒 Undo |
| 长期目标与后台续跑 | ✅ | 目标/状态持久化、侧栏恢复标记、暂停恢复、切任务继续运行、Plan 完成条件和限次自动续跑 |

## 对话与 Agent 控制

| Codex 能力 | 当前状态 | Mox 验收标准 |
|---|---:|---|
| 流式回答、thinking、tool cards | ✅ | 文本/推理/工具顺序稳定，Markdown 与原生公式正确，长会话不白屏 |
| Stop / Steer / Queue | ✅ | Queue 可查看、删除、排序并独立落库 |
| Compact / Auto Compact | ✅ | lifecycle 与 token 前后状态可见 |
| Retry / Regenerate / Fork from Here | ✅ | pi session 真分支，不污染原会话 |
| 搜索、链接、复制、导出 | ✅ | 消息级深链、⌘F、Markdown/JSON |
| Plan / TODO / progress | ✅ | pi `update_plan` 扩展工具驱动结构化计划，独立持久化并随分支/Undo 保留 |
| 子 Agent / 并行协作 | 🚫 | 需要 pi 扩展或后端事件协议支持 agent tree |

## 开发工作流

| Codex 能力 | 当前状态 | Mox 验收标准 |
|---|---:|---|
| Integrated Terminal | ✅ | 多标签 PTY、按对话保留状态 |
| Changes / Diff | ✅ | 整文件/逐 hunk 操作、行内意见、Commit、首次/后续 Push；PR 通过已认证的 GitHub CLI 创建 |
| Code Review | ✅ | Changes 一键创建独立只读审查任务，按严重度输出可定位 findings |
| 文件输入与图片输入 | ✅ | 多图、粘贴、文件/文件夹上下文 |
| 文件产物预览 | ✅ | write/edit 工具卡内嵌 Quick Look，支持系统可预览的图片/PDF/文档/表格/HTML，并可打开或 Finder 定位 |
| Browser / 网页测试 | ✅ | 任务侧栏内嵌 WKWebView，支持地址、刷新、停止与前进后退 |
| Side Chat | ✅ | 独立临时 PiConnector 与内存 transcript，不污染主任务 session |

## 扩展、自动化与安全

| Codex 能力 | 当前状态 | Mox 验收标准 |
|---|---:|---|
| Skills | ✅ | 从 pi `get_commands` 读取并可插入执行 |
| Plugins / pi Packages | ✅ | 原生 `pi install/remove/update`；用户/项目作用域、可信提示、输出诊断，变更后重建 connector |
| MCP | 🟡 | 可由 pi package 提供；pi 0.80.6 暂无统一 MCP server registry API，待后端协议 |
| AGENTS.md / 项目指引 | ✅ | 项目菜单显示 pi 实际生效的全局/祖先/cwd 指引，可打开、创建、重扫并重载 connector |
| Hooks / Rules | 🟡 | 可由 pi extension 实现；缺统一规则清单、生命周期状态与机械执行 UI |
| Scheduled Tasks | ✅ | SwiftData 持久化；创建/编辑/启停/立即运行；周期调度、最终运行状态与错过任务策略 |
| Notifications | ✅ | 完成/失败通知与任务跳转 |
| 审批卡 | ✅ | Extension UI 三档策略：关闭、仅高风险、所有变更；严格档覆盖非只读 extension 工具 |
| 强沙盒 | 🚫 | 目标是 Developer ID + 同签名内置 pi + macOS Sandbox/bookmark |
| 网络权限策略 | 🟡 | 常见网络命令可允许/询问/阻止；待强沙盒实现进程级网络隔离与完整审计 |

## 实施顺序

1. ✅ Local / Worktree 新任务环境选择 + Code Review 工作流。
2. ✅ Browser、Side Chat、结构化 Plan/TODO，清除所有占位入口。
3. ✅ 长期目标与后台续跑。
4. ✅ Scheduled Tasks、pi Packages 与内嵌文件产物；统一 MCP 待 pi registry 协议。
5. ✅ Extension tool policy 基础；继续强沙盒，最后接 Cloud runner。

官方基线：

- <https://learn.chatgpt.com/docs/projects>
- <https://learn.chatgpt.com/docs/environments/modes>
- <https://learn.chatgpt.com/docs/code-review>
- <https://learn.chatgpt.com/docs/integrated-terminal>
- <https://learn.chatgpt.com/docs/features>
- <https://learn.chatgpt.com/docs/customization/overview#agents-guidance>
- <https://learn.chatgpt.com/docs/agent-configuration/agents-md#how-codex-discovers-guidance>
- <https://learn.chatgpt.com/docs/environments/local-environment#use-built-in-git-tools>
- <https://learn.chatgpt.com/docs/environments/git-worktrees>
