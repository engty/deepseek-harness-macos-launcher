import Foundation

enum ProfileManagerError: LocalizedError {
    case profileUnavailable
    case pluginHasNoPatchRows(String)
    case invalidManifest
    case mutationFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileUnavailable:
            return "Harness 的 web profile 尚未初始化。"
        case .pluginHasNoPatchRows(let name):
            return "插件 \(name) 没有可识别的 bundle patch 行，无法由应用单独启停。"
        case .invalidManifest:
            return "Harness 的 profile package.json 无法解析。"
        case .mutationFailed(let message):
            return message
        }
    }
}

/// An App-owned patch overlay projected for a candidate profile. Keeping the
/// overlay separate from the profile slot lets a Runtime update preserve a
/// user's plugin disable choices even when a plugin changes its patch row ID.
struct PluginOverlayProjection: Equatable {
    let disabledRows: Set<String>
}

@MainActor
final class ProfileManager {
    let paths: AppPaths
    private let fileManager: FileManager
    private var disabledRows: Set<String> = []

    init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.disabledRows = Self.readDisabledRows(from: paths.overlay, fileManager: fileManager)
    }

    func refresh() -> [HarnessPlugin] {
        disabledRows = Self.readDisabledRows(from: paths.overlay, fileManager: fileManager)
        return plugins(in: paths.profileWeb, disabledRows: disabledRows)
    }

    func setEnabled(_ plugin: HarnessPlugin, enabled: Bool) throws {
        try setEnabled([plugin], enabled: enabled)
    }

    func setEnabled(_ plugins: [HarnessPlugin], enabled: Bool) throws {
        guard !plugins.isEmpty else { return }
        let selectedIDs = Set(plugins.map(\.id))
        let protectedRows: Set<String> = if enabled {
            Set(
                refresh()
                    .filter { $0.isDisabled && !selectedIDs.contains($0.id) }
                    .flatMap(\.bundleRowIDs)
            )
        } else {
            []
        }
        for plugin in plugins {
            guard !plugin.bundleRowIDs.isEmpty else {
                throw ProfileManagerError.pluginHasNoPatchRows(plugin.id)
            }
            if enabled {
                disabledRows.subtract(plugin.bundleRowIDs.filter { !protectedRows.contains($0) })
            } else {
                disabledRows.formUnion(plugin.bundleRowIDs)
            }
        }
        try writeOverlay()
    }

    func overlayURLIfNeeded() -> URL? {
        disabledRows.isEmpty ? nil : paths.overlay
    }

    /// Transfers the enabled/disabled state of updated plugins from the
    /// active profile to their candidate versions. Other plugin overlay rows
    /// remain unchanged. The result is written only after the caller's
    /// candidate passes its startup check.
    func projectOverlay(
        forCandidateProfile candidateProfile: URL,
        replacingPluginIDs: Set<String>
    ) -> PluginOverlayProjection {
        let activePlugins = refresh()
        let replacedPlugins = activePlugins.filter { replacingPluginIDs.contains($0.id) }
        let disabledPluginIDs = Set(
            replacedPlugins
                .filter(\.isDisabled)
                .map(\.id)
        )
        var projectedRows = disabledRows
        projectedRows.subtract(replacedPlugins.flatMap(\.bundleRowIDs))

        guard !disabledPluginIDs.isEmpty else {
            return PluginOverlayProjection(disabledRows: projectedRows)
        }

        let candidatePlugins = plugins(in: candidateProfile, disabledRows: [])
        for plugin in candidatePlugins where disabledPluginIDs.contains(plugin.id) {
            projectedRows.formUnion(plugin.bundleRowIDs)
        }
        return PluginOverlayProjection(disabledRows: projectedRows)
    }

    /// Writes an overlay for a candidate slot and returns its URL only when
    /// the candidate needs a patch argument at launch.
    @discardableResult
    func writeOverlay(
        _ projection: PluginOverlayProjection,
        to url: URL
    ) throws -> URL? {
        try writeOverlay(rows: projection.disabledRows, to: url)
        return projection.disabledRows.isEmpty ? nil : url
    }

    /// Makes a verified candidate overlay the live App-owned overlay.
    func applyOverlay(_ projection: PluginOverlayProjection) throws {
        try writeOverlay(rows: projection.disabledRows, to: paths.overlay)
        disabledRows = projection.disabledRows
    }

    /// Captures the exact prior overlay before a data-slot transaction. This
    /// is needed only if a later live restart fails after candidate activation.
    func overlaySnapshot() throws -> Data? {
        guard fileManager.fileExists(atPath: paths.overlay.path) else { return nil }
        return try Data(contentsOf: paths.overlay)
    }

    func restoreOverlay(_ data: Data?) throws {
        if let data {
            try fileManager.createDirectory(at: paths.state, withIntermediateDirectories: true)
            try data.write(to: paths.overlay, options: .atomic)
        } else if fileManager.fileExists(atPath: paths.overlay.path) {
            try fileManager.removeItem(at: paths.overlay)
        }
        disabledRows = Self.readDisabledRows(from: paths.overlay, fileManager: fileManager)
    }

    func packageDirectory(named packageName: String) -> URL {
        packageDirectory(named: packageName, in: paths.profileWeb)
    }

    private func plugins(
        in profileURL: URL,
        disabledRows: Set<String>
    ) -> [HarnessPlugin] {
        guard fileManager.fileExists(atPath: profileURL.appendingPathComponent("package.json").path) else {
            return []
        }
        guard let manifest = readJSON(at: profileURL.appendingPathComponent("package.json")) else {
            AppLogger.plugins.error("Could not parse web profile package.json")
            return []
        }

        let bundleNames = nestedStringArray(manifest, path: ["dsh", "profile", "bundles"])
        let dependencies = (manifest["dependencies"] as? [String: Any]) ?? [:]
        let pluginNames = bundleNames.filter { dependencies[$0] != nil }

        return pluginNames.compactMap { packageName in
            guard let packageManifest = packageManifest(named: packageName, in: profileURL) else { return nil }
            let packageURL = packageDirectory(named: packageName, in: profileURL)
            let rows: [String]
            if let patchPath = nestedString(packageManifest, path: ["dsh", "bundle", "patch"]) {
                let patchURL = packageURL.appendingPathComponent(patchPath).resolvingSymlinksInPath()
                rows = Self.patchRowIDs(at: patchURL, fileManager: fileManager)
            } else {
                // Not every valid Harness plugin contributes a Cordis bundle
                // patch. It still belongs in the installed-plugin list so the
                // user can remove it through the standard `dsh plugin remove`
                // command. Such a plugin cannot be disabled by this launcher.
                rows = []
            }
            let version = packageManifest["version"] as? String ?? "unknown"
            return HarnessPlugin(
                id: packageName,
                version: version,
                bundleRowIDs: rows,
                isDisabled: !rows.isEmpty && rows.allSatisfy(disabledRows.contains)
            )
        }
    }

    private func packageDirectory(named packageName: String, in profileURL: URL) -> URL {
        profileURL
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
            .resolvingSymlinksInPath()
    }

    func profileExists() -> Bool {
        fileManager.fileExists(atPath: paths.profileWeb.path)
    }

    private func writeOverlay() throws {
        try writeOverlay(rows: disabledRows, to: paths.overlay)
    }

    private func writeOverlay(rows: Set<String>, to url: URL) throws {
        if rows.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }

        var content = "# Generated by DeepSeek Harness. Do not edit.\n"
        for rowID in rows.sorted() {
            content += "- id: \(rowID)\n  disabled: true\n"
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func packageManifest(named packageName: String, in profileURL: URL) -> [String: Any]? {
        readJSON(at: packageDirectory(named: packageName, in: profileURL).appendingPathComponent("package.json"))
    }

    private func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func nestedString(_ object: [String: Any], path: [String]) -> String? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return nil }
            current = next
        }
        return current as? String
    }

    private func nestedStringArray(_ object: [String: Any], path: [String]) -> [String] {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return [] }
            current = next
        }
        return current as? [String] ?? []
    }

    private static func readDisabledRows(from url: URL, fileManager: FileManager) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var result: Set<String> = []
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- id:") else { continue }
            let id = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard index + 1 < lines.count,
                  lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("disabled: true") else { continue }
            result.insert(id.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
        }
        return result
    }

    private static func patchRowIDs(at url: URL, fileManager: FileManager) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let pattern = #"(?m)^\s*-\s+id:\s*['\"]?([A-Za-z0-9_.:-]+)['\"]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let idRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[idRange])
        }
    }
}
