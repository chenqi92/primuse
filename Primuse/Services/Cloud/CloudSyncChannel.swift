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
    /// Covers: playback and intelligence settings, artist parsing rules,
    /// scraper sources, lyrics font, and recent searches.
    case settings
    /// iCloud Keychain `kSecAttrSynchronizable` flag for new writes.
    /// Past entries already on iCloud Keychain remain there — system-controlled.
    case credentials
    /// Full listening-stat events from `PlayHistoryStore`, used by Stats.
    case listeningStats

    var defaultsKey: String {
        "primuse.iCloudSync.channel.\(rawValue)"
    }

    /// The master switch's UserDefaults key. Every platform's settings UI binds
    /// to this one key, and `CloudKitSyncService` forces it off when the iCloud
    /// account signs out or switches.
    static let masterDefaultsKey = "primuse.iCloudSyncEnabled"

    /// The master switch alone. Transfers that belong to no single channel —
    /// the whole-library snapshot Apple TV pulls, for one — have to consult it
    /// directly, otherwise they keep running after the user turned sync off.
    static func isMasterEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: masterDefaultsKey) as? Bool) ?? true
    }

    /// True when both the master switch and this channel's switch are on.
    static func isEnabled(_ channel: CloudSyncChannel, defaults: UserDefaults = .standard) -> Bool {
        guard isMasterEnabled(defaults: defaults) else { return false }
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
