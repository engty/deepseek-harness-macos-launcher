import Foundation

/// A narrow, untrusted browser request. Never execute the page's shell text.
struct PluginStoreRequest: Equatable {
    let arguments: [String]
    let allowedBuildScripts: [String]

    var isRemoval: Bool { arguments.first == "remove" }

    init(arguments input: [String]) throws {
        guard input.count >= 5, input.count <= 32,
              Array(input.prefix(3)) == ["plugin", "--profile", "web"],
              ["add", "remove"].contains(input[3]),
              input.allSatisfy({
                  !$0.isEmpty && $0.count <= 1024 &&
                  $0.range(of: #"^[A-Za-z0-9@:/._#+=-]+$"#, options: .regularExpression) != nil
              }) else { throw PluginCommandParserError.unsupportedCommand }
        var specs: [String] = []
        var approvals: [String] = []
        for value in input.dropFirst(4) {
            if input[3] == "add", value.hasPrefix("--allow-build=") {
                let name = String(value.dropFirst("--allow-build=".count))
                guard Self.isPackageName(name) else {
                    throw PluginCommandParserError.optionNotAllowed(value)
                }
                approvals.append(name)
            } else {
                guard !value.hasPrefix("-"), input[3] != "remove" || Self.isPackageName(value) else {
                    throw PluginCommandParserError.optionNotAllowed(value)
                }
                // An upstream self-install would replace this reviewed adapter.
                guard value != "dsh1024", !value.hasPrefix("dsh1024@") else {
                    throw PluginCommandParserError.optionNotAllowed("1024 Store 由启动器维护")
                }
                specs.append(value)
            }
        }
        guard !specs.isEmpty else { throw PluginCommandParserError.missingPackageSpec }
        arguments = input[3] == "remove" ? ["remove"] + specs : try PluginCommandParser.parseInstallCommand(
            (["dsh", "plugin", "--profile", "web", "add"] + specs).joined(separator: " ")
        )
        allowedBuildScripts = Array(Set(approvals)).sorted()
    }

    private static func isPackageName(_ name: String) -> Bool {
        name != "." && name != ".." && name.range(
            of: #"^(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9][A-Za-z0-9._-]*$"#,
            options: .regularExpression
        ) != nil
    }
}
