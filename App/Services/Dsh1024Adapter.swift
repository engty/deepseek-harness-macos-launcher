import Foundation

enum Dsh1024Adapter {
    static let version = "0.5.0"
    static let files = ["client/client.js", "lib/routes.js", "lib/update.js"]

    enum Failure: LocalizedError {
        case unsupportedVersion(String)
        case missingResources
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "1024 Store \(version) 尚未通过此启动器的适配验证，请使用内置的 0.5.0 版本。"
            case .missingResources:
                return "启动器缺少 1024 Store 适配资源，请重新构建或安装 App。"
            }
        }
    }

    static var resourceDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("dsh1024-launcher"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // SwiftPM tests and the local build use the same reviewed resources.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/dsh1024-launcher")
    }

    @discardableResult
    static func sync(profile: URL, resources: URL = resourceDirectory) throws -> Bool {
        let package = profile.appendingPathComponent("node_modules/dsh1024")
        let manifest = package.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        let installed = json?["version"] as? String ?? "unknown"
        guard json?["name"] as? String == "dsh1024", installed == version else {
            throw Failure.unsupportedVersion(installed)
        }
        // Read all resources before writing any file, so a broken bundle fails early.
        let replacements = try files.map { path -> (URL, Data) in
            let source = resources.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.missingResources }
            return (package.appendingPathComponent(path), try Data(contentsOf: source))
        }
        var changed = false
        for (destination, data) in replacements {
            if (try? Data(contentsOf: destination)) == data { continue }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            changed = true
        }
        return changed
    }
}
