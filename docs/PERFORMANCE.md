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

## 待做

- [ ] markdown 增量渲染：只重渲染尾部变化块，不整条重解析。
- [ ] 会话切换懒加载 + 骨架屏，避免大 `blocksJSON` 同步反序列化阻塞主线程。
- [ ] pi 历史导入去重（幂等 append）。
- [ ] 消息列表虚拟化 / 更激进的视图复用。
- [ ] 用 `os_signpost`（已有 `ConversationPerformance.signposter`）在 Instruments
      里量化，别凭感觉优化。

## 曾讨论但未采纳

- **改成 WebView 渲染对话**（copilot session `bf786f55`）：能一次性拿到成熟 web
  渲染栈，但会丢原生质感、引入桥接复杂度，与"原生 GUI"定位冲突。**暂缓**，
  先把原生路径的增量渲染做到位再评估。

## 相关文件

- `Stores/ConversationStore.swift`（`AgentRun`、`handleEvent`、Throttler）
- `Agent/MessageBlock.swift`（渲染块模型）
- `UI/Shared/Chat/Components/ChatMessages/`（消息视图）
- `docs/large_text_input_design.md`（大段文本输入防卡顿）
