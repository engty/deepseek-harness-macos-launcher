import Foundation
import Testing

@testable import HarnessLauncher

@Suite
struct StrictSemanticVersionTests {
    @Test
    func parsesAndOrdersVersions() {
        #expect(StrictSemanticVersion(rawValue: "1.2.3")?.description == "1.2.3")
        #expect(StrictSemanticVersion(rawValue: "v0.1.11")?.description == "0.1.11")
        #expect(StrictSemanticVersion(rawValue: "1.0.0-rc.6")?.description == "1.0.0-rc.6")
        #expect(StrictSemanticVersion(rawValue: "1.0.0-alpha")! < StrictSemanticVersion(rawValue: "1.0.0")!)
        #expect(StrictSemanticVersion(rawValue: "1.0.0-alpha.1")! < StrictSemanticVersion(rawValue: "1.0.0-beta.1")!)
        #expect(StrictSemanticVersion(rawValue: "1.0.0-rc.1")! < StrictSemanticVersion(rawValue: "1.0.0-rc.2")!)
        #expect(StrictSemanticVersion(rawValue: "1.0.1")! > StrictSemanticVersion(rawValue: "1.0.0-rc.6")!)
    }

    @Test
    func rejectsMalformedVersions() {
        // Previously accepted by truncating digits: 1.2.3rc == 1.2.3.
        #expect(StrictSemanticVersion(rawValue: "1.2.3rc") == nil)
        #expect(StrictSemanticVersion(rawValue: "1.2foo") == nil)
        #expect(StrictSemanticVersion(rawValue: "1.2") == nil)
        #expect(StrictSemanticVersion(rawValue: "1.2.3.4") == nil)
        #expect(StrictSemanticVersion(rawValue: "1.2.3-01") == nil)
        #expect(StrictSemanticVersion(rawValue: "1.2.3+") == nil)
        #expect(StrictSemanticVersion(rawValue: "") == nil)
    }

    @Test
    func manifestVerifierRequiresStrictVersionsAndPositiveSize() {
        var manifest = makeManifest(minShellVersion: "1.2.3rc")
        do {
            try RuntimeManifestVerifier.validate(
                manifest: manifest,
                architecture: currentArchitecture,
                shellVersion: "0.1.11"
            )
            Issue.record("expected invalidMinShellVersion")
        } catch let error as RuntimeManifestError {
            guard case .invalidMinShellVersion = error else {
                Issue.record("expected invalidMinShellVersion, got: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        manifest = makeManifest(minShellVersion: "0.1.0")
        manifest = RuntimeManifest(
            schemaVersion: manifest.schemaVersion,
            runtimeID: manifest.runtimeID,
            channel: manifest.channel,
            architecture: manifest.architecture,
            harness: manifest.harness,
            nodeVersion: manifest.nodeVersion,
            testedPlugins: manifest.testedPlugins,
            minShellVersion: manifest.minShellVersion,
            dataFormat: manifest.dataFormat,
            artifact: .init(url: manifest.artifact.url, size: 0, sha256: manifest.artifact.sha256),
            releaseNotesURL: manifest.releaseNotesURL,
            publishedAt: manifest.publishedAt
        )
        do {
            try RuntimeManifestVerifier.validate(
                manifest: manifest,
                architecture: currentArchitecture,
                shellVersion: "0.1.11"
            )
            Issue.record("expected invalidArtifactSize")
        } catch let error as RuntimeManifestError {
            guard case .invalidArtifactSize = error else {
                Issue.record("expected invalidArtifactSize, got: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    private func makeManifest(minShellVersion: String) -> RuntimeManifest {
        RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "test-runtime",
            channel: "test",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "0.1.0", commit: "fixture"),
            nodeVersion: "22",
            testedPlugins: nil,
            minShellVersion: minShellVersion,
            dataFormat: "1",
            artifact: .init(
                url: URL(string: "https://example.com/runtime.tar")!,
                size: 1024,
                sha256: String(repeating: "a", count: 64)
            ),
            releaseNotesURL: nil,
            publishedAt: nil
        )
    }
}

@Suite
struct DataSlotRecoveryTests {
    private func makePaths(root: URL) -> AppPaths {
        AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }

    private func writeProfile(_ name: String, in slot: URL) throws {
        let profile = slot.appendingPathComponent("dsh-home/profiles/web/package.json")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"\#(name)","lockfileVersion":1}"#.utf8).write(to: profile)
    }

    private func profileName(at paths: AppPaths) throws -> String {
        let data = try Data(contentsOf: paths.profileWeb.appendingPathComponent("package.json"))
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test
    func candidateCloneRebasesTemporaryProfileModuleLinks() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = makePaths(root: root)
        try paths.prepare()
        let profileWeb = paths.profileWeb
        let profileModules = profileWeb.appendingPathComponent("node_modules", isDirectory: true)
        let fallbackModules = profileWeb.appendingPathComponent(
            ".dsh-module-fallback/node_modules",
            isDirectory: true
        )
        let sharedPackage = paths.dshHome
            .appendingPathComponent("profiles/node_modules/core-package", isDirectory: true)
        try fileManager.createDirectory(at: profileModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallbackModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedPackage, withIntermediateDirectories: true)
        try Data("module".utf8).write(to: sharedPackage.appendingPathComponent("package.json"))

        // This is the shape left by the previous updater: the profile link
        // points at a cache candidate that has already been removed.
        let staleTarget = paths.caches
            .appendingPathComponent(
                "updates/data-slots/old/candidate/dsh-home/profiles/web/.dsh-module-fallback/node_modules/core-package"
            )
        try fileManager.createSymbolicLink(
            atPath: profileModules.appendingPathComponent("core-package").path,
            withDestinationPath: staleTarget.path
        )
        try fileManager.createSymbolicLink(
            atPath: profileModules.appendingPathComponent("orphan-package").path,
            withDestinationPath: paths.caches
                .appendingPathComponent("updates/data-slots/old/candidate/dsh-home/profiles/web/.dsh-module-fallback/node_modules/orphan-package")
                .path
        )
        try fileManager.createSymbolicLink(
            atPath: fallbackModules.appendingPathComponent("core-package").path,
            withDestinationPath: sharedPackage.path
        )

        let manager = DataSlotManager()
        let candidate = try await manager.cloneActiveSlot(paths: paths)
        let candidateLink = candidate.appendingPathComponent(
            "dsh-home/profiles/web/node_modules/core-package"
        )
        let candidateDestination = try fileManager.destinationOfSymbolicLink(atPath: candidateLink.path)
        #expect(!candidateDestination.hasPrefix("/"))
        #expect(fileManager.fileExists(atPath: candidateLink.deletingLastPathComponent()
            .appendingPathComponent(candidateDestination).path))
        #expect((try? fileManager.destinationOfSymbolicLink(
            atPath: candidateLink.deletingLastPathComponent()
                .appendingPathComponent("orphan-package").path
        )) == nil)
        try manager.validateCandidateModuleLinks(candidateSlot: candidate)
    }

    @Test
    func candidateLinksAreRebasedAfterRuntimeBootMutatesProfile() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = makePaths(root: root)
        try paths.prepare()
        let profileModules = paths.profileWeb.appendingPathComponent("node_modules", isDirectory: true)
        let fallbackModules = paths.profileWeb.appendingPathComponent(
            ".dsh-module-fallback/node_modules",
            isDirectory: true
        )
        let sharedPackage = paths.dshHome
            .appendingPathComponent("profiles/node_modules/core-package", isDirectory: true)
        try fileManager.createDirectory(at: profileModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallbackModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedPackage, withIntermediateDirectories: true)
        try Data("module".utf8).write(to: sharedPackage.appendingPathComponent("package.json"))
        try fileManager.createSymbolicLink(
            atPath: profileModules.appendingPathComponent("core-package").path,
            withDestinationPath: sharedPackage.path
        )
        try fileManager.createSymbolicLink(
            atPath: fallbackModules.appendingPathComponent("core-package").path,
            withDestinationPath: sharedPackage.path
        )

        let manager = DataSlotManager()
        let candidate = try await manager.cloneActiveSlot(paths: paths)
        let candidateLink = candidate.appendingPathComponent(
            "dsh-home/profiles/web/node_modules/core-package"
        )
        try fileManager.removeItem(at: candidateLink)
        let generatedAbsoluteTarget = candidate.appendingPathComponent(
            "dsh-home/profiles/web/.dsh-module-fallback/node_modules/core-package"
        )
        try fileManager.createSymbolicLink(
            atPath: candidateLink.path,
            withDestinationPath: generatedAbsoluteTarget.path
        )

        try manager.rebaseCandidateModuleLinks(candidateSlot: candidate, paths: paths)
        let destination = try fileManager.destinationOfSymbolicLink(atPath: candidateLink.path)
        #expect(!destination.hasPrefix("/"))
        try manager.validateCandidateModuleLinks(candidateSlot: candidate)
    }

    @Test
    func repairsExistingActiveProfileLinksOnLaunch() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = makePaths(root: root)
        try paths.prepare()
        let profileModules = paths.profileWeb.appendingPathComponent("node_modules", isDirectory: true)
        let fallbackModules = paths.profileWeb.appendingPathComponent(
            ".dsh-module-fallback/node_modules",
            isDirectory: true
        )
        let sharedPackage = paths.dshHome
            .appendingPathComponent("profiles/node_modules/core-package", isDirectory: true)
        try fileManager.createDirectory(at: profileModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallbackModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedPackage, withIntermediateDirectories: true)
        try Data("module".utf8).write(to: sharedPackage.appendingPathComponent("package.json"))

        let staleTarget = paths.caches
            .appendingPathComponent(
                "updates/data-slots/old/candidate/dsh-home/profiles/web/.dsh-module-fallback/node_modules/core-package"
            )
        try fileManager.createSymbolicLink(
            atPath: profileModules.appendingPathComponent("core-package").path,
            withDestinationPath: staleTarget.path
        )
        try fileManager.createSymbolicLink(
            atPath: fallbackModules.appendingPathComponent("core-package").path,
            withDestinationPath: sharedPackage.path
        )

        let manager = DataSlotManager()
        try manager.repairActiveModuleLinks(paths: paths)
        let destination = try fileManager.destinationOfSymbolicLink(
            atPath: profileModules.appendingPathComponent("core-package").path
        )
        #expect(!destination.hasPrefix("/"))
        try manager.validateCandidateModuleLinks(candidateSlot: paths.activeDataSlot)
    }

    @Test
    func completesInterruptedSwapForwardWhenCandidateExists() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.prepare()
        try writeProfile("original", in: paths.activeDataSlot)

        let manager = DataSlotManager()
        let candidate = try await manager.cloneActiveSlot(paths: paths)
        try writeProfile("candidate", in: candidate)

        // Simulate a crash right after the journal was written and the
        // active slot was moved away, before the candidate landed.
        let previousSlot = paths.backups.appendingPathComponent("data-slot-crash-sim", isDirectory: true)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let journal = DataSlotTransactionJournal(
            phase: DataSlotTransactionJournal.phaseActiveMoved,
            previousSlot: previousSlot.path,
            candidateSlot: candidate.path,
            recordedAt: Date()
        )
        try JSONEncoder().encode(journal).write(
            to: paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName)
        )
        try fileManager.moveItem(at: paths.activeDataSlot, to: previousSlot)

        manager.recoverPendingTransaction(paths: paths)
        #expect(try profileName(at: paths).contains("candidate"))
        #expect(!fileManager.fileExists(
            atPath: paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName).path
        ))
    }

    @Test
    func rollsBackInterruptedSwapWhenCandidateIsGone() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.prepare()
        try writeProfile("original", in: paths.activeDataSlot)

        let manager = DataSlotManager()
        let candidate = try await manager.cloneActiveSlot(paths: paths)
        // Candidate disappears entirely (e.g. interrupted copy).
        try fileManager.removeItem(at: candidate)

        let previousSlot = paths.backups.appendingPathComponent("data-slot-crash-sim", isDirectory: true)
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let journal = DataSlotTransactionJournal(
            phase: DataSlotTransactionJournal.phaseActiveMoved,
            previousSlot: previousSlot.path,
            candidateSlot: candidate.path,
            recordedAt: Date()
        )
        try JSONEncoder().encode(journal).write(
            to: paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName)
        )
        try fileManager.moveItem(at: paths.activeDataSlot, to: previousSlot)

        manager.recoverPendingTransaction(paths: paths)
        #expect(try profileName(at: paths).contains("original"))
    }

    @Test
    func ignoresJournalPointingOutsideAppOwnedDirectories() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.prepare()
        try writeProfile("original", in: paths.activeDataSlot)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("do not move".utf8).write(to: outside.appendingPathComponent("victim.txt"))

        let journal = DataSlotTransactionJournal(
            phase: DataSlotTransactionJournal.phaseActiveMoved,
            previousSlot: outside.path,
            candidateSlot: outside.path,
            recordedAt: Date()
        )
        try JSONEncoder().encode(journal).write(
            to: paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName)
        )

        let manager = DataSlotManager()
        manager.recoverPendingTransaction(paths: paths)
        // The active slot is untouched and the hostile journal is removed.
        #expect(try profileName(at: paths).contains("original"))
        #expect(!fileManager.fileExists(
            atPath: paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName).path
        ))
    }
}

@Suite
struct RedactorHardeningTests {
    @Test
    func redactsJsonFieldForms() {
        let result = SensitiveDataRedactor.redact(
            #"{"password":"plain-secret","authorization":"Bearer opaque-token"}"#
        )
        #expect(!result.contains("plain-secret"))
        #expect(!result.contains("opaque-token"))
    }

    @Test
    func redactsQuotedSecretsContainingSpaces() {
        let result = SensitiveDataRedactor.redact(#"password="my secret phrase""#)
        #expect(!result.contains("secret phrase"))
        #expect(!result.contains("my secret"))
    }

    @Test
    func redactsRegisteredLiteralSecretsInAnyContext() {
        SensitiveDataRedactor.registerLiteralSecret("customsecretvalue123")
        let json = #"{"token":"customsecretvalue123"}"#
        let url = "https://example.com/?t=customsecretvalue123"
        #expect(!SensitiveDataRedactor.redact(json).contains("customsecretvalue123"))
        #expect(!SensitiveDataRedactor.redact(url).contains("customsecretvalue123"))
    }
}

@Suite
struct ToolchainTrustTests {
    @Test
    func rejectsPrivateToolWithoutValidManifest() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        // A jq binary exists but its manifest.json is missing: resolution
        // must not trust it.
        let toolchainRoot = root.appendingPathComponent("toolchain", isDirectory: true)
        let jq = toolchainRoot.appendingPathComponent("jq/1.7.1/bin/jq", isDirectory: false)
        try fileManager.createDirectory(at: jq.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fake-jq\n".utf8).write(to: jq)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)

        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let pnpm = runtimeRoot.appendingPathComponent("node_modules/.bin/pnpm", isDirectory: false)
        let dsh = runtimeRoot.appendingPathComponent("bin/dsh", isDirectory: false)
        try fileManager.createDirectory(at: pnpm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dsh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: pnpm)
        try Data("#!/bin/sh\n".utf8).write(to: dsh)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pnpm.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)

        let installation = RuntimeInstallation(
            executable: dsh,
            root: runtimeRoot,
            version: nil,
            nodeExecutable: nil
        )
        let service = PluginDependencyService(
            environment: ["PATH": "/usr/bin:/bin"],
            privateToolchainRoot: toolchainRoot
        )
        // The fake jq binary must not be trusted: without a valid manifest
        // and matching SHA-256 the resolver falls back to planning a fresh
        // (catalog-verified) installation.
        let plan = try service.resolve(
            installation: installation,
            arguments: ["remove", "some-plugin"],
            additionalRequirements: [ToolchainRequirement(id: "jq", version: "1.7.1")]
        )
        #expect(plan.dependencies.allSatisfy { $0.name != "jq" })
        #expect(plan.toolchainInstallPlans.contains { $0.manifest.id == "jq" })
    }
}

@Suite
struct OrphanedRuntimeGCTests {
    @Test
    @MainActor
    func removesRuntimesNotReferencedByAnyManifest() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        func makeRuntime(_ id: String) throws -> URL {
            let dir = paths.runtimes.appendingPathComponent(id, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        let active = try makeRuntime("active-runtime")
        let good = try makeRuntime("last-known-good-runtime")
        let orphan = try makeRuntime("orphaned-runtime")

        let encoder = JSONEncoder()
        try encoder.encode(RuntimeActivationRecord(
            runtimeID: "active-runtime",
            runtimePath: active.path,
            architecture: currentArchitecture,
            harnessVersion: "0.1.0"
        )).write(to: paths.activeRuntimeManifest)
        try encoder.encode(RuntimeActivationRecord(
            runtimeID: "last-known-good-runtime",
            runtimePath: good.path,
            architecture: currentArchitecture,
            harnessVersion: "0.0.9"
        )).write(to: paths.lastKnownGoodRuntimeManifest)

        RuntimeArchiveInstaller().cleanupOrphanedRuntimes(paths: paths)

        #expect(fileManager.fileExists(atPath: active.path))
        #expect(fileManager.fileExists(atPath: good.path))
        #expect(!fileManager.fileExists(atPath: orphan.path))
    }
}

private var currentArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}
