# DeepSeek Harness for macOS

> 把 DeepSeek Harness 变成 macOS 上双击就能用的桌面 App。**非官方项目**，与 DeepSeek 官方无关。

![DeepSeek Harness 界面](Resources/DeepSeekHarness-screenshot.png)

## 项目初衷

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 本身是一个通过命令行或浏览器使用的工具：要自己装 Node.js、装依赖、敲命令、管版本。对普通用户来说门槛太高了。

这个项目做的事情很简单：**把官方 Harness 原封不动地装进一个 macOS App 里**。双击图标就能打开，不用碰终端，不用装任何东西，聊天、模型、插件全是官方的原样功能。

## 怎么用

**要求**：macOS 13 或更高，Apple Silicon（M 系列芯片）。

1. **下载**：到本仓库的 [Releases](https://github.com/engty/deepseek-harness-macos-launcher/releases) 页面，下载 `DeepSeek-Harness-v<版本号>-macos-arm64.dmg`（文件名就带着版本，下载后一眼可辨）。
2. **安装**：打开 DMG，把 `DeepSeek Harness.app` 拖到旁边的 `Applications` 里。
3. **首次打开**：App 未做官方签名，系统可能提示"无法验证开发者"——右键点 App 选"打开"，或在"系统设置 → 隐私与安全性"里点"仍要打开"即可。
4. **配置 API Key**：打开 App 后，点击顶栏的"余额"按钮，粘贴你的 DeepSeek API Key。配好后顶栏会显示余额，聊天和余额共用同一个 Key。
5. **装插件**：菜单栏 `Plugins → Install Plugin…`，粘贴官方安装命令即可，例如：
   ```
   dsh plugin --profile web add dsh-llm-codex
   ```
   装好的插件可以在同一菜单里启动、停用或卸载。
6. **更新**：App 会静默检查 Harness 更新，有新版时顶栏出现下载按钮，一键升级、失败自动回退；`DeepSeek → Check DeepSeek Harness App Updates…` 检查外壳自身更新。

## 安全性

- **API Key 只留在你的电脑上**：一份存 macOS Keychain，一份存 Harness 的私有凭据文件（仅当前用户可读）。不上传到任何服务器，没有遥测、没有广告、没有账号系统。
- **界面只连本机**：窗口里加载的是运行在你电脑上的 Harness 界面（127.0.0.1），只有你主动点击的外部链接才会交给系统浏览器打开。
- **不碰你的系统环境**：App 在私有目录里运行 Harness 和插件，不会改你的 Node.js、npm、pnpm 或 Shell 配置。
- **更新经过校验**：Harness 升级包走 HTTPS 下载、SHA-256 校验、启动预检，失败自动回退到旧版本。
- **插件是第三方代码**：安装插件前请确认来源可信，插件行为由插件作者负责。

## 实现方式

一句话：这是一个"薄外壳"。

App 内置了一份固定版本的 Node.js 和官方 DeepSeek Harness，在你电脑本地启动它，然后用系统网页组件把官方 Web 界面显示在 App 窗口里。外壳只负责四件事：

- 启动、停止、崩溃后自动拉起 Harness；
- 提供 macOS 菜单来配置 Key、管理插件；
- 安全保存凭据；
- 检查并安装 Harness 更新。

聊天、会话、模型选择、插件功能全部由官方 Harness 原样提供，本项目不重写、不阉割、也不夹带自己的逻辑。

---

本项目代码使用 MIT 许可；第三方组件的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
