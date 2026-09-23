import Foundation
import PrimuseKit

/// 键值存储的最小接口。`NSUbiquitousKeyValueStore` 原样满足; 测试用内存实现。
protocol CloudKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func double(forKey key: String) -> Double
    func string(forKey key: String) -> String?
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}

/// Mirrors a curated set of UserDefaults entries into NSUbiquitousKeyValueStore so they
/// roam across the user's iCloud-signed-in devices.
///
/// Design:
/// - `register(key:reload:)` registers a key and a callback. On registration the key is
///   reconciled with KVS (pull a newer cloud copy, or push an edit recorded while sync
///   was off), then `reload` runs.
/// - Each registered key gets sibling `<key>__updatedAt` / `<key>__writerID` entries in
///   both KVS and UserDefaults. `CloudKVSReconciliationPolicy` decides which side wins.
/// - Stores call `markChanged(key:)` after they persist a new value to UserDefaults to
///   push it out. While sync is off the edit is still recorded locally, so it can be
///   pushed later instead of being lost or overwriting a newer cloud copy.
/// - `catchUp()` reconciles every registered key: run it when sync is switched on and
///   when the engine starts. It never pushes a value this device has not edited, so a
///   fresh install cannot replace the user's settings with defaults.
/// - On `didChangeExternallyNotification` the change reason is honoured: the initial
///   download and an account change take the cloud copy outright.
///
/// Limits to keep in mind: 1MB total, 1024 keys, 1MB per value. Don't put large blobs
/// here — those go through CloudKit.
@MainActor
final class CloudKVSSync {
    typealias Policy = CloudKVSReconciliationPolicy

    static let shared: CloudKVSSync = {
        // Match the CloudKit boundary: linker-signed simulator and ad-hoc Mac
        // builds have no KVS store identifier, and touching `.default` there
        // is a system-level client error. Local UserDefaults still work.
        guard CloudKitRuntime.canCreateContainer else {
            return CloudKVSSync(store: nil, defaults: .standard, observing: nil)
        }
        let store = NSUbiquitousKeyValueStore.default
        return CloudKVSSync(store: store, defaults: .standard, observing: store)
    }()

    /// Posted when a registered key was updated by another device. `userInfo["key"]`
    /// names the key that changed.
    static let externalChangeNotification = Notification.Name("primuse.cloudkvs.externalChange")

    private let kvs: (any CloudKeyValueStore)?
    private let defaults: UserDefaults
    private var registrations: [String: () -> Void] = [:]
    // Set on the main thread via the observer block; read only in deinit, where
    // strict concurrency rules don't allow touching MainActor state, so mark
    // this nonisolated(unsafe). NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?

    init(store: (any CloudKeyValueStore)?, defaults: UserDefaults, observing: NSUbiquitousKeyValueStore?) {
        self.kvs = store
        self.defaults = defaults
        guard let observing else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: observing,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable bits before hopping to the actor — Notification itself isn't Sendable.
            let userInfo = note.userInfo as? [String: Any]
            let changedKeys = (userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            let reason = Policy.ExternalChangeReason(
                rawChangeReason: userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            )
            Task { @MainActor in
                self?.handleExternalChange(changedKeys: changedKeys, reason: reason)
            }
        }
        observing.synchronize()
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Register a UserDefaults key for two-way mirroring with KVS.
    ///
    /// Call once per key during app startup. The `reload` closure is invoked on
    /// registration, and again whenever a remote device updates the key.
    func register(key: String, reload: @escaping () -> Void) {
        registrations[key] = reload
        _ = reconcile(key: key)
        reload()
    }

    /// Mirror a local change up to KVS. Call after writing the new value to
    /// UserDefaults — we read it back from defaults rather than taking it as a
    /// parameter so callers don't have to think about types.
    ///
    /// 同步关着时只把修订号记在本机: 再打开时 `catchUp()` 才知道这个键在关着的
    /// 期间改过, 该推上去而不是被云端的旧值盖掉。
    func markChanged(key: String) {
        guard let kvs else { return }
        let enabled = isEnabled
        let local = localVersion(for: key)
        let remote = enabled ? remoteVersion(for: key) : .unset
        // 刚从云端拉下来的值又被本机的观察者原样写了一遍(比如 @AppStorage 的
        // onChange): 版本一致、值也一致, 不是一次编辑, 别再抬修订号推回去。
        if enabled, local.revision > 0, local == remote, valuesMatch(key: key, in: kvs) { return }
        let version = Policy.Version(
            revision: Policy.nextRevision(
                now: Date().timeIntervalSince1970,
                local: local.revision,
                remote: remote.revision
            ),
            writer: localWriterID
        )
        storeLocalVersion(version, for: key)
        guard enabled else { return }
        push(key: key, version: version, to: kvs)
    }

    /// Reconcile every registered key with the cloud copy. Run when the settings
    /// channel or the master switch is turned on, and when the sync engine starts.
    @discardableResult
    func catchUp() -> (pulled: Int, pushed: Int) {
        guard kvs != nil, isEnabled else { return (0, 0) }
        var pulled = 0
        var pushed = 0
        var reloaded: [String] = []
        for key in registrations.keys.sorted() {
            switch reconcile(key: key) {
            case .pull:
                pulled += 1
                reloaded.append(key)
            case .pushValue, .pushDeletion:
                pushed += 1
            case .keep:
                break
            }
        }
        for key in reloaded {
            registrations[key]?()
            postExternalChange(for: key)
        }
        if pulled > 0 || pushed > 0 {
            plog("☁️ CloudKVS catch-up pulled=\(pulled) pushed=\(pushed) keys=\(registrations.count)")
        }
        return (pulled, pushed)
    }

    // MARK: - Internal

    private var isEnabled: Bool {
        CloudSyncChannel.isEnabled(.settings, defaults: defaults)
    }

    private func timestampKey(for key: String) -> String { "\(key)__updatedAt" }
    private func writerKey(for key: String) -> String { "\(key)__writerID" }

    private var localWriterID: String {
        let key = "primuse_cloud_kvs_writer_id"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    private func remoteVersion(for key: String) -> Policy.Version {
        guard let kvs else { return .unset }
        return Policy.Version(
            revision: kvs.double(forKey: timestampKey(for: key)),
            writer: kvs.string(forKey: writerKey(for: key)) ?? ""
        )
    }

    private func localVersion(for key: String) -> Policy.Version {
        Policy.Version(
            revision: defaults.double(forKey: timestampKey(for: key)),
            writer: defaults.string(forKey: writerKey(for: key)) ?? ""
        )
    }

    private func storeLocalVersion(_ version: Policy.Version, for key: String) {
        defaults.set(version.revision, forKey: timestampKey(for: key))
        defaults.set(version.writer, forKey: writerKey(for: key))
    }

    private func clearLocalVersion(for key: String) {
        defaults.removeObject(forKey: timestampKey(for: key))
        defaults.removeObject(forKey: writerKey(for: key))
    }

    private func valuesMatch(key: String, in kvs: any CloudKeyValueStore) -> Bool {
        let local = defaults.object(forKey: key)
        let remote = kvs.object(forKey: key)
        switch (local, remote) {
        case (nil, nil): return true
        case let (l?, r?): return (l as? NSObject)?.isEqual(r) ?? false
        default: return false
        }
    }

    /// One key, one decision: pull a newer cloud copy, push a newer local edit, or
    /// leave both alone. Never touches the cloud for a key this device has not edited.
    private func reconcile(key: String) -> Policy.Action {
        guard let kvs, isEnabled else { return .keep }
        let local = localVersion(for: key)
        let remote = remoteVersion(for: key)
        let action = Policy.catchUpAction(
            local: local,
            hasLocalValue: defaults.object(forKey: key) != nil,
            remote: remote
        )
        switch action {
        case .pull:
            applyRemoteValue(forKey: key, remoteVersion: remote, from: kvs)
        case .pushValue, .pushDeletion:
            push(key: key, version: local, to: kvs)
        case .keep:
            break
        }
        return action
    }

    /// Copy whatever is at `key` in defaults up to KVS under `version`.
    private func push(key: String, version: Policy.Version, to kvs: any CloudKeyValueStore) {
        // Order matters: a Bool stored in UserDefaults round-trips as an NSNumber
        // whose Swift bridging satisfies both `is Bool` and `is Double` — Bool
        // detection via CFBoolean has to come first.
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
            // 本机删掉了这个键(比如清空最近搜索), 云端也删。
            kvs.removeObject(forKey: key)
        }
        kvs.set(version.revision, forKey: timestampKey(for: key))
        kvs.set(version.writer, forKey: writerKey(for: key))
        kvs.synchronize()
    }

    private func applyRemoteValue(
        forKey key: String,
        remoteVersion: Policy.Version,
        from kvs: any CloudKeyValueStore
    ) {
        guard let value = kvs.object(forKey: key) else {
            defaults.removeObject(forKey: key)
            storeLocalVersion(remoteVersion, for: key)
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
        storeLocalVersion(remoteVersion, for: key)
    }

    private func postExternalChange(for key: String) {
        NotificationCenter.default.post(
            name: Self.externalChangeNotification,
            object: nil,
            userInfo: ["key": key]
        )
    }

    /// KVS reported a change. Ordinary server changes go through the revision
    /// comparison; the initial download and an account switch take the cloud
    /// copy as-is, because the system has already replaced whatever this device
    /// wrote before them.
    func handleExternalChange(changedKeys: [String], reason: Policy.ExternalChangeReason) {
        guard let kvs else { return }
        if Policy.resetsLocalRevisions(reason) {
            // 旧账号留下的修订号对新账号的值没有意义, 哪怕同步此刻是关着的。
            for key in registrations.keys { clearLocalVersion(for: key) }
        }
        guard Policy.carriesRemoteValues(reason) else {
            plog("⚠️ CloudKVS quota violation: local write rejected for \(changedKeys.count) key(s)")
            return
        }
        guard isEnabled else { return }

        let unconditional = Policy.appliesRemoteUnconditionally(reason)
        // KVS can notify each sibling key separately. Normalize timestamp/writer
        // changes back to their registered value key so deletions are not lost.
        let candidates: Set<String> = unconditional
            ? Set(registrations.keys)
            : Set(changedKeys.compactMap { changed -> String? in
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

        var keysToReload: [String] = []
        for key in candidates.sorted() {
            let remote = remoteVersion(for: key)
            if unconditional {
                // 云端根本没有这个键的, 本机的照旧。
                guard remote.revision > 0 || kvs.object(forKey: key) != nil else { continue }
            } else {
                guard remote.revision > 0, Policy.isNewer(remote, than: localVersion(for: key)) else { continue }
            }
            applyRemoteValue(forKey: key, remoteVersion: remote, from: kvs)
            keysToReload.append(key)
        }

        for key in keysToReload {
            registrations[key]?()
            postExternalChange(for: key)
        }
        if unconditional {
            plog("☁️ CloudKVS applied \(keysToReload.count) key(s) after \(reason)")
        }
    }
}

// MARK: - Well-known KVS keys

enum CloudKVSKey {
    static let aiSettings = AISettingsStore.storageKey
    static let lyricsTranscriptionSettings = LyricsTranscriptionSettingsStore.storageKey
    static let artistNameConfiguration = ArtistNameConfiguration.storageKey
    static let playbackSettings = "primuse_playback_settings_v1"
    static let scraperSettings = "primuse_scraper_settings_v3"
    static let lyricsFontScale = "lyricsFontScale"
    static let recentSearches = "search_recent_queries"
    static let aiRecommendationIntents = AIRecommendationIntentStoragePolicy.storageKey
    static let aiRecommendationHiddenPresets =
        AIRecommendationIntentPresetVisibilityPolicy.storageKey
    static let aiRecommendationSelectedIntent = AIRecommendationIntentSelectionPolicy.storageKey
    /// 电台清单订阅的定义(不含刷新状态)。订阅每次变化时自己推送; 打开开关时的
    /// 补推按修订号比对, 一台没有订阅的设备不会再把别的设备的订阅清空。
    static let radioSubscriptions = "primuse_radio_subscriptions_v1"
    // Certificate trust and public cleartext-HTTP permissions are intentionally
    // NOT synced: both are per-device security decisions. SSLTrustStore keeps
    // them in local UserDefaults only.
}
