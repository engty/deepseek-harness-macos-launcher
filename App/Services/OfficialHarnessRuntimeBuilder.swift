import CryptoKit
import Foundation

struct OfficialHarnessRuntimeArtifact {
    let manifest: RuntimeManifest
    let artifactURL: URL
}

enum OfficialHarnessRuntimeBuilderError: LocalizedError {
    case sourceRuntimeMissing
    case bundledNodeMissing
    case packageManagerMissing
    case installFailed(String)
    case runtimeProbeFailed(String)
    case archiveFailed(String)
    case artifactMissing

    var errorDescription: String? {
        switch self {
        case .sourceRuntimeMissing:
            return "当前 Harness Runtime 不存在，无法准备升级。"
        case .bundledNodeMissing:
            return "当前 Runtime 没有内置 Node，无法在 App 私有目录中升级。"
        case .packageManagerMissing:
            return "当前 Runtime 没有内置 pnpm，无法在 App 私有目录中升级。"
        case .installFailed(let output):
            return "官方 Harness 依赖安装失败：\(SensitiveDataRedactor.redact(output))"
        case .runtimeProbeFailed(let output):
            return "升级后的 Harness Runtime 预检失败：\(SensitiveDataRedactor.redact(output))"
        case .archiveFailed(let output):
            return "无法生成 Runtime 更新包：\(SensitiveDataRedactor.redact(output))"
        case .artifactMissing:
            return "Runtime 更新包没有生成。"
        }
    }
}

/// Rebuilds a complete Runtime in the App-owned cache from the exact package
/// version reported by the official npm registry. The existing bundled
/// Runtime is copied first, so Node, pnpm and every dependency remain private
/// to this App; the user's DSH_HOME and plugin profile are never modified.
@MainActor
final class OfficialHarnessRuntimeBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        currentInstallation: RuntimeInstallation,
        official: OfficialHarnessVersionResult,
        paths: AppPaths,
        shellVersion: String,
        progress: @escaping @MainActor (RuntimeUpdateStage) -> Void
    ) async throws -> OfficialHarnessRuntimeArtifact {
        progress(.preparing)
        guard fileManager.fileExists(atPath: currentInstallation.root.path) else {
            throw OfficialHarnessRuntimeBuilderError.sourceRuntimeMissing
        }

        let node = currentInstallation.root.appendingPathComponent("node/bin/node")
        guard fileManager.isExecutableFile(atPath: node.path) else {
            throw OfficialHarnessRuntimeBuilderError.bundledNodeMissing
        }
        let pnpm = currentInstallation.root.appendingPathComponent("node_modules/pnpm/bin/pnpm.cjs")
        guard fileManager.fileExists(atPath: pnpm.path) else {
            throw OfficialHarnessRuntimeBuilderError.packageManagerMissing
        }

        let updatesRoot = paths.caches
            .appendingPathComponent("updates/official-staging", isDirectory: true)
        let staging = updatesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedRuntime = staging.appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let copy = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [currentInstallation.root.path, stagedRuntime.path],
            timeout: 15 * 60
        )
        guard copy.status == 0 else {
            throw OfficialHarnessRuntimeBuilderError.installFailed(copy.output)
        }

        progress(.downloading)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            stagedRuntime.appendingPathComponent("node/bin").path,
            stagedRuntime.appendingPathComponent("node_modules/.bin").path,
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")
        // The bundled Runtime may carry a mirror configured for the original
        // npm install. Runtime updates must resolve the exact version reported
        // by the official registry, so do not inherit a stale mirror or a
        // user-level npm registry override here.
        environment["npm_config_registry"] = "https://registry.npmjs.org"
        environment["NPM_CONFIG_REGISTRY"] = "https://registry.npmjs.org"
        environment["npm_config_ignore_scripts"] = "true"
        environment["CI"] = "1"

        let install = try await SubprocessRunner.run(
            executable: node,
            arguments: [
                pnpm.path,
                "--dir", stagedRuntime.path,
                "add",
                "--ignore-scripts",
                "--lockfile=false",
                // The bundled tree was installed by npm, while this update
                // step uses pnpm. Without --force pnpm can report success but
                // leave the old top-level package link in place.
                "--force",
                "--save-exact",
                "@deepseek-ai/dsh@\(official.version)"
            ],
            environment: environment,
            currentDirectory: stagedRuntime,
            timeout: 15 * 60
        )
        guard install.status == 0 else {
            throw OfficialHarnessRuntimeBuilderError.installFailed(install.output)
        }

        // The official package update may replace the fork provider. Reapply
        // the review-only text filter before archiving so fixed-model Mnemon
        // reviews remain compatible with text-only provider adapters.
        _ = try DefaultProfileInstaller(fileManager: fileManager)
            .syncDshMnemonTextOnlyReviewCompatibility(
                profileWeb: stagedRuntime.appendingPathComponent(
                    "default-profile/profiles/web",
                    isDirectory: true
                ),
                runtimeRoot: stagedRuntime
            )

        progress(.verifying)
        let locator = RuntimeLocator(environment: [
            "HARNESS_RUNTIME_ROOT": stagedRuntime.path,
            "PATH": environment["PATH"] ?? ""
        ])
        let installation: RuntimeInstallation
        do {
            installation = try locator.locate()
        } catch {
            throw OfficialHarnessRuntimeBuilderError.runtimeProbeFailed(error.localizedDescription)
        }
        guard installation.version == official.version else {
            throw OfficialHarnessRuntimeBuilderError.runtimeProbeFailed(
                "期望版本 \(official.version)，实际版本 \(installation.version ?? "unknown")。"
            )
        }

        let versionProbe = try await SubprocessRunner.run(
            executable: installation.command(arguments: ["--version"]).executable,
            arguments: installation.command(arguments: ["--version"]).arguments,
            environment: environment,
            currentDirectory: stagedRuntime,
            timeout: 60
        )
        guard versionProbe.status == 0 else {
            throw OfficialHarnessRuntimeBuilderError.runtimeProbeFailed(versionProbe.output)
        }

        progress(.packaging)
        let artifactURL = paths.caches
            .appendingPathComponent("updates/official-artifacts", isDirectory: true)
            .appendingPathComponent("DeepSeek-Harness-\(official.version)-runtime.tar.gz")
        try fileManager.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: artifactURL.path) {
            try fileManager.removeItem(at: artifactURL)
        }

        let archive = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", artifactURL.path, "-C", stagedRuntime.path, "."],
            timeout: 20 * 60
        )
        guard archive.status == 0 else {
            throw OfficialHarnessRuntimeBuilderError.archiveFailed(archive.output)
        }
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            throw OfficialHarnessRuntimeBuilderError.artifactMissing
        }

        let attributes = try fileManager.attributesOfItem(atPath: artifactURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            throw OfficialHarnessRuntimeBuilderError.artifactMissing
        }

        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "official-\(official.version.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "+", with: "-"))",
            channel: "official-npm",
            architecture: currentArchitecture,
            harness: .init(
                package: "@deepseek-ai/dsh",
                version: official.version,
                commit: "npm-\(official.version)"
            ),
            nodeVersion: try await readNodeVersion(node: node, environment: environment, currentDirectory: stagedRuntime),
            testedPlugins: nil,
            minShellVersion: shellVersion,
            dataFormat: "dsh-home-v1",
            artifact: .init(
                url: artifactURL,
                size: size,
                sha256: try sha256Hex(of: artifactURL)
            ),
            releaseNotesURL: official.packageURL,
            publishedAt: nil
        )
        return OfficialHarnessRuntimeArtifact(manifest: manifest, artifactURL: artifactURL)
    }

    private func readNodeVersion(
        node: URL,
        environment: [String: String],
        currentDirectory: URL
    ) async throws -> String {
        let result = try await SubprocessRunner.run(
            executable: node,
            arguments: ["--version"],
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: 30
        )
        guard result.status == 0 else {
            throw OfficialHarnessRuntimeBuilderError.runtimeProbeFailed(result.output)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
