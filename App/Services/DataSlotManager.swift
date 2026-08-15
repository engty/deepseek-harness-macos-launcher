import Foundation

struct DataSlotActivation {
    let previousSlot: URL
    let candidateSlot: URL
}

enum DataSlotError: LocalizedError {
    case cloneFailed(String)
    case activationFailed(String)
    case rollbackFailed(String)
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let message):
            return "无法复制 Harness 数据 slot：\(message)"
        case .activationFailed(let message):
            return "无法切换 Harness 数据 slot：\(message)"
        case .rollbackFailed(let message):
            return "数据 slot 恢复失败：\(message)"
        case .recoveryFailed(let message):
            return "数据 slot 事务恢复失败：\(message)"
        }
    }
}

/// Journal written before the active slot is moved, so a crash or power loss
/// between the two rename steps can be repaired on next launch.
struct DataSlotTransactionJournal: Codable {
    static let fileName = "slot-transaction.json"
    static let phaseActiveMoved = "active-moved"

    let phase: String
    let previousSlot: String
    let candidateSlot: String
    let recordedAt: Date
}

/// Provides recoverable data-slot transactions for plugin and Runtime
/// preflight. The active slot is never deleted; it is moved into App-owned
/// backups before a candidate slot becomes active. A durable journal bridges
/// the window between the two moves: `recoverPendingTransaction` is called at
/// launch and before every start to finish or roll back an interrupted swap.
struct DataSlotManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies the active slot off the main actor: a profile with installed
    /// plugins can be hundreds of megabytes, and the copy is pure blocking
    /// file I/O that would otherwise freeze the window and menus.
    func cloneActiveSlot(paths: AppPaths) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager()
            do {
                try paths.prepare()
                let root = paths.caches
                    .appendingPathComponent("updates/data-slots", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let candidate = root.appendingPathComponent("candidate", isDirectory: true)
                try fileManager.copyItem(at: paths.activeDataSlot, to: candidate)
                return candidate
            } catch {
                throw DataSlotError.cloneFailed(error.localizedDescription)
            }
        }.value
    }

    func activate(candidateSlot: URL, paths: AppPaths) throws -> DataSlotActivation {
        let previousSlot = paths.backups
            .appendingPathComponent("data-slot-\(Self.timestamp())-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
            try writeJournal(
                phase: DataSlotTransactionJournal.phaseActiveMoved,
                previousSlot: previousSlot,
                candidateSlot: candidateSlot,
                paths: paths
            )
            try fileManager.moveItem(at: paths.activeDataSlot, to: previousSlot)
            do {
                try fileManager.moveItem(at: candidateSlot, to: paths.activeDataSlot)
            } catch {
                var restoreFailed = false
                do {
                    try fileManager.moveItem(at: previousSlot, to: paths.activeDataSlot)
                } catch {
                    restoreFailed = true
                }
                if restoreFailed {
                    // Keep the journal: the next launch repairs this state.
                    throw DataSlotError.rollbackFailed(
                        "候选 slot 切换失败，且旧 slot 恢复也失败。事务日志已保留，下次启动将自动恢复。"
                    )
                }
                try removeJournal(paths: paths)
                throw error
            }
            try removeJournal(paths: paths)
            return DataSlotActivation(previousSlot: previousSlot, candidateSlot: paths.activeDataSlot)
        } catch let error as DataSlotError {
            throw error
        } catch {
            try? removeJournal(paths: paths)
            throw DataSlotError.activationFailed(error.localizedDescription)
        }
    }

    /// Restores the old slot and preserves the failed candidate under the
    /// diagnostics/backups tree for post-update investigation. Restore
    /// failures are loud instead of being silently swallowed.
    func rollback(_ activation: DataSlotActivation, paths: AppPaths) throws {
        let failedSlot = paths.backups
            .appendingPathComponent("failed-data-slot-\(Self.timestamp())-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: activation.candidateSlot.path) {
            try? fileManager.moveItem(at: activation.candidateSlot, to: failedSlot)
        }
        guard fileManager.fileExists(atPath: activation.previousSlot.path) else {
            throw DataSlotError.recoveryFailed(
                "rollback 时找不到旧 slot：\(activation.previousSlot.path)"
            )
        }
        do {
            try fileManager.moveItem(at: activation.previousSlot, to: paths.activeDataSlot)
        } catch {
            throw DataSlotError.rollbackFailed(error.localizedDescription)
        }
    }

    /// Finishes or rolls back an interrupted slot swap. Called at launch and
    /// before every Harness start; a no-op when no transaction is pending.
    func recoverPendingTransaction(paths: AppPaths) {
        let journalURL = journalURL(paths: paths)
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(DataSlotTransactionJournal.self, from: data) else {
            return
        }

        let previousSlot = URL(fileURLWithPath: journal.previousSlot).standardizedFileURL
        let candidateSlot = URL(fileURLWithPath: journal.candidateSlot).standardizedFileURL

        // The journal only ever holds paths inside App-owned directories.
        // Ignore anything else instead of moving arbitrary user files.
        guard isAppOwnedSlotPath(previousSlot, paths: paths),
              isAppOwnedSlotPath(candidateSlot, paths: paths) else {
            AppLogger.launcher.error("Ignored data-slot journal with unexpected paths.")
            try? removeJournal(paths: paths)
            return
        }

        let activeExists = fileManager.fileExists(atPath: paths.activeDataSlot.path)
        let previousExists = fileManager.fileExists(atPath: previousSlot.path)
        let candidateExists = fileManager.fileExists(atPath: candidateSlot.path)

        do {
            if activeExists {
                // The swap completed right before the crash: only the journal
                // deletion was lost.
                try removeJournal(paths: paths)
            } else if candidateExists {
                // Active was moved away but the candidate never landed:
                // finish the transaction forward.
                try fileManager.moveItem(at: candidateSlot, to: paths.activeDataSlot)
                try removeJournal(paths: paths)
                AppLogger.launcher.info("Recovered data-slot transaction by activating the candidate slot.")
            } else if previousExists {
                // The candidate is gone: roll back to the previous slot.
                try fileManager.moveItem(at: previousSlot, to: paths.activeDataSlot)
                try removeJournal(paths: paths)
                AppLogger.launcher.info("Recovered data-slot transaction by restoring the previous slot.")
            } else {
                AppLogger.launcher.error(
                    "Data-slot journal exists but neither slot is available; starting with a fresh profile."
                )
                try removeJournal(paths: paths)
            }
        } catch {
            AppLogger.launcher.error("Data-slot transaction recovery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Journal I/O

    private func journalURL(paths: AppPaths) -> URL {
        paths.state.appendingPathComponent(DataSlotTransactionJournal.fileName)
    }

    private func writeJournal(
        phase: String,
        previousSlot: URL,
        candidateSlot: URL,
        paths: AppPaths
    ) throws {
        let journal = DataSlotTransactionJournal(
            phase: phase,
            previousSlot: previousSlot.path,
            candidateSlot: candidateSlot.path,
            recordedAt: Date()
        )
        let data = try JSONEncoder().encode(journal)
        let url = journalURL(paths: paths)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func removeJournal(paths: AppPaths) throws {
        let url = journalURL(paths: paths)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func isAppOwnedSlotPath(_ url: URL, paths: AppPaths) -> Bool {
        let value = url.standardizedFileURL.path
        let supportPrefix = paths.applicationSupport.standardizedFileURL.path + "/"
        let cachesPrefix = paths.caches.standardizedFileURL.path + "/"
        // Previous slots live under backups (Application Support); candidate
        // slots live under the caches data-slot tree.
        guard value.hasPrefix(supportPrefix) || value.hasPrefix(cachesPrefix) else { return false }
        return value.hasPrefix(paths.backups.standardizedFileURL.path + "/")
            || value.hasPrefix(paths.caches.appendingPathComponent("updates/data-slots", isDirectory: true).standardizedFileURL.path + "/")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
