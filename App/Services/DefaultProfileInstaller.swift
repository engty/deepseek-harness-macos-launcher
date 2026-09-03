import Foundation

/// Seeds a fresh App-owned Harness profile with the plugin bundle that ships
/// in the Runtime. Existing profiles are never modified, so removing the
/// default plugin remains a durable user choice.
struct DefaultProfileInstaller {
    private let fileManager: FileManager

    private enum RuntimeCompatibilityError: LocalizedError {
        case runtimePackageMissing(String)
        case quarantineFailed(String)

        var errorDescription: String? {
            switch self {
            case .runtimePackageMissing(let package):
                return "当前 Runtime 缺少官方模块 \(package)，无法完成兼容性修复。"
            case .quarantineFailed(let message):
                return "无法隔离旧版 Runtime 模块：\(message)"
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

    /// Keeps the profile's official LLM module aligned with the active
    /// Runtime. A profile created by an older Harness can contain a real
    /// `@deepseek-ai/dsh-llm` directory. Node resolves that directory before
    /// the Runtime's module tree, and the old module does not register the
    /// modern `/api/llm/*` routes, producing an opaque HTTP 404 in Settings.
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
        let runtimePackage = try runtimePackageDirectory(
            named: "dsh-llm",
            runtimeRoot: runtimeRoot
        )
        let activePackage = profileWeb
            .appendingPathComponent("node_modules/@deepseek-ai/dsh-llm", isDirectory: true)
        let activeExists = fileManager.fileExists(atPath: activePackage.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: activePackage.path)) != nil
        let activeResolved = activePackage.resolvingSymlinksInPath().standardizedFileURL.path
        let runtimeResolved = runtimePackage.standardizedFileURL.path
        guard !activeExists || activeResolved != runtimeResolved else { return false }

        if activeExists {
            let version = packageNameAndVersion(
                at: activePackage.appendingPathComponent("package.json")
            )?.1 ?? "unknown"
            let backup = quarantineRoot
                .appendingPathComponent(
                    "dsh-llm-\(safePathComponent(version))-\(UUID().uuidString)",
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
            "Aligned profile @deepseek-ai/dsh-llm with the active Runtime."
        )
        return true
    }

    /// dsh-llm-codex 0.1.1 was released against the old `CallId` export.
    /// Modern Harness Runtimes expose the equivalent `ToolCallId` symbol.
    /// Adapt only this narrow import/call site based on the actual Runtime
    /// export, and reverse it automatically when an older Runtime is selected.
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
        let sourceURL = profileWeb
            .appendingPathComponent("node_modules/dsh-llm-codex/lib/translate.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }
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
            return false
        }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info(
            "Aligned dsh-llm-codex with the active Runtime LLM identifier API."
        )
        return true
    }

    /// Newer Harness Runtime Sessions expose their durable history through
    /// `snapshotEvents()` instead of the former iterable `events` property.
    /// Vision Toolkit 0.1.39 reads that history while each Agent is created;
    /// the old access therefore aborts every new session before it can be
    /// attached to a Workspace. Keep the adapter source-compatible with both
    /// contracts so a Runtime upgrade cannot disable session creation.
    @discardableResult
    func syncVisionToolkitSessionCompatibility(paths: AppPaths) throws -> Bool {
        try syncVisionToolkitSessionCompatibility(profileWeb: paths.profileWeb)
    }

    /// Staged-slot variant used by Runtime update preflight. The patch stays
    /// within the candidate profile until the candidate has successfully
    /// started, so a failed update cannot change the active user profile.
    @discardableResult
    func syncVisionToolkitSessionCompatibility(profileWeb: URL) throws -> Bool {
        let packageDirectory = profileWeb
            .appendingPathComponent(
                "node_modules/@anionex/dsh-vision-toolkit",
                isDirectory: true
            )
            .resolvingSymlinksInPath()
        let manifestURL = packageDirectory.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let identity = packageNameAndVersion(at: manifestURL),
              identity.0 == "@anionex/dsh-vision-toolkit" else {
            return false
        }

        let sourceURL = packageDirectory.appendingPathComponent("lib/exposure.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let adapted = Self.adaptVisionToolkitSessionSource(source),
              adapted != source else {
            return false
        }
        try adapted.write(to: sourceURL, atomically: true, encoding: .utf8)
        AppLogger.plugins.info(
            "Applied Vision Toolkit session-history compatibility."
        )
        return true
    }

    /// Recent dsh-mnemon releases still read the former `session.events` array from
    /// its lifecycle hooks. Modern Harness Runtimes replaced that property
    /// with `snapshotEvents()`. Unlike the Vision Toolkit's single startup
    /// probe, Mnemon reads the event log throughout a session, so every known
    /// read site is routed through one small compatibility helper. The helper
    /// keeps old Runtimes working and returns an empty history only when a
    /// malformed session provides neither contract.
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
        let bundledPackage = runtimeRoot
            .appendingPathComponent("default-profile/profiles/web/node_modules/better-dsh-pet", isDirectory: true)
        let activePackage = paths.profileWeb
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

        for relativePath in Self.betterDshPetAdapterFiles {
            let source = bundledPackage.appendingPathComponent(relativePath)
            let destination = activePackage.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else { return false }
            try replaceItemAtomically(source: source, destination: destination)
        }
        AppLogger.plugins.info("Refreshed the bundled macOS better-dsh-pet adapter.")
        return true
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

    private static func adaptVisionToolkitSessionSource(_ source: String) -> String? {
        let legacyLoop = "for (const event of session.events) {"
        let compatibleLoop = """
        const events = typeof session.snapshotEvents === 'function' ? session.snapshotEvents() : session.events;
            for (const event of events) {
        """
        guard source.contains(legacyLoop),
              !source.contains("session.snapshotEvents === 'function'") else {
            return nil
        }
        return source.replacingOccurrences(of: legacyLoop, with: compatibleLoop)
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
            ".(destination.lastPathComponent).(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}
