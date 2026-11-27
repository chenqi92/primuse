import Foundation

/// Stable key for a user-hidden authoritative mirror. The upstream source and
/// upstream playlist identity are stored separately so a newly-created remote
/// playlist remains visible even when it reuses the same display name.
public struct MirrorPlaylistSuppressionKey: Codable, Hashable, Sendable {
    public let sourceID: String
    public let remotePlaylistID: String

    public init(sourceID: String, remotePlaylistID: String) {
        self.sourceID = sourceID
        self.remotePlaylistID = remotePlaylistID
    }
}

public struct MirrorPlaylistSuppression: Codable, Hashable, Sendable, Identifiable {
    public let key: MirrorPlaylistSuppressionKey
    public var playlistID: String
    public var displayName: String
    public var hiddenAt: Date

    public var id: String { "\(key.sourceID)\u{1F}\(key.remotePlaylistID)" }

    public init(
        key: MirrorPlaylistSuppressionKey,
        playlistID: String,
        displayName: String,
        hiddenAt: Date = Date()
    ) {
        self.key = key
        self.playlistID = playlistID
        self.displayName = displayName
        self.hiddenAt = hiddenAt
    }
}

public enum MirrorPlaylistSuppressionPolicy {
    public static let appleMusicLibraryRemoteID = "library"

    public static func key(forPlaylistID playlistID: String) -> MirrorPlaylistSuppressionKey? {
        if playlistID == AppleMusicLibraryIdentity.systemPlaylistID {
            return MirrorPlaylistSuppressionKey(
                sourceID: AppleMusicLibraryIdentity.sourceID,
                remotePlaylistID: appleMusicLibraryRemoteID
            )
        }
        if playlistID.hasPrefix(AppleMusicLibraryIdentity.userPlaylistIDPrefix) {
            let remoteID = String(playlistID.dropFirst(AppleMusicLibraryIdentity.userPlaylistIDPrefix.count))
            guard !remoteID.isEmpty else { return nil }
            return MirrorPlaylistSuppressionKey(
                sourceID: AppleMusicLibraryIdentity.sourceID,
                remotePlaylistID: remoteID
            )
        }
        guard playlistID.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix) else { return nil }
        let remainder = playlistID.dropFirst(ServerPlaylistIdentity.playlistIDPrefix.count)
        guard let separator = remainder.firstIndex(of: ".") else { return nil }
        let sourceID = String(remainder[..<separator])
        let remoteID = String(remainder[remainder.index(after: separator)...])
        guard !sourceID.isEmpty, !remoteID.isEmpty else { return nil }
        return MirrorPlaylistSuppressionKey(sourceID: sourceID, remotePlaylistID: remoteID)
    }

    public static func isSuppressed(
        playlistID: String,
        suppressions: Set<MirrorPlaylistSuppressionKey>
    ) -> Bool {
        guard let key = key(forPlaylistID: playlistID) else { return false }
        return suppressions.contains(key)
    }
}
