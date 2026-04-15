import Foundation

/// Persists user-friendly directory names for cloud-drive paths whose internal
/// identifiers are opaque IDs (for example OneDrive / Google Drive folder IDs).
enum CloudDirectoryNameStore {
    static let didChangeNotification = Notification.Name("CloudDirectoryNameStore.didChange")

    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    private static func storageKey(for sourceID: String) -> String {
        "cloud_directory_names_\(sourceID)"
    }

    static func save(_ items: [RemoteFileItem], for sourceID: String) {
        guard !items.isEmpty else { return }

        let previousMapping = loadMapping(for: sourceID)
        var mapping = previousMapping
        for item in items where item.isDirectory {
            mapping[item.path] = item.name
        }
        persist(mapping, for: sourceID)
        if mapping != previousMapping {
            notifyChange(for: sourceID)
        }
    }

    static func saveName(_ name: String, for path: String, sourceID: String) {
        var mapping = loadMapping(for: sourceID)
        let previousName = mapping[path]
        mapping[path] = name
        persist(mapping, for: sourceID)
        if previousName != name {
            notifyChange(for: sourceID)
        }
    }

    static func displayName(for path: String, sourceID: String) -> String? {
        loadMapping(for: sourceID)[path]
    }

    static func deleteAll(for sourceID: String) {
        defaults.removeObject(forKey: storageKey(for: sourceID))
        notifyChange(for: sourceID)
    }

    private static func loadMapping(for sourceID: String) -> [String: String] {
        defaults.dictionary(forKey: storageKey(for: sourceID)) as? [String: String] ?? [:]
    }

    private static func persist(_ mapping: [String: String], for sourceID: String) {
        defaults.set(mapping, forKey: storageKey(for: sourceID))
    }

    private static func notifyChange(for sourceID: String) {
        NotificationCenter.default.post(name: didChangeNotification, object: sourceID)
    }
}
