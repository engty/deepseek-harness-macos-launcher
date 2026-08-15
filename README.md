# DeepSeek Harness

这是一个把 DeepSeek Harness `dsh --profile web` 包装成 macOS 专用 App 窗口的 SwiftPM Launcher。App 不重写 Harness UI；Electron/浏览器不是本项目的运行时，当前实现使用 macOS `WKWebView` 承载同一 loopback Web UI，并由 Swift App 监督 `dsh` sidecar。

本项目是非官方的独立启动器，不代表 DeepSeek、OpenAI、Codex、ChatGPT 或任何第三方插件作者。当前只支持 macOS；由于外壳使用 SwiftUI/AppKit 和 WKWebView，项目不会发布伪造的 Windows 版本。

## 下载

带 `v*` 标签的提交会由 GitHub Actions 在 macOS 14 runner 上构建 Apple Silicon (`arm64`) App，并自动创建 GitHub Release。Release 中包含：

- `DeepSeek-Harness-macos-arm64.zip`
- `SHA256SUMS.txt`

下载后解压并把 `DeepSeek Harness.app` 移到 Applications。当前产物使用 ad-hoc 签名，不包含 Developer ID、Apple notarization 或 Mac App Store 分发；首次运行可能需要在 macOS 的隐私与安全性设置中允许打开。

源码仓库不提交 `Resources/runtime/`、`dist/`、用户 profile 或任何凭证。Release 构建会临时安装固定版本的 Node.js 与 `@deepseek-ai/dsh`，再把 Runtime Bundle 放进 App。

## Development

要求：macOS 13+、Xcode/Swift 6、一个已经构建好的 Harness Runtime。

```sh
HARNESS_DSH_PATH=/absolute/path/to/dsh ./script/build_and_run.sh
```

如果 `dsh` 已在 `PATH` 中，也可以直接运行：

```sh
./script/build_and_run.sh
```

可用已验证的 Harness 依赖树生成本地 Runtime Bundle：

```sh
HARNESS_RUNTIME_SOURCE=/absolute/path/to/runtime \
HARNESS_NODE_PATH=/absolute/path/to/node \
./script/package_runtime.sh
```

高级自动化可以使用 App Bundle 内的 helper CLI，它只转发官方插件命令，不发明新的插件格式：

```sh
dist/HarnessLauncher.app/Contents/Resources/bin/deepseek-harness-plugin add dsh-llm-codex
dist/HarnessLauncher.app/Contents/Resources/bin/deepseek-harness-plugin remove dsh-llm-codex
```

开发构建的 Runtime 预期布局见 [`Resources/README.md`](Resources/README.md)。App 会把 Harness 数据隔离到：

```text
~/Library/Application Support/com.harness.desktop.launcher/
```

## Verification

```sh
swift build
swift test
./script/build_and_run.sh --verify
# Release-style local bundle checks (also require the embedded Runtime):
REQUIRE_BUNDLED_RUNTIME=1 ./script/validate_app_bundle.sh dist/HarnessLauncher.app
# Controlled-channel release checks (ad-hoc bundle integrity only):
./script/validate_release.sh dist/HarnessLauncher.app
```

GitHub Actions 的 macOS 发布构建使用同一套验证脚本：`swift test`、固定 Runtime 组装、Bundle 校验、App 压缩和 SHA-256 清单。发布触发条件为推送 `v*` 标签，手动构建可以在 Actions 页面执行 `workflow_dispatch`。

本地和受控渠道构建使用 ad-hoc 签名；本项目不实现 Developer ID、Apple notarization 或 staple。

`--logs` 和 `--telemetry` 可用于查看 macOS unified logs。退出 App 会先通过 `SIGTERM` 优雅停止 Harness sidecar。
sidecar PID 仅写入 App 私有 state；若 App 被强制终止，下一次启动会校验可执行文件路径后清理陈旧 sidecar，避免误杀其他 Node/dsh 进程。

Plugins 菜单使用官方 `dsh plugin --profile web ...` 语义。安装时可以直接粘贴 `dsh plugin --profile web add <plugin-spec>` 命令，Launcher 只解析参数，不经过 shell。卸载和停用会列出实际插件并支持多选/全选；卸载调用官方 `remove`，停用通过官方支持的 `--patch` overlay 将 bundle row 标记为 `disabled: true`，不删除插件源码。产品承诺范围是插件安装、卸载和停止；插件本身的 Provider 兼容性由 Harness/插件上游负责。

顶栏绿色/红色圆点分别表示 Harness 已运行/未运行，旁边显示当前 `@deepseek-ai/dsh` 版本。检测到受控 HTTPS Runtime manifest 更新后会显示圆形下载按钮；artifact 通过 SHA-256、大小、架构、归档安全和候选启动检查。余额按钮首次使用时将 DeepSeek API Key 保存到 macOS Keychain，并调用官方余额接口；配置后立即查询，之后每 60 秒自动刷新。为避免 ad-hoc App 在启动阶段触发 Keychain 授权弹窗，Launcher 不在启动时主动读取旧 Keychain 条目，余额配置通过用户主动操作建立当前会话。

Runtime artifact 现已支持 HTTPS feed、SHA-256、`minShellVersion`、tar archive 安全检查、base `--version`/`--dump-config` 预检、实际用户 data slot 候选启动、候选 Runtime 激活和失败回滚。Runtime feed 不使用公钥签名，适合受控分发，不提供供应链签名安全保证。插件安装/删除也会在完整 data slot 副本中执行官方命令，成功后原子切换，失败时保留旧 slot。

插件变更前会显示 spec 和 lifecycle/build script 风险确认；sidecar 输出、错误和诊断文件统一脱敏。Harness WebView 只允许当前 loopback origin，只有用户主动点击的 HTTPS 外链才会交给系统浏览器。
插件事务还会把解析版本、来源、license 和 lifecycle script 标志写入当前 data slot 的 `dsh-home/launcher/plugin-metadata.json`，仅供用户查看来源风险，不会复制插件源码到 App Shell。

Runtime 更新只信任配置的 HTTPS feed；发布方需要自行维护 feed、artifact SHA-256 和 Runtime Bundle。Developer ID 与 notarization 不在本项目范围内。

`compatibility-matrix.json` 只记录 Shell、Harness、Node 和 Launcher 已验证的插件操作组合，不承诺全量第三方插件兼容；Provider canary 和插件许可证审核由上游/插件发布方负责。

`script/validate_app_bundle.sh` 和 `script/validate_release.sh` 是受控渠道发布前的只读自检：校验 App 元数据、图标、ad-hoc Bundle 完整性和内置 Runtime 的 `dsh`/Node 入口。

## 来源与引用

本项目只实现 macOS 启动器、插件管理和进程维护；Harness 的聊天 UI、会话、模型、工具和插件协议来自以下上游项目：

1. [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — 官方 `dsh` Runtime 与 Web UI。本项目按上游 MIT License 使用其公开的 `dsh --profile web` 运行方式；具体 Runtime 版本由 GitHub Actions 中的 `HARNESS_VERSION` 固定。上游项目仍是 Harness 源码、第三方依赖清单和协议的权威来源。
2. [dsh-llm-codex](https://github.com/yequ172672/dsh-codex-subscription) — 可选的标准 Harness 插件，通过 `dsh plugin --profile web add dsh-llm-codex` 安装。本仓库不复制、不默认捆绑该插件源码，也不维护其 ChatGPT/Codex Provider 协议；许可证、订阅条款、凭证读取和模型可用性以插件上游为准。
3. [DeepSeek Balance API](https://api-docs.deepseek.com/api/get-user-balance) — 顶栏余额查询仅使用用户主动配置的 API Key，并保存到 macOS Keychain，不写入仓库、WebView、日志或诊断包。
4. [Swift](https://www.swift.org/)、[SwiftUI/AppKit](https://developer.apple.com/documentation/) 和 [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) — macOS 原生窗口、菜单和 Web UI 容器。

第三方声明和发布边界见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)；本项目自身代码使用 [`LICENSE`](LICENSE) 中的 MIT License。任何 Runtime Release 都应同时遵循上游 Runtime、Node.js 和 npm 依赖的许可证要求。

## Windows 支持

当前没有 Windows 外壳。SwiftUI/AppKit、macOS Keychain、WKWebView 和 AppKit 菜单是本实现的核心依赖，因此 GitHub Actions 只构建 macOS arm64。未来如需 Windows，需要另行实现 WinUI/WebView2 或 Electron 外壳，并重新验证 Harness 的进程、插件和凭证边界；在此之前不会发布 Windows 下载链接。
