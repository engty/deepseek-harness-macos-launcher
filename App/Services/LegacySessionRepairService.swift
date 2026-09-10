import Foundation

/// Repairs legacy v0 Session artifacts before Harness starts reading history.
///
/// Harness Runtime 0.1.5 tightened the v0 validator. Older dsh-mnemon builds
/// wrote a `summary` member on non-`notice` plugin sources, which makes the
/// migration reject the whole Session even though the conversation content is
/// otherwise valid. The helper only removes that obsolete metadata member;
/// every original artifact is moved to an App-owned backup before replacement.
struct LegacySessionRepairSummary: Equatable {
    let scannedFiles: Int
    let repairedSessions: Int
    let repairedMessages: Int
    let failedFiles: Int
}

struct LegacySessionRepairService {
    private let fileManager: FileManager
    private let helperURL: URL?

    init(
        fileManager: FileManager = .default,
        helperURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.helperURL = helperURL ?? Bundle.main.resourceURL?.appendingPathComponent(
            "session-repair/repair_legacy_sessions.mjs",
            isDirectory: false
        )
    }

    /// Repairs all legacy Session artifacts below one App-owned DSH_HOME.
    /// This is deliberately best-effort: one malformed or concurrently written
    /// artifact must not prevent the rest of Harness from starting.
    func repairLegacySessions(
        dshHome: URL,
        installation: RuntimeInstallation,
        backupRoot: URL
    ) async -> LegacySessionRepairSummary {
        let sessionsRoot = dshHome.appendingPathComponent("sessions", isDirectory: true)
        let files = sessionFiles(in: sessionsRoot)
        guard !files.isEmpty else {
            return LegacySessionRepairSummary(
                scannedFiles: 0,
                repairedSessions: 0,
                repairedMessages: 0,
                failedFiles: 0
            )
        }

        guard let helperURL,
              fileManager.isReadableFile(atPath: helperURL.path) else {
            AppLogger.launcher.warning(
                "Legacy Session repair helper is unavailable; preserving existing artifacts."
            )
            return LegacySessionRepairSummary(
                scannedFiles: files.count,
                repairedSessions: 0,
                repairedMessages: 0,
                failedFiles: files.count
            )
        }

        guard let node = installation.nodeExecutable,
              fileManager.isExecutableFile(atPath: node.path) else {
            AppLogger.launcher.warning(
                "Bundled Node is unavailable; skipping legacy Session repair."
            )
            return LegacySessionRepairSummary(
                scannedFiles: files.count,
                repairedSessions: 0,
                repairedMessages: 0,
                failedFiles: files.count
            )
        }

        let repairBackupRoot = backupRoot.appendingPathComponent(
            "legacy-session-repair-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRoot = backupRoot.appendingPathComponent(
            ".legacy-session-repair-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: node,
                arguments: [
                    helperURL.path,
                    "--root", sessionsRoot.path,
                    "--output-root", stagingRoot.path
                ],
                currentDirectory: sessionsRoot,
                timeout: max(120, Double(files.count) * 2)
            )
        } catch {
            AppLogger.launcher.warning(
                "Legacy Session repair helper failed: \(error.localizedDescription, privacy: .public)"
            )
            return LegacySessionRepairSummary(
                scannedFiles: files.count,
                repairedSessions: 0,
                repairedMessages: 0,
                failedFiles: files.count
            )
        }
        guard result.status == 0,
              let report = Self.batchReport(from: result.output) else {
            AppLogger.launcher.warning(
                "Legacy Session repair helper returned an invalid result: \(Self.redacted(result.output), privacy: .public)"
            )
            return LegacySessionRepairSummary(
                scannedFiles: files.count,
                repairedSessions: 0,
                repairedMessages: 0,
                failedFiles: files.count
            )
        }

        var repairedSessions = 0
        var repairedMessages = 0
        var failedFiles = report.failedFiles.count
        for repairedFile in report.repairedFiles {
            let file = sessionsRoot.appendingPathComponent(repairedFile.relativePath, isDirectory: false)
            let staged = stagingRoot.appendingPathComponent(repairedFile.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: file.path),
                  fileManager.fileExists(atPath: staged.path) else {
                failedFiles += 1
                continue
            }
            do {
                let backup = repairBackupRoot.appendingPathComponent(
                    repairedFile.relativePath,
                    isDirectory: false
                )
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: file, to: backup)
                do {
                    try fileManager.moveItem(at: staged, to: file)
                } catch {
                    // Restore the canonical path if publishing the repaired
                    // copy fails, then surface the file as a skipped repair.
                    try? fileManager.moveItem(at: backup, to: file)
                    throw error
                }
                repairedSessions += 1
                repairedMessages += repairedFile.repairedMessages
                AppLogger.launcher.info(
                    "Repaired legacy Session history: \(repairedFile.relativePath, privacy: .public) (\(repairedFile.repairedMessages) metadata entries)."
                )
            } catch {
                failedFiles += 1
                AppLogger.launcher.warning(
                    "Legacy Session repair failed for \(repairedFile.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if repairedSessions > 0 {
            AppLogger.launcher.info(
                "Legacy Session repair completed: \(repairedSessions) Sessions, \(repairedMessages) metadata entries; originals preserved under App backups."
            )
        }
        return LegacySessionRepairSummary(
            scannedFiles: files.count,
            repairedSessions: repairedSessions,
            repairedMessages: repairedMessages,
            failedFiles: failedFiles
        )
    }

    private func sessionFiles(in root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        let names: Set<String> = ["session.jsonl.zstd", "session.jsonl"]
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  names.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private struct BatchReport {
        struct RepairedFile {
            let relativePath: String
            let repairedMessages: Int
        }

        let repairedFiles: [RepairedFile]
        let failedFiles: [String]
    }

    private static func batchReport(from output: String) -> BatchReport? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repaired = object["repairedFiles"] as? [[String: Any]],
              let failed = object["failedFiles"] as? [[String: Any]] else {
            return nil
        }
        let repairedFiles = repaired.compactMap { entry -> BatchReport.RepairedFile? in
            guard let relativePath = entry["relativePath"] as? String,
                  !relativePath.isEmpty,
                  let count = entry["repairedMessages"] as? NSNumber else {
                return nil
            }
            return BatchReport.RepairedFile(
                relativePath: relativePath,
                repairedMessages: max(0, count.intValue)
            )
        }
        let failedFiles = failed.compactMap { $0["relativePath"] as? String }
        return BatchReport(repairedFiles: repairedFiles, failedFiles: failedFiles)
    }

    private static func redacted(_ output: String) -> String {
        let text = SensitiveDataRedactor.redact(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "helper returned no diagnostic" : String(text.suffix(500))
    }
}
