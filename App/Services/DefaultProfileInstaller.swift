import Foundation

/// Seeds a fresh App-owned Harness profile with the plugin bundle that ships
/// in the Runtime. Existing profiles are never modified, so removing the
/// default plugin remains a durable user choice.
struct DefaultProfileInstaller {
    private let fileManager: FileManager

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
    /// `schema` and a top-level `view`; dsh-mnemon 0.3.5 was published with
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

    private func packageNameAndVersion(at manifest: URL) -> (String, String)? {
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              let version = object["version"] as? String else {
            return nil
        }
        return (name, version)
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
