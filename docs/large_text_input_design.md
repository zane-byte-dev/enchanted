# 交互方案设计：防卡顿的大段文本输入 (Codex Style)

当用户在聊天框中粘贴大段内容（如几千行代码或完整文档）时，传统的文本渲染方式会导致严重卡顿甚至应用无响应，同时也会挤占整个屏幕视野。

本方案参考了 Codex / Pi 等前沿 AI 工具的交互模式，提供了一套从**事件拦截**到**UI 展现**的完整思路。

---

## 1. 核心交互流程

1. **触发与拦截**
   - 用户在输入框执行 `Cmd+V` 粘贴。
   - 系统静默计算剪贴板内的文本长度与行数。
   - **分流逻辑**：
     - 如果字数 < 500 字 且 行数 < 10 行：执行原生粘贴，文本直接进入输入框。
     - 如果超过阈值：**取消原生粘贴行为**，将文本保存到内存（状态变量），并在输入框上方生成一个“附件卡片 (Chip)”。
2. **视觉呈现 (Context Chip)**
   - 输入框内依然保持清爽（或保留用户原有的简短提示词）。
   - 输入框上方横向排列显示“卡片”。
   - **卡片设计规范**（参考截图）：
     - **左侧**：文档/扫描小图标（带浅色圆角矩形底色）。
     - **右侧**：分两行显示。第一行为截取的前十几个字符预览（如 `# 方案: 在 pi 侧用...`）；第二行为引导文案（如 `在文本框中显示 >`）。
     - **右上角**：一个悬浮的暗色小圆圈包裹着白色的 `x`，用于随时删除该附件。
     - **固定尺寸**：卡片应具备固定宽度（如 `180px`）和高度，防止多张卡片时排版错乱。
3. **内容提交 (Submit)**
   - 当用户按下回车发送时，程序在后台自动将所有卡片内缓存的长文本与输入框内的短指令通过特定的分隔符（如 `\n\n`）进行拼接。
   - 拼装后的完整 Prompt 一次性发给 LLM 后端。

---

## 2. 前端架构实现方案 (针对 macOS/SwiftUI 栈)

纯 SwiftUI 的 `TextField` 无法在文本渲染前完美阻断粘贴（`.onChange` 触发时由于长文本已经进入渲染管线，依然会卡死）。因此必须在更底层拦截。

### A. 状态管理模型
```swift
struct TextAttachment: Identifiable {
    let id = UUID()
    let rawContent: String
    
    var previewTitle: String {
        // 截取第一行或前20个字符作为标题
    }
}

// 在外层视图中维护
@State var attachments: [TextAttachment] = []
```

### B. 拦截层的封装 (NSViewRepresentable)
使用原生的 `NSTextView` 进行桥接封装：
1. 创建一个继承自 `NSTextView` 的子类。
2. 重写 `paste(_ sender: Any?)` 方法。
3. 在方法内读取 `NSPasteboard.general.string(forType: .string)`。
4. 判断阈值。如果超长，则通过闭包 `onLargePaste(String)` 将内容抛给上层 SwiftUI，**并不调用 `super.paste`**；如果不超长，则调用 `super.paste` 放行。

### C. 视图层级结构
```swift
VStack(alignment: .leading) {
    // 1. 附件卡片展示区 (横向滚动)
    if !attachments.isEmpty {
        ScrollView(.horizontal) {
            HStack {
                ForEach(attachments) { item in 
                    AttachmentChipView(item: item)
                }
            }
        }
    }
    
    // 2. 文本输入区
    // 使用 ZStack 搭配一个透明的 Text 来撑开高度，
    // 确保内部的 NSTextView 不会无限拉伸导致布局崩塌。
    ZStack {
        Text("Hidden Text for Sizing")
             .opacity(0)
             .lineLimit(1...12) // 控制最大高度
             
        CustomPasteTextView(text: $message, onLargePaste: { ... })
    }
}
```

---

## 3. 体验优化的细节建议

> [!TIP]
> 1. **动画过渡**：当长文本转化为卡片时，使用 `.animation(.spring())` 让卡片平滑地从左侧滑入，能大幅减轻用户对“我刚才粘贴的内容去哪了”的疑惑。
> 2. **查看详情**：由于卡片只显示预览，建议支持点击卡片弹出一个 `Popover` 或大弹窗，允许用户浏览甚至二次编辑这段长文本。
> 3. **焦点保持**：粘贴产生卡片后，输入框的焦点不应丢失，光标应继续在输入框内闪烁，以便用户可以无缝继续输入简短的指令。
