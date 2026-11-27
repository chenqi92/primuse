import Foundation

/// Any playlist Primuse regenerates locally from an external library rather than
/// storing as user data — Apple Music mirrors and server-library mirrors.
///
/// These share three behaviours: the next sync overwrites their contents, the UI
/// must not offer destructive edits (a deleted mirror reappears), and they are
/// excluded from CloudKit — a device that cannot resolve the same external
/// library would receive an unresolvable, and therefore empty, playlist and push
/// that emptiness back to the device that could resolve it.
public enum MirrorPlaylistIdentity {
    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        AppleMusicLibraryIdentity.isMirrorPlaylist(playlistID)
            || ServerPlaylistIdentity.isMirrorPlaylist(playlistID)
    }
}
