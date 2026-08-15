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

    private func extract(_ artifact: URL, to destination: URL) async throws {
        let listing = try await run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tf", artifact.path]
        )
        guard listing.status == 0 else {
            throw RuntimeArchiveError.archiveListingFailed(listing.output)
        }
        for entry in listing.output.split(whereSeparator: \.isNewline).map(String.init) {
            try validateArchiveEntry(entry)
        }

        let extraction = try await run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", artifact.path, "-C", destination.path]
        )
        guard extraction.status == 0 else {
            throw RuntimeArchiveError.archiveExtractionFailed(extraction.output)
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
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private struct ToolResult {
        let status: Int32
        let output: String
    }

    private func run(executable: URL, arguments: [String]) async throws -> ToolResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ToolResult(
                    status: process.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
