import Foundation

struct RuntimeActivationRecord: Codable, Equatable {
    let runtimeID: String
    let runtimePath: String
    let architecture: String
    let harnessVersion: String

    enum CodingKeys: String, CodingKey {
        case runtimeID = "runtimeId"
        case runtimePath
        case architecture
        case harnessVersion
    }
}

struct RuntimeActivation {
    let installation: RuntimeInstallation
    let runtimePath: URL
    let previousManifestData: Data?
}

enum RuntimeArchiveError: LocalizedError {
    case invalidRuntimeID
    case unsupportedArchive
    case archiveListingFailed(String)
    case archiveExtractionFailed(String)
    case unsafeArchiveEntry(String)
    case unsafeArchiveEntryType(String)
    case duplicateArchiveEntry(String)
    case tooManyArchiveEntries
    case symlinkEscapesRuntime(String)
    case runtimeExecutableMissing
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRuntimeID:
            return "Runtime ID 不是安全的目录名称。"
        case .unsupportedArchive:
            return "Runtime artifact 不是受支持的归档格式。"
        case .archiveListingFailed(let message):
            return "无法读取 Runtime artifact 目录：\(message)"
        case .archiveExtractionFailed(let message):
            return "Runtime artifact 解压失败：\(message)"
        case .unsafeArchiveEntry(let entry):
            return "Runtime artifact 包含不安全路径：\(entry)"
        case .unsafeArchiveEntryType(let detail):
            return "Runtime artifact 包含不允许的条目类型：\(detail)"
        case .duplicateArchiveEntry(let entry):
            return "Runtime artifact 包含重复路径条目：\(entry)"
        case .tooManyArchiveEntries:
            return "Runtime artifact 条目数量超过安全上限。"
        case .symlinkEscapesRuntime(let path):
            return "Runtime artifact 的符号链接越出 Bundle：\(path)"
        case .runtimeExecutableMissing:
            return "Runtime Bundle 中没有可执行的 dsh。"
        case .activationFailed(let message):
            return "Runtime 激活失败：\(message)"
        }
    }
}

@MainActor
final class RuntimeArchiveInstaller {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func activate(
        manifest: RuntimeManifest,
        artifactURL: URL,
        paths: AppPaths,
        previousInstallation: RuntimeInstallation? = nil
    ) async throws -> RuntimeActivation {
        guard manifest.hasSafeRuntimeID else {
            throw RuntimeArchiveError.invalidRuntimeID
        }
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            throw RuntimeArchiveError.activationFailed("artifact 不存在。")
        }

        try paths.prepare()
        let staging = paths.caches
            .appendingPathComponent("updates/staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try await extract(artifactURL, to: staging)
        try validateSymlinks(in: staging)
        let runtimeRoot = try locateRuntimeRoot(in: staging)

        let runtimePath = paths.runtimes.appendingPathComponent(
            "\(manifest.runtimeID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
        try fileManager.moveItem(at: runtimeRoot, to: runtimePath)

        let previousData = try? Data(contentsOf: paths.activeRuntimeManifest)
        var rollbackData = previousData
        let record = RuntimeActivationRecord(
            runtimeID: manifest.runtimeID,
            runtimePath: runtimePath.path,
            architecture: manifest.architecture,
            harnessVersion: manifest.harness.version
        )
        do {
            if let previousData {
                try writeAtomically(previousData, to: paths.lastKnownGoodRuntimeManifest)
            } else if let previousInstallation {
                let previousRecord = RuntimeActivationRecord(
                    runtimeID: "last-known-good",
                    runtimePath: previousInstallation.root.path,
                    architecture: currentArchitecture,
                    harnessVersion: previousInstallation.version ?? "unknown"
                )
                rollbackData = try JSONEncoder().encode(previousRecord)
                try writeAtomically(
                    rollbackData!,
                    to: paths.lastKnownGoodRuntimeManifest
                )
            }
            let data = try JSONEncoder().encode(record)
            try writeAtomically(data, to: paths.activeRuntimeManifest)
        } catch {
            try? fileManager.removeItem(at: runtimePath)
            throw RuntimeArchiveError.activationFailed(error.localizedDescription)
        }

        do {
            let locator = RuntimeLocator(environment: [
                "HARNESS_RUNTIME_ROOT": runtimePath.path,
                "PATH": ""
            ])
            let installation = try locator.locate()
            return RuntimeActivation(
                installation: installation,
                runtimePath: runtimePath,
                previousManifestData: rollbackData
            )
        } catch {
            try? rollback(activation: RuntimeActivation(
                installation: RuntimeInstallation(executable: runtimePath, root: runtimePath, version: nil, nodeExecutable: nil),
                runtimePath: runtimePath,
                previousManifestData: rollbackData
            ), paths: paths)
            throw RuntimeArchiveError.runtimeExecutableMissing
        }
    }

    func rollback(activation: RuntimeActivation, paths: AppPaths) throws {
        try? fileManager.removeItem(at: activation.runtimePath)
        if let previousManifestData = activation.previousManifestData {
            try writeAtomically(previousManifestData, to: paths.activeRuntimeManifest)
        } else if fileManager.fileExists(atPath: paths.activeRuntimeManifest.path) {
            try fileManager.removeItem(at: paths.activeRuntimeManifest)
        }
    }

    func restoreLastKnownGood(paths: AppPaths) throws {
        let data = try Data(contentsOf: paths.lastKnownGoodRuntimeManifest)
        try writeAtomically(data, to: paths.activeRuntimeManifest)
    }

    /// Removes Runtime trees under `runtimes/` that are no longer referenced
    /// by the active or last-known-good manifests. Without this, every
    /// successful update would leave a full node_modules tree (hundreds of
    /// megabytes) on disk forever.
    func cleanupOrphanedRuntimes(paths: AppPaths) {
        let protected = referencedRuntimePaths(paths: paths)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.runtimes,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let standardized = entry.resolvingSymlinksInPath().standardizedFileURL.path
            guard !protected.contains(standardized) else { continue }
            do {
                try fileManager.removeItem(at: entry)
                AppLogger.launcher.info("Removed orphaned Runtime: \(entry.lastPathComponent, privacy: .public)")
            } catch {
                AppLogger.launcher.error(
                    "Could not remove orphaned Runtime \(entry.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func referencedRuntimePaths(paths: AppPaths) -> Set<String> {
        var result: Set<String> = []
        for manifest in [paths.activeRuntimeManifest, paths.lastKnownGoodRuntimeManifest] {
            guard let data = try? Data(contentsOf: manifest),
                  let record = try? JSONDecoder().decode(RuntimeActivationRecord.self, from: data) else {
                continue
            }
            result.insert(URL(fileURLWithPath: record.runtimePath).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return result
    }

    /// Safety limits for untrusted Runtime archives. The real Runtime bundle
    /// currently has ~38k entries; 200k leaves generous headroom while still
    /// bounding work for a tar bomb.
    private static let maxArchiveEntries = 200_000
    // The bundled Runtime currently produces roughly 7 MB for `tar -tf` and
    // 11 MB for `tar -tvf`. Keep a generous bounded ceiling while rejecting
    // anything larger instead of validating a truncated suffix.
    private static let archiveListingOutputLimit = 64 * 1_024 * 1_024
    private static let listingTimeout: TimeInterval = 120
    private static let extractionTimeout: TimeInterval = 600

    private func extract(_ artifact: URL, to destination: URL) async throws {
        let tarExecutable = URL(fileURLWithPath: "/usr/bin/tar")

        // 1. Enumerate every entry path first: reject absolute paths, `..`
        //    components, duplicates and oversized archives before anything
        //    touches the filesystem.
        let listing = try await SubprocessRunner.run(
            executable: tarExecutable,
            arguments: ["-tf", artifact.path],
            timeout: Self.listingTimeout,
            outputLimit: Self.archiveListingOutputLimit
        )
        guard listing.status == 0 else {
            throw RuntimeArchiveError.archiveListingFailed(
                SensitiveDataRedactor.redact(listing.output)
            )
        }
        guard !listing.outputWasTruncated else {
            throw RuntimeArchiveError.archiveListingFailed("Runtime artifact 目录列表超过安全上限。")
        }
        let entries = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        try validateArchiveEntries(entries)

        // 2. Reject hardlink/device/FIFO/socket entries up front. Regular
        //    files, directories and symlinks are the only types the Runtime
        //    bundle legitimately contains (npm `.bin` shims are symlinks).
        //    Symlink containment is verified after extraction below.
        let verbose = try await SubprocessRunner.run(
            executable: tarExecutable,
            arguments: ["-tvf", artifact.path],
            timeout: Self.listingTimeout,
            outputLimit: Self.archiveListingOutputLimit
        )
        guard verbose.status == 0 else {
            throw RuntimeArchiveError.archiveListingFailed(
                SensitiveDataRedactor.redact(verbose.output)
            )
        }
        guard !verbose.outputWasTruncated else {
            throw RuntimeArchiveError.archiveListingFailed("Runtime artifact 类型列表超过安全上限。")
        }
        try validateEntryTypes(verbose.output)

        // 3. Extract into the private staging directory. macOS tar refuses to
        //    extract through symlinks it just created ("Cannot extract
        //    through symlink"), so the entry checks above plus the
        //    post-extraction containment check below cover the escape paths.
        let extraction = try await SubprocessRunner.run(
            executable: tarExecutable,
            arguments: ["-xf", artifact.path, "-C", destination.path],
            timeout: Self.extractionTimeout
        )
        guard extraction.status == 0 else {
            throw RuntimeArchiveError.archiveExtractionFailed(
                SensitiveDataRedactor.redact(extraction.output)
            )
        }
    }

    private func locateRuntimeRoot(in staging: URL) throws -> URL {
        let directCandidates = [
            staging.appendingPathComponent("bin/dsh"),
            staging.appendingPathComponent("dsh"),
            staging.appendingPathComponent("node_modules/.bin/dsh")
        ]
        if let direct = directCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            if direct.path.hasSuffix("/bin/dsh") { return staging }
            if direct.path.hasSuffix("/node_modules/.bin/dsh") {
                return direct.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            }
            return direct.deletingLastPathComponent()
        }

        let entries = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard entries.count == 1 else { throw RuntimeArchiveError.runtimeExecutableMissing }
        let nested = entries[0]
        let nestedCandidates = [
            nested.appendingPathComponent("bin/dsh"),
            nested.appendingPathComponent("dsh"),
            nested.appendingPathComponent("node_modules/.bin/dsh")
        ]
        guard let nestedExecutable = nestedCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw RuntimeArchiveError.runtimeExecutableMissing
        }
        if nestedExecutable.path.hasSuffix("/bin/dsh") { return nested }
        if nestedExecutable.path.hasSuffix("/node_modules/.bin/dsh") {
            return nestedExecutable.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return nestedExecutable.deletingLastPathComponent()
    }

    private func validateArchiveEntries(_ entries: [String]) throws {
        guard entries.count <= Self.maxArchiveEntries else {
            throw RuntimeArchiveError.tooManyArchiveEntries
        }
        var seen: Set<String> = []
        for entry in entries {
            try validateArchiveEntry(entry)
            guard seen.insert(entry).inserted else {
                throw RuntimeArchiveError.duplicateArchiveEntry(entry)
            }
        }
    }

    private func validateArchiveEntry(_ entry: String) throws {
        let normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0") else {
            throw RuntimeArchiveError.unsafeArchiveEntry(entry)
        }
        let components = normalized.split(separator: "/")
        guard !components.contains("..") else {
            throw RuntimeArchiveError.unsafeArchiveEntry(entry)
        }
        guard normalized.utf8.count <= 1_024 else {
            throw RuntimeArchiveError.unsafeArchiveEntry(entry)
        }
    }

    /// `tar -tvf` starts every line with the entry type character:
    /// `-` regular file, `d` directory, `l` symlink, `h` hardlink,
    /// `c`/`b` character/block device, `p` FIFO, `s` socket. Everything
    /// except files, directories and symlinks is rejected because the
    /// Runtime bundle never legitimately contains them.
    private func validateEntryTypes(_ verboseListing: String) throws {
        for rawLine in verboseListing.split(separator: "\n") {
            guard let first = rawLine.first else { continue }
            if "-dl".contains(first) { continue }
            throw RuntimeArchiveError.unsafeArchiveEntryType(String(rawLine.prefix(160)))
        }
    }

    private func validateSymlinks(in root: URL) throws {
        let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == root.standardizedFileURL.path || resolved.hasPrefix(rootPrefix) else {
                throw RuntimeArchiveError.symlinkEscapesRuntime(item.path)
            }
        }
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        // fsync the payload so a power loss cannot leave a zero-length
        // manifest paired with the new Runtime pointer.
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
