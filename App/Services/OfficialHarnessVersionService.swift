import Foundation

/// The official npm registry is used only as a lightweight version signal.
/// Installing still requires a launcher-produced, hash-verified Runtime
/// bundle; an npm package tarball is not treated as an installable Runtime.
struct OfficialHarnessVersionResult: Equatable {
    let version: String
    let packageURL: URL

    func isUpdateAvailable(currentHarnessVersion: String?) -> Bool {
        guard let latest = StrictSemanticVersion(rawValue: version) else { return false }
        guard let currentHarnessVersion,
              let current = StrictSemanticVersion(rawValue: currentHarnessVersion) else {
            return true
        }
        return latest > current
    }
}

enum OfficialHarnessVersionError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case invalidJSON
    case invalidVersion

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "官方 Harness 版本查询地址无效。"
        case .invalidResponse:
            return "官方 Harness 版本服务返回了无效响应。"
        case .invalidJSON:
            return "官方 Harness 版本信息不是有效 JSON。"
        case .invalidVersion:
            return "官方 Harness 返回的版本号无法识别。"
        }
    }
}

@MainActor
final class OfficialHarnessVersionService {
    private static let defaultURL = URL(
        string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest"
    )!
    private static let packageURL = URL(
        string: "https://www.npmjs.com/package/@deepseek-ai/dsh"
    )!

    private let endpoint: URL?
    private let session: URLSession

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession? = nil
    ) {
        if let rawURL = environment["HARNESS_OFFICIAL_VERSION_URL"], !rawURL.isEmpty {
            endpoint = URL(string: rawURL)
        } else {
            endpoint = Self.defaultURL
        }

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func check() async throws -> OfficialHarnessVersionResult {
        guard let endpoint, endpoint.scheme == "https" else {
            throw OfficialHarnessVersionError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DeepSeek-Harness-macOS-Launcher", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw OfficialHarnessVersionError.invalidResponse
        }

        let payload: LatestPackagePayload
        do {
            payload = try JSONDecoder().decode(LatestPackagePayload.self, from: data)
        } catch {
            throw OfficialHarnessVersionError.invalidJSON
        }
        guard let version = StrictSemanticVersion(rawValue: payload.version)?.description else {
            throw OfficialHarnessVersionError.invalidVersion
        }

        return OfficialHarnessVersionResult(version: version, packageURL: Self.packageURL)
    }
}

private struct LatestPackagePayload: Decodable {
    let version: String
}
