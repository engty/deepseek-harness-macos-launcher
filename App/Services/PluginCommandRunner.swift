import Darwin
import Foundation

struct PluginCommandResult {
    let status: Int32
    let output: String
}

enum PluginCommandError: LocalizedError {
    case failedToLaunch(String)
    case nonZeroExit(String)
    case commandTimedOut(command: String, output: String)
    case buildScriptsRequireApproval([String], output: String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return "无法启动 Harness 插件命令：\(message)"
        case .nonZeroExit(let output):
            return "插件命令执行失败。\n\(output)"
        case .commandTimedOut(let command, let output):
            let tail = SensitiveDataRedactor.redact(String(output.suffix(2_000)))
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "插件命令执行超时（\(command)），已终止其进程树。\(detail)"
        case .buildScriptsRequireApproval(let packages, let output):
            return "pnpm 阻止了插件构建脚本：\(packages.joined(separator: "、"))。\n\(output)"
        }
    }
}

@MainActor
final class PluginCommandRunner {
    /// Default wall-clock limit for one `dsh plugin` command (installs with
    /// build scripts can legitimately take minutes; a hung child must not
    /// keep the launcher busy forever).
    private static let defaultCommandTimeout: TimeInterval = 900

    /// The command currently executing (the operation gate serializes all
    /// plugin mutations, so there is at most one).
    private var activeProcess: Process?

    /// Terminates the currently running plugin command and its child tree.
    /// Used when the app quits so pnpm/plugin build children do not survive
    /// as orphans.
    func cancelActiveCommand() {
        guard let process = activeProcess, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            Self.killProcessTree(root: process.processIdentifier)
        }
    }
    func dependencyPlan(
        installation: RuntimeInstallation,
        paths: AppPaths,
        arguments: [String],
        additionalRequirements: [ToolchainRequirement] = []
    ) throws -> PluginDependencyPlan {
        try PluginDependencyService(
            privateToolchainRoot: paths.toolchain
        ).resolve(
            installation: installation,
            arguments: arguments,
            additionalRequirements: additionalRequirements
        )
    }

    func mutateProfile(
        installation: RuntimeInstallation,
        paths: AppPaths,
        arguments: [String],
        dependencyPlan: PluginDependencyPlan? = nil,
        allowedBuildScripts: [String] = []
    ) async throws -> PluginCommandResult {
        let dependencyPlan = try dependencyPlan ?? self.dependencyPlan(
            installation: installation,
            paths: paths,
            arguments: arguments
        )
        let dataSlotManager = DataSlotManager()
        let stagingSlot = try await dataSlotManager.cloneActiveSlot(paths: paths)
        let stagingRoot = stagingSlot.deletingLastPathComponent()
        // The private staging copy is removed on every exit path after this
        // point; only the slot that was actually activated survives.
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let stagingHome = stagingSlot.appendingPathComponent("dsh-home", isDirectory: true)
        let stagingProfile = stagingHome.appendingPathComponent("profiles/web", isDirectory: true)
        let metadataStore = PluginMetadataStore()
        try FileManager.default.createDirectory(at: stagingProfile, withIntermediateDirectories: true)
        PluginOperationLog.append(
            "DEPENDENCY PLAN \(dependencyPlan.dependencies.map { "\($0.name)=\($0.version ?? "unknown") [\($0.source.displayName)]" }.joined(separator: ", "))",
            to: paths.pluginOperationsLog
        )
        if !allowedBuildScripts.isEmpty {
            try PnpmWorkspaceConfig.approveBuildScripts(
                allowedBuildScripts,
                in: stagingProfile
            )
        }

        let result: PluginCommandResult
        result = try await run(
            installation: installation,
            arguments: ["plugin", "--profile", "web"] + arguments,
            environment: PluginDependencyService(
                privateToolchainRoot: paths.toolchain
            ).applying(
                plan: dependencyPlan,
                additions: [
                    "DSH_HOME": stagingHome.path,
                    "DSH_LAUNCHER": "DeepSeekHarness",
                    "MNEMON_DATA_DIR": stagingHome.appendingPathComponent("mnemon", isDirectory: true).path
                ]
            ),
            currentDirectory: stagingProfile,
            logURL: paths.pluginOperationsLog
        )

        guard result.status == 0 else {
            if let packages = Self.parseBuildApprovalPackages(result.output) {
                throw PluginCommandError.buildScriptsRequireApproval(
                    packages,
                    output: Self.redact(result.output)
                )
            }
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
                    "DSH_LAUNCHER": "DeepSeekHarness",
                    "MNEMON_DATA_DIR": stagingHome.appendingPathComponent("mnemon", isDirectory: true).path
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
            throw PluginCommandError.nonZeroExit("插件配置预检失败，当前 profile 未改变。")
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
            throw PluginCommandError.nonZeroExit("插件候选启动预检失败，当前 profile 未改变。")
        }

        // `dsh` may refresh the module-fallback projection during candidate
        // boot. Rebase those links before the temporary slot is activated, so
        // the next cleanup cannot invalidate the newly installed profile.
        try dataSlotManager.rebaseCandidateModuleLinks(
            candidateSlot: stagingSlot,
            paths: paths
        )
        try dataSlotManager.validateCandidateModuleLinks(candidateSlot: stagingSlot)

        guard FileManager.default.fileExists(atPath: stagingProfile.appendingPathComponent("package.json").path) else {
            PluginOperationLog.append(
                "STAGING PROFILE INVALID: package.json missing",
                to: paths.pluginOperationsLog
            )
            throw PluginCommandError.nonZeroExit("临时 profile 没有生成 package.json")
        }

        let metadata = try metadataStore.collect(profileURL: stagingProfile, arguments: arguments)
        try metadataStore.write(
            metadata,
            to: stagingHome.appendingPathComponent("launcher/plugin-metadata.json")
        )

        do {
            _ = try dataSlotManager.activate(candidateSlot: stagingSlot, paths: paths)
        } catch {
            PluginOperationLog.append(
                "ACTIVATE FAILED \(Self.redact(error.localizedDescription))",
                to: paths.pluginOperationsLog
            )
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
        let outputBuffer = BoundedSubprocessOutputBuffer(limit: 4 * 1_024 * 1_024)
        let command = installation.command(arguments: arguments)
        process.executableURL = command.executable
        process.arguments = command.arguments
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
        activeProcess = process
        defer { activeProcess = nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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

                let timeoutWork = DispatchWorkItem {
                    guard completionGate.claim() else { return }
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    AppLogger.plugins.error(
                        "Plugin command timed out: \(commandDescription, privacy: .public)"
                    )
                    if process.isRunning {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning {
                                Self.killProcessTree(root: process.processIdentifier)
                            }
                        }
                    }
                    continuation.resume(throwing: PluginCommandError.commandTimedOut(
                        command: commandDescription,
                        output: outputBuffer.stringValue
                    ))
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Self.defaultCommandTimeout,
                    execute: timeoutWork
                )

                do {
                    try process.run()
                } catch {
                    timeoutWork.cancel()
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
        } onCancel: {
            // The owning Task was cancelled (e.g. the app is quitting): stop
            // the command and its child tree instead of leaving orphans.
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    Self.killProcessTree(root: process.processIdentifier)
                }
            }
        }
    }

    /// TERM then KILL for a whole child tree (pnpm spawns nested node
    /// processes for lifecycle scripts).
    nonisolated static func killProcessTree(root pid: Int32, depth: Int = 0) {
        guard depth < 8 else { return }
        for child in directChildren(of: pid) {
            killProcessTree(root: child, depth: depth + 1)
        }
        kill(pid, SIGKILL)
    }

    private nonisolated static func directChildren(of pid: Int32) -> [Int32] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) } ?? []
        } catch {
            return []
        }
    }

    private nonisolated static func redact(_ output: String) -> String {
        SensitiveDataRedactor.redact(output)
            .split(separator: "\n")
            .suffix(80)
            .joined(separator: "\n")
    }

    nonisolated static func parseBuildApprovalPackages(_ output: String) -> [String]? {
        let marker = #"(?im)ignored build scripts:\s*([^\r\n]+)"#
        guard let markerRegex = try? NSRegularExpression(pattern: marker),
              let match = markerRegex.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let lineRange = Range(match.range(at: 1), in: output) else { return nil }
        let line = String(output[lineRange])
        let pattern = #"(?:(?:@[\w._-]+/)?[\w._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let candidates = regex.matches(
            in: line,
            range: NSRange(line.startIndex..<line.endIndex, in: line)
        ).compactMap { match -> String? in
            guard let range = Range(match.range, in: line) else { return nil }
            let value = String(line[range])
            let ignored = Set(["allowBuilds", "ignored", "build", "scripts", "run", "pnpm"])
            return ignored.contains(value.lowercased()) ? nil : value
        }
        let unique = Array(Set(candidates)).filter {
            $0.contains("/") || $0.range(of: #"^[a-z0-9._-]+$"#, options: [.regularExpression]) != nil
        }.sorted()
        return unique.isEmpty ? nil : unique
    }
}

enum PluginOperationLog {
    /// Cap on how many rotated plugin-operation logs are kept. The log is
    /// append-only and plugin output can be large, so unbounded rotation
    /// would eventually exhaust the disk.
    private static let maxRotatedLogs = 5

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
                let rotated = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        "plugin-operations-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).log"
                    )
                try? fileManager.moveItem(at: url, to: rotated)
                pruneRotatedLogs(in: url.deletingLastPathComponent(), fileManager: fileManager)
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

    private static func pruneRotatedLogs(in directory: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let rotated = entries
            .filter { $0.lastPathComponent.hasPrefix("plugin-operations-") && $0.lastPathComponent.hasSuffix(".log") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        for old in rotated.dropFirst(maxRotatedLogs) {
            try? fileManager.removeItem(at: old)
        }
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
