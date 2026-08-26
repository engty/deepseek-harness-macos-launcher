import Foundation

/// Seeds a fresh App-owned Harness profile with the plugin bundle that ships
/// in the Runtime. Existing profiles are never modified, so removing the
/// default plugin remains a durable user choice.
struct DefaultProfileInstaller {
    private let fileManager: FileManager

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
}
