import Foundation

struct PluginCommandResult {
    let status: Int32
    let output: String
}

enum PluginCommandError: LocalizedError {
    case failedToLaunch(String)
    case nonZeroExit(String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return "无法启动 Harness 插件命令：\(message)"
        case .nonZeroExit(let output):
            return "插件命令执行失败。\n\(output)"
        }
    }
}

@MainActor
final class PluginCommandRunner {
    func mutateProfile(
        installation: RuntimeInstallation,
        paths: AppPaths,
        arguments: [String]
    ) async throws -> PluginCommandResult {
        let dataSlotManager = DataSlotManager()
        let stagingSlot = try dataSlotManager.cloneActiveSlot(paths: paths)
        let stagingRoot = stagingSlot.deletingLastPathComponent()
        let stagingHome = stagingSlot.appendingPathComponent("dsh-home", isDirectory: true)
        let stagingProfile = stagingHome.appendingPathComponent("profiles/web", isDirectory: true)
        let metadataStore = PluginMetadataStore()
        try FileManager.default.createDirectory(at: stagingProfile, withIntermediateDirectories: true)

        let result: PluginCommandResult
        do {
            result = try await run(
                installation: installation,
                arguments: ["plugin", "--profile", "web"] + arguments,
                environment: ["DSH_HOME": stagingHome.path],
                currentDirectory: stagingProfile
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }

        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PluginCommandError.nonZeroExit(Self.redact(result.output))
        }

        let preflight = try await run(
            installation: installation,
            arguments: ["--profile", "web", "--dump-config"],
            environment: ["DSH_HOME": stagingHome.path],
            currentDirectory: stagingProfile
        )
        guard preflight.status == 0 else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PluginCommandError.nonZeroExit("插件 profile preflight 失败，active profile 未改变。")
        }

        let candidateController = HarnessProcessController()
        do {
            _ = try await candidateController.start(
                installation: installation,
                paths: paths,
                overlayURL: FileManager.default.fileExists(atPath: paths.overlay.path) ? paths.overlay : nil,
                dshHomeOverride: stagingHome,
                currentDirectoryOverride: stagingSlot
            )
            await candidateController.stop()
        } catch {
            await candidateController.stop()
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PluginCommandError.nonZeroExit("插件候选启动 preflight 失败，active profile 未改变。")
        }

        guard FileManager.default.fileExists(atPath: stagingProfile.appendingPathComponent("package.json").path) else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PluginCommandError.nonZeroExit("staging profile 没有生成 package.json")
        }

        let metadata = try metadataStore.collect(profileURL: stagingProfile, arguments: arguments)
        try metadataStore.write(
            metadata,
            to: stagingHome.appendingPathComponent("launcher/plugin-metadata.json")
        )

        do {
            _ = try dataSlotManager.activate(candidateSlot: stagingSlot, paths: paths)
            try? FileManager.default.removeItem(at: stagingRoot)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
        return result
    }

    private func run(
        installation: RuntimeInstallation,
        arguments: [String],
        environment additions: [String: String],
        currentDirectory: URL
    ) async throws -> PluginCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        if let nodeExecutable = installation.nodeExecutable {
            process.executableURL = nodeExecutable
            process.arguments = [installation.executable.path] + arguments
        } else {
            process.executableURL = installation.executable
            process.arguments = arguments
        }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment.merge(additions) { _, new in new }
        process.environment = environment

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: PluginCommandResult(status: process.terminationStatus, output: output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PluginCommandError.failedToLaunch(error.localizedDescription))
            }
        }
    }

    private static func redact(_ output: String) -> String {
        SensitiveDataRedactor.redact(output)
            .split(separator: "\n")
            .suffix(80)
            .joined(separator: "\n")
    }
}
