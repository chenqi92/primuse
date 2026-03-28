import Foundation
import GRDB

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of artistName + albumTitle
    public var title: String
    public var artistID: String?
    public var artistName: String?
    public var year: Int?
    public var genre: String?
    public var coverArtPath: String?
    public var songCount: Int
    public var totalDuration: TimeInterval
    public var sourceID: String?

    public init(
        id: String,
        title: String,
        artistID: String? = nil,
        artistName: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        coverArtPath: String? = nil,
        songCount: Int = 0,
        totalDuration: TimeInterval = 0,
        sourceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.coverArtPath = coverArtPath
        self.songCount = songCount
        self.totalDuration = totalDuration
        self.sourceID = sourceID
    }
}

extension Album: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "albums" }
}
