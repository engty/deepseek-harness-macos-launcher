import Foundation

/// Persists a single skipped Runtime update key. The key contains the update
/// channel and version, so any newer version is eligible for notification.
struct RuntimeUpdateSkipStore {
    private static let storageKey = "skipped-runtime-update-keys"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ updateKey: String) -> Bool {
        skippedKeys.contains(updateKey)
    }

    func skip(_ updateKey: String) {
        defaults.set(Array(skippedKeys.union([updateKey])).sorted(), forKey: Self.storageKey)
    }

    private var skippedKeys: Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }
}
