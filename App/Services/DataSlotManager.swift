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
    case profileIntegrityFailed(String)

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
        case .profileIntegrityFailed(let message):
            return "Harness profile 完整性检查失败：\(message)"
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
                try Self.rebaseModuleLinks(
                    in: candidate,
                    sourceSlot: paths.activeDataSlot,
                    paths: paths,
                    fileManager: fileManager,
                    removeMissing: true
                )
                return candidate
            } catch {
                throw DataSlotError.cloneFailed(error.localizedDescription)
            }
        }.value
    }

    /// Rebase links created by the Harness module-fallback layer after a
    /// candidate has been booted. The candidate is moved from the cache into
    /// `data/active`, so absolute links into either location would become
    /// stale as soon as activation completes. External links (for example,
    /// links into the bundled Runtime) are intentionally left untouched.
    func rebaseCandidateModuleLinks(candidateSlot: URL, paths: AppPaths) throws {
        try Self.rebaseModuleLinks(
            in: candidateSlot,
            sourceSlot: paths.activeDataSlot,
            paths: paths,
            fileManager: fileManager,
            removeMissing: false
        )
    }

    /// Repairs an already-active profile left by an older launcher version.
    /// This is safe to run at launch: only links inside the App-owned Harness
    /// web profile are changed, and only when their target is inside an
    /// App-owned slot or update candidate.
    func repairActiveModuleLinks(paths: AppPaths) throws {
        try Self.rebaseModuleLinks(
            in: paths.activeDataSlot,
            sourceSlot: paths.activeDataSlot,
            paths: paths,
            fileManager: fileManager,
            removeMissing: true
        )
    }

    /// Reject a candidate whose profile still contains an unresolved module
    /// link. Runtime `--version` and `--dump-config` checks do not load every
    /// browser/plugin module, so this guard catches the failure before the
    /// candidate can replace the working slot.
    func validateCandidateModuleLinks(candidateSlot: URL) throws {
        let links = try Self.moduleLinkURLs(
            profileWeb: candidateSlot.appendingPathComponent(
                "dsh-home/profiles/web",
                isDirectory: true
            ),
            fileManager: fileManager
        )
        var broken: [String] = []
        for link in links {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                continue
            }
            let target = Self.absoluteTargetPath(
                destination: destination,
                parent: link.deletingLastPathComponent()
            )
            guard !fileManager.fileExists(atPath: target) else { continue }
            broken.append(link.lastPathComponent)
        }
        guard broken.isEmpty else {
            let preview = broken.prefix(5).joined(separator: ", ")
            let suffix = broken.count > 5 ? " 等 \(broken.count) 项" : ""
            throw DataSlotError.profileIntegrityFailed(
                "发现无法解析的模块链接：\(preview)\(suffix)"
            )
        }
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

    // MARK: - Profile module-link hygiene

    private static func rebaseModuleLinks(
        in slot: URL,
        sourceSlot: URL,
        paths: AppPaths,
        fileManager: FileManager,
        removeMissing: Bool
    ) throws {
        let profileWeb = slot.appendingPathComponent(
            "dsh-home/profiles/web",
            isDirectory: true
        )
        let links = try moduleLinkURLs(profileWeb: profileWeb, fileManager: fileManager)
        let candidatePath = slot.standardizedFileURL.path
        let sourcePath = sourceSlot.standardizedFileURL.path
        let cacheDataSlotsPath = paths.caches
            .appendingPathComponent("updates/data-slots", isDirectory: true)
            .standardizedFileURL.path

        for link in links {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                continue
            }
            let targetPath = absoluteTargetPath(
                destination: destination,
                parent: link.deletingLastPathComponent()
            )
            guard let mappedTarget = mapOwnedTarget(
                targetPath,
                candidatePath: candidatePath,
                sourcePath: sourcePath,
                cacheDataSlotsPath: cacheDataSlotsPath
            ) else {
                continue
            }

            // An older active profile can retain an orphaned link for a package
            // that is no longer present in the Runtime closure. Remove that
            // stale projection during active-slot repair/clone instead of
            // carrying a guaranteed failure into the next slot. Candidate
            // post-boot rebasing keeps missing links so validation can reject
            // the update rather than hiding a newly introduced dependency.
            if removeMissing && !fileManager.fileExists(atPath: mappedTarget) {
                try fileManager.removeItem(at: link)
                continue
            }

            let relativeTarget = relativePath(
                from: link.deletingLastPathComponent().standardizedFileURL.path,
                to: mappedTarget
            )
            guard destination != relativeTarget else { continue }

            // `removeItem` removes the link itself even when its destination
            // is dangling; `fileExists` must not be used as the guard here.
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: relativeTarget
            )
        }
    }

    /// Returns only the shallow module-link directories used by pnpm's hoisted
    /// profile and by Harness's private module-fallback projection. Avoiding a
    /// full package-tree walk keeps launch-time repair cheap for large plugins.
    private static func moduleLinkURLs(
        profileWeb: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let roots = [
            profileWeb.appendingPathComponent("node_modules", isDirectory: true),
            profileWeb.appendingPathComponent(
                ".dsh-module-fallback/node_modules",
                isDirectory: true
            )
        ]
        var links: [URL] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
            for entry in entries {
                if (try? fileManager.destinationOfSymbolicLink(atPath: entry.path)) != nil {
                    links.append(entry)
                    continue
                }
                guard entry.lastPathComponent.hasPrefix("@") || entry.lastPathComponent == ".bin",
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                let scopedEntries = try fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                links.append(contentsOf: scopedEntries.filter {
                    (try? fileManager.destinationOfSymbolicLink(atPath: $0.path)) != nil
                })
            }
        }
        return links
    }

    private static func absoluteTargetPath(destination: String, parent: URL) -> String {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL.path
        }
        return parent
            .appendingPathComponent(destination)
            .standardizedFileURL
            .path
    }

    private static func mapOwnedTarget(
        _ targetPath: String,
        candidatePath: String,
        sourcePath: String,
        cacheDataSlotsPath: String
    ) -> String? {
        if targetPath == candidatePath || targetPath.hasPrefix(candidatePath + "/") {
            return targetPath
        }
        if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
            return candidatePath + String(targetPath.dropFirst(sourcePath.count))
        }

        let cachePrefix = cacheDataSlotsPath + "/"
        guard targetPath.hasPrefix(cachePrefix) else { return nil }
        let remainder = String(targetPath.dropFirst(cachePrefix.count))
        guard let marker = remainder.range(of: "/candidate") else { return nil }
        let suffix = remainder[marker.upperBound...]
        guard suffix.isEmpty || suffix.first == "/" else { return nil }
        return candidatePath + String(suffix)
    }

    private static func relativePath(from base: String, to target: String) -> String {
        let baseComponents = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count,
              common < targetComponents.count,
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: baseComponents.count - common)
        let down = Array(targetComponents.dropFirst(common))
        let components = up + down
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}
