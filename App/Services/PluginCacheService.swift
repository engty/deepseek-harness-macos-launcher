import Foundation

struct PluginCacheEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case plugin(String)
        case sharedPnpm
        case staging
    }

    let id: String
    let title: String
    let sizeBytes: Int64
    let kind: Kind
}

struct PluginCacheCleanupReport {
    let removedBytes: Int64
    let prunedBytes: Int64
    let pnpmPruneSucceeded: Bool

    var summary: String {
        let removed = ByteCountFormatter.string(
            fromByteCount: removedBytes + prunedBytes,
            countStyle: .file
        )
        if pnpmPruneSucceeded {
            return "已清理 \(removed) 缓存。"
        }
        return "已清理 \(removed) App 缓存；共享 pnpm 缓存未完成回收。"
    }
}

/// Handles only cache locations whose ownership is known. Plugin packages
/// themselves are managed by the official dsh command and are never removed
/// by this service.
struct PluginCacheService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func entries(for plugins: [HarnessPlugin], paths: AppPaths) -> [PluginCacheEntry] {
        var entries = plugins.map { plugin in
            PluginCacheEntry(
                id: "plugin:\(plugin.id)",
                title: plugin.name,
                sizeBytes: size(of: pluginCacheDirectories(for: plugin.id, paths: paths)),
                kind: .plugin(plugin.id)
            )
        }

        let pnpmSize = size(of: globalPnpmStoreCandidates())
        if pnpmSize > 0 {
            entries.append(
                PluginCacheEntry(
                    id: "shared-pnpm",
                    title: "共享 pnpm 缓存",
                    sizeBytes: pnpmSize,
                    kind: .sharedPnpm
                )
            )
        }

        let stagingSize = size(of: [paths.pluginStaging])
        if stagingSize > 0 {
            entries.append(
                PluginCacheEntry(
                    id: "staging",
                    title: "安装暂存缓存",
                    sizeBytes: stagingSize,
                    kind: .staging
                )
            )
        }
        return entries
    }

    func cleanup(
        entries: [PluginCacheEntry],
        paths: AppPaths,
        installation: RuntimeInstallation?
    ) async -> PluginCacheCleanupReport {
        let selectedKinds = entries.map { $0.kind }
        var removedBytes: Int64 = 0

        for kind in selectedKinds {
            switch kind {
            case .plugin(let id):
                let urls = pluginCacheDirectories(for: id, paths: paths)
                removedBytes += size(of: urls)
                remove(urls)
            case .staging:
                removedBytes += size(of: [paths.pluginStaging])
                removeContents(of: paths.pluginStaging)
            case .sharedPnpm:
                break
            }
        }

        guard selectedKinds.contains(.sharedPnpm), let installation else {
            return PluginCacheCleanupReport(
                removedBytes: removedBytes,
                prunedBytes: 0,
                pnpmPruneSucceeded: !selectedKinds.contains(.sharedPnpm)
            )
        }

        let before = size(of: globalPnpmStoreCandidates())
        let succeeded = await prunePnpmStore(installation: installation, paths: paths)
        let after = size(of: globalPnpmStoreCandidates())
        return PluginCacheCleanupReport(
            removedBytes: removedBytes,
            prunedBytes: max(0, before - after),
            pnpmPruneSucceeded: succeeded
        )
    }

    func cleanupAfterUninstall(
        pluginIDs: [String],
        paths: AppPaths,
        installation: RuntimeInstallation
    ) async -> PluginCacheCleanupReport {
        let pluginEntries = pluginIDs.map {
            PluginCacheEntry(
                id: "plugin:\($0)",
                title: $0,
                sizeBytes: 0,
                kind: .plugin($0)
            )
        }
        let sharedEntry = PluginCacheEntry(
            id: "shared-pnpm",
            title: "共享 pnpm 缓存",
            sizeBytes: 0,
            kind: .sharedPnpm
        )
        return await cleanup(
            entries: pluginEntries + [sharedEntry],
            paths: paths,
            installation: installation
        )
    }

    private func pluginCacheDirectories(for id: String, paths: AppPaths) -> [URL] {
        // These directories are App-owned and are safe to remove. Arbitrary
        // ~/Library/Application Support/<plugin> directories are intentionally
        // excluded because they may contain user data or another app's state.
        [
            paths.caches.appendingPathComponent("plugin-cache", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true),
            paths.dshHome.appendingPathComponent("launcher/plugin-cache", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
        ]
    }

    private func globalPnpmStoreCandidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/pnpm/store", isDirectory: true),
            home.appendingPathComponent(".local/share/pnpm/store", isDirectory: true),
            home.appendingPathComponent(".pnpm-store", isDirectory: true)
        ]
    }

    private func pnpmExecutable(installation: RuntimeInstallation) -> URL? {
        var candidates = [
            installation.root.appendingPathComponent("node_modules/.bin/pnpm"),
            installation.root.appendingPathComponent("bin/pnpm"),
            installation.executable.deletingLastPathComponent().appendingPathComponent("pnpm")
        ]
        if let node = installation.nodeExecutable {
            candidates.append(node.deletingLastPathComponent().appendingPathComponent("pnpm"))
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func prunePnpmStore(
        installation: RuntimeInstallation,
        paths: AppPaths
    ) async -> Bool {
        guard let pnpm = pnpmExecutable(installation: installation) else { return false }
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = paths.dshHome.path
        environment["DSH_LAUNCHER"] = "DeepSeekHarness"
        environment["PATH"] = PluginDependencyService(
            environment: environment,
            privateToolchainRoot: paths.toolchain
        ).runtimeSearchPath(installation: installation)
        do {
            let result = try await SubprocessRunner.run(
                executable: pnpm,
                arguments: ["store", "prune"],
                environment: environment,
                currentDirectory: paths.profileWeb,
                timeout: 180
            )
            return result.status == 0
        } catch {
            return false
        }
    }

    private func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + size(of: $1) }
    }

    private func size(of url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let value = attributes[.size] as? NSNumber,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            return value.int64Value
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, item in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return total
            }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private func remove(_ urls: [URL]) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private func removeContents(of directory: URL) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        remove(children)
    }
}
