import Foundation
import GRDB

public struct Artist: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of normalized name
    public var name: String
    public var albumCount: Int
    public var songCount: Int
    public var thumbnailPath: String?

    public init(
        id: String,
        name: String,
        albumCount: Int = 0,
        songCount: Int = 0,
        thumbnailPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
        self.thumbnailPath = thumbnailPath
    }
}

extension Artist: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "artists" }
}
