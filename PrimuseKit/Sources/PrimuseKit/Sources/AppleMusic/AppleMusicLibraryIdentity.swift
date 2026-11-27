import Foundation

/// Stable identifiers shared by the app targets and the Apple Music adapter.
///
/// `MusicLibrary` is also compiled into the tvOS target, while the concrete
/// MusicKit-backed service is not. Keeping these values in PrimuseKit prevents
/// the shared library model from depending on a platform-specific service.
public enum AppleMusicLibraryIdentity {
    public static let sourceID = "primuse.appleMusic.system"
    public static let systemPlaylistID = "primuse.system.appleMusicLibrary"
    public static let userPlaylistIDPrefix = "primuse.system.appleMusic.playlist."
    public static let notInPlaylistCollectionID = "primuse.system.appleMusic.notInPlaylist"

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID == systemPlaylistID
            || playlistID.hasPrefix(userPlaylistIDPrefix)
    }
}

/// Preferences that affect the platform-neutral music-library projection.
///
/// The Apple Music settings UI and the shared library model must read the same
/// key. This lives outside the MusicKit implementation so macOS/iOS and tvOS
/// can all compile the shared model without target-membership assumptions.
public enum AppleMusicLibraryPreferences {
    public static let syncUserLibraryKey = "primuse.appleMusic.syncUserLibrary"

    public static var syncUserLibraryEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: syncUserLibraryKey) != nil else { return true }
        return defaults.bool(forKey: syncUserLibraryKey)
    }
}
