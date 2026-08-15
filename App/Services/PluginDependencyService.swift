import Foundation

enum PluginDependencySource: Equatable {
    case bundled
    case system
    case user

    var displayName: String {
        switch self {
        case .bundled:
            return "App 内置"
        case .system:
            return "macOS 系统"
        case .user:
            return "用户已有"
        }
    }
}

struct ResolvedPluginDependency: Equatable {
    let name: String
    let executable: URL
    let version: String?
    let source: PluginDependencySource

    var confirmationLine: String {
        let versionText = version.map { " \($0)" } ?? ""
        return "• \(name)\(versionText)（\(source.displayName)，仅供本 App 使用）"
    }
}

struct PluginDependencyPlan: Equatable {
    let dependencies: [ResolvedPluginDependency]
    let searchPath: String

    var usesUserTools: Bool {
        dependencies.contains { $0.source == .user }
    }

    var confirmationText: String {
        let dependencyLines = dependencies.map(\.confirmationLine).joined(separator: "\n")
        return """
        插件基础依赖：
        \(dependencyLines)

        PATH 只会传给 DeepSeek Harness 的插件子进程，不会修改系统 PATH、Shell 配置或全局包。
        插件及其 Node.js 依赖只会写入 App 私有 DSH_HOME。
        """
    }
}

enum PluginDependencyError: LocalizedError, Equatable {
    case missing([String])

    var errorDescription: String? {
        switch self {
        case .missing(let names):
            return "App 私有插件工具链不完整，缺少：\(names.joined(separator: "、"))。请更新或重新安装 DeepSeek Harness；Launcher 不会自动修改全局环境。"
        }
    }
}

/// Resolves the small, allow-listed toolchain required by the official
/// `dsh plugin` command. App-bundled tools always win. Existing user tools are
/// a compatibility fallback and are exposed only to the child process.
struct PluginDependencyService {
    private let fileManager: FileManager
    private let baseEnvironment: [String: String]
    private let privateToolchainRoot: URL?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        privateToolchainRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        baseEnvironment = environment
        self.privateToolchainRoot = privateToolchainRoot
    }

    func resolve(
        installation: RuntimeInstallation,
        arguments: [String]
    ) throws -> PluginDependencyPlan {
        var dependencies: [ResolvedPluginDependency] = []
        var missing: [String] = []

        if let pnpm = resolvePNPM(installation: installation) {
            dependencies.append(pnpm)
        } else {
            missing.append("pnpm")
        }

        if arguments.contains(where: Self.isGitHostedSpec) {
            if let git = resolveSystemTool(named: "git", preferredPath: "/usr/bin/git") {
                dependencies.append(git)
            } else {
                missing.append("git")
            }
            if let curl = resolveSystemTool(named: "curl", preferredPath: "/usr/bin/curl") {
                dependencies.append(curl)
            } else {
                missing.append("curl")
            }
        }

        guard missing.isEmpty else { throw PluginDependencyError.missing(missing) }
        return PluginDependencyPlan(
            dependencies: dependencies,
            searchPath: searchPath(installation: installation, dependencies: dependencies)
        )
    }

    /// The Harness sidecar inherits the same private tool directories so an
    /// installed plugin can reach App-managed basics such as Node and pnpm.
    /// Missing plugin-only tools do not prevent the base Harness UI from starting.
    func runtimeSearchPath(installation: RuntimeInstallation) -> String {
        let dependencies = [resolvePNPM(installation: installation)].compactMap { $0 }
        return searchPath(installation: installation, dependencies: dependencies)
    }

    func applying(
        plan: PluginDependencyPlan,
        additions: [String: String],
        to environment: [String: String]? = nil
    ) -> [String: String] {
        var result = environment ?? baseEnvironment
        result.merge(additions) { _, new in new }
        result["PATH"] = plan.searchPath
        return result
    }

    private func resolvePNPM(installation: RuntimeInstallation) -> ResolvedPluginDependency? {
        var bundledCandidates = [
            installation.root.appendingPathComponent("node_modules/.bin/pnpm"),
            installation.root.appendingPathComponent("bin/pnpm"),
            installation.executable.deletingLastPathComponent().appendingPathComponent("pnpm")
        ]
        if let nodeExecutable = installation.nodeExecutable {
            bundledCandidates.append(nodeExecutable.deletingLastPathComponent().appendingPathComponent("pnpm"))
        }
        if let privateToolchainRoot {
            bundledCandidates.append(contentsOf: [
                privateToolchainRoot.appendingPathComponent("bin/pnpm"),
                privateToolchainRoot.appendingPathComponent("pnpm/bin/pnpm")
            ])
        }

        if let executable = bundledCandidates.first(where: isExecutable) {
            return ResolvedPluginDependency(
                name: "pnpm",
                executable: executable,
                version: pnpmVersion(for: executable, installation: installation),
                source: .bundled
            )
        }

        if let executable = executableOnConfiguredPath(named: "pnpm") {
            return ResolvedPluginDependency(
                name: "pnpm",
                executable: executable,
                version: nil,
                source: .user
            )
        }

        if let executable = commonUserPNPMCandidates().first(where: isExecutable) {
            return ResolvedPluginDependency(
                name: "pnpm",
                executable: executable,
                version: nil,
                source: .user
            )
        }
        return nil
    }

    private func resolveSystemTool(named name: String, preferredPath: String) -> ResolvedPluginDependency? {
        let preferred = URL(fileURLWithPath: preferredPath)
        if isExecutable(preferred) {
            return ResolvedPluginDependency(name: name, executable: preferred, version: nil, source: .system)
        }
        guard let executable = executableOnConfiguredPath(named: name) else { return nil }
        return ResolvedPluginDependency(name: name, executable: executable, version: nil, source: .user)
    }

    private func searchPath(
        installation: RuntimeInstallation,
        dependencies: [ResolvedPluginDependency]
    ) -> String {
        var directories = dependencies.map { $0.executable.deletingLastPathComponent().path }
        if let nodeDirectory = installation.nodeExecutable?.deletingLastPathComponent().path {
            directories.append(nodeDirectory)
        }
        if let privateToolchainRoot {
            directories.append(privateToolchainRoot.appendingPathComponent("bin").path)
        }
        directories.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        if let configuredPath = baseEnvironment["PATH"] {
            directories.append(contentsOf: configuredPath.split(separator: ":").map(String.init))
        }

        var seen: Set<String> = []
        return directories
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func executableOnConfiguredPath(named name: String) -> URL? {
        guard let configuredPath = baseEnvironment["PATH"] else { return nil }
        return configuredPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first(where: isExecutable)
    }

    private func commonUserPNPMCandidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            URL(fileURLWithPath: "/usr/local/bin/pnpm"),
            home.appendingPathComponent(".local/bin/pnpm"),
            home.appendingPathComponent(".local/share/pnpm/pnpm"),
            home.appendingPathComponent("Library/pnpm/pnpm"),
            home.appendingPathComponent(".volta/bin/pnpm"),
            home.appendingPathComponent(".asdf/shims/pnpm"),
            home.appendingPathComponent(".bun/bin/pnpm")
        ]

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/pnpm") })
        }
        return candidates
    }

    private func pnpmVersion(for executable: URL, installation: RuntimeInstallation) -> String? {
        let candidates = [
            installation.root.appendingPathComponent("node_modules/pnpm/package.json"),
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("pnpm/package.json")
        ]
        for manifest in candidates {
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let version = object["version"] as? String { return version }
        }
        return nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    private static func isGitHostedSpec(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.hasPrefix("github:")
            || normalized.hasPrefix("git+")
            || normalized.hasPrefix("git@")
            || normalized.contains("github.com/")
            || normalized.contains(".git#")
            || normalized.hasSuffix(".git")
    }
}
