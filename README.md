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
4. **配置 API Key**：打开 App 后，从 `设置 → 更换 DeepSeek API 密钥…` 输入你的 DeepSeek API Key。聊天和余额查询共用同一个 Key；余额会继续显示在右上角，对话框中的“充值”按钮会打开官方 `https://platform.deepseek.com/usage` 页面。
5. **装插件**：菜单栏 `插件 → 安装插件…`，粘贴官方安装命令即可，例如：
   ```
   dsh plugin --profile web add dsh-llm-codex
   ```
   App 首次启动时默认已经带有 `dsh1024`（当前锁定 `0.5.0`）、`better-dsh-pet`（当前锁定 `0.3.5`）和 `dsh-mnemon`（当前锁定 `0.3.5`）。dsh-mnemon 的本地 Mnemon Native CLI（当前锁定 `0.2.5`）随 App Runtime 私有打包，只在本 App 的 Harness 进程中生效，不会安装到系统全局 PATH；记忆数据也会默认写入 App 私有 DSH_HOME 下的 `mnemon` 目录，默认远程记忆 Provider 不会自动启用。1024Store 内容会出现在 Harness 页面侧边栏；桌宠默认关闭，可从 `插件 → 桌宠 → 显示桌宠` 开启，`隐藏桌宠` 会立即停止悬浮窗口，不会重启 Harness。桌宠被手动拖动后会记住上次位置，重启 App 会自动恢复；更换屏幕或分辨率时会自动将位置校正到可见区域。装好的插件可以在同一菜单里启动、停用、卸载或清理缓存。插件 profile 保存在 App 私有 DSH_HOME；pnpm 的共享缓存沿用用户环境以兼容更多插件，卸载和“清理插件缓存”会在确认后回收未使用缓存。用户卸载默认插件后不会在重启时自动装回。
   桌宠的 macOS 适配层由本项目在构建时应用到上游包；气泡大小支持 40%–120%，默认 100%。macOS 语音播报使用系统 `/usr/bin/say`，默认使用 `Yue (Premium)`（月）高级中文音色，未安装时自动回退到系统默认音色，不上传音频；上游依赖 Windows SAPI 的麦克风识别入口在 macOS 版保持关闭。首次显示桌宠时才会把固定版本 Electron 下载到 App 私有 DSH_HOME，并校验 SHA-256，不安装到系统全局目录。
   需要识图时可按官方标准方式安装 `@anionex/dsh-vision-toolkit`：
   `dsh plugin --profile web add @anionex/dsh-vision-toolkit`。它会在 App 私有目录准备隔离的 Python、Pillow、NumPy 和 vtracer，不写入系统 Python；首次启动视觉插件可能需要几分钟准备依赖，启动器会等待其完成。
6. **更新**：App 会静默检查 Harness 更新，有新版时右上角只显示下载按钮，一键升级、失败自动回退；`设置 → 检查 DeepSeek Harness 更新…` 检查外壳自身更新。无更新时右上角显示按北京时间计算的折扣倍率：工作日 9:00–12:00、14:00–18:00 为 `1.0x`，其余时间为 `0.5x`。

## 安全性

- **API Key 只留在你的电脑上**：一份存 macOS Keychain，一份存 Harness 的私有凭据文件（仅当前用户可读）。不上传到任何服务器，没有遥测、没有广告、没有账号系统。
- **界面只连本机**：窗口里加载的是运行在你电脑上的 Harness 界面（127.0.0.1），只有你主动点击的外部链接才会交给系统浏览器打开。
- **不碰你的系统配置**：插件 profile 和 Harness 数据保存在 App 私有目录；App 不改 Node.js、npm、pnpm 或 Shell 配置。为保持插件兼容性，pnpm 共享缓存可能沿用用户已有位置，清理时只回收未使用内容。
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
