import Foundation
import Testing
@testable import HarnessLauncher

struct OfficialRuntimeIntegrationTests {
    /// Opt-in because this downloads the current official Runtime and may take
    /// several minutes. Run before a launcher release with:
    /// `HARNESS_RUN_OFFICIAL_RUNTIME_INTEGRATION=1 swift test --filter officialRuntimeBuilderRebuildsLatestRuntimeInCleanTree`
    @Test
    @MainActor
    func officialRuntimeBuilderRebuildsLatestRuntimeInCleanTree() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OFFICIAL_RUNTIME_INTEGRATION"] == "1" else {
            return
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "harness-official-runtime-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let currentInstallation = try RuntimeLocator().locate()
        let official = try await OfficialHarnessVersionService().check()
        let artifact = try await OfficialHarnessRuntimeBuilder(fileManager: fileManager).prepare(
            currentInstallation: currentInstallation,
            official: official,
            paths: paths,
            shellVersion: "0.1.0",
            progress: { _ in }
        )

        #expect(artifact.manifest.harness.version == official.version)
        #expect(artifact.manifest.artifact.size > 0)
        #expect(fileManager.fileExists(atPath: artifact.artifactURL.path))
    }
}
