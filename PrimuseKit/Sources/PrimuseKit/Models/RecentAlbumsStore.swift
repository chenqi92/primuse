import Foundation

/// Stores recent album info in App Group UserDefaults for Widget access.
public struct RecentAlbumEntry: Codable, Sendable {
    public let id: String
    public let title: String
    public let artistName: String
    public let coverImageName: String?

    public init(id: String, title: String, artistName: String, coverImageName: String?) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.coverImageName = coverImageName
    }
}

public enum RecentAlbumsStore {
    private static let key = "recentAlbums"
    private static let maxCount = 8
    // Only the app writes this snapshot; widgets read the complete Data value.
    // Serialize app writers without holding a file lock across iOS suspension.
    private static let lock = NSLock()

    public static func load() -> [RecentAlbumEntry] {
        load(from: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    }

    static func load(from defaults: UserDefaults?) -> [RecentAlbumEntry] {
        lock.withLock { loadUnlocked(from: defaults) }
    }

    private static func loadUnlocked(from defaults: UserDefaults?) -> [RecentAlbumEntry] {
        guard let data = defaults?.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([RecentAlbumEntry].self, from: data)) ?? []
    }

    public static func record(_ entry: RecentAlbumEntry) {
        record(entry, in: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    }

    static func record(_ entry: RecentAlbumEntry, in defaults: UserDefaults?) {
        lock.withLock {
            var albums = loadUnlocked(from: defaults)
            // Remove existing entry with same id to avoid duplicates
            albums.removeAll { $0.id == entry.id }
            // Insert at front (most recent first)
            albums.insert(entry, at: 0)
            // Keep only maxCount entries
            if albums.count > maxCount {
                albums = Array(albums.prefix(maxCount))
            }
            save(albums, in: defaults)
        }
    }

    private static func save(_ albums: [RecentAlbumEntry], in defaults: UserDefaults?) {
        guard let defaults,
              let data = try? JSONEncoder().encode(albums) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    public static func clear() {
        clear(in: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    }

    static func clear(in defaults: UserDefaults?) {
        lock.withLock {
            defaults?.removeObject(forKey: key)
        }
    }
}
