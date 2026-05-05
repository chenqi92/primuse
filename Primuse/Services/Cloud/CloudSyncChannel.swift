import Foundation

/// One independently-toggleable sync surface. The master toggle
/// `primuse.iCloudSyncEnabled` gates everything; per-channel switches let users
/// opt out of individual data types without disabling the rest.
enum CloudSyncChannel: String, CaseIterable, Sendable {
    /// CloudKit `Playlist` records.
    case playlists
    /// CloudKit `MusicSource` records (passwords stay in `.credentials`).
    case sources
    /// CloudKit `PlaybackHistory` singleton (5-min throttled).
    case playbackHistory
    /// KVS-mirrored settings + custom scraper configs in CloudKit.
    /// Covers: playback settings, scraper sources, lyrics font, recent searches.
    case settings
    /// iCloud Keychain `kSecAttrSynchronizable` flag for new writes.
    /// Past entries already on iCloud Keychain remain there — system-controlled.
    case credentials

    var defaultsKey: String {
        "primuse.iCloudSync.channel.\(rawValue)"
    }

    /// True when both the master switch and this channel's switch are on.
    static func isEnabled(_ channel: CloudSyncChannel, defaults: UserDefaults = .standard) -> Bool {
        let master = (defaults.object(forKey: "primuse.iCloudSyncEnabled") as? Bool) ?? true
        guard master else { return false }
        return (defaults.object(forKey: channel.defaultsKey) as? Bool) ?? true
    }

    /// iOS simulators do not consistently receive iCloud Keychain entitlements
    /// when signed locally, and older runtimes can reject synchronizable writes.
    static func usesSynchronizableKeychain(defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(.credentials, defaults: defaults) else { return false }
#if targetEnvironment(simulator)
        return false
#else
        return true
#endif
    }
}
