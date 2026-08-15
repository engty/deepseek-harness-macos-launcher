import Foundation

enum PnpmWorkspaceConfigError: LocalizedError, Equatable {
    case invalidPackageName(String)
    case missingWorkspaceFile(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPackageName(let name):
            return "pnpm build 脚本依赖名称不安全：\(name)"
        case .missingWorkspaceFile(let url):
            return "找不到临时 profile 的 pnpm-workspace.yaml：\(url.path)"
        }
    }
}

enum PnpmWorkspaceConfig {
    static func approveBuildScripts(
        _ packageNames: [String],
        in profileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let validNames = try packageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { name -> String in
                guard isSafePackageName(name) else {
                    throw PnpmWorkspaceConfigError.invalidPackageName(name)
                }
                return name
            }
        let uniqueNames = Array(Set(validNames)).sorted()
        guard !uniqueNames.isEmpty else { return }

        let workspaceURL = profileURL.appendingPathComponent("pnpm-workspace.yaml")
        let existing: String
        if fileManager.fileExists(atPath: workspaceURL.path) {
            existing = try String(contentsOf: workspaceURL, encoding: .utf8)
        } else {
            // This is the same minimal profile configuration that Harness
            // creates on first use. It is written only into staging, so the
            // active profile is untouched until the complete transaction
            // passes preflight and is activated.
            existing = """
            packages:
              - .

            nodeLinker: hoisted
            autoInstallPeers: false
            """
        }
        let existingNames = Set(existing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line)
            guard text.first == " ", text.contains(":") else { return nil }
            let name = text.trimmingCharacters(in: .whitespaces)
                .split(separator: ":", maxSplits: 1)
                .first.map(String.init)
            guard let name, isSafePackageName(name) else { return nil }
            return name
        })
        let missingNames = uniqueNames.filter { !existingNames.contains($0) }
        guard !missingNames.isEmpty else { return }

        let entries = missingNames.map { "  \($0): true" }
        var lines = existing.components(separatedBy: "\n")
        if let allowBuildsIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "allowBuilds:"
        }) {
            var insertionIndex = allowBuildsIndex + 1
            while insertionIndex < lines.count {
                let line = lines[insertionIndex]
                guard line.isEmpty || line.first == " " || line.first == "\t" else { break }
                if line.isEmpty { break }
                insertionIndex += 1
            }
            lines.insert(contentsOf: entries, at: insertionIndex)
        } else {
            lines.append("")
            lines.append("allowBuilds:")
            lines.append(contentsOf: entries)
        }
        let updated = lines.joined(separator: "\n")
        try updated.write(to: workspaceURL, atomically: true, encoding: .utf8)
    }

    private static func isSafePackageName(_ name: String) -> Bool {
        let pattern = #"^(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
