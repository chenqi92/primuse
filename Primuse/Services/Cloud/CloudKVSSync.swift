import Foundation
import PrimuseKit

/// 键值存储的最小接口。`NSUbiquitousKeyValueStore` 原样满足; 测试用内存实现。
protocol CloudKeyValueStore: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func double(forKey key: String) -> Double
    func string(forKey key: String) -> String?
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}

private final class CloudKeyValueMemoryStore: CloudKeyValueStore {
    var dictionaryRepresentation: [String: Any] = [:]
    func object(forKey key: String) -> Any? { dictionaryRepresentation[key] }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func removeObject(forKey key: String) { dictionaryRepresentation.removeValue(forKey: key) }
    func double(forKey key: String) -> Double { (dictionaryRepresentation[key] as? NSNumber)?.doubleValue ?? 0 }
    func string(forKey key: String) -> String? { dictionaryRepresentation[key] as? String }
    @discardableResult func synchronize() -> Bool { true }
}

/// 通知可能早于 actor 处理到达，先使旧账号／初次下载前排队的写入失效。
private final class CloudKVSAccountEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func current() -> Int { lock.withLock { value } }
    func advance() -> Int { lock.withLock { value += 1; return value } }
}

/// 启动时复制初始镜像后，系统 KVS 的后续访问集中在这个 actor。
/// 不跨隔离域传递 non-Sendable 系统对象，只传属性列表 Data。
private actor CloudKeyValueStoreIO {
    typealias Policy = CloudKVSReconciliationPolicy
    struct Snapshot: Sendable {
        let data: Data
        let epoch: Int
    }

    private let makeStore: @Sendable () -> any CloudKeyValueStore
    private let notify: @Sendable (Snapshot, [String], Policy.ExternalChangeReason) async -> Void
    private var store: (any CloudKeyValueStore)?
    private let epoch = CloudKVSAccountEpoch()
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?

    init(
        makeStore: @escaping @Sendable () -> any CloudKeyValueStore,
        notify: @escaping @Sendable (Snapshot, [String], Policy.ExternalChangeReason) async -> Void
    ) {
        self.makeStore = makeStore
        self.notify = notify
    }

    deinit {
        if let observerToken { NotificationCenter.default.removeObserver(observerToken) }
    }

    private func storage() -> any CloudKeyValueStore {
        if let store { return store }
        let store = makeStore()
        self.store = store
        return store
    }

    func start() throws -> Snapshot {
        let store = storage()
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: nil
        ) { [weak self, epoch] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let reason = Policy.ExternalChangeReason(
                rawChangeReason: note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            )
            if Policy.appliesRemoteUnconditionally(reason) { _ = epoch.advance() }
            Task { await self?.didChange(keys: keys, reason: reason) }
        }
        store.synchronize()
        return try snapshot()
    }

    func snapshot() throws -> Snapshot {
        let snapshotEpoch = epoch.current()
        return Snapshot(
            data: try PropertyListSerialization.data(
                fromPropertyList: storage().dictionaryRepresentation, format: .binary, options: 0
            ),
            epoch: snapshotEpoch
        )
    }

    private func didChange(keys: [String], reason: Policy.ExternalChangeReason) async {
        guard let snapshot = try? snapshot() else { return }
        await notify(snapshot, keys, reason)
    }

    func write(key: String, data: Data?, version: Policy.Version, expectedEpoch: Int) throws -> Snapshot {
        guard expectedEpoch == epoch.current() else { return try snapshot() }
        let store = storage()
        let remote = Policy.Version(
            revision: store.double(forKey: key + "__updatedAt"),
            writer: store.string(forKey: key + "__writerID") ?? ""
        )
        // 排队期间另一个设备可能已经写了更新值，不能用旧快照把它覆盖。
        guard !Policy.isNewer(remote, than: version) else { return try snapshot() }
        let value: Any?
        if let data {
            let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any]
            value = values?.first
        } else {
            value = nil
        }
        if remote == version {
            let existing = store.object(forKey: key)
            if existing == nil && value == nil { return try snapshot() }
            if let existing = existing as? NSObject, let value, existing.isEqual(value) { return try snapshot() }
        }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        guard expectedEpoch == epoch.current() else { return try snapshot() }
        store.set(version.revision, forKey: key + "__updatedAt")
        guard expectedEpoch == epoch.current() else { return try snapshot() }
        store.set(version.writer, forKey: key + "__writerID")
        return try snapshot()
    }
}

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
        // 仅启动时取一次现有缓存，让登记及一次性迁移仍先看到云端已有值。
        // 原对象不传给 actor；后续所有系统读写由 actor 独占。
        let cachedValues = NSUbiquitousKeyValueStore.default.dictionaryRepresentation
        return CloudKVSSync(defaults: .standard, initialValues: cachedValues,
                            systemStoreFactory: { NSUbiquitousKeyValueStore.default })
    }()

    /// Posted when a registered key was updated by another device. `userInfo["key"]`
    /// names the key that changed.
    static let externalChangeNotification = Notification.Name("primuse.cloudkvs.externalChange")

    private let kvs: (any CloudKeyValueStore)?
    private let defaults: UserDefaults
    private var registrations: [String: () -> Void] = [:]
    private var systemIO: CloudKeyValueStoreIO?
    private var initialReadTask: Task<Void, Never>?
    private var pendingWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var systemEpoch = 0
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

    init(
        defaults: UserDefaults, initialValues: [String: Any] = [:],
        systemStoreFactory: @escaping @Sendable () -> any CloudKeyValueStore
    ) {
        let mirror = CloudKeyValueMemoryStore()
        mirror.dictionaryRepresentation = initialValues
        self.kvs = mirror
        self.defaults = defaults
        let io = CloudKeyValueStoreIO(makeStore: systemStoreFactory) { [weak self] snapshot, keys, reason in
            await self?.receiveSystemSnapshot(snapshot, changedKeys: keys, reason: reason)
        }
        systemIO = io
        initialReadTask = Task { [weak self] in
            do {
                let snapshot = try await io.start()
                self?.receiveSystemSnapshot(snapshot, changedKeys: [], reason: nil)
            } catch {
                plog("⚠️ CloudKVS initial read failed: \(error.localizedDescription)")
            }
        }
    }

    /// 等待已排队的本机写入完成；网络传播仍由系统管理。
    func synchronizePendingChanges() async {
        await initialReadTask?.value
        while !pendingWriteTasks.isEmpty {
            let tasks = Array(pendingWriteTasks.values)
            for task in tasks { await task.value }
        }
    }

    private func receiveSystemSnapshot(
        _ snapshot: CloudKeyValueStoreIO.Snapshot,
        changedKeys: [String], reason: Policy.ExternalChangeReason?
    ) {
        guard snapshot.epoch >= systemEpoch, let mirror = kvs as? CloudKeyValueMemoryStore else { return }
        systemEpoch = snapshot.epoch
        if reason.map(Policy.carriesRemoteValues) ?? true,
           let values = try? PropertyListSerialization.propertyList(from: snapshot.data, options: [], format: nil) as? [String: Any] {
            mirror.dictionaryRepresentation = values
        }
        if let reason {
            handleExternalChange(changedKeys: changedKeys, reason: reason)
        } else {
            _ = catchUp()
        }
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
        // 这台设备上的一次编辑: 之前扫码直传写进来的那一笔从此不再特殊, 照常推送。
        defaults.removeObject(forKey: transferredRevisionKey(for: key))
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

    /// 局域网扫码直传来的设置值(`LANSettingsTransferPolicy` 放行的键)。写进本机后,
    /// 按一次外部变更通知这个键的登记方重新载入。
    ///
    /// Apple TV 登录的常常是另一个 Apple ID, 所以这一笔不当成这台设备上的编辑:
    /// - 这台设备的 iCloud 里已经是同一份值(同一个账号), 直接认云端的修订号, 两边一致;
    /// - 否则按本机编辑记修订号 —— 比这台设备上现有的云端旧值新, 不会被它盖回去; 之后
    ///   别的设备真正改了又比它新, 照常拉下来 —— 同时记下这是直传来的修订号, 补推时不推
    ///   (`CloudKVSReconciliationPolicy.catchUpAction(...transferredRevision:)`), 免得
    ///   手机主人的设置灌进另一个账号的其他设备。在这台设备上再改一次就是普通编辑。
    func applyTransferred(key: String, value: Any) {
        defaults.set(value, forKey: key)
        let remote = remoteVersion(for: key)
        if let kvs, remote.revision > 0, valuesMatch(key: key, in: kvs) {
            storeLocalVersion(remote, for: key)
            defaults.removeObject(forKey: transferredRevisionKey(for: key))
        } else {
            let version = Policy.Version(
                revision: Policy.nextRevision(
                    now: Date().timeIntervalSince1970,
                    local: localVersion(for: key).revision,
                    remote: remote.revision
                ),
                writer: localWriterID
            )
            storeLocalVersion(version, for: key)
            defaults.set(version.revision, forKey: transferredRevisionKey(for: key))
        }
        registrations[key]?()
        postExternalChange(for: key)
    }

    // MARK: - Internal

    private var isEnabled: Bool {
        CloudSyncChannel.isEnabled(.settings, defaults: defaults)
    }

    private func timestampKey(for key: String) -> String { "\(key)__updatedAt" }
    private func writerKey(for key: String) -> String { "\(key)__writerID" }
    /// 只在本机 UserDefaults 里: 扫码直传写进来的那一笔修订号。
    private func transferredRevisionKey(for key: String) -> String { "\(key)__transferredRevision" }

    private func transferredRevision(for key: String) -> Double? {
        defaults.object(forKey: transferredRevisionKey(for: key)) as? Double
    }

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
        defaults.removeObject(forKey: transferredRevisionKey(for: key))
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
            remote: remote,
            transferredRevision: transferredRevision(for: key)
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
        guard let io = systemIO else { return }
        let valueData: Data?
        if let value = kvs.object(forKey: key) {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0) else { return }
            valueData = data
        } else {
            valueData = nil
        }
        let expectedEpoch = systemEpoch
        let taskID = UUID()
        pendingWriteTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWriteTasks.removeValue(forKey: taskID) }
            await self.initialReadTask?.value
            do {
                let snapshot: CloudKeyValueStoreIO.Snapshot
                if self.isEnabled, expectedEpoch == self.systemEpoch, self.localVersion(for: key) == version {
                    snapshot = try await io.write(key: key, data: valueData, version: version, expectedEpoch: expectedEpoch)
                } else {
                    snapshot = try await io.snapshot()
                }
                self.receiveSystemSnapshot(snapshot, changedKeys: [key], reason: .serverChange)
            } catch {
                plog("⚠️ CloudKVS queued write failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyRemoteValue(
        forKey key: String,
        remoteVersion: Policy.Version,
        from kvs: any CloudKeyValueStore
    ) {
        // 云端值盖过来了, 直传的那一笔已经不在本机。
        defaults.removeObject(forKey: transferredRevisionKey(for: key))
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

#if os(iOS) || os(macOS)
// MARK: - Home and library layout

/// 首页与资料库的界面布局跟着 iCloud 走: 区块顺序、显示哪些、每块的样式与条数;
/// 音乐播放页上几个位置放哪些按钮也在这里。
///
/// 这些设置散在各个界面里用 `@AppStorage` 直接读写, 没有哪个 store 管着它们, 所以这里统一
/// 登记、盯着 UserDefaults 的变化, 清单里的值真的变了才 `markChanged`。从云端拉下来的值先
/// 记作已知, 不会被当成本机编辑推回去。
///
/// 只收用户在编辑页、首页编辑状态里改的键。会被程序自己改写的不收: 首页挑选的书和电台
/// (管理页按本机有的清一遍)、收藏顺序(新喜欢到达时自动改写)、艺人页只看专辑艺术家
/// (Mac 跳转时自动切换) —— 收了它们, 一台还没装齐内容的设备就会把别的设备的设置改掉。
@MainActor
final class InterfaceLayoutSync {
    static let shared = InterfaceLayoutSync()

    static let keys: [String] = [
        // iPhone / iPad 首页
        HomeSectionConfiguration.orderKey,
        HomeSectionLayoutConfiguration.storageKey,
        "primuse.home.showHero",
        "primuse.home.showContinueSpaces",
        AlbumRecommendationService.homeVisibilityKey,
        ListeningIntentService.homeVisibilityKey,
        "primuse.home.showContinueListening",
        "primuse.home.showRadio",
        "primuse.home.showBooksInProgress",
        "primuse.home.showAudiobooks",
        "primuse.home.showPodcasts",
        "primuse.home.showQuickAccess",
        "primuse.home.showFolders",
        HomeFolderPinStorage.displayCountKey,
        "primuse.home.showListeningRanking",
        "primuse.home.showForYou",
        "primuse.home.showPlaylists",
        "primuse.home.showTopArtists",
        "primuse.home.showRecentlyAdded",
        "primuse.home.showStatsGlimpse",
        // Mac 首页
        MacHomeSectionLayout.orderKey,
        MacHomeSectionLayout.showsOverviewKey,
        MacHomeSectionLayout.showsPipelineKey,
        MacHomeSectionLayout.showsBooksKey,
        // 资料库
        LibrarySectionLayoutPolicy.orderKey,
        LibrarySectionLayoutPolicy.hiddenKey,
        QuickAccessCoverStyle.storageKey,
        // iPhone / iPad 播放页的按钮与底部状态行(只在「播放页按钮」编辑页里写)
        NowPlayingControlLayout.musicStorageKey,
        SpokenWordControlLayout.storageKey(for: .audiobook),
        SpokenWordControlLayout.storageKey(for: .podcast),
        PlayerAppearancePreferences.controlTintKey,
    ]

    private let keys: [String]
    private let cloud: CloudKVSSync
    private let defaults: UserDefaults
    private let checkDelay: Duration
    /// 每个键上次见到的值: 本机编辑要和它比, 从云端拉下来的也先记在这里。
    private var known: [String: NSObject] = [:]
    private var pendingCheck: Task<Void, Never>?
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(
        keys: [String] = InterfaceLayoutSync.keys,
        cloud: CloudKVSSync? = nil,
        defaults: UserDefaults = .standard,
        checkDelay: Duration = .milliseconds(300)
    ) {
        self.keys = keys
        self.cloud = cloud ?? .shared
        self.defaults = defaults
        self.checkDelay = checkDelay
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard observer == nil else { return }
        for key in keys {
            cloud.register(key: key) { [weak self] in self?.remember(key) }
        }
        // 每次 UserDefaults 有写入都会到这里, 合批后只比这几十个键。
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
    }

    private func remember(_ key: String) {
        known[key] = defaults.object(forKey: key) as? NSObject
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self, checkDelay] in
            try? await Task.sleep(for: checkDelay)
            guard !Task.isCancelled else { return }
            self?.pushEditedKeys()
        }
    }

    /// 和上次见到的值比, 变了的推上去。
    func pushEditedKeys() {
        for key in keys {
            let current = defaults.object(forKey: key) as? NSObject
            guard !Self.same(current, known[key]) else { continue }
            known[key] = current
            cloud.markChanged(key: key)
        }
    }

    private static func same(_ lhs: NSObject?, _ rhs: NSObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isEqual(rhs)
        default: false
        }
    }
}
#endif

