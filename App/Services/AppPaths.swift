import Foundation

struct AppPaths {
    static let bundleIdentifier = "com.harness.desktop.launcher"

    let applicationSupport: URL
    let caches: URL
    let logs: URL
    let toolchain: URL

    init(fileManager: FileManager = .default) {
        let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let cachesRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let logsRoot = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Logs") ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")

        self.init(
            applicationSupport: applicationSupportRoot.appendingPathComponent(Self.bundleIdentifier, isDirectory: true),
            caches: cachesRoot.appendingPathComponent(Self.bundleIdentifier, isDirectory: true),
            logs: logsRoot.appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
        )
    }

    init(applicationSupport: URL, caches: URL, logs: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.logs = logs
        self.toolchain = applicationSupport.appendingPathComponent("toolchain", isDirectory: true)
    }

    var state: URL { applicationSupport.appendingPathComponent("state", isDirectory: true) }
    var data: URL { applicationSupport.appendingPathComponent("data", isDirectory: true) }
    var activeDataSlot: URL { data.appendingPathComponent("active", isDirectory: true) }
    var dshHome: URL { activeDataSlot.appendingPathComponent("dsh-home", isDirectory: true) }
    var pluginMetadata: URL { dshHome.appendingPathComponent("launcher/plugin-metadata.json") }
    var profileWeb: URL { dshHome.appendingPathComponent("profiles/web", isDirectory: true) }
    var runtimes: URL { applicationSupport.appendingPathComponent("runtimes", isDirectory: true) }
    var activeRuntimeManifest: URL { state.appendingPathComponent("active-runtime.json") }
    var lastKnownGoodRuntimeManifest: URL { state.appendingPathComponent("last-known-good-runtime.json") }
    var overlay: URL { state.appendingPathComponent("launcher-web-overlay.cordis.patch.yml") }
    var sidecarPID: URL { state.appendingPathComponent("harness-sidecar.pid") }
    var pluginStaging: URL { caches.appendingPathComponent("plugin-staging", isDirectory: true) }
    var pluginOperationsLog: URL { logs.appendingPathComponent("plugin-operations.log") }
    var backups: URL { applicationSupport.appendingPathComponent("backups", isDirectory: true) }
    var diagnostics: URL { applicationSupport.appendingPathComponent("diagnostics", isDirectory: true) }

    func prepare() throws {
        let directories = [
            applicationSupport,
            caches,
            logs,
            state,
            data,
            activeDataSlot,
            runtimes,
            dshHome,
            toolchain,
            pluginStaging,
            backups,
            diagnostics
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
