# Mox

Mox 是一款原生 macOS coding agent 客户端：在项目目录中驱动 `pi --mode rpc`，
把对话、推理、工具调用、终端、Git Changes、Browser 和任务历史放进同一个工作区。
交互体验以 Codex Mac App 为基线，同时保留原生 SwiftUI 的性能和系统集成。

> 当前仓库是 `gluonfield/enchanted` 的 fork。第一阶段只更改用户可见品牌；Xcode
> 工程名、Target、Swift module、Bundle Identifier、源码目录与 URL scheme 继续保留
> `Enchanted`，以避免不必要的迁移风险。

## 核心能力

- 本地项目、多任务与 Git Worktree 环境
- pi 流式回答、thinking、工具卡、Stop / Steer / Follow-up Queue
- Integrated Terminal、可写行内意见的 Changes / Diff 与独立 Code Review
- 图片、文件和文件夹上下文，工具产物 Quick Look
- Markdown、代码高亮、原生公式以及离线 Mermaid 图表渲染
- Browser、Side Chat、Plan / TODO 与长期目标续跑
- Skills、pi Packages、项目 Agent 指引、审批与网络策略
- Scheduled Tasks、完成通知、搜索、分支、Retry 与导出
- 本地 SwiftData 历史与 pi session 恢复、漂移探测和修复

完整对齐状态见 [`docs/CODEX_PARITY.md`](docs/CODEX_PARITY.md)，实施计划见
[`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 开发

要求：macOS、Xcode，以及 pi `0.80.6` 或更新版本。

```bash
# 验证 pi JSONL RPC
node Scripts/verify-pi-rpc.mjs

# macOS 单元测试
xcodebuild -quiet -project Enchanted.xcodeproj -scheme Enchanted \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test

# 干净构建并要求 0 warning
Scripts/check-warnings.sh
```

可通过环境变量覆盖 pi 路径和默认工作目录：

```bash
PI_EXECUTABLE=~/.local/bin/pi PI_CWD=/path/to/project open Mox.app
```

架构、测试和分发决策集中在 [`docs/`](docs/README.md)。

## 分发

目标分发方式是 Developer ID 直分发（DMG + 公证），不上 App Store。Release 已内置
精简 Node + pi runtime，外部 pi 继续作为开发和 fallback 模式；macOS Sandbox 与
security-scoped bookmark 是下一阶段。

## 来源与许可

Mox 基于开源项目 Enchanted 演进，继续遵循仓库中的 [`LICENSE`](LICENSE)。应用内置
Mermaid 11.15.0 用于离线图表渲染，其 MIT 许可随资源保存在
[`MERMAID-LICENSE.txt`](Enchanted/Resources/Mermaid/MERMAID-LICENSE.txt)。
