import Foundation

/// Validates a decoded Runtime manifest without performing network or file I/O.
/// The product deliberately uses an unsigned HTTPS feed. The verifier therefore
/// treats the feed URL as an operator-controlled trust boundary and enforces the
/// independent artifact hash, architecture, version and path checks here.
struct RuntimeManifestVerifier {
    static func validate(
        manifest: RuntimeManifest,
        architecture: String,
        shellVersion: String
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw RuntimeManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.hasSafeRuntimeID else {
            throw RuntimeManifestError.invalidRuntimeID
        }
        guard manifest.artifact.url.scheme == "https" else {
            throw RuntimeManifestError.invalidURL
        }
        guard manifest.architecture == architecture else {
            throw RuntimeManifestError.unsupportedArchitecture(manifest.architecture)
        }
        guard satisfiesMinimumShellVersion(
            current: shellVersion,
            minimum: manifest.minShellVersion
        ) else {
            throw RuntimeManifestError.incompatibleShellVersion(
                required: manifest.minShellVersion,
                current: shellVersion
            )
        }
        guard manifest.artifact.size >= 0 else {
            throw RuntimeManifestError.invalidArtifactSize
        }
        let hash = manifest.artifact.sha256
        guard hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeManifestError.invalidArtifactHash
        }
    }

    private static func satisfiesMinimumShellVersion(current: String, minimum: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let values = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(values.count) else { return nil }
            let numbers = values.map { part -> Int? in
                let digits = part.prefix { $0.isNumber }
                return digits.isEmpty ? nil : Int(digits)
            }
            guard numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count)
        }
        guard let currentComponents = components(current),
              let minimumComponents = components(minimum) else { return false }
        return currentComponents.lexicographicallyPrecedes(minimumComponents) == false
    }
}
