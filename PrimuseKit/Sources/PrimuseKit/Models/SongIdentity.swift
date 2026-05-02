import Foundation

/// Stable cross-device identity for a song. Used by CloudKit-synced
/// records (playlists, playback history) so a freshly-synced device can
/// match entries even when the local `Song.id` differs.
///
/// `Song.id = SHA256(sourceID + filePath)`, but `MusicSource.id` is a
/// per-device UUID — same track on two devices hashes to two different
/// song IDs, so a naive `songIDs: [String]` sync points at nothing on
/// the receiving device.
///
/// Match strategy on import (priority order):
/// 1. `songID` exact hit — same source mount on both devices, or local
///    `Song.id` happened to match (rare unless mounts are shared)
/// 2. `(cloudAccountID, filePath)` — different mounts of the same OAuth
///    cloud account; `CloudAccount.id` is `SHA256(provider + accountUID)`
///    and stable across devices
/// 3. `(title, artistName?, duration ±1s)` — last-resort fuzzy match for
///    local / NAS / FTP / SMB sources whose identity is host-bound
public struct SongIdentity: Codable, Hashable, Sendable {
    public let songID: String
    public let title: String
    public let artistName: String?
    public let duration: Double
    public let cloudAccountID: String?
    public let filePath: String

    public init(
        songID: String,
        title: String,
        artistName: String?,
        duration: Double,
        cloudAccountID: String?,
        filePath: String
    ) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.duration = duration
        self.cloudAccountID = cloudAccountID
        self.filePath = filePath
    }
}
