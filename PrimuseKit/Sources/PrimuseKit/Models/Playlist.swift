import Foundation
import GRDB

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var coverArtPath: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        coverArtPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverArtPath = coverArtPath
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
