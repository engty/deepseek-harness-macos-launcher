import Foundation
import CryptoKit
import Testing
@testable import HarnessLauncher

// The URLProtocol stub uses shared static response dictionaries; serial
// execution keeps parallel tests from clearing each other's responses.
@Suite(.serialized)
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
            nodeVersion: "22.19.0",
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
            nodeVersion: "22.19.0",
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
    @MainActor
    func officialHarnessVersionServiceDetectsNewNpmVersion() async throws {
        let endpoint = URL(string: "https://updates.example.com/npm-dsh-latest")!
        URLProtocolStub.responses = [
            endpoint: (
                200,
                Data(#"{"versions":{"0.1.0-rc.6":{},"0.1.1-rc.2":{},"0.1.1-rc.3":{}}}"#.utf8)
            )
        ]
        defer { URLProtocolStub.responses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OfficialHarnessVersionService(
            environment: ["HARNESS_OFFICIAL_VERSION_URL": endpoint.absoluteString],
            session: URLSession(configuration: configuration)
        )

        let result = try await service.check()
        #expect(result.version == "0.1.1-rc.3")
        #expect(result.isUpdateAvailable(currentHarnessVersion: "0.1.0-rc.6"))
        #expect(!result.isUpdateAvailable(currentHarnessVersion: "0.1.1-rc.3"))
    }

    @Test
    @MainActor
    func officialHarnessVersionServiceRejectsMalformedVersion() async throws {
        let endpoint = URL(string: "https://updates.example.com/npm-dsh-invalid")!
        URLProtocolStub.responses = [
            endpoint: (200, Data(#"{"version":"0.1.1rc.2"}"#.utf8))
        ]
        defer { URLProtocolStub.responses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = OfficialHarnessVersionService(
            environment: ["HARNESS_OFFICIAL_VERSION_URL": endpoint.absoluteString],
            session: URLSession(configuration: configuration)
        )

        await #expect(throws: OfficialHarnessVersionError.invalidVersion) {
            try await service.check()
        }
    }

    @Test
    @MainActor
    func appUpdateServiceChecksGitHubRelease() async throws {
        let feedURL = URL(string: "https://updates.example.com/app/latest")!
        let payload = Data(#"""
        {
            "tag_name":"v0.1.11",
            "name":"DeepSeek Harness v0.1.11",
            "html_url":"https://github.com/engty/deepseek-harness-macos-launcher/releases/tag/v0.1.11",
            "published_at":"2026-08-15T00:00:00Z"
        }
        """#.utf8)
        URLProtocolStub.appResponses = [feedURL: (200, payload)]
        defer { URLProtocolStub.appResponses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = AppUpdateService(
            environment: ["HARNESS_APP_UPDATE_URL": feedURL.absoluteString],
            session: URLSession(configuration: configuration)
        )

        let result = try await service.check(currentVersion: "0.1.10-local")
        #expect(result.latestVersion == "0.1.11")
        #expect(result.isUpdateAvailable)
    }

    @Test
    func launcherPhaseReportsReadiness() {
        #expect(LauncherPhase.ready(URL(string: "http://127.0.0.1:1234")!).isReady)
        #expect(!LauncherPhase.stopped.isReady)
    }

    @Test
    @MainActor
    func readinessParserPreservesHarnessBrowserToken() {
        let url = HarnessProcessController.readinessURL(
            from: "dsh web: http://127.0.0.1:43127/?token=opaque-bootstrap-token\n"
        )
        #expect(url?.absoluteString == "http://127.0.0.1:43127/?token=opaque-bootstrap-token")
        #expect(HarnessProcessController.readinessURL(
            from: "dsh web: http://192.168.1.2:43127/?token=opaque"
        ) == nil)
    }

    @Test
    func redactsHarnessBrowserTokenFromLogs() {
        let result = SensitiveDataRedactor.redact(
            "dsh web: http://127.0.0.1:43127/?token=opaque-bootstrap-token"
        )
        #expect(!result.contains("opaque-bootstrap-token"))
        #expect(result.contains("token=[REDACTED]"))
    }

    @Test
    func discountScheduleUsesBeijingBusinessHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        func date(hour: Int, minute: Int = 0, day: Int = 24) -> Date {
            calendar.date(
                from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
            )!
        }

        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 9)) == .peak)
        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 11, minute: 59)) == .peak)
        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 12)) == .offPeak)
        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 14)) == .peak)
        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 18)) == .offPeak)
        #expect(DeepSeekDiscountPeriod.current(at: date(hour: 10, day: 29)) == .offPeak)
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

        let command = installation.command(arguments: ["--version"])
        #expect(command.executable.path == dsh.path)
        #expect(command.arguments == ["--version"])
    }

    @Test
    func launchesJavaScriptEntryPointThroughBundledNode() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let dsh = root.appendingPathComponent("bin/dsh")
        let node = root.appendingPathComponent("node/bin/node")
        try fileManager.createDirectory(at: dsh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\nconsole.log('ok')\n".utf8).write(to: dsh)
        try Data("#!/bin/sh\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let installation = try RuntimeLocator(environment: [
            "HARNESS_RUNTIME_ROOT": root.path,
            "PATH": ""
        ]).locate()
        let command = installation.command(arguments: ["--version"])
        #expect(command.executable.path == node.path)
        #expect(command.arguments == [dsh.path, "--version"])
    }

    @Test
    @MainActor
    func allowsOnlyHTTPSOriginsForEmbeddedPluginStore() {
        #expect(HarnessWebView.isAllowedEmbeddedPluginOrigin(URL(string: "https://deepseek1024.com/embed/store")!))
        #expect(!HarnessWebView.isAllowedEmbeddedPluginOrigin(URL(string: "http://deepseek1024.com/embed/store")!))
        #expect(!HarnessWebView.isAllowedEmbeddedPluginOrigin(URL(string: "https://cdn.deepseek1024.com/store.js")!))
        #expect(!HarnessWebView.isAllowedEmbeddedPluginOrigin(URL(string: "https://example.com/embed/store")!))
    }

    @Test
    func seedsBundledDefaultProfileOnlyWhenProfileIsMissing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let bundledProfile = runtimeRoot
            .appendingPathComponent("default-profile/profiles/web", isDirectory: true)
        try fileManager.createDirectory(at: bundledProfile, withIntermediateDirectories: true)
        try Data(#"{"name":"dsh-profile-web","dependencies":{"dsh1024":"0.5.0"}}"#.utf8)
            .write(to: bundledProfile.appendingPathComponent("package.json"))

        let installer = DefaultProfileInstaller(fileManager: fileManager)
        #expect(try installer.seedIfNeeded(paths: paths, runtimeRoot: runtimeRoot))
        #expect(fileManager.fileExists(atPath: paths.profileWeb.appendingPathComponent("package.json").path))

        try Data(#"{"name":"user-profile","dependencies":{}}"#.utf8)
            .write(to: paths.profileWeb.appendingPathComponent("package.json"))
        #expect(try !installer.seedIfNeeded(paths: paths, runtimeRoot: runtimeRoot))
        let preserved = try Data(contentsOf: paths.profileWeb.appendingPathComponent("package.json"))
        #expect(String(decoding: preserved, as: UTF8.self).contains("user-profile"))
    }

    @Test
    func refreshesBundledBetterDshPetAdapterWithoutReplacingUserProfile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let bundledPackage = runtimeRoot
            .appendingPathComponent("default-profile/profiles/web/node_modules/better-dsh-pet", isDirectory: true)
        let activePackage = paths.profileWeb
            .appendingPathComponent("node_modules/better-dsh-pet", isDirectory: true)
        try fileManager.createDirectory(at: bundledPackage, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: activePackage, withIntermediateDirectories: true)
        let manifest = #"{"name":"better-dsh-pet","version":"0.3.5"}"#
        try Data(manifest.utf8).write(to: bundledPackage.appendingPathComponent("package.json"))
        try Data(manifest.utf8).write(to: activePackage.appendingPathComponent("package.json"))
        let sourceMain = bundledPackage.appendingPathComponent("runtime/electron-helper/main.js")
        let activeMain = activePackage.appendingPathComponent("runtime/electron-helper/main.js")
        try fileManager.createDirectory(at: sourceMain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: activeMain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new-adapter".utf8).write(to: sourceMain)
        try Data("old-adapter".utf8).write(to: activeMain)
        let requiredFiles = [
            "lib/index.js", "lib/client.js", "lib/pet-helper-process.js",
            "runtime/electron-helper/preload.js", "runtime/electron-helper/renderer.js",
            "scripts/ensure-electron.mjs", "cordis.patch.yml"
        ]
        for relativePath in requiredFiles {
            let source = bundledPackage.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("adapter".utf8).write(to: source)
        }

        let installer = DefaultProfileInstaller(fileManager: fileManager)
        #expect(try installer.syncBetterDshPetAdapter(paths: paths, runtimeRoot: runtimeRoot))
        #expect(String(decoding: try Data(contentsOf: activeMain), as: UTF8.self) == "new-adapter")
        #expect(String(decoding: try Data(contentsOf: activePackage.appendingPathComponent("package.json")), as: UTF8.self).contains("0.3.5"))
    }

    @Test
    func adaptsDshMnemonProjectionForLegacyRuntimeAndRestoresModernShape() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let packageDirectory = paths.profileWeb.appendingPathComponent(
            "node_modules/dsh-mnemon",
            isDirectory: true
        )
        let sourceURL = packageDirectory.appendingPathComponent("lib/index.js")
        try fileManager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"dsh-mnemon","version":"0.3.5"}"#.utf8)
            .write(to: packageDirectory.appendingPathComponent("package.json"))
        let modernSource = [
            "const projection = {",
            "\tkey: \"mnemonSubagentTokenUsage\",",
            "\tstateVersion: 1,",
            "\tstateSchema: tokenUsageStateSchema,",
            "\tinit: () => ({ descriptorSeen: false }),",
            "\tapply: (state) => state,",
            "\twire: {",
            "\t\tviewSchema: tokenUsageSchema.nullable(),",
            "\t\tview: (state) => state.descriptorSeen ? state.totals : null",
            "\t}",
            "};"
        ].joined(separator: "\n")
        try Data(modernSource.utf8).write(to: sourceURL)

        let installer = DefaultProfileInstaller(fileManager: fileManager)
        #expect(try installer.syncDshMnemonProjectionCompatibility(
            paths: paths,
            runtimeVersion: "0.1.0-rc.6"
        ))
        let legacy = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(legacy.contains("schema: tokenUsageSchema.nullable(),"))
        #expect(legacy.contains("view: (state) => state.descriptorSeen ? state.totals : null"))
        #expect(!legacy.contains("stateSchema: tokenUsageStateSchema"))
        #expect(!legacy.contains("viewSchema: tokenUsageSchema.nullable()"))

        #expect(try installer.syncDshMnemonProjectionCompatibility(
            paths: paths,
            runtimeVersion: "0.1.1-rc.2"
        ))
        let restored = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(restored.contains("stateSchema: tokenUsageStateSchema,"))
        #expect(restored.contains("viewSchema: tokenUsageSchema.nullable(),"))
        #expect(restored.contains("wire: {"))
    }

    @Test
    func filtersImagesOnlyForFixedModelMnemonReviews() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let mnemonPackage = paths.profileWeb.appendingPathComponent(
            "node_modules/dsh-mnemon",
            isDirectory: true
        )
        let mnemonSourceURL = mnemonPackage.appendingPathComponent("lib/index.js")
        try fileManager.createDirectory(at: mnemonSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"dsh-mnemon","version":"0.3.5"}"#.utf8)
            .write(to: mnemonPackage.appendingPathComponent("package.json"))
        let mnemonSource = [
            "\t\t\tconst resolvedAgentOptions = fixed === void 0 ? baseAgentOptions : {",
            "\t\t\t\t...baseAgentOptions ?? {},",
            "\t\t\t\tprovider: fixed.provider,",
            "\t\t\t\tmodel: fixed.model",
            "\t\t\t};"
        ].joined(separator: "\n") + "\n"
        try Data(mnemonSource.utf8).write(to: mnemonSourceURL)

        let forkSourceURL = runtimeRoot.appendingPathComponent(
            "node_modules/@deepseek-ai/dsh-subagent-fork-in-process/lib/index.js"
        )
        try fileManager.createDirectory(at: forkSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forkSource = [
            "function completedTurnPrefix(parent) { return parent.session.events; }",
            "var ForkInProcessProvider = class {",
            "\tstart(request) {",
            "\t\tconst seed = completedTurnPrefix(request.parent);",
            "\t\treturn seed;",
            "\t}",
            "\tprepareContinuable(request) {",
            "\t\tconst seed = completedTurnPrefix(request.parent);",
            "\t\treturn seed;",
            "\t}",
            "};"
        ].joined(separator: "\n") + "\n"
        try Data(forkSource.utf8).write(to: forkSourceURL)

        let installer = DefaultProfileInstaller(fileManager: fileManager)
        #expect(try installer.syncDshMnemonTextOnlyReviewCompatibility(
            profileWeb: paths.profileWeb,
            runtimeRoot: runtimeRoot
        ))
        let patchedMnemon = try String(contentsOf: mnemonSourceURL, encoding: .utf8)
        #expect(patchedMnemon.contains("...operation === \"review\" ? { dshMnemonTextOnly: true } : {},"))
        let patchedFork = try String(contentsOf: forkSourceURL, encoding: .utf8)
        #expect(patchedFork.contains("function sanitizeMnemonForkValue(value)"))
        #expect(patchedFork.contains("request.agentOptions?.dshMnemonTextOnly === true"))
        #expect(patchedFork.components(separatedBy: "const seed = mnemonForkSeed(request);").count == 3)
        #expect(!(try installer.syncDshMnemonTextOnlyReviewCompatibility(
            profileWeb: paths.profileWeb,
            runtimeRoot: runtimeRoot
        )))
    }

    @Test
    @MainActor
    func officialRuntimeStagingDoesNotCopyPreviousCoreDependencies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let sourceNode = source.appendingPathComponent("node/bin/node")
        let sourcePnpm = source.appendingPathComponent("node_modules/pnpm/bin/pnpm.cjs")
        let staleCore = source.appendingPathComponent("node_modules/@deepseek-ai/dsh-old/package.json")
        let helper = source.appendingPathComponent("bin/mnemon")
        let staleCLI = source.appendingPathComponent("bin/dsh")
        let defaultProfile = source.appendingPathComponent("default-profile/profiles/web/package.json")
        for file in [sourceNode, sourcePnpm, staleCore, helper, staleCLI, defaultProfile] {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceNode.path)

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let stagedRuntime = staging.appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let installation = RuntimeInstallation(
            executable: staleCLI,
            root: source,
            version: "0.1.1-rc.2",
            nodeExecutable: sourceNode
        )
        let builder = OfficialHarnessRuntimeBuilder(fileManager: fileManager)
        let layout = try builder.stageCleanRuntimeFoundation(
            currentInstallation: installation,
            staging: staging,
            stagedRuntime: stagedRuntime
        )

        #expect(fileManager.fileExists(atPath: layout.node.path))
        #expect(fileManager.fileExists(atPath: layout.packageManagerBootstrap.path))
        #expect(fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("bin/mnemon").path))
        #expect(!fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("bin/dsh").path))
        #expect(fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("default-profile/profiles/web/package.json").path))
        #expect(!fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("node_modules/@deepseek-ai/dsh-old/package.json").path))
        #expect(!fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("node_modules/pnpm").path))

        try builder.embedPackageManager(layout.packageManagerPackage, in: stagedRuntime)
        let pnpmLink = stagedRuntime.appendingPathComponent("node_modules/.bin/pnpm")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: pnpmLink.path) == "../pnpm/bin/pnpm.cjs")
        #expect(fileManager.fileExists(atPath: stagedRuntime.appendingPathComponent("node_modules/pnpm/bin/pnpm.cjs").path))
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
    func dataSlotCloneActivationAndRollbackPreserveUserProfile() async throws {
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
        let candidate = try await manager.cloneActiveSlot(paths: paths)
        let candidateProfile = candidate.appendingPathComponent("dsh-home/profiles/web/package.json")
        try Data(#"{"name":"candidate-profile","lockfileVersion":1}"#.utf8).write(to: candidateProfile)
        let activation = try manager.activate(candidateSlot: candidate, paths: paths)
        let activatedProfile = try String(
            contentsOf: paths.profileWeb.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        #expect(activatedProfile.contains("candidate-profile"))

        let secondCandidate = try await manager.cloneActiveSlot(paths: paths)
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
    func cleansOnlyTemporaryRuntimeUpdateFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let updateRoots = [
            paths.caches.appendingPathComponent("updates/staging", isDirectory: true),
            paths.caches.appendingPathComponent("updates/official-artifacts", isDirectory: true),
            paths.caches.appendingPathComponent("updates/official-staging", isDirectory: true),
            paths.caches.appendingPathComponent("updates/base-preflight", isDirectory: true),
            paths.caches.appendingPathComponent("updates/data-slots", isDirectory: true)
        ]
        for (index, updateRoot) in updateRoots.enumerated() {
            let item = updateRoot.appendingPathComponent("temporary-\(index)", isDirectory: true)
            try fileManager.createDirectory(at: item, withIntermediateDirectories: true)
            try Data("temporary".utf8).write(to: item.appendingPathComponent("payload"))
        }

        let activeRuntime = paths.runtimes.appendingPathComponent("official-active", isDirectory: true)
        try fileManager.createDirectory(at: activeRuntime, withIntermediateDirectories: true)
        try Data("active".utf8).write(to: activeRuntime.appendingPathComponent("payload"))

        RuntimeUpdateService().cleanupTemporaryFiles(paths: paths)

        for updateRoot in updateRoots {
            #expect(try fileManager.contentsOfDirectory(at: updateRoot, includingPropertiesForKeys: nil).isEmpty)
        }
        #expect(fileManager.fileExists(atPath: activeRuntime.appendingPathComponent("payload").path))
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

    @Test
    @MainActor
    func refreshIncludesInstalledPluginWithoutPatchForRemoval() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        let packageDirectory = paths.profileWeb.appendingPathComponent("node_modules/plain-plugin", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let profileManifest = #"{"dsh":{"profile":{"bundles":["plain-plugin"]}},"dependencies":{"plain-plugin":"1.0.0"}}"#
        try Data(profileManifest.utf8).write(to: paths.profileWeb.appendingPathComponent("package.json"))
        let packageManifest = #"{"name":"plain-plugin","version":"1.0.0"}"#
        try Data(packageManifest.utf8).write(to: packageDirectory.appendingPathComponent("package.json"))

        let manager = ProfileManager(paths: paths)
        let plugin = try #require(manager.refresh().first)
        #expect(plugin.id == "plain-plugin")
        #expect(plugin.bundleRowIDs.isEmpty)
        #expect(!plugin.canBeDisabled)
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
    nonisolated(unsafe) static var appResponses: [URL: (status: Int, data: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.responses[url] ?? Self.appResponses[url] else {
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
