# DeepSeek Harness

这是一个把 DeepSeek Harness `dsh --profile web` 包装成 macOS 专用 App 窗口的 SwiftPM Launcher。App 不重写 Harness UI；Electron/浏览器不是本项目的运行时，当前实现使用 macOS `WKWebView` 承载同一 loopback Web UI，并由 Swift App 监督 `dsh` sidecar。

本项目是非官方的独立启动器，不代表 DeepSeek、OpenAI、Codex、ChatGPT 或任何第三方插件作者。当前只支持 macOS；由于外壳使用 SwiftUI/AppKit 和 WKWebView，项目不会发布伪造的 Windows 版本。

## 下载

带 `v*` 标签的提交会由 GitHub Actions 在 macOS 14 runner 上构建 Apple Silicon (`arm64`) App，并自动创建 GitHub Release。Release 中包含：

- `DeepSeek-Harness-macos-arm64.dmg`
- `SHA256SUMS.txt`

GitHub Release 只提供 DMG，避免为同一个 App 保存两份近乎相同的发行包。打开 DMG 后，直接把窗口中的 `DeepSeek Harness.app` 拖到旁边的 `Applications` 快捷方式即可完成安装。公共 GitHub runner 默认使用 ad-hoc 签名，不包含 Developer ID 或 Apple notarization；DMG 只是分发封装格式，未 notarize 的网络下载 App 首次运行仍可能需要在 macOS 的隐私与安全性设置中允许打开。

源码仓库不提交 `Resources/runtime/`、`dist/`、用户 profile 或任何凭证。Release 构建会临时安装固定版本的 Node.js、`@deepseek-ai/dsh` 与 `pnpm`，再把 Runtime Bundle 放进 App。插件命令使用 App 私有 PATH，不会修改用户的 Shell 配置、Homebrew 或全局 npm/pnpm。若 pnpm 10 阻止插件的 prepare/build script，App 会在确认后只为精确包名写入 staging profile 的 `allowBuilds`。

## API Key 与隐私说明

为了让余额查询和 Harness Web Models 使用同一个 DeepSeek API Key，App 会在用户主动配置或更换 Key 后保存两份本地凭据：

1. 一份保存到 macOS Keychain（Generic Password，当前版本的服务标识为 `com.harness.desktop.launcher.credentials.v2`，账户标识为 `DEEPSEEK_API_KEY`）。
2. 一份写入 Harness 要求的 `$DSH_HOME/.credentials.yaml`，位置在 `~/Library/Application Support/com.harness.desktop.launcher/` 下；文件权限为 `0600`，仅当前 macOS 用户可读写。

这样做是因为 Harness 的官方本地凭据提供方需要读取 `.credentials.yaml`，而 App 自己还需要在不启动 Web UI 的情况下查询余额。Key 只在本机用于启动 Harness 和请求 DeepSeek 官方余额接口：

- 本项目不会把 Key 上传到我们的服务器，也没有遥测、广告或远程凭据同步服务。
- Key 不会写入 Git、GitHub Release、日志、诊断导出文件或 WebView 页面。
- 插件安装日志和错误输出会进行敏感信息脱敏；插件本身属于第三方代码，用户应先确认插件来源。
- App 启动时优先读取私有凭据文件，不会自动修改旧版本的 Keychain 条目，因此正常替换 App 不应反复弹出钥匙串授权窗口。
- 更换 API Key 时，新值会同时更新这两处；用户可以通过顶部余额区域或 DeepSeek 菜单中的“更换 DeepSeek API Key…”执行更换。

如果用户不再使用 DeepSeek，可以在 App 中更换为新 Key；删除本地 App 支持目录和对应的 Keychain 条目即可清除本地凭据。请不要把 `.credentials.yaml` 或 API Key 提交到公开仓库、截图或问题报告中。

### 首次运行显示“App 已损坏”

这通常是 macOS Gatekeeper 对未 notarize 的网络下载 App 的提示，不代表 DMG 内容真的损坏。请先从 Release 的 `SHA256SUMS.txt` 校验下载包，再使用 macOS 自带方式打开 DMG；不要让第三方工具改写 App Bundle。然后可以右键 App 选择“打开”，或在“系统设置 → 隐私与安全性”中选择“仍要打开”。

如果系统仍然阻止一个已核对 SHA-256、来源可信的 App，可以只对该 App 移除下载隔离属性：

```sh
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
open "/Applications/DeepSeek Harness.app"
```

这条命令只适用于你已确认来源和校验值的 App。若希望所有用户首次双击都不出现 Gatekeeper 提示，则必须使用 Developer ID Application 签名、Apple notarization 和 staple；当前 GitHub 公共 runner 默认不执行这套签名发布流程。

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

GitHub Actions 的 macOS 发布构建使用同一套验证脚本：macOS 14 runner 上的 `swift build`、固定 Runtime 组装、Bundle 校验、DMG 封装和 SHA-256 清单。源码测试使用 Swift Testing，当前本地 Swift 6 工具链可运行 `swift test`；macOS 14 公共 runner 的 Swift 5.10 不包含该测试模块，因此发布门禁使用 `swift build`，避免把工具链差异误判为产品编译失败。发布触发条件为推送 `v*` 标签，手动构建可以在 Actions 页面执行 `workflow_dispatch`。

本地开发默认使用 ad-hoc 签名；在已安装 Developer ID 私钥的签名机器上，可通过 `DEEPSEEK_HARNESS_SIGNING_MODE=developer-id` 生成带 Hardened Runtime 的正式签名包。GitHub runner 不保存证书私钥，因此不会默认执行 Developer ID 签名或 notarization；需要时应通过临时钥匙串和 GitHub encrypted secrets 配置独立的发布作业。

`--logs` 和 `--telemetry` 可用于查看 macOS unified logs。退出 App 会先通过 `SIGTERM` 优雅停止 Harness sidecar。
sidecar PID 仅写入 App 私有 state；若 App 被强制终止，下一次启动会校验可执行文件路径后清理陈旧 sidecar，避免误杀其他 Node/dsh 进程。

Plugins 菜单使用官方 `dsh plugin --profile web ...` 语义。安装时可以直接粘贴 `dsh plugin --profile web add <plugin-spec>` 命令，Launcher 只解析参数，不经过 shell。卸载和停用会列出实际插件并支持多选/全选；卸载调用官方 `remove`，停用通过官方支持的 `--patch` overlay 将 bundle row 标记为 `disabled: true`，不删除插件源码。产品承诺范围是插件安装、卸载和停止；插件本身的 Provider 兼容性由 Harness/插件上游负责。

顶栏绿色/红色圆点分别表示 Harness 已运行/未运行，旁边显示当前 `@deepseek-ai/dsh` 版本。检测到受控 HTTPS Runtime manifest 更新后会显示圆形下载按钮；这个按钮更新的是 App 内部的 DeepSeek Harness Runtime（Node、`@deepseek-ai/dsh` 和配套前端），不是外层 macOS App。Runtime artifact 通过 SHA-256、大小、架构、归档安全和候选启动检查。若没有配置 Runtime feed，不会影响 App 启动，只表示底层 Runtime 暂时没有可检查的更新源。

菜单中的 `Check DeepSeek Harness App Updates…` 检查的是外层 SwiftUI/AppKit macOS App，使用本项目的 GitHub Releases，并在发现新版本后打开下载页。它不会直接替换正在运行的 App；安装新的 DMG 后由 macOS 完成替换。两条更新通道彼此独立：App 更新不会自动修改用户插件 profile，Runtime 更新也不会替换外层 App。

余额按钮首次使用时会按上面的隐私说明保存 DeepSeek API Key，并调用官方余额接口；应用重新启动后会自动恢复这个绑定，之后每 60 秒自动刷新。只有用户主动点击余额区域或菜单中的“更换 DeepSeek API Key…”才会替换已保存的 Key。

Runtime artifact 现已支持 HTTPS feed、SHA-256、`minShellVersion`、tar archive 安全检查、base `--version`/`--dump-config` 预检、实际用户 data slot 候选启动、候选 Runtime 激活和失败回滚。Runtime feed 不使用公钥签名，适合受控分发，不提供供应链签名安全保证。插件安装/删除也会在完整 data slot 副本中执行官方命令，成功后原子切换，失败时保留旧 slot。

插件依赖还支持受控的 App 私有工具链恢复：当前只允许清单中的 jq 1.7.1，下载会校验 HTTPS、固定大小、SHA-256、可执行文件名和来源；未知依赖不会被自动执行或安装。对常用于公开仓库的 `github:owner/repo` shorthand，App 会在不经过 Shell 的前提下转换为 HTTPS Git URL，避免 Finder 启动时依赖交互式 SSH agent；显式 `git+ssh` 地址仍保持原语义。

插件变更前会显示 spec 和 lifecycle/build script 风险确认；sidecar 输出、错误和诊断文件统一脱敏。Harness WebView 只允许当前 loopback origin，只有用户主动点击的 HTTPS 外链才会交给系统浏览器。
插件事务还会把解析版本、来源、license 和 lifecycle script 标志写入当前 data slot 的 `dsh-home/launcher/plugin-metadata.json`，仅供用户查看来源风险，不会复制插件源码到 App Shell。

Runtime 更新只信任配置的 HTTPS feed；发布方需要自行维护 feed、artifact SHA-256 和 Runtime Bundle。Runtime 更新校验与外层 App 的 Developer ID/notarization 发布流程相互独立。

`compatibility-matrix.json` 只记录 Shell、Harness、Node 和 Launcher 已验证的插件操作组合，不承诺全量第三方插件兼容；Provider canary 和插件许可证审核由上游/插件发布方负责。

`script/validate_app_bundle.sh` 和 `script/validate_release.sh` 是发布前的只读自检：校验 App 元数据、图标、Bundle 完整性和内置 Runtime 的 `dsh`/Node/`pnpm` 入口。

## 来源与引用

本项目只实现 macOS 启动器、插件管理和进程维护；Harness 的聊天 UI、会话、模型、工具和插件协议来自以下上游项目：

1. [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — 官方 `dsh` Runtime 与 Web UI。本项目按上游 MIT License 使用其公开的 `dsh --profile web` 运行方式；具体 Runtime 版本由 GitHub Actions 中的 `HARNESS_VERSION` 固定。上游项目仍是 Harness 源码、第三方依赖清单和协议的权威来源。
2. [dsh-llm-codex](https://github.com/yequ172672/dsh-codex-subscription) — 可选的标准 Harness 插件，通过 `dsh plugin --profile web add dsh-llm-codex` 安装。本仓库不复制、不默认捆绑该插件源码，也不维护其 ChatGPT/Codex Provider 协议；许可证、订阅条款、凭证读取和模型可用性以插件上游为准。
3. [DeepSeek Balance API](https://api-docs.deepseek.com/api/get-user-balance) — 顶栏余额查询与 Harness Web Models 页面共用同一个 DeepSeek API Key：App 将其保存到 macOS Keychain，并同步到 Harness 标准 `$DSH_HOME/.credentials.yaml`，不写入仓库、WebView、日志或诊断包。
4. [Swift](https://www.swift.org/)、[SwiftUI/AppKit](https://developer.apple.com/documentation/) 和 [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) — macOS 原生窗口、菜单和 Web UI 容器。

第三方声明和发布边界见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)；本项目自身代码使用 [`LICENSE`](LICENSE) 中的 MIT License。任何 Runtime Release 都应同时遵循上游 Runtime、Node.js 和 npm 依赖的许可证要求。

## Windows 支持

当前没有 Windows 外壳。SwiftUI/AppKit、macOS Keychain、WKWebView 和 AppKit 菜单是本实现的核心依赖，因此 GitHub Actions 只构建 macOS arm64。未来如需 Windows，需要另行实现 WinUI/WebView2 或 Electron 外壳，并重新验证 Harness 的进程、插件和凭证边界；在此之前不会发布 Windows 下载链接。
