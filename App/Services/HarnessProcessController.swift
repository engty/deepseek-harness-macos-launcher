import Darwin
import Foundation

/// Sidecar identity stored in the PID file. The process start time and nonce
/// let the next launch prove that a lingering PID actually belongs to this
/// App's previous sidecar instead of a reused PID that now points at an
/// unrelated process.
private struct SidecarPIDRecord: Codable {
    let pid: Int
    let nonce: String
    let startedAt: Date
    let executable: String
}

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
            return "等待 Harness Web UI 就绪超时。插件首次启动可能正在准备依赖，请稍后重试；若持续失败可导出诊断。"
        }
    }
}

@MainActor
final class HarnessProcessController {
    /// Plugins may prepare a private runtime before Harness prints its ready
    /// URL. Keep this longer than the vision toolkit's first-run dependency
    /// preparation timeout so the launcher does not kill a healthy process.
    static let defaultReadinessTimeout: TimeInterval = 12 * 60

    private let readinessTimeout: TimeInterval
    private let baseEnvironment: [String: String]
    private(set) var process: Process?
    var onUnexpectedTermination: (@MainActor (String) -> Void)?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readinessContinuation: CheckedContinuation<URL, Error>?
    private var launchToken = UUID()
    private var outputBuffer = ""
    private var sidecarPIDURL: URL?
    /// Thread-safe sink that coalesces pipe chunks and hands them to the main
    /// actor in bounded batches (see PendingOutputSink).
    private let pendingOutputSink = PendingOutputSink()

    init() {
        readinessTimeout = Self.defaultReadinessTimeout
        baseEnvironment = ProcessInfo.processInfo.environment
    }

    init(readinessTimeout: TimeInterval, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.readinessTimeout = max(1, readinessTimeout)
        baseEnvironment = environment
    }

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
        let currentDirectory = currentDirectoryOverride ?? paths.activeDataSlot
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let harnessHome = dshHomeOverride ?? paths.dshHome
        try Dsh1024Adapter.sync(profile: harnessHome.appendingPathComponent("profiles/web"))
        let environment = try PluginExecutionEnvironment.make(
            installation: installation, paths: paths, dshHome: harnessHome, base: baseEnvironment
        )

        // Use the explicit profile form because the current web alias rejects
        // parent launcher flags such as --patch. Newer Harness runtimes expose
        // `--no-open`, which keeps the UI inside this App's WKWebView. Probe
        // the installed runtime instead of assuming a version threshold so
        // older runtimes remain launchable without receiving an unknown flag.
        var dshArguments = [
            "--profile", "web"
        ] + (overlayURL.map { ["--patch", $0.path] } ?? []) + [
            "--host", "127.0.0.1",
            "--port", "0"
        ]
        if await supportsNoOpen(
            installation: installation,
            environment: environment,
            currentDirectory: currentDirectory
        ) {
            dshArguments.append("--no-open")
        }

        let command = installation.command(arguments: dshArguments)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        let token = UUID()
        launchToken = token

        // Install the termination handler before `run()` so an instantly
        // exiting child is still observed (previously the handler was set
        // after run, leaving a window where the exit was missed until the
        // readiness timeout).
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleTermination(process, token: token)
            }
        }

        attachOutputHandler(to: outputPipe, isError: false, token: token)
        attachOutputHandler(to: errorPipe, isError: true, token: token)

        do {
            try process.run()
            sidecarPIDURL = paths.sidecarPID
            let record = SidecarPIDRecord(
                pid: Int(process.processIdentifier),
                nonce: token.uuidString,
                startedAt: Date(),
                executable: installation.executable.path
            )
            try? JSONEncoder().encode(record).write(
                to: paths.sidecarPID,
                options: .atomic
            )
        } catch {
            cleanupProcess()
            throw HarnessProcessError.failedToLaunch(error.localizedDescription)
        }

        let timeoutNanoseconds = UInt64(readinessTimeout * 1_000_000_000)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: timeoutNanoseconds
            )
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

    private func attachOutputHandler(to pipe: Pipe, isError: Bool, token: UUID) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            // Coalesce chunks: at most one MainActor task is scheduled per
            // burst, so a noisy sidecar cannot flood the main actor with one
            // task per pipe chunk.
            let shouldSchedule = self.pendingOutputSink.append(data)
            guard shouldSchedule else { return }
            Task { @MainActor [weak self] in
                self?.drainPendingOutput(isError: isError, token: token)
            }
        }
    }

    private func drainPendingOutput(isError: Bool, token: UUID) {
        guard let data = pendingOutputSink.drain(), !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        consume(text, isError: isError, token: token)
    }

    private func consume(_ text: String, isError: Bool, token: UUID) {
        // Only output belonging to the current launch may update the
        // readiness buffer; a stale chunk from a previous sidecar would
        // otherwise be mistaken for this launch's ready URL.
        guard token == launchToken else { return }
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
        guard let url = Self.readinessURL(from: text) else { return }
        let continuation = readinessContinuation
        readinessContinuation = nil
        continuation?.resume(returning: url)
    }

    /// Harness 0.1.2 and later append a one-time browser launch token to the
    /// printed URI. Keep the complete local URI so the WebView can exchange
    /// that token for its HttpOnly session cookie; never reduce it to only the
    /// port. The host is deliberately restricted to loopback because this
    /// URL is an internal App transport, not a remote navigation target.
    static func readinessURL(from text: String) -> URL? {
        let pattern = #"dsh web:\s+(https?://(?:127\.0\.0\.1|localhost):\d+(?:[/?#][^\s\"'<>]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text),
              let url = URL(string: String(text[range])),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "") else {
            return nil
        }
        return url
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
        if let process, let sidecarPIDURL,
           let data = try? Data(contentsOf: sidecarPIDURL),
           let record = try? JSONDecoder().decode(SidecarPIDRecord.self, from: data),
           record.pid == process.processIdentifier {
            try? FileManager.default.removeItem(at: sidecarPIDURL)
        }
        sidecarPIDURL = nil
        pendingOutputSink.reset()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process?.terminationHandler = nil
        process = nil
    }

    private func supportsNoOpen(
        installation: RuntimeInstallation,
        environment: [String: String],
        currentDirectory: URL
    ) async -> Bool {
        let command = installation.command(arguments: ["--profile", "web", "--help"])
        guard let result = try? await SubprocessRunner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: 15,
            outputLimit: 128 * 1024
        ), result.status == 0 else {
            return false
        }
        return Self.helpOutputContainsNoOpen(result.output)
    }

    /// Kept separate from process probing so the capability check is explicit
    /// and can be covered without starting a server in tests.
    static func helpOutputContainsNoOpen(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.range(of: #"(^|\s)--no-open(\s|$)"#, options: .regularExpression) != nil
        }
    }

    private func cleanupStaleSidecar(for installation: RuntimeInstallation, paths: AppPaths) {
        guard let data = try? Data(contentsOf: paths.sidecarPID) else { return }
        let pid: Int32
        var recordedStartTime: Date?

        if let record = try? JSONDecoder().decode(SidecarPIDRecord.self, from: data) {
            pid = Int32(record.pid)
            recordedStartTime = record.startedAt
        } else if let legacyPID = Int32(
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            // Legacy plain-integer PID files keep the previous path-only
            // behaviour for one upgrade cycle.
            pid = legacyPID
        } else {
            try? FileManager.default.removeItem(at: paths.sidecarPID)
            return
        }

        guard pid > 0, pid != getpid() else {
            try? FileManager.default.removeItem(at: paths.sidecarPID)
            return
        }

        let runningPath = executablePath(of: pid)
        let allowedPaths = [installation.nodeExecutable?.path, installation.executable.path].compactMap { $0 }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        guard let runningPath,
              allowedPaths.contains(URL(fileURLWithPath: runningPath).resolvingSymlinksInPath().standardizedFileURL.path) else {
            // Do not remove a PID file that no longer refers to this App's
            // Runtime; it may have been reused by an unrelated process.
            try? FileManager.default.removeItem(at: paths.sidecarPID)
            return
        }

        if let recordedStartTime {
            // The executable path matches, but a reused PID can still point
            // at a different instance of the same binary. Only kill when the
            // recorded process start time matches the live one.
            guard let liveStart = processStartTime(of: pid),
                  abs(liveStart.timeIntervalSince(recordedStartTime)) < 5 else {
                try? FileManager.default.removeItem(at: paths.sidecarPID)
                return
            }
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

    private func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let pathLength = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard pathLength > 0 else { return nil }
        return String(
            decoding: buffer.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    private func processStartTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_starttime.tv_sec))
    }
}

/// Coalesces pipe chunks off the main actor. `append` returns true when the
/// caller should schedule the next drain on the main actor; `drain` returns
/// everything accumulated since the last drain and re-arms the flag.
final class PendingOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var drainScheduled = false

    func append(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return false }
        lock.lock()
        data.append(chunk)
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        lock.unlock()
        return shouldSchedule
    }

    func drain() -> Data? {
        lock.lock()
        guard drainScheduled else {
            lock.unlock()
            return nil
        }
        let snapshot = data
        data = Data()
        drainScheduled = false
        lock.unlock()
        return snapshot
    }

    func reset() {
        lock.lock()
        data = Data()
        drainScheduled = false
        lock.unlock()
    }
}
