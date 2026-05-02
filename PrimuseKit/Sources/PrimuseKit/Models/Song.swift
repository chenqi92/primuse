import Foundation
import GRDB

public struct Song: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of sourceID + relativePath
    public var title: String
    public var albumID: String?
    public var artistID: String?
    public var albumTitle: String?
    public var artistName: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var fileFormat: AudioFormat
    public var filePath: String // relative within source
    public var sourceID: String
    public var fileSize: Int64
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var genre: String?
    public var year: Int?
    public var lastModified: Date?
    public var dateAdded: Date
    public var coverArtFileName: String?
    public var lyricsFileName: String?
    /// Provider-supplied content identifier — etag, md5, content_hash,
    /// `fs_id` + `local_mtime`, etc. Used by re-scan to detect remote
    /// replacement on cloud drives that don't report a usable
    /// modifiedDate (Baidu, Aliyun, Dropbox, OneDrive). When non-nil on
    /// both sides and different, the file is treated as replaced even
    /// when path and size are identical.
    public var revision: String?

    public init(
        id: String,
        title: String,
        albumID: String? = nil,
        artistID: String? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        fileFormat: AudioFormat,
        filePath: String,
        sourceID: String,
        fileSize: Int64 = 0,
        bitRate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        genre: String? = nil,
        year: Int? = nil,
        lastModified: Date? = nil,
        dateAdded: Date = Date(),
        coverArtFileName: String? = nil,
        lyricsFileName: String? = nil,
        revision: String? = nil
    ) {
        self.id = id
        self.title = title
        self.albumID = albumID
        self.artistID = artistID
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.fileFormat = fileFormat
        self.filePath = filePath
        self.sourceID = sourceID
        self.fileSize = fileSize
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.genre = genre
        self.year = year
        self.lastModified = lastModified
        self.dateAdded = dateAdded
        self.coverArtFileName = coverArtFileName
        self.lyricsFileName = lyricsFileName
        self.revision = revision
    }
}

extension Song: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "songs" }
}

public extension Song {
    /// True when the song has enough metadata to drive normal playback UI
    /// (progress bar, seek). Cloud-source songs added by the Phase A scan
    /// stay non-playable until `MetadataBackfillService` fills duration.
    /// Distinct from `MetadataBackfillService.isBareSong`: backfill stops
    /// retrying once any field is filled, but the player needs `duration`
    /// specifically.
    var isPlayable: Bool { duration > 0 }
}

public extension Sequence where Element == Song {
    /// Drop songs that aren't ready for the player queue. Use at every
    /// `setQueue` call site so auto-advance never lands on a Phase A bare
    /// song without progress/seek.
    func filteredPlayable() -> [Song] { filter(\.isPlayable) }
}
