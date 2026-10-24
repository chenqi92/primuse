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

/// Matches a synced identity to a song of this device's own files by the
/// path inside the source (#341).
///
/// A device-local source (files imported into Primuse, or a folder picked on
/// this device) gets a fresh UUID on every device, so the same file has a
/// different `Song.id` on each one and tier 1 never hits. The fuzzy tier
/// then needs both rows to have read their tags already: a freshly imported
/// file is titled after its file name with no duration until the tags are
/// read, and the sender's identity freezes whatever its row said at the
/// moment the song was added. The relative path is the same on both devices
/// from the first scan on.
///
/// Only a duration both sides know can veto a match; titles are compared only
/// to choose among several files at the same path.
public enum SongIdentityDeviceLocalPathMatch {
    public struct Candidate: Equatable, Sendable {
        public let songID: String
        public let title: String
        public let duration: Double

        public init(songID: String, title: String, duration: Double) {
            self.songID = songID
            self.title = title
            self.duration = duration
        }
    }

    /// Durations of one file measured on two devices (estimated before the
    /// tags were read, or by another decoder) stay within this.
    public static let durationTolerance: Double = 2

    /// Identities that can name a device-local file: no cloud account behind
    /// them and a path that points at a file.
    public static func isEligible(_ identity: SongIdentity) -> Bool {
        guard identity.cloudAccountID == nil else { return false }
        let name = (identity.filePath as NSString).lastPathComponent
        return !name.isEmpty && name != "/" && name.contains(".")
    }

    /// A file at the identity's path is the same song unless both sides know
    /// its duration and they disagree.
    public static func isCompatible(_ identity: SongIdentity, duration: Double) -> Bool {
        identity.duration <= 0 || duration <= 0
            || abs(identity.duration - duration) < durationTolerance
    }

    public static func match(_ identity: SongIdentity, among candidates: [Candidate]) -> String? {
        guard isEligible(identity) else { return nil }
        var firstCompatible: String?
        for candidate in candidates {
            guard isCompatible(identity, duration: candidate.duration) else { continue }
            if !identity.title.isEmpty, candidate.title == identity.title {
                return candidate.songID
            }
            if firstCompatible == nil { firstCompatible = candidate.songID }
        }
        return firstCompatible
    }
}
