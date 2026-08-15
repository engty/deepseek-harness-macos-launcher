import Foundation

struct DataSlotActivation {
    let previousSlot: URL
    let candidateSlot: URL
}

enum DataSlotError: LocalizedError {
    case cloneFailed(String)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let message):
            return "无法复制 Harness 数据 slot：\(message)"
        case .activationFailed(let message):
            return "无法切换 Harness 数据 slot：\(message)"
        }
    }
}

/// Provides recoverable data-slot transactions for plugin and Runtime
/// preflight. The active slot is never deleted; it is moved into App-owned
/// backups before a candidate slot becomes active.
struct DataSlotManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func cloneActiveSlot(paths: AppPaths) throws -> URL {
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
    }

    func activate(candidateSlot: URL, paths: AppPaths) throws -> DataSlotActivation {
        let previousSlot = paths.backups
            .appendingPathComponent("data-slot-\(Self.timestamp())-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
            try fileManager.moveItem(at: paths.activeDataSlot, to: previousSlot)
            do {
                try fileManager.moveItem(at: candidateSlot, to: paths.activeDataSlot)
            } catch {
                try? fileManager.moveItem(at: previousSlot, to: paths.activeDataSlot)
                throw error
            }
            return DataSlotActivation(previousSlot: previousSlot, candidateSlot: paths.activeDataSlot)
        } catch {
            throw DataSlotError.activationFailed(error.localizedDescription)
        }
    }

    /// Restores the old slot and preserves the failed candidate under the
    /// diagnostics/backups tree for post-update investigation.
    func rollback(_ activation: DataSlotActivation, paths: AppPaths) throws {
        let failedSlot = paths.backups
            .appendingPathComponent("failed-data-slot-\(Self.timestamp())-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: activation.candidateSlot.path) {
            try? fileManager.moveItem(at: activation.candidateSlot, to: failedSlot)
        }
        guard fileManager.fileExists(atPath: activation.previousSlot.path) else { return }
        try fileManager.moveItem(at: activation.previousSlot, to: paths.activeDataSlot)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
