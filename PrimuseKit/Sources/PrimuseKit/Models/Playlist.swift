import Foundation
import GRDB

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var coverArtPath: String?
    /// Soft-delete flag. When true, the playlist is hidden from the regular UI
    /// but kept on disk + in CloudKit so other devices can converge before the
    /// 30-day prune sweeps it for good.
    public var isDeleted: Bool
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        coverArtPath: String? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverArtPath = coverArtPath
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.coverArtPath = try c.decodeIfPresent(String.self, forKey: .coverArtPath)
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

extension Playlist: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "playlists" }
}

public struct PlaylistSong: Codable, Sendable {
    public var playlistID: String
    public var songID: String
    public var sortOrder: Int

    public init(playlistID: String, songID: String, sortOrder: Int) {
        self.playlistID = playlistID
        self.songID = songID
        self.sortOrder = sortOrder
    }
}

extension PlaylistSong: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "playlistSongs" }
}
