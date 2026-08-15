import Foundation

enum PluginCommandParserError: LocalizedError, Equatable {
    case emptyCommand
    case unterminatedQuote
    case unsupportedCommand
    case missingPackageSpec
    case optionNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "没有输入插件安装命令。"
        case .unterminatedQuote:
            return "插件命令中的引号没有闭合。"
        case .unsupportedCommand:
            return "只支持官方 dsh plugin --profile web add 命令。"
        case .missingPackageSpec:
            return "安装命令中没有插件 package spec。"
        case .optionNotAllowed(let option):
            return "不允许把 pnpm 选项传给插件安装器：\(option)"
        }
    }
}

/// Parses a pasted command into argv without invoking a shell. Only the
/// official web-profile install form is accepted; the caller still executes
/// the resulting argv through the bundled Runtime's process API.
struct PluginCommandParser {
    static func parseInstallCommand(_ input: String) throws -> [String] {
        let tokens = try tokenize(input)
        guard !tokens.isEmpty else { throw PluginCommandParserError.emptyCommand }

        // Accept either the official executable form or the App helper form.
        if let pluginIndex = tokens.firstIndex(where: { $0 == "plugin" }) {
            let prefix = Array(tokens[..<pluginIndex])
            guard isSupportedDSHInvocation(prefix) else {
                throw PluginCommandParserError.unsupportedCommand
            }
            guard pluginIndex + 1 < tokens.count else {
                throw PluginCommandParserError.unsupportedCommand
            }
            var cursor = pluginIndex + 1
            guard tokens[cursor] == "--profile" else {
                throw PluginCommandParserError.unsupportedCommand
            }
            cursor += 1
            guard cursor < tokens.count, tokens[cursor] == "web" else {
                throw PluginCommandParserError.unsupportedCommand
            }
            cursor += 1
            guard cursor < tokens.count, tokens[cursor] == "add" else {
                throw PluginCommandParserError.unsupportedCommand
            }
            cursor += 1
            return try packageArguments(from: Array(tokens[cursor...]))
        }

        if let executable = tokens.first,
           executable == "deepseek-harness-plugin" || executable.hasSuffix("/deepseek-harness-plugin") {
            guard tokens.count >= 2, tokens[1] == "add" else {
                throw PluginCommandParserError.unsupportedCommand
            }
            return try packageArguments(from: Array(tokens.dropFirst(2)))
        }

        throw PluginCommandParserError.unsupportedCommand
    }

    private static func isSupportedDSHInvocation(_ prefix: [String]) -> Bool {
        if prefix.count == 1 {
            return prefix[0] == "dsh" || prefix[0].hasSuffix("/dsh")
        }
        if prefix == ["npx", "@deepseek-ai/dsh"] {
            return true
        }
        if prefix == ["pnpm", "dlx", "@deepseek-ai/dsh"] {
            return true
        }
        return false
    }

    private static func packageArguments(from values: [String]) throws -> [String] {
        guard !values.isEmpty else { throw PluginCommandParserError.missingPackageSpec }
        for value in values where value.hasPrefix("-") {
            throw PluginCommandParserError.optionNotAllowed(value)
        }
        // pnpm resolves the shorthand `github:owner/repo` through Git SSH.
        // Finder-launched apps do not inherit a user's interactive SSH agent,
        // while public GitHub repositories are safely cloneable over HTTPS.
        // Normalize only the strict public shorthand shape; explicit git/SSH
        // specs and malformed values retain their original semantics.
        return ["add"] + values.map(normalizeGitHubShorthand)
    }

    private static func normalizeGitHubShorthand(_ value: String) -> String {
        let pattern = #"^github:([A-Za-z0-9][A-Za-z0-9._-]*)/([A-Za-z0-9][A-Za-z0-9._-]*)(#[^\s]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let ownerRange = Range(match.range(at: 1), in: value),
              let repositoryRange = Range(match.range(at: 2), in: value) else {
            return value
        }
        let owner = String(value[ownerRange])
        let repository = String(value[repositoryRange])
        let suffix = match.range(at: 3).location == NSNotFound
            ? ""
            : String(value[Range(match.range(at: 3), in: value)!])
        return "https://github.com/\(owner)/\(repository).git\(suffix)"
    }

    private static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if character == ";" || character == "|" || character == "&" || character == "<" || character == ">" {
                // These are shell operators, not valid package specs. Reject
                // them even though we never pass the text to a shell.
                throw PluginCommandParserError.unsupportedCommand
            } else {
                current.append(character)
            }
        }

        if escaping { current.append("\\") }
        if quote != nil { throw PluginCommandParserError.unterminatedQuote }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
