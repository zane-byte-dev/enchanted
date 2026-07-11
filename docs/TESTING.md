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

`EnchantedTests/CoreWorkflowTests.swift` 当前覆盖版本诊断、Plan 持久化、任务产物识别和
Scheduled Task 运行记录。新增核心状态结构时，应优先补充无 UI 的序列化与策略测试。

## 告警策略

- `Scripts/check-warnings.sh` 不维护可增长的白名单；当前基线是 **0 warning**。
- 工程使用 Swift 5 的 `minimal` 并发检查。Xcode 26.5 的 SwiftData 宏在
  `complete` 下会对 `#Predicate` / `KeyPath` 产生大量 SDK 误报；业务层的 UI Store、
  AppKit 回调、pi RPC continuation 和 SwiftData → MainActor 传递边界仍显式标注隔离。
- 升级到 Swift 6 前，应重新开启 `complete`，并优先确认新版 SwiftData 宏是否已修复
  上述诊断，再处理真实迁移问题。

## macOS UI 冒烟

每次涉及启动、导航或 Store 初始化时，至少检查：

1. 冷启动后无需进入设置，模型选择器即可显示配置的 pi 模型。
2. 旧 SwiftData 项目和对话可正常载入。
3. Settings / Scheduled Tasks / Extensions 可打开并返回聊天。
4. 右侧工具栏、Browser、Side Chat 可打开，且不会改动主会话。
5. 未主动发送消息、安装扩展或创建任务时，冒烟检查不产生业务数据。

2026-07-11 已用外部 pi `0.80.6+` 完成以上只读冒烟；首次检查发现的模型启动竞态已通过
顺序执行安装诊断与模型发现、失败后单次短暂重试修复。
