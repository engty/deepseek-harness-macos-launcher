import Foundation

/// Defines the small, explicit plugin set that must stay aligned with a
/// Harness Runtime upgrade. It intentionally updates only packages already
/// present in the profile, so a user's explicit removal remains respected.
enum RuntimeManagedPluginMaintenance {
    private static let managedPluginSpecs: [(id: String, latestSpec: String)] = [
        (id: "dsh-mnemon", latestSpec: "dsh-mnemon@latest"),
        (id: "@anionex/dsh-vision-toolkit", latestSpec: "@anionex/dsh-vision-toolkit@latest")
    ]

    static func managedPluginIDs(installedPluginIDs: Set<String>) -> [String] {
        managedPluginSpecs
            .map(\.id)
            .filter(installedPluginIDs.contains)
    }

    static func updateArguments(installedPluginIDs: Set<String>) -> [String] {
        let specs = managedPluginSpecs
            .filter { installedPluginIDs.contains($0.id) }
            .map(\.latestSpec)
        return specs.isEmpty ? [] : ["add"] + specs
    }

    static func installedPluginIDs(in profileURL: URL) -> Set<String> {
        let manifestURL = profileURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = manifest["dependencies"] as? [String: Any] else {
            return []
        }
        let bundles = nestedStringArray(
            manifest,
            path: ["dsh", "profile", "bundles"]
        )
        // A package dependency alone is not necessarily an active Harness
        // plugin. Restrict the maintenance task to packages both installed
        // and registered in the current web profile, preserving an explicit
        // user removal or deactivation from the profile.
        return Set(bundles.filter { dependencies[$0] != nil })
    }

    private static func nestedStringArray(
        _ object: [String: Any],
        path: [String]
    ) -> [String] {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return []
            }
            current = next
        }
        return current as? [String] ?? []
    }
}
