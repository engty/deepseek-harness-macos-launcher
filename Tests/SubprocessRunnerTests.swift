import CryptoKit
import Foundation
import Testing

@testable import HarnessLauncher

@Suite
struct SubprocessRunnerTests {
    @Test
    func largeOutputCompletesWithoutPipeDeadlock() async throws {
        // ~1.4 MB of stdout, far beyond the pipe buffer. The old pattern
        // (readDataToEndOfFile only after termination) deadlocks here because
        // the child blocks once the pipe fills and nobody drains it.
        let result = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "200000"],
            timeout: 60
        )
        #expect(result.status == 0)
        #expect(result.output.contains("200000"))
    }

    @Test
    @MainActor
    func detectsNoOpenCapabilityOnlyWhenAdvertised() {
        #expect(HarnessProcessController.helpOutputContainsNoOpen(
            "Usage: dsh --profile web [options]\n  --no-open  do not open the Web UI in the default browser\n"
        ))
        #expect(!HarnessProcessController.helpOutputContainsNoOpen(
            "Usage: dsh --profile web [options]\n  --port <port>  listen port\n"
        ))
    }

    @Test
    func timeoutTerminatesHungProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                timeout: 0.5
            )
            Issue.record("expected a timeout error")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(10))
    }
}

@Suite
struct RuntimeArchiveSafetyTests {
    @Test
    @MainActor
    func rejectsHardlinkEntriesBeforeExtraction() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceRuntime = root.appendingPathComponent("source-runtime", isDirectory: true)
        let bin = sourceRuntime.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let dsh = bin.appendingPathComponent("dsh")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: dsh)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dsh.path)
        // Two directory entries sharing one inode make BSD tar store the
        // second one as a hardlink entry.
        let original = sourceRuntime.appendingPathComponent("original.txt")
        let hardlinked = sourceRuntime.appendingPathComponent("hardlinked.txt")
        try Data("payload".utf8).write(to: original)
        try fileManager.linkItem(at: original, to: hardlinked)

        let artifact = root.appendingPathComponent("hardlink-runtime.tar")
        try runTool("/usr/bin/tar", arguments: ["-cf", artifact.path, "-C", sourceRuntime.path, "."])
        let artifactData = try Data(contentsOf: artifact)
        let digest = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
        let manifest = RuntimeManifest(
            schemaVersion: 1,
            runtimeID: "hardlink-runtime",
            channel: "test",
            architecture: currentArchitecture,
            harness: .init(package: "@deepseek-ai/dsh", version: "test.1", commit: "fixture"),
            nodeVersion: "22",
            testedPlugins: nil,
            minShellVersion: "0.1.0",
            dataFormat: "1",
            artifact: .init(url: URL(string: "https://example.com/hardlink-runtime.tar")!, size: Int64(artifactData.count), sha256: digest),
            releaseNotesURL: nil,
            publishedAt: nil
        )
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try paths.prepare()

        do {
            _ = try await RuntimeArchiveInstaller().activate(
                manifest: manifest,
                artifactURL: artifact,
                paths: paths
            )
            Issue.record("expected hardlink archive to be rejected")
        } catch let error as RuntimeArchiveError {
            guard case .unsafeArchiveEntryType = error else {
                Issue.record("expected unsafeArchiveEntryType, got: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    private func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private var currentArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}
