import AppKit
import Combine
import Foundation

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var phase: LauncherPhase = .stopped
    @Published private(set) var plugins: [HarnessPlugin] = []
    @Published private(set) var pluginOperationStates: [String: PluginRuntimeState] = [:]
    @Published private(set) var runtimePath: String?
    @Published private(set) var runtimeVersion: String?
    @Published private(set) var lastError: String?
    @Published private(set) var updateState: RuntimeUpdateState = .idle
    @Published private(set) var balanceState: DeepSeekBalanceState = .notConfigured
    @Published private(set) var isBalanceConfigured = false

    let paths: AppPaths
    private let locator: RuntimeLocator
    private let profileManager: ProfileManager
    private let processController: HarnessProcessController
    private let pluginRunner: PluginCommandRunner
    private let updateService: RuntimeUpdateService
    private let runtimeInstaller: RuntimeArchiveInstaller
    private let dataSlotManager: DataSlotManager
    private let runtimePreflight: RuntimePreflightService
    private let balanceService: DeepSeekBalanceService
    private let balanceKeychain = KeychainStore(
        service: AppPaths.bundleIdentifier,
        account: "deepseek-api-key"
    )
    private var latestManifest: RuntimeManifest?
    private var balanceRefreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var consecutiveCrashCount = 0

    init(
        paths: AppPaths = AppPaths(),
        locator: RuntimeLocator = RuntimeLocator()
    ) {
        self.paths = paths
        self.locator = locator
        profileManager = ProfileManager(paths: paths)
        processController = HarnessProcessController()
        pluginRunner = PluginCommandRunner()
        updateService = RuntimeUpdateService()
        runtimeInstaller = RuntimeArchiveInstaller()
        dataSlotManager = DataSlotManager()
        runtimePreflight = RuntimePreflightService()
        balanceService = DeepSeekBalanceService()
        processController.onUnexpectedTermination = { [weak self] output in
            self?.handleUnexpectedTermination(output)
        }
        do {
            try paths.prepare()
            plugins = profileManager.refresh()
            // Do not probe a previously stored Keychain item during launch:
            // ad-hoc development identities can trigger a macOS access sheet.
            // Balance configuration is an explicit user action for this App.
            isBalanceConfigured = false
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    var endpointURL: URL? {
        if case .ready(let url) = phase { return url }
        return nil
    }

    var isHarnessRunning: Bool { processController.isRunning }

    func pluginStatus(for plugin: HarnessPlugin) -> PluginRuntimeState {
        pluginOperationStates[plugin.id] ?? plugin.state
    }

    var canRestart: Bool {
        switch phase {
        case .starting, .busy:
            return false
        default:
            return true
        }
    }

    func webViewDidFail(_ message: String) {
        lastError = "Harness Web UI: \(message)"
        AppLogger.launcher.error("Harness Web UI failed: \(message, privacy: .public)")
    }

    func startIfNeeded() async {
        guard !phase.isReady, phase != .starting, !processController.isRunning else { return }
        await start()
    }

    func start() async {
        guard !processController.isRunning else { return }
        phase = .starting
        lastError = nil
        do {
            try paths.prepare()
            let installation = try locator.locate()
            runtimePath = installation.executable.path
            runtimeVersion = installation.version
            let url = try await processController.start(
                installation: installation,
                paths: paths,
                overlayURL: profileManager.overlayURLIfNeeded()
            )
            plugins = profileManager.refresh()
            phase = .ready(url)
            consecutiveCrashCount = 0
            AppLogger.launcher.info("Harness ready at \(url.absoluteString, privacy: .public)")
            scheduleAutomaticUpdateCheck()
            scheduleBalanceRefresh()
        } catch {
            lastError = error.localizedDescription
            if let locatorError = error as? RuntimeLocatorError {
                phase = .runtimeMissing(locatorError.localizedDescription)
            } else {
                phase = .failed(error.localizedDescription)
            }
            AppLogger.launcher.error("Harness start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        guard processController.isRunning else {
            phase = .stopped
            return
        }
        phase = .busy("Stopping Harness")
        await processController.stop()
        phase = .stopped
    }

    func restart() async {
        await stop()
        await start()
    }

    func setPluginEnabled(_ plugin: HarnessPlugin, enabled: Bool) async {
        await setPluginsEnabled([plugin], enabled: enabled)
    }

    func setPluginsEnabled(_ selectedPlugins: [HarnessPlugin], enabled: Bool) async {
        guard !selectedPlugins.isEmpty else { return }
        let wasRunning = processController.isRunning
        selectedPlugins.forEach {
            pluginOperationStates[$0.id] = enabled ? .starting : .stopping
        }
        let names = selectedPlugins.map(\.name).joined(separator: ", ")
        phase = .busy(enabled ? "Starting \(names)" : "Stopping \(names)")
        if wasRunning { await processController.stop() }

        do {
            try profileManager.setEnabled(selectedPlugins, enabled: enabled)
            plugins = profileManager.refresh()
            selectedPlugins.forEach {
                pluginOperationStates[$0.id] = enabled ? .running : .stopped
            }
            if wasRunning {
                await start()
            } else {
                phase = .stopped
            }
        } catch {
            lastError = error.localizedDescription
            selectedPlugins.forEach {
                pluginOperationStates[$0.id] = .error
            }
            phase = .failed(error.localizedDescription)
            if wasRunning { await start() }
        }
    }

    func installPluginPrompt() {
        guard let command = promptForText(
            title: "Install Harness Plugin",
            message: "粘贴官方安装命令。只接受 dsh plugin --profile web add <plugin-spec>，不会通过 shell 执行。",
            placeholder: "例如 dsh plugin --profile web add dsh-llm-codex"
        ) else { return }
        do {
            let arguments = try PluginCommandParser.parseInstallCommand(command)
            let specs = Array(arguments.dropFirst()).joined(separator: " ")
            guard confirmPluginMutation(operation: "安装", spec: specs) else { return }
            Task { await mutatePlugin(arguments: arguments, operation: "Installing Plugin") }
        } catch {
            presentInfoAlert(title: "安装命令无法识别", message: error.localizedDescription)
        }
    }

    func removePluginPrompt() {
        let selected = promptForPluginSelection(title: "卸载 Harness 插件", operation: "卸载")
        guard !selected.isEmpty else { return }
        let names = selected.map(\.name).joined(separator: ", ")
        guard confirmPluginMutation(operation: "卸载", spec: names) else { return }
        Task { await mutatePlugin(arguments: ["remove"] + selected.map(\.id), operation: "Removing Plugins") }
    }

    func stopPluginPrompt() {
        let selected = promptForPluginSelection(title: "停用 Harness 插件", operation: "停用")
        guard !selected.isEmpty else { return }
        let names = selected.map(\.name).joined(separator: ", ")
        guard confirmPluginMutation(operation: "停用", spec: names) else { return }
        Task { await setPluginsEnabled(selected, enabled: false) }
    }

    func checkForUpdates() {
        Task { await checkForUpdates(presentResult: true) }
    }

    func downloadLatestUpdate() {
        Task { await downloadLatestUpdateIfAvailable() }
    }

    func configureDeepSeekBalance(forcePrompt: Bool = false) {
        if isBalanceConfigured && !forcePrompt {
            Task { await refreshBalance() }
            return
        }

        guard let apiKey = promptForSecret(
            title: "配置 DeepSeek API Key",
            message: "API Key 仅保存到 macOS Keychain，并仅用于调用 DeepSeek 官方余额接口。不会注入 Harness Web UI、日志或诊断文件。"
        ) else { return }

        do {
            try balanceKeychain.save(apiKey)
            isBalanceConfigured = true
            scheduleBalanceRefresh()
        } catch {
            balanceState = .failed(error.localizedDescription)
            presentInfoAlert(title: "无法保存 DeepSeek API Key", message: error.localizedDescription)
        }
    }

    func refreshBalance() async {
        guard let apiKey = balanceKeychain.read(allowInteraction: true), !apiKey.isEmpty else {
            isBalanceConfigured = false
            balanceState = .notConfigured
            return
        }

        balanceState = .loading
        do {
            let response = try await balanceService.fetch(apiKey: apiKey)
            balanceState = .available(response.balanceInfos)
        } catch {
            balanceState = .failed(error.localizedDescription)
        }
    }

    var balanceDisplayText: String {
        switch balanceState {
        case .notConfigured:
            return "余额未设置"
        case .loading:
            return "余额查询中…"
        case .available(let infos):
            let amounts = infos.map { balanceAmount(for: $0) }
            return amounts.isEmpty ? "余额不可用" : "余额 \(amounts.joined(separator: " / "))"
        case .failed:
            return "余额查询失败"
        }
    }

    var hasAvailableRuntimeUpdate: Bool {
        if case .available = updateState { return true }
        return false
    }

    func exportDiagnostics() {
        let text = SensitiveDataRedactor.redact("""
        DeepSeek Harness
        Phase: \(phase.title)
        Runtime: \(runtimePath ?? "not found")
        Runtime version: \(runtimeVersion ?? "unknown")
        DSH_HOME: \(paths.dshHome.path)
        Plugins: \(plugins.map(\.id).joined(separator: ", "))
        Balance: \(balanceDisplayText)
        Error: \(lastError ?? "none")
        """)
        let url = paths.diagnosticsFile
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func mutatePlugin(arguments: [String], operation: String) async {
        guard let installation = try? locator.locate() else {
            phase = .runtimeMissing("插件管理需要可执行的 Harness Runtime。")
            return
        }

        let wasRunning = processController.isRunning
        phase = .busy(operation)
        if wasRunning { await processController.stop() }

        do {
            _ = try await pluginRunner.mutateProfile(
                installation: installation,
                paths: paths,
                arguments: arguments
            )
            plugins = profileManager.refresh()
            if wasRunning { await start() } else { phase = .stopped }
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
            if wasRunning { await start() }
        }
    }

    private func handleUnexpectedTermination(_ output: String) {
        guard phase.isReady || phase == .busy("Starting DeepSeek Harness") else { return }
        consecutiveCrashCount += 1
        let message = output.isEmpty ? "Harness sidecar unexpectedly exited." : output
        lastError = message
        phase = .failed("Harness sidecar unexpectedly exited.\n\(message)")
        guard consecutiveCrashCount <= 3 else {
            Task { [weak self] in
                await self?.recoverLastKnownGoodRuntime()
            }
            return
        }
        let retryDelay = UInt64(consecutiveCrashCount) * 1_000_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: retryDelay)
            guard !Task.isCancelled else { return }
            await self?.start()
        }
    }

    private func recoverLastKnownGoodRuntime() async {
        guard let fallback = try? locator.locateLastKnownGood() else { return }
        do {
            try runtimeInstaller.restoreLastKnownGood(paths: paths)
            let url = try await processController.start(
                installation: fallback,
                paths: paths,
                overlayURL: profileManager.overlayURLIfNeeded()
            )
            runtimePath = fallback.executable.path
            runtimeVersion = fallback.version
            phase = .ready(url)
            lastError = "已回退到 last-known-good DeepSeek Harness Runtime。"
            consecutiveCrashCount = 0
        } catch {
            lastError = "Runtime 回退失败：\(error.localizedDescription)"
        }
    }

    private func scheduleAutomaticUpdateCheck() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                while !Task.isCancelled {
                    await self?.checkForUpdates(presentResult: false)
                    try await Task.sleep(nanoseconds: 21_600_000_000_000)
                }
            } catch {
                return
            }
        }
    }

    private func scheduleBalanceRefresh() {
        guard isBalanceConfigured else {
            balanceRefreshTask?.cancel()
            balanceRefreshTask = nil
            return
        }
        balanceRefreshTask?.cancel()
        balanceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBalance()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func checkForUpdates(presentResult: Bool) async {
        updateState = .checking
        do {
            let result = try await updateService.check(currentHarnessVersion: runtimeVersion)
            if result.isUpdateAvailable {
                latestManifest = result.manifest
                updateState = .available(result.manifest.runtimeID)
                if presentResult { presentUpdateAlert(result) }
            } else {
                latestManifest = nil
                updateState = .upToDate
                if presentResult { presentInfoAlert(title: "Harness Runtime 已是最新", message: result.manifest.runtimeID) }
            }
        } catch {
            latestManifest = nil
            updateState = .failed(error.localizedDescription)
            if presentResult { presentInfoAlert(title: "无法检查 Harness 更新", message: error.localizedDescription) }
        }
    }

    private func downloadLatestUpdateIfAvailable() async {
        guard let manifest = latestManifest else {
            await checkForUpdates(presentResult: false)
            guard let manifest = latestManifest else { return }
            await downloadLatestUpdate(manifest)
            return
        }
        await downloadLatestUpdate(manifest)
    }

    private func downloadLatestUpdate(_ manifest: RuntimeManifest) async {
        updateState = .checking
        do {
            let destination = paths.caches.appendingPathComponent("updates/staging", isDirectory: true)
            let artifactURL = try await updateService.download(manifest, to: destination)
            guard presentRuntimeActivationConfirmation(manifest: manifest, artifactURL: artifactURL) else {
                updateState = .available(manifest.runtimeID)
                return
            }
            await activateRuntimeUpdate(manifest: manifest, artifactURL: artifactURL)
        } catch {
            updateState = .failed(error.localizedDescription)
            presentInfoAlert(title: "Harness 更新下载失败", message: error.localizedDescription)
        }
    }

    private func activateRuntimeUpdate(manifest: RuntimeManifest, artifactURL: URL) async {
        let wasRunning = processController.isRunning
        let previousInstallation = try? locator.locate()
        var activation: RuntimeActivation?
        var dataActivation: DataSlotActivation?
        phase = .busy("Updating DeepSeek Harness")
        if wasRunning { await processController.stop() }

        do {
            let candidateSlot = try dataSlotManager.cloneActiveSlot(paths: paths)
            let newActivation = try await runtimeInstaller.activate(
                manifest: manifest,
                artifactURL: artifactURL,
                paths: paths,
                previousInstallation: previousInstallation
            )
            activation = newActivation
            runtimePath = newActivation.installation.executable.path
            runtimeVersion = newActivation.installation.version ?? manifest.harness.version

            let basePreflightRoot = paths.caches
                .appendingPathComponent("updates/base-preflight", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: basePreflightRoot) }
            try await runtimePreflight.run(
                installation: newActivation.installation,
                paths: paths,
                dshHome: basePreflightRoot.appendingPathComponent("dsh-home", isDirectory: true),
                currentDirectory: basePreflightRoot
            )

            // Always boot the new Runtime against a clone of the user's real
            // profile, even when the App was stopped before the update.
            let candidateController = HarnessProcessController()
            do {
                _ = try await candidateController.start(
                    installation: newActivation.installation,
                    paths: paths,
                    overlayURL: profileManager.overlayURLIfNeeded(),
                    dshHomeOverride: candidateSlot.appendingPathComponent("dsh-home", isDirectory: true),
                    currentDirectoryOverride: candidateSlot
                )
                await candidateController.stop()
            } catch {
                await candidateController.stop()
                throw HarnessProcessError.failedToLaunch(
                    "Runtime 用户 profile 预检失败：\(error.localizedDescription)"
                )
            }

            dataActivation = try dataSlotManager.activate(candidateSlot: candidateSlot, paths: paths)
            if wasRunning {
                let url = try await processController.start(
                    installation: newActivation.installation,
                    paths: paths,
                    overlayURL: profileManager.overlayURLIfNeeded()
                )
                phase = .ready(url)
            } else {
                phase = .stopped
            }
            updateState = .downloaded(artifactURL.path)
            presentInfoAlert(
                title: "DeepSeek Harness 已更新",
                message: "Runtime \(manifest.harness.version) 已完成激活，并通过启动检查。"
            )
        } catch {
            if let dataActivation {
                try? dataSlotManager.rollback(dataActivation, paths: paths)
            }
            if let activation {
                try? runtimeInstaller.rollback(activation: activation, paths: paths)
            }
            lastError = error.localizedDescription
            updateState = .failed(error.localizedDescription)
            phase = .failed("DeepSeek Harness 更新失败。\n\(error.localizedDescription)")

            if wasRunning, let previousInstallation {
                do {
                    let url = try await processController.start(
                        installation: previousInstallation,
                        paths: paths,
                        overlayURL: profileManager.overlayURLIfNeeded()
                    )
                    runtimePath = previousInstallation.executable.path
                    runtimeVersion = previousInstallation.version
                    phase = .ready(url)
                } catch {
                    lastError = "更新失败，旧 Runtime 也无法恢复：\(error.localizedDescription)"
                }
            }
        }
    }

    private func presentRuntimeActivationConfirmation(
        manifest: RuntimeManifest,
        artifactURL: URL
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认更新 DeepSeek Harness？"
        alert.informativeText = "版本：\(manifest.harness.version)\n\nartifact 已通过 HTTPS、大小和 SHA-256 校验，并暂存于：\n\(artifactURL.path)\n\n当前更新源不使用公钥签名，请确认该 feed 属于你信任的发布方。确认后将优雅停止当前 Harness，激活新 Runtime，并用当前插件 profile 做启动检查。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentUpdateAlert(_ result: RuntimeUpdateResult) {
        let alert = NSAlert()
        alert.messageText = "发现 Harness Runtime 更新"
        alert.informativeText = "候选版本：\(result.manifest.runtimeID)\n\n当前版本：\(result.currentRuntimeID ?? runtimeVersion ?? "unknown")\n\n请点击顶栏的圆形下载按钮下载并校验更新 artifact。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func promptForText(
        title: String,
        message: String,
        placeholder: String,
        allowsEmpty: Bool = false
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowsEmpty || !value.isEmpty ? value : nil
    }

    private func promptForPluginSelection(
        title: String,
        operation: String
    ) -> [HarnessPlugin] {
        guard !plugins.isEmpty else {
            presentInfoAlert(title: "没有已安装插件", message: "请先通过 Plugins > Install Plugin… 安装标准 Harness 插件。")
            return []
        }

        let selectionView = PluginSelectionAccessoryView(plugins: plugins)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "可单选、多选或点击“全选”。\(operation)不会删除 Harness 会话或其他用户数据。"
        alert.alertStyle = .informational
        alert.accessoryView = selectionView
        alert.addButton(withTitle: operation)
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }

        let selected = selectionView.selectedPlugins
        guard !selected.isEmpty else {
            presentInfoAlert(title: "未选择插件", message: "请至少选择一个插件后再执行\(operation)。")
            return []
        }
        return selected
    }

    private func promptForSecret(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let field = NSSecureTextField(string: "")
        field.placeholderString = "sk-…"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存并查询")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func confirmPluginMutation(operation: String, spec: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认\(operation) Harness 插件？"
        alert.informativeText = "目标：\(spec)\n\nLauncher 会把当前 web profile 复制到 staging，执行官方 dsh plugin 命令或 profile patch，并执行候选启动预检。插件可能包含本地代码和 lifecycle/build script；请确认来源可信。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func balanceAmount(for info: DeepSeekBalanceInfo) -> String {
        switch info.currency.uppercased() {
        case "CNY":
            return "¥\(info.totalBalance)"
        case "USD":
            return "$\(info.totalBalance)"
        default:
            return "\(info.totalBalance) \(info.currency)"
        }
    }
}

private extension AppPaths {
    var diagnosticsFile: URL {
        diagnostics.appendingPathComponent("last-diagnostics.txt")
    }
}
