# DeepSeek Harness for macOS

<p align="center">
  <img src="Resources/AppIcon.png" alt="DeepSeek Harness for macOS" width="128" />
</p>

<p align="center">
  <strong>把 DeepSeek Harness 带到 macOS 桌面。</strong><br />
  一个开源、原生、开箱即用的桌面启动器。
</p>

<p align="center">
  <a href="https://github.com/engty/deepseek-harness-macos-launcher/releases">下载 Releases</a>
  ·
  <a href="https://github.com/deepseek-ai/deepseek-harness">查看官方 Harness</a>
</p>

![DeepSeek Harness macOS 界面预览](Resources/DeepSeekHarness-ui.png)

## 为什么使用

- **双击即用**：Node.js、pnpm 与 Harness Runtime 由 App 管理，不必手动配置终端环境。
- **原生桌面体验**：官方 Web UI 运行在本机，并放进 macOS 原生窗口；菜单栏可管理密钥、插件和 Runtime。
- **插件生态保持兼容**：继续使用官方插件命令，支持插件安装、停用、卸载和缓存清理。
- **本机优先**：运行时与用户数据保存在 App 的私有目录，减少对系统全局环境的影响。
- **开发预览友好**：面向快速试用和迭代中的 Harness 版本，保留官方能力与更新路径。

## 安装

1. 打开 [Releases](https://github.com/engty/deepseek-harness-macos-launcher/releases)，下载最新 macOS 安装包。
2. 打开 DMG，将 **DeepSeek Harness.app** 拖入 **Applications** 文件夹。
3. 首次启动若被 macOS 拦截，请在 Finder 中右键 App，选择“打开”。
4. 在 App 菜单中配置 DeepSeek API Key，然后开始使用。

项目面向 macOS 13 或更高版本，优先支持 Apple Silicon。具体系统兼容性以发布页说明为准。

## 代码来源

本项目是独立的开源 macOS 启动器，不是 DeepSeek 官方产品，也不代表 DeepSeek、OpenAI
或任何第三方插件作者。

- **官方运行时与 Web UI**：来自 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)，遵循其 MIT 许可证。
- **macOS 启动器**：本仓库中的 Swift、SwiftUI、AppKit 和 WebKit 代码，遵循本项目的 MIT 许可证。
- **桌宠适配**：基于 [better-dsh-pet](https://github.com/ysppwn721/better-dsh-pet) 及其公开 macOS 适配工作。
- **记忆与其他插件**：通过 Harness 官方插件机制接入，来源、许可证和服务条款由各自上游项目负责。

所有第三方组件与来源记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 隐私与安全

- API Key 只保存在本机的 macOS Keychain 与 Harness 私有凭据目录，不写入本仓库，也不会随发布包上传。
- Harness 默认只监听本机地址；只有用户主动点击的外部链接才会交给系统浏览器。
- 插件属于第三方代码，安装前请确认来源可信，并按其项目说明使用。

## 开发

```bash
swift test
./script/build_and_run.sh --build-only
```

构建脚本会使用本地 Swift 工具链生成 macOS App；发布与签名流程见仓库中的脚本和第三方声明。

## 许可证

本项目使用 [MIT License](LICENSE)。第三方组件仍受其各自许可证约束。
