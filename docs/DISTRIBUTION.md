# 分发与内置 pi

Mox 走 Developer ID 直分发。macOS Release 必须包含内置 pi runtime；Debug 在没有
runtime 时允许回退到外部安装，便于开发 pi 本身。

## 为什么默认是 Node bundle

pi 同时支持 Bun 单体编译和 Node runtime。2026-07-12 在 arm64 实测：Bun 单体约 79MB，
但连续 `--version` 冷启动约 11 秒；精简 Node runtime 约 266MB，启动约 1 秒，并完成真实
RPC、extension、auto compact 和 v3 session 恢复冒烟。因此默认选择体验更好的 Node bundle。
`MOX_PI_RUNTIME_KIND=bun` 仍可生成单体产物用于后续复测。

## 准备 runtime

```bash
NODE_EXECUTABLE=/path/to/node \
  Scripts/prepare-pi-runtime.sh /path/to/pi
```

脚本会：

1. 把 pi 源码和已安装依赖复制到临时目录，不修改 pi 仓库；
2. 编译仓库中已锁定的 generated model catalog，不访问在线模型目录；
3. 按实际 package dependency graph 离线裁剪 dev/unrelated packages；
4. 写入源码 revision 与逐文件 SHA-256 manifest；
5. 生成 `Vendor/PiRuntime/` 和 `Vendor/PiRuntime.zip`（均不提交 Git）。

默认只保留当前机器架构。准备 Universal Release 时，使用 universal Node 并设置：

```bash
MOX_PI_ARCHS="arm64 x86_64" Scripts/prepare-pi-runtime.sh /path/to/pi
```

嵌入阶段会验证 archive manifest，并要求 helper 覆盖 Xcode 当前全部 `ARCHS`。

## Xcode 嵌入与签名

`Embed Bundled Pi` phase 把 archive 解到：

```text
Mox.app/Contents/Helpers/
  pi-node # 唯一的主 runtime Mach-O
Mox.app/Contents/Resources/pi-runtime/
  packages/
  node_modules/
```

Xcode 使用 `EXPANDED_CODE_SIGN_IDENTITY` 给 `pi-node` 加 hardened-runtime 签名，再签外层
App。Node/V8 只获得 `allow-jit` 与 `allow-unsigned-executable-memory` 两项运行时例外；原生
`.node` modules 分别同 Team 签名，不关闭 library validation。
Release 设置 `MOX_REQUIRE_BUNDLED_PI=YES`，缺 archive 时构建硬失败；Debug 为 `NO`。

动态解包树无法用 Xcode User Script Sandbox 的静态 file list 完整表达，因此 App target
关闭的是**构建期脚本沙盒**；嵌入脚本本身受版本控制、无网络、声明了 archive 输入和 bundle
输出。这与尚待开启的 macOS **App Sandbox** 是两件不同的事。

发布前检查：

```bash
codesign --verify --deep --strict --verbose=2 /path/to/Mox.app
HELPER=/path/to/Mox.app/Contents/Helpers/pi-node
ENTRY=/path/to/Mox.app/Contents/Resources/pi-runtime/packages/coding-agent/dist/cli.js
"$HELPER" "$ENTRY" --version
PI_EXECUTABLE="$HELPER" PI_ENTRYPOINT="$ENTRY" \
  node Scripts/verify-pi-rpc.mjs
```

2026-07-12 已用 Apple Development 完成同 Team/hardened-runtime 布局、两项 Node JIT
entitlement、native module 签名、`codesign --deep --strict` 和 bundle 内 RPC 验收。正式
Developer ID Application 签名、DMG、公证与 staple 仍是独立发布门禁。
