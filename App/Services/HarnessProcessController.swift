import Darwin
import Foundation

enum HarnessProcessError: LocalizedError {
    case alreadyRunning
    case failedToLaunch(String)
    case exitedBeforeReady(String)
    case readinessTimeout

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Harness 已经在运行。"
        case .failedToLaunch(let message):
            return "无法启动 Harness：\(message)"
        case .exitedBeforeReady(let output):
            return "Harness 在 UI 就绪前退出。\n\(output)"
        case .readinessTimeout:
            return "等待 Harness Web UI 就绪超时。"
        }
    }
}

@MainActor
final class HarnessProcessController {
    private(set) var process: Process?
    var onUnexpectedTermination: (@MainActor (String) -> Void)?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readinessContinuation: CheckedContinuation<URL, Error>?
    private var launchToken = UUID()
    private var outputBuffer = ""
    private var sidecarPIDURL: URL?

    var isRunning: Bool { process?.isRunning == true }

    func start(
        installation: RuntimeInstallation,
        paths: AppPaths,
        overlayURL: URL?,
        dshHomeOverride: URL? = nil,
        currentDirectoryOverride: URL? = nil
    ) async throws -> URL {
        guard process == nil else { throw HarnessProcessError.alreadyRunning }
        try paths.prepare()
        cleanupStaleSidecar(for: installation, paths: paths)
        outputBuffer = ""

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        // Use the explicit profile form because the current web alias rejects
        // parent launcher flags such as --patch.
        let dshArguments = [
            "--profile", "web"
        ] + (overlayURL.map { ["--patch", $0.path] } ?? []) + [
            "--host", "127.0.0.1",
            "--port", "0"
        ]
        if let nodeExecutable = installation.nodeExecutable {
            process.executableURL = nodeExecutable
            process.arguments = [installation.executable.path] + dshArguments
        } else {
            process.executableURL = installation.executable
            process.arguments = dshArguments
        }
        process.currentDirectoryURL = currentDirectoryOverride ?? paths.activeDataSlot
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = (dshHomeOverride ?? paths.dshHome).path
        environment["DSH_LAUNCHER"] = "DeepSeekHarness"
        process.environment = environment

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        let token = UUID()
        launchToken = token

        attachOutputHandler(to: outputPipe, isError: false)
        attachOutputHandler(to: errorPipe, isError: true)

        do {
            try process.run()
            sidecarPIDURL = paths.sidecarPID
            try? String(process.processIdentifier).write(to: paths.sidecarPID, atomically: true, encoding: .utf8)
        } catch {
            cleanupProcess()
            throw HarnessProcessError.failedToLaunch(error.localizedDescription)
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleTermination(process, token: token)
            }
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.launchToken == token else { return }
            self.failReadiness(HarnessProcessError.readinessTimeout)
        }

        do {
            let url = try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
                if outputBuffer.contains("dsh web:") {
                    resolveReadiness(from: outputBuffer)
                }
            }
            timeoutTask.cancel()
            return url
        } catch {
            timeoutTask.cancel()
            await stop()
            throw error
        }
    }

    func stop() async {
        launchToken = UUID()
        if let continuation = readinessContinuation {
            readinessContinuation = nil
            continuation.resume(throwing: HarnessProcessError.exitedBeforeReady("Harness 被请求停止。"))
        }
        guard let process else {
            cleanupProcess()
            return
        }

        process.terminate()
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.interrupt()
            for _ in 0..<10 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        cleanupProcess()
    }

    private func attachOutputHandler(to pipe: Pipe, isError: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.consume(text, isError: isError)
            }
        }
    }

    private func consume(_ text: String, isError: Bool) {
        outputBuffer.append(text)
        if outputBuffer.count > 160_000 {
            outputBuffer = String(outputBuffer.suffix(160_000))
        }
        let redactedText = SensitiveDataRedactor.redact(text)
        if isError {
            AppLogger.runtime.error("Harness stderr: \(redactedText, privacy: .public)")
        } else {
            AppLogger.runtime.info("Harness stdout: \(redactedText, privacy: .public)")
        }
        resolveReadiness(from: outputBuffer)
    }

    private func resolveReadiness(from text: String) {
        guard readinessContinuation != nil else { return }
        let pattern = #"dsh web:\s+(http://127\.0\.0\.1:\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text),
              let url = URL(string: String(text[range])) else { return }
        let continuation = readinessContinuation
        readinessContinuation = nil
        continuation?.resume(returning: url)
    }

    private func failReadiness(_ error: Error) {
        let continuation = readinessContinuation
        readinessContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func handleTermination(_ process: Process, token: UUID) {
        guard launchToken == token else { return }
        let message = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if readinessContinuation != nil {
            failReadiness(HarnessProcessError.exitedBeforeReady(
                SensitiveDataRedactor.redact(String(message.suffix(4_000)))
            ))
        } else {
            onUnexpectedTermination?(SensitiveDataRedactor.redact(String(message.suffix(4_000))))
        }
        if self.process === process {
            cleanupProcess()
        }
    }

    private func cleanupProcess() {
        if let process, let sidecarPIDURL, let pidText = try? String(contentsOf: sidecarPIDURL, encoding: .utf8),
           Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) == process.processIdentifier {
            try? FileManager.default.removeItem(at: sidecarPIDURL)
        }
        sidecarPIDURL = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process?.terminationHandler = nil
        process = nil
    }

    private func cleanupStaleSidecar(for installation: RuntimeInstallation, paths: AppPaths) {
        guard let pidText = try? String(contentsOf: paths.sidecarPID, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid() else {
            try? FileManager.default.removeItem(at: paths.sidecarPID)
            return
        }

        var buffer = [CChar](repeating: 0, count: 4096)
        let pathLength = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        let runningPath: String? = if pathLength > 0 {
            String(
                decoding: buffer.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        } else {
            nil
        }
        let allowedPaths = [installation.nodeExecutable?.path, installation.executable.path].compactMap { $0 }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        guard let runningPath,
              allowedPaths.contains(URL(fileURLWithPath: runningPath).resolvingSymlinksInPath().standardizedFileURL.path) else {
            // Do not remove a PID file that no longer refers to this App's
            // Runtime; it may have been reused by an unrelated process.
            try? FileManager.default.removeItem(at: paths.sidecarPID)
            return
        }

        _ = Darwin.kill(pid, SIGTERM)
        for _ in 0..<10 {
            if Darwin.kill(pid, 0) != 0 { break }
            usleep(50_000)
        }
        if Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: paths.sidecarPID)
    }
}
