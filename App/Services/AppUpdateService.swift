import Foundation

struct AppUpdateResult: Equatable {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
    let releaseName: String?
    let publishedAt: Date?

    var isUpdateAvailable: Bool {
        guard let latest = StrictSemanticVersion(rawValue: latestVersion) else { return false }
        guard let current = StrictSemanticVersion(rawValue: currentVersion) else { return true }
        return latest > current
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidFeedURL
    case invalidResponse
    case invalidJSON
    case invalidReleaseURL
    case invalidReleaseVersion

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            return "DeepSeek Harness App 更新源地址无效。"
        case .invalidResponse:
            return "GitHub App 更新服务返回了无效响应。"
        case .invalidJSON:
            return "GitHub App 更新信息不是有效 JSON。"
        case .invalidReleaseURL:
            return "GitHub Release 下载地址不是受信任的 HTTPS 地址。"
        case .invalidReleaseVersion:
            return "GitHub Release 没有可识别的版本号。"
        }
    }
}

@MainActor
final class AppUpdateService {
    private static let defaultFeedURL = URL(
        string: "https://api.github.com/repos/engty/deepseek-harness-macos-launcher/releases/latest"
    )!

    private let feedURL: URL?
    private let session: URLSession

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession? = nil
    ) {
        let rawURL = environment["HARNESS_APP_UPDATE_URL"]
        if let rawURL, !rawURL.isEmpty {
            feedURL = URL(string: rawURL)
        } else {
            feedURL = Self.defaultFeedURL
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

    func check(currentVersion: String) async throws -> AppUpdateResult {
        guard let feedURL, feedURL.scheme == "https" else {
            throw AppUpdateError.invalidFeedURL
        }

        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DeepSeek-Harness-macOS-Launcher", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.invalidResponse
        }

        let release: GitHubRelease
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            release = try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw AppUpdateError.invalidJSON
        }

        guard let latestVersion = StrictSemanticVersion(rawValue: release.tagName)?.description else {
            throw AppUpdateError.invalidReleaseVersion
        }
        guard release.htmlURL.scheme == "https",
              release.htmlURL.host == "github.com" else {
            throw AppUpdateError.invalidReleaseURL
        }

        return AppUpdateResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: release.htmlURL,
            releaseName: release.name,
            publishedAt: release.publishedAt
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
