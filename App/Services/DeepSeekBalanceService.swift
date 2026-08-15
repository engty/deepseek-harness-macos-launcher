import Foundation

enum DeepSeekBalanceError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case unauthorized
    case server(statusCode: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "DeepSeek API 地址无效，必须使用 HTTPS。"
        case .invalidResponse:
            return "DeepSeek 余额接口返回了无效响应。"
        case .unauthorized:
            return "DeepSeek API Key 无效或已失效。"
        case .server(let statusCode):
            return "DeepSeek 余额接口请求失败（HTTP \(statusCode)）。"
        case .emptyResponse:
            return "DeepSeek 余额接口没有返回余额数据。"
        }
    }
}

@MainActor
final class DeepSeekBalanceService {
    private let baseURL: URL
    private let session: URLSession

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // DEEPSEEK_BASE_URL is a local test/代理 hook; only structurally
        // valid HTTPS URLs without credentials/query/fragment are accepted.
        // (A local process that can set the environment can already read the
        // on-disk credential, so this is input validation, not a boundary.)
        let configuredURL = environment["DEEPSEEK_BASE_URL"].flatMap(URL.init(string:))
        if let configuredURL,
           configuredURL.scheme == "https",
           let host = configuredURL.host, !host.isEmpty,
           configuredURL.user == nil, configuredURL.password == nil,
           configuredURL.query == nil, configuredURL.fragment == nil {
            baseURL = configuredURL
        } else {
            baseURL = URL(string: "https://api.deepseek.com")!
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectBalanceDelegate(),
            delegateQueue: nil
        )
    }

    func fetch(apiKey: String) async throws -> DeepSeekBalanceResponse {
        guard baseURL.scheme == "https" else { throw DeepSeekBalanceError.invalidBaseURL }
        let endpoint = baseURL.appendingPathComponent("user/balance")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekBalanceError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DeepSeekBalanceError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekBalanceError.server(statusCode: http.statusCode)
        }
        // Bound the response body: the real balance payload is a few hundred
        // bytes, and an abnormal endpoint must not be able to balloon memory.
        let maxBodyBytes = 1_024 * 1_024
        if http.expectedContentLength > maxBodyBytes {
            throw DeepSeekBalanceError.invalidResponse
        }
        guard data.count <= maxBodyBytes else {
            throw DeepSeekBalanceError.invalidResponse
        }

        let decoded: DeepSeekBalanceResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw DeepSeekBalanceError.invalidResponse
        }
        guard !decoded.balanceInfos.isEmpty else { throw DeepSeekBalanceError.emptyResponse }
        return decoded
    }
}

private final class NoRedirectBalanceDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
