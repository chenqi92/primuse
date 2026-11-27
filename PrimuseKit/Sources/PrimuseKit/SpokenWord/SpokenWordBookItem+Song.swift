import Foundation

extension SpokenWordBookItem {
    /// The grouping's view of a library song. Every surface that groups
    /// books builds its items here, so the fields the rules read (path and
    /// source included) cannot drift apart between them. On an item-id cloud
    /// drive the path is spelled out of the scanned folders, since the song's
    /// own path is a file id.
    public init(
        song: Song,
        knownDuration: TimeInterval? = nil,
        position: TimeInterval? = nil,
        positionUpdatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.init(
            id: song.id,
            title: song.title,
            albumTitle: song.albumTitle,
            albumArtist: song.albumArtistName,
            artist: song.artistName,
            discNumber: song.discNumber,
            trackNumber: song.trackNumber,
            duration: song.duration > 0 ? song.duration : (knownDuration ?? 0),
            fileName: SpokenWordBookSourcePaths.groupingPath(sourceID: song.sourceID, filePath: song.filePath),
            sourceID: song.sourceID,
            position: position,
            positionUpdatedAt: positionUpdatedAt,
            finishedAt: finishedAt,
            addedAt: Self.addedDate(dateAdded: song.dateAdded, fileModified: song.lastModified)
        )
    }

    /// When a file came into the library: the earlier of its own modification
    /// time and when the library first saw it. A folder scanned in one go
    /// gets near-identical library dates, and only the files' own dates tell
    /// its episodes apart; a file whose tags were edited later gets a newer
    /// modification time, and taking the earlier date keeps it in its place.
    /// A modification time before 2000 is a server that did not report one.
    static func addedDate(dateAdded: Date, fileModified: Date?) -> Date {
        guard let fileModified, fileModified.timeIntervalSince1970 >= 946_684_800 else { return dateAdded }
        return min(dateAdded, fileModified)
    }
}
