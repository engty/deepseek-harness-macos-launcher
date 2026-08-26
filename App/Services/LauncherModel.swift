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
    @Published private(set) var appUpdateState: AppUpdateState = .idle
    @Published private(set) var balanceState: DeepSeekBalanceState = .notConfigured
    @Published private(set) var isBalanceConfigured = false
    /// True while a slot-mutating operation (plugin install/remove/start/stop,
    /// restart, Runtime update activation) is running. New such operations are
    /// rejected instead of interleaving, because concurrent operations would
    /// clone/activate the same data slot and silently lose user configuration.
    @Published private(set) var isOperationInProgress = false

    let paths: AppPaths
    private let locator: RuntimeLocator
    private let profileManager: ProfileManager
    private let processController: HarnessProcessController
    private let pluginRunner: PluginCommandRunner
    private let pluginCacheService: PluginCacheService
    private let updateService: RuntimeUpdateService
    private let appUpdateService: AppUpdateService
    private let runtimeInstaller: RuntimeArchiveInstaller
    private let toolchainInstaller: ToolchainInstaller
    private let dataSlotManager: DataSlotManager
    private let runtimePreflight: RuntimePreflightService
    private let defaultProfileInstaller: DefaultProfileInstaller
    private let balanceService: DeepSeekBalanceService
    private let deepSeekCredentialStore = DeepSeekCredentialStore()
    private let deepSeekRechargeURL = URL(string: "https://platform.deepseek.com/usage")!
    private let balanceKeychain = KeychainStore(
        service: AppPaths.bundleIdentifier + ".credentials.v2",
        account: DeepSeekCredentialStore.reference
    )
    private var latestManifest: RuntimeManifest?
    private var balanceRefreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var consecutiveCrashCount = 0
    /// Bumped whenever a user-facing operation changes the desired state.
    /// The delayed crash-recovery task only restarts Harness when the
    /// generation is unchanged, so a manual stop/restart/mutation in the
    /// meantime cancels the automatic recovery instead of "ghost restarting".
    private var operationGeneration = UUID()
    private var crashRecoveryTask: Task<Void, Never>?
    private var balanceRequestID = UUID()
    private var updateRequestID = UUID()

    init(
        paths: AppPaths = AppPaths(),
        locator: RuntimeLocator = RuntimeLocator()
    ) {
        self.paths = paths
        self.locator = locator
        profileManager = ProfileManager(paths: paths)
        processController = HarnessProcessController()
        pluginRunner = PluginCommandRunner()
        pluginCacheService = PluginCacheService()
        updateService = RuntimeUpdateService()
        appUpdateService = AppUpdateService()
        runtimeInstaller = RuntimeArchiveInstaller()
        toolchainInstaller = ToolchainInstaller()
        dataSlotManager = DataSlotManager()
        runtimePreflight = RuntimePreflightService()
        defaultProfileInstaller = DefaultProfileInstaller()
        balanceService = DeepSeekBalanceService()
        processController.onUnexpectedTermination = { [weak self] output in
            self?.handleUnexpectedTermination(output)
        }
        do {
            try paths.prepare()
            dataSlotManager.recoverPendingTransaction(paths: paths)
            plugins = profileManager.refresh()
            // Restore the binding state from Keychain. The item is created
            // without an access-control prompt, so a non-interactive read is
            // safe at launch and keeps the user's API key bound across relaunches.
            do {
                isBalanceConfigured = try synchronizeDeepSeekCredential() != nil
            } catch {
                // Keep launch available if a malformed credential document is
                // present; the next explicit key replacement repairs it.
                isBalanceConfigured = balanceKeychain.read(allowInteraction: false)
                    .map { !$0.isEmpty } ?? false
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    var endpointURL: URL? {
        if case .ready(let url) = phase { return url }
        return nil
    }

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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
            dataSlotManager.recoverPendingTransaction(paths: paths)
            let installation = try locator.locate()
            runtimePath = installation.executable.path
            runtimeVersion = installation.version
            try defaultProfileInstaller.seedIfNeeded(paths: paths, runtimeRoot: installation.root)
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
        bumpOperationGeneration()
        crashRecoveryTask?.cancel()
        crashRecoveryTask = nil
        // A plugin command must not outlive the launcher: pnpm and lifecycle
        // scripts would otherwise keep running as orphans.
        pluginRunner.cancelActiveCommand()
        guard processController.isRunning else {
            phase = .stopped
            return
        }
        phase = .busy("Stopping Harness")
        await processController.stop()
        phase = .stopped
    }

    func restart() async {
        guard beginExclusiveOperation() else { return }
        defer { endExclusiveOperation() }
        await stop()
        await start()
    }

    /// Serializes every operation that clones or swaps the active data slot
    /// (plugin mutations, enable/disable, restart, Runtime update activation).
    /// Overlapping operations used to be possible because each menu entry
    /// launched its own `Task`; two such tasks could clone the same active
    /// slot and then activate their own candidates, silently losing one
    /// operation's result or leaving the active slot half-switched.
    private func beginExclusiveOperation(notifyBusy: Bool = true) -> Bool {
        guard !isOperationInProgress else {
            if notifyBusy {
                presentInfoAlert(
                    title: "已有操作正在进行",
                    message: "请等待当前 DeepSeek Harness 操作完成后再试。"
                )
            }
            return false
        }
        isOperationInProgress = true
        bumpOperationGeneration()
        return true
    }

    private func endExclusiveOperation() {
        isOperationInProgress = false
    }

    private func bumpOperationGeneration() {
        operationGeneration = UUID()
    }

    func setPluginEnabled(_ plugin: HarnessPlugin, enabled: Bool) async {
        await setPluginsEnabled([plugin], enabled: enabled)
    }

    func setPluginsEnabled(_ selectedPlugins: [HarnessPlugin], enabled: Bool) async {
        guard !selectedPlugins.isEmpty else { return }
        guard beginExclusiveOperation() else { return }
        defer { endExclusiveOperation() }
        let wasRunning = processController.isRunning
        selectedPlugins.forEach {
            pluginOperationStates[$0.id] = enabled ? .starting : .stopping
        }
        let names = selectedPlugins.map(\.name).joined(separator: ", ")
        phase = .busy(enabled ? "正在启用 \(names)" : "正在停用 \(names)")
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
            title: "安装 Harness 插件",
            message: "粘贴官方安装命令。只接受 dsh plugin --profile web add <plugin-spec>，不会通过 shell 执行。",
            placeholder: "例如 dsh plugin --profile web add dsh-llm-codex"
        ) else { return }
        do {
            let arguments = try PluginCommandParser.parseInstallCommand(command)
            let specs = Array(arguments.dropFirst()).joined(separator: " ")
            let installation = try locator.locate()
            let dependencyPlan = try pluginRunner.dependencyPlan(
                installation: installation,
                paths: paths,
                arguments: arguments
            )
            guard confirmPluginMutation(
                operation: "安装",
                spec: specs,
                dependencyPlan: dependencyPlan
            ) else { return }
            Task {
                await mutatePlugin(
                    arguments: arguments,
                    operation: "正在安装插件",
                    userOperation: "安装",
                    dependencyPlan: dependencyPlan
                )
            }
        } catch {
            presentInfoAlert(title: "无法准备插件安装", message: error.localizedDescription)
        }
    }

    func removePluginPrompt() {
        let selected = promptForPluginSelection(title: "卸载 Harness 插件", operation: "卸载")
        guard !selected.isEmpty else { return }
        let names = selected.map(\.name).joined(separator: ", ")
        let arguments = ["remove"] + selected.map(\.id)
        do {
            let installation = try locator.locate()
            let dependencyPlan = try pluginRunner.dependencyPlan(
                installation: installation,
                paths: paths,
                arguments: arguments
            )
            guard confirmPluginMutation(
                operation: "卸载",
                spec: names,
                dependencyPlan: dependencyPlan
            ) else { return }
            Task {
                await mutatePlugin(
                    arguments: arguments,
                    operation: "正在卸载插件",
                    userOperation: "卸载",
                    dependencyPlan: dependencyPlan,
                    cleanupPluginsAfterRemoval: selected
                )
            }
        } catch {
            presentInfoAlert(title: "无法准备插件卸载", message: error.localizedDescription)
        }
    }

    func stopPluginPrompt() {
        let refresh = profileManager.refresh()
        plugins = refresh
        let stoppablePlugins = refresh.filter(\.canBeDisabled)
        guard !stoppablePlugins.isEmpty else {
            presentInfoAlert(
                title: "没有可停用插件",
                message: "当前已安装插件没有提供 Harness bundle patch，因此只能通过“卸载插件”移除。"
            )
            return
        }
        let selected = promptForPluginSelection(
            title: "停用 Harness 插件",
            operation: "停用",
            plugins: stoppablePlugins
        )
        guard !selected.isEmpty else { return }
        let names = selected.map(\.name).joined(separator: ", ")
        guard confirmPluginMutation(operation: "停用", spec: names) else { return }
        Task { await setPluginsEnabled(selected, enabled: false) }
    }

    func clearPluginCachePrompt() {
        let entries = pluginCacheService.entries(for: profileManager.refresh(), paths: paths)
        guard !entries.isEmpty else {
            presentInfoAlert(title: "没有可清理的缓存", message: "当前没有发现插件或共享 pnpm 缓存。")
            return
        }

        let selectionView = PluginCacheSelectionAccessoryView(entries: entries)
        let alert = NSAlert()
        alert.messageText = "清理插件缓存"
        alert.informativeText = "可选择一个或多个插件。共享 pnpm 缓存只会回收未被项目使用的内容，不会删除其他项目的 node_modules，但其他项目下次安装可能需要重新下载。"
        alert.accessoryView = selectionView
        alert.addButton(withTitle: "清理")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = selectionView.selectedEntries
        guard !selected.isEmpty else {
            presentInfoAlert(title: "未选择缓存", message: "请至少选择一项缓存后再清理。")
            return
        }
        Task { await clearPluginCaches(selected) }
    }

    func checkForUpdates() {
        Task { await checkForUpdates(presentResult: true) }
    }

    func checkForAppUpdates() {
        Task { await checkForAppUpdates(presentResult: true) }
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
            title: isBalanceConfigured ? "更换 DeepSeek API Key" : "配置 DeepSeek API Key",
            message: "同一个 API Key 会同时绑定 DeepSeek 模型和余额查询：一份保存到 macOS Keychain，另一份同步到 Harness 标准凭据文件。不会写入日志或诊断文件。"
        ) else { return }

        do {
            // The credential FILE is Harness's source of truth, so write and
            // verify it first. A Keychain failure afterwards must not leave
            // the file silently un-updated while the UI claims success.
            try deepSeekCredentialStore.write(apiKey, to: paths.dshHome)
            SensitiveDataRedactor.registerLiteralSecret(apiKey)
            do {
                try balanceKeychain.save(apiKey)
            } catch {
                AppLogger.launcher.error(
                    "DeepSeek API Key saved to the credential file but not to Keychain: \(error.localizedDescription)"
                )
            }
            isBalanceConfigured = true
            scheduleBalanceRefresh()
        } catch {
            balanceState = .failed(error.localizedDescription)
            presentInfoAlert(title: "无法保存 DeepSeek API Key", message: error.localizedDescription)
        }
    }

    func refreshBalance() async {
        let requestID = UUID()
        balanceRequestID = requestID
        let apiKey: String?
        do {
            apiKey = try synchronizeDeepSeekCredential()
        } catch {
            balanceState = .failed(error.localizedDescription)
            return
        }

        guard let apiKey, !apiKey.isEmpty else {
            // Do not forget a valid binding just because a transient Keychain
            // read failed. Only an explicit replacement changes the binding.
            isBalanceConfigured = false
            balanceState = .notConfigured
            return
        }

        balanceState = .loading
        do {
            let response = try await balanceService.fetch(apiKey: apiKey)
            // A slow earlier request must not overwrite the result of a newer
            // one (for example right after the user replaced the key).
            guard requestID == balanceRequestID else { return }
            balanceState = .available(response.balanceInfos)
        } catch {
            guard requestID == balanceRequestID else { return }
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

    var balanceAmountDisplayText: String? {
        guard case .available(let infos) = balanceState else { return nil }
        let amounts = infos.map { balanceAmount(for: $0) }
        return amounts.isEmpty ? nil : amounts.joined(separator: " / ")
    }

    var balanceTone: DeepSeekBalanceTone {
        guard case .available(let infos) = balanceState else { return .unknown }
        return DeepSeekBalanceTone(balanceInfos: infos)
    }

    var hasAvailableRuntimeUpdate: Bool {
        if case .available = updateState { return true }
        return false
    }

    private func clearPluginCaches(_ entries: [PluginCacheEntry]) async {
        guard beginExclusiveOperation() else { return }
        defer { endExclusiveOperation() }

        let wasRunning = processController.isRunning
        phase = .busy("正在清理插件缓存")
        if wasRunning {
            await processController.stop()
        }

        let installation = try? locator.locate()
        let report = await pluginCacheService.cleanup(
            entries: entries,
            paths: paths,
            installation: installation
        )
        if wasRunning {
            await start()
        } else {
            phase = .stopped
        }
        presentInfoAlert(title: "插件缓存清理完成", message: report.summary)
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

    private func mutatePlugin(
        arguments: [String],
        operation: String,
        userOperation: String,
        dependencyPlan: PluginDependencyPlan,
        additionalToolRequirements: [ToolchainRequirement] = [],
        allowedBuildScripts: [String] = [],
        cleanupPluginsAfterRemoval: [HarnessPlugin] = [],
        restartAfterMutation: Bool? = nil,
        attemptDependencyRecovery: Bool = true,
        attemptBuildScriptApproval: Bool = true,
        holdsExclusiveLock: Bool = false
    ) async {
        if !holdsExclusiveLock {
            guard beginExclusiveOperation() else { return }
        }
        defer { if !holdsExclusiveLock { endExclusiveOperation() } }

        guard let installation = try? locator.locate() else {
            let message = "插件管理需要可执行的 Harness Runtime。"
            phase = .runtimeMissing(message)
            lastError = message
            presentInfoAlert(title: "插件\(userOperation)失败", message: message)
            return
        }

        let wasRunning = restartAfterMutation ?? processController.isRunning
        phase = .busy(operation)
        if restartAfterMutation == nil, wasRunning {
            await processController.stop()
        }

        do {
            _ = try await pluginRunner.mutateProfile(
                installation: installation,
                paths: paths,
                arguments: arguments,
                dependencyPlan: dependencyPlan,
                allowedBuildScripts: allowedBuildScripts
            )
            var cleanupSummary: String?
            if !cleanupPluginsAfterRemoval.isEmpty {
                let cleanup = await pluginCacheService.cleanupAfterUninstall(
                    pluginIDs: cleanupPluginsAfterRemoval.map(\.id),
                    paths: paths,
                    installation: installation
                )
                cleanupSummary = cleanup.summary
            }
            plugins = profileManager.refresh()
            if wasRunning {
                await start()
                guard phase.isReady else {
                    let restartError = lastError ?? "Harness 重启失败。"
                    lastError = "插件\(userOperation)已完成，但 Harness 重启失败：\(restartError)"
                    presentInfoAlert(
                        title: "插件\(userOperation)完成，但 Harness 未启动",
                        message: lastError ?? restartError
                    )
                    return
                }
            } else {
                phase = .stopped
            }
            lastError = nil
            AppLogger.plugins.info("Plugin \(userOperation, privacy: .public) succeeded")
            let completionText = "DeepSeek Harness 的 web profile 配置已更新。"
            presentInfoAlert(
                title: "插件\(userOperation)完成",
                message: cleanupSummary.map { completionText + " 清理结果：" + $0 } ?? completionText
            )
        } catch {
            let message = error.localizedDescription
            if attemptBuildScriptApproval,
               case let PluginCommandError.buildScriptsRequireApproval(packages, output) = error {
                guard confirmBuildScriptApproval(packages: packages) else {
                    await finishPluginFailure(
                        output,
                        userOperation: userOperation,
                        restartAfterMutation: wasRunning
                    )
                    return
                }
                phase = .busy("正在准备 pnpm 构建权限")
                do {
                    let retryPlan = try pluginRunner.dependencyPlan(
                        installation: installation,
                        paths: paths,
                        arguments: arguments,
                        additionalRequirements: additionalToolRequirements
                    )
                    await mutatePlugin(
                        arguments: arguments,
                        operation: operation,
                        userOperation: userOperation,
                        dependencyPlan: retryPlan,
                        additionalToolRequirements: additionalToolRequirements,
                        allowedBuildScripts: packages,
                        cleanupPluginsAfterRemoval: cleanupPluginsAfterRemoval,
                        restartAfterMutation: wasRunning,
                        attemptDependencyRecovery: true,
                        attemptBuildScriptApproval: false,
                        holdsExclusiveLock: true
                    )
                    return
                } catch {
                    await finishPluginFailure(
                        error.localizedDescription,
                        userOperation: userOperation,
                        restartAfterMutation: wasRunning
                    )
                    return
                }
            }
            if attemptDependencyRecovery,
               let requirement = PluginDependencyService.installableRequirement(from: message),
               let manifest = ToolchainCatalog.bundled.manifest(for: requirement) {
                let installPlan = ToolchainInstallPlan(
                    manifest: manifest,
                    destination: paths.toolchain
                        .appendingPathComponent(manifest.id, isDirectory: true)
                        .appendingPathComponent(manifest.version, isDirectory: true)
                )
                guard confirmToolchainInstallation(installPlan) else {
                    await finishPluginFailure(
                        message,
                        userOperation: userOperation,
                        restartAfterMutation: wasRunning
                    )
                    return
                }
                phase = .busy("正在准备 \(manifest.id)")
                do {
                    _ = try await toolchainInstaller.install(
                        requirement: requirement,
                        paths: paths,
                        progress: { completed, total in
                            AppLogger.plugins.info("Private dependency download \(completed)/\(total)")
                        }
                    )
                    let retryPlan = try pluginRunner.dependencyPlan(
                        installation: installation,
                        paths: paths,
                        arguments: arguments,
                        additionalRequirements: additionalToolRequirements + [requirement]
                    )
                    await mutatePlugin(
                        arguments: arguments,
                        operation: operation,
                        userOperation: userOperation,
                        dependencyPlan: retryPlan,
                        additionalToolRequirements: additionalToolRequirements + [requirement],
                        cleanupPluginsAfterRemoval: cleanupPluginsAfterRemoval,
                        restartAfterMutation: wasRunning,
                        attemptDependencyRecovery: false,
                        holdsExclusiveLock: true
                    )
                    return
                } catch {
                    await finishPluginFailure(
                        error.localizedDescription,
                        userOperation: userOperation,
                        restartAfterMutation: wasRunning
                    )
                    return
                }
            }
            await finishPluginFailure(
                message,
                userOperation: userOperation,
                restartAfterMutation: wasRunning
            )
        }
    }

    private func finishPluginFailure(
        _ message: String,
        userOperation: String,
        restartAfterMutation: Bool
    ) async {
        lastError = message
        phase = .failed(message)
        if restartAfterMutation {
            await start()
        }
        // start() clears transient state on a successful restart; retain the
        // mutation error so it remains visible in the launcher.
        lastError = message
        AppLogger.plugins.error(
            "Plugin \(userOperation, privacy: .public) failed: \(message, privacy: .public)"
        )
        presentInfoAlert(title: "插件\(userOperation)失败", message: message)
    }

    private func handleUnexpectedTermination(_ output: String) {
        guard phase.isReady || phase == .busy("Starting DeepSeek Harness") else { return }
        consecutiveCrashCount += 1
        let message = output.isEmpty ? "Harness sidecar unexpectedly exited." : output
        lastError = message
        phase = .failed("Harness sidecar unexpectedly exited.\n\(message)")
        let generation = operationGeneration
        guard consecutiveCrashCount <= 3 else {
            crashRecoveryTask?.cancel()
            crashRecoveryTask = Task { [weak self] in
                await self?.recoverLastKnownGoodRuntime()
            }
            return
        }
        let retryDelay = UInt64(consecutiveCrashCount) * 1_000_000_000
        crashRecoveryTask?.cancel()
        crashRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: retryDelay)
            guard !Task.isCancelled, let self else { return }
            // Only restart when nothing else changed the desired state while
            // we slept; otherwise the automatic recovery would override a
            // manual stop/restart/mutation ("ghost restart").
            guard self.operationGeneration == generation else { return }
            await self.start()
        }
    }

    private func recoverLastKnownGoodRuntime() async {
        guard beginExclusiveOperation(notifyBusy: false) else {
            AppLogger.launcher.error(
                "Skipped last-known-good Runtime recovery because another operation is in progress."
            )
            return
        }
        defer { endExclusiveOperation() }
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

    /// Keep the native balance lookup and Harness's Web Models page on one
    /// credential. The standard Harness file is the source of truth when it
    /// already contains a key (for example, the user entered it in Settings →
    /// Models). Startup never writes back to Keychain, because updating an old
    /// legacy item can trigger an authorization sheet after an App replacement.
    /// The Keychain value is used only as a fallback when the file is missing.
    private func synchronizeDeepSeekCredential() throws -> String? {
        let fileValue: String?
        do {
            fileValue = try deepSeekCredentialStore.read(from: paths.dshHome)
        } catch {
            // A malformed credential document must not brick the balance
            // feature while a valid Keychain copy exists: fall back and
            // repair the file below.
            AppLogger.launcher.error(
                "Credential file is unreadable, falling back to Keychain: \(error.localizedDescription)"
            )
            fileValue = nil
        }
        if let fileValue, !fileValue.isEmpty {
            SensitiveDataRedactor.registerLiteralSecret(fileValue)
            isBalanceConfigured = true
            return fileValue
        }

        // Only the current credential item is used as a fallback when the
        // private Harness credential file is missing. The old service is
        // deliberately never queried during startup: even a non-interactive
        // read can surface an authorization sheet for an item owned by a
        // previous ad-hoc App signature.
        let keychainValue = balanceKeychain.read(allowInteraction: false)

        guard let keychainValue, !keychainValue.isEmpty else {
            isBalanceConfigured = false
            return nil
        }
        try deepSeekCredentialStore.write(keychainValue, to: paths.dshHome)
        SensitiveDataRedactor.registerLiteralSecret(keychainValue)
        isBalanceConfigured = true
        return keychainValue
    }

    private func checkForUpdates(presentResult: Bool) async {
        let requestID = UUID()
        updateRequestID = requestID
        updateState = .checking
        do {
            let result = try await updateService.check(currentHarnessVersion: runtimeVersion)
            guard requestID == updateRequestID else { return }
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
            guard requestID == updateRequestID else { return }
            latestManifest = nil
            updateState = .failed(error.localizedDescription)
            if presentResult {
                let title: String
                if let runtimeError = error as? RuntimeManifestError,
                   runtimeError == .feedNotConfigured {
                    title = "Harness Runtime 更新源未配置"
                } else {
                    title = "无法检查 Harness Runtime 更新"
                }
                presentInfoAlert(title: title, message: error.localizedDescription)
            }
        }
    }

    private func checkForAppUpdates(presentResult: Bool) async {
        appUpdateState = .checking
        do {
            let result = try await appUpdateService.check(currentVersion: currentAppVersion)
            if result.isUpdateAvailable {
                appUpdateState = .available(version: result.latestVersion, url: result.releaseURL)
                if presentResult { presentAppUpdateAlert(result) }
            } else {
                appUpdateState = .upToDate
                if presentResult {
                    presentInfoAlert(
                        title: "DeepSeek Harness App 已是最新",
                        message: "当前版本：\(result.currentVersion)"
                    )
                }
            }
        } catch {
            appUpdateState = .failed(error.localizedDescription)
            if presentResult {
                presentInfoAlert(
                    title: "无法检查 DeepSeek Harness App 更新",
                    message: error.localizedDescription
                )
            }
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
        guard beginExclusiveOperation() else { return }
        defer { endExclusiveOperation() }
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
            let candidateSlot = try await dataSlotManager.cloneActiveSlot(paths: paths)
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
            // Every successful update used to leave the entire previous
            // Runtime tree on disk forever; remove versions that are no
            // longer referenced by any pointer.
            runtimeInstaller.cleanupOrphanedRuntimes(paths: paths)
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

    private func presentAppUpdateAlert(_ result: AppUpdateResult) {
        let alert = NSAlert()
        alert.messageText = "发现 DeepSeek Harness App 更新"
        alert.informativeText = "当前版本：\(result.currentVersion)\n最新版本：\(result.latestVersion)\n\n此更新会替换外层 macOS App；底层 Harness Runtime 由版本号旁的下载按钮单独管理。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(result.releaseURL)
        }
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
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowsEmpty || !value.isEmpty ? value : nil
    }

    private func promptForPluginSelection(
        title: String,
        operation: String,
        plugins candidates: [HarnessPlugin]? = nil
    ) -> [HarnessPlugin] {
        let currentPlugins = profileManager.refresh()
        plugins = currentPlugins
        let availablePlugins = candidates ?? currentPlugins
        guard !availablePlugins.isEmpty else {
            presentInfoAlert(title: "没有已安装插件", message: "请先通过“插件 > 安装插件…”安装标准 Harness 插件。")
            return []
        }

        let selectionView = PluginSelectionAccessoryView(plugins: availablePlugins)
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
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "充值")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(deepSeekRechargeURL)
            return nil
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func confirmPluginMutation(
        operation: String,
        spec: String,
        dependencyPlan: PluginDependencyPlan? = nil
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认\(operation) Harness 插件？"
        let dependencyText = dependencyPlan.map { "\n\n\($0.confirmationText)" } ?? ""
        let cleanupText = operation == "卸载"
            ? "\n\n卸载完成后会清理 App 可确定归属的插件缓存，并回收当前用户 pnpm 中未被使用的共享缓存（其他项目下次安装可能需要重新下载）。"
            : ""
        alert.informativeText = "目标：\(spec)\n\n应用会把当前 web profile 复制到临时目录，执行官方 dsh plugin 命令或配置补丁，并执行候选启动预检。插件可能包含本地代码和生命周期/构建脚本；请确认来源可信。\(dependencyText)\(cleanupText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmToolchainInstallation(_ plan: ToolchainInstallPlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "插件需要额外依赖"
        alert.informativeText = """
        插件安装报告缺少一个受控的基础工具。Launcher 只会安装下面列出的固定版本，不会执行插件提供的任意命令。

        \(plan.confirmationText)

        下载完成后会进行 HTTPS、大小、SHA-256 和可执行文件校验；依赖只对本 App 的 Harness 子进程生效。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装依赖并继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmBuildScriptApproval(packages: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "插件需要执行安装构建脚本"
        alert.informativeText = """
        pnpm 为安全起见阻止了以下插件的 prepare/build 构建脚本：
        \(packages.map { "• \($0)" }.joined(separator: "\n"))

        继续后，应用只会把这些精确的包名写入临时 profile 的 pnpm-workspace.yaml allowBuilds 配置，然后重新执行官方安装命令。不会执行 README 中的任意命令，也不会修改用户全局 pnpm 配置。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "允许并重试")
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
