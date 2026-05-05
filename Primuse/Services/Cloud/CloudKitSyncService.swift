import CloudKit
import Foundation
import PrimuseKit
import SwiftUI

enum CloudSyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case upToDate
    case error(String)
    case accountUnavailable(AccountUnavailableReason)
    case quotaExceeded
    case networkUnavailable
}

enum AccountUnavailableReason: Equatable, Sendable {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unknown

    var localizedKey: LocalizedStringKey {
        switch self {
        case .noAccount: return "status_no_icloud_account"
        case .restricted: return "status_icloud_restricted"
        case .temporarilyUnavailable: return "status_icloud_temporarily_unavailable"
        case .unknown: return "status_icloud_unknown"
        }
    }
}

/// Entity payloads flowing through CKSyncEngine. Each conforms to `Codable` so we can
/// stash them inside a single CKRecord blob field, which sidesteps schema management
/// for CloudKit dashboard.
@MainActor
@Observable
final class CloudKitSyncService {
    nonisolated static let containerID = "iCloud.com.welape.yuanyin"
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "PrimuseSync")

    enum RecordType {
        static let playlist = "Playlist"
        static let musicSource = "MusicSource"
        static let cloudAccount = "CloudAccount"
        static let playbackHistory = "PlaybackHistory"
        static let scraperConfig = "ScraperConfig"
    }

    /// Singleton ID used for the playback-history record (one per user).
    static let playbackHistoryRecordName = "primuse.playbackHistory.singleton"

    // MARK: - Collaborators

    private let library: MusicLibrary
    private let sourcesStore: SourcesStore
    private let scraperConfigStore: ScraperConfigStore
    private let scraperSettingsStore: ScraperSettingsStore

    // MARK: - State

    private var container: CKContainer?
    private var database: CKDatabase?
    private(set) var engine: CKSyncEngine?
    private let stateURL: URL
    private let systemFieldsURL: URL
    /// `recordName → encoded CKRecord system fields`。用于在重建 CKRecord
    /// 时复用 server changeTag,否则 saveRecord 每次都被 server 当成 insert,
    /// 触发 "record to insert already exists" (CKError.serverRecordChanged)
    /// 死循环。
    private var systemFieldsCache: [String: Data] = [:]
    private var systemFieldsCacheLoaded = false

    /// In-memory marker so callers know whether a remote update is currently being
    /// applied — local stores can bail out of their own `markChanged` loop.
    private(set) var isApplyingRemote = false

    /// Coalesces playback-history pushes to at most once per 5 minutes.
    private var pendingHistoryFlush: Task<Void, Never>?
    private static let historyThrottle: Duration = .seconds(300)

    /// Set true once the consumer calls `start()`. While false we don't propagate
    /// local changes to CloudKit.
    private(set) var isStarted = false

    /// NotificationCenter observer tokens — held so we can detach in `stop()`.
    private var observerTokens: [NSObjectProtocol] = []

    /// User-facing sync state — bound to the Settings UI.
    private(set) var status: CloudSyncStatus = .disabled
    private(set) var lastSyncedAt: Date?

    /// Listens for `CKAccountChanged` so we can flip into `.accountUnavailable`
    /// when the user signs out of iCloud while the app is running.
    private var accountChangeObserver: NSObjectProtocol?

    /// Once-per-install flag: did we run `scheduleInitialUpload()` to seed
    /// CloudKit with everything that was already on disk before sync existed?
    /// CKSyncEngine's persisted state tracks per-record sync status after the
    /// first run, so re-uploading on every cold launch is wasteful.
    private static let initialUploadDoneKey = "primuse.cloudSync.initialUploadComplete"
    private var didCompleteInitialUpload: Bool {
        get { UserDefaults.standard.bool(forKey: Self.initialUploadDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.initialUploadDoneKey) }
    }

    // MARK: - Init

    init(
        library: MusicLibrary,
        sourcesStore: SourcesStore,
        scraperConfigStore: ScraperConfigStore = .shared,
        scraperSettingsStore: ScraperSettingsStore
    ) {
        self.library = library
        self.sourcesStore = sourcesStore
        self.scraperConfigStore = scraperConfigStore
        self.scraperSettingsStore = scraperSettingsStore
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = directory.appendingPathComponent("cloudkit-engine-state.bin")
        self.systemFieldsURL = directory.appendingPathComponent("cloudkit-system-fields.plist")
    }

    // MARK: - Lifecycle

    /// Bring the sync engine online. Reads previous engine state from disk if present,
    /// then does an initial fetch + sends any locally pending changes.
    func start() async {
        guard engine == nil else { return }
        guard let database = configuredDatabase() else { return }

        // Verify the user has an iCloud account before standing up the engine —
        // CKSyncEngine will fail every operation with `.notAuthenticated`
        // otherwise, and the UI is much friendlier when we surface that up front.
        let accountAvailable = await checkAccountAndUpdateStatus()
        guard accountAvailable else { return }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true

        let engine = CKSyncEngine(configuration)
        self.engine = engine
        self.isStarted = true
        self.status = .syncing

        // Make sure the zone exists by enqueueing a save (the engine de-dupes).
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])

        attachLocalChangeObservers()
        attachAccountChangeObserver()

        // Push existing local state once after install so the engine has a
        // baseline. After that CKSyncEngine's persisted state tracks per-record
        // sync status — re-uploading on every cold launch just burns quota.
        if !didCompleteInitialUpload {
            scheduleInitialUpload()
        }

        do {
            plog("CloudKitSync: starting fetchChanges()")
            try await engine.fetchChanges()
            plog("CloudKitSync: fetchChanges OK, starting sendChanges()")
            try await engine.sendChanges()
            plog("CloudKitSync: sendChanges OK")
            self.didCompleteInitialUpload = true
            self.status = .upToDate
            self.lastSyncedAt = Date()
        } catch {
            plog("CloudKitSync: initial sync error: \(error)")
            if let ck = error as? CKError {
                plog("CloudKitSync: CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            self.status = mapToSyncStatus(error)
        }
    }

    /// Query CloudKit account status and translate it into `self.status`. Returns
    /// `true` only if the account is available for sync.
    @discardableResult
    private func checkAccountAndUpdateStatus() async -> Bool {
        guard let container = configuredContainer() else { return false }

        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                return true
            case .noAccount:
                self.status = .accountUnavailable(.noAccount)
            case .restricted:
                self.status = .accountUnavailable(.restricted)
            case .temporarilyUnavailable:
                self.status = .accountUnavailable(.temporarilyUnavailable)
            case .couldNotDetermine:
                self.status = .accountUnavailable(.unknown)
            @unknown default:
                self.status = .accountUnavailable(.unknown)
            }
        } catch {
            self.status = .error(error.localizedDescription)
        }
        return false
    }

    private func configuredDatabase() -> CKDatabase? {
        if let database { return database }
        guard let container = configuredContainer() else { return nil }
        let database = container.privateCloudDatabase
        self.database = database
        return database
    }

    private func configuredContainer() -> CKContainer? {
        if let container { return container }
        guard Self.shouldCreateCloudKitContainer else {
            status = .error("CloudKit unavailable in this simulator run — \(String(localized: "icloud_container_setup_hint"))")
            return nil
        }
        let container = CKContainer(identifier: Self.containerID)
        self.container = container
        return container
    }

    private nonisolated static var shouldCreateCloudKitContainer: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["PRIMUSE_ENABLE_CLOUDKIT_IN_SIMULATOR"] == "1"
        #else
        true
        #endif
    }

    private func attachAccountChangeObserver() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let available = await self.checkAccountAndUpdateStatus()
                if !available {
                    self.stop(updateStatus: false)
                }
            }
        }
    }

    /// Tear down the engine. Local data is left intact.
    func stop(updateStatus: Bool = true) {
        pendingHistoryFlush?.cancel()
        pendingHistoryFlush = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
            self.accountChangeObserver = nil
        }
        engine = nil
        isStarted = false
        if updateStatus { status = .disabled }
    }

    /// Re-enqueue every local entity belonging to a channel. Use this when a
    /// channel is toggled from off → on so edits made while it was off get
    /// caught up. Cheap because CKSyncEngine de-dupes against server change tags.
    func catchUp(channel: CloudSyncChannel) async {
        guard isStarted else { return }
        switch channel {
        case .playlists:
            playlistsChanged(ids: library.allPlaylists.map(\.id))
        case .sources:
            sourcesChanged(ids: sourcesStore.allSources.map(\.id))
        case .playbackHistory:
            enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
        case .settings:
            scraperConfigsChanged(ids: scraperConfigStore.allConfigsIncludingDeleted.map(\.id))
            // KVS-mirrored UserDefaults keys: poke each so timestamps update.
            for key in [CloudKVSKey.playbackSettings, CloudKVSKey.scraperSettings,
                        CloudKVSKey.lyricsFontScale, CloudKVSKey.recentSearches] {
                CloudKVSSync.shared.markChanged(key: key)
            }
        case .credentials:
            // Past Keychain entries are governed by the system iCloud Keychain
            // toggle — nothing for us to push from here.
            break
        }
        await syncNow()
    }

    /// Force a fetch + send pass (used by the "Sync now" action).
    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status = .upToDate
            lastSyncedAt = Date()
        } catch {
            status = mapToSyncStatus(error)
        }
    }

    private func mapToSyncStatus(_ error: any Error) -> CloudSyncStatus {
        guard let ckError = error as? CKError else {
            return .error(error.localizedDescription)
        }
        plog("CloudKitSync: CKError code=\(ckError.code.rawValue) (\(ckError.code)) desc=\(ckError.localizedDescription) userInfo=\(ckError.userInfo)")
        if ckError.code == .partialFailure,
           let perItem = ckError.partialErrorsByItemID {
            for (key, err) in perItem {
                if let ck = err as? CKError {
                    plog("CloudKitSync: partial failure on \(key) → code=\(ck.code.rawValue) (\(ck.code)) desc=\(ck.localizedDescription) info=\(ck.userInfo)")
                } else {
                    plog("CloudKitSync: partial failure on \(key) → \(err)")
                }
            }
        }
        switch ckError.code {
        case .quotaExceeded:
            return .quotaExceeded
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .accountTemporarilyUnavailable:
            return .accountUnavailable(.temporarilyUnavailable)
        case .partialFailure:
            // CKSyncEngine surfaces per-record failures via the
            // `sentRecordZoneChanges` event handler, where they're either
            // resolved (conflict merge) or re-queued. The top-level
            // partial-failure error here is informational — the run as a whole
            // succeeded enough to be worth treating as up-to-date so the UI
            // doesn't go red. Stuck records will retry on the next pass.
            lastSyncedAt = Date()
            // Engine state has been updated for everything that did succeed,
            // so future cold launches don't need to re-seed.
            didCompleteInitialUpload = true
            return .upToDate
        case .serverRejectedRequest, .badContainer, .missingEntitlement, .permissionFailure:
            // Container / entitlement misconfigured server-side. Surface a specific
            // hint so the user knows it isn't a transient runtime issue.
            return .error("CloudKit \(ckError.code.rawValue): \(ckError.localizedDescription) — \(String(localized: "icloud_container_setup_hint"))")
        default:
            return .error("CloudKit \(ckError.code.rawValue): \(ckError.localizedDescription)")
        }
    }

    private func attachLocalChangeObservers() {
        let nc = NotificationCenter.default
        observerTokens.append(nc.addObserver(forName: .primusePlaylistsDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.playlistsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primusePlaylistDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.playlistDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSourcesDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.sourcesChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSourceDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.sourceDeleted(id: id) }
        })
        // Soft-delete is a different signal than permanent delete: the
        // local row stays for recycle-bin recovery, but the upstream
        // CloudKit record must be removed (otherwise fetchChanges would
        // resurrect it on every sync).
        observerTokens.append(nc.addObserver(forName: .primuseSourceDidSoftDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.sourceDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseCloudAccountsDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.cloudAccountsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseCloudAccountDidSoftDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.cloudAccountDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseCloudAccountDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.cloudAccountDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseScraperConfigDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.scraperConfigsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseScraperConfigDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.scraperConfigDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primusePlaybackHistoryDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playbackHistoryChanged() }
        })
    }

    // MARK: - Local-change hooks (called by stores after they persist locally)

    func playlistsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueSaves(recordType: RecordType.playlist, ids: ids)
    }

    func playlistDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueDeletes(recordType: RecordType.playlist, ids: [id])
    }

    func sourcesChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueSaves(recordType: RecordType.musicSource, ids: ids)
    }

    func sourceDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueDeletes(recordType: RecordType.musicSource, ids: [id])
    }

    func cloudAccountsChanged(ids: [String]) {
        // Cloud accounts piggy-back on the `.sources` sync channel —
        // they're the same lifecycle (user-managed cloud entities) and
        // don't deserve a separate user-facing toggle.
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueSaves(recordType: RecordType.cloudAccount, ids: ids)
    }

    func cloudAccountDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueDeletes(recordType: RecordType.cloudAccount, ids: [id])
    }

    func scraperConfigsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.settings) else { return }
        enqueueSaves(recordType: RecordType.scraperConfig, ids: ids)
    }

    func scraperConfigDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.settings) else { return }
        enqueueDeletes(recordType: RecordType.scraperConfig, ids: [id])
    }

    /// Coalesce playback-history pushes — at most once per 5 minutes.
    func playbackHistoryChanged() {
        guard isStarted, !isApplyingRemote else { return }
        guard CloudSyncChannel.isEnabled(.playbackHistory) else { return }
        guard pendingHistoryFlush == nil else { return }

        pendingHistoryFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.historyThrottle)
            guard let self else { return }
            self.pendingHistoryFlush = nil
            self.enqueueSaves(
                recordType: RecordType.playbackHistory,
                ids: [Self.playbackHistoryRecordName]
            )
        }
    }

    /// Maps a CloudKit record type to the channel that controls it. Used to
    /// gate inbound (apply-remote) processing.
    private static func channel(for recordType: String) -> CloudSyncChannel? {
        switch recordType {
        case RecordType.playlist: return .playlists
        case RecordType.musicSource: return .sources
        case RecordType.cloudAccount: return .sources
        case RecordType.playbackHistory: return .playbackHistory
        case RecordType.scraperConfig: return .settings
        default: return nil
        }
    }

    // MARK: - Internal helpers

    private func enqueueSaves(recordType: String, ids: [String]) {
        guard let engine, isStarted, !isApplyingRemote else { return }
        let changes = ids.map { id in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(recordType: recordType, id: id))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func enqueueDeletes(recordType: String, ids: [String]) {
        guard let engine, isStarted, !isApplyingRemote else { return }
        let changes = ids.map { id in
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(recordType: recordType, id: id))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func recordID(recordType: String, id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(recordType)/\(id)", zoneID: Self.zoneID)
    }

    /// On first start, push everything we have locally — including soft-deleted
    /// tombstones — so the engine can de-dupe against existing server records
    /// via change tags. Each call respects the per-channel toggles.
    private func scheduleInitialUpload() {
        playlistsChanged(ids: library.allPlaylists.map(\.id))
        sourcesChanged(ids: sourcesStore.allSources.map(\.id))
        cloudAccountsChanged(ids: sourcesStore.allAccounts.map(\.id))
        scraperConfigsChanged(ids: scraperConfigStore.allConfigsIncludingDeleted.map(\.id))
        // Push history at startup too (bypass the 5-min throttle, but still
        // honour the channel toggle).
        if CloudSyncChannel.isEnabled(.playbackHistory) {
            enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
        }
    }

    // MARK: - State persistence

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    fileprivate func saveStateSerialization(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Record system fields cache
    //
    // Without this, every save call to CloudKit went up as a fresh insert,
    // colliding with the existing server record and triggering a
    // serverRecordChanged → re-queue → re-collide loop. Caching the encoded
    // system fields (which include the per-record changeTag) lets `makeRecord`
    // hand the engine an existing-record handle so the save is recognised as
    // an update.

    private func loadSystemFieldsCacheIfNeeded() {
        guard !systemFieldsCacheLoaded else { return }
        systemFieldsCacheLoaded = true
        guard let data = try? Data(contentsOf: systemFieldsURL),
              let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) else {
            return
        }
        systemFieldsCache = dict
    }

    private func persistSystemFieldsCache() {
        guard let data = try? PropertyListEncoder().encode(systemFieldsCache) else { return }
        try? data.write(to: systemFieldsURL, options: .atomic)
    }

    fileprivate func storeSystemFields(_ record: CKRecord) {
        loadSystemFieldsCacheIfNeeded()
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let data = coder.encodedData
        let key = record.recordID.recordName
        if systemFieldsCache[key] != data {
            systemFieldsCache[key] = data
            persistSystemFieldsCache()
        }
    }

    fileprivate func removeSystemFields(for recordID: CKRecord.ID) {
        loadSystemFieldsCacheIfNeeded()
        if systemFieldsCache.removeValue(forKey: recordID.recordName) != nil {
            persistSystemFieldsCache()
        }
    }

    private func clearSystemFieldsCache() {
        systemFieldsCache.removeAll()
        systemFieldsCacheLoaded = true
        try? FileManager.default.removeItem(at: systemFieldsURL)
    }

    private func cachedRecord(for recordID: CKRecord.ID) -> CKRecord? {
        loadSystemFieldsCacheIfNeeded()
        guard let data = systemFieldsCache[recordID.recordName],
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    // MARK: - Record (de)serialization

    fileprivate func populateRecord(_ record: CKRecord, recordType: String, id: String) -> Bool {
        switch recordType {
        case RecordType.playlist:
            return populatePlaylistRecord(record, playlistID: id)
        case RecordType.musicSource:
            return populateSourceRecord(record, sourceID: id)
        case RecordType.cloudAccount:
            return populateCloudAccountRecord(record, accountID: id)
        case RecordType.scraperConfig:
            return populateScraperConfigRecord(record, configID: id)
        case RecordType.playbackHistory:
            return populatePlaybackHistoryRecord(record)
        default:
            return false
        }
    }

    fileprivate func applyRemoteRecord(_ record: CKRecord) {
        // 不论本 channel 是否启用,都先保留 system fields——禁用期间也可能后续
        // 又开启,届时如果没有 changeTag 还是会撞 "record to insert already exists"。
        storeSystemFields(record)

        if let channel = Self.channel(for: record.recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        switch record.recordType {
        case RecordType.playlist:
            applyPlaylistRecord(record)
        case RecordType.musicSource:
            applySourceRecord(record)
        case RecordType.cloudAccount:
            applyCloudAccountRecord(record)
        case RecordType.scraperConfig:
            applyScraperConfigRecord(record)
        case RecordType.playbackHistory:
            applyPlaybackHistoryRecord(record)
        default:
            break
        }
    }

    fileprivate func applyRemoteDeletion(recordID: CKRecord.ID, recordType: String) {
        // record 已经从 server 移除,缓存里的 changeTag 也没用了。
        removeSystemFields(for: recordID)

        if let channel = Self.channel(for: recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        guard let id = parseLocalID(from: recordID, recordType: recordType) else { return }

        // Recycle-bin recovery race: if the local copy has been restored
        // (isDeleted == false) since the remote prune was scheduled, treat
        // the remote deletion as stale and re-push our restored state instead
        // of wiping it.
        if isLocallyRestored(recordType: recordType, id: id) {
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        switch recordType {
        case RecordType.playlist:
            library.deletePlaylistFromRemote(id: id)
        case RecordType.musicSource:
            sourcesStore.removeFromRemote(id: id)
        case RecordType.cloudAccount:
            sourcesStore.removeAccountFromRemote(id: id)
        case RecordType.scraperConfig:
            scraperConfigStore.deleteFromRemote(id: id)
        case RecordType.playbackHistory:
            library.clearPlaybackHistory()
        default:
            break
        }
    }

    /// True if the local store still holds an active (non-soft-deleted) entry
    /// for `id`. Used to ignore stale remote prunes that would otherwise wipe
    /// a recently-restored item.
    private func isLocallyRestored(recordType: String, id: String) -> Bool {
        switch recordType {
        case RecordType.playlist:
            return library.allPlaylists.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.musicSource:
            return sourcesStore.allSources.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.cloudAccount:
            return sourcesStore.allAccounts.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.scraperConfig:
            return scraperConfigStore.allConfigsIncludingDeleted
                .first(where: { $0.id == id })
                .map { $0.isDeleted != true } ?? false
        default:
            return false
        }
    }

    private func parseLocalID(from recordID: CKRecord.ID, recordType: String) -> String? {
        let prefix = "\(recordType)/"
        guard recordID.recordName.hasPrefix(prefix) else { return nil }
        return String(recordID.recordName.dropFirst(prefix.count))
    }

    // MARK: - Playlist mapping

    private func populatePlaylistRecord(_ record: CKRecord, playlistID: String) -> Bool {
        guard let playlist = library.playlist(id: playlistID) else { return false }
        record["name"] = playlist.name
        record["createdAt"] = playlist.createdAt
        record["updatedAt"] = playlist.updatedAt
        if let cover = playlist.coverArtPath { record["coverArtPath"] = cover }
        let songIDs = library.rawSongIDs(forPlaylist: playlistID)
        record["songIDs"] = songIDs
        // Stable cross-device identities — receivers fall back through
        // (cloudAccountID, filePath) and fuzzy match when the originating
        // Song.id doesn't line up with the local mount's hash.
        if let data = encodeIdentities(makeIdentities(forSongIDs: songIDs)) {
            record[Self.songIdentitiesField] = data
        }
        return true
    }

    private func applyPlaylistRecord(_ record: CKRecord) {
        guard let id = parseLocalID(from: record.recordID, recordType: RecordType.playlist),
              let name = record["name"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return }
        let coverArtPath = record["coverArtPath"] as? String
        let songIDs = (record["songIDs"] as? [String]) ?? []
        let identities = decodeIdentities(record[Self.songIdentitiesField] as? Data)
        // Hand the raw payload to the library; it owns the 3-tier resolver
        // and stashes anything that doesn't match yet as pending so a later
        // scan can fill it in.
        library.applyRemotePlaylist(
            Playlist(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt, coverArtPath: coverArtPath),
            songIDs: songIDs,
            identities: identities
        )
    }

    // MARK: - Music source mapping

    private func populateSourceRecord(_ record: CKRecord, sourceID: String) -> Bool {
        guard let source = sourcesStore.source(id: sourceID) else { return false }
        do {
            let data = try JSONEncoder().encode(SyncableSource(source: source))
            record["payload"] = data
            record["updatedAt"] = source.modifiedAt
            return true
        } catch {
            plog("CloudKitSync: encode source failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applySourceRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let syncable = try? JSONDecoder().decode(SyncableSource.self, from: data) else { return }
        sourcesStore.upsertFromRemote(syncable.source)
    }

    // MARK: - Cloud account mapping

    private func populateCloudAccountRecord(_ record: CKRecord, accountID: String) -> Bool {
        guard let account = sourcesStore.account(id: accountID) else { return false }
        do {
            let data = try JSONEncoder().encode(account)
            record["payload"] = data
            record["updatedAt"] = account.modifiedAt
            return true
        } catch {
            plog("CloudKitSync: encode cloudAccount failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applyCloudAccountRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let account = try? JSONDecoder().decode(CloudAccount.self, from: data) else { return }
        sourcesStore.upsertAccountFromRemote(account)
    }

    // MARK: - Scraper config mapping

    private func populateScraperConfigRecord(_ record: CKRecord, configID: String) -> Bool {
        guard let config = scraperConfigStore.config(for: configID) else { return false }
        do {
            let data = try JSONEncoder().encode(config)
            record["payload"] = data
            record["updatedAt"] = config.modifiedAt ?? .distantPast
            return true
        } catch {
            plog("CloudKitSync: encode scraper config failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applyScraperConfigRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let config = try? JSONDecoder().decode(ScraperConfig.self, from: data) else { return }
        scraperConfigStore.applyRemoteConfig(config)
        scraperSettingsStore.ensureCustomSourcePresent(for: config)
    }

    // MARK: - Playback history mapping

    private func populatePlaybackHistoryRecord(_ record: CKRecord) -> Bool {
        let songIDs = library.recentPlaybackSongIDsForSync
        record["songIDs"] = songIDs
        record["updatedAt"] = Date()
        if let data = encodeIdentities(makeIdentities(forSongIDs: songIDs)) {
            record[Self.songIdentitiesField] = data
        }
        return true
    }

    private func applyPlaybackHistoryRecord(_ record: CKRecord) {
        guard let songIDs = record["songIDs"] as? [String] else { return }
        let identities = decodeIdentities(record[Self.songIdentitiesField] as? Data)
        library.applyRemotePlaybackHistory(songIDs: songIDs, identities: identities)
    }

    // MARK: - Song identity / cross-device resolution

    private static let songIdentitiesField = "songIdentities"

    /// Build cross-device identities for a batch of locally-stored song
    /// IDs. Songs that have already been deleted locally still get a stub
    /// identity so the receiving device can attempt a fuzzy match — at
    /// worst it's dropped, which matches the receiver's reality anyway.
    private func makeIdentities(forSongIDs songIDs: [String]) -> [SongIdentity] {
        songIDs.map { id in
            if let song = library.song(id: id) {
                return SongIdentity(
                    songID: song.id,
                    title: song.title,
                    artistName: song.artistName,
                    duration: song.duration,
                    cloudAccountID: sourcesStore.source(id: song.sourceID)?.cloudAccountID,
                    filePath: song.filePath
                )
            }
            return SongIdentity(
                songID: id, title: "", artistName: nil,
                duration: 0, cloudAccountID: nil, filePath: ""
            )
        }
    }

    private func encodeIdentities(_ identities: [SongIdentity]) -> Data? {
        try? JSONEncoder().encode(identities)
    }

    private func decodeIdentities(_ data: Data?) -> [SongIdentity]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([SongIdentity].self, from: data)
    }

    // The cross-device 3-tier resolver lives on `MusicLibrary` — it
    // owns the songs collection, can use `sourceIdentityResolver` to map
    // a song's mount UUID back to a stable cloud account, and persists
    // unresolved identities as pending so a later scan can fill them in.
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncService: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            await MainActor.run { self.saveStateSerialization(event.stateSerialization) }
        case .fetchedRecordZoneChanges(let event):
            for modification in event.modifications {
                await MainActor.run { self.applyRemoteRecord(modification.record) }
            }
            for deletion in event.deletions {
                await MainActor.run {
                    self.applyRemoteDeletion(recordID: deletion.recordID, recordType: deletion.recordType)
                }
            }
        case .fetchedDatabaseChanges(let event):
            // Zone-level changes from another device. Most often: zone deletion
            // (user wiped CloudKit data on another device, or container reset).
            // We re-create our zone if it's gone and force a re-seed on next
            // start so the local data ends up back in CloudKit.
            for deletion in event.deletions where deletion.zoneID == Self.zoneID {
                plog("CloudKitSync: PrimuseSync zone was deleted remotely — recreating + re-seeding")
                await MainActor.run {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    self.clearSystemFieldsCache()
                    self.didCompleteInitialUpload = false
                }
            }
        case .sentRecordZoneChanges(let event):
            for saved in event.savedRecords {
                await MainActor.run { self.storeSystemFields(saved) }
            }
            for deletedID in event.deletedRecordIDs {
                await MainActor.run { self.removeSystemFields(for: deletedID) }
            }
            for failed in event.failedRecordSaves {
                await MainActor.run {
                    self.handleFailedSave(failed, syncEngine: syncEngine)
                }
            }
        case .sentDatabaseChanges(let event):
            for failed in event.failedZoneSaves {
                plog("CloudKitSync: failed to save zone \(failed.zone.zoneID): \(failed.error.localizedDescription)")
            }
        case .accountChange(let change):
            await MainActor.run { self.handleAccountChange(change) }
        case .willFetchChanges, .willSendChanges, .didFetchChanges, .didSendChanges:
            // Lifecycle markers — useful for debugging but no action needed.
            break
        @unknown default:
            plog("CloudKitSync: unhandled engine event \(event)")
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            let record = await MainActor.run { self.makeRecord(for: recordID) }
            if let record { return record }
            // Local entity is gone — drop the pending change so the engine
            // doesn't retry forever. (Default behavior is to leave it queued.)
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    @MainActor
    fileprivate func handleFailedSave(
        _ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        let recordID = failed.record.recordID
        guard let ckError = failed.error as? CKError else {
            plog("CloudKitSync: unhandled save error: \(failed.error.localizedDescription)")
            return
        }

        switch ckError.code {
        case .serverRecordChanged:
            resolveServerRecordChanged(local: failed.record, error: ckError, syncEngine: syncEngine)
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and try again.
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .unknownItem:
            // Server-side record went away (deleted on another device). Mirror
            // that locally so the two sides line up.
            applyRemoteDeletion(recordID: recordID, recordType: failed.record.recordType)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Engine retries automatically; honor any explicit retry-after.
            if let retry = ckError.retryAfterSeconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(retry))
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            }
        case .quotaExceeded:
            status = .quotaExceeded
        case .notAuthenticated:
            status = .accountUnavailable(.noAccount)
        default:
            plog("CloudKitSync: unhandled save error code \(ckError.code.rawValue): \(ckError.localizedDescription)")
        }
    }

    /// Resolve a `serverRecordChanged` conflict with type-aware merging.
    ///
    /// - **Playlists**: union both sides' `songIDs` so neither device's recent
    ///   add is lost; pick name/coverArt from the larger `updatedAt`.
    /// - **PlaybackHistory**: union+dedup, capped at 100, local entries first.
    /// - **MusicSource / ScraperConfig** (payload-based atomic types):
    ///   straight last-writer-wins on `updatedAt`.
    ///
    /// Always applies the merged record locally, then re-enqueues a save —
    /// CKSyncEngine carries the server's new changeTag forward so the next
    /// save isn't rejected.
    @MainActor
    private func resolveServerRecordChanged(
        local: CKRecord,
        error: CKError,
        syncEngine: CKSyncEngine
    ) {
        guard let server = error.serverRecord else {
            // No server record provided — naive re-queue.
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
            return
        }

        // 不论分支走哪条,都先把 server 的 changeTag 存起来——下一轮 makeRecord
        // 重建时才能复用,save 才会被识别成 update。
        storeSystemFields(server)

        switch server.recordType {
        case RecordType.playlist:
            mergePlaylistRecord(local: local, server: server)
        case RecordType.playbackHistory:
            mergePlaybackHistoryRecord(local: local, server: server)
        default:
            // MusicSource / ScraperConfig: payload is atomic, LWW on updatedAt.
            let localUpdated = (local["updatedAt"] as? Date) ?? .distantPast
            let serverUpdated = (server["updatedAt"] as? Date) ?? .distantPast
            if serverUpdated >= localUpdated {
                applyRemoteRecord(server)
                return  // local save dropped
            }
            // Local wins: keep our store as-is and re-push.
        }

        // Re-enqueue so engine picks up the merged local state with server's
        // changeTag.
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
    }

    @MainActor
    private func mergePlaylistRecord(local: CKRecord, server: CKRecord) {
        guard let id = parseLocalID(from: server.recordID, recordType: RecordType.playlist) else { return }

        let localIDs = (local["songIDs"] as? [String]) ?? []
        let serverIdentities = decodeIdentities(server[Self.songIdentitiesField] as? Data)
        let serverIDs = (server["songIDs"] as? [String]) ?? []

        let localUpdated = (local["updatedAt"] as? Date) ?? .distantPast
        let serverUpdated = (server["updatedAt"] as? Date) ?? .distantPast
        let useLocalScalars = localUpdated > serverUpdated
        let name = (useLocalScalars ? local["name"] : server["name"]) as? String
            ?? (server["name"] as? String) ?? ""
        let createdAt = (server["createdAt"] as? Date) ?? Date()
        let coverArtPath = (useLocalScalars ? local["coverArtPath"] : server["coverArtPath"]) as? String
        let updatedAt = max(localUpdated, serverUpdated)
        let mergedPlaylist = Playlist(
            id: id, name: name,
            createdAt: createdAt, updatedAt: updatedAt,
            coverArtPath: coverArtPath
        )

        applyRemoteEnvelope {
            if let serverIdentities {
                // Identity-aware merge: server entries that resolve are
                // unioned in; entries that don't go to pending so a later
                // local scan can fill them. localIDs preserved as the
                // base list (already resolved on this device).
                library.mergeRemotePlaylist(
                    mergedPlaylist,
                    baseSongIDs: localIDs,
                    additionalIdentities: serverIdentities
                )
            } else {
                // Legacy record without identities — naive ID union.
                var seen = Set<String>()
                let mergedIDs = (localIDs + serverIDs).filter { seen.insert($0).inserted }
                library.applyRemotePlaylist(mergedPlaylist, songIDs: mergedIDs)
            }
        }
    }

    @MainActor
    private func mergePlaybackHistoryRecord(local: CKRecord, server: CKRecord) {
        let localIDs = (local["songIDs"] as? [String]) ?? []
        let serverIdentities = decodeIdentities(server[Self.songIdentitiesField] as? Data)
        let serverIDs = (server["songIDs"] as? [String]) ?? []

        applyRemoteEnvelope {
            if let serverIdentities {
                library.mergeRemotePlaybackHistory(
                    baseSongIDs: localIDs,
                    additionalIdentities: serverIdentities
                )
            } else {
                var seen = Set<String>()
                let merged = (localIDs + serverIDs).filter { seen.insert($0).inserted }
                let capped = Array(merged.prefix(100))
                library.applyRemotePlaybackHistory(songIDs: capped)
            }
        }
    }

    @MainActor
    private func applyRemoteEnvelope(_ work: () -> Void) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        work()
    }

    @MainActor
    private func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let parts = recordID.recordName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let recordType = parts[0]
        let localID = parts[1]
        // 优先从缓存还原带 changeTag 的 record;否则只能新建 (server 会当成 insert)
        let record = cachedRecord(for: recordID)
            ?? CKRecord(recordType: recordType, recordID: recordID)
        guard populateRecord(record, recordType: recordType, id: localID) else {
            return nil
        }
        return record
    }

    @MainActor
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // Drop the engine state and disarm sync. We deliberately do NOT
            // wipe the local stores (playlists, sources, scraper configs) —
            // that would be data loss the user didn't ask for. We also force
            // the master toggle off so we don't auto-push the previous user's
            // data into the new account on next launch. The user can re-enable
            // sync from Settings when they're ready, and the next start() will
            // re-seed CloudKit because we've cleared `didCompleteInitialUpload`.
            try? FileManager.default.removeItem(at: stateURL)
            clearSystemFieldsCache()
            didCompleteInitialUpload = false
            UserDefaults.standard.set(false, forKey: "primuse.iCloudSyncEnabled")
            stop(updateStatus: true)
            status = .accountUnavailable(.unknown)
        case .signIn:
            // Don't auto-start — let the user re-toggle iCloud sync explicitly
            // so they understand the data direction.
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Sync payloads

/// Sources are written to CloudKit minus their device-local fields (`lastScannedAt`,
/// `songCount`) so a freshly-synced device doesn't inherit a stale scan state.
private struct SyncableSource: Codable {
    var source: MusicSource

    init(source: MusicSource) {
        var copy = source
        copy.lastScannedAt = nil
        copy.songCount = 0
        self.source = copy
    }
}

private extension CKError {
    var retryAfterSeconds: Double? {
        userInfo[CKErrorRetryAfterKey] as? Double
    }
}

private extension Error {
    var retryAfterSeconds: Double? {
        (self as? CKError)?.retryAfterSeconds
    }
}
