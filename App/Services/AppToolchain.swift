import CryptoKit
import Foundation

struct ToolchainRequirement: Equatable, Hashable {
    let id: String
    let version: String?

    init(id: String, version: String? = nil) {
        self.id = id
        self.version = version
    }
}

enum ToolchainArtifactKind: String, Codable, Equatable {
    case raw
}

struct ToolchainManifest: Codable, Equatable {
    let id: String
    let version: String
    let architecture: String
    let executableName: String
    let artifactURL: URL
    let artifactSize: Int64
    let sha256: String
    let artifactKind: ToolchainArtifactKind
    let sourceURL: URL
    let licenseURL: URL
    let maxBytes: Int64

    var requirement: ToolchainRequirement {
        ToolchainRequirement(id: id, version: version)
    }
}

struct ToolchainInstallPlan: Equatable {
    let manifest: ToolchainManifest
    let destination: URL

    var executable: URL {
        destination
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(manifest.executableName)
    }

    var confirmationText: String {
        """
        • \(manifest.id) \(manifest.version)（App 私有依赖）
          来源：\(manifest.sourceURL.absoluteString)
          下载：\(manifest.artifactSize) bytes，SHA-256：\(manifest.sha256)
          目录：\(destination.path)
          只对 DeepSeek Harness 子进程生效，不写入系统目录或全局 PATH。
        """
    }
}

struct ToolchainCatalog: Equatable {
    let manifests: [String: ToolchainManifest]

    init(manifests: [ToolchainManifest]) {
        self.manifests = Dictionary(uniqueKeysWithValues: manifests.map {
            ("\($0.id):\($0.version):\($0.architecture)", $0)
        })
    }

    func manifest(for requirement: ToolchainRequirement) -> ToolchainManifest? {
        if let version = requirement.version {
            return manifests["\(requirement.id):\(version):\(currentArchitecture)"]
        }
        return manifests.values
            .filter { $0.id == requirement.id && $0.architecture == currentArchitecture }
            .sorted { $0.version > $1.version }
            .first
    }

    static let bundled = ToolchainCatalog(manifests: [
        ToolchainManifest(
            id: "jq",
            version: "1.7.1",
            architecture: "arm64",
            executableName: "jq",
            artifactURL: URL(string: "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64")!,
            artifactSize: 807_984,
            sha256: "0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a",
            artifactKind: .raw,
            sourceURL: URL(string: "https://github.com/jqlang/jq")!,
            licenseURL: URL(string: "https://github.com/jqlang/jq/blob/jq-1.7.1/COPYING")!,
            maxBytes: 2_000_000
        ),
        ToolchainManifest(
            id: "jq",
            version: "1.7.1",
            architecture: "x86_64",
            executableName: "jq",
            artifactURL: URL(string: "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64")!,
            artifactSize: 851_328,
            sha256: "4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443",
            artifactKind: .raw,
            sourceURL: URL(string: "https://github.com/jqlang/jq")!,
            licenseURL: URL(string: "https://github.com/jqlang/jq/blob/jq-1.7.1/COPYING")!,
            maxBytes: 2_000_000
        )
    ])
}

enum ToolchainInstallerError: LocalizedError, Equatable {
    case unsupportedRequirement(String)
    case invalidURL
    case invalidResponse
    case downloadTooLarge
    case artifactSizeMismatch(expected: Int64, actual: Int64)
    case artifactHashMismatch
    case unsupportedArtifact
    case unsafeExecutableName
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRequirement(let id):
            return "没有受控清单允许自动安装依赖：\(id)。"
        case .invalidURL:
            return "依赖下载地址不是 HTTPS。"
        case .invalidResponse:
            return "依赖下载服务器返回了无效响应。"
        case .downloadTooLarge:
            return "依赖下载超过允许的大小上限。"
        case .artifactSizeMismatch(let expected, let actual):
            return "依赖大小校验失败（预期 \(expected)，实际 \(actual)）。"
        case .artifactHashMismatch:
            return "依赖 SHA-256 校验失败，未安装任何文件。"
        case .unsupportedArtifact:
            return "依赖归档格式不在受控清单范围内。"
        case .unsafeExecutableName:
            return "依赖可执行文件名不安全。"
        case .installationFailed(let message):
            return "依赖安装失败：\(message)"
        }
    }
}

@MainActor
final class ToolchainInstaller {
    private let fileManager: FileManager
    private let catalog: ToolchainCatalog
    private let session: URLSession

    init(
        fileManager: FileManager = .default,
        catalog: ToolchainCatalog = .bundled,
        session: URLSession? = nil
    ) {
        self.fileManager = fileManager
        self.catalog = catalog
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func install(
        requirement: ToolchainRequirement,
        paths: AppPaths,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> ToolchainInstallPlan {
        guard let manifest = catalog.manifest(for: requirement) else {
            throw ToolchainInstallerError.unsupportedRequirement(requirement.id)
        }
        guard manifest.artifactURL.scheme == "https",
              manifest.sourceURL.scheme == "https",
              manifest.licenseURL.scheme == "https" else {
            throw ToolchainInstallerError.invalidURL
        }
        guard isSafeExecutableName(manifest.executableName) else {
            throw ToolchainInstallerError.unsafeExecutableName
        }

        try paths.prepare()
        let destination = paths.toolchain
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
        let plan = ToolchainInstallPlan(manifest: manifest, destination: destination)
        if fileManager.isExecutableFile(atPath: plan.executable.path),
           isInstalledManifestValid(plan: plan) {
            return plan
        }

        let request = URLRequest(url: manifest.artifactURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await session.data(for: request)
        progress?(0, manifest.artifactSize)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else {
            throw ToolchainInstallerError.invalidResponse
        }
        guard Int64(data.count) <= manifest.maxBytes else {
            throw ToolchainInstallerError.downloadTooLarge
        }
        guard Int64(data.count) == manifest.artifactSize else {
            throw ToolchainInstallerError.artifactSizeMismatch(
                expected: manifest.artifactSize,
                actual: Int64(data.count)
            )
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw ToolchainInstallerError.artifactHashMismatch
        }
        progress?(Int64(data.count), manifest.artifactSize)

        let staging = paths.toolchain
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: staging.appendingPathComponent("bin", isDirectory: true),
                withIntermediateDirectories: true
            )
            guard manifest.artifactKind == .raw else {
                throw ToolchainInstallerError.unsupportedArtifact
            }
            let executable = staging
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(manifest.executableName)
            try data.write(to: executable, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(
                to: staging.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ToolchainInstallerError.installationFailed(
                    "目标版本目录已存在但校验不一致，已保留原目录。"
                )
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch let error as ToolchainInstallerError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ToolchainInstallerError.installationFailed(error.localizedDescription)
        }
        return plan
    }

    private func isInstalledManifestValid(plan: ToolchainInstallPlan) -> Bool {
        guard let data = try? Data(contentsOf: plan.destination.appendingPathComponent("manifest.json")),
              let installed = try? JSONDecoder().decode(ToolchainManifest.self, from: data) else {
            return false
        }
        return installed == plan.manifest
    }

    private func isSafeExecutableName(_ name: String) -> Bool {
        !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent
        && !name.contains("/") && !name.contains("\\")
    }
}

private var currentArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}
