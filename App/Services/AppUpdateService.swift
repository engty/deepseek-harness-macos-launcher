import Foundation

struct AppUpdateResult: Equatable {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
    let releaseName: String?
    let publishedAt: Date?

    var isUpdateAvailable: Bool {
        guard let latest = SemanticVersion(rawValue: latestVersion) else { return false }
        return latest > (SemanticVersion(rawValue: currentVersion) ?? .zero)
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

        guard let latestVersion = SemanticVersion(rawValue: release.tagName)?.description else {
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

private struct SemanticVersion: Comparable, CustomStringConvertible {
    static let zero = SemanticVersion(major: 0, minor: 0, patch: 0)

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
        guard let value else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        let numbers = components.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        major = numbers[0] ?? 0
        minor = numbers.count > 1 ? numbers[1] ?? 0 : 0
        patch = numbers.count > 2 ? numbers[2] ?? 0 : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
