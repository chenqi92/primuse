import Foundation

/// Which mirrored server playlists accept songs added from Primuse.
///
/// Only these implement an append call: the Subsonic family (`updatePlaylist`
/// with `songIdToAdd`), Emby/Jellyfin (`POST /Playlists/{id}/Items`), Plex
/// (`PUT /playlists/{id}/items`), Songloft (`POST /playlists/{id}/songs`),
/// Synology Audio Station (`updatesongs` at offset -1), fnMusic (`/playlist/add-track`) and
/// DaoLiYu (`POST /playlists/{id}/tracks/batch`).
/// The rest of a mirror stays read-only: removals and reorders
/// would be overwritten by the next sync. Song IDs are only meaningful on the
/// server they came from, so a song can go into a mirror of its own source only.
public enum ServerPlaylistWritebackPolicy {
    /// Airsonic/gonic mirror getStarred2 as a pseudo playlist; it is not a
    /// server playlist and cannot be appended to.
    public static let starredPseudoPlaylistID = "primuse.subsonic.starred-songs"

    public static func supports(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .subsonic, .navidrome, .airsonic, .gonic, .zspace, .emby, .jellyfin, .plex, .songloft, .synologyAudioStation, .fnMusic,
             .daoliyu:
            return true
        default:
            return false
        }
    }

    /// Sources that can also create an empty playlist: the Subsonic family
    /// (`createPlaylist`), Emby/Jellyfin (`POST /Playlists`) and Audio Station
    /// (`create`). Plex needs at least one item to create one, and Songloft,
    /// fnMusic and DaoLiYu have no confirmed create call; those only take songs
    /// into a playlist that already exists on the server.
    public static func supportsCreating(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .subsonic, .navidrome, .airsonic, .gonic, .zspace, .emby, .jellyfin, .synologyAudioStation:
            return true
        default:
            return false
        }
    }

    /// Server playlist ID behind a local mirror of `sourceID`, or nil when the
    /// mirror belongs to another source or is the starred pseudo playlist.
    public static func serverPlaylistID(
        fromMirrorPlaylistID playlistID: String,
        sourceID: String
    ) -> String? {
        let prefix = ServerPlaylistIdentity.playlistIDPrefix(sourceID: sourceID)
        guard playlistID.hasPrefix(prefix) else { return nil }
        let serverID = String(playlistID.dropFirst(prefix.count))
        guard !serverID.isEmpty, serverID != starredPseudoPlaylistID else { return nil }
        return serverID
    }

    public static func songID(
        fromConnectorPath filePath: String,
        sourceType: MusicSourceType
    ) -> String? {
        guard supports(sourceType) else { return nil }
        switch sourceType {
        case .emby, .jellyfin, .plex, .songloft, .fnMusic:
            // MediaServerSource's `/items/<id>.<ext>` paths, Songloft's and fnMusic's own track paths.
            return ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: filePath,
                sourceType: sourceType
            )
        case .synologyAudioStation:
            return SynologyAudioStationAPI.songID(fromTrackPath: filePath)
        case .daoliyu:
            return DaoLiYuAPIProtocol.trackID(from: filePath)
        default:
            // The Subsonic family shares SubsonicSource and its `/songs/<id>.<suffix>` paths.
            return ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: filePath,
                sourceType: .subsonic
            )
        }
    }
}
