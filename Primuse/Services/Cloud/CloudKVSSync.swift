import Foundation

/// Mirrors a curated set of UserDefaults entries into NSUbiquitousKeyValueStore so they
/// roam across the user's iCloud-signed-in devices.
///
/// Design:
/// - `register(key:reload:)` registers a key and a callback. On registration we pull
///   the latest value from KVS into UserDefaults if KVS is newer, then invoke `reload`.
/// - Each registered key gets a sibling `<key>__updatedAt` timestamp in both KVS and
///   UserDefaults; conflicts are resolved by last-write-wins on the timestamp.
/// - Stores call `markChanged(key:)` after they persist a new value to UserDefaults to
///   push it out. We bump the timestamp and copy the value into KVS.
/// - On `didChangeExternallyNotification` from KVS, we copy values back into
///   UserDefaults and invoke each registered reload callback.
///
/// Limits to keep in mind: 1MB total, 1024 keys, 1MB per value. Don't put large blobs
/// here — those go through CloudKit.
@MainActor
final class CloudKVSSync {
    static let shared = CloudKVSSync()

    /// Posted when a registered key was updated by another device. `userInfo["key"]`
    /// names the key that changed.
    static let externalChangeNotification = Notification.Name("primuse.cloudkvs.externalChange")

    private let kvs = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var registrations: [String: () -> Void] = [:]
    // Set on the main thread via the observer block; read only in deinit, where
    // strict concurrency rules don't allow touching MainActor state, so mark
    // this nonisolated(unsafe). NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?

    private init() {
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable bits before hopping to the actor — Notification itself isn't Sendable.
            let userInfo = note.userInfo as? [String: Any]
            let changedKeys = (userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            Task { @MainActor in
                self?.handleExternalChange(changedKeys: changedKeys)
            }
        }
        kvs.synchronize()
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Register a UserDefaults key for two-way mirroring with KVS.
    ///
    /// Call once per key during app startup. The `reload` closure is invoked on
    /// registration if the KVS copy was newer than local, and again whenever a remote
    /// device updates the key.
    func register(key: String, reload: @escaping () -> Void) {
        registrations[key] = reload
        pullIfNewer(key: key)
        reload()
    }


    /// Mirror a local change up to KVS. Call after writing the new value to
    /// UserDefaults — we read it back from defaults rather than taking it as a
    /// parameter so callers don't have to think about types.
    func markChanged(key: String) {
        guard CloudSyncChannel.isEnabled(.settings) else { return }
        let timestamp = Date().timeIntervalSince1970
        defaults.set(timestamp, forKey: timestampKey(for: key))

        // Copy whatever is at `key` in defaults up to KVS.
        if let data = defaults.data(forKey: key) {
            kvs.set(data, forKey: key)
        } else if let array = defaults.stringArray(forKey: key) {
            kvs.set(array, forKey: key)
        } else if let s = defaults.string(forKey: key) {
            kvs.set(s, forKey: key)
        } else if defaults.object(forKey: key) is Double || defaults.object(forKey: key) is Int {
            kvs.set(defaults.double(forKey: key), forKey: key)
        } else if defaults.object(forKey: key) is Bool {
            kvs.set(defaults.bool(forKey: key), forKey: key)
        } else {
            // Nothing to push — treat as deletion.
            kvs.removeObject(forKey: key)
        }

        kvs.set(timestamp, forKey: timestampKey(for: key))
        kvs.synchronize()
    }

    // MARK: - Internal

    private func timestampKey(for key: String) -> String { "\(key)__updatedAt" }

    private func pullIfNewer(key: String) {
        let remoteTimestamp = kvs.double(forKey: timestampKey(for: key))
        let localTimestamp = defaults.double(forKey: timestampKey(for: key))
        guard remoteTimestamp > 0, remoteTimestamp > localTimestamp else { return }
        applyRemoteValue(forKey: key, remoteTimestamp: remoteTimestamp)
    }

    private func applyRemoteValue(forKey key: String, remoteTimestamp: Double) {
        guard let value = kvs.object(forKey: key) else {
            defaults.removeObject(forKey: key)
            defaults.set(remoteTimestamp, forKey: timestampKey(for: key))
            return
        }
        if let data = value as? Data {
            defaults.set(data, forKey: key)
        } else if let arr = value as? [String] {
            defaults.set(arr, forKey: key)
        } else if let s = value as? String {
            defaults.set(s, forKey: key)
        } else if let n = value as? NSNumber {
            defaults.set(n, forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        defaults.set(remoteTimestamp, forKey: timestampKey(for: key))
    }

    private func handleExternalChange(changedKeys: [String]) {
        guard !changedKeys.isEmpty else { return }
        guard CloudSyncChannel.isEnabled(.settings) else { return }

        // KVS notifies on both the value key and the timestamp key. We only care
        // about the value keys we registered.
        var keysToReload = Set<String>()
        for key in changedKeys where registrations.keys.contains(key) {
            let remoteTimestamp = kvs.double(forKey: timestampKey(for: key))
            let localTimestamp = defaults.double(forKey: timestampKey(for: key))
            guard remoteTimestamp > localTimestamp else { continue }
            applyRemoteValue(forKey: key, remoteTimestamp: remoteTimestamp)
            keysToReload.insert(key)
        }

        for key in keysToReload {
            registrations[key]?()
            NotificationCenter.default.post(
                name: Self.externalChangeNotification,
                object: nil,
                userInfo: ["key": key]
            )
        }
    }
}

// MARK: - Well-known KVS keys

enum CloudKVSKey {
    static let playbackSettings = "primuse_playback_settings_v1"
    static let scraperSettings = "primuse_scraper_settings_v3"
    static let lyricsFontScale = "lyricsFontScale"
    static let recentSearches = "search_recent_queries"
    static let trustedDomains = "primuse.trustedDomains"
}

