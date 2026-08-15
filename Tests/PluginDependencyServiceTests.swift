import Foundation
import Testing
@testable import HarnessLauncher

struct PluginDependencyServiceTests {
    @Test
    func bundledPnpmWinsOverConfiguredUserPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledPnpm = root.appendingPathComponent("runtime/node_modules/.bin/pnpm")
        let userPnpm = root.appendingPathComponent("user-bin/pnpm")
        try makeExecutable(bundledPnpm)
        try makeExecutable(userPnpm)
        try fileManager.createDirectory(
            at: root.appendingPathComponent("runtime/node_modules/pnpm", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"pnpm","version":"10.19.0"}"#.utf8)
            .write(to: root.appendingPathComponent("runtime/node_modules/pnpm/package.json"))

        let installation = RuntimeInstallation(
            executable: root.appendingPathComponent("runtime/node_modules/.bin/dsh"),
            root: root.appendingPathComponent("runtime/node_modules"),
            version: "0.1.0-test",
            nodeExecutable: nil
        )
        let plan = try PluginDependencyService(
            environment: ["PATH": userPnpm.deletingLastPathComponent().path],
            privateToolchainRoot: root.appendingPathComponent("toolchain")
        ).resolve(installation: installation, arguments: ["add", "fixture-plugin"])

        #expect(plan.dependencies.first?.source == .bundled)
        #expect(plan.dependencies.first?.executable == bundledPnpm)
        #expect(plan.dependencies.first?.version == "10.19.0")
        #expect(String(plan.searchPath.split(separator: ":").first ?? "") == bundledPnpm.deletingLastPathComponent().path)
    }

    @Test
    func configuredUserPnpmIsOnlyAChildProcessFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let userPnpm = root.appendingPathComponent("user-bin/pnpm")
        try makeExecutable(userPnpm)
        let installation = RuntimeInstallation(
            executable: root.appendingPathComponent("runtime/dsh"),
            root: root.appendingPathComponent("runtime"),
            version: nil,
            nodeExecutable: nil
        )
        let plan = try PluginDependencyService(
            environment: ["PATH": userPnpm.deletingLastPathComponent().path],
            privateToolchainRoot: root.appendingPathComponent("toolchain")
        ).resolve(installation: installation, arguments: ["add", "fixture-plugin"])

        #expect(plan.usesUserTools)
        #expect(plan.dependencies.first?.source == .user)
        #expect(plan.searchPath.contains(userPnpm.deletingLastPathComponent().path))
        #expect(plan.confirmationText.contains("用户已有"))
        #expect(plan.confirmationText.contains("不会修改系统 PATH"))
    }

    @Test
    func gitHostedPluginDeclaresGitAndCurlInConfirmationPlan() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let pnpm = root.appendingPathComponent("runtime/node_modules/.bin/pnpm")
        try makeExecutable(pnpm)
        let installation = RuntimeInstallation(
            executable: root.appendingPathComponent("runtime/dsh"),
            root: root.appendingPathComponent("runtime"),
            version: nil,
            nodeExecutable: nil
        )
        let plan = try PluginDependencyService(
            environment: ["PATH": "/usr/bin:/bin"],
            privateToolchainRoot: root.appendingPathComponent("toolchain")
        ).resolve(
            installation: installation,
            arguments: ["add", "github:mishibeikejie/zat-dsh-engine"]
        )

        #expect(plan.dependencies.map(\.name).contains("pnpm"))
        #expect(plan.dependencies.map(\.name).contains("git"))
        #expect(plan.dependencies.map(\.name).contains("curl"))
    }

    private func makeExecutable(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
