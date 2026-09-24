import CloudKit
import Foundation
import PrimuseKit
import SwiftUI

enum CloudSyncStatus: Equatable, Sendable {
    case disabled
    /// The running binary has no usable CloudKit entitlement (simulator,
    /// linker-signed preview, or ad-hoc QA build). This is a build capability,
    /// not an account or synchronization failure.
    case unavailableInBuild
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

private struct CloudSchemaNotDeployedSyncError: LocalizedError, Sendable {
    let gap: CloudSchemaDeploymentPolicy.Gap

    var errorDescription: String? {
        PMString("icloud_cloud_schema_missing", gap.name)
    }
}

#if DEBUG
/// 开发脚本的 iCloud 同步测试场景(`scripts/primuse-dev.sh sync-test`), 只在 Debug 构建生效。
/// 由环境变量 `PRIMUSE_SYNC_TEST_SCENARIO` 或启动参数 `-PrimuseSyncTestScenario` 指定;
/// 两种都读, 是因为 devicectl 会把 App 的 `-xxx` 启动参数当成自己的选项吞掉。
enum SyncTestScenario: String {
    /// 模拟带着旧同步进度升级上来、或从备份恢复的设备。
    case upgradeReset = "upgrade-reset"

    static let current: SyncTestScenario? = {
        let raw = ProcessInfo.processInfo.environment["PRIMUSE_SYNC_TEST_SCENARIO"]
            ?? UserDefaults.standard.string(forKey: "PrimuseSyncTestScenario")
        guard let raw, !raw.isEmpty else { return nil }
        guard let scenario = SyncTestScenario(rawValue: raw) else {
            plog("🧪 Unknown sync test scenario '\(raw)' ignored")
            return nil
        }
        plog("🧪 Sync test scenario requested: \(raw)")
        return scenario
    }()
}
#endif

/// Entity payloads flowing through CKSyncEngine. Each conforms to `Codable` so we can
/// stash them inside a single CKRecord blob field. This reduces schema churn, but each
/// record type and blob field still has to be deployed to CloudKit Production.
@MainActor
@Observable
final class CloudKitSyncService {
    nonisolated static let containerID = CloudKitRuntime.containerID
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
        static let radioStation = "RadioStation"
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
             RecordType.musicSource, RecordType.cloudAccount, RecordType.radioStation:
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
        // Playlist 类型按 id 例外: 「我喜欢」及它的封面规则每人独立。
        if recordType == RecordType.playlist {
            if id == MusicLibrary.likedSongsPlaylistID {
                return Self.zoneID
            }
            if let owner = LibraryArtworkOwner.fromCloudRecordID(id),
               owner.kind == .playlist,
               owner.id == MusicLibrary.likedSongsPlaylistID {
                return Self.zoneID
            }
        }
        // participant 写到所有者的共享 zone; 所有者写自己的 PrimuseFamily。
        return participantSharedZoneID ?? Self.familyZoneID
    }

    /// Singleton ID used for the playback-history record (one per user).
    static let playbackHistoryRecordName = "primuse.playbackHistory.singleton"
    /// Singleton ID used for full listening stats (one per user).
    static let listeningStatsRecordName = "primuse.listeningStats.singleton"

    // MARK: - Collaborators

    private let library: MusicLibrary
    private let sourcesStore: SourcesStore
    private let radioStationsStore: RadioStationsStore
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
    /// 缓存是整份字典一次编码写盘的。逐条记录都写一遍, 首次同步拉下 N 条记录
    /// 就要写 N 份越来越大的字典, 写入量随记录数平方增长 —— 新设备装好几分钟
    /// 就撞上系统的 1GB 写盘上限。所以改动只记账, 一批事件处理完再写一次。
    private var systemFieldsCacheNeedsPersist = false
    private var systemFieldsPersistTask: Task<Void, Never>?
    private static let systemFieldsPersistDelay: Duration = .seconds(2)
    /// 每次整份清空 system-fields 缓存都会 +1(退出登录/切换账号、云端 zone 被
    /// 删除后的重新播种)。缓存存的是「服务器已经接受的那份 etag」,清空之后
    /// 再被一台早已摘掉的 engine 用旧账号的 etag 填回去,下次登录就会拿别人的
    /// changeTag 去 save。
    private var systemFieldsCacheGeneration = 0
    /// 最近一次创建 engine 时的 `systemFieldsCacheGeneration`。两者相等说明
    /// 这台 engine 出生之后缓存没有被清过,它报回来的保存结果仍然可信。
    private var engineCacheGeneration = 0

    /// In-memory marker so callers know whether a remote update is currently being
    /// applied — local stores can bail out of their own `markChanged` loop.
    private(set) var isApplyingRemote = false

    /// Coalesces playback-history pushes to at most once per 5 minutes.
    private var pendingHistoryFlush: Task<Void, Never>?
    private var pendingListeningStatsFlush: Task<Void, Never>?
    /// Identifies the one armed flush that is allowed to cross the throttle
    /// sleep. `Task.sleep`'s cancellation error is swallowed by `try?`, so a
    /// task cancelled in `stop()` still resumes; without a token it would clear
    /// the handle a restarted service had just armed and push immediately.
    private var historyFlushToken: UUID?
    private var listeningStatsFlushToken: UUID?
    private static let historyThrottle: Duration = .seconds(300)

    /// The debounced radio-station snapshot upload, owned so `stop()` can take
    /// it down and so an import burst collapses into a single write.
    private var pendingRadioSnapshotUpload: Task<Void, Never>?
    private var radioSnapshotToken: UUID?
    private var radioSnapshotFirstPendingAt: ContinuousClock.Instant?
    /// 补传了待上传账本里的电台（见 `flushDeferredRadioStationChanges`），快照要等
    /// 下一次拉取成功、本机 radio-stations.json 已含拉到的记录之后再传。
    private var radioSnapshotAfterFetch = false

    /// Listening-stats payload precomputed by the throttled flush, keyed by the
    /// store revision it was built from. A miss simply encodes synchronously.
    private struct StatsPayload: Sendable {
        let payload: Data
        let entryCount: Int
    }
    private var statsPayloadCache: (revision: Int, payload: StatsPayload)?

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
    var isAvailableInCurrentBuild: Bool { CloudKitRuntime.canCreateContainer }

    /// Listens for `CKAccountChanged` so we can flip into `.accountUnavailable`
    /// when the user signs out of iCloud while the app is running.
    private var accountChangeObserver: NSObjectProtocol?

    /// Once-per-install flag: did we run `scheduleInitialUpload()` to seed
    /// CloudKit with everything that was already on disk before sync existed?
    /// CKSyncEngine's persisted state tracks per-record sync status after the
    /// first run, so re-uploading on every cold launch is wasteful.
    private static let initialUploadDoneKey = "primuse.cloudSync.initialUploadComplete"
    private static let sourceTypeFingerprintKey = "primuse.cloudSync.sourceTypeFingerprint"
    #if DEBUG
    /// 同一进程里 `start()` 可能被调多次(开关同步、换账号), 测试场景只模拟一次。
    private static var didApplySyncTestScenario = false
    #endif
    private var didCompleteInitialUpload: Bool {
        get { UserDefaults.standard.bool(forKey: Self.initialUploadDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.initialUploadDoneKey) }
    }
    /// Set by record-level callbacks when a send pass contains a failure that
    /// the app neither resolved nor expects CKSyncEngine to retry automatically.
    private var unresolvedRecordSaveError: String?

    // MARK: - Init

    init(
        library: MusicLibrary,
        sourcesStore: SourcesStore,
        radioStationsStore: RadioStationsStore,
        scraperConfigStore: ScraperConfigStore = .shared,
        scraperSettingsStore: ScraperSettingsStore
    ) {
        self.library = library
        self.sourcesStore = sourcesStore
        self.radioStationsStore = radioStationsStore
        self.scraperConfigStore = scraperConfigStore
        self.scraperSettingsStore = scraperSettingsStore
        #if os(tvOS)
        let appSupport = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = directory.appendingPathComponent("cloudkit-engine-state.bin")
        self.systemFieldsURL = directory.appendingPathComponent("cloudkit-system-fields.plist")
        if !CloudKitRuntime.canCreateContainer {
            self.status = .unavailableInBuild
        }
    }

    // MARK: - Lifecycle

    /// Bring the sync engine online. Reads previous engine state from disk if present,
    /// then does an initial fetch + sends any locally pending changes.
    func start() async {
        guard engine == nil, startAttemptID == nil else { return }
        guard CloudKitRuntime.canCreateContainer else {
            status = .unavailableInBuild
            return
        }
        preparePersistedStateForSupportedSourceTypes()
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
        self.engineCacheGeneration = systemFieldsCacheGeneration
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
        // 设置类键在总开关关着的时候只在本机记账; 引擎起来这一刻补齐两边。
        CloudKVSSync.shared.catchUp()

        migratePendingSourceDeletesToTombstoneSaves(in: engine)
        retryRememberedFailedSaves(in: engine)
        // Deletion evidence must be re-seeded on every start, independently of
        // the once-per-install initial-upload flag. A delete can be created
        // while sync or the sources channel is disabled.
        // 只补传服务器还没确认过的那一次删除: 已确认的也每次重传, 任何一台设备
        // 启动一次, 其它设备就得把全部墓碑(实测 40 条)再收一遍。
        sourcesChanged(ids: unacknowledgedSourceDeletionIDs())
        // 同步没在跑时本机改过的电台同理：每次 start 都补，与只做一次的首次上传无关。
        // 仍是先拉后推，拉到的远端改动按修改时间与补传的记录比较。
        flushDeferredRadioStationChanges()

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
            // 用户可能刚好在 fetch 期间关掉同步 / 切换账号。此时这条 pass 必须
            // 停在这里,不能再把本地数据推上去。
            guard self.engine === engine, startAttemptID == attemptID else { return }
            uploadDeferredRadioSnapshotIfNeeded()
            let drained = try await sendChangesResolvingRecoverableFailures(using: engine)
            plog("CloudKitSync: sendChanges OK")
            guard self.engine === engine, startAttemptID == attemptID else { return }
            // 只允许从未完成升为完成：已经做过的首次上传，不因这一轮补传的积压没传完
            // 就被改回未完成，下次启动再整份重传一遍。
            if drained { self.didCompleteInitialUpload = true }
            self.status = drained ? .upToDate : .syncing
            if drained { self.lastSyncedAt = Date() }
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

    /// participant 接受的那个 zone: zone 名是所有者的 PrimuseFamily, ownerName 是所有者
    /// 的 CloudKit 用户记录名。participant 的共享写入必须落到这个 zone(经
    /// sharedCloudDatabase), 而不是自己私有库里同名的 zone —— 以前就是写错了地方,
    /// 所有者永远看不到参与者的改动。
    @MainActor
    private static var participantSharedZoneID: CKRecordZone.ID? {
        get {
            guard let name = UserDefaults.standard.string(forKey: "primuse.familySharing.sharedZoneName"),
                  let owner = UserDefaults.standard.string(forKey: "primuse.familySharing.sharedZoneOwner") else {
                return nil
            }
            return CKRecordZone.ID(zoneName: name, ownerName: owner)
        }
        set {
            UserDefaults.standard.set(newValue?.zoneName, forKey: "primuse.familySharing.sharedZoneName")
            UserDefaults.standard.set(newValue?.ownerName, forKey: "primuse.familySharing.sharedZoneOwner")
        }
    }

    /// 某个 zone 的记录该由哪个引擎上传: participant 的共享 zone 走 sharedEngine, 其余走私有引擎。
    private func engine(for zoneID: CKRecordZone.ID) -> CKSyncEngine? {
        if let shared = Self.participantSharedZoneID, zoneID == shared { return sharedEngine }
        return engine
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
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "cloudkit_unavailable")])
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

        // 2. 已有 zone 级 share 就复用(用户重复点、重装后再点都走这里)。
        let zoneShareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.familyZoneID)
        if let existing = try? await db.record(for: zoneShareID) as? CKShare {
            Self.familySharingEnabled = true
            isParticipantOfShare = false
            plog("☁️ Family sharing reuse existing zone share")
            return existing
        }

        // 3. 旧版本按根记录建的 share 只共享 holder 那一条: zone 里的歌单、源、电台
        //    都没有 parent 引用, 参与者什么都收不到。一个 zone 不能同时有记录级
        //    share 和 zone 级 share, 先把旧的拆掉(参与者要重新接受一次邀请)。
        let holderID = CKRecord.ID(recordName: "primuse.family.holder", zoneID: Self.familyZoneID)
        if (try? await db.record(for: holderID)) != nil {
            _ = try? await db.deleteRecord(withID: holderID)
            plog("☁️ Family sharing removed the legacy root-record share")
        }

        // 4. 整个 zone 共享: zone 里现在和将来的每条记录参与者都能读写。
        let share = CKShare(recordZoneID: Self.familyZoneID)
        share[CKShare.SystemFieldKey.title] = "Primuse Family" as CKRecordValue
        share.publicPermission = .none
        try await saveFamilyRecords([share], in: db)

        Self.familySharingEnabled = true
        isParticipantOfShare = false

        // migration: shareable record 重新 push, recordID 算到 family zone
        scheduleInitialUpload()
        plog("☁️ Family sharing enabled, zone share created")
        return share
    }

    private func saveFamilyRecords(_ records: [CKRecord], in database: CKDatabase) async throws {
        do {
            let (results, _) = try await database.modifyRecords(
                saving: records,
                deleting: []
            )
            for (_, result) in results {
                if case .failure(let error) = result { throw error }
            }
        } catch {
            throw Self.userFacingCloudError(error)
        }
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
            // zone 级 share 删掉即停止共享; 旧版本的 holder(连同它的 share)一并清。
            let zoneShareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.familyZoneID)
            _ = try? await db.deleteRecord(withID: zoneShareID)
            let holderID = CKRecord.ID(recordName: "primuse.family.holder",
                                        zoneID: Self.familyZoneID)
            _ = try? await db.deleteRecord(withID: holderID)
        }
        Self.familySharingEnabled = false
        isParticipantOfShare = false
        Self.participantSharedZoneID = nil
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
        // 之后本机的共享类型记录都写到所有者的这个 zone。
        Self.participantSharedZoneID = metadata.share.recordID.zoneID
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
        engineCacheGeneration = systemFieldsCacheGeneration
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
        guard let container = CloudKitRuntime.makeContainer() else {
            status = .unavailableInBuild
            return nil
        }
        self.container = container
        return container
    }

    func containerForSharingController() -> CKContainer? {
        configuredContainer()
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
                } else if !self.isStarted, self.startAttemptID == nil,
                          CloudSyncChannel.isMasterEnabled() {
                    // 账号短暂不可用时 stop() 过一次; 恢复了就自己起来, 以前要等
                    // 用户重开开关或重启 app, 期间推送来了也只是空转。
                    await self.start()
                }
            }
        }
    }

    /// Tear down the engine. Local data is left intact.
    func stop(updateStatus: Bool = true) {
        startAttemptID = nil
        pendingHistoryFlush?.cancel()
        pendingHistoryFlush = nil
        historyFlushToken = nil
        pendingListeningStatsFlush?.cancel()
        pendingListeningStatsFlush = nil
        listeningStatsFlushToken = nil
        pendingRadioSnapshotUpload?.cancel()
        pendingRadioSnapshotUpload = nil
        radioSnapshotToken = nil
        radioSnapshotFirstPendingAt = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        // 账号观察者留着: 它是账号恢复可用时把引擎重新拉起来的唯一入口, 拆了
        // 就只能等用户重开开关。总开关关着时它什么都不做。
        // 引擎摘掉之后不会再有批末落盘, 攒着的现在写掉。
        flushCoalescedRemoteWrites()
        engine = nil
        sharedEngine = nil
        isStarted = false
        if updateStatus {
            status = CloudKitRuntime.canCreateContainer ? .disabled : .unavailableInBuild
        }
    }

    /// Re-enqueue every local entity belonging to a channel. Use this when a
    /// channel is toggled from off → on so edits made while it was off get
    /// caught up. Cheap because CKSyncEngine de-dupes against server change tags.
    ///
    /// 通道关着的时候, 拉到的记录被原样跳过、游标却照样往前走了。所以先丢掉游标
    /// 全量重拉一遍, 让别的设备在这期间的改动先落地; 再把本机实体补推时, 和服务器
    /// 相同的会被撤掉, 更旧的已经被拉回来的版本盖掉 —— 以前是直接整份推, 本机的
    /// 旧副本带着最新的 changeTag 无冲突地盖掉服务器上更新的记录。
    func catchUp(channel: CloudSyncChannel) async {
        guard isStarted else { return }
        await refetchEverythingBeforeCatchUp()
        guard isStarted else { return }
        enqueueLocalEntities(for: channel)
        await syncNow()
    }

    /// 总开关从关到开: 引擎停着的时候观察者也被拆了, 这期间的本机改动没人记。
    /// 起来之后把每个开着的通道的本机实体都补推一遍; 游标没动过, 不必重拉。
    func startAfterUserEnabledSync() async {
        await start()
        guard isStarted else { return }
        for channel in CloudSyncChannel.allCases where CloudSyncChannel.isEnabled(channel) {
            enqueueLocalEntities(for: channel)
        }
        await syncNow()
    }

    private func refetchEverythingBeforeCatchUp() async {
        guard let engine else { return }
        // 先把在途的待传送完: 状态文件里还有别的通道的待传, 直接删会把它们一起丢掉。
        let drained = (try? await sendChangesResolvingRecoverableFailures(using: engine)) ?? false
        guard self.engine === engine else { return }
        guard drained, engine.state.pendingRecordZoneChanges.isEmpty else {
            plog("CloudKitSync: catch-up keeps the cursor — pending changes could not be drained first")
            return
        }
        stop(updateStatus: false)
        for url in [stateURL, sharedStateURL] {
            try? FileManager.default.removeItem(at: url)
        }
        plog("CloudKitSync: catch-up dropped the fetch cursor, refetching everything")
        await start()
    }

    private func enqueueLocalEntities(for channel: CloudSyncChannel) {
        switch channel {
        case .playlists:
            playlistsChanged(ids: library.allPlaylists.map(\.id))
            artworkOverridesChanged(ids: library.allArtworkOverrides.map(\.cloudRecordID))
            smartPlaylistsChanged(ids: library.allSmartPlaylists.map(\.id))
        case .sources:
            sourcesChanged(ids: sourceIDsForCatchUp())
            // 电台逐条同步，不全量重传；只补通道关着时本机改过的那些。
            flushDeferredRadioStationChanges()
        case .playbackHistory:
            enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
        case .listeningStats:
            enqueueSaves(recordType: RecordType.listeningStats, ids: [Self.listeningStatsRecordName])
        case .settings:
            scraperConfigsChanged(ids: scraperConfigStore.allConfigsIncludingDeleted.map(\.id))
            // KVS 镜像的键逐个按修订号比对: 云端新的拉下来, 本机在关着时改过的
            // 推上去。以前是不看云端就整份推, 一台没改过设置的设备打开开关就把
            // 别的设备的设置全盖掉, 本机没值的键还会推成删除。
            CloudKVSSync.shared.catchUp()
        case .credentials:
            // Past Keychain entries are governed by the system iCloud Keychain
            // toggle — nothing for us to push from here.
            break
        }
    }

    /// Force a fetch + send pass (used by the "Sync now" action).
    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            // 同上:stop() 之后这条 pass 既不能继续上传,也不能把 `.disabled`
            // 状态改回来。
            guard self.engine === engine else { return }
            uploadDeferredRadioSnapshotIfNeeded()
            let drained = try await sendChangesResolvingRecoverableFailures(using: engine)
            guard self.engine === engine else { return }
            status = drained ? .upToDate : .syncing
            if drained { lastSyncedAt = Date() }
        } catch {
            guard self.engine === engine else { return }
            status = mapToSyncStatus(error)
        }
    }

    /// `sendChanges()` may throw a top-level partial failure even when every
    /// per-record error is recoverable. Repair those entries immediately, then
    /// give the engine one clean retry so startup doesn't leave sync looking
    /// failed after a harmless "record already exists" conflict.
    private func sendChangesResolvingRecoverableFailures(using engine: CKSyncEngine) async throws -> Bool {
        unresolvedRecordSaveError = nil
        do {
            try await engine.sendChanges()
        } catch {
            guard resolveRecoverablePartialFailure(error, syncEngine: engine) else {
                throw error
            }
            plog("CloudKitSync: resolved recoverable send conflicts, retrying sendChanges()")
            unresolvedRecordSaveError = nil
            try await engine.sendChanges()
        }
        if let unresolvedRecordSaveError {
            throw CloudSyncSendError.unresolvedRecordFailure(unresolvedRecordSaveError)
        }
        return engine.state.pendingRecordZoneChanges.isEmpty
    }

    private enum CloudSyncSendError: LocalizedError {
        case unresolvedRecordFailure(String)

        var errorDescription: String? {
            switch self {
            case .unresolvedRecordFailure(let detail):
                return String(
                    format: String(localized: "error_cloudkit_record_upload %@"),
                    detail
                )
            }
        }
    }

    private static func schemaError(
        in error: any Error
    ) -> CloudSchemaNotDeployedSyncError? {
        guard let gap = CloudSchemaDeploymentPolicy.gap(in: error) else { return nil }
        return CloudSchemaNotDeployedSyncError(gap: gap)
    }

    private static func userFacingCloudError(_ error: any Error) -> any Error {
        schemaError(in: error) ?? error
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
            // A missing Production schema is also CKError 12, but unlike a
            // duplicate save it must stay pending so it can succeed after the
            // server schema is deployed.
            guard Self.schemaError(in: error) == nil else { return false }
            dropPendingRecordZoneChanges(for: recordID, syncEngine: syncEngine)
            return true
        case .unknownItem:
            if let recordType = recordMetadata(for: recordID)?.recordType {
                resolveUnknownItem(recordID: recordID, recordType: recordType, syncEngine: syncEngine)
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
        #if os(tvOS)
        plog("TV cloud synchronization failed: \(message)")
        #else
        Task { @MainActor in
            await UserNotificationService.shared.postError(
                category: .cloudSyncFailed,
                title: title,
                body: message
            )
        }
        #endif
    }

    private func mapToSyncStatus(_ error: any Error) -> CloudSyncStatus {
        if let schemaError = Self.schemaError(in: error) {
            didCompleteInitialUpload = false
            return .error(schemaError.localizedDescription)
        }
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
            // 逐条失败已经在 `handleFailedSave` 里各自记下重试, 不再整库重传。
            return .error("CloudKit partial upload failure: \(ckError.localizedDescription)")
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

    /// True when the posting store was applying a record fetched from CloudKit
    /// rather than a user edit. Read synchronously inside the observer block —
    /// it must not depend on when the follow-up main-actor task runs.
    nonisolated private static func notificationCameFromRemote(_ note: Notification) -> Bool {
        (note.userInfo?["origin"] as? String) == "remote"
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
        observerTokens.append(nc.addObserver(forName: .primuseArtworkOverridesDidChange, object: nil, queue: .main) { [weak self] note in
            // 与 `.primuseSourcesDidChange` 同理: 刚落地的远端封面覆盖不能再
            // 入队保存, 否则两台设备会围着同一条记录来回推送。
            guard !Self.notificationCameFromRemote(note) else { return }
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.artworkOverridesChanged(ids: ids) }
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
            // `isApplyingRemote` only covers direct calls: the observer's
            // `Task { @MainActor }` runs after the current main-actor job, i.e.
            // after the flag was reset, so a record we just fetched would be
            // enqueued again as a save and ping-pong between devices forever.
            // The origin the store carries survives that hop.
            guard !Self.notificationCameFromRemote(note) else { return }
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.sourcesChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSourceDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.sourceDeleted(id: id) }
        })
        // Soft and permanent delete both publish the same durable tombstone
        // payload. The independent deletion ledger keeps it available even
        // after the user-facing row is pruned.
        observerTokens.append(nc.addObserver(forName: .primuseSourceDidSoftDelete, object: nil, queue: .main) { [weak self] note in
            // A tombstone that arrived from CloudKit must not be re-saved; the
            // durable cleanup journal in AppServices still observes this signal
            // and keeps its own catch-up behaviour.
            guard !Self.notificationCameFromRemote(note) else { return }
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
        observerTokens.append(nc.addObserver(forName: .primuseRadioStationsDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.radioStationsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseRadioStationDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.radioStationDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseRadioStationDidPurge, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.radioStationsPurged(ids: ids) }
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
        observerTokens.append(nc.addObserver(forName: .primuseListeningStatsDidChange, object: nil, queue: .main) { [weak self] note in
            // 远端并进来的那批同样广播这条通知; `isApplyingRemote` 在这个 Task 跑到
            // 时早已复位, 只能靠 origin 挡住, 否则每台设备都把整份统计再传一遍。
            guard !Self.notificationCameFromRemote(note) else { return }
            Task { @MainActor in self?.listeningStatsChanged() }
        })
    }

    // MARK: - Local-change hooks (called by stores after they persist locally)

    func playlistsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        // Mirror playlists (Apple Music, server libraries) are regenerated
        // locally from each device's own copy of the external library. Keeping
        // them in Primuse CloudKit creates stale, empty, or duplicate playlists
        // on devices that cannot resolve that library — and worse, such a device
        // would push the emptied playlist back. Existing mirrors are deleted
        // from CloudKit to clean up older builds that used to sync them.
        let syncable = ids.filter { !MirrorPlaylistIdentity.isMirrorPlaylist($0) }
        let mirrorIDs = ids.filter { MirrorPlaylistIdentity.isMirrorPlaylist($0) }
        enqueueSaves(recordType: RecordType.playlist, ids: syncable)
        enqueueDeletes(recordType: RecordType.playlist, ids: mirrorIDs)
    }

    func playlistDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(id) else { return }
        enqueueDeletes(recordType: RecordType.playlist, ids: [id])
    }

    func artworkOverridesChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        let validIDs = ids.filter { LibraryArtworkOwner.fromCloudRecordID($0) != nil }
        enqueueSaves(recordType: RecordType.playlist, ids: validIDs)
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
        // A source deletion is a durable tombstone payload, not a record
        // removal. Keeping that payload on the server lets a reset cursor or a
        // newly installed device distinguish deletion from local absence.
        enqueueSaves(recordType: RecordType.musicSource, ids: resolved.deleted)
    }

    func sourceDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        let resolved = resolveSourceIDsForSync([id])
        enqueueSaves(recordType: RecordType.musicSource, ids: resolved.deleted)
    }

    @discardableResult
    func enqueueSourceTombstoneForCleanup(id: String) -> Bool {
        guard isStarted,
              CloudSyncChannel.isEnabled(.sources),
              let tombstone = sourcesStore.sourceDeletionRecord(id: id)?.tombstone,
              MusicSourceCloudSyncPolicy.isEligible(tombstone) else { return false }
        enqueueSaves(recordType: RecordType.musicSource, ids: [id])
        return true
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

    func radioStationsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueRadioStationRecords(ids: ids)
        scheduleRadioSnapshotUpload()
        // 真交给了正在运行的引擎才销账。引擎没起来、或者这是 stop() 之后才跑到的
        // 观察者任务，id 留在账本里，等下一次 start / catchUp 补传。
        if canEnqueueRecordChanges { radioStationsStore.clearCloudPending(ids) }
    }

    /// 补传同步没在跑时（总开关或「音乐源」通道关着、Apple TV 引擎还没起来、引导早退）
    /// 本机改过的电台。只把记录交给引擎；快照要等这一轮拉取成功之后再传
    /// （`uploadDeferredRadioSnapshotIfNeeded`）—— 此刻本机文件还没追上远端，
    /// 现在传会把旧行写进 Apple TV 每次启动都要装的共享快照。
    private func flushDeferredRadioStationChanges() {
        let ids = radioStationsStore.cloudPendingStationIDs
        guard !ids.isEmpty, CloudSyncChannel.isEnabled(.sources) else { return }
        let sortedIDs = ids.sorted()
        plog("☁️ CloudKitSync: re-enqueueing \(sortedIDs.count) radio station change(s) made while sync was not running")
        enqueueRadioStationRecords(ids: sortedIDs)
        guard canEnqueueRecordChanges else { return }
        radioStationsStore.clearCloudPending(sortedIDs)
        radioSnapshotAfterFetch = true
    }

    /// 拉取成功之后补传一次电台快照。先把拉到、还攒在内存里的远端记录写进
    /// radio-stations.json，快照读的是这个文件。拉取失败不走到这里，留给下一次。
    private func uploadDeferredRadioSnapshotIfNeeded() {
        guard radioSnapshotAfterFetch else { return }
        radioSnapshotAfterFetch = false
        flushCoalescedRemoteWrites()
        scheduleRadioSnapshotUpload()
    }

    /// 通道关着时拉到的电台变更照样被消费了：etag 已存、游标已越过，重新打开后不会再送来。
    /// 账本里同一台的本机改动如果不比远端新，就不能再补传 —— 否则会盖掉较新的远端版本，
    /// 或者把别处删掉的台当成新台插回去。只清账本，不改本地数据。
    /// `serverUpdatedAt == nil` 表示远端删除，删除优先。
    private func supersedeDeferredRadioChange(recordID: CKRecord.ID, serverUpdatedAt: Date?) {
        guard let id = parseLocalID(from: recordID, recordType: RecordType.radioStation),
              radioStationsStore.cloudPendingStationIDs.contains(id) else { return }
        if let serverUpdatedAt,
           let local = radioStationsStore.allStations.first(where: { $0.id == id }),
           serverUpdatedAt < local.modifiedAt {
            return
        }
        radioStationsStore.clearCloudPending([id])
    }

    /// Per-station record sync on its own. This is the channel that carries an
    /// edit to other devices; the snapshot copy is a bootstrap convenience.
    private func enqueueRadioStationRecords(ids: [String]) {
        var active: [String] = []
        var deleted: [String] = []
        // 服务端目录一次对账就能改动几千个台,逐个 id 线性查找是平方级的。
        let stationsByID = Dictionary(
            radioStationsStore.allStations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in Set(ids) {
            guard stationsByID[id] != nil else { continue }
            // 墓碑也作为一条普通记录保存出去(以前普通删除走 CloudKit 删除): 记录
            // 带着删除时刻, 别的设备上一次更早的保存到了也盖不掉它, 删掉的台不会
            // 再复活。订阅的排除标记本来就是这么传的; 过了保留期的墓碑由清理流程
            // 真正删除记录。
            active.append(id)
        }
        enqueueSaves(recordType: RecordType.radioStation, ids: active)
        enqueueDeletes(recordType: RecordType.radioStation, ids: deleted)
    }

    /// Collapse a burst of station edits into one snapshot write. Re-arming
    /// cancels the previous task, so the last change is always the one that
    /// uploads, and the task stays owned so `stop()` can take it down.
    private func scheduleRadioSnapshotUpload() {
        guard RadioSnapshotUploadPolicy.shouldSchedule(
            isStarted: isStarted,
            isChannelEnabled: CloudSyncChannel.isEnabled(.sources)
        ) else { return }
        let token = UUID()
        let now = ContinuousClock.now
        // 第一次改动的时刻要留住: 用户连续编辑时每次都重新计时的话, 快照
        // 会被无限推后, 所以超过上限就不再等下一次改动了。
        let firstPending = radioSnapshotFirstPendingAt ?? now
        radioSnapshotFirstPendingAt = firstPending
        let delay = RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: firstPending.duration(to: now))
        radioSnapshotToken = token
        pendingRadioSnapshotUpload?.cancel()
        pendingRadioSnapshotUpload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            guard RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: self.isStarted,
                isCancelled: Task.isCancelled,
                currentToken: self.radioSnapshotToken,
                taskToken: token
            ) else { return }
            self.radioSnapshotFirstPendingAt = nil
            _ = await LibrarySnapshotSync.shared.uploadRadioStationsOnly()
            guard self.radioSnapshotToken == token else { return }
            self.radioSnapshotToken = nil
            self.pendingRadioSnapshotUpload = nil
        }
    }

    func radioStationDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        // 删除是一次带时间的保存(墓碑), 见 `enqueueRadioStationRecords`; 只有过了
        // 保留期的清理才真正删记录。
        enqueueRadioStationRecords(ids: [id])
    }

    /// 本机把过期墓碑清掉了: 现在才把记录从 CloudKit 删掉, 别的设备收到删除后
    /// 也把自己那条墓碑行清掉。
    func radioStationsPurged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueDeletes(recordType: RecordType.radioStation, ids: ids)
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

        let token = UUID()
        historyFlushToken = token
        pendingHistoryFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.historyThrottle)
            guard let self,
                  CloudFlushGate.shouldFlush(
                      isCancelled: Task.isCancelled,
                      currentToken: self.historyFlushToken,
                      taskToken: token
                  ) else { return }
            self.historyFlushToken = nil
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

        let token = UUID()
        listeningStatsFlushToken = token
        pendingListeningStatsFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.historyThrottle)
            guard let self,
                  CloudFlushGate.shouldFlush(
                      isCancelled: Task.isCancelled,
                      currentToken: self.listeningStatsFlushToken,
                      taskToken: token
                  ) else { return }
            // The whole history is encoded and compressed for the record. This
            // task owns a 5-minute budget, so do it here instead of leaving it
            // to the synchronous record build the sync engine asks for.
            //
            // 令牌要等这一段挂起结束之后再消费: 压缩期间如果同步被关掉再打开,
            // 这条已经退休的任务既不能把新任务的句柄清掉, 也不能往新引擎投递。
            await self.precomputeListeningStatsPayload()
            guard CloudFlushGate.shouldFlush(
                isCancelled: Task.isCancelled,
                currentToken: self.listeningStatsFlushToken,
                taskToken: token
            ) else { return }
            self.listeningStatsFlushToken = nil
            self.pendingListeningStatsFlush = nil
            self.enqueueSaves(
                recordType: RecordType.listeningStats,
                ids: [Self.listeningStatsRecordName]
            )
        }
    }

    /// Encode the listening-stats payload off the main actor and keep it keyed
    /// by the store revision it was built from. Anything that mutates the store
    /// afterwards makes the entry unusable, and `populateListeningStatsRecord`
    /// then falls back to encoding from live state.
    private func precomputeListeningStatsPayload() async {
        let store = PlayHistoryStore.shared
        let revision = store.revision
        let entries = store.entriesForSync
        let encoded = await Task.detached(priority: .utility) {
            Self.encodeTrimmedStatsPayload(entries)
        }.value
        guard let encoded, store.revision == revision else { return }
        statsPayloadCache = (revision: revision, payload: encoded)
    }

    private typealias SyncIDResolution = (active: [String], deleted: [String])

    private func resolveSourceIDsForSync(_ ids: [String]) -> SyncIDResolution {
        var seen = Set<String>()
        var active: [String] = []
        var deleted: [String] = []
        for id in ids where seen.insert(id).inserted {
            if let source = sourcesStore.allSources.first(where: { $0.id == id }) {
                guard MusicSourceCloudSyncPolicy.isEligible(source) else { continue }
                if source.isDeleted {
                    deleted.append(id)
                } else {
                    active.append(id)
                }
            } else if let tombstone = sourcesStore.sourceDeletionRecord(id: id)?.tombstone,
                      MusicSourceCloudSyncPolicy.isEligible(tombstone) {
                deleted.append(id)
            }
        }
        return (active, deleted)
    }

    private func sourceIDsForCatchUp() -> [String] {
        let storedIDs = sourcesStore.allSources
            .filter(MusicSourceCloudSyncPolicy.isEligible)
            .map(\.id)
        let tombstoneIDs: [String] = sourcesStore.sourceDeletionRecords.compactMap { record -> String? in
            guard let tombstone = record.tombstone,
                  MusicSourceCloudSyncPolicy.isEligible(tombstone) else { return nil }
            return record.id
        }
        return Array(Set(storedIDs + tombstoneIDs))
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
        case RecordType.radioStation: return .sources
        case RecordType.playbackHistory: return .playbackHistory
        case RecordType.listeningStats: return .listeningStats
        case RecordType.scraperConfig: return .settings
        default: return nil
        }
    }

    // MARK: - Internal helpers

    /// 现在入队的记录能不能真的交给引擎。入队和电台账本的销账用同一个判定，
    /// 不会出现没入队却销了账的情况。
    private var canEnqueueRecordChanges: Bool {
        engine != nil && isStarted && !isApplyingRemote
    }

    private func enqueueSaves(recordType: String, ids: [String]) {
        guard canEnqueueRecordChanges else { return }
        enqueue(ids.map { recordID(recordType: recordType, id: $0) }, deleting: false)
    }

    private func enqueueDeletes(recordType: String, ids: [String]) {
        guard canEnqueueRecordChanges else { return }
        enqueue(ids.map { recordID(recordType: recordType, id: $0) }, deleting: true)
    }

    /// 按记录所在的 zone 分给各自的引擎: participant 的共享记录进 sharedEngine。
    private func enqueue(_ recordIDs: [CKRecord.ID], deleting: Bool) {
        var byEngine: [ObjectIdentifier: (engine: CKSyncEngine, changes: [CKSyncEngine.PendingRecordZoneChange])] = [:]
        for recordID in recordIDs {
            guard let target = engine(for: recordID.zoneID) else { continue }
            let change: CKSyncEngine.PendingRecordZoneChange = deleting
                ? .deleteRecord(recordID)
                : .saveRecord(recordID)
            byEngine[ObjectIdentifier(target), default: (target, [])].changes.append(change)
        }
        for entry in byEngine.values {
            addCoalescedRecordZoneChanges(entry.changes, to: entry.engine)
        }
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
           MirrorPlaylistIdentity.isMirrorPlaylist(metadata.localID) {
            return false
        }
        if metadata.recordType == RecordType.musicSource {
            let stored = sourcesStore.source(id: metadata.localID)
            let tombstone = sourcesStore.sourceDeletionRecord(id: metadata.localID)?.tombstone
            guard let source = stored ?? tombstone else { return false }
            return MusicSourceCloudSyncPolicy.isEligible(source)
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

    private func migratePendingSourceDeletesToTombstoneSaves(in syncEngine: CKSyncEngine) {
        let legacyDeletes = syncEngine.state.pendingRecordZoneChanges.filter { change in
            guard case .deleteRecord(let recordID) = change,
                  let metadata = recordMetadata(for: recordID),
                  metadata.recordType == RecordType.musicSource else { return false }
            return sourcesStore.sourceDeletionRecord(id: metadata.localID)?.tombstone != nil
        }
        guard !legacyDeletes.isEmpty else { return }
        syncEngine.state.remove(pendingRecordZoneChanges: legacyDeletes)
        let saves = legacyDeletes.compactMap { change -> CKSyncEngine.PendingRecordZoneChange? in
            guard case .deleteRecord(let recordID) = change else { return nil }
            return .saveRecord(recordID)
        }
        syncEngine.state.add(pendingRecordZoneChanges: saves)
        plog("CloudKitSync: migrated \(saves.count) pending source delete(s) to durable tombstone saves")
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
            plog("CloudKitSync: dropped \(dropped.count) device-local/stale pending change(s)")
        }

        return kept
    }

    /// On first start, push everything we have locally. Source tombstones are
    /// saved as durable payloads; CloudAccount keeps its legacy deleteRecord
    /// behavior because account IDs are deterministic and not user-facing.
    private func scheduleInitialUpload() {
        // 整份重传会让其它设备把这些记录再逐条收一遍, 记下规模供写盘量诊断。
        plog(
            "☁️ CloudKitSync: initial upload re-seeding playlists=\(library.allPlaylists.count) "
                + "artworkOverrides=\(library.allArtworkOverrides.count) "
                + "smartPlaylists=\(library.allSmartPlaylists.count) "
                + "radioStations=\(radioStationsStore.allStations.count) "
                + "scraperConfigs=\(scraperConfigStore.allConfigsIncludingDeleted.count)"
        )
        playlistsChanged(ids: library.allPlaylists.map(\.id))
        artworkOverridesChanged(ids: library.allArtworkOverrides.map(\.cloudRecordID))
        smartPlaylistsChanged(ids: library.allSmartPlaylists.map(\.id))
        sourcesChanged(ids: sourceIDsForCatchUp())
        cloudAccountsChanged(ids: sourcesStore.allAccounts.map(\.id))
        // Records only: the lifecycle full upload already carries
        // radio-stations.json, so a first start needs no snapshot rewrite.
        if CloudSyncChannel.isEnabled(.sources) {
            enqueueRadioStationRecords(ids: radioStationsStore.allStations.map(\.id))
        }
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

    /// A previous app version may have advanced its CloudKit cursor past a
    /// `MusicSource` record whose type it could not decode. When the supported
    /// source-type set changes, discard that cursor once so CKSyncEngine
    /// replays the zone and the upgraded build can recover skipped sources.
    /// Re-seeding local entities preserves any pending offline edits lost with
    /// the old engine state; fetch-before-send still applies normal LWW rules.
    private func preparePersistedStateForSupportedSourceTypes() {
        let defaults = UserDefaults.standard
        let currentFingerprint = CloudSourceTypeCompatibilityPolicy.currentFingerprint
        var storedFingerprint = defaults.string(forKey: Self.sourceTypeFingerprintKey)
        #if DEBUG
        if !Self.didApplySyncTestScenario, SyncTestScenario.current == .upgradeReset {
            Self.didApplySyncTestScenario = true
            // 当成从不认识现有源类型的旧版本升级上来: 走真实的重置 → 全量重拉 → 首次上传。
            storedFingerprint = "legacy"
            plog("🧪 Sync test scenario upgrade-reset: treating stored source-type fingerprint as legacy")
        }
        #endif
        let action = CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: storedFingerprint,
            currentFingerprint: currentFingerprint
        )
        guard action == .resetAndRefetch else {
            // 只少了类型时游标照旧可用, 但要记下现在的集合: 以后把少掉的类型加回来,
            // 这台设备在这期间确实可能跳过过它们, 那时仍要重拉。
            if storedFingerprint != currentFingerprint {
                defaults.set(currentFingerprint, forKey: Self.sourceTypeFingerprintKey)
            }
            return
        }

        // 全新安装没有旧游标可丢, 本来就会从头拉取并做首次上传, 只记下指纹。
        // 真正要重置的是带着旧游标升级上来的设备(包括从备份恢复的)。
        let existingStateURLs = [stateURL, sharedStateURL].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingStateURLs.isEmpty else {
            defaults.set(currentFingerprint, forKey: Self.sourceTypeFingerprintKey)
            return
        }

        do {
            for url in existingStateURLs {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            plog("CloudKitSync: source compatibility reset failed: \(error.localizedDescription)")
            return
        }

        didCompleteInitialUpload = false
        defaults.set(currentFingerprint, forKey: Self.sourceTypeFingerprintKey)
        plog("CloudKitSync: supported source types changed; scheduling full refetch")
    }

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
        plog("💾 CloudKit system fields cache written entries=\(systemFieldsCache.count) bytes=\(data.count)")
    }

    /// 记下缓存有改动, 并安排一次合并写。CKSyncEngine 送来的整批记录由
    /// `handleEvent` 在批末显式 `flushSystemFieldsCache()`; 冲突处理这类零散
    /// 调用靠这里的短延迟合并。
    private func scheduleSystemFieldsCachePersist() {
        systemFieldsCacheNeedsPersist = true
        guard systemFieldsPersistTask == nil else { return }
        systemFieldsPersistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.systemFieldsPersistDelay)
            guard !Task.isCancelled else { return }
            self?.flushSystemFieldsCache()
        }
    }

    /// 有未写盘的改动就立刻写。保存引擎游标之前必须先调它: 游标一旦越过某条
    /// 记录就不会再拉它, 那条记录的 changeTag 只能靠这份缓存留住。
    fileprivate func flushSystemFieldsCache() {
        systemFieldsPersistTask?.cancel()
        systemFieldsPersistTask = nil
        guard systemFieldsCacheNeedsPersist else { return }
        systemFieldsCacheNeedsPersist = false
        persistSystemFieldsCache()
    }

    /// 「总数 (类型=条数 …)」的紧凑摘要, 条数多的在前; 按批记日志, 不按记录。
    nonisolated static func recordTypeSummary(_ recordTypes: [String]) -> String {
        guard !recordTypes.isEmpty else { return "0" }
        let counts = Dictionary(recordTypes.map { ($0, 1) }, uniquingKeysWith: +)
        let parts = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return "\(recordTypes.count) (\(parts.joined(separator: " ")))"
    }

    /// 一批远端事件处理完、或者引擎游标落盘之前, 把攒着的整份写一次:
    /// system fields 缓存、逐条并进来的电台清单和歌单耐久账本。
    fileprivate func flushCoalescedRemoteWrites() {
        flushSystemFieldsCache()
        radioStationsStore.flushRemotePersist()
        library.flushRemotePlaylistDurabilityLedger()
        // 歌单曲目、智能歌单和听歌统计只在整库快照 / 统计文件里, 它们的防抖写
        // 还没到点就存游标, 进程这时被杀, 越过游标的那批记录就再也拉不回来。
        library.flushArmedSnapshotWriteNow()
        PlayHistoryStore.shared.flushPendingSave()
    }

    private func engineIsCurrent(_ syncEngine: CKSyncEngine) -> Bool {
        syncEngine === engine || syncEngine === sharedEngine
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
            scheduleSystemFieldsCachePersist()
        }
    }

    fileprivate func removeSystemFields(for recordID: CKRecord.ID) {
        loadSystemFieldsCacheIfNeeded()
        var removed = systemFieldsCache.removeValue(forKey: Self.systemFieldsKey(for: recordID)) != nil
        for legacyKey in Self.legacySystemFieldsKeys(for: recordID) {
            removed = (systemFieldsCache.removeValue(forKey: legacyKey) != nil) || removed
        }
        if removed {
            scheduleSystemFieldsCachePersist()
        }
    }

    private func clearSystemFieldsCache() {
        // 服务器那边的状态不再可信(退出登录/换账号/zone 被删), 墓碑确认记录一并作废,
        // 下次启动全部补传。
        acknowledgedSourceTombstones = [:]
        // 待写的旧内容作废: 清空的语义是文件也一起消失, 不能被延迟写回来。
        systemFieldsPersistTask?.cancel()
        systemFieldsPersistTask = nil
        systemFieldsCacheNeedsPersist = false
        systemFieldsCache.removeAll()
        systemFieldsCacheLoaded = true
        systemFieldsCacheGeneration &+= 1
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
        case RecordType.radioStation:
            return populateRadioStationRecord(record, stationID: id)
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

    fileprivate func applyRemoteRecord(_ record: CKRecord, decodedListeningStats: [PlayHistoryStore.Entry]? = nil) {
        if record.recordType == RecordType.musicSource,
           let source = decodedSource(from: record),
           !MusicSourceCloudSyncPolicy.isEligible(source) {
            removeSystemFields(for: record.recordID)
            return
        }
        // 不论本 channel 是否启用,都先保留 system fields——禁用期间也可能后续
        // 又开启,届时如果没有 changeTag 还是会撞 "record to insert already exists"。
        storeSystemFields(record)
        if record.recordType == RecordType.radioStation {
            supersedeDeferredRadioChange(
                recordID: record.recordID,
                serverUpdatedAt: (record["updatedAt"] as? Date) ?? .distantPast
            )
        }

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
        case RecordType.radioStation:
            applyRadioStationRecord(record)
        case RecordType.scraperConfig:
            applyScraperConfigRecord(record)
        case RecordType.playbackHistory:
            applyPlaybackHistoryRecord(record)
        case RecordType.listeningStats:
            applyListeningStatsRecord(record, decodedEntries: decodedListeningStats)
        default:
            break
        }
    }

    /// Apply a record delivered by a fetch without discarding an unsent local
    /// mutation for the same record. `syncNow()` intentionally fetches before
    /// sending; a plain remote apply here used to replace the local playlist,
    /// so the subsequent save contained only the remote side of a concurrent
    /// edit. Merge the set-like record types while their save is pending.
    @MainActor
    fileprivate func applyFetchedRecord(
        _ record: CKRecord,
        decodedListeningStats: [PlayHistoryStore.Entry]? = nil,
        syncEngine: CKSyncEngine
    ) {
        if record.recordType == RecordType.musicSource,
           let source = decodedSource(from: record),
           !MusicSourceCloudSyncPolicy.isEligible(source) {
            dropPendingRecordZoneChanges(for: record.recordID, syncEngine: syncEngine)
            return
        }
        if CloudSyncChannel.isEnabled(.sources), shouldReassertSourceTombstone(for: record) {
            // Preserve the fetched change tag, then overwrite this stale active
            // payload with the durable local tombstone in the same sync cycle.
            storeSystemFields(record)
            addCoalescedRecordZoneChanges([.saveRecord(record.recordID)], to: syncEngine)
            return
        }

        let hasPendingSave = syncEngine.state.pendingRecordZoneChanges.contains { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return Self.sameRecordID(recordID, record.recordID)
        }
        guard hasPendingSave,
              let local = makeRecord(for: record.recordID) else {
            if record.recordType == RecordType.playlist {
                storeSystemFields(record)
                if CloudSyncChannel.isEnabled(.playlists) {
                    isApplyingRemote = true
                    let localWon = applyPlaylistRecord(record)
                    isApplyingRemote = false
                    if localWon {
                        addCoalescedRecordZoneChanges([.saveRecord(record.recordID)], to: syncEngine)
                    }
                }
                return
            }
            applyRemoteRecord(record, decodedListeningStats: decodedListeningStats)
            return
        }

        // Preserve the server change tag before the already-pending send asks
        // makeRecord(for:) to rebuild the merged payload.
        storeSystemFields(record)
        if record.recordType == RecordType.radioStation {
            supersedeDeferredRadioChange(
                recordID: record.recordID,
                serverUpdatedAt: (record["updatedAt"] as? Date) ?? .distantPast
            )
        }

        if let channel = Self.channel(for: record.recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        switch record.recordType {
        case RecordType.playlist:
            mergePlaylistRecord(local: local, server: record)
        case RecordType.playbackHistory:
            mergePlaybackHistoryRecord(local: local, server: record)
        case RecordType.listeningStats:
            mergeListeningStatsRecord(local: local, server: record)
        case RecordType.musicSource:
            if sourceWinner(local: local, remote: record) == .remote {
                applyRemoteRecord(record)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }
        default:
            // Atomic records keep their existing last-writer-wins behavior.
            let localUpdated = (local["updatedAt"] as? Date) ?? .distantPast
            let serverUpdated = (record["updatedAt"] as? Date) ?? .distantPast
            if serverUpdated >= localUpdated {
                applyRemoteRecord(record)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }
        }

        // 合并之后本地要推的内容若已与服务器相同(典型是源类型指纹重置后整份重排的
        // 那些), 推上去只会让其它设备把它再逐条收一遍, 撤掉。
        dropPendingSaveIfServerMatches(record, syncEngine: syncEngine)
    }

    /// 本地这条待传记录与服务器上的已逐字段相同就撤掉待传。
    private func dropPendingSaveIfServerMatches(_ server: CKRecord, syncEngine: CKSyncEngine) {
        let stillPending = syncEngine.state.pendingRecordZoneChanges.contains { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return Self.sameRecordID(recordID, server.recordID)
        }
        guard stillPending, let rebuilt = makeRecord(for: server.recordID) else { return }
        let differing = Self.differingRecordKeys(rebuilt, server)
        guard differing.isEmpty else {
            // 只记字段名不记值: 下次抓日志就能看出是哪一类字段让重传撤不掉。
            plog(
                "☁️ CloudKitSync: kept pending \(server.recordType) save, "
                    + "differing keys=\(differing.sorted().joined(separator: ","))"
            )
            return
        }
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
    }

    /// 本地记录与服务器上的有哪些字段不同; 空数组就是相同。
    /// 只比本地会写入或清空的字段, 忽略每次构造都会刷新的 `updatedAt`;
    /// 带附件算不同(保留待传, 行为与原来一致)。JSON 数据按内容比, 不看键的顺序 ——
    /// 编码器不保证两次输出的键序一致, 逐字节比会把内容相同的记录判成不同。
    nonisolated static func differingRecordKeys(_ local: CKRecord, _ server: CKRecord) -> [String] {
        let keys = Set(local.allKeys())
            .union(local.changedKeys())
            .subtracting(["updatedAt"])
        guard !keys.isEmpty else { return ["<no fields>"] }
        return keys.filter { key in
            !recordValuesMatch(local[key], server[key])
        }
    }

    private nonisolated static func recordValuesMatch(
        _ localValue: (any CKRecordValue)?,
        _ serverValue: (any CKRecordValue)?
    ) -> Bool {
        if localValue is CKAsset || serverValue is CKAsset { return false }
        switch (localValue, serverValue) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if let lhsData = lhs as? Data, let rhsData = rhs as? Data {
                return jsonDataMatch(lhsData, rhsData)
            }
            guard let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject else {
                return false
            }
            return lhsObject.isEqual(rhsObject)
        default:
            return false
        }
    }

    private nonisolated static func jsonDataMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let lhsObject = try? JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed]) as? NSObject,
              let rhsObject = try? JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed]) as? NSObject else {
            return false
        }
        return lhsObject.isEqual(rhsObject)
    }

    fileprivate func applyRemoteDeletion(
        recordID: CKRecord.ID,
        recordType: String,
        allowLocalRestore: Bool = false
    ) {
        // record 已经从 server 移除,缓存里的 changeTag 也没用了。
        removeSystemFields(for: recordID)
        if recordType == RecordType.radioStation {
            supersedeDeferredRadioChange(recordID: recordID, serverUpdatedAt: nil)
        }

        if let channel = Self.channel(for: recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        guard let id = parseLocalID(from: recordID, recordType: recordType) else { return }
        if recordType == RecordType.musicSource,
           let source = sourcesStore.source(id: id)
                ?? sourcesStore.sourceDeletionRecord(id: id)?.tombstone,
           !MusicSourceCloudSyncPolicy.isEligible(source) {
            return
        }
        if recordType == RecordType.playlist,
           let owner = LibraryArtworkOwner.fromCloudRecordID(id) {
            if allowLocalRestore, library.artworkOverride(for: owner) != nil {
                if let target = engine(for: recordID.zoneID) {
                    addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: target)
                }
                return
            }
            isApplyingRemote = true
            library.deleteArtworkOverrideFromRemote(owner: owner)
            isApplyingRemote = false
            return
        }
        if recordType == RecordType.playlist,
           MirrorPlaylistIdentity.isMirrorPlaylist(id) {
            return
        }

        // Only protect a local restore while resolving a save failure. A
        // fetched CloudKit deletion is authoritative remote state; treating
        // every active local row as "restored" re-pushes stale sources and
        // makes deletions appear to come back.
        if allowLocalRestore, isLocallyRestored(recordType: recordType, id: id) {
            if let target = engine(for: recordID.zoneID) {
                addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: target)
            }
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        switch recordType {
        case RecordType.playlist:
            if library.deletePlaylistFromRemote(id: id), let target = engine(for: recordID.zoneID) {
                addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: target)
            }
        case RecordType.smartPlaylist:
            library.deleteSmartPlaylistFromRemote(id: id)
        case RecordType.musicSource:
            sourcesStore.removeFromRemote(id: id)
        case RecordType.cloudAccount:
            sourcesStore.removeAccountFromRemote(id: id)
        case RecordType.radioStation:
            radioStationsStore.removeFromRemote(id: id)
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
            if let owner = LibraryArtworkOwner.fromCloudRecordID(id) {
                return library.artworkOverride(for: owner) != nil
            }
            if MirrorPlaylistIdentity.isMirrorPlaylist(id) { return false }
            return library.allPlaylists.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.smartPlaylist:
            return library.allSmartPlaylists.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.musicSource:
            return sourcesStore.allSources.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.cloudAccount:
            return sourcesStore.allAccounts.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
        case RecordType.radioStation:
            return radioStationsStore.allStations.first(where: { $0.id == id }).map { !$0.isDeleted } ?? false
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
        if let owner = LibraryArtworkOwner.fromCloudRecordID(playlistID) {
            return populateArtworkOverrideRecord(record, owner: owner)
        }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID) else { return false }
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
        var identities = makeIdentities(forSongIDs: songIDs)
        identities.append(contentsOf: library.pendingSongIdentities(forPlaylist: playlistID))
        var seenIdentities = Set<SongIdentity>()
        identities = identities.filter { seenIdentities.insert($0).inserted }
        if let data = try? JSONEncoder().encode(
            PlaylistCloudSyncEnvelope(playlist: playlist, songIdentities: identities)
        ) {
            if data.count > Self.playlistEnvelopeInlineLimit {
                // 两千首以上的歌单, 身份信封本身就超过一条记录 1MB 的字段上限,
                // 以前这条记录永远保存不了。超额的信封改走附件; 旧版本读不到
                // 附件时仍有 songIDs 可用。
                guard let assetURL = stagePlaylistEnvelopeAsset(data, playlistID: playlistID) else {
                    return false
                }
                record[Self.songIdentitiesField] = nil
                record[Self.songIdentitiesAssetField] = CKAsset(fileURL: assetURL)
            } else {
                record[Self.songIdentitiesField] = data
                record[Self.songIdentitiesAssetField] = nil
            }
        }
        return true
    }

    /// 身份信封内联进记录的上限。记录还带着 songIDs 数组和几个小字段, 留够余量。
    private nonisolated static let playlistEnvelopeInlineLimit = 700_000
    /// 超大歌单的信封附件字段。新字段: 发布前要把 Playlist 的 schema 部署到生产环境。
    private nonisolated static let songIdentitiesAssetField = "songIdentitiesAsset"

    /// 附件文件要活到引擎真正上传完为止, 所以按歌单 id 放在固定路径、每次构建
    /// 记录时整份覆盖, 不用临时目录。
    private func stagePlaylistEnvelopeAsset(_ data: Data, playlistID: String) -> URL? {
        let directory = stateURL.deletingLastPathComponent()
            .appendingPathComponent("cloudkit-playlist-envelopes", isDirectory: true)
        let fileName = playlistID.replacingOccurrences(of: "/", with: "_") + ".json"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            plog("CloudKitSync: staging playlist envelope asset failed id=\(playlistID.prefix(8))…: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func applyPlaylistRecord(_ record: CKRecord) -> Bool {
        if let id = parseLocalID(from: record.recordID, recordType: RecordType.playlist),
           let owner = LibraryArtworkOwner.fromCloudRecordID(id) {
            return applyArtworkOverrideRecord(record, owner: owner)
        }
        guard let payload = decodePlaylistPayload(record) else { return false }
        let id = payload.playlist.id
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(id) else { return false }
        let songIDs = (record["songIDs"] as? [String]) ?? []
        // Hand the raw payload to the library; it owns the 3-tier resolver
        // and stashes anything that doesn't match yet as pending so a later
        // scan can fill it in.
        return library.applyRemotePlaylist(
            payload.playlist,
            songIDs: songIDs,
            identities: payload.identities
        )
    }

    private func populateArtworkOverrideRecord(
        _ record: CKRecord,
        owner: LibraryArtworkOwner
    ) -> Bool {
        guard let value = library.artworkOverride(for: owner),
              value.cloudRecordID == owner.cloudRecordID else { return false }

        let uploadedData: Data?
        if value.mode == .uploaded {
            guard let contentID = value.uploadedContentID,
                  LibraryArtworkContentIDPolicy.isValid(contentID),
                  let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID) else {
                // Never replace a valid remote upload with a metadata-only
                // value after local storage loss.
                return false
            }
            uploadedData = data
        } else {
            uploadedData = nil
        }

        let envelope = LibraryArtworkCloudEnvelope(
            override: value,
            uploadedArtworkData: uploadedData
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        record[Self.songIdentitiesField] = data
        record["name"] = owner.id
        record["createdAt"] = value.updatedAt
        record["updatedAt"] = value.updatedAt
        record["songIDs"] = [] as [String]
        if let contentID = value.uploadedContentID {
            record["coverArtPath"] = contentID
        } else {
            record["coverArtPath"] = nil
        }
        return true
    }

    private func decodeArtworkOverrideEnvelope(
        _ record: CKRecord,
        owner: LibraryArtworkOwner
    ) -> LibraryArtworkCloudEnvelope? {
        guard let data = record[Self.songIdentitiesField] as? Data,
              let envelope = try? JSONDecoder().decode(
                LibraryArtworkCloudEnvelope.self,
                from: data
              ),
              envelope.schemaVersion == LibraryArtworkCloudEnvelope.currentSchemaVersion,
              envelope.override.owner == owner,
              envelope.override.cloudRecordID == owner.cloudRecordID else {
            return nil
        }
        switch envelope.override.mode {
        case .automatic:
            return envelope
        case .selectedSong:
            return envelope.override.selectedSongIdentity == nil ? nil : envelope
        case .uploaded:
            guard let contentID = envelope.override.uploadedContentID,
                  LibraryArtworkContentIDPolicy.isValid(contentID) else { return nil }
            if let uploadedData = envelope.uploadedArtworkData,
               uploadedData.count > LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes {
                return nil
            }
            return envelope
        }
    }

    private func installArtworkAssetIfNeeded(
        from envelope: LibraryArtworkCloudEnvelope
    ) -> Bool {
        guard envelope.override.mode == .uploaded else { return true }
        guard let contentID = envelope.override.uploadedContentID else { return false }
        if MetadataAssetStore.shared.hasCustomArtwork(contentID: contentID) {
            return true
        }
        guard let data = envelope.uploadedArtworkData else { return false }
        return MetadataAssetStore.shared.storeCustomArtworkSync(
            data,
            expectedContentID: contentID
        ) != nil
    }

    @discardableResult
    private func applyArtworkOverrideRecord(
        _ record: CKRecord,
        owner: LibraryArtworkOwner
    ) -> Bool {
        guard let envelope = decodeArtworkOverrideEnvelope(record, owner: owner) else {
            return library.artworkOverride(for: owner) != nil
        }
        if let local = library.artworkOverride(for: owner) {
            let outcome = LibraryArtworkOverrideReconciliationPolicy.outcome(
                local: local,
                remote: envelope.override
            )
            if outcome != .remoteWins {
                // A metadata snapshot can arrive before CloudKit's image bytes.
                // Equal uploaded values still get a chance to repair the missing
                // local asset even though the local logical value wins the tie.
                if local.mode == .uploaded,
                   local.uploadedContentID == envelope.override.uploadedContentID {
                    _ = installArtworkAssetIfNeeded(from: envelope)
                }
                // 完全相等时不能请求回推: 两台设备都会这么判, 于是同一条记录
                // 被无休止地互相保存。只有本地确实更新才让冲突路径重申它。
                return outcome == .localWins
            }
        }
        guard installArtworkAssetIfNeeded(from: envelope) else {
            return library.artworkOverride(for: owner) != nil
        }
        return library.applyRemoteArtworkOverride(envelope.override)
    }

    private func decodePlaylistPayload(
        _ record: CKRecord
    ) -> (playlist: Playlist, identities: [SongIdentity]?)? {
        guard let id = parseLocalID(from: record.recordID, recordType: RecordType.playlist) else {
            return nil
        }
        // 超大歌单的信封在附件里; 引擎在回调前已把附件下载到本地临时文件。
        let envelopeData = (record[Self.songIdentitiesField] as? Data)
            ?? (record[Self.songIdentitiesAssetField] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        if let data = envelopeData,
           let envelope = try? JSONDecoder().decode(PlaylistCloudSyncEnvelope.self, from: data),
           envelope.playlist.id == id {
            return (envelope.playlist, envelope.songIdentities)
        }
        guard let name = record["name"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        return (
            Playlist(
                id: id,
                name: name,
                createdAt: createdAt,
                updatedAt: record.modificationDate ?? updatedAt,
                coverArtPath: record["coverArtPath"] as? String
            ),
            decodeIdentities(record[Self.songIdentitiesField] as? Data)
        )
    }

    // MARK: - Smart playlist mapping
    //
    // 整份 SmartPlaylist 编码成 JSON 塞进单个 `payload` 字段。规则型只存定义；
    // AI 型还会保存可跨设备解析的 SongIdentity，由 MusicLibrary 在展示时解析。
    // 不同设备的 PlayHistoryStore 不同步，同一份规则可能得到不同结果，这是设计选择。

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
        // 本机那份更新时不让远端旧副本盖掉, 并把本机这份再推一次(与歌单一致)。
        if library.applyRemoteSmartPlaylist(smart), let target = engine(for: record.recordID.zoneID) {
            addCoalescedRecordZoneChanges([.saveRecord(record.recordID)], to: target)
        }
    }

    // MARK: - Music source mapping

    private func populateSourceRecord(_ record: CKRecord, sourceID: String) -> Bool {
        let storedSource = sourcesStore.allSources.first(where: { $0.id == sourceID })
        let ledgerTombstone = sourcesStore.sourceDeletionRecord(id: sourceID)?.tombstone
        let source = if storedSource?.isDeleted != false, let ledgerTombstone {
            ledgerTombstone
        } else {
            storedSource
        }
        guard let source,
              MusicSourceCloudSyncPolicy.isEligible(source) else { return false }
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
        guard var source = decodedSource(from: record),
              MusicSourceCloudSyncPolicy.isEligible(source) else { return }
        // Older records may still contain a Synology trusted-device token.
        // Never import it onto a different physical device.
        source.deviceId = nil
        sourcesStore.upsertFromRemote(source)
    }

    private func decodedSource(from record: CKRecord) -> MusicSource? {
        guard let data = record["payload"] as? Data,
              let syncable = try? JSONDecoder().decode(SyncableSource.self, from: data) else {
            return nil
        }
        return syncable.source
    }

    private func shouldReassertSourceTombstone(for record: CKRecord) -> Bool {
        guard record.recordType == RecordType.musicSource,
              let source = decodedSource(from: record),
              MusicSourceCloudSyncPolicy.isEligible(source),
              !source.isDeleted,
              let deletion = sourcesStore.sourceDeletionRecord(id: source.id),
              deletion.tombstone != nil else { return false }
        return MusicSourceLifecyclePolicy.shouldSuppress(active: source, with: deletion)
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

    // MARK: - Internet radio mapping

    private func populateRadioStationRecord(_ record: CKRecord, stationID: String) -> Bool {
        // 墓碑(普通删除和订阅的排除标记)都以 `isDeleted = true` 的完整记录保存:
        // 带修改时间的墓碑才挡得住别的设备更早的一次保存把它复活。
        //
        // 兼容旧版本：旧版本认识 `isDeleted`。它收到墓碑时，`upsertFromRemote`
        // 对本地已有的那条会变成墓碑(隐藏)，对本地没有的直接忽略 —— 正好都是
        // 想要的结果，所以这条记录可以放心地发给所有版本。
        guard var station = radioStationsStore.allStations.first(where: { $0.id == stationID }) else {
            return false
        }
        // 最近收听时间只用于当前设备排序，不参与跨设备合并。
        station.lastPlayedAt = nil
        let logoData = station.logoData
        station.logoData = nil
        guard let data = try? JSONEncoder().encode(station) else { return false }
        record["payload"] = data
        record["logoData"] = logoData
        record["updatedAt"] = station.modifiedAt
        return true
    }

    private func applyRadioStationRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              var station = try? JSONDecoder().decode(RadioStation.self, from: data) else {
            return
        }
        if let logoData = record["logoData"] as? Data,
           logoData.count <= RadioStationValidation.maximumLogoBytes {
            station.logoData = logoData
        }
        radioStationsStore.upsertFromRemote(station)
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
        // 已删除的配置不再往刮削来源列表里补一行: 那会把别的设备刚删掉的来源
        // 又加回来, 再经 KVS 传一圈。
        guard config.isDeleted != true else { return }
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
    /// 这个上限是编译期常量, 且压缩后的裁剪判定要在主 actor 之外做, 所以
    /// 显式声明为 nonisolated —— 值本身不可变, 不需要任何隔离。
    private nonisolated static let statsInlineLimit = 900_000

    private func populateListeningStatsRecord(_ record: CKRecord) -> Bool {
        // 最多 5000 条历史的 JSON 编码 + zlib 压缩。节流刷新会提前把这份 payload
        // 算好, 这里只在缓存跟当前 revision 对不上时才现编。名字对 Instruments
        // 稳定不要改。
        let signpost = PrimuseSignposts.hitch.beginInterval("sync.statsEncode")
        defer { PrimuseSignposts.hitch.endInterval("sync.statsEncode", signpost) }
        let revision = PlayHistoryStore.shared.revision
        let encoded: StatsPayload
        if let cache = statsPayloadCache,
           ListeningStatsPayloadCache.isUsable(cachedRevision: cache.revision, currentRevision: revision) {
            encoded = cache.payload
        } else {
            guard let fresh = Self.encodeTrimmedStatsPayload(PlayHistoryStore.shared.entriesForSync) else { return false }
            encoded = fresh
            statsPayloadCache = (revision: revision, payload: fresh)
        }
        record["payloadGz"] = encoded.payload as CKRecordValue
        // 清掉旧的未压缩字段, 避免更新既有记录时残留的超大 payload 把记录顶过 1MB。
        record["payload"] = nil
        record["entryCount"] = encoded.entryCount
        record["updatedAt"] = Date()
        // 只在真的清空过时才写这个字段: 生产环境的 schema 还没有它之前, 没清空过
        // 的用户照常同步。
        if let clearedAt = PlayHistoryStore.shared.clearedAt {
            record[Self.listeningStatsClearedAtField] = clearedAt
        }
        return true
    }

    /// 「清空听歌记录」的时刻, 随统计记录同步; 早于它的条目在合并时一律丢弃。
    /// 新字段: 发布前要把 ListeningStats 的 schema 部署到生产环境。
    private nonisolated static let listeningStatsClearedAtField = "clearedAt"

    private nonisolated static func decodeListeningStatsClearedAt(_ record: CKRecord) -> Date? {
        record[listeningStatsClearedAtField] as? Date
    }

    /// Pure: entries in, compressed payload out. Safe to run off the main actor,
    /// which is what the throttled flush does before the record is ever built.
    private nonisolated static func encodeTrimmedStatsPayload(_ entries: [PlayHistoryStore.Entry]) -> StatsPayload? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var entries = entries
        guard var payload = encodeStatsPayload(entries, encoder: encoder) else { return nil }
        if payload.count > statsInlineLimit {
            // 几乎不可能(gzip 后远小于上限), 但仍兜底: 只保留最近条目再压。
            // entries 为最新在前, prefix 即保留最近的。
            entries = Array(entries.prefix(2000))
            guard let trimmed = encodeStatsPayload(entries, encoder: encoder),
                  trimmed.count <= statsInlineLimit else {
                plog("⚠️ Listening stats payload still over limit after trim — skipping sync")
                return nil
            }
            payload = trimmed
        }
        return StatsPayload(payload: payload, entryCount: entries.count)
    }

    private nonisolated static func encodeStatsPayload(_ entries: [PlayHistoryStore.Entry], encoder: JSONEncoder) -> Data? {
        guard let data = try? encoder.encode(entries) else { return nil }
        return try? (data as NSData).compressed(using: .zlib) as Data
    }

    private func applyListeningStatsRecord(_ record: CKRecord, decodedEntries: [PlayHistoryStore.Entry]? = nil) {
        guard let entries = decodedEntries ?? Self.decodeListeningStatsEntries(record) else { return }
        PlayHistoryStore.shared.mergeRemoteEntries(
            entries,
            remoteClearedAt: Self.decodeListeningStatsClearedAt(record)
        )
    }

    /// Pure: record in, entries out. The fetch handler runs it before it hops to
    /// the main actor; the conflict merge still calls it inline.
    private nonisolated static func decodeListeningStatsEntries(_ record: CKRecord) -> [PlayHistoryStore.Entry]? {
        // 解压 + 整表解码;冲突合并一次会调用两遍(本地 + 服务端)。
        let signpost = PrimuseSignposts.hitch.beginInterval("sync.statsDecode")
        defer { PrimuseSignposts.hitch.endInterval("sync.statsDecode", signpost) }
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
            if let song = library.songForSynchronization(id: id) {
                return SongIdentity(
                    songID: song.id,
                    title: song.title,
                    artistName: song.artistName,
                    duration: song.duration,
                    cloudAccountID: sourcesStore.source(id: song.sourceID)?.cloudAccountID,
                    filePath: song.filePath
                )
            }
            // 置灰的占位条目带着自己的元数据走, 接收方原位保留、用自己的曲库点亮。
            if let pending = library.pendingEntry(id: id) {
                return pending.syncIdentity
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
        // `stop()` (sync toggled off, sign-out)只是把 engine 摘掉,CKSyncEngine
        // 内部已经在路上的回调不会跟着消失。用 engine 身份而不是取消状态来做栅栏:
        // 一个已经被摘掉的 engine 不允许再落地远端记录、也不允许改写 state 游标
        // (`handleAccountChange` 刚删掉的那份)。`.accountChange` 例外——拆除流程
        // 本身要靠它。
        let (isCurrentEngine, acceptsSystemFieldUpdates) = await MainActor.run {
            () -> (Bool, Bool) in
            let current = syncEngine === self.engine || syncEngine === self.sharedEngine
            // system fields 只是「服务器已接受的 etag」缓存,不是本地数据改写:
            // 一台被摘掉的 engine 报回来的保存结果照样要记下来,否则下次 start()
            // 第一笔 save 就撞 serverRecordChanged,走合并把用户删掉的歌单曲目
            // 从服务器副本并回来。唯一不能记的是这台 engine 退役之后缓存又被
            // 整份清空的情况(退出登录/切账号),那时旧账号的 etag 必须留在过去。
            let accepts = current
                || self.systemFieldsCacheGeneration == self.engineCacheGeneration
            return (current, accepts)
        }
        switch event {
        case .stateUpdate(let event):
            guard isCurrentEngine else { return }
            await MainActor.run {
                // 进入 handleEvent 时判过一次, 但跳回主 actor 之前引擎可能已被摘掉。
                guard self.engineIsCurrent(syncEngine) else { return }
                // 游标落盘前先把已拉到的记录落盘: 游标一旦越过就不会再拉。
                self.flushCoalescedRemoteWrites()
                // private engine 跟 sharedEngine state 分开存, 否则下次启动
                // 一个 engine 用错 state cursor 会重 fetch 全量。
                if syncEngine === self.sharedEngine {
                    self.saveSharedStateSerialization(event.stateSerialization)
                } else {
                    self.saveStateSerialization(event.stateSerialization)
                }
            }
        case .fetchedRecordZoneChanges(let event):
            guard isCurrentEngine else { return }
            for modification in event.modifications {
                let record = modification.record
                // 听歌统计整表解压 + 解码放在跳回主 actor 之前做完, 主 actor 只做
                // 合并。这多出一个挂起点, 所以身份栅栏必须在真正落地的那次
                // `MainActor.run` 里重新判一遍, 不能只靠进入 handleEvent 时那次。
                if record.recordType == RecordType.listeningStats {
                    let entries = Self.decodeListeningStatsEntries(record)
                    await MainActor.run {
                        guard syncEngine === self.engine || syncEngine === self.sharedEngine else { return }
                        self.applyFetchedRecord(record, decodedListeningStats: entries, syncEngine: syncEngine)
                    }
                    continue
                }
                await MainActor.run {
                    guard self.engineIsCurrent(syncEngine) else { return }
                    self.applyFetchedRecord(record, syncEngine: syncEngine)
                }
            }
            for deletion in event.deletions {
                await MainActor.run {
                    guard self.engineIsCurrent(syncEngine) else { return }
                    self.applyRemoteDeletion(
                        recordID: deletion.recordID,
                        recordType: deletion.recordType,
                        allowLocalRestore: false
                    )
                }
            }
            // 整批一次写盘, 不按记录逐条整份写。
            await MainActor.run { self.flushCoalescedRemoteWrites() }
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                plog(
                    "☁️ CloudKitSync: fetched \(Self.recordTypeSummary(event.modifications.map(\.record.recordType))) "
                        + "deletions=\(event.deletions.count)"
                )
            }
        case .fetchedDatabaseChanges(let event):
            // Zone-level changes from another device. Most often: zone deletion
            // (user wiped CloudKit data on another device, or container reset).
            // We re-create our zone if it's gone and force a re-seed on next
            // start so the local data ends up back in CloudKit.
            guard isCurrentEngine else { return }
            // 所有者停止共享(或撤掉本机的参与资格): 共享 zone 从共享库里消失。本机
            // 退回只同步自己的私有库, 免得共享类型的记录继续往一个不存在的 zone 排队。
            await MainActor.run {
                guard let shared = Self.participantSharedZoneID,
                      event.deletions.contains(where: { $0.zoneID == shared }) else { return }
                plog("CloudKitSync: shared family zone was removed by its owner — leaving the share")
                self.isParticipantOfShare = false
                Self.participantSharedZoneID = nil
                Self.familySharingEnabled = false
                self.sharedEngine = nil
                try? FileManager.default.removeItem(at: self.sharedStateURL)
            }
            for deletion in event.deletions where deletion.zoneID == Self.zoneID {
                plog("CloudKitSync: PrimuseSync zone was deleted remotely — recreating + re-seeding")
                await MainActor.run {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    self.clearSystemFieldsCache()
                    self.didCompleteInitialUpload = false
                }
            }
        case .sentRecordZoneChanges(let event):
            if acceptsSystemFieldUpdates {
                // 每一跳都再判一次: 退役引擎报回来的 etag 在缓存整份清空之后不能再写进去。
                let stillAccepts: @MainActor () -> Bool = {
                    self.engineIsCurrent(syncEngine)
                        || self.systemFieldsCacheGeneration == self.engineCacheGeneration
                }
                for saved in event.savedRecords {
                    await MainActor.run {
                        guard stillAccepts() else { return }
                        self.storeSystemFields(saved)
                    }
                }
                for deletedID in event.deletedRecordIDs {
                    await MainActor.run {
                        guard stillAccepts() else { return }
                        self.removeSystemFields(for: deletedID)
                    }
                }
                await MainActor.run { self.flushSystemFieldsCache() }
            }
            // 重新入队、墓碑回执这些会改本地状态 / 再次上传的动作,仍然只允许
            // 当前 engine 触发。
            guard isCurrentEngine else { return }
            for saved in event.savedRecords {
                await MainActor.run {
                    self.acknowledgeSavedSourceTombstone(saved)
                    self.acknowledgeSavedPlaylist(saved)
                }
            }
            for failed in event.failedRecordSaves {
                await MainActor.run {
                    self.handleFailedSave(failed, syncEngine: syncEngine)
                }
            }
            // 冲突处理会把服务器那份并回本地。
            await MainActor.run { self.flushCoalescedRemoteWrites() }
            if !event.savedRecords.isEmpty || !event.failedRecordSaves.isEmpty || !event.deletedRecordIDs.isEmpty {
                plog(
                    "☁️ CloudKitSync: sent saved=\(Self.recordTypeSummary(event.savedRecords.map(\.recordType))) "
                        + "deleted=\(event.deletedRecordIDs.count) failed=\(event.failedRecordSaves.count)"
                )
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

    /// 服务器已确认保存过的音乐源墓碑: 源 id → 那一次删除的 deletedAt。
    private static let acknowledgedSourceTombstonesKey = "primuse.cloudSync.acknowledgedSourceTombstones"

    private var acknowledgedSourceTombstones: [String: Double] {
        get {
            (UserDefaults.standard.dictionary(forKey: Self.acknowledgedSourceTombstonesKey) as? [String: Double]) ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.acknowledgedSourceTombstonesKey) }
    }

    /// 本机的删除记录里, 哪些还没被服务器确认过「这一次」删除。重新删除(先恢复再删)
    /// 会换一个 deletedAt, 所以同一个 id 的新删除仍会补传。
    private func unacknowledgedSourceDeletionIDs() -> [String] {
        let acknowledged = acknowledgedSourceTombstones
        return sourcesStore.sourceDeletionRecords.compactMap { record in
            guard let confirmed = acknowledged[record.id],
                  abs(confirmed - record.deletedAt.timeIntervalSinceReferenceDate) < 1 else {
                return record.id
            }
            return nil
        }
    }

    /// 歌单记录保存成功: 服务器上的曲目表就是刚推上去的这份, 交给资料库记成
    /// 三方合并的基线。
    private func acknowledgeSavedPlaylist(_ record: CKRecord) {
        guard record.recordType == RecordType.playlist,
              let id = parseLocalID(from: record.recordID, recordType: RecordType.playlist) else { return }
        library.markPlaylistSynced(id: id, songIDs: (record["songIDs"] as? [String]) ?? [])
    }

    private func acknowledgeSavedSourceTombstone(_ record: CKRecord) {
        guard record.recordType == RecordType.musicSource,
              let source = decodedSource(from: record),
              MusicSourceCloudSyncPolicy.isEligible(source),
              source.isDeleted else { return }
        acknowledgedSourceTombstones[source.id] =
            (source.deletedAt ?? source.modifiedAt).timeIntervalSinceReferenceDate
        NotificationCenter.default.post(
            name: .primuseSourceTombstoneDidSync,
            object: nil,
            userInfo: ["id": source.id]
        )
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // 同一个身份栅栏:被摘掉的 engine 不允许再往上传任何本地记录。
        // 判定先落到局部量再 guard: `MainActor.run` 的闭包是带标签的 `body:`,
        // 只有尾随闭包写法能省掉标签, 而 guard 条件里不能直接跟尾随闭包。
        let syncEngineIsCurrent = await MainActor.run {
            syncEngine === self.engine || syncEngine === self.sharedEngine
        }
        guard syncEngineIsCurrent else { return nil }
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

        if let schemaError = Self.schemaError(in: ckError) {
            let message = schemaError.localizedDescription
            didCompleteInitialUpload = false
            unresolvedRecordSaveError = message
            status = .error(message)
            plog(
                "CloudKitSync: Production schema missing for "
                    + "\(failed.record.recordType): \(message)"
            )
            return
        }

        switch ckError.code {
        case .serverRecordChanged:
            // `failed.record` is the snapshot `makeRecord` built when the batch
            // was assembled. Edits made while the save was in flight are not in
            // it, and the merge below writes its membership back, so merging the
            // batch-time record would revert them. Rebuild from live state and
            // only fall back when the entity is gone — this mirrors
            // `applyFetchedRecord`, which already rebuilds fresh.
            let current = makeRecord(for: recordID) ?? failed.record
            resolveServerRecordChanged(local: current, error: ckError, syncEngine: syncEngine)
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and try again.
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
            addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: syncEngine)
        case .unknownItem:
            // Server-side record went away (deleted on another device). Mirror
            // that locally so the two sides line up.
            resolveUnknownItem(recordID: recordID, recordType: failed.record.recordType, syncEngine: syncEngine)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Engine retries automatically; honor any explicit retry-after.
            if let retry = ckError.retryAfterSeconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(retry))
                    self.addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: syncEngine)
                }
            }
        case .quotaExceeded:
            rememberFailedSave(recordID)
            unresolvedRecordSaveError = ckError.localizedDescription
            status = .quotaExceeded
        case .notAuthenticated:
            rememberFailedSave(recordID)
            unresolvedRecordSaveError = ckError.localizedDescription
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
            // 以前这里把「首次上传已完成」清掉, 让下次启动整库重传一遍 —— 一条
            // 永远保存不了的记录(比如超过 1MB 的歌单)就让每次启动都重传全部、
            // 每台设备都重收全部。改成只记住这一条, 下次启动单独重试它。
            rememberFailedSave(recordID)
            unresolvedRecordSaveError = "\(ckError.code.rawValue): \(ckError.localizedDescription)"
            plog("CloudKitSync: unhandled save error code \(ckError.code.rawValue) for \(recordID.recordName): \(ckError.localizedDescription)")
        }
    }

    /// 服务器说这条记录不存在, 而本机缓存着它的 changeTag。单例记录(播放历史、
    /// 听歌统计)只有本机这一份是事实: 丢掉旧 etag 当新记录重传, 不能把本机历史
    /// 清空。其它类型仍按「别的设备删了」处理, 本机还活着的行会重新保存。
    private func resolveUnknownItem(recordID: CKRecord.ID, recordType: String, syncEngine: CKSyncEngine) {
        if recordType == RecordType.playbackHistory || recordType == RecordType.listeningStats {
            removeSystemFields(for: recordID)
            addCoalescedRecordZoneChanges([.saveRecord(recordID)], to: syncEngine)
        } else {
            applyRemoteDeletion(recordID: recordID, recordType: recordType, allowLocalRestore: true)
        }
    }

    private static let rememberedFailedSavesKey = "primuse.cloudSync.rememberedFailedSaves"
    private static let rememberedFailedSavesLimit = 500

    /// 引擎对不可重试的失败会把那条待传丢掉。记下 record 名, 下次 start() 单独
    /// 重排它, 而不是靠整库重传碰运气。
    private func rememberFailedSave(_ recordID: CKRecord.ID) {
        var names = UserDefaults.standard.stringArray(forKey: Self.rememberedFailedSavesKey) ?? []
        guard !names.contains(recordID.recordName) else { return }
        names.append(recordID.recordName)
        if names.count > Self.rememberedFailedSavesLimit {
            names.removeFirst(names.count - Self.rememberedFailedSavesLimit)
        }
        UserDefaults.standard.set(names, forKey: Self.rememberedFailedSavesKey)
    }

    private func retryRememberedFailedSaves(in engine: CKSyncEngine) {
        let names = UserDefaults.standard.stringArray(forKey: Self.rememberedFailedSavesKey) ?? []
        guard !names.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.rememberedFailedSavesKey)
        let changes: [CKSyncEngine.PendingRecordZoneChange] = names.compactMap { name in
            guard let meta = recordMetadata(for: CKRecord.ID(recordName: name)) else { return nil }
            return .saveRecord(recordID(recordType: meta.recordType, id: meta.localID))
        }
        guard !changes.isEmpty else { return }
        addCoalescedRecordZoneChanges(changes, to: engine)
        plog("☁️ CloudKitSync: retrying \(changes.count) save(s) that failed permanently last time")
    }

    /// Resolve a `serverRecordChanged` conflict with type-aware merging.
    ///
    /// - **Playlists**: union both sides' `songIDs` so neither device's recent
    ///   add is lost; pick name/coverArt from the larger `updatedAt`.
    /// - **PlaybackHistory**: union+dedup, capped at 100, local entries first.
    /// - **MusicSource**: durable deletion wins unless the active payload carries
    ///   a later explicit restore marker.
    /// - **ScraperConfig**: straight last-writer-wins on `updatedAt`.
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
        case RecordType.musicSource:
            if sourceWinner(local: local, remote: server) == .remote {
                applyRemoteRecord(server)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
                return
            }
        default:
            // Remaining payload-based atomic types use LWW on updatedAt.
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

    private func sourceWinner(
        local: CKRecord,
        remote: CKRecord
    ) -> MusicSourceLifecyclePolicy.Winner? {
        guard let localSource = decodedSource(from: local),
              let remoteSource = decodedSource(from: remote) else { return nil }
        return MusicSourceLifecyclePolicy.winner(local: localSource, remote: remoteSource)
    }

    @MainActor
    private func mergePlaylistRecord(local: CKRecord, server: CKRecord) {
        guard let id = parseLocalID(from: server.recordID, recordType: RecordType.playlist) else { return }
        if let owner = LibraryArtworkOwner.fromCloudRecordID(id) {
            mergeArtworkOverrideRecord(local: local, server: server, owner: owner)
            return
        }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(id) else {
            enqueueDeletes(recordType: RecordType.playlist, ids: [id])
            return
        }

        let localIDs = (local["songIDs"] as? [String]) ?? []
        let serverIDs = (server["songIDs"] as? [String]) ?? []
        guard let localPayload = decodePlaylistPayload(local),
              let serverPayload = decodePlaylistPayload(server) else { return }
        let localWins = PlaylistReconciliationPolicy.winner(
            local: localPayload.playlist,
            remote: serverPayload.playlist
        ) == .local
        let mergedPlaylist = localWins ? localPayload.playlist : serverPayload.playlist
        let serverIdentities = serverPayload.identities ?? serverIDs.map {
            SongIdentity(
                songID: $0,
                title: "",
                artistName: nil,
                duration: 0,
                cloudAccountID: nil,
                filePath: ""
            )
        }

        applyRemoteEnvelope {
            // Membership remains a set-like merge only while the winning
            // state retains it. Metadata/deletion state follows the logical
            // operation policy above, independent of device clocks.
            library.mergeRemotePlaylist(
                mergedPlaylist,
                baseSongIDs: localIDs,
                additionalIdentities: serverIdentities
            )
        }
    }

    @MainActor
    private func mergeArtworkOverrideRecord(
        local: CKRecord,
        server: CKRecord,
        owner: LibraryArtworkOwner
    ) {
        guard let localEnvelope = decodeArtworkOverrideEnvelope(local, owner: owner),
              let serverEnvelope = decodeArtworkOverrideEnvelope(server, owner: owner) else {
            return
        }
        let winner = LibraryArtworkOverrideReconciliationPolicy.winner(
            local: localEnvelope.override,
            remote: serverEnvelope.override
        )
        if winner == .local,
           localEnvelope.override.mode == .uploaded,
           localEnvelope.override.uploadedContentID == serverEnvelope.override.uploadedContentID {
            _ = installArtworkAssetIfNeeded(from: serverEnvelope)
        }
        guard winner == .remote,
              installArtworkAssetIfNeeded(from: serverEnvelope) else { return }
        applyRemoteEnvelope {
            _ = library.applyRemoteArtworkOverride(serverEnvelope.override)
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
        let localEntries = Self.decodeListeningStatsEntries(local) ?? []
        let serverEntries = Self.decodeListeningStatsEntries(server) ?? []
        let clearedAt = [Self.decodeListeningStatsClearedAt(local), Self.decodeListeningStatsClearedAt(server)]
            .compactMap { $0 }
            .max()

        applyRemoteEnvelope {
            PlayHistoryStore.shared.mergeRemoteEntries(
                localEntries + serverEntries,
                remoteClearedAt: clearedAt
            )
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
            Self.participantSharedZoneID = nil
            UserDefaults.standard.set(false, forKey: CloudSyncChannel.masterDefaultsKey)
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
