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

    /// 家庭共享 zone ── owner 在这里创建 CKShare, 邀请的 participant 通过
    /// 系统 sharing 接受后能看到这个 zone 里的 record。
    /// 哪些 record 类型进 family zone 由 `recordTypeIsShareable(_:)` 决定:
    /// - shared: Playlist / SmartPlaylist / MusicSource / CloudAccount (家庭共曲库)
    /// - private (留在 PrimuseSync): PlaybackHistory / ListeningStats / ScraperConfig (个人偏好)
    nonisolated static let familyZoneID = CKRecordZone.ID(zoneName: "PrimuseFamily")

    /// 共享 CKShare 的固定 recordName, 跟 family zone 1:1 绑定。
    nonisolated static let familyShareRecordName = "primuse.family.share"

    enum RecordType {
        static let playlist = "Playlist"
        static let smartPlaylist = "SmartPlaylist"
        static let musicSource = "MusicSource"
        static let cloudAccount = "CloudAccount"
        static let playbackHistory = "PlaybackHistory"
        static let listeningStats = "ListeningStats"
        static let scraperConfig = "ScraperConfig"
    }

    /// 是否家庭共享, 启用后 shareable record 写到 family zone, 否则继续走老的
    /// PrimuseSync zone (向后兼容现有用户)。用 UserDefaults 持久化 (CloudKit 自己
    /// 那 share 状态由 server 维护, 本地只缓存开关)。
    @MainActor
    static var familySharingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "primuse.familySharing.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "primuse.familySharing.enabled") }
    }

    /// 哪些 record 类型属于"家庭共享内容"。匹配的 record 启用 family sharing
    /// 后写入 familyZoneID, 否则一律 PrimuseSync。
    nonisolated static func recordTypeIsShareable(_ recordType: String) -> Bool {
        switch recordType {
        case RecordType.playlist, RecordType.smartPlaylist,
             RecordType.musicSource, RecordType.cloudAccount:
            return true
        default:
            return false   // history / stats / scraperConfig 属于个人偏好不共享
        }
    }

    /// 当前应该用哪个 zone 写指定 recordType + id。三层决定:
    /// - 未启用 family sharing → 一律 PrimuseSync
    /// - 启用 + 非共享类型 (history / stats / scraperConfig) → PrimuseSync
    /// - 启用 + 共享类型 + 例外 record id → PrimuseSync
    ///   (「我喜欢」每人独立, 不进家庭共享; 升级前已在 PrimuseSync 的 record
    ///   也继续在那里, 不强制迁)
    /// - 启用 + 共享类型 + 普通 id → familyZoneID
    @MainActor
    static func zoneFor(recordType: String, id: String) -> CKRecordZone.ID {
        guard Self.familySharingEnabled, recordTypeIsShareable(recordType) else {
            return Self.zoneID
        }
        // Playlist 类型按 id 例外: 「我喜欢」每人独立
        if recordType == RecordType.playlist, id == MusicLibrary.likedSongsPlaylistID {
            return Self.zoneID
        }
        return Self.familyZoneID
    }

    /// Singleton ID used for the playback-history record (one per user).
    static let playbackHistoryRecordName = "primuse.playbackHistory.singleton"
    /// Singleton ID used for full listening stats (one per user).
    static let listeningStatsRecordName = "primuse.listeningStats.singleton"

    // MARK: - Collaborators

    private let library: MusicLibrary
    private let sourcesStore: SourcesStore
    private let scraperConfigStore: ScraperConfigStore
    private let scraperSettingsStore: ScraperSettingsStore

    // MARK: - State

    private var container: CKContainer?
    private var database: CKDatabase?
    private(set) var engine: CKSyncEngine?
    /// Identifies the one start attempt that is allowed to cross the async
    /// account check. Main-actor isolation alone does not prevent reentrancy at
    /// that suspension point.
    private var startAttemptID: UUID?
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
    private var pendingListeningStatsFlush: Task<Void, Never>?
    private static let historyThrottle: Duration = .seconds(300)

    /// Set true once the consumer calls `start()`. While false we don't propagate
    /// local changes to CloudKit.
    private(set) var isStarted = false

    /// NotificationCenter observer tokens — held so we can detach in `stop()`.
    private var observerTokens: [NSObjectProtocol] = []

    /// User-facing sync state — bound to the Settings UI.
    private(set) var status: CloudSyncStatus = .disabled {
        didSet { Self.notifyOnErrorTransition(old: oldValue, new: status) }
    }
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
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = directory.appendingPathComponent("cloudkit-engine-state.bin")
        self.systemFieldsURL = directory.appendingPathComponent("cloudkit-system-fields.plist")
    }

    // MARK: - Lifecycle

    /// Bring the sync engine online. Reads previous engine state from disk if present,
    /// then does an initial fetch + sends any locally pending changes.
    func start() async {
        guard engine == nil, startAttemptID == nil else { return }
        guard let database = configuredDatabase() else { return }
        let attemptID = UUID()
        startAttemptID = attemptID
        defer {
            if startAttemptID == attemptID {
                startAttemptID = nil
            }
        }

        // Verify the user has an iCloud account before standing up the engine —
        // CKSyncEngine will fail every operation with `.notAuthenticated`
        // otherwise, and the UI is much friendlier when we surface that up front.
        let accountAvailable = await checkAccountAndUpdateStatus()
        guard accountAvailable, startAttemptID == attemptID, engine == nil else { return }

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
        // Family zone 只有在启用家庭共享时才需要; 没启用时建出来也没坏处
        // (空 zone), 但为了少跑一次 server roundtrip, 仅 enable 时主动 add。
        if Self.familySharingEnabled {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.familyZoneID))])
        }

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
            try await sendChangesResolvingRecoverableFailures(using: engine)
            plog("CloudKitSync: sendChanges OK")
            guard self.engine === engine, startAttemptID == attemptID else { return }
            self.didCompleteInitialUpload = true
            self.status = .upToDate
            self.lastSyncedAt = Date()
        } catch {
            guard self.engine === engine, startAttemptID == attemptID else { return }
            if let ck = error as? CKError {
                plog("CloudKitSync: initial sync error \(Self.compactDescription(for: ck))")
            } else {
                plog("CloudKitSync: initial sync error: \(error.localizedDescription)")
            }
            self.status = mapToSyncStatus(error)
        }

        // 如果之前是 participant (接受过别人家庭包), 启动 shared DB engine
        // 拉 owner 那侧 family zone 的最新 record。
        if Self.familySharingEnabled, isParticipantOfShare {
            guard self.engine === engine, startAttemptID == attemptID else { return }
            await startSharedDatabaseEngine()
        }
    }

    // MARK: - Family Sharing

    /// Participant 端的第二个 sync engine, 监听 .sharedCloudDatabase。
    /// owner 端不需要 (owner 写自己的 privateDB + family zone, 走 privateEngine)。
    private(set) var sharedEngine: CKSyncEngine?

    /// 标记是不是 participant (接受过别人的 share)。owner 自己也算开了 family,
    /// 但 owner 不需要 sharedEngine, 走 privateEngine 就行。
    /// 用 UserDefaults 持久 ── CKContainer 没暴露简便的 "我接受过哪些 share"。
    @MainActor
    private var isParticipantOfShare: Bool {
        get { UserDefaults.standard.bool(forKey: "primuse.familySharing.isParticipant") }
        set { UserDefaults.standard.set(newValue, forKey: "primuse.familySharing.isParticipant") }
    }

    /// Owner 启用家庭共享 ── 在 family zone 建一个 holder record + CKShare,
    /// 返回 CKShare 让 UI 用 UICloudSharingController 弹邀请发到 iMessage / 邮件。
    /// 之后 shareable record (playlist / source / cloud account 等) 会自动走
    /// family zone, participant 接受后能看到。
    /// 「我喜欢」playlist 例外仍在 PrimuseSync (zoneFor 已经处理), 不会被 share。
    ///
    /// 幂等 ── 用户重复点 "创建家庭包" / 重装 app 后再点, 都能正确返回当前
    /// CKShare 而不是抛 "record already exists":
    /// 1. holder 已在 server (上次创建成功) → fetch + 复用
    /// 2. holder 有但 share 被删了 (用户曾解散) → 在现有 holder 上重建 share
    /// 3. 都没有 → fresh insert
    @MainActor
    func enableFamilySharing() async throws -> CKShare {
        guard let db = configuredDatabase() else {
            throw NSError(domain: "Primuse.Cloud", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "CloudKit unavailable"])
        }

        // 1. ensure family zone on server (save zone 幂等, 已存在不报错)
        let zone = CKRecordZone(zoneID: Self.familyZoneID)
        do {
            _ = try await db.save(zone)
        } catch let err as CKError where err.code == .serverRecordChanged {
            // 已存在, ignore
        } catch {
            plog("⚠️ ensure family zone failed: \(error.localizedDescription)")
        }

        let holderID = CKRecord.ID(recordName: "primuse.family.holder",
                                    zoneID: Self.familyZoneID)

        // 2. 试 fetch 现有 holder ── 如果在 + 有 share, 直接复用
        if let existingHolder = try? await db.record(for: holderID) {
            // holder 已存在, 查它关联的 share reference
            if let shareRef = existingHolder.share,
               let existingShare = try? await db.record(for: shareRef.recordID) as? CKShare {
                Self.familySharingEnabled = true
                isParticipantOfShare = false
                plog("☁️ Family sharing reuse existing share")
                return existingShare
            }
            // holder 在但 share 没了 → 在现有 holder 上 attach 新 share
            let newShare = CKShare(rootRecord: existingHolder)
            newShare[CKShare.SystemFieldKey.title] = "Primuse Family" as CKRecordValue
            newShare.publicPermission = .none
            let (rebuiltResults, _) = try await db.modifyRecords(
                saving: [existingHolder, newShare], deleting: []
            )
            for (_, result) in rebuiltResults {
                if case .failure(let err) = result { throw err }
            }
            Self.familySharingEnabled = true
            isParticipantOfShare = false
            scheduleInitialUpload()
            plog("☁️ Family sharing rebuilt share on existing holder")
            return newShare
        }

        // 3. 全新创建 holder + share (CKShare 必须依附 rootRecord, holder 当
        //    placeholder; 真正 share 整个 family zone 的 record 通过这个
        //    rootRecord 的关联做)
        let holder = CKRecord(recordType: "FamilyHolder", recordID: holderID)
        holder["createdAt"] = Date() as CKRecordValue

        let share = CKShare(rootRecord: holder)
        share[CKShare.SystemFieldKey.title] = "Primuse Family" as CKRecordValue
        share.publicPermission = .none

        let (results, _) = try await db.modifyRecords(saving: [holder, share], deleting: [])
        for (_, result) in results {
            if case .failure(let err) = result { throw err }
        }

        Self.familySharingEnabled = true
        isParticipantOfShare = false

        // migration: shareable record 重新 push, recordID 算到 family zone
        scheduleInitialUpload()
        plog("☁️ Family sharing enabled, share created")
        return share
    }

    /// Owner 解散家庭包 / participant 退出。
    /// owner: 删 CKShare record, family zone 里的数据保留 (server-side; 用户
    /// 关掉 sharing 不应该丢数据, 后续重新启用能直接恢复)。后续 shareable
    /// record 写回 PrimuseSync zone。
    /// participant: 仅清本地状态; CloudKit 不暴露 "退出 share" 简便 API, 等
    /// owner 主动移除或解散。
    @MainActor
    func disableFamilySharing() async {
        if let db = configuredDatabase() {
            let holderID = CKRecord.ID(recordName: "primuse.family.holder",
                                        zoneID: Self.familyZoneID)
            // 删 holder 会级联清掉 CKShare (CKShare 是 holder 的关联)
            _ = try? await db.deleteRecord(withID: holderID)
        }
        Self.familySharingEnabled = false
        isParticipantOfShare = false
        sharedEngine = nil
        plog("☁️ Family sharing disabled")
    }

    /// Participant 接受 share ── 系统 SceneDelegate 收到 .ck 链接转过来, 我们
    /// 用 CKAcceptSharesOperation 完成接受, 然后启动 sharedEngine 拉 owner 那
    /// 边的 family zone 数据进本地 library。
    @MainActor
    func acceptShare(metadata: CKShare.Metadata) async {
        guard let container else {
            plog("⚠️ acceptShare: CloudKit container not ready")
            return
        }
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        op.qualityOfService = .userInitiated
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            op.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: true)
                case .failure(let err):
                    plog("⚠️ acceptShare failed: \(err.localizedDescription)")
                    cont.resume(returning: false)
                }
            }
            container.add(op)
        }
        guard ok else { return }
        Self.familySharingEnabled = true
        isParticipantOfShare = true
        await startSharedDatabaseEngine()
        plog("☁️ Family share accepted, participant engine started")
    }

    /// Participant 端 sharedEngine 启动 ── 跟 privateEngine 并行, 监听
    /// .sharedCloudDatabase 的 family zone 变化。delegate (CKSyncEngineDelegate)
    /// 共用 self, handleEvent 内部按 syncEngine 区分。
    @MainActor
    private func startSharedDatabaseEngine() async {
        guard sharedEngine == nil, let container else { return }
        let sharedDB = container.sharedCloudDatabase
        var config = CKSyncEngine.Configuration(
            database: sharedDB,
            stateSerialization: loadSharedStateSerialization(),
            delegate: self
        )
        config.automaticallySync = true
        let eng = CKSyncEngine(config)
        sharedEngine = eng
        do {
            try await eng.fetchChanges()
            plog("☁️ Shared engine initial fetchChanges OK")
        } catch {
            plog("⚠️ Shared engine fetchChanges failed: \(error.localizedDescription)")
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
        startAttemptID = nil
        pendingHistoryFlush?.cancel()
        pendingHistoryFlush = nil
        pendingListeningStatsFlush?.cancel()
        pendingListeningStatsFlush = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
            self.accountChangeObserver = nil
        }
        engine = nil
        sharedEngine = nil
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
            smartPlaylistsChanged(ids: library.allSmartPlaylists.map(\.id))
        case .sources:
            sourcesChanged(ids: sourcesStore.allSources.map(\.id))
        case .playbackHistory:
            enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
        case .listeningStats:
            enqueueSaves(recordType: RecordType.listeningStats, ids: [Self.listeningStatsRecordName])
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
            try await sendChangesResolvingRecoverableFailures(using: engine)
            status = .upToDate
            lastSyncedAt = Date()
        } catch {
            status = mapToSyncStatus(error)
        }
    }

    /// `sendChanges()` may throw a top-level partial failure even when every
    /// per-record error is recoverable. Repair those entries immediately, then
    /// give the engine one clean retry so startup doesn't leave sync looking
    /// failed after a harmless "record already exists" conflict.
    private func sendChangesResolvingRecoverableFailures(using engine: CKSyncEngine) async throws {
        do {
            try await engine.sendChanges()
        } catch {
            guard resolveRecoverablePartialFailure(error, syncEngine: engine) else {
                throw error
            }
            plog("CloudKitSync: resolved recoverable send conflicts, retrying sendChanges()")
            try await engine.sendChanges()
        }
    }

    @discardableResult
    private func resolveRecoverablePartialFailure(_ error: any Error, syncEngine: CKSyncEngine) -> Bool {
        guard let ckError = error as? CKError,
              ckError.code == .partialFailure,
              let partialErrors = ckError.partialErrorsByItemID else {
            return false
        }

        var handledAny = false
        var hasUnhandled = false

        for (itemID, itemError) in partialErrors {
            guard let recordID = itemID as? CKRecord.ID,
                  let itemCKError = itemError as? CKError else {
                hasUnhandled = true
                continue
            }

            if resolveRecoverableRecordSaveFailure(
                recordID: recordID,
                error: itemCKError,
                syncEngine: syncEngine
            ) {
                handledAny = true
            } else {
                hasUnhandled = true
            }
        }

        return handledAny && !hasUnhandled
    }

    private func resolveRecoverableRecordSaveFailure(
        recordID: CKRecord.ID,
        error: CKError,
        syncEngine: CKSyncEngine
    ) -> Bool {
        guard isSyncableRecordID(recordID) else {
            dropPendingRecordZoneChanges(for: recordID, syncEngine: syncEngine)
            return true
        }

        switch error.code {
        case .serverRecordChanged:
            guard let local = makeRecord(for: recordID) else {
                dropPendingRecordZoneChanges(for: recordID, syncEngine: syncEngine)
                return true
            }
            resolveServerRecordChanged(local: local, error: error, syncEngine: syncEngine)
            return true
        case .invalidArguments:
            dropPendingRecordZoneChanges(for: recordID, syncEngine: syncEngine)
            return true
        case .unknownItem:
            if let recordType = recordMetadata(for: recordID)?.recordType {
                applyRemoteDeletion(recordID: recordID, recordType: recordType, allowLocalRestore: true)
            } else {
                dropPendingRecordZoneChanges(for: recordID, syncEngine: syncEngine)
            }
            return true
        default:
            return false
        }
    }

    /// Fire a user-visible notification when sync first transitions into a
    /// hard error state. We deliberately ignore `.networkUnavailable` (will
    /// auto-recover when the device reconnects) and `.syncing → upToDate`
    /// roundtrips. Dedup'd by category identifier — repeat hits replace the
    /// existing notification rather than stacking.
    private static func notifyOnErrorTransition(old: CloudSyncStatus, new: CloudSyncStatus) {
        guard old != new else { return }
        let title = String(localized: "notify_cloud_sync_failed_title")
        let message: String?
        switch new {
        case .error(let detail):
            message = detail
        case .quotaExceeded:
            message = String(localized: "icloud_quota_exceeded")
        default:
            message = nil
        }
        guard let message else { return }
        Task { @MainActor in
            await UserNotificationService.shared.postError(
                category: .cloudSyncFailed,
                title: title,
                body: message
            )
        }
    }

    private func mapToSyncStatus(_ error: any Error) -> CloudSyncStatus {
        guard let ckError = error as? CKError else {
            return .error(error.localizedDescription)
        }
        plog("CloudKitSync: CKError \(Self.compactDescription(for: ckError))")
        if ckError.code == .partialFailure,
           let perItem = ckError.partialErrorsByItemID {
            for (key, err) in perItem {
                if let ck = err as? CKError {
                    plog("CloudKitSync: partial failure on \(key) → \(Self.compactDescription(for: ck))")
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

    private nonisolated static func compactDescription(for error: CKError) -> String {
        var parts = [
            "code=\(error.code.rawValue) (\(error.code))",
            "desc=\(error.localizedDescription)"
        ]
        if let retry = error.retryAfterSeconds {
            parts.append(String(format: "retryAfter=%.1fs", retry))
        }
        if let serverRecord = error.serverRecord {
            parts.append("serverRecord=\(serverRecord.recordID.recordName)")
            parts.append("serverZone=\(serverRecord.recordID.zoneID.zoneName)")
        }
        if let partials = error.partialErrorsByItemID {
            parts.append("partialFailures=\(partials.count)")
        }
        for key in ["ServerErrorDescription", "ClientEtag", "ServerEtag", "OperationID", "RequestUUID"] {
            if let value = error.userInfo[key] {
                parts.append("\(key)=\(value)")
            }
        }
        return parts.joined(separator: " ")
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
        observerTokens.append(nc.addObserver(forName: .primuseSmartPlaylistsDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.smartPlaylistsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSmartPlaylistDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.smartPlaylistDeleted(id: id) }
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
        observerTokens.append(nc.addObserver(forName: .primuseListeningStatsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.listeningStatsChanged() }
        })
    }

    // MARK: - Local-change hooks (called by stores after they persist locally)

    func playlistsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        // Apple Music mirrors are regenerated locally from each device's
        // MusicKit library. Keeping them in Primuse CloudKit creates stale,
        // empty, or duplicate playlists on devices that cannot resolve the
        // same Apple Music library. Existing mirrors are deleted from CloudKit
        // to clean up older builds that used to sync them.
        let syncable = ids.filter { !AppleMusicLibraryService.isAppleMusicMirrorPlaylist($0) }
        let mirrorIDs = ids.filter { AppleMusicLibraryService.isAppleMusicMirrorPlaylist($0) }
        enqueueSaves(recordType: RecordType.playlist, ids: syncable)
        enqueueDeletes(recordType: RecordType.playlist, ids: mirrorIDs)
    }

    func playlistDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        guard !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(id) else { return }
        enqueueDeletes(recordType: RecordType.playlist, ids: [id])
    }

    func smartPlaylistsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueSaves(recordType: RecordType.smartPlaylist, ids: ids)
    }

    func smartPlaylistDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueDeletes(recordType: RecordType.smartPlaylist, ids: [id])
    }

    func sourcesChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        let resolved = resolveSourceIDsForSync(ids)
        enqueueSaves(recordType: RecordType.musicSource, ids: resolved.active)
        enqueueDeletes(recordType: RecordType.musicSource, ids: resolved.deleted)
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
        let resolved = resolveCloudAccountIDsForSync(ids)
        enqueueSaves(recordType: RecordType.cloudAccount, ids: resolved.active)
        enqueueDeletes(recordType: RecordType.cloudAccount, ids: resolved.deleted)
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

    func listeningStatsChanged() {
        guard isStarted, !isApplyingRemote else { return }
        guard CloudSyncChannel.isEnabled(.listeningStats) else { return }
        guard pendingListeningStatsFlush == nil else { return }

        pendingListeningStatsFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.historyThrottle)
            guard let self else { return }
            self.pendingListeningStatsFlush = nil
            self.enqueueSaves(
                recordType: RecordType.listeningStats,
                ids: [Self.listeningStatsRecordName]
            )
        }
    }

    private typealias SyncIDResolution = (active: [String], deleted: [String])

    private func resolveSourceIDsForSync(_ ids: [String]) -> SyncIDResolution {
        var seen = Set<String>()
        var active: [String] = []
        var deleted: [String] = []
        for id in ids where seen.insert(id).inserted {
            guard let source = sourcesStore.allSources.first(where: { $0.id == id }) else { continue }
            if source.isDeleted {
                deleted.append(id)
            } else {
                active.append(id)
            }
        }
        return (active, deleted)
    }

    private func resolveCloudAccountIDsForSync(_ ids: [String]) -> SyncIDResolution {
        var seen = Set<String>()
        var active: [String] = []
        var deleted: [String] = []
        for id in ids where seen.insert(id).inserted {
            guard let account = sourcesStore.allAccounts.first(where: { $0.id == id }) else { continue }
            if account.isDeleted {
                deleted.append(id)
            } else {
                active.append(id)
            }
        }
        return (active, deleted)
    }

    /// Maps a CloudKit record type to the channel that controls it. Used to
    /// gate inbound (apply-remote) processing.
    private static func channel(for recordType: String) -> CloudSyncChannel? {
        switch recordType {
        case RecordType.playlist: return .playlists
        case RecordType.smartPlaylist: return .playlists
        case RecordType.musicSource: return .sources
        case RecordType.cloudAccount: return .sources
        case RecordType.playbackHistory: return .playbackHistory
        case RecordType.listeningStats: return .listeningStats
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
        addCoalescedRecordZoneChanges(changes, to: engine)
    }

    private func enqueueDeletes(recordType: String, ids: [String]) {
        guard let engine, isStarted, !isApplyingRemote else { return }
        let changes = ids.map { id in
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(recordType: recordType, id: id))
        }
        addCoalescedRecordZoneChanges(changes, to: engine)
    }

    private func addCoalescedRecordZoneChanges(
        _ changes: [CKSyncEngine.PendingRecordZoneChange],
        to syncEngine: CKSyncEngine
    ) {
        Self.replacePendingRecordZoneChanges(
            with: changes,
            in: syncEngine,
            scopeFilter: nil
        )
    }

    nonisolated private static func replacePendingRecordZoneChanges(
        with changes: [CKSyncEngine.PendingRecordZoneChange],
        in syncEngine: CKSyncEngine,
        scopeFilter: ((CKSyncEngine.PendingRecordZoneChange) -> Bool)?
    ) {
        let coalescedChanges = coalescedRecordZoneChanges(changes)
        guard !coalescedChanges.isEmpty else { return }

        let changedRecordIDs = Set(coalescedChanges.compactMap(recordID(for:)))
        guard !changedRecordIDs.isEmpty else {
            syncEngine.state.add(pendingRecordZoneChanges: coalescedChanges)
            return
        }

        let existingChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
            if let scopeFilter, !scopeFilter(change) { return false }
            guard let recordID = recordID(for: change) else { return false }
            return changedRecordIDs.contains(recordID)
        }

        if !existingChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: existingChanges)
        }
        syncEngine.state.add(pendingRecordZoneChanges: coalescedChanges)
    }

    nonisolated private static func coalescedRecordZoneChanges(
        _ changes: [CKSyncEngine.PendingRecordZoneChange]
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        var coalesced: [CKSyncEngine.PendingRecordZoneChange] = []
        var indexByRecordID: [CKRecord.ID: Int] = [:]

        for change in changes {
            guard let recordID = recordID(for: change) else {
                coalesced.append(change)
                continue
            }

            if let index = indexByRecordID[recordID] {
                coalesced[index] = change
            } else {
                indexByRecordID[recordID] = coalesced.count
                coalesced.append(change)
            }
        }

        return coalesced
    }

    nonisolated private static func recordID(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            return recordID
        @unknown default:
            return nil
        }
    }

    private func recordID(recordType: String, id: String) -> CKRecord.ID {
        // 共享 record 进 family zone (启用家庭共享时), 个人 record 始终 PrimuseSync。
        // 「我喜欢」playlist 按 id 例外仍走 PrimuseSync。
        CKRecord.ID(recordName: "\(recordType)/\(id)",
                    zoneID: Self.zoneFor(recordType: recordType, id: id))
    }

    private func recordMetadata(for recordID: CKRecord.ID) -> (recordType: String, localID: String)? {
        let parts = recordID.recordName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func isSyncableRecordID(_ recordID: CKRecord.ID) -> Bool {
        guard let metadata = recordMetadata(for: recordID) else { return true }
        if metadata.recordType == RecordType.playlist,
           AppleMusicLibraryService.isAppleMusicMirrorPlaylist(metadata.localID) {
            return false
        }
        return true
    }

    private func pendingRecordID(from change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            return recordID
        @unknown default:
            return nil
        }
    }

    private func dropPendingRecordZoneChanges(for recordID: CKRecord.ID, syncEngine: CKSyncEngine) {
        syncEngine.state.remove(pendingRecordZoneChanges: [
            .saveRecord(recordID),
            .deleteRecord(recordID)
        ])
        removeSystemFields(for: recordID)
    }

    private func filteredPendingRecordZoneChanges(
        _ changes: [CKSyncEngine.PendingRecordZoneChange],
        syncEngine: CKSyncEngine
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        var kept: [CKSyncEngine.PendingRecordZoneChange] = []
        var dropped: [CKSyncEngine.PendingRecordZoneChange] = []

        for change in changes {
            guard let recordID = pendingRecordID(from: change) else {
                kept.append(change)
                continue
            }
            if isSyncableRecordID(recordID) {
                kept.append(change)
            } else {
                dropped.append(change)
            }
        }

        if !dropped.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: dropped)
            for change in dropped {
                if let recordID = pendingRecordID(from: change) {
                    removeSystemFields(for: recordID)
                }
            }
            plog("CloudKitSync: dropped \(dropped.count) stale Apple Music mirror pending change(s)")
        }

        return kept
    }

    /// On first start, push everything we have locally. Soft-deleted sources /
    /// cloud accounts are enqueued as CloudKit deletes, not payload saves, so
    /// stale server rows cannot resurrect them after a reinstall.
    private func scheduleInitialUpload() {
        playlistsChanged(ids: library.allPlaylists.map(\.id))
        smartPlaylistsChanged(ids: library.allSmartPlaylists.map(\.id))
        sourcesChanged(ids: sourcesStore.allSources.map(\.id))
        cloudAccountsChanged(ids: sourcesStore.allAccounts.map(\.id))
        scraperConfigsChanged(ids: scraperConfigStore.allConfigsIncludingDeleted.map(\.id))
        // Push history at startup too (bypass the 5-min throttle, but still
        // honour the channel toggle).
        if CloudSyncChannel.isEnabled(.playbackHistory) {
            enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
        }
        if CloudSyncChannel.isEnabled(.listeningStats) {
            enqueueSaves(recordType: RecordType.listeningStats, ids: [Self.listeningStatsRecordName])
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

    /// Shared engine 的 state 文件单独存, 跟 private engine 的 fetch cursor 不冲突。
    private var sharedStateURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("cloudkit-shared-engine-state.bin")
    }

    private func loadSharedStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: sharedStateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    fileprivate func saveSharedStateSerialization(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: sharedStateURL, options: .atomic)
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

    /// systemFieldsCache 的 key。必须带上 ownerName + zoneName: 同一条 record 在
    /// 启用/关闭家庭共享时会在 PrimuseSync ↔ PrimuseFamily 之间迁移, 只用
    /// recordName 做 key 会让两个 zone 的同 id 记录共用一个 etag 槽。
    private nonisolated static func systemFieldsKey(for recordID: CKRecord.ID) -> String {
        "\(recordID.zoneID.ownerName)|\(recordID.zoneID.zoneName)|\(recordID.recordName)"
    }

    private nonisolated static func legacySystemFieldsKeys(for recordID: CKRecord.ID) -> [String] {
        [
            "\(recordID.zoneID.zoneName)/\(recordID.recordName)",
            recordID.recordName
        ]
    }

    /// 把 `record` 的 system fields(含 changeTag/etag)序列化下来,以便下次
    /// 重建 CKRecord 时复用。CKSyncEngine 必须看到带 changeTag 的 record 才会
    /// 把 saveRecord 翻译成 update,否则 server 直接拒。
    fileprivate func storeSystemFields(_ record: CKRecord) {
        loadSystemFieldsCacheIfNeeded()
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let data = coder.encodedData
        let key = Self.systemFieldsKey(for: record.recordID)
        var removedLegacy = false
        for legacyKey in Self.legacySystemFieldsKeys(for: record.recordID) {
            removedLegacy = (systemFieldsCache.removeValue(forKey: legacyKey) != nil) || removedLegacy
        }
        if systemFieldsCache[key] != data || removedLegacy {
            systemFieldsCache[key] = data
            persistSystemFieldsCache()
        }
    }

    fileprivate func removeSystemFields(for recordID: CKRecord.ID) {
        loadSystemFieldsCacheIfNeeded()
        var removed = systemFieldsCache.removeValue(forKey: Self.systemFieldsKey(for: recordID)) != nil
        for legacyKey in Self.legacySystemFieldsKeys(for: recordID) {
            removed = (systemFieldsCache.removeValue(forKey: legacyKey) != nil) || removed
        }
        if removed {
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
        let keys = [Self.systemFieldsKey(for: recordID)] + Self.legacySystemFieldsKeys(for: recordID)
        for key in keys {
            guard let data = systemFieldsCache[key],
                  let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
                continue
            }
            // A corrupted/stale CloudKit system-fields archive must be a cache
            // miss, not an uncaught Objective-C exception. The default policy
            // is `.raiseException`, which bypasses Swift's `try?`/`do-catch`.
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            unarchiver.requiresSecureCoding = true
            let record = CKRecord(coder: unarchiver)
            unarchiver.finishDecoding()
            guard unarchiver.error == nil,
                  let record,
                  Self.sameRecordID(record.recordID, recordID) else {
                continue
            }
            return record
        }
        return nil
    }

    private nonisolated static func sameRecordID(_ lhs: CKRecord.ID, _ rhs: CKRecord.ID) -> Bool {
        lhs.recordName == rhs.recordName
            && lhs.zoneID.zoneName == rhs.zoneID.zoneName
            && lhs.zoneID.ownerName == rhs.zoneID.ownerName
    }

    // MARK: - Record (de)serialization

    fileprivate func populateRecord(_ record: CKRecord, recordType: String, id: String) -> Bool {
        switch recordType {
        case RecordType.playlist:
            return populatePlaylistRecord(record, playlistID: id)
        case RecordType.smartPlaylist:
            return populateSmartPlaylistRecord(record, smartPlaylistID: id)
        case RecordType.musicSource:
            return populateSourceRecord(record, sourceID: id)
        case RecordType.cloudAccount:
            return populateCloudAccountRecord(record, accountID: id)
        case RecordType.scraperConfig:
            return populateScraperConfigRecord(record, configID: id)
        case RecordType.playbackHistory:
            return populatePlaybackHistoryRecord(record)
        case RecordType.listeningStats:
            return populateListeningStatsRecord(record)
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
        case RecordType.smartPlaylist:
            applySmartPlaylistRecord(record)
        case RecordType.musicSource:
            applySourceRecord(record)
        case RecordType.cloudAccount:
            applyCloudAccountRecord(record)
        case RecordType.scraperConfig:
            applyScraperConfigRecord(record)
        case RecordType.playbackHistory:
            applyPlaybackHistoryRecord(record)
        case RecordType.listeningStats:
            applyListeningStatsRecord(record)
        default:
            break
        }
    }

    fileprivate func applyRemoteDeletion(
        recordID: CKRecord.ID,
        recordType: String,
        allowLocalRestore: Bool = false
    ) {
        // record 已经从 server 移除,缓存里的 changeTag 也没用了。
        removeSystemFields(for: recordID)

        if let channel = Self.channel(for: recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        guard let id = parseLocalID(from: recordID, recordType: recordType) else { return }
        if recordType == RecordType.playlist,
           AppleMusicLibraryService.isAppleMusicMirrorPlaylist(id) {
            return
        }

        // Only protect a local restore while resolving a save failure. A
        // fetched CloudKit deletion is authoritative remote state; treating
        // every active local row as "restored" re-pushes stale sources and
        // makes deletions appear to come back.
        if allowLocalRestore, isLocallyRestored(recordType: recordType, id: id) {
            if let engine {
                addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: engine)
            }
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        switch recordType {
        case RecordType.playlist:
            library.deletePlaylistFromRemote(id: id)
        case RecordType.smartPlaylist:
            library.deleteSmartPlaylistFromRemote(id: id)
        case RecordType.musicSource:
            sourcesStore.removeFromRemote(id: id)
        case RecordType.cloudAccount:
            sourcesStore.removeAccountFromRemote(id: id)
        case RecordType.scraperConfig:
            scraperConfigStore.deleteFromRemote(id: id)
        case RecordType.playbackHistory:
            library.clearPlaybackHistory()
        case RecordType.listeningStats:
            PlayHistoryStore.shared.clearFromRemote()
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
            if AppleMusicLibraryService.isAppleMusicMirrorPlaylist(id) { return false }
            return library.allPlaylists.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.smartPlaylist:
            return library.allSmartPlaylists.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
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
        guard !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlistID) else { return false }
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
        guard !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(id) else { return }
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

    // MARK: - Smart playlist mapping
    //
    // 比 Playlist 简单 ── 只存定义不存歌曲列表, 把整份 SmartPlaylist 编码成 JSON
    // 塞进单个 `payload` 字段, 不需要拆字段也不需要 song identity 解析。
    // 不同设备的 PlayHistoryStore 不同步, 同一份规则会得到不同结果, 这是设计选择。

    private func populateSmartPlaylistRecord(_ record: CKRecord, smartPlaylistID id: String) -> Bool {
        guard let smart = library.allSmartPlaylists.first(where: { $0.id == id }) else { return false }
        do {
            let data = try JSONEncoder().encode(smart)
            record["payload"] = data
            record["updatedAt"] = smart.updatedAt
            return true
        } catch {
            plog("CloudKitSync: encode smartPlaylist failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applySmartPlaylistRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let smart = try? JSONDecoder().decode(SmartPlaylist.self, from: data) else { return }
        library.applyRemoteSmartPlaylist(smart)
    }

    // MARK: - Music source mapping

    private func populateSourceRecord(_ record: CKRecord, sourceID: String) -> Bool {
        guard let source = sourcesStore.allSources.first(where: { $0.id == sourceID }),
              !source.isDeleted else { return false }
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
        var source = syncable.source
        // Older records may still contain a Synology trusted-device token.
        // Never import it onto a different physical device.
        source.deviceId = nil
        sourcesStore.upsertFromRemote(source)
    }

    // MARK: - Cloud account mapping

    private func populateCloudAccountRecord(_ record: CKRecord, accountID: String) -> Bool {
        guard let account = sourcesStore.allAccounts.first(where: { $0.id == accountID }),
              !account.isDeleted else { return false }
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

    // MARK: - Listening stats mapping

    /// CloudKit 单字段 ~1MB 上限, 留余量。听歌历史最多 5000 条, 原始 JSON 接近上限,
    /// gzip 后约 100-200KB —— 内联压缩既稳过限又向后兼容。
    private static let statsInlineLimit = 900_000

    private func populateListeningStatsRecord(_ record: CKRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var entries = PlayHistoryStore.shared.entriesForSync
        guard var payload = Self.encodeStatsPayload(entries, encoder: encoder) else { return false }
        if payload.count > Self.statsInlineLimit {
            // 几乎不可能(gzip 后远小于上限), 但仍兜底: 只保留最近条目再压。
            // entries 为最新在前, prefix 即保留最近的。
            entries = Array(entries.prefix(2000))
            guard let trimmed = Self.encodeStatsPayload(entries, encoder: encoder),
                  trimmed.count <= Self.statsInlineLimit else {
                plog("⚠️ Listening stats payload still over limit after trim — skipping sync")
                return false
            }
            payload = trimmed
        }
        record["payloadGz"] = payload as CKRecordValue
        // 清掉旧的未压缩字段, 避免更新既有记录时残留的超大 payload 把记录顶过 1MB。
        record["payload"] = nil
        record["entryCount"] = entries.count
        record["updatedAt"] = Date()
        return true
    }

    private static func encodeStatsPayload(_ entries: [PlayHistoryStore.Entry], encoder: JSONEncoder) -> Data? {
        guard let data = try? encoder.encode(entries) else { return nil }
        return try? (data as NSData).compressed(using: .zlib) as Data
    }

    private func applyListeningStatsRecord(_ record: CKRecord) {
        guard let entries = decodeListeningStatsEntries(record) else { return }
        PlayHistoryStore.shared.mergeRemoteEntries(entries)
    }

    private func decodeListeningStatsEntries(_ record: CKRecord) -> [PlayHistoryStore.Entry]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let gzField = record["payloadGz"] as? Data {
            // CloudKit 返回的 Data 可能是非连续 backing, 先强制连续拷贝再解压。
            let gz = Data(gzField)
            guard let raw = try? (gz as NSData).decompressed(using: .zlib) as Data else { return nil }
            return try? decoder.decode([PlayHistoryStore.Entry].self, from: raw)
        }
        // 向后兼容旧记录的未压缩 payload。
        guard let data = record["payload"] as? Data else { return nil }
        return try? decoder.decode([PlayHistoryStore.Entry].self, from: data)
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
            await MainActor.run {
                // private engine 跟 sharedEngine state 分开存, 否则下次启动
                // 一个 engine 用错 state cursor 会重 fetch 全量。
                if syncEngine === self.sharedEngine {
                    self.saveSharedStateSerialization(event.stateSerialization)
                } else {
                    self.saveStateSerialization(event.stateSerialization)
                }
            }
        case .fetchedRecordZoneChanges(let event):
            for modification in event.modifications {
                await MainActor.run { self.applyRemoteRecord(modification.record) }
            }
            for deletion in event.deletions {
                await MainActor.run {
                    self.applyRemoteDeletion(
                        recordID: deletion.recordID,
                        recordType: deletion.recordType,
                        allowLocalRestore: false
                    )
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
        case .willFetchChanges, .willFetchRecordZoneChanges,
             .willSendChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .didSendChanges:
            // Lifecycle markers — useful for debugging but no action needed.
            break
        @unknown default:
            let description = String(describing: event)
            if description.contains("WillFetchRecordZoneChanges")
                || description.contains("DidFetchRecordZoneChanges") {
                break
            }
            plog("CloudKitSync: unhandled engine event \(description)")
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let scopedPending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let filtered = await MainActor.run {
            self.filteredPendingRecordZoneChanges(scopedPending, syncEngine: syncEngine)
        }
        let pending = Self.coalescedRecordZoneChanges(filtered)
        if pending.count != filtered.count {
            Self.replacePendingRecordZoneChanges(
                with: pending,
                in: syncEngine,
                scopeFilter: { scope.contains($0) }
            )
        }

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
        let ckError = failed.error

        switch ckError.code {
        case .serverRecordChanged:
            resolveServerRecordChanged(local: failed.record, error: ckError, syncEngine: syncEngine)
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and try again.
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
            addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: syncEngine)
        case .unknownItem:
            // Server-side record went away (deleted on another device). Mirror
            // that locally so the two sides line up.
            applyRemoteDeletion(recordID: recordID, recordType: failed.record.recordType, allowLocalRestore: true)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Engine retries automatically; honor any explicit retry-after.
            if let retry = ckError.retryAfterSeconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(retry))
                    self.addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: syncEngine)
                }
            }
        case .quotaExceeded:
            status = .quotaExceeded
        case .notAuthenticated:
            status = .accountUnavailable(.noAccount)
        case .invalidArguments:
            // CKError 12, 常见信息 "You can't save the same record twice" — 同一
            // 条 record 在一次 send 周期里被重复保存(引擎自动重试 + 冲突处理手动
            // 重排叠加)。把这条多余的 pending 丢掉打断死循环, 并清掉可能已失真的
            // system fields; 下次本地真有改动时会带新的 changeTag 干净地重传。
            // 不在此处立即重排, 否则可能与引擎自身重试再次撞车形成新循环。
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            removeSystemFields(for: recordID)
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
            addCoalescedRecordZoneChanges([.saveRecord(local.recordID)], to: syncEngine)
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
        case RecordType.listeningStats:
            mergeListeningStatsRecord(local: local, server: server)
        default:
            // MusicSource / ScraperConfig: payload is atomic, LWW on updatedAt.
            let localUpdated = (local["updatedAt"] as? Date) ?? .distantPast
            let serverUpdated = (server["updatedAt"] as? Date) ?? .distantPast
            if serverUpdated >= localUpdated {
                applyRemoteRecord(server)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
                return  // local save dropped
            }
            // Local wins: keep our store as-is and re-push.
        }

        // Re-enqueue so engine picks up the merged local state with server's
        // changeTag.
        addCoalescedRecordZoneChanges([.saveRecord(local.recordID)], to: syncEngine)
    }

    @MainActor
    private func mergePlaylistRecord(local: CKRecord, server: CKRecord) {
        guard let id = parseLocalID(from: server.recordID, recordType: RecordType.playlist) else { return }
        guard !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(id) else {
            enqueueDeletes(recordType: RecordType.playlist, ids: [id])
            return
        }

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
    private func mergeListeningStatsRecord(local: CKRecord, server: CKRecord) {
        let localEntries = decodeListeningStatsEntries(local) ?? []
        let serverEntries = decodeListeningStatsEntries(server) ?? []

        applyRemoteEnvelope {
            PlayHistoryStore.shared.mergeRemoteEntries(localEntries + serverEntries)
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
        guard isSyncableRecordID(recordID),
              let metadata = recordMetadata(for: recordID) else {
            return nil
        }
        let recordType = metadata.recordType
        let localID = metadata.localID
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
            try? FileManager.default.removeItem(at: sharedStateURL)
            clearSystemFieldsCache()
            didCompleteInitialUpload = false
            isParticipantOfShare = false
            Self.familySharingEnabled = false
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

/// Sources are written to CloudKit minus their device-local fields
/// (`lastScannedAt`, `songCount`, `deviceId`) so a freshly-synced device
/// doesn't inherit stale scan state or another device's NAS trust token.
private struct SyncableSource: Codable {
    var source: MusicSource

    init(source: MusicSource) {
        var copy = source
        copy.lastScannedAt = nil
        copy.songCount = 0
        copy.deviceId = nil
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
