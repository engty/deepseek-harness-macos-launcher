import Foundation

enum SensitiveDataRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let definitions: [(String, String)] = [
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(\b(?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret|cookie)\b\s*[:=]\s*[\"']?)[^\s,;\"']+"#, "$1[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_API_KEY]")
        ]
        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ value: String) -> String {
        patterns.reduce(value) { result, item in
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return item.0.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: item.1
            )
        }
    }
}
