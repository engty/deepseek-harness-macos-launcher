import Foundation

struct PluginPackageMetadata: Codable, Equatable {
    let name: String
    let version: String
    let requestedSpec: String?
    let license: String?
    let repository: String?
    let distributionURL: String?
    let lifecycleScripts: [String]
}

struct PluginMetadata: Codable, Equatable {
    let capturedAt: Date
    let requestedArguments: [String]
    let packages: [PluginPackageMetadata]
}

enum PluginMetadataError: LocalizedError {
    case invalidProfile
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "无法从 staging profile 读取插件元数据。"
        case .writeFailed(let message):
            return "无法保存插件元数据：\(message)"
        }
    }
}

struct PluginMetadataStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func collect(profileURL: URL, arguments: [String]) throws -> PluginMetadata {
        let manifestURL = profileURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginMetadataError.invalidProfile
        }
        let dependencies = (manifest["dependencies"] as? [String: Any]) ?? [:]
        let bundles = nestedStringArray(manifest, path: ["dsh", "profile", "bundles"])
        let packages = bundles.compactMap { packageName -> PluginPackageMetadata? in
            guard let packageSpec = dependencies[packageName] as? String else { return nil }
            let packageURL = profileURL.appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(packageName, isDirectory: true)
                .resolvingSymlinksInPath()
            guard let packageData = try? Data(contentsOf: packageURL.appendingPathComponent("package.json")),
                  let packageManifest = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
                  let version = packageManifest["version"] as? String else { return nil }
            let scripts = (packageManifest["scripts"] as? [String: Any]) ?? [:]
            let lifecycleNames = ["preinstall", "install", "postinstall", "prepare", "prepublish", "postpublish"]
                .filter { scripts[$0] != nil }
            let distributionURL = (packageManifest["dist"] as? [String: Any])?["tarball"] as? String
            return PluginPackageMetadata(
                name: packageManifest["name"] as? String ?? packageName,
                version: version,
                requestedSpec: SensitiveDataRedactor.redact(packageSpec),
                license: licenseValue(packageManifest["license"]),
                repository: repositoryValue(packageManifest["repository"]),
                distributionURL: distributionURL.map(SensitiveDataRedactor.redact),
                lifecycleScripts: lifecycleNames
            )
        }
        return PluginMetadata(
            capturedAt: Date(),
            requestedArguments: arguments.map(SensitiveDataRedactor.redact),
            packages: packages
        )
    }

    func write(_ metadata: PluginMetadata, to url: URL) throws {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PluginMetadataError.writeFailed(error.localizedDescription)
        }
    }

    private func nestedStringArray(_ object: [String: Any], path: [String]) -> [String] {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return [] }
            current = next
        }
        return current as? [String] ?? []
    }

    private func licenseValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let object = value as? [String: Any] { return object["type"] as? String }
        return nil
    }

    private func repositoryValue(_ value: Any?) -> String? {
        if let value = value as? String { return SensitiveDataRedactor.redact(value) }
        if let object = value as? [String: Any] {
            let type = object["type"] as? String ?? ""
            let url = object["url"] as? String ?? ""
            let result = [type, url].filter { !$0.isEmpty }.joined(separator: " ")
            return result.isEmpty ? nil : SensitiveDataRedactor.redact(result)
        }
        return nil
    }
}
