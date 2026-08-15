import Foundation

struct RuntimeManifest: Codable, Equatable {
    let schemaVersion: Int
    let runtimeID: String
    let channel: String
    let architecture: String
    let harness: HarnessVersion
    let nodeVersion: String
    let testedPlugins: [String: TestedPlugin]?
    let minShellVersion: String
    let dataFormat: String
    let artifact: Artifact
    let releaseNotesURL: URL?
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runtimeID = "runtimeId"
        case channel
        case architecture
        case harness
        case nodeVersion
        case testedPlugins
        case minShellVersion
        case dataFormat
        case artifact
        case releaseNotesURL = "releaseNotesUrl"
        case publishedAt
    }

    struct HarnessVersion: Codable, Equatable {
        let package: String
        let version: String
        let commit: String
    }

    struct TestedPlugin: Codable, Equatable {
        let versions: [String]
        let status: String
    }

    struct Artifact: Codable, Equatable {
        let url: URL
        let size: Int64
        let sha256: String
    }

    var hasSafeRuntimeID: Bool {
        !runtimeID.isEmpty && runtimeID.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }

}

enum RuntimeManifestError: LocalizedError, Equatable {
    case feedNotConfigured
    case invalidURL
    case invalidJSON
    case unsupportedSchema(Int)
    case unsupportedArchitecture(String)
    case incompatibleShellVersion(required: String, current: String)
    case invalidRuntimeID
    case invalidArtifactHash
    case invalidArtifactSize
    case invalidResponse
    case artifactHashMismatch
    case artifactSizeMismatch

    var errorDescription: String? {
        switch self {
        case .feedNotConfigured:
            return "当前 App 未配置 Harness Runtime 更新源；这只影响底层 Runtime 更新，不影响 App 使用。"
        case .invalidURL:
            return "更新 feed 或 artifact URL 必须是 HTTPS。"
        case .invalidJSON:
            return "Runtime manifest 不是有效 JSON。"
        case .unsupportedSchema(let version):
            return "不支持的 Runtime manifest schema：\(version)"
        case .unsupportedArchitecture(let architecture):
            return "Runtime 架构不匹配：\(architecture)"
        case .incompatibleShellVersion(let required, let current):
            return "当前 App Shell 版本 \(current) 低于 Runtime 要求的最低版本 \(required)。"
        case .invalidRuntimeID:
            return "Runtime ID 不是安全的目录名称。"
        case .invalidArtifactHash:
            return "Runtime artifact 必须提供 64 位 SHA-256。"
        case .invalidArtifactSize:
            return "Runtime artifact 大小无效。"
        case .invalidResponse:
            return "更新服务返回了无效 HTTP 响应。"
        case .artifactHashMismatch:
            return "Runtime artifact SHA-256 校验失败。"
        case .artifactSizeMismatch:
            return "Runtime artifact 大小校验失败。"
        }
    }
}
