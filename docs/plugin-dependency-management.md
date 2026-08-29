# DeepSeek Harness App 插件依赖管理方案

> 文档状态：阶段 1/2/3 已实现，阶段 4 等待 Harness 上游依赖声明协议
>
> 文档版本：0.1
>
> 更新日期：2026-08-15
>
> 适用范围：macOS DeepSeek Harness Launcher 的插件安装、卸载和运行环境

## 1. 结论

DeepSeek Harness App 不应要求普通用户先打开终端、安装全局 Node.js、pnpm 或修改 Shell PATH，才能安装标准 Harness 插件。

推荐方案是建立一套 **App 私有工具链**：

1. App 发布包固定携带 Node.js、`dsh` 和 `pnpm`。
2. App 启动插件命令时，为该子进程构造私有 PATH。
3. 不修改用户的系统 PATH、`~/.zshrc`、`~/.zprofile`、Homebrew 或全局 npm/pnpm 环境。
4. 插件及其 Node.js 依赖继续由官方 `dsh plugin --profile web ...` 管理，但全部安装到 App 私有 `DSH_HOME`。
5. 额外的基础依赖只允许通过明确的依赖清单和受控安装器处理；执行前必须展示名称、版本、来源、安装位置和影响范围，由用户确认。
6. 不根据第三方 README、错误文本或插件返回的任意命令直接执行安装操作。

这个方案保持 App 的产品边界不变：它仍然只是 Launcher、Plugin Manager 和 Process Maintainer，但负责把官方网页版原本需要用户手工配置的本地运行环境封装好。

## 2. 当前问题与根因

复现命令：

```sh
dsh plugin --profile web add github:mishibeikejie/zat-dsh-engine
```

该命令来自 [Zat-DSH Engine 官方安装说明](https://github.com/mishibeikejie/zat-dsh-engine#installation)，命令格式正确。

当前故障不是插件命令解析失败，而是 Finder 启动的 App 只得到以下最小 PATH：

```text
/usr/bin:/bin:/usr/sbin:/sbin
```

Harness 的 `dsh plugin` 内部会调用外部 `pnpm`。当前 App Bundle 内没有 `pnpm`，Finder PATH 里也找不到用户通过 nvm 安装的 `pnpm`，因此插件安装进程以退出码 `127` 结束：

```text
dsh: pnpm not found on PATH — install pnpm to manage profile plugins
```

同一命令在终端中可以成功，是因为终端 PATH 包含用户的 nvm 目录。这说明依赖用户终端环境的做法不可重复，也不符合 App 的产品目标。

另外，pnpm 会把常用于公开仓库的 `github:owner/repository` shorthand 解析成 GitHub SSH 地址。
Finder 启动的 App 不应依赖交互式 SSH agent，因此 Launcher 对这个严格 shorthand 形态转换为
HTTPS Git URL；用户明确输入的 `git+ssh`、`git@github.com` 或其他显式地址保持原语义。私有仓库
应使用用户明确配置好的 HTTPS 凭证或显式 SSH 地址。

当前还有两个伴随问题：

- 插件子进程输出没有形成完整、可查询的插件操作日志。
- 插件失败后 Harness 会重新启动，原始错误状态容易被新的 Ready 状态覆盖，用户只看到窗口短暂切换，误以为命令“闪退”。

## 3. 产品目标

### 3.1 必须实现

- 用户从 Finder 双击 App 后，可以直接安装标准 Harness 插件。
- 日常插件安装不要求用户预装全局 Node.js、pnpm 或 `dsh`。
- App 私有工具链只对 App 启动的 Harness 和插件子进程生效。
- 插件及其包依赖只写入 App 私有 profile。
- 需要下载或新增额外依赖时，先获得用户明确确认。
- 安装失败不得破坏当前可用插件树、会话或设置。
- 用户能看到安装成功、失败阶段、退出码和经过脱敏的错误摘要。

### 3.2 不做

- 不修改全局 PATH 或用户 Shell 启动文件。
- 不自动安装 Homebrew。
- 不使用 `sudo`，不写入 `/usr/local`、`/opt/homebrew`、`/Library` 或系统目录。
- 不执行插件 README 中的任意安装命令。
- 不承诺解决驱动、内核扩展、系统服务、Xcode Command Line Tools 等高权限依赖。
- 不维护全量第三方插件兼容矩阵。
- 不替代 Harness 官方插件协议或发明新的插件包格式。

## 4. 依赖分层

### 4.1 A 类：App 发布包内置基础工具

首版固定包含：

| 工具 | 用途 | 建议来源 | 安装范围 |
|---|---|---|---|
| Node.js | 运行 Harness 与 pnpm | App Runtime Bundle 固定版本 | App Bundle |
| `dsh` | Harness Runtime 与插件管理入口 | `@deepseek-ai/dsh` 固定版本 | App Bundle |
| `pnpm` | 官方 `dsh plugin` 的实际包管理器 | 固定版本 npm 包 | App Bundle |

这些工具随 App Release 构建，不需要首次运行时修改用户电脑。App 安装本身就是用户对这套内置工具链的授权。

### 4.2 B 类：macOS 系统基础工具

首版可检测：

- `/usr/bin/curl`
- `/usr/bin/git`

系统工具存在时使用绝对路径或把固定系统目录加入子进程 PATH。若工具实际不可用，不直接安装系统组件，而是向用户说明缺失项和影响。

### 4.3 C 类：App 私有可下载工具

未来某些常见基础工具无法随主 App 发布时，可以安装到：

```text
~/Library/Application Support/com.harness.desktop.launcher/toolchain/
  <tool-name>/
    <version>/
      bin/
      manifest.json
```

每个可下载工具必须有 Launcher 自己维护的受控清单：

- 工具名称和固定版本
- 支持的 macOS 架构
- HTTPS 下载地址
- SHA-256
- 解压后允许的可执行文件
- License/来源链接
- 最大下载和解压尺寸

没有进入受控清单的依赖只能提示，不自动安装。

### 4.4 D 类：插件的 Node.js 包依赖

这部分继续交给官方 `dsh plugin` 和 pnpm，目标目录是：

```text
~/Library/Application Support/com.harness.desktop.launcher/
  data/active/dsh-home/profiles/web/node_modules/
```

这些依赖不是全局 npm/pnpm 包，不会影响用户其他 Node.js 项目。

### 4.5 E 类：不支持自动安装的依赖

以下依赖默认只提示用户，不自动处理：

- 需要管理员权限或 `sudo` 的系统包
- Homebrew 本身
- 驱动、内核扩展、登录项和系统服务
- 需要修改防火墙、安全策略或网络代理的组件
- 来源、版本或校验值不明确的二进制文件
- 插件通过日志或 README 临时要求执行的任意 Shell 命令

## 5. 私有 PATH 设计

App 每次启动 Harness 或插件命令时单独构造 PATH，不写入任何全局配置。

建议顺序：

1. 当前操作明确批准的 App 私有工具目录。
2. App Bundle 内的 `runtime/node_modules/.bin`。
3. App Bundle 内的 `runtime/node/bin`。
4. Application Support 下的 App 私有 toolchain 目录。
5. `/usr/bin:/bin:/usr/sbin:/sbin`。
6. 用户明确同意使用的已有工具目录，作为最后的兼容回退。

示例：

```text
<App>/Contents/Resources/runtime/node_modules/.bin:
<App>/Contents/Resources/runtime/node/bin:
~/Library/Application Support/com.harness.desktop.launcher/toolchain/bin:
/usr/bin:/bin:/usr/sbin:/sbin
```

原则：

- App 内置版本优先，保证可重复。
- 默认不完整继承用户的 Shell PATH，避免不同电脑产生不同结果。
- 可以发现用户已有工具，但只有在确认框中显示实际路径并获得同意后，才加入 App 子进程 PATH。
- 不执行登录 Shell 来读取 PATH，避免触发用户 Shell 初始化脚本。

## 6. 依赖发现规则

### 6.1 已知基础依赖

Launcher 自己知道官方插件管理必需 `pnpm`，因此在执行任何 `add`、`remove` 或 `update` 前检查它。

GitHub 类型的 package spec 可以额外检查 `git` 和 `curl`：

```text
github:user/repository
git+https://...
git@github.com:...
https://github.com/...git
```

`github:owner/repository` 的严格 shorthand 在进入官方命令前会转换为
`https://github.com/owner/repository.git`（保留 `#ref`）。这只是解决 Finder 环境没有 SSH agent
的问题，不会把显式 SSH 地址改写成 HTTPS。

### 6.2 插件声明的额外依赖

只有 Harness 上游形成正式、结构化的系统依赖声明后，Launcher 才直接读取该字段。当前不根据自然语言 README 推断安装命令，也不发明与上游不兼容的强制字段。

在没有官方声明标准时，可以维护一个很小的 Launcher 受控基础依赖目录，但只能覆盖广泛复用、无管理员权限、可安装到 App 私有目录的工具。

### 6.3 失败后的缺失依赖识别

安装失败时可以识别 `ENOENT`、`command not found` 等信息，用于告诉用户缺少什么；错误文本不能直接转化为自动执行的 Shell 命令。

如果识别出的工具已在受控依赖清单中，可以重新生成依赖计划并再次请求确认；否则停止并保留原 profile。

## 7. 用户确认流程

### 7.1 无需下载额外依赖

插件确认框显示：

```text
目标插件：github:mishibeikejie/zat-dsh-engine

运行环境：
• Node.js 22.19.0（App 内置）
• dsh 0.1.0-rc.6（App 内置）
• pnpm 10.19.0（App 内置）
• git / curl（macOS 系统）

影响范围：
• 只修改 DeepSeek Harness App 私有 profile
• 不修改系统 PATH、Shell 配置或全局 npm/pnpm
• 插件可能执行其 package lifecycle script
```

按钮：

- `安装插件`
- `取消`

### 7.2 需要安装 App 私有依赖

确认框必须额外显示：

- 缺少的依赖名称
- 将安装的固定版本
- 下载来源
- SHA-256 校验状态
- 安装目录
- 下载大小
- 是否需要重启 Harness

按钮：

- `安装依赖并继续`
- `取消`

用户取消后不得创建半成品工具链或修改 active profile。

### 7.3 需要全局或管理员权限

Launcher 停止自动流程，明确说明该依赖不能由 App 私有安装器安全处理。此时不提供“自动执行 sudo”按钮。

## 8. 完整执行流程

1. 用户粘贴官方 `dsh plugin --profile web add <spec>` 命令。
2. Launcher 只解析 argv，不经过 Shell。
3. 校验命令只包含允许的 `web` profile 插件操作。
4. 定位当前 Runtime、Node 和 App 私有 `DSH_HOME`。
5. 生成依赖计划：已内置、系统已有、可私有安装、不可自动处理。
6. 展示插件来源、依赖、安装位置、lifecycle script 风险和影响范围。
7. 用户确认后，准备 App 私有工具链；每个新下载依赖完成 HTTPS、大小、SHA-256 和归档路径校验。
8. 复制当前完整 data slot 到 staging。
9. 使用私有 PATH 和 staging `DSH_HOME` 执行官方 `dsh plugin` 命令。
10. 持续读取 stdout/stderr，写入脱敏日志，避免输出管道阻塞。
11. 执行 `dsh --profile web --dump-config`。
12. 启动候选 Harness，验证 Host 与 Web UI readiness。
13. 所有步骤成功后原子激活 staging slot。
14. 重启正式 Harness sidecar。
15. 显示成功结果和最终插件版本。
16. 任一步失败都删除或隔离 staging，恢复原 active slot，并显示失败阶段、退出码和日志摘要。

## 9. 安装状态模型

| 状态 | 用户看到的内容 | 是否修改 active profile |
|---|---|---|
| 检测依赖 | 正在检查插件运行环境 | 否 |
| 等待确认 | 依赖、来源、目录和风险摘要 | 否 |
| 准备私有工具链 | 下载和校验进度 | 否 |
| 安装到 staging | 插件安装进度 | 否 |
| 候选预检 | 正在检查插件是否可启动 | 否 |
| 激活 | 正在切换插件 profile | 原子切换 |
| 完成 | 插件名称、版本、状态 | 是 |
| 失败 | 阶段、退出码、脱敏错误、查看日志 | 否 |

App 不应让确认框关闭后长时间没有反馈，也不应在 Harness 重启后丢失插件安装错误。

## 10. 日志与诊断

建议增加专用日志：

```text
~/Library/Logs/com.harness.desktop.launcher/plugin-operations.log
```

每次操作记录：

- 时间和操作 ID
- 插件 spec（脱敏后）
- 依赖计划和来源类型
- 当前 Runtime、Node、pnpm 版本
- 执行阶段
- 退出码
- 脱敏 stdout/stderr 尾部
- active slot 是否改变
- 是否完成回滚

禁止记录：

- API Key、Authorization Header、token、密码
- `.credentials.yaml` 内容
- Keychain 内容
- 带凭证的 URL
- 完整用户环境变量

日志必须限制总大小并轮转。导出诊断时只包含脱敏摘要，不默认包含完整插件源码或用户会话。

## 11. 安全边界

- 插件命令继续使用 `Process` 和 argv，不使用 `eval`、`sh -c` 或拼接 Shell 字符串。
- 自动安装器只处理 Launcher 内置允许列表中的依赖。
- 所有可下载依赖固定版本、HTTPS、SHA-256、架构和最大尺寸。
- 解压时拒绝绝对路径、`..` 和逃逸 symlink。
- App 不修改已签名 Bundle；运行时新增工具写入 Application Support 私有目录。
- 默认禁止 `sudo` 和系统范围写入。
- 插件自身 lifecycle/build script 仍属于第三方代码执行风险，必须在最终确认前明确提示。
- 依赖准备和插件安装都在 staging 中完成，active profile 只在全部预检成功后切换。

## 12. 分阶段实施计划

### 阶段 0：方案确认

- 评审本文档。
- 确认“App 内置 pnpm、私有 PATH、不修改全局环境”为正式架构决策。
- 确认自动安装只覆盖允许列表中的无管理员权限基础依赖。

交付物：本方案文档，不修改产品代码。

### 阶段 1：解决 pnpm 与安装反馈

- Release Runtime 固定打包 `pnpm`。
- App Bundle 校验增加 `pnpm` 可执行入口检查。
- 插件命令 PATH 优先使用 App 内置 pnpm 和 Node。
- 安装确认框展示依赖版本、来源与作用范围。
- 插件执行输出写入脱敏日志。
- 安装结束显示明确成功或失败提示。
- 修复失败状态被 Harness 重启覆盖的问题。

当前阶段已落地：App Bundle 的 Runtime 由发布流水线固定包含 Node.js、@deepseek-ai/dsh
和 pnpm；Harness sidecar、插件命令和候选预检共用 App 私有 PATH。插件操作输出会持续读取、
脱敏并写入 ~/Library/Logs/com.harness.desktop.launcher/plugin-operations.log。

阶段 1 之后补充了 pnpm 10 的 build-script 安全流程：当官方 Harness 输出明确的
`Ignored build scripts` 包名时，Launcher 会要求用户确认，只把这些精确包名写入 staging
profile 的 `pnpm-workspace.yaml` `allowBuilds`，然后重新执行官方命令。

验收插件：

```text
dsh plugin --profile web add github:mishibeikejie/zat-dsh-engine
```

### 阶段 2：统一 App 私有工具链服务

- 建立基础依赖解析器和固定 PATH 生成器。
- 检测 App 内置、macOS 系统、App 私有下载和用户已有工具四种来源。
- 为 App 私有工具建立版本目录、manifest、校验和清理规则。
- Harness sidecar、插件命令和候选预检使用同一套环境构造逻辑。

当前阶段已落地：`AppToolchain` 提供固定版本清单、App Support 下的版本目录、manifest
记录和统一 PATH；Harness、插件命令和候选预检都通过同一个依赖服务读取这些目录。

### 阶段 3：受控依赖自动安装

- 增加允许列表依赖清单。
- 增加依赖下载、SHA-256、归档安全、原子激活和失败清理。
- 增加“安装依赖并继续”确认流程和下载进度。
- 只选择一个体积小、无管理员权限的测试工具完成端到端验证。

当前阶段已落地：受控清单包含 jq 1.7.1（按 arm64/x86_64 固定 URL、大小、SHA-256、来源和
许可证），仅在插件失败明确报告 jq 缺失且用户再次确认后下载到 App 私有目录。下载结果会
进行 HTTPS、大小、SHA-256、可执行文件名和原子目录激活校验；未知工具、Homebrew 和
管理员权限依赖仍然只提示，不会自动执行。

### 阶段 4：上游依赖声明兼容

- 跟踪 Harness 是否增加正式系统依赖声明。
- 若上游提供稳定字段，优先采用上游协议并废弃 Launcher 私有映射。
- 保持旧 Runtime 的兼容回退，但不扩展为第三方插件市场或通用系统包管理器。

截至本次实现审计，Harness 上游公开的插件协议仍然是把参数转发给 pnpm，并没有稳定的
系统依赖声明字段。Launcher 因此没有发明新的强制 manifest 字段；当前只支持受控清单和
pnpm 官方 allowBuilds 提示，后续上游提供正式字段后再接入。

## 13. 阶段 1 验收标准

- Finder 启动的 App 在只有 `/usr/bin:/bin:/usr/sbin:/sbin` 的环境下仍能安装测试插件。
- 安装过程不依赖用户电脑上的 nvm、Homebrew 或全局 pnpm。
- `zat-dsh-engine` 安装后出现在 active profile 的 dependencies 和 bundles 中。
- 插件候选 `--dump-config` 和 Harness readiness 通过。
- App 重启后插件仍然存在并可加载。
- 用户取消确认后 active profile、工具链和日志之外的状态不变。
- 安装失败时 active profile 保持原状，Harness 恢复运行。
- 用户能看到明确错误，不再表现为无说明的“闪退”。
- 不修改 `~/.zshrc`、`~/.zprofile`、系统 PATH、Homebrew 和全局 npm/pnpm。
- 日志中不出现 API Key、token 或凭证文件内容。
- Release 校验能够阻止缺少 Node、dsh 或 pnpm 的不完整 App 被发布。

## 14. 需要评审的决策

### 决策 A：pnpm 如何提供

推荐：随每个 App Release 固定打包，不在用户第一次安装插件时临时下载。

原因：版本可重复、无需额外网络步骤、不会修改主机全局环境，也最容易与固定 Harness Runtime 一起验证。

### 决策 B：是否使用用户已有 pnpm

推荐：默认不用；只有 App 内置 pnpm 不可用时，才把发现到的用户 pnpm 作为显式确认后的兼容回退，并显示完整路径。

### 决策 C：是否自动安装任意插件要求的系统依赖

推荐：不允许。自动安装只覆盖 Launcher 受控允许列表；其他依赖只提供明确诊断。

### 决策 D：是否修改用户 Shell PATH

推荐：永不修改。每次由 Launcher 为自己的子进程构造 PATH，效果稳定且不会影响其他软件。

## 15. 推荐评审结论

阶段 1、2、3 已按本文方案落地，建议后续按以下顺序维护：

1. 使用 `zat-dsh-engine`、npm 包插件和现有 `dsh-llm-codex` 做回归验证。
2. 继续保持受控依赖清单小而明确；新增工具必须补齐固定版本、架构、大小、SHA-256、来源和许可证。
3. 在没有上游正式依赖声明前，不扩大为任意系统依赖自动安装器。
4. Harness 上游出现正式依赖声明字段后，再单独评审协议接入和旧 Runtime 兼容策略。

这样既实现“用户不需要终端”的产品价值，也保留清晰的安全和维护边界。
