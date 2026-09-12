# dsh-privacy-router 集成说明

启动器在构建 Runtime 时固定安装
[`pub-dsh-privacy-router`](https://github.com/LYiHub/pub-dsh-privacy-router)
的提交 `1b51e6d622eaebaa3b0a3ab51a416cb2499d1251`。插件源码仍由上游仓库维护，
启动器只负责把它放入 App 私有的 `web` profile，不把依赖写入系统 Node、npm 或 pnpm。

## 为什么默认停用

隐私路由要求主链路先使用一个本地 Provider，再根据分类结果决定是否把安全的纯文本请求发送到云端。
新安装时通常还没有配置本地 Provider；如果直接启用，主 Agent 会被插件拒绝而无法开始对话。
因此，预装 profile 会保留插件和它的 patch，但启动器第一次复制 profile 时自动停用该 patch。
这不会删除插件，也不会改动用户的其他插件。

## 启用方式

1. 在 Harness 的 Models 页面配置一个本地 Provider（默认信任 `local-ai-*`）。
2. 重启 Harness 后，从菜单进入“插件 → 已安装插件 → dsh-privacy-router”。
3. 选择“启用插件”，启动器会先停止当前 sidecar，更新 App 私有 profile，并通过启动预检后再恢复。

插件默认策略是 `unknown -> local`；非纯文本输入、敏感信息、上下文不足或分类失败都会留在本地。
只有分类为 `public` 的纯文本请求才会按插件配置发送到云端 Provider。

## 构建与升级边界

`script/package_runtime.sh` 使用固定 HTTPS Git URL 安装该提交。上游提交不会在用户启动时自动拉取，
也不会在 Runtime 升级时被隐式替换。若要升级，维护者需要审查新的提交、更新固定值并重新构建 Runtime。
