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
        guard StrictSemanticVersion(rawValue: manifest.minShellVersion) != nil else {
            throw RuntimeManifestError.invalidMinShellVersion(manifest.minShellVersion)
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
        // size == 0 used to act as a wildcard that skipped the exact-size
        // check on download; a manifest must now always declare a positive
        // size so tar bombs cannot dodge the resource limit.
        guard manifest.artifact.size > 0 else {
            throw RuntimeManifestError.invalidArtifactSize
        }
        let hash = manifest.artifact.sha256
        guard hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeManifestError.invalidArtifactHash
        }
    }

    /// Strict SemVer comparison: both sides must parse as valid versions
    /// (prerelease suffixes included), and prerelease versions sort below
    /// the corresponding release. Malformed values are rejected by the
    /// caller before this comparison via `invalidMinShellVersion`.
    private static func satisfiesMinimumShellVersion(current: String, minimum: String) -> Bool {
        guard let currentVersion = StrictSemanticVersion(rawValue: current),
              let minimumVersion = StrictSemanticVersion(rawValue: minimum) else {
            return false
        }
        return currentVersion >= minimumVersion
    }
}
