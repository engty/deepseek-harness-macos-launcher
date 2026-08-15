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
        currentDirectory: URL
    ) async throws -> Result {
        let process = Process()
        let pipe = Pipe()
        if let nodeExecutable = installation.nodeExecutable {
            process.executableURL = nodeExecutable
            process.arguments = [installation.executable.path] + arguments
        } else {
            process.executableURL = installation.executable
            process.arguments = arguments
        }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = dshHome.path
        environment["DSH_LAUNCHER"] = "DeepSeekHarness"
        process.environment = environment

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
