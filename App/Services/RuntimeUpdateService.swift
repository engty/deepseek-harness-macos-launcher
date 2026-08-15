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
        // Whole-transfer deadline (the per-request timeout alone does not
        // bound a slow drip of data).
        configuration.timeoutIntervalForResource = 600
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
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Unique per-attempt staging name: two overlapping downloads (or a
        // stale one) can never remove or overwrite each other's file.
        let target = destination.appendingPathComponent(
            "\(manifest.runtimeID)-\(UUID().uuidString).artifact"
        )
        defer {
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: target)
            }
        }

        var lastError: Error = RuntimeManifestError.invalidResponse
        // Transient network failures get a short bounded retry with backoff;
        // hash/size mismatches do not (they would fail identically again).
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: manifest.artifact.url)
                request.timeoutInterval = 120
                let (temporaryURL, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw RuntimeManifestError.invalidResponse
                }
                try fileManager.moveItem(at: temporaryURL, to: target)

                let attributes = try fileManager.attributesOfItem(atPath: target.path)
                guard let actualSize = (attributes[.size] as? NSNumber)?.int64Value else {
                    throw RuntimeManifestError.artifactSizeMismatch
                }
                guard actualSize == manifest.artifact.size else {
                    throw RuntimeManifestError.artifactSizeMismatch
                }

                let digest = try sha256Hex(of: target)
                guard digest.caseInsensitiveCompare(manifest.artifact.sha256) == .orderedSame else {
                    throw RuntimeManifestError.artifactHashMismatch
                }
                // Transfer ownership to the caller: a validated artifact must
                // not be deleted by this function's defer.
                let finalURL = destination.appendingPathComponent(
                    "\(manifest.runtimeID)-\(UUID().uuidString).verified.artifact"
                )
                try fileManager.moveItem(at: target, to: finalURL)
                return finalURL
            } catch {
                lastError = error
                let permanent = error as? RuntimeManifestError == .artifactHashMismatch
                    || error as? RuntimeManifestError == .artifactSizeMismatch
                if permanent { break }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                }
            }
        }
        throw lastError
    }

    /// Streams the file in 1 MiB chunks instead of loading the whole
    /// artifact into memory (`Data(contentsOf:)` previously made the hash
    /// step an OOM risk for large runtimes).
    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
