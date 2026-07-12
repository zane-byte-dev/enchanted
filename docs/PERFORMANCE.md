# PERFORMANCE — 流式渲染性能

> 这是本项目最大的技术风险。原生 SwiftUI 渲染大段流式 markdown + SwiftData
> 持久化，天然容易抖动 / 白屏 / 重复渲染。改聊天渲染或 Store 前先读这里。

## 症状与成因

| 症状 | 出现场景 | 根因（推断） |
|------|---------|------------|
| 消息框抖动 | AI 流式返回时 | 每个 delta 触发布局重算；markdown 重新解析 |
| 长白屏 | 切换会话 / 任务进行中切出再切回 | 大 `blocksJSON` 反序列化 + 全量 relayout |
| 重复渲染 | 导入 pi 历史会话 | 同一条消息被多次 append/渲染 |
| 滚动卡 | 长会话 | 消息列表未充分复用/虚拟化 |

## 已有对策（别改回去）

1. **Throttler(0.1s)**：`AgentRun` 用节流批量刷 UI，而非每个 token 刷一次。
2. **只读工具结果丢弃**：`AgentRun.endTool` 对 read/grep/glob 等只读工具
   `resultText = nil`，不落库不渲染 —— 这些结果可达 MB 级，是白屏主因之一。
3. **分块渲染模型**：`MessageBlock`（text / thinking / tool）有序累加，尾部
   text block 就地拼接，减少块数量。
4. **每会话独立 `AgentRun`**：支持多会话并行且互不阻塞。
5. **渲染块写穿缓存**：流式 flush 在持久化 `blocksJSON` 时同步写入 typed blocks
   缓存，SwiftUI 不再每 0.1 秒把刚编码的 JSON 重新解码；历史消息仍按需懒解码。
6. **pi 历史幂等重建**：按稳定 entry id 覆盖重复 JSONL 行，只遍历 active parent
   branch 一次，并把连续 assistant/tool 片段合并为一个可见回复。
7. **会话切换分页与热缓存**：数据库只取最新 60 条，视图只挂载尾部 30 条；最近
   8 个 transcript 直接回显并后台刷新。2026-07-12 用历史长工具会话实测回切约
   1.06 秒（包含 UI 自动化状态采集），完整 transcript 可见且无白屏。
8. **增量 Markdown 前缀**：流式回复只把围栏外已完成段落交给 MarkdownUI 并缓存，
   当前尾段用轻量 `Text` 更新；代码围栏关闭前不会切分。完成后再统一渲染最终
   Markdown 与语法高亮，避免每 0.1 秒重解析整条回复。
9. **有界长会话渲染**：默认只挂载尾部 30 条消息，早期记录按 30 条显式加载；
   真实 8 段 Markdown + 30 行代码回复滚动 3 页约 0.56 秒（含自动化状态采集）。
10. **Instruments 标记**：`ConversationSwitch`、消息页 fetch、`MarkdownParse`、
    `FormulaParse` 与 `SyntaxHighlight` 都有 `os_signpost` interval，可直接定位缓存
    miss 和主线程耗时。
11. **Mermaid 延迟渲染**：流式围栏关闭并进入稳定 Markdown 前缀后才启动隐藏 WebKit；
    进程内只保留一个 renderer，任务串行，SVG 按源码和深浅色放入有界缓存，视图树不挂 WebView。

## 待做

- [x] markdown 增量渲染：稳定段落前缀缓存，只有 live tail 每 tick 更新。
- [x] 会话切换分页 + 尾部渲染窗口 + 最近会话热缓存，避免同步全量挂载。
- [x] pi 历史导入去重（稳定 id + active branch 重建，含重复行回归测试）。
- [x] 消息列表有界复用：尾部 30 条窗口 + 30 条分页，不默认挂载完整 transcript。
- [x] 用 `os_signpost` 量化会话切换、分页 fetch、Markdown/公式解析和语法高亮。

## 曾讨论但未采纳

- **改成 WebView 渲染整段对话**（copilot session `bf786f55`）：能一次性拿到成熟 web
  渲染栈，但会丢原生质感、引入桥接复杂度，与"原生 GUI"定位冲突。**暂缓**，
  先把原生路径的增量渲染做到位再评估。Mermaid 仅把隐藏 WebKit 当离线 SVG 编译器，
  最终仍由 SwiftUI 原生图片视图展示，不改变该决策。

## 相关文件

- `Stores/ConversationStore.swift`（`AgentRun`、`handleEvent`、Throttler）
- `Agent/MessageBlock.swift`（渲染块模型）
- `Services/MermaidRenderer.swift`（进程级离线 SVG renderer 与缓存）
- `UI/Shared/Chat/Components/ChatMessages/`（消息视图）
- `docs/large_text_input_design.md`（大段文本输入防卡顿）
