import Foundation

public enum PrimuseConstants {
    public static let appGroupIdentifier = "group.com.welape.yuanyin"
    public static let playbackStateKey = "playbackState"
    public static let keychainServiceName = "com.welape.primuse.credentials"

    // Widget shared snapshots (App Group). Written by the main app, read by
    // the WidgetKit extension. Keys also double as the @AppStorage keys the
    // settings UI binds to (sync toggle / refresh mode) so both sides agree.
    public static let lyricsSnapshotKey = "widget.lyricsSnapshot"
    public static let listeningStatsKey = "widget.listeningStats"
    public static let sourcesSnapshotKey = "widget.sourcesSnapshot"
    public static let wrappedSnapshotKey = "widget.wrappedSnapshot"
    public static let widgetSyncEnabledKey = "widget.syncEnabled"
    public static let widgetRefreshModeKey = "widget.refreshMode"
    public static let widgetSharedDataScopeKey = "widget.sharedDataScope"
    public static let widgetClickableInteractionKey = "widget.clickableInteraction"
    public static let widgetNowPlayingEnabledKey = "widget.enabled.nowPlaying"
    public static let widgetLyricsEnabledKey = "widget.enabled.lyrics"
    public static let widgetListeningStatsEnabledKey = "widget.enabled.listeningStats"
    public static let widgetRecentAlbumsEnabledKey = "widget.enabled.recentAlbums"
    public static let widgetSourcesEnabledKey = "widget.enabled.sources"
    public static let widgetWrappedEnabledKey = "widget.enabled.wrapped"

    public static let eqBandFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    public static let eqBandCount = 10
    public static let eqMinGain: Float = -12.0
    public static let eqMaxGain: Float = 12.0
    public static let eqDefaultBandwidth: Float = 1.0

    public static let defaultCacheSizeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    public static let smallFileThreshold: Int64 = 50 * 1024 * 1024 // 50 MB

    public static let supportedCoverExtensions = ["jpg", "jpeg", "png", "webp"]
    public static let supportedLyricsExtensions = ["lrc"]
    public static let supportedMusicVideoExtensions = ["mp4", "m4v", "mov"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    /// Note: `.mp4` is intentionally excluded — it's primarily a video
    /// container, and the SFB AAC-in-MP4 decoder is unreliable for the
    /// kind of mp4 a user typically drops in their music folder (often
    /// extracted-from-video files with non-standard atom layout). Audio
    /// MP4 files should use `.m4a`. Including `.mp4` here led to mid-stream
    /// PCM decode errors that auto-skipped 25%+ of cloud-drive scans.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "alac",
        "ape", "dsf", "dff", "ogg", "opus", "wma", "wv"
    ]
}

/// Stable identifiers shared by the app targets and the Apple Music adapter.
///
/// `MusicLibrary` is also compiled into the tvOS target, while the concrete
/// MusicKit-backed service is not. Keeping these values in PrimuseKit prevents
/// the shared library model from depending on a platform-specific service.
public enum AppleMusicLibraryIdentity {
    public static let sourceID = "primuse.appleMusic.system"
    public static let systemPlaylistID = "primuse.system.appleMusicLibrary"
    public static let userPlaylistIDPrefix = "primuse.system.appleMusic.playlist."

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

/// Validates the non-query portion of an OAuth callback URL.
///
/// Providers that redirect straight back to the app must return the registered
/// custom URL exactly (scheme/host are case-insensitive; path is not). Providers
/// that use an HTTPS relay can only be checked against the custom scheme because
/// their registered HTTPS URL differs from the deep link emitted by the relay.
public enum OAuthCallbackURLMatcher {
    public static func matches(
        _ callbackURL: URL,
        registeredRedirectURI: String,
        callbackScheme: String
    ) -> Bool {
        guard
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let actualScheme = callback.scheme?.lowercased(),
            actualScheme == callbackScheme.lowercased(),
            let registered = URLComponents(string: registeredRedirectURI),
            let registeredScheme = registered.scheme?.lowercased(),
            callback.user == nil,
            callback.password == nil,
            registered.user == nil,
            registered.password == nil
        else {
            return false
        }

        // An HTTPS relay ultimately emits a different custom URL. Preserve the
        // existing scheme-only behavior for that flow.
        guard registeredScheme == callbackScheme.lowercased() else {
            return true
        }

        return registeredScheme == actualScheme
            && registered.host?.lowercased() == callback.host?.lowercased()
            && registered.port == callback.port
            && registered.percentEncodedPath == callback.percentEncodedPath
    }
}
