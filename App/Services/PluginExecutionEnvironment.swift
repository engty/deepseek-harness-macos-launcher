import Foundation

/// One environment for the sidecar and every native plugin mutation.
/// HOME remains real so authorised workspace and external-tool access works.
enum PluginExecutionEnvironment {
    static func make(
        installation: RuntimeInstallation,
        paths: AppPaths,
        dshHome: URL,
        searchPath: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        var environment = base
        let npmPrefix = paths.toolchain.appendingPathComponent("npm-global")
        let pnpmHome = paths.toolchain.appendingPathComponent("pnpm-global")
        let store = paths.caches.appendingPathComponent("pnpm/store")
        let npmCache = paths.caches.appendingPathComponent("npm")
        for directory in [npmPrefix, pnpmHome, store, npmCache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let path = searchPath ?? PluginDependencyService(environment: base, privateToolchainRoot: paths.toolchain)
            .runtimeSearchPath(installation: installation)
        var directories = path.split(separator: ":").map(String.init)
        let insertion = directories.firstIndex(of: "/usr/bin") ?? directories.count
        directories.insert(contentsOf: [
            dshHome.appendingPathComponent("profiles/web/node_modules/.bin").path,
            npmPrefix.appendingPathComponent("bin").path,
            pnpmHome.path,
        ], at: insertion)
        // Older active Runtimes can reuse npm shipped with the new App shell.
        let bundledRoots = [installation.root, Bundle.main.resourceURL?.appendingPathComponent("runtime"),
            Dsh1024Adapter.resourceDirectory.deletingLastPathComponent().appendingPathComponent("runtime")].compactMap { $0 }
        if let npm = bundledRoots.map({ $0.appendingPathComponent("node_modules/npm/bin") })
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("npm-cli.js").path) }) {
            let bin = paths.toolchain.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            environment["HARNESS_NPM_ROOT"] = npm.deletingLastPathComponent().path
            for name in ["npm", "npx"] {
                let script = "#!/bin/sh\nexec \"$HARNESS_NODE_PATH\" \"$HARNESS_NPM_ROOT/bin/\(name)-cli.js\" \"$@\"\n"
                let destination = bin.appendingPathComponent(name)
                if (try? String(contentsOf: destination, encoding: .utf8)) != script {
                    try script.write(to: destination, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                }
            }
        }
        environment["PATH"] = directories.reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }.joined(separator: ":")
        environment["DSH_HOME"] = dshHome.path
        environment["DSH_LAUNCHER"] = "DeepSeekHarness"
        environment["HARNESS_NODE_PATH"] = installation.nodeExecutable?.path
        environment["HARNESS_DSH_PATH"] = installation.executable.path
        environment["MNEMON_DATA_DIR"] = dshHome.appendingPathComponent("mnemon").path
        environment["PNPM_HOME"] = pnpmHome.path
        environment["PNPM_STORE_DIR"] = store.path
        for (name, value) in ["prefix": npmPrefix.path, "cache": npmCache.path, "store_dir": store.path] {
            environment["npm_config_\(name)"] = value
            environment["NPM_CONFIG_\(name.uppercased())"] = value
        }
        return environment
    }

    static func requiresStoreMigration(profile: URL, store: URL) -> Bool {
        guard let contents = try? String(contentsOf: profile.appendingPathComponent("node_modules/.modules.yaml"), encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("storeDir:") }) else { return false }
        let previous = line.dropFirst("storeDir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let root = store.standardizedFileURL.path
        return previous != root && !previous.hasPrefix(root + "/")
    }
}
