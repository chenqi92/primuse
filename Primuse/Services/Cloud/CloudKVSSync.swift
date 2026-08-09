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

    private var kvs: NSUbiquitousKeyValueStore?
    private let defaults = UserDefaults.standard
    private var registrations: [String: () -> Void] = [:]
    // Set on the main thread via the observer block; read only in deinit, where
    // strict concurrency rules don't allow touching MainActor state, so mark
    // this nonisolated(unsafe). NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?

    private init() {
        // Match the CloudKit boundary: linker-signed simulator and ad-hoc Mac
        // builds have no KVS store identifier, and touching `.default` there
        // is a system-level client error. Local UserDefaults still work.
        guard CloudKitRuntime.canCreateContainer else { return }
        let kvs = NSUbiquitousKeyValueStore.default
        self.kvs = kvs
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
        if kvs != nil {
            pullIfNewer(key: key)
        }
        reload()
    }


    /// Mirror a local change up to KVS. Call after writing the new value to
    /// UserDefaults — we read it back from defaults rather than taking it as a
    /// parameter so callers don't have to think about types.
    func markChanged(key: String) {
        guard CloudSyncChannel.isEnabled(.settings), let kvs else { return }
        // Keep the existing timestamp field for on-disk compatibility, but use
        // it as a Lamport-style revision. A device whose wall clock is ahead can
        // no longer permanently dominate other devices: every edit advances
        // beyond both the local and currently visible remote revision.
        let timestamp = max(
            Date().timeIntervalSince1970,
            max(
                defaults.double(forKey: timestampKey(for: key)),
                kvs.double(forKey: timestampKey(for: key))
            )
        ) + 1
        let writer = localWriterID
        defaults.set(timestamp, forKey: timestampKey(for: key))
        defaults.set(writer, forKey: writerKey(for: key))

        // Copy whatever is at `key` in defaults up to KVS. Order matters: a
        // Bool stored in UserDefaults round-trips as an NSNumber whose Swift
        // bridging satisfies both `is Bool` and `is Double` — Bool detection
        // via CFBoolean has to come first.
        if let data = defaults.data(forKey: key) {
            kvs.set(data, forKey: key)
        } else if let array = defaults.stringArray(forKey: key) {
            kvs.set(array, forKey: key)
        } else if let raw = defaults.object(forKey: key) {
            // 类型判定必须在 string(forKey:) 之前: 后者会把 NSNumber(Double/Int)
            // 也字符串化(如 "1.2")提前吞掉, 数值就被当成 String 推到 KVS。
            // Bool 经 CFBoolean 先于 NSNumber 判定。
            if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() {
                kvs.set(defaults.bool(forKey: key), forKey: key)
            } else if raw is NSNumber {
                kvs.set(defaults.double(forKey: key), forKey: key)
            } else if let s = raw as? String {
                kvs.set(s, forKey: key)
            } else {
                kvs.set(raw, forKey: key)
            }
        } else {
            // Nothing to push — treat as deletion.
            kvs.removeObject(forKey: key)
        }

        kvs.set(timestamp, forKey: timestampKey(for: key))
        kvs.set(writer, forKey: writerKey(for: key))
        kvs.synchronize()
    }

    // MARK: - Internal

    private func timestampKey(for key: String) -> String { "\(key)__updatedAt" }
    private func writerKey(for key: String) -> String { "\(key)__writerID" }

    private var localWriterID: String {
        let key = "primuse_cloud_kvs_writer_id"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    private func remoteVersion(for key: String) -> (revision: Double, writer: String) {
        guard let kvs else { return (0, "") }
        return (kvs.double(forKey: timestampKey(for: key)), kvs.string(forKey: writerKey(for: key)) ?? "")
    }

    private func localVersion(for key: String) -> (revision: Double, writer: String) {
        (defaults.double(forKey: timestampKey(for: key)), defaults.string(forKey: writerKey(for: key)) ?? "")
    }

    private func isNewer(
        _ candidate: (revision: Double, writer: String),
        than current: (revision: Double, writer: String)
    ) -> Bool {
        candidate.revision > current.revision
            || (candidate.revision == current.revision && candidate.writer > current.writer)
    }

    private func pullIfNewer(key: String) {
        let remote = remoteVersion(for: key)
        guard remote.revision > 0, isNewer(remote, than: localVersion(for: key)) else { return }
        applyRemoteValue(forKey: key, remoteVersion: remote)
    }

    private func applyRemoteValue(
        forKey key: String,
        remoteVersion: (revision: Double, writer: String)
    ) {
        guard let kvs else { return }
        guard let value = kvs.object(forKey: key) else {
            defaults.removeObject(forKey: key)
            defaults.set(remoteVersion.revision, forKey: timestampKey(for: key))
            defaults.set(remoteVersion.writer, forKey: writerKey(for: key))
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
        defaults.set(remoteVersion.revision, forKey: timestampKey(for: key))
        defaults.set(remoteVersion.writer, forKey: writerKey(for: key))
    }

    private func handleExternalChange(changedKeys: [String]) {
        guard !changedKeys.isEmpty else { return }
        guard CloudSyncChannel.isEnabled(.settings) else { return }

        // KVS can notify each sibling key separately. Normalize timestamp/writer
        // changes back to their registered value key so deletions are not lost.
        var keysToReload = Set<String>()
        let relevantKeys = Set(changedKeys.compactMap { changed -> String? in
            if registrations[changed] != nil { return changed }
            if changed.hasSuffix("__updatedAt") {
                let base = String(changed.dropLast("__updatedAt".count))
                return registrations[base] == nil ? nil : base
            }
            if changed.hasSuffix("__writerID") {
                let base = String(changed.dropLast("__writerID".count))
                return registrations[base] == nil ? nil : base
            }
            return nil
        })
        for key in relevantKeys {
            let remote = remoteVersion(for: key)
            guard remote.revision > 0, isNewer(remote, than: localVersion(for: key)) else { continue }
            applyRemoteValue(forKey: key, remoteVersion: remote)
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
    // Certificate trust and public cleartext-HTTP permissions are intentionally
    // NOT synced: both are per-device security decisions. SSLTrustStore keeps
    // them in local UserDefaults only.
}
