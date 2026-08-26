import Foundation

enum RuntimePreflightError: LocalizedError {
    case versionFailed(String)
    case configFailed(String)
    case emptyVersion

    var errorDescription: String? {
        switch self {
        case .versionFailed(let output):
            return "Runtime --version 预检失败：\(SensitiveDataRedactor.redact(output))"
        case .configFailed(let output):
            return "Runtime --dump-config 预检失败：\(SensitiveDataRedactor.redact(output))"
        case .emptyVersion:
            return "Runtime --version 没有返回版本号。"
        }
    }
}

@MainActor
final class RuntimePreflightService {
    func run(
        installation: RuntimeInstallation,
        paths: AppPaths,
        dshHome: URL,
        currentDirectory: URL
    ) async throws {
        try FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        let version = try await execute(
            installation: installation,
            arguments: ["--version"],
            dshHome: dshHome,
            paths: paths,
            currentDirectory: currentDirectory
        )
        guard version.status == 0 else { throw RuntimePreflightError.versionFailed(version.output) }
        guard !version.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimePreflightError.emptyVersion
        }

        let config = try await execute(
            installation: installation,
            arguments: ["--profile", "web", "--dump-config"],
            dshHome: dshHome,
            paths: paths,
            currentDirectory: currentDirectory
        )
        guard config.status == 0 else { throw RuntimePreflightError.configFailed(config.output) }
    }

    private struct Result {
        let status: Int32
        let output: String
    }

    private func execute(
        installation: RuntimeInstallation,
        arguments: [String],
        dshHome: URL,
        paths: AppPaths,
        currentDirectory: URL
    ) async throws -> Result {
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = dshHome.path
        environment["DSH_LAUNCHER"] = "DeepSeekHarness"
        environment["PATH"] = PluginDependencyService(
            environment: environment,
            privateToolchainRoot: paths.toolchain
        ).runtimeSearchPath(installation: installation)

        let command = installation.command(arguments: arguments)

        // Streams output while the child runs and enforces a hard timeout, so
        // a broken candidate Runtime can neither fill the pipe (deadlock) nor
        // hang the update flow forever.
        let result = try await SubprocessRunner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: 60
        )
        return Result(status: result.status, output: result.output)
    }
}
