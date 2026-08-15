import CryptoKit
import Foundation
import Testing
@testable import HarnessLauncher

@Suite(.serialized)
struct AppToolchainTests {
    @Test
    @MainActor
    func downloadsVerifiesAndAtomicallyInstallsPrivateTool() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let payload = Data("#!/bin/sh\necho fixture\n".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ToolchainManifest(
            id: "fixture-tool",
            version: "1.0.0",
            architecture: testArchitecture,
            executableName: "fixture",
            artifactURL: URL(string: "https://example.test/fixture-good")!,
            artifactSize: Int64(payload.count),
            sha256: digest,
            artifactKind: .raw,
            sourceURL: URL(string: "https://example.test/source")!,
            licenseURL: URL(string: "https://example.test/license")!,
            maxBytes: 1024
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolchainDownloadStub.self]
        ToolchainDownloadStub.responses = [manifest.artifactURL: payload]
        defer { ToolchainDownloadStub.responses = [:] }
        let installer = ToolchainInstaller(
            catalog: ToolchainCatalog(manifests: [manifest]),
            session: URLSession(configuration: configuration)
        )
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let progress = ProgressBox()
        let plan = try await installer.install(
            requirement: manifest.requirement,
            paths: paths,
            progress: { progress.append(($0, $1)) }
        )

        #expect(fileManager.isExecutableFile(atPath: plan.executable.path))
        #expect(fileManager.fileExists(atPath: plan.destination.appendingPathComponent("manifest.json").path))
        #expect(try String(contentsOf: plan.executable, encoding: .utf8) == String(data: payload, encoding: .utf8))
        #expect(progress.values.last?.0 == Int64(payload.count))
        #expect(progress.values.last?.1 == Int64(payload.count))
    }

    @Test
    @MainActor
    func rejectsHashMismatchWithoutCreatingToolchainDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let manifest = ToolchainManifest(
            id: "fixture-tool",
            version: "1.0.0",
            architecture: testArchitecture,
            executableName: "fixture",
            artifactURL: URL(string: "https://example.test/fixture-bad")!,
            artifactSize: 4,
            sha256: String(repeating: "0", count: 64),
            artifactKind: .raw,
            sourceURL: URL(string: "https://example.test/source")!,
            licenseURL: URL(string: "https://example.test/license")!,
            maxBytes: 1024
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolchainDownloadStub.self]
        ToolchainDownloadStub.responses = [manifest.artifactURL: Data("test".utf8)]
        defer { ToolchainDownloadStub.responses = [:] }
        let installer = ToolchainInstaller(
            catalog: ToolchainCatalog(manifests: [manifest]),
            session: URLSession(configuration: configuration)
        )
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        await #expect(throws: ToolchainInstallerError.artifactHashMismatch) {
            try await installer.install(requirement: manifest.requirement, paths: paths)
        }
        #expect(!fileManager.fileExists(atPath: paths.toolchain.appendingPathComponent("fixture-tool").path))
    }

    @Test
    func recognizesOnlyAllowListedMissingExecutable() {
        #expect(
            PluginDependencyService.installableRequirement(
                from: "/bin/sh: jq: command not found"
            ) == ToolchainRequirement(id: "jq", version: "1.7.1")
        )
        #expect(
            PluginDependencyService.installableRequirement(
                from: "please run brew install anything"
            ) == nil
        )
    }

    @Test
    func parsesOnlyPnpmIgnoredBuildScriptPackageNames() {
        let output = """
        Ignored build scripts: @scope/plugin, esbuild
        Run "pnpm approve-builds" to pick which dependencies should be allowed.
        """
        #expect(
            PluginCommandRunner.parseBuildApprovalPackages(output) == ["@scope/plugin", "esbuild"]
        )
        #expect(PluginCommandRunner.parseBuildApprovalPackages("allowBuilds: true") == nil)
    }

    @Test
    func writesExactPnpmBuildApprovalIntoStagingProfile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("pnpm-workspace.yaml")
        try Data("""
        packages:
          - .

        nodeLinker: hoisted
        autoInstallPeers: false
        """.utf8).write(to: workspace)

        try PnpmWorkspaceConfig.approveBuildScripts(
            ["@scope/plugin", "esbuild", "esbuild"],
            in: root
        )
        let result = try String(contentsOf: workspace, encoding: .utf8)
        #expect(result.contains("allowBuilds:"))
        #expect(result.contains("  @scope/plugin: true"))
        #expect(result.contains("  esbuild: true"))
        #expect(result.components(separatedBy: "esbuild: true").count == 2)
    }

    @Test
    func initializesHarnessWorkspaceWhenStagingProfileIsNew() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try PnpmWorkspaceConfig.approveBuildScripts(["esbuild"], in: root)

        let workspace = root.appendingPathComponent("pnpm-workspace.yaml")
        let result = try String(contentsOf: workspace, encoding: .utf8)
        #expect(result.contains("packages:\n  - ."))
        #expect(result.contains("nodeLinker: hoisted"))
        #expect(result.contains("  esbuild: true"))
    }

    private var testArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

private final class ToolchainDownloadStub: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let data = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [(Int64, Int64)] = []

    func append(_ value: (Int64, Int64)) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
