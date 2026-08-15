import CryptoKit
import Foundation

struct RuntimeUpdateResult {
    let manifest: RuntimeManifest
    let currentRuntimeID: String?
    let currentHarnessVersion: String?

    var isUpdateAvailable: Bool {
        if let currentRuntimeID {
            return currentRuntimeID != manifest.runtimeID
        }
        if let currentHarnessVersion {
            return currentHarnessVersion != manifest.harness.version
        }
        return true
    }
}

@MainActor
final class RuntimeUpdateService {
    private let environment: [String: String]
    private let session: URLSession

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession? = nil
    ) {
        self.environment = environment
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = NoRedirectDelegate()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func check(currentHarnessVersion: String? = nil) async throws -> RuntimeUpdateResult {
        guard let rawFeed = environment["HARNESS_UPDATE_MANIFEST_URL"], !rawFeed.isEmpty,
              let feedURL = URL(string: rawFeed), feedURL.scheme == "https" else {
            throw RuntimeManifestError.feedNotConfigured
        }

        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeManifestError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: RuntimeManifest
        do {
            manifest = try decoder.decode(RuntimeManifest.self, from: data)
        } catch {
            throw RuntimeManifestError.invalidJSON
        }
        try RuntimeManifestVerifier.validate(
            manifest: manifest,
            architecture: currentArchitecture,
            shellVersion: environment["HARNESS_SHELL_VERSION"] ??
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
        )

        let currentID = readCurrentRuntimeID()
        return RuntimeUpdateResult(
            manifest: manifest,
            currentRuntimeID: currentID,
            currentHarnessVersion: currentHarnessVersion
        )
    }

    func download(_ manifest: RuntimeManifest, to destination: URL) async throws -> URL {
        guard manifest.artifact.url.scheme == "https" else { throw RuntimeManifestError.invalidURL }
        let (temporaryURL, response) = try await session.download(from: manifest.artifact.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeManifestError.invalidResponse
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("\(manifest.runtimeID).artifact")
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: temporaryURL, to: target)
        var artifactIsValid = false
        defer {
            if !artifactIsValid {
                try? fileManager.removeItem(at: target)
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        if let size = attributes[.size] as? NSNumber, manifest.artifact.size > 0,
           size.int64Value != manifest.artifact.size {
            throw RuntimeManifestError.artifactSizeMismatch
        }
        let digest = SHA256.hash(data: try Data(contentsOf: target))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(manifest.artifact.sha256) == .orderedSame else {
            throw RuntimeManifestError.artifactHashMismatch
        }
        artifactIsValid = true
        return target
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func readCurrentRuntimeID() -> String? {
        let url = AppPaths().applicationSupport.appendingPathComponent("state/active-runtime.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["runtimeId"] as? String
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
