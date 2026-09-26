import Foundation

extension SpokenWordBookItem {
    /// The grouping's view of a library song. Every surface that groups
    /// books builds its items here, so the fields the rules read (path and
    /// source included) cannot drift apart between them.
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
            fileName: song.filePath,
            sourceID: song.sourceID,
            position: position,
            positionUpdatedAt: positionUpdatedAt,
            finishedAt: finishedAt
        )
    }
}
