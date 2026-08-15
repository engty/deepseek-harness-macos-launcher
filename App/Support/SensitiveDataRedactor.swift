import Foundation

enum SensitiveDataRedactor {
    private static let literalLock = NSLock()
    private static var literalSecrets: [String] = []

    /// Registers the currently known secret values (for example the user's
    /// real DeepSeek API key) so redaction no longer depends on recognizing
    /// a key's shape. Literal replacement is exact, so JSON, YAML, header,
    /// query and URL-encoded contexts are all covered.
    static func registerLiteralSecret(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 8 else { return }
        literalLock.lock()
        defer { literalLock.unlock() }
        guard !literalSecrets.contains(trimmed) else { return }
        literalSecrets.append(trimmed)
        if literalSecrets.count > 8 {
            literalSecrets.removeFirst(literalSecrets.count - 8)
        }
    }

    private static func literalSnapshot() -> [String] {
        literalLock.lock()
        defer { literalLock.unlock() }
        return literalSecrets.sorted { $0.count > $1.count }
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        let definitions: [(String, String)] = [
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1[REDACTED]"),
            // Field-name forms: key = value, key: value, "key":"value" and
            // quoted values with spaces. The value alternatives are ordered
            // so quoted strings (which may contain spaces) win; the prefix
            // deliberately stops before the value's own quote.
            (#"(?i)(\b(?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret|cookie|authorization)\b\s*["']?\s*[:=]\s*)((?:"[^"]*"|'[^']*'|[^\s,;="'&]+))"#, "$1[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_API_KEY]")
        ]
        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ value: String) -> String {
        var result = value
        for secret in literalSnapshot() {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED_API_KEY]")
        }
        return patterns.reduce(result) { current, item in
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return item.0.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: item.1
            )
        }
    }
}
