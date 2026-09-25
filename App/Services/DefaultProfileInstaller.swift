import Foundation

/// Seeds a fresh App-owned Harness profile with the plugin bundle that ships
/// in the Runtime. Existing profiles are never modified, so removing the
/// default plugin remains a durable user choice.
struct DefaultProfileInstaller {
    private let fileManager: FileManager

    private enum RuntimeCompatibilityError: LocalizedError {
        case runtimePackageMissing(String)
        case quarantineFailed(String)
        case unsupportedPluginCompatibility(String)

        var errorDescription: String? {
            switch self {
            case .runtimePackageMissing(let package):
                return "当前 Runtime 缺少官方模块 \(package)，无法完成兼容性修复。"
            case .quarantineFailed(let message):
                return "无法隔离旧版 Runtime 模块：\(message)"
            case .unsupportedPluginCompatibility(let plugin):
                return "插件 \(plugin) 使用了当前 Runtime 已移除的设置接口，且无法安全自动适配。"
            }
        }
    }

    private static let betterDshPetAdapterFiles = [
        "lib/index.js",
        "lib/client.js",
        "lib/pet-helper-process.js",
        "runtime/electron-helper/main.js",
        "runtime/electron-helper/preload.js",
        "runtime/electron-helper/renderer.js",
        "scripts/ensure-electron.mjs",
        "cordis.patch.yml"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Keeps profile-hoisted official modules aligned with the active Runtime.
    /// Node resolves modules in the profile before the Runtime's package tree,
    /// so an old first-party package can shadow its compatible Runtime copy.
    /// This is especially important for `dsh-llm` (which owns `/api/llm/*`)
    /// and `dsh-settings`, whose provider lifecycle changed after rc.6.
    ///
    /// The previous directory is moved into an App-owned backup instead of
    /// being deleted. The replacement is an absolute link to the exact
    /// Runtime package selected for this launch, so future Runtime updates
    /// can safely re-point it without touching user plugin settings.
    @discardableResult
    func syncRuntimeCoreModuleCompatibility(
        paths: AppPaths,
        runtimeRoot: URL
    ) throws -> Bool {
        try syncRuntimeCoreModuleCompatibility(
            profileWeb: paths.profileWeb,
            runtimeRoot: runtimeRoot,
            quarantineRoot: paths.backups
                .appendingPathComponent("runtime-compatibility", isDirectory: true)
        )
    }

    /// Staged-slot variant used during Runtime update preflight. Keeping the
    /// quarantine inside the candidate slot makes the clone self-contained;
    /// it is moved together with the profile only after the candidate boots.
    @discardableResult
    func syncRuntimeCoreModuleCompatibility(
        profileWeb: URL,
        runtimeRoot: URL,
        quarantineRoot: URL
    ) throws -> Bool {
        var changed = try syncRuntimeCoreModule(
            named: "dsh-llm",
            profileWeb: profileWeb,
            runtimeRoot: runtimeRoot,
            quarantineRoot: quarantineRoot,
            installWhenMissing: true
        )

        // Profiles from rc.6 may contain dsh-settings 0.1.0-rc.6. Its service
        // contract predates `load()`, while newer Runtime settings providers
        // call that method during Cordis initialization. Keep the user's
        // profile copy as a backup, but let the selected Runtime supply the
        // matching core module. Older Runtimes without dsh-settings are left
        // untouched for backwards compatibility.
        if try syncRuntimeCoreModule(
            named: "dsh-settings",
            profileWeb: profileWeb,
            runtimeRoot: runtimeRoot,
            quarantineRoot: quarantineRoot,
            installWhenMissing: false
        ) {
            changed = true
        }
        return changed
    }

    private func syncRuntimeCoreModule(
        named package: String,
        profileWeb: URL,
        runtimeRoot: URL,
        quarantineRoot: URL,
        installWhenMissing: Bool
    ) throws -> Bool {
        let runtimePackage: URL
        do {
            runtimePackage = try runtimePackageDirectory(named: package, runtimeRoot: runtimeRoot)
        } catch RuntimeCompatibilityError.runtimePackageMissing(_) where !installWhenMissing {
            return false
        }

        let activePackage = profileWeb
            .appendingPathComponent("node_modules/@deepseek-ai/\(package)", isDirectory: true)
        let activeExists = fileManager.fileExists(atPath: activePackage.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: activePackage.path)) != nil
        guard activeExists || installWhenMissing else { return false }

        let activeResolved = activePackage.resolvingSymlinksInPath().standardizedFileURL.path
        let runtimeResolved = runtimePackage.standardizedFileURL.path
        guard !activeExists || activeResolved != runtimeResolved else { return false }

        if activeExists {
            let version = packageNameAndVersion(
                at: activePackage.appendingPathComponent("package.json")
            )?.1 ?? "unknown"
            let backup = quarantineRoot
                .appendingPathComponent(
                    "\(package)-\(safePathComponent(version))-\(UUID().uuidString)",
                    isDirectory: true
                )
            do {
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: activePackage, to: backup)
            } catch {
                throw RuntimeCompatibilityError.quarantineFailed(error.localizedDescription)
            }
        }

        do {
            try fileManager.createDirectory(
                at: activePackage.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(
                atPath: activePackage.path,
                withDestinationPath: runtimePackage.path
            )
        } catch {
            throw RuntimeCompatibilityError.quarantineFailed(error.localizedDescription)
        }
        AppLogger.plugins.info(
            "Aligned profile @deepseek-ai/\(package) with the active Runtime."
        )
        return true
    }

    /// dsh-llm-codex 0.1.1 uses two Runtime APIs that changed independently:
    /// the settings-section helper was replaced by `ctx.settings.register`,
    /// and the LLM call identifier was renamed from `CallId` to `ToolCallId`.
    /// Adapt only these known import/call sites based on the selected Runtime,
    /// and reverse each adapter when an older Runtime is selected.
    @discardableResult
    func syncDshLlmCodexCompatibility(
        paths: AppPaths,
        runtimeRoot: URL
    ) throws -> Bool {
        try syncDshLlmCodexCompatibility(
            profileWeb: paths.profileWeb,
            runtimeRoot: runtimeRoot
        )
    }

    @discardableResult
    func syncDshLlmCodexCompatibility(
        profileWeb: URL,
        runtimeRoot: URL
    ) throws -> Bool {
        var changed = try syncDshLlmCodexSettingsCompatibility(
            profileWeb: profileWeb,
            runtimeRoot: runtimeRoot
        )
        let sourceURL = profileWeb
            .appendingPathComponent("node_modules/dsh-llm-codex/lib/translate.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return changed }
        let runtimePackage = try runtimePackageDirectory(
            named: "dsh-llm",
            runtimeRoot: runtimeRoot
        )
        let runtimeExports = try String(
            contentsOf: runtimePackage.appendingPathComponent("lib/index.js"),
            encoding: .utf8
        )
        let modernRuntime = runtimeExports.contains("ToolCallId")
        let legacyRuntime = !modernRuntime && runtimeExports.contains("CallId")
        let adapted: String
        if modernRuntime,
           source.contains("import { CallId, LlmError, EMPTY_RESPONSE_CODE }") {
            adapted = source
                .replacingOccurrences(
                    of: "import { CallId, LlmError, EMPTY_RESPONSE_CODE }",
                    with: "import { ToolCallId, LlmError, EMPTY_RESPONSE_CODE }"
                )
                .replacingOccurrences(of: "CallId(", with: "ToolCallId(")
        } else if legacyRuntime,
                  source.contains("import { ToolCallId, LlmError, EMPTY_RESPONSE_CODE }") {
            adapted = source
                .replacingOccurrences(
                    of: "import { ToolCallId, LlmError, EMPTY_RESPONSE_CODE }",
                    with: "import { CallId, LlmError, EMPTY_RESPONSE_CODE }"
                )
                .replacingOccurrences(of: "ToolCallId(", with: "CallId(")
        } else {
            return changed
        }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info(
            "Aligned dsh-llm-codex with the active Runtime LLM identifier API."
        )
        changed = true
        return changed
    }

    private func syncDshLlmCodexSettingsCompatibility(
        profileWeb: URL,
        runtimeRoot: URL
    ) throws -> Bool {
        let sourceURL = profileWeb
            .appendingPathComponent("node_modules/dsh-llm-codex/lib/index.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }

        let runtimeSettings = try runtimePackageDirectory(
            named: "dsh-settings",
            runtimeRoot: runtimeRoot
        )
        let runtimeExports = try String(
            contentsOf: runtimeSettings.appendingPathComponent("lib/index.js"),
            encoding: .utf8
        )
        let hasLegacySettingsHelpers = runtimeExports.contains("installSettingsSection")
            && runtimeExports.contains("settingsNamespace")

        let legacyImport = "import { installSettingsSection, settingsNamespace } from '@deepseek-ai/dsh-settings';"
        let legacyNamespace = "const NS = settingsNamespace('llm-codex');"
        let modernNamespace = "const NS = 'llm-codex';"
        let legacyIntegration = #"""
          installSettingsSection(ctx, NS, Config, config, {
            setSource: (source) => {
              current = source;
            },
            onChange: () => {
              // 设置段变化后重注册路由,保持注册事实与配置一致
              registration.replace([PROVIDER]);
            },
          });
        """#
        let modernIntegration = #"""
          const isSettingsConsumerUnloading = () => ctx.fiber.state === 5 || ctx.fiber.state === 4;
          ctx.inject(['settings'], (sctx) => {
            const scope = sctx.settings.register(NS, Config, { base: config });
            current = () => scope.get();
            sctx.effect(() => () => {
              if (isSettingsConsumerUnloading()) return;
              current = () => config;
              registration.replace([PROVIDER]);
            });
            scope.watch(() => {
              if (isSettingsConsumerUnloading()) return;
              registration.replace([PROVIDER]);
            });
            registration.replace([PROVIDER]);
          });
        """#

        if hasLegacySettingsHelpers {
            guard source.contains(modernIntegration) else { return false }
            let restored = source
                .replacingOccurrences(of: modernIntegration, with: legacyIntegration)
                .replacingOccurrences(of: modernNamespace, with: legacyNamespace)
            let withImport = restored.replacingOccurrences(
                of: "import z from '@deepseek-ai/schemastery';",
                with: "import z from '@deepseek-ai/schemastery';\n\(legacyImport)"
            )
            guard withImport != source else { return false }
            try withImport.write(to: sourceURL, atomically: true, encoding: .utf8)
            AppLogger.plugins.info("Restored dsh-llm-codex legacy settings API compatibility.")
            return true
        }

        guard source.contains(legacyImport) else { return false }
        guard source.contains(legacyIntegration), source.contains(legacyNamespace) else {
            throw RuntimeCompatibilityError.unsupportedPluginCompatibility("dsh-llm-codex")
        }

        let adapted = source
            .replacingOccurrences(of: "\(legacyImport)\n", with: "")
            .replacingOccurrences(of: legacyNamespace, with: modernNamespace)
            .replacingOccurrences(of: legacyIntegration, with: modernIntegration)
        guard adapted != source else { return false }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info("Aligned dsh-llm-codex with the active Runtime settings API.")
        return true
    }

    /// Recent dsh-mnemon releases still read the former `session.events` array from
    /// its lifecycle hooks. Modern Harness Runtimes replaced that property
    /// with `snapshotEvents()`. Mnemon reads the event log throughout a
    /// session, so every known read site is routed through one small
    /// compatibility helper. The helper keeps old Runtimes working and
    /// returns an empty history only when a malformed session provides
    /// neither contract.
    @discardableResult
    func syncDshMnemonSessionCompatibility(paths: AppPaths) throws -> Bool {
        try syncDshMnemonSessionCompatibility(profileWeb: paths.profileWeb)
    }

    /// Applies the Mnemon session-log bridge to either the active profile or
    /// an isolated candidate profile used by plugin and Runtime preflight.
    @discardableResult
    func syncDshMnemonSessionCompatibility(profileWeb: URL) throws -> Bool {
        let packageDirectory = profileWeb
            .appendingPathComponent("node_modules/dsh-mnemon", isDirectory: true)
            .resolvingSymlinksInPath()
        let manifestURL = packageDirectory.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let identity = packageNameAndVersion(at: manifestURL),
              identity.0 == "dsh-mnemon" else {
            return false
        }

        let sourceURL = packageDirectory.appendingPathComponent("lib/index.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let adapted = Self.adaptDshMnemonSessionSource(source),
              adapted != source else {
            return false
        }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info(
            "Applied dsh-mnemon session-history compatibility."
        )
        return true
    }

    @discardableResult
    func seedIfNeeded(paths: AppPaths, runtimeRoot: URL) throws -> Bool {
        let manifestURL = paths.profileWeb.appendingPathComponent("package.json")
        guard !fileManager.fileExists(atPath: manifestURL.path) else { return false }

        let bundledProfile = runtimeRoot
            .appendingPathComponent("default-profile", isDirectory: true)
            .appendingPathComponent("profiles/web", isDirectory: true)
        let bundledManifest = bundledProfile.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: bundledManifest.path) else { return false }

        let stagingRoot = paths.caches
            .appendingPathComponent("default-profile-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: bundledProfile, to: stagingRoot)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try fileManager.createDirectory(
            at: paths.profileWeb.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: stagingRoot, to: paths.profileWeb)
        AppLogger.plugins.info("Seeded the bundled default Harness web profile.")
        return true
    }

    /// Applies the bundled macOS adapter to an existing better-dsh-pet profile.
    /// Existing profiles are deliberately preserved, but the platform adapter
    /// must be refreshed after an App update; otherwise an older helper would
    /// continue using Windows-only code and ignore new persistence fixes.
    @discardableResult
    func syncBetterDshPetAdapter(paths: AppPaths, runtimeRoot: URL) throws -> Bool {
        try syncBetterDshPetAdapter(profileWeb: paths.profileWeb, runtimeRoot: runtimeRoot)
    }

    @discardableResult
    func syncBetterDshPetAdapter(profileWeb: URL, runtimeRoot: URL) throws -> Bool {
        let bundledPackage = runtimeRoot
            .appendingPathComponent("default-profile/profiles/web/node_modules/better-dsh-pet", isDirectory: true)
        let activePackage = profileWeb
            .appendingPathComponent("node_modules/better-dsh-pet", isDirectory: true)
        let bundledManifest = bundledPackage.appendingPathComponent("package.json")
        let activeManifest = activePackage.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: bundledManifest.path),
              fileManager.fileExists(atPath: activeManifest.path),
              let bundledIdentity = packageNameAndVersion(at: bundledManifest),
              let activeIdentity = packageNameAndVersion(at: activeManifest),
              bundledIdentity.0 == "better-dsh-pet",
              bundledIdentity.1 == "0.3.5",
              activeIdentity.0 == "better-dsh-pet",
              activeIdentity.1 == "0.3.5" else {
            return false
        }

        var changed = false
        for relativePath in Self.betterDshPetAdapterFiles {
            let source = bundledPackage.appendingPathComponent(relativePath)
            let destination = activePackage.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else { return false }
            if (try? Data(contentsOf: source)) == (try? Data(contentsOf: destination)) { continue }
            try replaceItemAtomically(source: source, destination: destination)
            changed = true
        }
        AppLogger.plugins.info("Refreshed the bundled macOS better-dsh-pet adapter.")
        return changed
    }

    /// Bridges the dsh-mnemon projection descriptor between the two Runtime
    /// contracts currently in the wild. Harness Runtime 0.1.0-rc.6 expects
    /// `schema` and a top-level `view`; recent dsh-mnemon releases use
    /// the newer `stateSchema`/`wire.viewSchema` shape. The latter makes the
    /// old Runtime throw while serving `session.history`, which leaves a
    /// completed turn with no visible messages. The transform is deliberately
    /// narrow and reversible so a later Runtime upgrade restores the package's
    /// native descriptor instead of leaving a stale compatibility mutation.
    @discardableResult
    func syncDshMnemonProjectionCompatibility(
        paths: AppPaths,
        runtimeVersion: String?
    ) throws -> Bool {
        try syncDshMnemonProjectionCompatibility(
            profileWeb: paths.profileWeb,
            runtimeVersion: runtimeVersion
        )
    }

    /// Applies the same bridge to a staged data slot used for Runtime
    /// preflight. An update candidate must use the projection contract of the
    /// candidate Runtime, not the contract of the currently running one.
    @discardableResult
    func syncDshMnemonProjectionCompatibility(
        profileWeb: URL,
        runtimeVersion: String?
    ) throws -> Bool {
        let packageDirectory = profileWeb
            .appendingPathComponent("node_modules/dsh-mnemon", isDirectory: true)
            .resolvingSymlinksInPath()
        let manifestURL = packageDirectory.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let identity = packageNameAndVersion(at: manifestURL),
              identity.0 == "dsh-mnemon" else {
            return false
        }

        let sourceURL = packageDirectory.appendingPathComponent("lib/index.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }

        let legacyRuntime = Self.usesLegacyProjectionContract(runtimeVersion)
        guard let adapted = Self.adaptDshMnemonProjectionSource(source, legacyRuntime: legacyRuntime),
              adapted != source else {
            return false
        }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info(
            "Applied dsh-mnemon projection compatibility for Harness Runtime \(runtimeVersion ?? "unknown")."
        )
        return true
    }

    /// Keeps fixed-model Mnemon reviews text-only. The fork provider normally
    /// inherits the completed parent session, including durable image blocks.
    /// A fixed model may use a text-only adapter even when the model itself can
    /// accept images, so only the review fork receives a sanitized seed. The
    /// parent session and follow-main-chain operations are left untouched.
    @discardableResult
    func syncDshMnemonTextOnlyReviewCompatibility(
        paths: AppPaths,
        runtimeRoot: URL
    ) throws -> Bool {
        try syncDshMnemonTextOnlyReviewCompatibility(
            profileWeb: paths.profileWeb,
            runtimeRoot: runtimeRoot
        )
    }

    /// Applies the review-only bridge to a profile and its matching Runtime.
    /// Both files are patched in place because the profile package and fork
    /// provider are loaded by separate module resolvers at Harness startup.
    @discardableResult
    func syncDshMnemonTextOnlyReviewCompatibility(
        profileWeb: URL,
        runtimeRoot: URL
    ) throws -> Bool {
        let mnemonPackage = profileWeb
            .appendingPathComponent("node_modules/dsh-mnemon", isDirectory: true)
            .resolvingSymlinksInPath()
        let mnemonManifest = mnemonPackage.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: mnemonManifest.path),
              let identity = packageNameAndVersion(at: mnemonManifest),
              identity.0 == "dsh-mnemon" else {
            return false
        }

        // Recent pnpm Runtime layouts no longer hoist this package at
        // `node_modules/@deepseek-ai/...`; resolve it through the same
        // Runtime-package lookup used for the core LLM module so the review
        // filter survives a Runtime upgrade.
        let forkPackage = try runtimePackageDirectory(
            named: "dsh-subagent-fork-in-process",
            runtimeRoot: runtimeRoot
        )
        let mnemonSourceURL = mnemonPackage.appendingPathComponent("lib/index.js")
        let forkSourceURL = forkPackage.appendingPathComponent("lib/index.js")
        guard let mnemonSource = try? String(contentsOf: mnemonSourceURL, encoding: .utf8),
              let forkSource = try? String(contentsOf: forkSourceURL, encoding: .utf8) else {
            return false
        }

        let patchedMnemon: String
        if mnemonSource.contains("dshMnemonTextOnly: true") {
            patchedMnemon = mnemonSource
        } else if let adapted = Self.adaptDshMnemonTextOnlyReviewSource(mnemonSource) {
            patchedMnemon = adapted
        } else {
            return false
        }

        let patchedFork: String
        if forkSource.contains("mnemonForkSeed(request)") {
            patchedFork = forkSource
        } else if let adapted = Self.adaptDshMnemonForkSource(forkSource) {
            patchedFork = adapted
        } else {
            return false
        }

        var changed = false
        if patchedMnemon != mnemonSource {
            try patchedMnemon.write(to: mnemonSourceURL, atomically: true, encoding: .utf8)
            changed = true
        }
        if patchedFork != forkSource {
            try patchedFork.write(to: forkSourceURL, atomically: true, encoding: .utf8)
            changed = true
        }

        if changed {
            AppLogger.plugins.info(
                "Applied text-only image filtering for fixed-model dsh-mnemon reviews."
            )
        }
        return changed
    }

    private static func usesLegacyProjectionContract(_ runtimeVersion: String?) -> Bool {
        guard let runtimeVersion,
              let parsed = StrictSemanticVersion(rawValue: runtimeVersion),
              let firstModern = StrictSemanticVersion(rawValue: "0.1.1-rc.1") else {
            return false
        }
        return parsed < firstModern
    }

    private static func adaptDshMnemonProjectionSource(
        _ source: String,
        legacyRuntime: Bool
    ) -> String? {
        let modernStateSchema = "stateSchema: tokenUsageStateSchema,"
        let modernWire = "wire: {\n\t\tviewSchema: tokenUsageSchema.nullable(),\n\t\tview: (state) => state.descriptorSeen ? state.totals : null\n\t}"
        let legacySchema = "schema: tokenUsageSchema.nullable(),"
        let legacyView = "view: (state) => state.descriptorSeen ? state.totals : null"

        if legacyRuntime {
            guard source.contains(modernStateSchema), source.contains(modernWire) else {
                return nil
            }
            return source
                .replacingOccurrences(of: modernStateSchema, with: legacySchema)
                .replacingOccurrences(of: modernWire, with: legacyView)
        }

        guard source.contains(legacySchema), source.contains(legacyView),
              !source.contains(modernStateSchema) else {
            return nil
        }
        return source
            .replacingOccurrences(of: legacySchema, with: modernStateSchema)
            .replacingOccurrences(of: legacyView, with: modernWire)
    }

    private static func adaptDshMnemonTextOnlyReviewSource(_ source: String) -> String? {
        let marker = "dshMnemonTextOnly: true"
        guard !source.contains(marker) else { return nil }

        let original = """
\t\t\tconst resolvedAgentOptions = fixed === void 0 ? baseAgentOptions : {
\t\t\t\t...baseAgentOptions ?? {},
\t\t\t\tprovider: fixed.provider,
\t\t\t\tmodel: fixed.model
\t\t\t};
"""
        let replacement = """
\t\t\tconst resolvedAgentOptions = fixed === void 0 ? baseAgentOptions : {
\t\t\t\t...baseAgentOptions ?? {},
\t\t\t\t...operation === \"review\" ? { dshMnemonTextOnly: true } : {},
\t\t\t\tprovider: fixed.provider,
\t\t\t\tmodel: fixed.model
\t\t\t};
"""
        guard source.contains(original) else { return nil }
        return source.replacingOccurrences(of: original, with: replacement)
    }

    private static func adaptDshMnemonSessionSource(_ source: String) -> String? {
        let marker = "function dshMnemonSessionEvents(session)"
        guard !source.contains(marker),
              source.contains("this.agent.session.events") || source.contains("run.localAgent?.session.events") else {
            return nil
        }

        let helper = """
        function dshMnemonSessionEvents(session) {
        \tconst events = typeof session?.snapshotEvents === "function" ? session.snapshotEvents() : session?.events;
        \treturn Array.isArray(events) ? events : [];
        }

        """
        let anchor = "const MNEMON_READ_CHANNEL = \"/dsh-mnemon-read\";"
        guard source.contains(anchor) else { return nil }

        let adapted = source
            .replacingOccurrences(
                of: "run.localAgent?.session.events ?? []",
                with: "dshMnemonSessionEvents(run.localAgent?.session)"
            )
            .replacingOccurrences(
                of: "this.agent.session.events",
                with: "dshMnemonSessionEvents(this.agent.session)"
            )
            .replacingOccurrences(of: anchor, with: helper + anchor)
        return adapted == source ? nil : adapted
    }

    private static func adaptDshMnemonForkSource(_ source: String) -> String? {
        let marker = "mnemonForkSeed(request)"
        guard !source.contains(marker) else { return nil }

        let classAnchor = "var ForkInProcessProvider = class {"
        let seedAnchor = "const seed = completedTurnPrefix(request.parent);"
        guard source.contains(classAnchor), source.components(separatedBy: seedAnchor).count == 3 else {
            return nil
        }

        let helpers = """
        function sanitizeMnemonForkValue(value) {
        \tif (Array.isArray(value)) return value.map((item) => sanitizeMnemonForkValue(item));
        \tif (value && typeof value === \"object\") {
        \t\tif (!Array.isArray(value) && value.type === \"image\") {
        \t\t\treturn { type: \"text\", text: \"[image content omitted from text-only Mnemon review]\" };
        \t\t}
        \t\treturn Object.fromEntries(Object.entries(value).map(([key, item]) => [key, sanitizeMnemonForkValue(item)]));
        \t}
        \treturn value;
        }
        function sanitizeMnemonForkSeed(seed) {
        \treturn seed.map((event) => sanitizeMnemonForkValue(event));
        }
        function mnemonForkSeed(request) {
        \tconst seed = completedTurnPrefix(request.parent);
        \treturn request.agentOptions?.dshMnemonTextOnly === true ? sanitizeMnemonForkSeed(seed) : seed;
        }
        """
        let replacedSeeds = source.replacingOccurrences(
            of: seedAnchor,
            with: "const seed = mnemonForkSeed(request);"
        )
        let withHelpers = replacedSeeds.replacingOccurrences(
            of: classAnchor,
            with: helpers + "\n" + classAnchor
        )
        guard withHelpers != source else { return nil }
        return withHelpers
    }

    private func packageNameAndVersion(at manifest: URL) -> (String, String)? {
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              let version = object["version"] as? String else {
            return nil
        }
        return (name, version)
    }

    private func runtimePackageDirectory(named package: String, runtimeRoot: URL) throws -> URL {
        let direct = runtimeRoot
            .appendingPathComponent("node_modules/.pnpm/node_modules/@deepseek-ai/\(package)", isDirectory: true)
        if fileManager.fileExists(atPath: direct.appendingPathComponent("package.json").path) {
            return direct.resolvingSymlinksInPath()
        }

        let pnpmRoot = runtimeRoot.appendingPathComponent("node_modules/.pnpm", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pnpmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw RuntimeCompatibilityError.runtimePackageMissing("@deepseek-ai/\(package)")
        }
        let prefix = "@deepseek-ai+\(package)@"
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let candidate = entry.appendingPathComponent(
                "node_modules/@deepseek-ai/\(package)",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        throw RuntimeCompatibilityError.runtimePackageMissing("@deepseek-ai/\(package)")
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "unknown" : result
    }

    private func replaceItemAtomically(source: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}
