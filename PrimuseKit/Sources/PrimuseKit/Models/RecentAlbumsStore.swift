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

    public static func load() -> [RecentAlbumEntry] {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([RecentAlbumEntry].self, from: data)) ?? []
    }

    public static func record(_ entry: RecentAlbumEntry) {
        var albums = load()
        // Remove existing entry with same id to avoid duplicates
        albums.removeAll { $0.id == entry.id }
        // Insert at front (most recent first)
        albums.insert(entry, at: 0)
        // Keep only maxCount entries
        if albums.count > maxCount {
            albums = Array(albums.prefix(maxCount))
        }
        save(albums)
    }

    private static func save(_ albums: [RecentAlbumEntry]) {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = try? JSONEncoder().encode(albums) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
