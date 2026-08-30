# better-dsh-pet 集成说明

DeepSeek Harness Launcher 将 `better-dsh-pet@0.3.5` 作为标准 Web profile bundle
预装到新 profile 中。启动器不重写 DSH 的插件加载流程，仍由 Harness 根据
`package.json` 的 `dsh.profile.bundles` 和插件自己的 `cordis.patch.yml` 挂载。

## macOS 适配边界

上游包包含面向 Windows 的 Electron Helper。构建 Runtime 时，
`script/patch_better_dsh_pet_macos.sh` 会在确认包版本为 `0.3.5` 后，替换为
`Resources/better-dsh-pet-macos` 中的 macOS 适配文件：

- 使用 Apple Silicon/Intel 对应的 Electron 路径和下载包；
- 使用透明置顶窗口和 macOS 光标轮询实现点击穿透；
- 不调用 Windows 前台窗口、PowerShell 或 System.Speech；
- 开启 Electron renderer sandbox；
- 只从当前 Harness 的私有 `DSH_HOME/electron` 解析 Electron，不使用全局安装。

动画和上游包仍从 npm registry 按锁定版本获取。首次显示桌宠时才下载
Electron，并在解压前校验官方发布的 SHA-256。

## 启用与停用

新 profile 的桌宠配置默认为 `enabled: false`，避免首次启动自动弹出窗口或
下载大型运行时。用户可通过 `插件 → 桌宠 → 显示桌宠` 或 `隐藏桌宠` 调用
`/plugins/better-dsh-pet/config` 的本机 PATCH 接口即时切换；这不会修改 profile、
不会重启 Harness，也不会中断当前对话。

气泡大小仍由桌宠自己的 `bubbleScale` 配置控制，范围为 40%–120%，默认 100%。

桌宠只作为状态展示和动画窗口使用。macOS 适配版不启用语音识别、桌宠内置
任务执行和直接读取明文凭据文件；主 App 的 DeepSeek API Key 与余额查询仍由
启动器自己的 Keychain/DSH 凭据流程负责。

## 现有用户

启动器不会自动修改已有 profile，也不会覆盖用户已经删除或停用的插件。已有
用户可以在插件菜单中按官方命令安装 `better-dsh-pet@0.3.5`；安装完成后，
启动器下一次启动即可识别它。插件安装/卸载属于 profile 变更操作，仍遵循
现有的 staging、候选启动预检和原子切换流程。

## 发布与授权

上游代码仓库为 MIT 许可证，但动画素材可能有额外的非商用和署名要求。发布
App 时保留上游 README 和 LICENSE，并在 `THIRD_PARTY_NOTICES.md` 中提供来源；
商业分发前应单独取得素材授权。
