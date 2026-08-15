import Foundation

/// Strict SemVer 2.0 parser/comparator used by both Runtime manifest and App
/// update version checks. Unlike the previous permissive parsers, it keeps
/// prerelease identifiers and rejects malformed suffixes instead of silently
/// truncating them (`1.2.3rc`, `1.2foo` are invalid, and `1.0.0-rc.1` sorts
/// below `1.0.0`).
struct StrictSemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var remainder = trimmed.drop { $0 == "v" || $0 == "V" }

        func nextComponent() -> Int? {
            let digits = remainder.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            remainder = remainder.dropFirst(digits.count)
            return Int(digits)
        }

        guard let parsedMajor = nextComponent(), remainder.first == "." else { return nil }
        remainder = remainder.dropFirst()
        guard let parsedMinor = nextComponent(), remainder.first == "." else { return nil }
        remainder = remainder.dropFirst()
        guard let parsedPatch = nextComponent() else { return nil }

        var prereleaseIdentifiers: [String] = []
        if remainder.first == "-" {
            remainder = remainder.dropFirst()
            let prereleaseText = remainder.prefix { $0 != "+" }
            remainder = remainder.dropFirst(prereleaseText.count)
            let identifiers = prereleaseText.split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            for identifier in identifiers {
                guard !identifier.isEmpty,
                      identifier.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "-") }) else {
                    return nil
                }
                if identifier.first?.isNumber == true, !identifier.allSatisfy({ $0.isNumber }) {
                    // Numeric identifiers must not contain leading zeroes.
                    return nil
                }
                if identifier.first == "0", identifier.count > 1, identifier.allSatisfy({ $0.isNumber }) {
                    return nil
                }
                prereleaseIdentifiers.append(String(identifier))
            }
        }

        // A trailing build-metadata section (`+...`) is legal SemVer and is
        // ignored for ordering, but any other trailing content is invalid.
        if remainder.first == "+" {
            remainder = remainder.dropFirst()
            guard remainder.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "-" || $0 == ".") }),
                  !remainder.isEmpty else { return nil }
        } else if !remainder.isEmpty {
            return nil
        }

        major = parsedMajor
        minor = parsedMinor
        patch = parsedPatch
        prerelease = prereleaseIdentifiers
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : "\(base)-\(prerelease.joined(separator: "."))"
    }

    static func < (lhs: StrictSemanticVersion, rhs: StrictSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A version with a prerelease is lower than the same version without.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (lhsID, rhsID) in zip(lhs.prerelease, rhs.prerelease) {
            if lhsID == rhsID { continue }
            let lhsNumber = Int(lhsID)
            let rhsNumber = Int(rhsID)
            switch (lhsNumber, rhsNumber) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                // Numeric identifiers always compare lower than alphanumeric.
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhsID < rhsID
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
