import Foundation
import CryptoKit
import Testing
@testable import HarnessLauncher

struct RuntimeManifestTests {
    @Test
    func unsignedManifestValidatesHTTPSHashAndSafeRuntimeID() throws {
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "r1",
            channel: "stable",
            architecture: "arm64",
            harness: .init(package: "dsh", version: "1", commit: "abc"),
            nodeVersion: "22",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(
                url: URL(string: "https://example.com/runtime")!,
                size: 1,
                sha256: String(repeating: "0", count: 64)
            ),
            releaseNotesURL: nil,
            publishedAt: nil
        )

        try RuntimeManifestVerifier.validate(
            manifest: manifest,
            architecture: currentArchitecture,
            shellVersion: "0.1.0"
        )
        #expect(manifest.hasSafeRuntimeID)
    }

    @Test
    func manifestValidationRejectsInvalidHashAndShellVersion() throws {
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "runtime-2026-08-15",
            channel: "stable",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "0.1.0", commit: "fixture"),
            nodeVersion: "22.18.0",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(url: URL(string: "https://updates.example.com/runtime.tar")!, size: 42, sha256: "bad"),
            releaseNotesURL: nil,
            publishedAt: nil
        )
        #expect(throws: RuntimeManifestError.invalidArtifactHash) {
            try RuntimeManifestVerifier.validate(
                manifest: manifest,
                architecture: currentArchitecture,
                shellVersion: "0.1.0"
            )
        }

        let validManifest = RuntimeManifest(
            schemaVersion: manifest.schemaVersion,
            runtimeID: manifest.runtimeID,
            channel: manifest.channel,
            architecture: manifest.architecture,
            harness: manifest.harness,
            nodeVersion: manifest.nodeVersion,
            testedPlugins: manifest.testedPlugins,
            minShellVersion: manifest.minShellVersion,
            dataFormat: manifest.dataFormat,
            artifact: .init(
                url: manifest.artifact.url,
                size: manifest.artifact.size,
                sha256: String(repeating: "a", count: 64)
            ),
            releaseNotesURL: manifest.releaseNotesURL,
            publishedAt: manifest.publishedAt
        )
        #expect(throws: RuntimeManifestError.incompatibleShellVersion(required: "0.1.0", current: "0.0.9")) {
            try RuntimeManifestVerifier.validate(
                manifest: validManifest,
                architecture: currentArchitecture,
                shellVersion: "0.0.9"
            )
        }
    }

    @Test
    @MainActor
    func updateServiceChecksUnsignedHTTPSFeed() async throws {
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "runtime-feed-test",
            channel: "stable",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "0.1.1", commit: "fixture"),
            nodeVersion: "22.18.0",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(url: URL(string: "https://updates.example.com/runtime-feed-test.tar")!, size: 42, sha256: String(repeating: "b", count: 64)),
            releaseNotesURL: nil,
            publishedAt: nil
        )
        let feedData = try JSONEncoder().encode(manifest)

        let feedURL = URL(string: "https://updates.example.com/manifest.json")!
        URLProtocolStub.responses = [feedURL: (200, feedData)]
        defer { URLProtocolStub.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let service = RuntimeUpdateService(
            environment: [
                "HARNESS_UPDATE_MANIFEST_URL": feedURL.absoluteString,
                "HARNESS_SHELL_VERSION": "0.1.0"
            ],
            session: session
        )

        let result = try await service.check(currentHarnessVersion: "0.1.0")
        #expect(result.manifest.runtimeID == "runtime-feed-test")
        #expect(result.isUpdateAvailable)
    }

    @Test
    func launcherPhaseReportsReadiness() {
        #expect(LauncherPhase.ready(URL(string: "http://127.0.0.1:1234")!).isReady)
        #expect(!LauncherPhase.stopped.isReady)
    }

    @Test
    func decodesDeepSeekBalanceResponse() throws {
        let source = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.50","granted_balance":1.5,"topped_up_balance":"11.00"}]}"#.utf8)
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: source)

        #expect(response.isAvailable)
        #expect(response.balanceInfos.first?.currency == "CNY")
        #expect(response.balanceInfos.first?.totalBalance == "12.50")
        #expect(response.balanceInfos.first?.grantedBalance == "1.5")
    }

    @Test
    func classifiesChineseYuanBalanceForToolbar() {
        func info(_ amount: String) -> DeepSeekBalanceInfo {
            DeepSeekBalanceInfo(
                currency: "CNY",
                totalBalance: amount,
                grantedBalance: "0",
                toppedUpBalance: amount
            )
        }

        #expect(DeepSeekBalanceTone(balanceInfos: [info("100")]) == .healthy)
        #expect(DeepSeekBalanceTone(balanceInfos: [info("50")]) == .warning)
        #expect(DeepSeekBalanceTone(balanceInfos: [info("49.99")]) == .critical)
        #expect(DeepSeekBalanceTone(balanceInfos: [info("invalid")]) == .unknown)
    }

    @Test
    @MainActor
    func activatesAndRollsBackTarRuntime() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceRuntime = root.appendingPathComponent("source-runtime", isDirectory: true)
        let bin = sourceRuntime.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let dsh = bin.appendingPathComponent("dsh")
        try Data("#!/bin/sh\necho 'dsh web: http://127.0.0.1:1234'\n".utf8).write(to: dsh)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)

        let artifact = root.appendingPathComponent("runtime.tar", isDirectory: false)
        try runTool("/usr/bin/tar", arguments: ["-cf", artifact.path, "-C", sourceRuntime.path, "."])
        let artifactData = try Data(contentsOf: artifact)
        let digest = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "test-runtime",
            channel: "test",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "test.1", commit: "fixture"),
            nodeVersion: "22",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(url: URL(string: "https://example.com/runtime.tar")!, size: Int64(artifactData.count), sha256: digest),
            releaseNotesURL: nil,
            publishedAt: nil
        )
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()
        let previousManifest = Data(#"{"runtimeId":"old-runtime","runtimePath":"/tmp/old-runtime"}"#.utf8)
        try previousManifest.write(to: paths.activeRuntimeManifest)

        let installer = RuntimeArchiveInstaller()
        let activation = try await installer.activate(manifest: manifest, artifactURL: artifact, paths: paths)
        #expect(fileManager.isExecutableFile(atPath: activation.installation.executable.path))
        #expect(FileManager.default.fileExists(atPath: paths.activeRuntimeManifest.path))
        #expect(FileManager.default.fileExists(atPath: paths.lastKnownGoodRuntimeManifest.path))

        try installer.rollback(activation: activation, paths: paths)
        let restoredManifest = try Data(contentsOf: paths.activeRuntimeManifest)
        #expect(restoredManifest == previousManifest)

        // When the previous runtime was discovered from the bundled/override
        // locator but had no active pointer yet, rollback still restores a
        // usable pointer instead of leaving the app without a runtime.
        try fileManager.removeItem(at: paths.activeRuntimeManifest)
        let previousInstallation = RuntimeInstallation(
            executable: dsh,
            root: sourceRuntime,
            version: "previous",
            nodeExecutable: nil
        )
        let secondActivation = try await installer.activate(
            manifest: manifest,
            artifactURL: artifact,
            paths: paths,
            previousInstallation: previousInstallation
        )
        try installer.rollback(activation: secondActivation, paths: paths)
        let restoredRecord = try JSONDecoder().decode(
            RuntimeActivationRecord.self,
            from: Data(contentsOf: paths.activeRuntimeManifest)
        )
        #expect(restoredRecord.runtimePath == sourceRuntime.path)
    }

    @Test
    func locatesBundledNodeAlongsideRuntime() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let dsh = root.appendingPathComponent("bin/dsh")
        let node = root.appendingPathComponent("node/bin/node")
        try fileManager.createDirectory(at: dsh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dsh)
        try Data("#!/bin/sh\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let installation = try RuntimeLocator(environment: [
            "HARNESS_RUNTIME_ROOT": root.path,
            "PATH": ""
        ]).locate()
        #expect(installation.executable.path == dsh.path)
        #expect(installation.nodeExecutable?.path == node.path)
    }

    @Test
    @MainActor
    func rejectsRuntimeArchiveSymlinkEscapingStagingRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceRuntime = root.appendingPathComponent("source-runtime", isDirectory: true)
        let bin = sourceRuntime.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let dsh = bin.appendingPathComponent("dsh")
        try Data("#!/bin/sh\n".utf8).write(to: dsh)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)
        try fileManager.createSymbolicLink(
            atPath: sourceRuntime.appendingPathComponent("escape").path,
            withDestinationPath: "/tmp"
        )

        let artifact = root.appendingPathComponent("unsafe-runtime.tar")
        try runTool("/usr/bin/tar", arguments: ["-cf", artifact.path, "-C", sourceRuntime.path, "."])
        let artifactData = try Data(contentsOf: artifact)
        let digest = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "unsafe-runtime",
            channel: "test",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "test.1", commit: "fixture"),
            nodeVersion: "22",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(url: URL(string: "https://example.com/runtime.tar")!, size: Int64(artifactData.count), sha256: digest),
            releaseNotesURL: nil,
            publishedAt: nil
        )
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        var didReject = false
        do {
            _ = try await RuntimeArchiveInstaller().activate(manifest: manifest, artifactURL: artifact, paths: paths)
        } catch {
            didReject = true
        }
        #expect(didReject)
    }

    @Test
    func redactsSecretsBeforeDiagnosticsAndLogging() {
        let source = "Authorization: Bearer abc123 api_key=sk-test-secret password='secret-value'"
        let result = SensitiveDataRedactor.redact(source)
        #expect(!result.contains("abc123"))
        #expect(!result.contains("sk-test-secret"))
        #expect(!result.contains("secret-value"))
        #expect(result.contains("[REDACTED]"))
    }

    @Test
    func dataSlotCloneActivationAndRollbackPreserveUserProfile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()
        let profile = paths.profileWeb.appendingPathComponent("package.json")
        try fileManager.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"active-profile","lockfileVersion":1}"#.utf8).write(to: profile)

        let manager = DataSlotManager()
        let candidate = try manager.cloneActiveSlot(paths: paths)
        let candidateProfile = candidate.appendingPathComponent("dsh-home/profiles/web/package.json")
        try Data(#"{"name":"candidate-profile","lockfileVersion":1}"#.utf8).write(to: candidateProfile)
        let activation = try manager.activate(candidateSlot: candidate, paths: paths)
        let activatedProfile = try String(
            contentsOf: paths.profileWeb.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        #expect(activatedProfile.contains("candidate-profile"))

        let secondCandidate = try manager.cloneActiveSlot(paths: paths)
        let secondProfile = secondCandidate.appendingPathComponent("dsh-home/profiles/web/package.json")
        try Data(#"{"name":"second-candidate","lockfileVersion":1}"#.utf8).write(to: secondProfile)
        let secondActivation = try manager.activate(candidateSlot: secondCandidate, paths: paths)
        let backups = try fileManager.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
        #expect(backups.filter { $0.lastPathComponent.hasPrefix("data-slot-") }.count >= 2)

        try manager.rollback(secondActivation, paths: paths)
        try manager.rollback(activation, paths: paths)
        let restored = try String(contentsOf: paths.profileWeb.appendingPathComponent("package.json"), encoding: .utf8)
        #expect(restored.contains("active-profile"))
    }

    @Test
    @MainActor
    func runtimePreflightRunsVersionAndWebConfigChecks() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/dsh")
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = #"""
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "0.1.0-test"
  exit 0
fi
if [ "$1" = "--profile" ] && [ "$2" = "web" ] && [ "$3" = "--dump-config" ]; then
  echo "- id: fixture"
  exit 0
fi
exit 1
"""#
        try Data(script.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let home = root.appendingPathComponent("preflight-home", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("cwd", isDirectory: true)
        try await RuntimePreflightService().run(
            installation: RuntimeInstallation(executable: executable, root: root, version: "0.1.0-test", nodeExecutable: nil),
            paths: paths,
            dshHome: home,
            currentDirectory: currentDirectory
        )
        #expect(fileManager.fileExists(atPath: home.path))
    }

    @Test
    func pluginMetadataCapturesSourceLicenseAndLifecycleScripts() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
        let packageDirectory = profile.appendingPathComponent("node_modules/fixture-plugin", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let profileManifest = #"{"dsh":{"profile":{"bundles":["fixture-plugin"]}},"dependencies":{"fixture-plugin":"1.2.3"}}"#
        try Data(profileManifest.utf8).write(to: profile.appendingPathComponent("package.json"))
        let packageManifest = #"{"name":"fixture-plugin","version":"1.2.3","license":"MIT","repository":{"type":"git","url":"https://example.com/fixture.git"},"dist":{"tarball":"https://registry.example.com/fixture.tgz"},"scripts":{"prepare":"echo build"}}"#
        try Data(packageManifest.utf8).write(to: packageDirectory.appendingPathComponent("package.json"))

        let store = PluginMetadataStore()
        let metadata = try store.collect(profileURL: profile, arguments: ["add", "fixture-plugin"])
        #expect(metadata.packages.count == 1)
        #expect(metadata.packages.first?.version == "1.2.3")
        #expect(metadata.packages.first?.license == "MIT")
        #expect(metadata.packages.first?.lifecycleScripts == ["prepare"])
        #expect(metadata.packages.first?.distributionURL == "https://registry.example.com/fixture.tgz")

        let metadataURL = root.appendingPathComponent("dsh-home/launcher/plugin-metadata.json")
        try store.write(metadata, to: metadataURL)
        let permissions = try fileManager.attributesOfItem(atPath: metadataURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    @MainActor
    func disablingPluginUsesOfficialPatchRowAndKeepsPackageInstalled() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let packageDirectory = paths.profileWeb.appendingPathComponent("node_modules/fixture-plugin", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let profileManifest = #"{"dsh":{"profile":{"bundles":["fixture-plugin"]}},"dependencies":{"fixture-plugin":"1.0.0"}}"#
        try Data(profileManifest.utf8).write(to: paths.profileWeb.appendingPathComponent("package.json"))
        let packageManifest = #"{"name":"fixture-plugin","version":"1.0.0","dsh":{"bundle":{"patch":"./cordis.bundle.yml"}}}"#
        try Data(packageManifest.utf8).write(to: packageDirectory.appendingPathComponent("package.json"))
        try Data("- insert:\n    - id: fixture-row\n      name: fixture-plugin\n".utf8)
            .write(to: packageDirectory.appendingPathComponent("cordis.bundle.yml"))

        let manager = ProfileManager(paths: paths)
        let plugin = try #require(manager.refresh().first)
        try manager.setEnabled(plugin, enabled: false)
        #expect(fileManager.fileExists(atPath: packageDirectory.appendingPathComponent("package.json").path))
        #expect(try String(contentsOf: paths.overlay, encoding: .utf8).contains("fixture-row"))
        #expect(try String(contentsOf: paths.overlay, encoding: .utf8).contains("disabled: true"))

        try manager.setEnabled(plugin, enabled: true)
        #expect(!fileManager.fileExists(atPath: paths.overlay.path))
        #expect(fileManager.fileExists(atPath: packageDirectory.appendingPathComponent("package.json").path))
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: (status: Int, data: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
