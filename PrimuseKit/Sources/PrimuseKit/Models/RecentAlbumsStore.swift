import Foundation

/// Stores recent album info in App Group UserDefaults for Widget access.
public struct RecentAlbumEntry: Codable, Sendable {
    public let id: String
    public let title: String
    public let artistName: String
    public let coverImageName: String?
    /// What a widget tap plays: the library album and the song last heard in
    /// it. Nil in entries written before taps existed.
    public let albumID: String?
    public let songID: String?
    /// Books and podcast shows are recorded too; the listening desk's music
    /// tile skips them. Nil when not known (older entries).
    public let listeningSpace: ListeningSpace?

    public init(id: String, title: String, artistName: String, coverImageName: String?,
                albumID: String? = nil, songID: String? = nil, listeningSpace: ListeningSpace? = nil) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.coverImageName = coverImageName
        self.albumID = albumID
        self.songID = songID
        self.listeningSpace = listeningSpace
    }

    /// The same entry with its cover withheld (privacy scope below covers).
    public func withoutCover() -> RecentAlbumEntry {
        RecentAlbumEntry(id: id, title: title, artistName: artistName, coverImageName: nil,
                         albumID: albumID, songID: songID, listeningSpace: listeningSpace)
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
