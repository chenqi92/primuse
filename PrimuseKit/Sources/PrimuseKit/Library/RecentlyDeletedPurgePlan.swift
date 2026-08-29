import Foundation

public struct RecentlyDeletedPurgePlan: Equatable, Sendable {
    public let playlistIDs: Set<String>
    public let smartPlaylistIDs: Set<String>
    public let sourceIDs: Set<String>
    public let scraperConfigurationIDs: Set<String>

    public init(
        playlistIDs: Set<String>,
        smartPlaylistIDs: Set<String>,
        sourceIDs: Set<String>,
        scraperConfigurationIDs: Set<String>
    ) {
        self.playlistIDs = playlistIDs
        self.smartPlaylistIDs = smartPlaylistIDs
        self.sourceIDs = sourceIDs
        self.scraperConfigurationIDs = scraperConfigurationIDs
    }

    public var count: Int {
        playlistIDs.count
            + smartPlaylistIDs.count
            + sourceIDs.count
            + scraperConfigurationIDs.count
    }

    public var isEmpty: Bool { count == 0 }

    /// Purging removes Primuse records and local credentials while preserving
    /// the same sync-tombstone semantics as individual purge. Mirror suppressions
    /// are intentionally absent, and no source-site media deletion or cloud-trash
    /// operation is represented by this plan.
    public var deletesRemoteMedia: Bool { false }
}
