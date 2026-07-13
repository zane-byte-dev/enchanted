# TESTING — 验证指南

> 目标：用一组可重复的检查覆盖 pi RPC、核心数据结构、工程构建和 macOS 交互冒烟。

## 自动化验证

```bash
# pi JSONL RPC：初始化、模型列表、会话状态
node Scripts/verify-pi-rpc.mjs

# macOS 单元测试
xcodebuild -quiet -project Enchanted.xcodeproj -scheme Enchanted \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test

# Debug 构建
xcodebuild -quiet -project Enchanted.xcodeproj -scheme Enchanted \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

# 干净构建并把任何新增 warning 当作失败
Scripts/check-warnings.sh
```

`EnchantedTests/CoreWorkflowTests.swift` 当前覆盖版本诊断、Plan 持久化、任务产物识别、
Scheduled Task 运行记录、增量 Markdown/公式解析，以及 pi assistant 错误/取消事件的区分。新增核心状态结构时，
应优先补充无 UI 的序列化与策略测试。

## 告警策略

- `Scripts/check-warnings.sh` 不维护可增长的白名单；当前基线是 **0 warning**。
- 工程使用 Swift 5 的 `minimal` 并发检查。Xcode 26.5 的 SwiftData 宏在
  `complete` 下会对 `#Predicate` / `KeyPath` 产生大量 SDK 误报；业务层的 UI Store、
  AppKit 回调、pi RPC continuation 和 SwiftData → MainActor 传递边界仍显式标注隔离。
- 升级到 Swift 6 前，应重新开启 `complete`，并优先确认新版 SwiftData 宏是否已修复
  上述诊断，再处理真实迁移问题。

## macOS UI 冒烟

每次涉及启动、导航或 Store 初始化时，至少检查：

1. 冷启动后无需进入设置，Composer 的模型设置入口即可显示配置的 pi 模型与当前推理强度，两个子菜单均可切换。
2. 旧 SwiftData 项目和对话可正常载入。
3. Settings / Scheduled Tasks / Extensions 可打开并返回聊天。
4. 左侧导航向下滚动时仅“新建对话”保持固定；搜索、技能、项目与归档一起滚动，底部账户入口保持固定。
5. 项目标题栏悬停时显示 `+`，并与项目行尾部悬停操作、已归档展开箭头共用视觉中心线；项目行悬停时显示背景、填充文件夹和项目级 `+ / …`，无常驻箭头。点击整行仍可折叠/展开且辅助功能状态正确。标题 `+` 可打开“新建空白项目 / 使用现有文件夹”菜单，取消面板后不产生项目或目录。
6. 将 Settings 窗口缩到最小宽度，Pi 页标题状态、路径选择、连接测试、Provider、推理与安全控件应自动换为纵向布局，不出现横向裁切。
7. 右侧工具栏、Files、Browser、Side Chat 可打开，Files 可展开目录、切换隐藏文件并预览文件，且不会改动主会话。
8. 输入 `/` 可看到核心命令；模型/推理进入二级列表，状态卡可关闭和刷新，压缩/任务 fork 不会在仅浏览命令时误触发。
9. 未主动发送消息、安装扩展或创建任务时，冒烟检查不产生业务数据。

2026-07-11 已用外部 pi `0.80.6+` 完成以上只读冒烟；首次检查发现的模型启动竞态已通过
顺序执行安装诊断与模型发现、失败后单次短暂重试修复。

2026-07-12 用 Computer Use 对 `Mox.app` 完成冷启动、主界面、设置返回与历史长会话
切换冒烟：系统菜单/窗口/侧栏品牌均为 Mox，pi 模型加载正常；包含大量历史工具块的
会话首次显示约 1.68 秒、热缓存回切约 1.06 秒（均包含自动化状态采集），未出现白屏。

同日用真实模型完成增量渲染冒烟：8 个 Markdown 段落加 30 行 Swift fenced code
block 在生成中逐段稳定显示，完成后代码高亮正确；长回复连续滚动 3 页约 0.56 秒
（包含 Computer Use 状态采集）。纯函数测试同时覆盖稳定前缀复用与围栏内空行不切分。

SwiftMath 公式冒烟覆盖行内欧拉恒等式和块级积分/分式：指数、π、积分上下限与分式均
正确渲染，短块公式居中；解析测试覆盖转义货币、inline/fenced code、未闭合表达式回退。

Mermaid 测试覆盖完整/未闭合/错误语言围栏的保守分流，并由宿主测试实际加载 app bundle
内的 Mermaid 11.15.0，在无网络参与的隐藏 WebKit 中生成 SVG，再由 `NSImage` 成功解码。

Agent 指引测试在临时目录构造全局、祖先与 cwd 多层文件，验证与 pi 相同的候选优先级、
根到 cwd 合并顺序、scope 标记和字节统计。Diff 评审测试覆盖 unified diff 新旧行号推进、
删除/新增定位、未跟踪文件行号及发送 prompt 的精确文件位置；另在临时 Git 仓库真实提交
基线并验证单 hunk Stage、Unstage 与 Revert。Git 发布测试再创建本地 bare remote，真实覆盖
staged 检测、两次 Commit、首次 upstream、ahead 计数和两次 Push，并检查 PR 参数与 GUI
环境 `gh` 路径探测。Worktree 测试真实覆盖 detached 创建、staged/unstaged/untracked 与
`.worktreeinclude` 文件复制，以及 Local ↔ Worktree 双向迁移；另覆盖脏目标非冲突合并、双方
index/working tree 分层保真，以及重叠修改时目标精确恢复、源端保持不变。当前 macOS
`CoreWorkflowTests` 共 34 项。项目列表测试覆盖默认 5 条、隐藏计数与展开全部，并验证视图、排序及手动顺序持久化；状态统计测试覆盖 token、费用与上下文窗口字段解析；文件系统测试覆盖目录优先排序、隐藏文件过滤、路径越界拒绝及
二进制/超大文件预览回退。历史权威测试另验证只有完全一致的 pi/local user-turn 链允许
Queue/Goal 自动续跑，drift、unknown 与 unavailable 均 fail closed。
内置 runtime 测试验证 `Contents/Helpers/pi-node` 只有具备执行权限才会被自动选择，并自动
拼接 Resources 中的 coding-agent entrypoint；
分发冒烟还需对真实 archive 完成 App bundle 嵌入、版本和 `verify-pi-rpc.mjs` 检查。
