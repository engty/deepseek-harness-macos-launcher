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
    func dependencyPlan(
        installation: RuntimeInstallation,
        paths: AppPaths,
        arguments: [String]
    ) throws -> PluginDependencyPlan {
        try PluginDependencyService(
            privateToolchainRoot: paths.toolchain
        ).resolve(installation: installation, arguments: arguments)
    }

    func mutateProfile(
        installation: RuntimeInstallation,
        paths: AppPaths,
        arguments: [String],
        dependencyPlan: PluginDependencyPlan? = nil
    ) async throws -> PluginCommandResult {
        let dependencyPlan = try dependencyPlan ?? self.dependencyPlan(
            installation: installation,
            paths: paths,
            arguments: arguments
        )
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
                environment: PluginDependencyService(
                    privateToolchainRoot: paths.toolchain
                ).applying(
                    plan: dependencyPlan,
                    additions: [
                        "DSH_HOME": stagingHome.path,
                        "DSH_LAUNCHER": "DeepSeekHarness"
                    ]
                ),
                currentDirectory: stagingProfile,
                logURL: paths.pluginOperationsLog
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
            environment: PluginDependencyService(
                privateToolchainRoot: paths.toolchain
            ).applying(
                plan: dependencyPlan,
                additions: [
                    "DSH_HOME": stagingHome.path,
                    "DSH_LAUNCHER": "DeepSeekHarness"
                ]
            ),
            currentDirectory: stagingProfile,
            logURL: paths.pluginOperationsLog
        )
        guard preflight.status == 0 else {
            PluginOperationLog.append(
                "PREFLIGHT FAILED \(Self.redact(preflight.output))",
                to: paths.pluginOperationsLog
            )
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
            PluginOperationLog.append(
                "CANDIDATE START FAILED \(Self.redact(error.localizedDescription))",
                to: paths.pluginOperationsLog
            )
            await candidateController.stop()
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PluginCommandError.nonZeroExit("插件候选启动 preflight 失败，active profile 未改变。")
        }

        guard FileManager.default.fileExists(atPath: stagingProfile.appendingPathComponent("package.json").path) else {
            PluginOperationLog.append(
                "STAGING PROFILE INVALID: package.json missing",
                to: paths.pluginOperationsLog
            )
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
            PluginOperationLog.append(
                "ACTIVATE FAILED \(Self.redact(error.localizedDescription))",
                to: paths.pluginOperationsLog
            )
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
        PluginOperationLog.append(
            "ACTIVATE SUCCEEDED \(Self.redact(arguments.joined(separator: " ")))",
            to: paths.pluginOperationsLog
        )
        AppLogger.plugins.info(
            "Plugin profile activated: \(Self.redact(arguments.joined(separator: " ")), privacy: .public)"
        )
        return result
    }

    private func run(
        installation: RuntimeInstallation,
        arguments: [String],
        environment additions: [String: String],
        currentDirectory: URL,
        logURL: URL
    ) async throws -> PluginCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let outputBuffer = PluginProcessOutputBuffer()
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

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        let commandDescription = Self.redact(arguments.joined(separator: " "))
        AppLogger.plugins.info("Plugin command started: \(commandDescription, privacy: .public)")
        PluginOperationLog.append(
            "START \(commandDescription)",
            to: logURL
        )
        let completionGate = PluginProcessCompletionGate()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                let output = outputBuffer.stringValue
                let redactedOutput = Self.redact(output)
                if process.terminationStatus == 0 {
                    AppLogger.plugins.info("Plugin command completed: \(commandDescription, privacy: .public)")
                    PluginOperationLog.append(
                        "EXIT 0 \(commandDescription)\n\(redactedOutput)",
                        to: logURL
                    )
                } else {
                    AppLogger.plugins.error(
                        "Plugin command failed (\(process.terminationStatus)): \(redactedOutput, privacy: .public)"
                    )
                    PluginOperationLog.append(
                        "EXIT \(process.terminationStatus) \(commandDescription)\n\(redactedOutput)",
                        to: logURL
                    )
                }
                guard completionGate.claim() else { return }
                continuation.resume(returning: PluginCommandResult(
                    status: process.terminationStatus,
                    output: output
                ))
            }
            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                guard completionGate.claim() else { return }
                AppLogger.plugins.error(
                    "Plugin command launch failed: \(error.localizedDescription, privacy: .public)"
                )
                PluginOperationLog.append(
                    "LAUNCH FAILED \(commandDescription): \(SensitiveDataRedactor.redact(error.localizedDescription))",
                    to: logURL
                )
                continuation.resume(throwing: PluginCommandError.failedToLaunch(error.localizedDescription))
            }
        }
    }

    private nonisolated static func redact(_ output: String) -> String {
        SensitiveDataRedactor.redact(output)
            .split(separator: "\n")
            .suffix(80)
            .joined(separator: "\n")
    }
}

enum PluginOperationLog {
    static func append(_ event: String, to url: URL) {
        let redacted = SensitiveDataRedactor.redact(event)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(redacted)\n"
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue >= 1_000_000 {
                let timestamp = Int(Date().timeIntervalSince1970)
                let rotated = url.deletingLastPathComponent()
                    .appendingPathComponent("plugin-operations-\(timestamp).log")
                try? fileManager.moveItem(at: url, to: rotated)
            }
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            AppLogger.plugins.error(
                "Could not persist plugin operation log: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private final class PluginProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

private final class PluginProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
