import Foundation

/// Avoid resolving MusicKit entries when Primuse owns the queue or the native
/// order is unchanged. Resolving an entry can synchronously query MediaLibrary.
public struct AppleMusicQueueSnapshotCache {
    private var previousEntryIDs: [String]?

    public init() {}

    public mutating func snapshotIfChanged<Song>(
        primuseOwnsCanonicalQueue: Bool,
        entryIDs: () -> [String],
        project: () -> [Song]
    ) -> [Song]? {
        guard !primuseOwnsCanonicalQueue else {
            previousEntryIDs = nil
            return nil
        }
        let ids = entryIDs()
        guard ids != previousEntryIDs else { return nil }
        let songs = project()
        previousEntryIDs = ids
        return songs
    }
}
