import Foundation

enum DeepSeekCredentialStoreError: LocalizedError {
    case invalidValue
    case unreadableDocument
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "DeepSeek API Key 格式无效。"
        case .unreadableDocument:
            return "Harness 凭据文件无法解析，请通过更换 API Key 重新保存。"
        case .writeFailed(let message):
            return "无法同步 Harness 凭据文件：\(message)"
        }
    }
}

/// Bridges the App's Keychain binding with Harness's standard credential file.
/// The file contains the provider's normal `DEEPSEEK_API_KEY` reference, so
/// the Web Models page and the native balance query always resolve one value.
struct DeepSeekCredentialStore {
    static let reference = "DEEPSEEK_API_KEY"
    static let fileName = ".credentials.yaml"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read(from dshHome: URL) throws -> String? {
        let url = credentialsURL(in: dshHome)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // Never follow a symlink planted at the credentials path: reading
        // through it could surface unrelated file contents as the API key.
        if isSymbolicLink(url) { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DeepSeekCredentialStoreError.unreadableDocument
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.hasPrefix("\u{FEFF}") ? String(rawLine.dropFirst()) : rawLine
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            guard indentation.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == Self.reference else { continue }
            let scalar = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !scalar.isEmpty else { throw DeepSeekCredentialStoreError.invalidValue }
            return try decodeScalar(String(scalar))
        }
        return nil
    }

    func write(_ apiKey: String, to dshHome: URL) throws {
        guard !apiKey.isEmpty else { throw DeepSeekCredentialStoreError.invalidValue }
        try fileManager.createDirectory(at: dshHome, withIntermediateDirectories: true)

        let url = credentialsURL(in: dshHome)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines)
        let replacement = "\(Self.reference): \(encodeScalar(apiKey))"
        var replaced = false

        for index in lines.indices {
            let line = lines[index]
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            guard indentation.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == Self.reference else { continue }
            lines[index] = replacement
            replaced = true
            break
        }

        if !replaced {
            if !existing.isEmpty, !existing.hasSuffix("\n") { lines.append("") }
            lines.append(replacement)
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        try writeOwnerOnly(text, to: url)
    }

    private func credentialsURL(in dshHome: URL) -> URL {
        dshHome.appendingPathComponent(Self.fileName)
    }

    private func decodeScalar(_ scalar: String) throws -> String {
        if scalar.first == "\"" {
            guard let data = scalar.data(using: .utf8),
                  let value = try? JSONDecoder().decode(String.self, from: data),
                  !value.isEmpty else {
                throw DeepSeekCredentialStoreError.invalidValue
            }
            return value
        }

        if scalar.first == "'" {
            guard scalar.last == "'", scalar.count >= 2 else {
                throw DeepSeekCredentialStoreError.invalidValue
            }
            let start = scalar.index(after: scalar.startIndex)
            let end = scalar.index(before: scalar.endIndex)
            let value = String(scalar[start..<end]).replacingOccurrences(of: "''", with: "'")
            guard !value.isEmpty else { throw DeepSeekCredentialStoreError.invalidValue }
            return value
        }

        let value = scalar.split(separator: " #", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DeepSeekCredentialStoreError.invalidValue }
        return value
    }

    private func encodeScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func writeOwnerOnly(_ text: String, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            // Create the temp file directly with 0600 so there is no window
            // in which another local process could read the plaintext key
            // (the previous approach created it with default permissions and
            // only chmod'ed afterwards).
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: Data(text.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw DeepSeekCredentialStoreError.writeFailed("无法创建临时凭据文件。")
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            if isSymbolicLink(url) {
                try fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as DeepSeekCredentialStoreError {
            throw error
        } catch {
            throw DeepSeekCredentialStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
