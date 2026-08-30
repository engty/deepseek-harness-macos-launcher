import Darwin
import Foundation

enum SubprocessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "无法启动子进程：\(message)"
        case .timedOut(let command, let output):
            let tail = SensitiveDataRedactor.redact(
                String(output.suffix(2_000))
            )
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "子进程执行超时（\(command)），已终止。\(detail)"
        }
    }
}

struct SubprocessResult {
    let status: Int32
    let output: String
    let outputWasTruncated: Bool
}

/// Runs a short-lived helper process and streams its stdout/stderr into a
/// bounded buffer while it runs. Reading only after termination would let the
/// child block forever once the pipe buffer fills (classic pipe deadlock), so
/// the readability handler drains continuously instead.
///
/// The caller is responsible for redacting `output` before display, and for
/// passing absolute tool paths (the runner never searches PATH implicitly).
enum SubprocessRunner {
    static let defaultTimeout: TimeInterval = 120

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = SubprocessRunner.defaultTimeout,
        outputLimit: Int = 4 * 1_024 * 1_024
    ) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let buffer = BoundedSubprocessOutputBuffer(limit: outputLimit)
            let gate = SubprocessCompletionGate()
            // FileHandle readability callbacks can overlap the process
            // termination handler. Reading the final bytes directly there
            // used to let the two paths append chunks out of order; large
            // `tar -tvf` output could then be misparsed as an unsafe archive
            // even though the archive itself was valid. Serialize every pipe
            // read, including the final drain, on one queue.
            let readQueue = DispatchQueue(
                label: "com.harness.desktop.launcher.subprocess-output-\(UUID().uuidString)"
            )
            let commandDescription = executable.lastPathComponent

            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                readQueue.async {
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    buffer.append(data)
                }
            }

            let timeoutWork = DispatchWorkItem {
                guard gate.claim() else { return }
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
                continuation.resume(throwing: SubprocessRunnerError.timedOut(
                    command: commandDescription,
                    output: buffer.stringValue
                ))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            process.terminationHandler = { process in
                timeoutWork.cancel()
                guard gate.claim() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                // The child has already exited here, so draining the rest of
                // the pipe cannot block. Do it on the same serial queue as
                // readability callbacks so no earlier chunk can be appended
                // after the final drain.
                readQueue.sync {
                    buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                }
                continuation.resume(returning: SubprocessResult(
                    status: process.terminationStatus,
                    output: buffer.stringValue,
                    outputWasTruncated: buffer.wasTruncated
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                guard gate.claim() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    throwing: SubprocessRunnerError.launchFailed(error.localizedDescription)
                )
            }
        }
    }
}

final class BoundedSubprocessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > limit {
            data = Data(data.suffix(limit))
            truncated = true
        }
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}

private final class SubprocessCompletionGate: @unchecked Sendable {
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
