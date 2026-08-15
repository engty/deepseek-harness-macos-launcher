import Foundation

struct RuntimeInstallation {
    let executable: URL
    let root: URL
    let version: String?
    let nodeExecutable: URL?
}

enum RuntimeLocatorError: LocalizedError {
    case notFound(searchLocations: [String])
    case notExecutable(URL)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "没有找到 DeepSeek Harness Runtime。"
        case .notExecutable(let url):
            return "Harness Runtime 不可执行：\(url.path)"
        }
    }
}

struct RuntimeLocator {
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func locate() throws -> RuntimeInstallation {
        var candidates: [(URL, URL)] = []

        if let explicit = environment["HARNESS_DSH_PATH"], !explicit.isEmpty {
            let executable = URL(fileURLWithPath: explicit).standardizedFileURL
            candidates.append((executable, executable.deletingLastPathComponent().deletingLastPathComponent()))
        }

        if let runtimeRoot = environment["HARNESS_RUNTIME_ROOT"], !runtimeRoot.isEmpty {
            let root = URL(fileURLWithPath: runtimeRoot).standardizedFileURL
            candidates.append(contentsOf: executableCandidates(root: root).map { ($0, root) })
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true) {
            candidates.append(contentsOf: executableCandidates(root: bundled).map { ($0, bundled) })
        }

        let paths = applicationSupportCandidates()
        for root in paths {
            candidates.append(contentsOf: executableCandidates(root: root).map { ($0, root) })
        }

        if let pathExecutable = executableOnPath(named: "dsh") {
            candidates.append((pathExecutable, pathExecutable.deletingLastPathComponent()))
        }

        var searchLocations: [String] = []
        for (executable, root) in candidates {
            searchLocations.append(executable.path)
            guard fileManager.fileExists(atPath: executable.path) else { continue }
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw RuntimeLocatorError.notExecutable(executable)
            }
            return RuntimeInstallation(
                executable: executable,
                root: root,
                version: version(for: executable, root: root),
                nodeExecutable: nodeExecutable(for: executable, root: root)
            )
        }

        throw RuntimeLocatorError.notFound(searchLocations: searchLocations)
    }

    func locateLastKnownGood() throws -> RuntimeInstallation {
        let manifest = AppPaths().lastKnownGoodRuntimeManifest
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimePath = object["runtimePath"] as? String else {
            throw RuntimeLocatorError.notFound(searchLocations: [manifest.path])
        }
        let root = URL(fileURLWithPath: runtimePath).standardizedFileURL
        for executable in executableCandidates(root: root) {
            guard fileManager.fileExists(atPath: executable.path) else { continue }
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw RuntimeLocatorError.notExecutable(executable)
            }
            return RuntimeInstallation(
                executable: executable,
                root: root,
                version: version(for: executable, root: root),
                nodeExecutable: nodeExecutable(for: executable, root: root)
            )
        }
        throw RuntimeLocatorError.notFound(searchLocations: [root.path])
    }

    private func applicationSupportCandidates() -> [URL] {
        let support = AppPaths().applicationSupport
        let runtimes = support.appendingPathComponent("runtimes", isDirectory: true)
        let activeManifest = support.appendingPathComponent("state/active-runtime.json")
        var roots: [URL] = []

        if let data = try? Data(contentsOf: activeManifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let runtimePath = object["runtimePath"] as? String {
                roots.append(URL(fileURLWithPath: runtimePath).standardizedFileURL)
            }
            if let runtimeID = object["runtimeId"] as? String {
                roots.append(runtimes.appendingPathComponent(runtimeID, isDirectory: true))
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: runtimes,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            roots.append(contentsOf: entries)
        }
        return roots
    }

    private func executableCandidates(root: URL) -> [URL] {
        [
            root.appendingPathComponent("bin/dsh"),
            root.appendingPathComponent("dsh"),
            root.appendingPathComponent("node_modules/.bin/dsh")
        ]
    }

    private func executableOnPath(named name: String) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func version(for executable: URL, root: URL) -> String? {
        var directories: [URL] = []
        var current = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            directories.append(current)
            current.deleteLastPathComponent()
        }
        directories.append(root.standardizedFileURL)

        var seen: Set<String> = []
        for directory in directories {
            let candidates = [
                directory.appendingPathComponent("package.json"),
                directory.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
            ]
            for manifestURL in candidates where seen.insert(manifestURL.path).inserted {
                guard let data = try? Data(contentsOf: manifestURL),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["name"] as? String == "@deepseek-ai/dsh",
                      let version = object["version"] as? String,
                      !version.isEmpty else { continue }
                return version
            }
        }
        return nil
    }

    private func nodeExecutable(for executable: URL, root: URL) -> URL? {
        var directories: [URL] = [root.standardizedFileURL]
        var current = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            directories.append(current)
            current.deleteLastPathComponent()
        }

        var candidates: [URL] = []
        for directory in directories {
            candidates.append(contentsOf: [
                directory.appendingPathComponent("node/bin/node"),
                directory.appendingPathComponent("bin/node"),
                directory.appendingPathComponent("node"),
                directory.appendingPathComponent("nodejs")
            ])
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
