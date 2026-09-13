import CryptoKit
import Darwin
import Foundation
import PrimuseKit
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

#if os(iOS)
@MainActor
private protocol MetadataBackgroundContinuation: AnyObject {
    var identifier: UUID { get }
    var isGranted: Bool { get }
    func advance()
    func finish(success: Bool)
}

#if !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
private final class MetadataContinuedProcessingSession: MetadataBackgroundContinuation {
    let identifier: UUID
    private var task: BGContinuedProcessingTask?
    private var finished = false
    private var completed: Int64 = 0
    private var lastProgressPublishedAt = Date.distantPast
    private let total: Int64
    private let started: () -> Void
    private let expired: () -> Void
    private var taskIdentifier: String { "com.welape.yuanyin.metadata-reading.\(identifier.uuidString)" }
    var isGranted: Bool { task != nil && !finished }

    init(identifier: UUID, total: Int, started: @escaping () -> Void, expired: @escaping () -> Void) {
        self.identifier = identifier
        self.total = Int64(max(1, total))
        self.started = started
        self.expired = expired
    }

    func submit() -> Bool {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, !self.finished, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.task = task
                plog("📥 Backfill: continued task granted id=\(self.identifier) total=\(self.total)")
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.finished else { return }
                        // 系统收回后台时间，不等于标签读取失败：app 还在前台时
                        // 读取会照常继续（见 start() 里对 applicationState 的
                        // 判断）。这时报失败，系统任务卡片会显示「任务失败」，
                        // 而用户在应用里看到的进度仍在往前走，两边对不上。
                        let continuesInForeground =
                            UIApplication.shared.applicationState == .active
                        plog("📥 Backfill: continued task expired id=\(self.identifier) foreground=\(continuesInForeground)")
                        self.finish(
                            success: continuesInForeground,
                            completesProgress: false
                        )
                        self.expired()
                    }
                }
                self.publishProgress()
                self.started()
            }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: String(localized: "backfill_in_progress"),
            subtitle: "0 / \(total)"
        )
        // Rejection falls back to normal execution, never a delayed job that
        // could revive a source the user has since paused or removed.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            finished = true
            plog("📥 Backfill: continued processing unavailable: \(error)")
            return false
        }
    }

    func advance() {
        guard !finished else { return }
        completed += 1
        publishProgress()
    }

    private func publishProgress() {
        guard let task else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublishedAt) >= 1 else { return }
        lastProgressPublishedAt = now
        // New rows can arrive while a source is scanning. Only worker
        // completion marks the system task finished, never a stale estimate.
        let currentTotal = max(total, completed + 1)
        task.progress.totalUnitCount = currentTotal
        task.progress.completedUnitCount = completed
        task.updateTitle(String(localized: "backfill_in_progress"), subtitle: "\(completed) / \(currentTotal)")
    }

    func finish(success: Bool) {
        finish(success: success, completesProgress: true)
    }

    /// - Parameter completesProgress: 是否把进度条补满。只有真正读完才补；
    ///   前台接手继续读时活儿还没干完，补满会让最后一眼的卡片说谎。
    private func finish(success: Bool, completesProgress: Bool) {
        guard !finished else { return }
        finished = true
        plog("📥 Backfill: continued task finished id=\(identifier) success=\(success) processed=\(completed)/\(total) granted=\(task != nil)")
        if let task {
            task.expirationHandler = nil
            if success, completesProgress {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        }
    }
}
#endif
#endif

enum SingleSongTagReadResult: Sendable, Equatable {
    case completed(MetadataReadCompletionKind)
    case alreadyReading
    case unsupported
    case failed(reason: String)
}

enum PlaybackSingleSongTagReadResult: Sendable, Equatable {
    case completed(MetadataReadCompletionKind)
    case alreadyReading
    case notNeeded
    case unsupported
    case cancelled
    case retryableFailure(reason: String)
    case failed(reason: String)
}

extension MetadataReadCompletionKind {
    var localizedRereadResult: String {
        switch self {
        case .embeddedTags:
            String(localized: "reread_song_tags_completed_embedded")
        case .sidecarMetadata:
            String(localized: "reread_song_tags_completed_sidecar")
        case .filenameInference:
            String(localized: "reread_song_tags_completed_filename")
        case .technicalProperties:
            String(localized: "reread_song_tags_completed_technical")
        case .verifiedNoMetadata:
            String(localized: "reread_song_tags_completed_no_metadata")
        }
    }
}

/// Fills in metadata for songs that were added by ConnectorScanner in
/// "bare-song" mode. File-oriented remote sources and local references read
/// only bounded metadata ranges here instead of blocking catalogue discovery
/// on one complete metadata parse per song.
///
/// Lifecycle:
/// - A real library/source mutation marks the durable queue dirty. iOS runs it
///   primarily in background/BGProcessing windows. A completed foreground
///   source scan drains small serial snapshots while the app stays active so
///   new rows receive metadata without restarting aggressive maintenance.
/// - The standard worker can use a small bounded amount of concurrency. iOS
///   background profiles deliberately trade throughput for smooth playback.
/// - Failed songs (corrupt / missing / decoder rejected) are recorded so we
///   don't retry them every launch. Successful ones are replaced in the
///   library and persist via `MusicLibrary.persistSnapshot()`.
/// 一次性闩: 把"worker 跑完了"和"这活已经不归我管了"收敛成同一次唤醒。
/// `Task<Void, Never>.value` 既不接受超时也不理会等待方的取消, 所以后者只能
/// 从外面把等待放掉。全部在主 actor 上 resume, 不存在重复 resume。
@MainActor
private final class MetadataBackfillWorkerWaitLatch {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}

@MainActor
@Observable
final class MetadataBackfillService {
    /// Bytes to fetch from the start of an audio file. Big enough to cover
    /// embedded artwork + ID3v2 + FLAC Vorbis comments + most M4A `moov`
    /// headers. If a particular file's metadata isn't in this slice we may
    /// need to retry with a tail-Range fetch (M4A with trailing moov).
    private static let headBytes: Int64 = 256 * 1024
    /// A declared ID3 boundary may place both artwork and the first MPEG frame
    /// beyond `headBytes`. Expansion stays capped so one outlier cannot turn a
    /// library backfill into full-file downloads.
    private static let maxMetadataHeadBytes = RemoteMetadataReadPolicy.maximumHeadByteCount
    private static let defaultMP3Bitrate = RemoteMetadataReadPolicy.defaultMP3BitRateKbps

    private static let fallbackTailBytes: Int64 = 256 * 1024
    private static let boundedHeadTagExtensions: Set<String> = ["ogg", "opus", "speex", "wma"]

    /// Persisted IDs whose bytes were read successfully but the expected
    /// metadata parser still produced no usable details.
    @ObservationIgnored private var failedSongIDs: Set<String> = []

    /// Persisted IDs that remain playable through a stream descriptor or the
    /// complete-file decoder even though bounded header reads cannot determine
    /// duration. This suppresses only the duration leg; title/artwork inspection
    /// remains independently eligible.
    @ObservationIgnored private var incompleteSongIDs: Set<String> = []

    /// Persisted IDs whose source object/path could not be read. They are not
    /// parser failures and surface as "check source" until an explicit retry,
    /// source availability change, or content-change notification clears them.
    @ObservationIgnored private var sourceIssueSongIDs: Set<String> = []

    /// Songs that parsed fine (have a usable duration) but yielded no
    /// extractable embedded artwork. Kept SEPARATE from `failedSongIDs`:
    /// a missing cover must not mark a song permanently failed (that dropped
    /// its duration update at flush and stuck it bare). These songs stay
    /// playable & recoverable; we only stop re-fetching them *for artwork*.
    @ObservationIgnored private var artworkGivenUpIDs: Set<String> = []

    /// Songs whose embedded title has been checked under the metadata-title
    /// policy. Older builds intentionally kept the filename even after parsing
    /// tags, so every backfillable remote song needs one successful pass after
    /// upgrading. Persisting the IDs makes this a one-time repair rather than a
    /// Range request on every launch.
    @ObservationIgnored private var titleCheckedIDs: Set<String> = []

    /// Songs whose album-artist field has been inspected, including files that
    /// legitimately contain neither an album artist nor a track artist. Absence
    /// is a completed result; without this independent marker those rows remain
    /// eligible forever whenever they have an album title.
    @ObservationIgnored private var albumArtistCheckedIDs: Set<String> = []

    /// Songs whose track-artist field has been inspected. Track artist is
    /// independent from duration and album artist: a valid FLAC STREAMINFO
    /// block can complete duration while a later Vorbis-comment block has not
    /// yet been read. Persisting absence prevents an artist-less file from
    /// looping forever after one complete bounded inspection.
    @ObservationIgnored private var artistCheckedIDs: Set<String> = []

    /// Consecutive transient failure count per song ID. Counts are persisted so
    /// relaunching the app or changing networks cannot reset the automatic retry
    /// budget and keep rereading the same permanently unreachable object.
    @ObservationIgnored private var transientFailureCounts: [String: Int] = [:]
    /// Source-wide authentication/connection failures use a separate budget so
    /// a 10k-song source cannot evade the cap by failing on a different row at
    /// every launch.
    @ObservationIgnored private var sourceTransientFailureCounts: [String: Int] = [:]

    /// Songs parked until another usable network path is observed. Every real
    /// transient failure parks immediately instead of being retried five times
    /// back-to-back in one worker loop.
    @ObservationIgnored private var sessionGivenUpIDs: Set<String> = []
    @ObservationIgnored private var sessionNetworkParkedIDs: Set<String> = []
    /// Repeated snapshots indicate a state-application problem rather than a
    /// transport problem and must not be unparked by a network transition.
    @ObservationIgnored private var sessionStallParkedIDs: Set<String> = []

    /// Persisted marker for songs that still need another attempt after a
    /// transient transport failure. Unlike `sessionGivenUpIDs`, this set does
    /// not suppress queueing: it survives relaunch only so the UI can explain
    /// that these requests are retries rather than a new scan. A successful or
    /// terminal inspection removes the marker.
    @ObservationIgnored private var deferredRetryMembership = DeferredRetryMembership()

    /// 只读投影, 让原有的读取点保持不变(Set 是写时复制, 取用是 O(1))。
    private var deferredRetrySongIDs: Set<String> {
        deferredRetryMembership.songIDs
    }

    /// 只在延迟重试集合的成员关系真的变化时前进。歌曲行订阅的是这个版本号
    /// 而不是 `statusRevision`, 因此每 5 秒一次的状态对账不会再让所有可见行
    /// 重新求值 body。
    private(set) var deferredRetryRevision: Int = 0

    /// 所有集合改动都经由这里: 变化才发布, 未变化则连版本号都不动。
    private func mutateDeferredRetries(
        _ body: (inout DeferredRetryMembership) -> Bool
    ) {
        guard body(&deferredRetryMembership) else { return }
        deferredRetryRevision = deferredRetryMembership.revision
    }

    /// Exact context for the latest failed attempt. Queue membership remains in
    /// the dedicated ID sets above; these records exist so the source detail UI
    /// can distinguish parser rejection, missing files, transient transport,
    /// and source-wide availability failures after a relaunch.
    @ObservationIgnored private var diagnosticRecords: [String: MetadataBackfillDiagnosticRecord] = [:]

    /// UserDefaults key for "only run backfill on Wi-Fi". Default true.
    /// User-facing toggle lives in CloudSyncSettingsView.
    static let wifiOnlyDefaultsKey = "primuse.cloudScanWifiOnly"

    /// Whether the cellular opt-in alert is currently visible. This is kept
    /// separate from `isWaitingForWiFi`: dismissing the alert must not make a
    /// deferred queue look active again.
    private(set) var pausedForCellular: Bool = false
    /// User opted into cellular backfill for this session only (not persisted).
    @ObservationIgnored private var cellularAllowedThisSession = false
    /// User dismissed the cellular prompt this session — don't re-prompt
    /// automatically until next launch.
    @ObservationIgnored private var cellularPromptDismissedThisSession = false

    /// Publish prompt visibility only on a real state transition. During a
    /// connector scan `musicLibrary.songs.count` changes repeatedly and each
    /// change calls `refreshQueue()` → `start()`. Assigning observable `true`
    /// again for every batch makes SwiftUI treat one cellular pause as many
    /// alert presentation events even though there is only one source.
    private func setCellularPromptPresented(_ presented: Bool) {
        guard pausedForCellular != presented else { return }
        pausedForCellular = presented
        if presented {
            #if os(iOS)
            AppAlertCoordinator.shared.enqueue(.cellularBackfill)
            #endif
        } else {
            AppAlertCoordinator.shared.cancel(.cellularBackfill)
        }
    }

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let backfillableSourceIDs: () -> Set<String>
    /// Local discovery deliberately creates duration-less rows. Once that
    /// initial detail read succeeds, older fully-populated local rows must not
    /// be swept again merely because their optional artwork/title inspection
    /// markers predate the shared backfill pipeline.
    private let bareOnlySourceIDs: () -> Set<String>
    /// Sources whose bytes live in the app sandbox and remain readable while
    /// Wi-Fi-only blocks connector and File Provider traffic.
    private let offlineReadableSourceIDs: () -> Set<String>
    // A filesystem reader may use a mounted/provider volume. Its CPU budget
    // must not grant the offline network-policy exemption of sandbox copies.
    private let localFileSourceIDs: () -> Set<String>
    private let manuallyReadableSourceIDs: () -> Set<String>
    private let metadataService = MetadataService()
    private let failedURL: URL
    private let incompleteURL: URL
    private let sourceIssueURL: URL
    private let artworkGivenUpURL: URL
    private let titleCheckedURL: URL
    private let albumArtistCheckedURL: URL
    private let artistCheckedURL: URL
    private let deferredRetryURL: URL
    private let diagnosticsURL: URL
    private let retryCountsURL: URL
    private let sourceRetryCountsURL: URL
    private let queueStateURL: URL
    private nonisolated static let queueDirtyDefaultsKey =
        "primuse.metadataBackfill.queueDirty.v1"
    private nonisolated static let queueMutationGenerationDefaultsKey =
        "primuse.metadataBackfill.queueMutationGeneration.v1"

    private struct QueueState: Codable, Equatable, Sendable {
        let needsRefresh: Bool
        let reconciledGeneration: Int
        let remainingCount: Int
        let failedCount: Int
        let deferredRetryCount: Int
        let statusCount: Int
        let remainingCountBySourceID: [String: Int]
        let deferredRetryCountBySourceID: [String: Int]
        let statusCountBySourceID: [String: Int]
    }

    /// Songs currently being processed (for UI / cancellation).
    private(set) var pendingCount: Int = 0
    private(set) var processedCount: Int = 0
    private(set) var isRunning: Bool = false
    /// True while eligible work exists but the Wi-Fi-only gate prevents new
    /// metadata reads. Unlike the alert state, this remains true after the user
    /// chooses to keep waiting for Wi-Fi.
    private(set) var isWaitingForWiFi: Bool = false
    /// Cached in one library pass and consumed by all source cards. The old
    /// implementation filtered the complete song array once per card on every
    /// SwiftUI body update, multiplying work by source count during scrolling.
    private(set) var cachedRemainingCount: Int = 0
    private(set) var cachedFailedCount: Int = 0
    private(set) var remainingCountBySourceID: [String: Int] = [:]
    private(set) var cachedDeferredRetryCount: Int = 0
    private(set) var deferredRetryCountBySourceID: [String: Int] = [:]
    private(set) var cachedStatusCount: Int = 0
    private(set) var statusCountBySourceID: [String: Int] = [:]
    private(set) var sourceStatusSummaries: [String: MetadataBackfillSourceSummary] = [:]
    private(set) var statusRevision: Int = 0
    /// Lightweight row values are prepared during the existing queue-summary
    /// pass. Opening a source detail can reuse that snapshot instead of doing a
    /// second complete-library pass or copying lyrics-bearing `Song` values.
    @ObservationIgnored private var statusDisplayItemsBySourceID: [
        String: [MetadataBackfillStatusDisplayItem]
    ] = [:]
    /// 当前已发布的展示行指纹, 见 `MetadataBackfillStatusSignature`。
    @ObservationIgnored private var statusDisplayItemsSignature =
        MetadataBackfillStatusSignature()
    /// Sources represented by the worker's current fixed snapshot. Per-source
    /// cards use this rather than the global worker flag, so an idle source does
    /// not show a spinner while another provider is being processed.
    private(set) var activeSourceIDs: Set<String> = []
    private(set) var manuallyReadingSongIDs: Set<String> = []
    private(set) var batchRereadingSourceIDs: Set<String> = []
    @ObservationIgnored private var activeReadSongIDs: Set<String> = []
    private struct PlaybackTagReadIdentity: Hashable, Sendable {
        let songID: String
        let sourceID: String
        let filePath: String
        let revision: String?
        let fileSize: Int64

        init(_ song: Song) {
            songID = song.id
            sourceID = song.sourceID
            filePath = song.filePath
            revision = song.revision
            fileSize = song.fileSize
        }
    }

    /// A deterministic playback failure is suppressed for this exact remote
    /// object for the rest of the launch. A changed path/revision/size gets a
    /// fresh probe, and failures recorded by the bulk worker do not block the
    /// playback-owned recovery path.
    @ObservationIgnored private var playbackTerminalFailureIdentities:
        Set<PlaybackTagReadIdentity> = []
    @ObservationIgnored private var lastRemainingCountRefreshAt = Date.distantPast
    @ObservationIgnored private var remainingCountComputationGeneration: UInt64 = 0
    /// 整库对账要遍历全部歌曲, 只在发布前后才有新数可算, 所以节流窗口跟着
    /// 发布节奏走而不是固定 5 秒 —— 固定窗口在低档位上会按更小的快照反复
    /// 重扫整库, 恰好让档位越低开销越大。
    private var remainingCountRefreshInterval: TimeInterval {
        max(5, executionLimits.flushInterval)
    }
    /// A durable dirty bit separates "the library changed" from "run a full
    /// eligibility sweep on every lifecycle/network callback". The first run
    /// after upgrading reconciles once; a proven-clean library then stays
    /// silent across launches until a real song/source mutation marks it dirty.
    private var queueNeedsRefresh = true
    private var queueMutationGeneration: Int
    private var reconciledQueueGeneration = -1
    @ObservationIgnored private var persistedQueueState: QueueState?
    @ObservationIgnored private var queueStatePersistenceTask: Task<Void, Never>?

    @ObservationIgnored private var worker: Task<Void, Never>?
    /// 自动路径上把整库对账挪到 off-main 之后再 start() 的那个任务。
    @ObservationIgnored private var deferredQueueReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var drainingWorker: Task<Void, Never>?
    /// Generation of the task parked in `drainingWorker`, so that task's own
    /// MainActor cleanup can clear it. Without this the handle outlives the
    /// drain until the next `start()`, and any await-based idle wait would
    /// never terminate.
    @ObservationIgnored private var drainingWorkerGeneration: Int?
    /// Set while the scene is only temporarily obscured (Control Center, a
    /// call, Face ID). Reads already in flight finish and are recorded; no new
    /// read is admitted and no interim batch is published.
    @ObservationIgnored private var isSceneTransitionPaused = false
    /// Parked `waitUntilIdle` callers, woken by the worker's completion or by
    /// `stop()`; see `awaitWorkerCompletionOrRelease`.
    @ObservationIgnored private var workerWaitLatches: [MetadataBackfillWorkerWaitLatch] = []
    @ObservationIgnored private var executionMode: MetadataBackfillExecutionMode = .standard
    @ObservationIgnored private var activeScheduler: MetadataReadScheduler<Song, BackfillOutcome>?
    @ObservationIgnored private var batchSchedulers: [String: MetadataReadScheduler<String, MetadataTagRereadBatch.Outcome>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var configurationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var playbackIsActive: () -> Bool
    private(set) var readingMode: MetadataReadingMode = .automatic
    private(set) var readingConfigurationRevision = 0
    private(set) var readingProgress: [String: MetadataReadingRate] = [:]
    @ObservationIgnored private var readProgressAccumulator: [String: MetadataReadingRate] = [:]
    @ObservationIgnored private var lastReadProgressPublishedAt = Date.distantPast
    @ObservationIgnored private var recentProcessingDuration: TimeInterval = 0.5
    // 攒起来等发布的结果。这些必须活在 worker 这一层而不是单个快照里: 一次
    // 发布的代价与整库规模成正比, 与这一批有几首无关, 而低档位的快照只有
    // 8~48 行。按快照边界强制收尾, 等于把同一笔整库开销摊到更少的歌上 ——
    // 档位越低每首歌付得越多。跨快照累积, 发布只由完成量与时间间隔决定。
    @ObservationIgnored private var pendingFlush: [Song] = []
    @ObservationIgnored private var pendingMetadataInspectionIDs: Set<String> = []
    @ObservationIgnored private var pendingArtistInspectionIDs: Set<String> = []
    @ObservationIgnored private var artistInspectionIDsRequiringReplacement: Set<String> = []
    @ObservationIgnored private var lastFlushAt = Date.distantPast
    /// 已读完但还没发布的歌。它们在资料库里仍然是"裸行", 所以必须和
    /// `manuallyReadingSongIDs` 一样从选取里排除, 否则下一个快照会把它们
    /// 再读一遍并触发"同一批 ID 反复出现"的停摆保护。
    @ObservationIgnored private var pendingFlushSongIDs: Set<String> = []

    private var executionLimits: MetadataBackfillExecutionLimits {
        let budget = MetadataBackfillExecutionPolicy.limits(
            for: executionMode,
            preference: readingMode,
            environment: readingEnvironment(),
            continuedProcessing: hasContinuedProcessingTime,
            recentProcessingDuration: recentProcessingDuration
        )
        // Explicit batches temporarily own the shared budget. In-flight
        // automatic reads drain normally before those slots become available.
        // Hand-off in the other direction: while a batch is registered but
        // cannot run (app not active), its already-dispatched reads are still
        // in flight, so the automatic queue only takes the slots they leave
        // free instead of the full budget.
        let manualInFlight = batchSchedulers.values.reduce(0) { $0 + $1.inFlightCount }
        let automaticWorkerCount = Self.automaticWorkerCount(
            budgetWorkerCount: budget.workerCount,
            hasRegisteredManualBatch: !batchSchedulers.isEmpty,
            applicationIsActive: Self.applicationIsActive,
            manualInFlightCount: manualInFlight
        )
        return budget.withWorkerCount(
            MetadataBackfillSceneTransitionPolicy.workerCount(
                base: automaticWorkerCount,
                isPaused: isSceneTransitionPaused
            )
        )
    }

    /// A registered manual/explicit reread batch owns the shared worker budget
    /// — but only while it can actually make progress. The batch's own limits
    /// closure returns `workerCount 0` whenever the iOS app is not active, so
    /// keeping the automatic budget at zero as well left *both* queues without
    /// a worker until the app returned to the foreground.
    /// When the app is not active the automatic budget therefore applies as if
    /// no batch were registered; the batch reclaims ownership on the next
    /// `executionLimits` read once the app is active again.
    nonisolated static func manualBatchOwnsAutomaticBudget(
        hasRegisteredManualBatch: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        hasRegisteredManualBatch && applicationIsActive
    }

    /// Worker count the automatic queue may use. A batch that owns the budget
    /// leaves nothing; a registered batch that cannot run still keeps the
    /// slots its in-flight reads occupy, so automatic + manual never exceed
    /// the device ceiling while the batch drains.
    nonisolated static func automaticWorkerCount(
        budgetWorkerCount: Int,
        hasRegisteredManualBatch: Bool,
        applicationIsActive: Bool,
        manualInFlightCount: Int
    ) -> Int {
        guard !manualBatchOwnsAutomaticBudget(
            hasRegisteredManualBatch: hasRegisteredManualBatch,
            applicationIsActive: applicationIsActive
        ) else { return 0 }
        return max(0, budgetWorkerCount - (hasRegisteredManualBatch ? manualInFlightCount : 0))
    }

    /// macOS has no application-state gate on manual batches, so ownership
    /// there keeps its historical "always active" meaning.
    private static var applicationIsActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    private func readingEnvironment(sourceID: String? = nil) -> MetadataReadingEnvironment {
        let sourceIDs = sourceID.map { Set([$0]) } ?? activeSourceIDs
        let localIDs = offlineReadableSourceIDs().union(localFileSourceIDs())
        return MetadataReadingEnvironment.current(
            playbackActive: playbackIsActive(),
            offlineSource: !sourceIDs.isEmpty && sourceIDs.isSubset(of: localIDs)
        )
    }

    func readingConstraint(forSource sourceID: String) -> MetadataReadingConstraint {
        _ = readingConfigurationRevision
        return MetadataBackfillExecutionPolicy.constraint(
            for: executionMode,
            environment: readingEnvironment(sourceID: sourceID),
            preference: readingMode
        )
    }

    func readingConfigurationChanged() {
        let wasPaused = !readingMode.readsAutomatically
        var resumesFromPause = false
        let mode = MetadataReadingMode.resolve(
            storedValue: UserDefaults.standard.string(forKey: MetadataBackfillExecutionPolicy.readingModeDefaultsKey),
            legacyFastEnabled: UserDefaults.standard.bool(forKey: MetadataBackfillExecutionPolicy.highPerformanceAfterScanDefaultsKey)
        )
        if mode != readingMode {
            readingMode = mode
            let now = Date()
            for sourceID in Array(readProgressAccumulator.keys) {
                readProgressAccumulator[sourceID] = MetadataReadingRate(startedAt: now)
            }
            readingProgress.removeAll()
            lastReadProgressPublishedAt = .distantPast
            plog("Backfill: reading preference -> \(mode.rawValue)")
            if !mode.readsAutomatically {
                // 切到暂停: 停掉 worker, 它会把攒下的那一批发布完再收尾。
                // 手动重读是用户主动发起的, 不在暂停范围内, 由下面的
                // configurationChanged() 原地换到最保守的预算。
                stop()
            } else if wasPaused {
                resumesFromPause = true
            }
        }
        readingConfigurationRevision += 1
        activeScheduler?.configurationChanged()
        for scheduler in batchSchedulers.values { scheduler.configurationChanged() }
        // 从暂停切回读取档位要真的重新开工; 只通知调度器不够, 暂停期间根本
        // 没有 worker 在跑。放在通知之后, 这样新 worker 看到的已经是新预算。
        if resumesFromPause { start() }
    }

    private func recordProcessingDuration(_ duration: TimeInterval) {
        guard duration.isFinite, duration >= 0 else { return }
        // React immediately to expensive parsing and recover gradually after
        // cheap reads; a single easy file cannot erase a heavy recent sample.
        recentProcessingDuration = max(duration, recentProcessingDuration * 0.8 + duration * 0.2)
        if readingEnvironment().thermalState == .serious {
            activeScheduler?.configurationChanged()
            for scheduler in batchSchedulers.values { scheduler.configurationChanged() }
        }
    }

    private func recordReadCompletion(sourceID: String) {
        let now = Date()
        readProgressAccumulator[sourceID, default: MetadataReadingRate(startedAt: now)]
            .recordCompletion(at: now)
        if now.timeIntervalSince(lastReadProgressPublishedAt) >= 2 {
            readingProgress = readProgressAccumulator
            lastReadProgressPublishedAt = now
        }
    }

    /// Session-scoped explicit user intent. Scene transitions may suspend the
    /// worker, but returning active resumes this source until its normal queue
    /// drains or the user taps Pause. A granted system continuation preserves
    /// the selected speed while ordinary background windows remain gentler.
    private(set) var userInitiatedSourceID: String?
    /// Automatic foreground intent for the iOS sandbox import source. It
    /// survives an active/inactive transition so a large import resumes from
    /// the next bounded snapshot instead of stopping after the first 24 rows.
    @ObservationIgnored private var automaticDeviceLocalSourceID: String?
    @ObservationIgnored private var automaticForegroundSourceIDs: Set<String> = []
    /// Source lifecycle notifications can arrive from the view, CloudKit and
    /// the global cleanup coordinator almost simultaneously. Coalesce them so
    /// removing several large sources scans the library once instead of once
    /// per notification/source on the main actor.
    @ObservationIgnored private var pendingDiscardSourceIDs: Set<String> = []
    @ObservationIgnored private var discardWorkTask: Task<Void, Never>?
    /// Exact session progress, kept non-observable so one completed network
    /// request doesn't invalidate every view that observes this service.
    @ObservationIgnored private var processedTotal: Int = 0
    /// Debounced writer for the persisted metadata-state ID sets. Encoding and atomic
    /// file replacement run off the main actor.
    @ObservationIgnored private var statePersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var statePersistenceTaskID: UInt64 = 0
    @ObservationIgnored private var statePersistenceDeadline: ContinuousClock.Instant?
    private static let statePersistenceDebounce: Duration = .seconds(5)
    /// Bumped on every `start()` / `stop()`. The worker captures its own
    /// generation and uses it to decide whether the cleanup at end-of-Task
    /// should clear shared state — without this, a cancelled-but-still-
    /// finishing worker can wipe `worker`/`isRunning` set by a new `start()`
    /// that ran between cancel and Task.value resumption.
    @ObservationIgnored private var workerGeneration: Int = 0

    /// 速率采样与平台无关 ── iOS 和 macOS 的读取都要能看到这行日志。
    @ObservationIgnored private var throughputSampler = MetadataReadThroughputSampler()

    /// Worker 持有的 UIBackgroundTask ID, app 切到后台时给 backfill ~30 秒额外
    /// 收尾时间。worker 完成 / stop 时释放。expirationHandler 兜底 ── 系统提前
    /// 回收时主动 stop, 不留半挂状态。
    /// macOS 没有 UIBackgroundTask 机制 ── app 切后台就是后台进程, 不会被立即
    /// 挂起, 所以这块代码用 `#if os(iOS)` 整体守卫。
    #if os(iOS)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundAssertionGeneration: UUID?
    @ObservationIgnored private var continuedProcessingSession: (any MetadataBackgroundContinuation)?
    @ObservationIgnored private var systemProcessingSessions: Set<UUID> = []
    @ObservationIgnored private var backgroundExecutionExpired = false
    #endif

    private var hasContinuedProcessingTime: Bool {
        #if os(iOS)
        continuedProcessingSession?.isGranted == true
        #else
        false
        #endif
    }

    /// Only call from a foreground user action, never from automatic upkeep
    /// or a defaults notification. The system owns progress and cancellation.
    func continueInBackgroundForUserAction() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active,
              isRunning, continuedProcessingSession == nil else { return }
        backgroundExecutionExpired = false
        let identifier = UUID()
        let session = MetadataContinuedProcessingSession(identifier: identifier,
            total: remainingCount(forSource: userInitiatedSourceID),
            started: { [weak self] in
                self?.endBackgroundTaskIfHeld()
                self?.readingConfigurationChanged()
            }, expired: { [weak self] in
                guard let self, self.continuedProcessingSession?.identifier == identifier else { return }
                self.automaticForegroundSourceIDs.subtract(self.activeSourceIDs)
                self.automaticDeviceLocalSourceID = nil
                self.pauseUserInitiated()
                self.backgroundExecutionExpired = true
            })
        continuedProcessingSession = session
        if !session.submit() { continuedProcessingSession = nil }
        #endif
    }

    #if os(iOS)
    func beginSystemBackgroundProcessing(identifier: UUID) {
        systemProcessingSessions.insert(identifier)
        backgroundExecutionExpired = false
        endBackgroundTaskIfHeld()
    }

    func systemBackgroundProcessingExpired(identifier: UUID) {
        guard systemProcessingSessions.contains(identifier), UIApplication.shared.applicationState != .active,
              executionMode != .backgroundDuringPlayback,
              !hasContinuedProcessingTime else { return }
        backgroundExecutionExpired = true
        stop()
    }

    func endSystemBackgroundProcessing(_ identifier: UUID) {
        systemProcessingSessions.remove(identifier)
        if isRunning { beginBackgroundTaskIfNeeded() }
    }
    #endif

    /// 定期把实测读取速率和当时的限制条件打在同一行。
    ///
    /// 速率慢下来的原因有好几个互不相干的来源：读取位被压、正在播放、机器发热、
    /// 低电量。单看「慢」分不出是哪一个，凑在一行就能直接对号入座。
    private func logReadThroughputIfDue(totalCompleted: Int) {
        guard let sample = throughputSampler.record(totalCompleted: totalCompleted) else {
            return
        }
        let limits = executionLimits
        let environment = readingEnvironment()
        plog(
            "📥 Backfill throughput "
                + String(format: "%.0f", sample.itemsPerMinute) + "/min "
                + "(\(sample.processedInWindow) in "
                + String(format: "%.0f", sample.windowSeconds) + "s) "
                + "workers=\(limits.workerCount) delay=\(limits.interRequestDelay) "
                + "mode=\(readingMode.rawValue) exec=\(executionMode) "
                + "playback=\(environment.playbackActive) offline=\(environment.offlineSource) "
                + "thermal=\(environment.thermalState) lowPower=\(environment.lowPowerMode)"
        )
    }

    private func finishContinuedProcessing(success: Bool) {
        #if os(iOS)
        continuedProcessingSession?.finish(success: success)
        continuedProcessingSession = nil
        #endif
    }

    init(
        library: MusicLibrary,
        sourceManager: SourceManager,
        backfillableSourceIDs: @escaping () -> Set<String> = { [] },
        bareOnlySourceIDs: @escaping () -> Set<String> = { [] },
        offlineReadableSourceIDs: @escaping () -> Set<String> = { [] },
        localFileSourceIDs: @escaping () -> Set<String> = { [] },
        manuallyReadableSourceIDs: (() -> Set<String>)? = nil,
        playbackIsActive: @escaping () -> Bool = { false }
    ) {
        self.playbackIsActive = playbackIsActive
        self.library = library
        self.sourceManager = sourceManager
        self.backfillableSourceIDs = backfillableSourceIDs
        self.bareOnlySourceIDs = bareOnlySourceIDs
        self.offlineReadableSourceIDs = offlineReadableSourceIDs
        self.localFileSourceIDs = localFileSourceIDs
        self.manuallyReadableSourceIDs = manuallyReadableSourceIDs ?? backfillableSourceIDs
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.failedURL = directory.appendingPathComponent("backfill-failed.json")
        self.incompleteURL = directory.appendingPathComponent("backfill-incomplete.json")
        self.sourceIssueURL = directory.appendingPathComponent("backfill-source-issues.json")
        self.artworkGivenUpURL = directory.appendingPathComponent("backfill-artwork-givenup.json")
        self.titleCheckedURL = directory.appendingPathComponent("backfill-title-checked.json")
        self.albumArtistCheckedURL = directory.appendingPathComponent("backfill-album-artist-checked.json")
        self.artistCheckedURL = directory.appendingPathComponent("backfill-artist-checked.json")
        self.deferredRetryURL = directory.appendingPathComponent("backfill-deferred-retry.json")
        self.diagnosticsURL = directory.appendingPathComponent("backfill-diagnostics.json")
        self.retryCountsURL = directory.appendingPathComponent("backfill-retry-counts.json")
        self.sourceRetryCountsURL = directory.appendingPathComponent("backfill-source-retry-counts.json")
        self.queueStateURL = directory.appendingPathComponent("backfill-queue-state.json")
        let defaults = UserDefaults.standard
        queueMutationGeneration = defaults.integer(
            forKey: Self.queueMutationGenerationDefaultsKey
        )
        if let data = try? Data(contentsOf: queueStateURL),
           let state = try? JSONDecoder().decode(QueueState.self, from: data) {
            persistedQueueState = state
            reconciledQueueGeneration = state.reconciledGeneration
            queueNeedsRefresh = state.needsRefresh
                || (defaults.object(forKey: Self.queueDirtyDefaultsKey) as? Bool ?? true)
                || state.reconciledGeneration != queueMutationGeneration
            cachedRemainingCount = state.remainingCount
            cachedFailedCount = state.failedCount
            cachedDeferredRetryCount = state.deferredRetryCount
            cachedStatusCount = state.statusCount
            remainingCountBySourceID = state.remainingCountBySourceID
            deferredRetryCountBySourceID = state.deferredRetryCountBySourceID
            statusCountBySourceID = state.statusCountBySourceID
        }
        loadFailed()
        loadIncomplete()
        loadSourceIssues()
        loadArtworkGivenUp()
        loadTitleChecked()
        loadAlbumArtistChecked()
        loadArtistChecked()
        loadDeferredRetries()
        loadDiagnostics()
        loadRetryCounts()
        loadSourceRetryCounts()

        // S3: 这些一次性修复都要遍历 `library.songs`。库若尚未发布,
        // 它们会在空库上把各自的 done-key 永久标记为完成。改由就绪回调驱动:
        // 同步启动路径下库在 init 返回前已就绪, 回调立即执行, 顺序保持不变。
        library.onReady { [weak self] in
            self?.runOneTimeRepairsAfterLibraryReady()
        }

        // A re-scan that found a path with new bytes wipes the failed
        // mark so backfill re-attempts the song with the fresh file. The
        // song's metadata in the library is already reset to bare by
        // `MusicLibrary.addSongs`, so `start()` will pick it up next pass.
        readingConfigurationChanged()
        configurationObservers = Self.observeReadingConfigurationChanges { [weak self] name in
            guard let self else { return }
            if name == UserDefaults.didChangeNotification {
                let mode = MetadataReadingMode.resolve(
                    storedValue: UserDefaults.standard.string(forKey: MetadataBackfillExecutionPolicy.readingModeDefaultsKey),
                    legacyFastEnabled: UserDefaults.standard.bool(forKey: MetadataBackfillExecutionPolicy.highPerformanceAfterScanDefaultsKey)
                )
                guard mode != self.readingMode else { return }
            }
            self.readingConfigurationChanged()
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            guard !songs.isEmpty else { return }
            MainActor.assumeIsolated {
                let ids = Set(songs.map(\.id))
                self.failedSongIDs.subtract(ids)
                self.incompleteSongIDs.subtract(ids)
                self.sourceIssueSongIDs.subtract(ids)
                self.sessionGivenUpIDs.subtract(ids)
                self.sessionNetworkParkedIDs.subtract(ids)
                self.sessionStallParkedIDs.subtract(ids)
                self.mutateDeferredRetries { $0.subtract(ids) }
                for id in ids { self.diagnosticRecords[id] = nil }
                self.titleCheckedIDs.subtract(ids)
                self.albumArtistCheckedIDs.subtract(ids)
                self.artistCheckedIDs.subtract(ids)
                for id in ids { self.transientFailureCounts[id] = nil }
                for sourceID in Set(songs.map(\.sourceID)) {
                    self.sourceTransientFailureCounts[sourceID] = nil
                }
                self.saveFailed()
                self.saveDeferredRetries()
                self.saveDiagnostics()
                self.saveInspectionState()
                self.saveRetryCounts()
                self.refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidSoftDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
            }
        }
    }

    /// 一次性修复 / 迁移。它们全部需要读取已发布的 `library.songs`,
    /// 因此只在库就绪之后运行一次(D-Startup 的 S3 不变量)。
    private func runOneTimeRepairsAfterLibraryReady() {
        // 这些一次性修复原本写在 init 里, 抽出来之后 `defaults` 必须在本方法
        // 内重新取得 —— 仍然是同一个 `UserDefaults.standard`, 各修复的判定与
        // 落标语义不变。
        let defaults = UserDefaults.standard
        // The first deferred-retry implementation persisted every song in a
        // source snapshot after one connector failure. That inflated a three-
        // request network interruption into hundreds of visible retries. Clear
        // those ambiguous batch markers once; corrected builds persist only the
        // request that actually failed.
        let deferredBatchRepairKey = "primuse.backfillDeferredRetryReset.v2026_08_singleFailure"
        if !UserDefaults.standard.bool(forKey: deferredBatchRepairKey) {
            if !deferredRetrySongIDs.isEmpty {
                plog("📥 Backfill: clearing \(deferredRetrySongIDs.count) inflated deferred retry markers")
                mutateDeferredRetries { $0.removeAll() }
                saveDeferredRetries()
            }
            UserDefaults.standard.set(true, forKey: deferredBatchRepairKey)
        }

        // One-time migration. Earlier builds had an overly-aggressive
        // partial-merge rule that marked any song as failed when head
        // 256KB didn't yield a duration — even if a tail-fetch would
        // have recovered it (M4A with udta in head, moov at tail are
        // the common victim). Field reports surfaced ~500 stuck songs
        // per library. Wipe the persisted set so those songs get a
        // fresh attempt under the corrected logic. Versioned key
        // prevents repeating on every launch.
        // v2026_06: 回填失败判定改为「区分瞬时/永久」后,清一次旧的 failedSongIDs,
        // 让此前被瞬时错误(源未就绪等)误钉成永久失败的歌按新逻辑重试。
        let migrationKey = "primuse.backfillFailedReset.v2026_06_transientRetry"
        if !UserDefaults.standard.bool(forKey: migrationKey), !failedSongIDs.isEmpty {
            plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time migration: transient/permanent split)")
            failedSongIDs.removeAll()
            saveFailed()
        }

        // v2026_06b: artwork-only failures used to land in failedSongIDs, which
        // dropped the song's (already parsed) duration at flush and stuck it
        // bare — playable songs that merely lacked an embedded cover ended up
        // unplayable with no cover. Now they go to artworkGivenUpIDs instead.
        // Wipe the old persisted failures once so anything stuck purely for a
        // missing cover gets a fresh pass and keeps its duration.
        let artworkDecoupleKey = "primuse.backfillFailedReset.v2026_06b_artworkDecouple"
        if !UserDefaults.standard.bool(forKey: artworkDecoupleKey) {
            if !failedSongIDs.isEmpty {
                plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time: artwork/fail decouple)")
                failedSongIDs.removeAll()
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: artworkDecoupleKey)
        }
        UserDefaults.standard.set(true, forKey: migrationKey)

        // Second one-time migration. The previous backfill stamped
        // many songs with SFB's truncated-head duration estimate
        // (typically 6–12 s for raw MP3s without XING/LAME, since
        // SFB only saw the first 256 KB). Sweep the library for
        // songs whose stored duration is < half what (fileSize ×
        // 8 / bitRate) predicts, reset their duration to 0, and
        // clear any matching failed mark so they re-enter the
        // queue. The corrected `correctedDuration` helper now
        // overwrites bogus parser values on the next pass.
        let durationFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDuration"
        if !UserDefaults.standard.bool(forKey: durationFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard let bitRate = song.bitRate, bitRate > 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(bitRate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) songs with truncated-head duration to re-trigger backfill")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFixKey)
        }

        // Third one-time migration. Some older backfill results stored
        // `bitRate = 0` alongside the truncated-head MP3 duration, so
        // the previous sweep (which required a parsed bitrate) missed
        // exactly the field-reported shape: 3-5 MB MP3s saved as
        // 10-15 second tracks. Use the same conservative 192kbps
        // fallback as `correctedDuration` and reset only when the saved
        // duration is less than half the file-size estimate.
        let durationFallbackFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDurationFallbackBitrate"
        if !UserDefaults.standard.bool(forKey: durationFallbackFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      (song.bitRate ?? 0) <= 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(Self.defaultMP3Bitrate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs with truncated duration + missing bitrate")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFallbackFixKey)
        }

        // Fourth one-time migration. Playback used to let SFB rewrite
        // cloud-stream duration from partial Range reads, so a healthy
        // 2-4 minute MP3 could regress back to ~8 seconds after the
        // previous migrations had already run. Reset every implausibly
        // short MP3 again, using parsed bitrate when available and the
        // conservative 192kbps fallback otherwise.
        let streamRewriteFixKey = "primuse.backfillFailedReset.v2026_05_streamDurationRewrite"
        if !UserDefaults.standard.bool(forKey: streamRewriteFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let effectiveBitRate = (song.bitRate ?? 0) > 0 ? song.bitRate! : Self.defaultMP3Bitrate
                let estimatedFromFileSize = Double(song.fileSize) / (Double(effectiveBitRate) * 125.0)
                if estimatedFromFileSize > 30, song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs after partial stream duration rewrite")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: streamRewriteFixKey)
        }

        // Fifth one-time migration. FLAC backfill used to rely entirely on
        // AVFoundation reading a truncated 256KB temp file. Field reports from
        // OneDrive showed those rows being marked failed because duration stayed
        // at 0. The reader now parses FLAC STREAMINFO directly from the header,
        // so clear failed marks for duration-less FLAC rows and let them retry.
        let flacStreamInfoFixKey = "primuse.backfillFailedReset.v2026_06_flacStreamInfo"
        if !UserDefaults.standard.bool(forKey: flacStreamInfoFixKey) {
            let flacIDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .flac && $0.duration <= 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(flacIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                saveFailed()
                plog("📥 Backfill: clearing \(resetIDs.count) failed FLAC rows for STREAMINFO retry")
            }
            UserDefaults.standard.set(true, forKey: flacStreamInfoFixKey)
        }

        // Sixth one-time migration. Before partial ID3 results were persisted,
        // an MP3 whose title/artist parsed correctly but whose duration did not
        // was pinned in failedSongIDs forever. Give those rows one fresh pass:
        // the native TIT2/TPE1/TALB reader can now recover their text, and the
        // worker saves that text even if duration remains unavailable.
        let partialID3FixKey = "primuse.backfillFailedReset.v2026_07_partialID3Text"
        if !UserDefaults.standard.bool(forKey: partialID3FixKey) {
            let mp3IDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .mp3
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(mp3IDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed MP3 rows for partial ID3 text retry")
            }
            UserDefaults.standard.set(true, forKey: partialID3FixKey)
        }

        // Seventh one-time migration. AVFoundation reports the duration of a
        // truncated WAV Range temp file from the bytes physically present,
        // commonly 0.495 s for our 256 KB head. WAVEHeaderParser now uses the
        // complete byte count advertised by the RIFF `data` chunk. Reset only
        // the unmistakable old signature on backfillable remote sources so a
        // genuinely short local sound effect is never touched.
        let waveDurationFixKey = "primuse.backfillReset.v2026_07_waveRangeDuration"
        if !UserDefaults.standard.bool(forKey: waveDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            var resetSongs: [Song] = []
            for song in library.songs {
                guard sourceIDs.contains(song.sourceID),
                      song.fileFormat == .wav,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0,
                      song.duration < 1.5 else { continue }
                var copy = song
                copy.duration = 0
                resetSongs.append(copy)
                failedSongIDs.remove(song.id)
                sessionGivenUpIDs.remove(song.id)
                titleCheckedIDs.remove(song.id)
                transientFailureCounts[song.id] = nil
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) remote WAV rows with truncated Range duration")
                library.replaceSongs(resetSongs)
                saveFailed()
                saveTitleChecked()
            }
            UserDefaults.standard.set(true, forKey: waveDurationFixKey)
        }

        // Eighth one-time migration. WebDAV/OpenList proxies that ignored a
        // Range request used to feed an invalid whole response into metadata
        // backfill, and those duration-less rows could already be persisted as
        // failed. Metadata reads now consume a bounded head/tail window without
        // weakening playback Range validation, so give only still-bare songs
        // from backfillable sources one fresh attempt under the corrected path.
        let rangeIgnoringProxyFixKey = "primuse.backfillFailedReset.v2026_08_rangeIgnoringProxy"
        if !UserDefaults.standard.bool(forKey: rangeIgnoringProxyFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && $0.duration <= 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed rows for Range-ignoring proxy retry")
            }
            UserDefaults.standard.set(true, forKey: rangeIgnoringProxyFixKey)
        }

        // Ninth one-time migration. A bounded MP3 header can expose a valid
        // MPEG bitrate without carrying a Xing/VBRI duration. Older backfill
        // code marked that row failed before its file-size/bitrate estimate
        // ran, so it stayed on "details unavailable" even though the stream
        // itself was valid. Retry only the rows that already have enough
        // technical evidence for the corrected path; corrupt/unknown payloads
        // remain failed instead of receiving a fabricated duration.
        let mp3BitrateDurationFixKey = "primuse.backfillFailedReset.v2026_08_mp3BitrateDuration"
        if !UserDefaults.standard.bool(forKey: mp3BitrateDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID)
                    && $0.fileFormat == .mp3
                    && $0.duration <= 0
                    && $0.fileSize > Self.headBytes * 2
                    && ($0.bitRate ?? 0) > 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed MP3 rows for bitrate duration recovery")
            }
            UserDefaults.standard.set(true, forKey: mp3BitrateDurationFixKey)
        }

        // Tenth one-time migration. Authenticated WebDAV sources can
        // redirect a media GET to an object-store/CDN endpoint. Older sessions
        // intentionally stopped at that cross-endpoint 302 and persisted a
        // metadata-backfill failure mark for an otherwise playable MP3. The transport now follows
        // read-only media redirects after removing source credentials, so give
        // still-bare remote MP3 rows one fresh pass.
        let webDAVMediaRedirectFixKey = "primuse.backfillFailedReset.v2026_08_webDAVMediaRedirect"
        if !UserDefaults.standard.bool(forKey: webDAVMediaRedirectFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID)
                    && $0.fileFormat == .mp3
                    && $0.duration <= 0
                    && $0.fileSize > 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed remote MP3 rows for media-redirect retry")
            }
            UserDefaults.standard.set(true, forKey: webDAVMediaRedirectFixKey)
        }

        // The legacy failure set mixed stale successes, temporary source
        // outages, unknown durations and real parser failures. Split only the
        // cases supported by current row data: completed rows are cleared,
        // stream/complete-file-decoder rows become playable-incomplete, and
        // ambiguous rows receive one fresh bounded read for classification.
        // No Song field or remote object is changed by this migration.
        let detailsStateMigrationKey = "primuse.backfillState.v2026_08_detailsState"
        if !UserDefaults.standard.bool(forKey: detailsStateMigrationKey) {
            let songsByID = Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0) })
            var completedCount = 0
            var incompleteCount = 0
            var retryCount = 0
            for id in Array(failedSongIDs) {
                guard let song = songsByID[id] else {
                    failedSongIDs.remove(id)
                    continue
                }
                if song.duration > 0 {
                    failedSongIDs.remove(id)
                    completedCount += 1
                } else if song.isStreamDescriptor || song.fileFormat.requiresFFmpeg {
                    failedSongIDs.remove(id)
                    incompleteSongIDs.insert(id)
                    incompleteCount += 1
                } else {
                    failedSongIDs.remove(id)
                    titleCheckedIDs.remove(id)
                    retryCount += 1
                }
            }

            let suspiciousTitleIDs = Set(library.songs.lazy.filter {
                $0.userMetadataEditedAt == nil
                    && !ServerCatalogMetadataInspectionPolicy.hasUsableTitle($0.title)
            }.map(\.id))
            titleCheckedIDs.subtract(suspiciousTitleIDs)
            saveFailed()
            saveTitleChecked()
            UserDefaults.standard.set(true, forKey: detailsStateMigrationKey)
            plog(
                "📥 Backfill: migrated legacy details state "
                    + "(completed=\(completedCount) incomplete=\(incompleteCount) "
                    + "retry=\(retryCount) suspiciousTitles=\(suspiciousTitleIDs.count))"
            )
        }

        // Standalone DTS rows that were previously inspected from a bounded
        // prefix were persisted as playable-but-incomplete because the prefix
        // cannot expose the stream's total frame count. MusicLibrary repairs
        // their duration from the complete remote byte count before this
        // service is constructed; clear the stale technical-failure state once
        // so those rows do not remain permanently excluded from normal status.
        let dtsDurationStateRepairKey = "primuse.backfillState.v2026_08_dtsDuration"
        if !defaults.bool(forKey: dtsDurationStateRepairKey) {
            let completedDTSIDs = Set(library.songs.lazy.filter { song in
                song.fileFormat == .dts
                    && song.duration.isFinite
                    && song.duration > 0
                    && AudioDurationPolicy.provisionalStandaloneDTSDuration(
                        fileSize: song.fileSize,
                        bitRateKbps: song.bitRate,
                        fileExtension: (song.filePath as NSString).pathExtension
                    ) != nil
            }.map(\.id))
            let staleStateIDs = completedDTSIDs.intersection(
                incompleteSongIDs.union(failedSongIDs)
            )
            if !staleStateIDs.isEmpty {
                incompleteSongIDs.subtract(staleStateIDs)
                failedSongIDs.subtract(staleStateIDs)
                for id in staleStateIDs { diagnosticRecords[id] = nil }
                saveFailed()
                saveDiagnostics()
                markQueueDirty()
                plog("📥 Backfill: cleared stale DTS duration state for \(staleStateIDs.count) song(s)")
            }
            defaults.set(true, forKey: dtsDurationStateRepairKey)
        }

        // Remote rows produced by the lossy-title path could be locked in both
        // titleCheckedIDs and incompleteSongIDs. Retry suspicious titles once
        // with the raw-ID3/filename policy, and retry incomplete remote MP3s
        // with the expanded MPEG-frame probe and bounded duration fallback.
        let cloudTitleAndDurationFixKey = "primuse.backfillState.v2026_08_cloudTitleAndDuration"
        if !UserDefaults.standard.bool(forKey: cloudTitleAndDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter { song in
                guard sourceIDs.contains(song.sourceID),
                      song.userMetadataEditedAt == nil else {
                    return false
                }
                let suspiciousTitle = MediaMetadataTextRepair.isSuspicious(song.title)
                    || TextEncodingRepair.requiresRawByteVerification(song.title)
                let incompleteMP3 = song.fileFormat == .mp3
                    && song.duration <= 0
                    && self.incompleteSongIDs.contains(song.id)
                return suspiciousTitle || incompleteMP3
            }.map(\.id))
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                incompleteSongIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                titleCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: retrying \(retryIDs.count) remote rows for cloud title/duration repair")
            }
            UserDefaults.standard.set(true, forKey: cloudTitleAndDurationFixKey)
        }

        // Track artist used to have no independent completion marker. A FLAC
        // row could therefore be considered complete as soon as STREAMINFO
        // supplied duration, even when its Vorbis comments were beyond the
        // first 256 KB. Reconcile the queue once and reopen only failed remote
        // FLAC rows that still have no artist; successful absence is persisted
        // by artistCheckedIDs after the new bounded inspection.
        let remoteFLACArtistFixKey = "primuse.backfillState.v2026_08_remoteFLACArtist"
        if !UserDefaults.standard.bool(forKey: remoteFLACArtistFixKey) {
            let missingArtistIDs = Set(library.songs.lazy.filter { song in
                song.fileFormat == .flac
                    && (song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.map(\.id))
            let retryIDs = failedSongIDs.intersection(missingArtistIDs)
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                artistCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveInspectionState()
                plog("📥 Backfill: reopening \(retryIDs.count) remote FLAC rows for artist repair")
            }
            markQueueDirty()
            UserDefaults.standard.set(true, forKey: remoteFLACArtistFixKey)
        }

        // FLAC and ISO-base-media covers used to be inspected only when some
        // unrelated field (most often duration or artist) was also missing.
        // Reconcile once so existing duration-complete rows get the same single
        // embedded-artwork attempt as newly scanned files.
        let embeddedArtworkFixKey = "primuse.backfillState.v2026_08_embeddedArtworkFormats"
        if !UserDefaults.standard.bool(forKey: embeddedArtworkFixKey) {
            markQueueDirty()
            UserDefaults.standard.set(true, forKey: embeddedArtworkFixKey)
        }

        // The bounded reader now understands the tag containers used by the
        // custom decoder formats. Reopen those remote rows once so an older
        // title/artwork-complete marker cannot hide newly readable album,
        // artist, track, lyrics, ReplayGain, or artwork fields.
        let expandedTagFormatsKey = "primuse.backfillState.v2026_08_expandedTagContainers"
        if !UserDefaults.standard.bool(forKey: expandedTagFormatsKey) {
            let formats: Set<AudioFormat> = [
                .ape, .wv, .mpc, .tta,
                .ogg, .opus, .speex,
                .wma, .dsf, .dff,
                .wav, .aiff, .aif,
            ]
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && formats.contains($0.fileFormat)
            }.map(\.id))
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                incompleteSongIDs.subtract(retryIDs)
                sourceIssueSongIDs.subtract(retryIDs)
                artworkGivenUpIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                sessionNetworkParkedIDs.subtract(retryIDs)
                sessionStallParkedIDs.subtract(retryIDs)
                mutateDeferredRetries { $0.subtract(retryIDs) }
                titleCheckedIDs.subtract(retryIDs)
                albumArtistCheckedIDs.subtract(retryIDs)
                artistCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveArtworkGivenUp()
                saveDeferredRetries()
                saveInspectionState()
                saveRetryCounts()
                plog("📥 Backfill: reopening \(retryIDs.count) rows for expanded tag containers")
            }
            markQueueDirty()
            UserDefaults.standard.set(true, forKey: expandedTagFormatsKey)
        }

        // Apple-produced M4A/ALAC files can store the song name only in an
        // iTunes or QuickTime metadata key that older readers skipped when
        // `commonKey` was nil. Reopen only untouched, non-CUE rows that still
        // carry a filename-derived title.
        let formatSpecificTitleKey = "primuse.backfillState.v2026_08_formatSpecificTitles"
        if !UserDefaults.standard.bool(forKey: formatSpecificTitleKey) {
            let sourceIDs = backfillableSourceIDs()
            let formats: Set<AudioFormat> = [.m4a, .alac]
            let retryIDs = Set(library.songs.lazy.filter { song in
                sourceIDs.contains(song.sourceID)
                    && formats.contains(song.fileFormat)
                    && MetadataTitleResolutionPolicy.shouldReinspectFileNameFallback(
                        currentTitle: song.title,
                        filePath: song.filePath,
                        userEdited: song.userMetadataEditedAt != nil,
                        isCueTrack: song.isCueTrack
                    )
            }.map(\.id))
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                incompleteSongIDs.subtract(retryIDs)
                sourceIssueSongIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                sessionNetworkParkedIDs.subtract(retryIDs)
                sessionStallParkedIDs.subtract(retryIDs)
                mutateDeferredRetries { $0.subtract(retryIDs) }
                titleCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveDeferredRetries()
                saveInspectionState()
                saveRetryCounts()
                plog("📥 Backfill: reopening \(retryIDs.count) ISO media rows for embedded titles")
            }
            markQueueDirty()
            UserDefaults.standard.set(true, forKey: formatSpecificTitleKey)
        }
    }

    static func observeReadingConfigurationChanges(
        center: NotificationCenter = .default,
        didChange: @escaping @MainActor @Sendable (Notification.Name) -> Void
    ) -> [NSObjectProtocol] {
        // ProcessInfo starts thermal monitoring on the first state access.
        _ = ProcessInfo.processInfo.thermalState
        return [UserDefaults.didChangeNotification,
         ProcessInfo.thermalStateDidChangeNotification,
         Notification.Name.NSProcessInfoPowerStateDidChange].map { name in
            // MusicKit can post defaults changes while holding a lock needed
            // by the main thread. A main OperationQueue would synchronously
            // wait for that thread before our callback could enqueue its Task.
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in didChange(name) }
            }
        }
    }

    deinit {
        for observer in configurationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Changes future dispatch cadence without discarding queue state. Moving
    /// into real background playback also releases the short UIKit assertion
    /// so its expiration cannot stop an audio-backed execution window.
    func setExecutionMode(_ mode: MetadataBackfillExecutionMode) {
        #if os(iOS)
        if MetadataBackfillExecutionPolicy.clearsBackgroundExpiration(entering: mode) {
            backgroundExecutionExpired = false
        }
        #endif
        guard executionMode != mode else { return }
        executionMode = mode
        readingConfigurationChanged()
        if mode == .backgroundDuringPlayback {
            // Real background audio already keeps the process eligible to run.
            // Holding a short UIApplication assertion here would make its
            // expiration handler stop an otherwise healthy slow queue at the
            // ~30 second boundary.
            endBackgroundTaskIfHeld()
        } else if isRunning {
            beginBackgroundTaskIfNeeded()
        }
        plog("📥 Backfill: execution mode -> \(String(describing: mode))")
    }

    /// Start (or resume) backfill. Idempotent — if a worker is already
    /// running this is a no-op. A durable clean state returns before touching
    /// the library array. Wi-Fi-only gating remains enforced before dispatch.
    func start() {
        // Stage 2: 库异步发布。就绪之前 `hasPendingWork` 与剩余计数都算在空
        // 模型上, 这一轮会被当成"没有待办"直接收尾 (并清掉续跑状态)。改为
        // 等发布后重试; 下面 `worker == nil` 的幂等守卫让重复注册无害。
        guard library.isReady else {
            library.onReady { [weak self] in self?.start() }
            return
        }
        #if os(iOS)
        guard !backgroundExecutionExpired || UIApplication.shared.applicationState == .active else { return }
        #endif
        // 用户把自动标签读取关掉了。手动单首/单源重读走自己的入口, 不受影响。
        guard readingMode.readsAutomatically
                || !MetadataBackfillExecutionPolicy.honoursPausedPreference(executionMode) else {
            plog("📥 Backfill: skip (tag reading paused by the user)")
            return
        }
        guard worker == nil else {
            // Worker still in flight — common during initial scan when
            // multiple onChange events fire. Logging was added because
            // a "spinner never stops" report initially looked like
            // start() wasn't being called at all.
            plog("📥 Backfill: skip (worker already running, gen=\(workerGeneration))")
            return
        }
        guard hasPendingWork else {
            finishContinuedProcessing(success: true)
            return
        }
        refreshRemainingCounts(
            force: queueNeedsRefresh
                || reconciledQueueGeneration != queueMutationGeneration
        )
        guard cachedRemainingCount > 0 else {
            finishContinuedProcessing(success: true)
            return
        }

        // Cellular gate. Backfill on a 2200-song cloud library is ~550MB, but
        // the managed iOS import source reads only sandbox files. When both
        // kinds are pending, drain the offline rows first and defer only the
        // connector/File Provider rows.
        let networkBlocked = shouldBlockForCellular()
        let allowedSourceIDs = MetadataBackfillNetworkPolicy.allowedSourceIDs(
            networkIsBlocked: networkBlocked,
            offlineReadableSourceIDs: offlineReadableSourceIDs()
        )
        if networkBlocked, allowedSourceIDs?.isEmpty != false {
            updateWaitingForWiFiState(presentPrompt: true)
            plog("📥 Backfill: deferred (cellular + Wi-Fi-only); pendingWork=\(hasPendingWork) prompt=\(pausedForCellular)")
            return
        }
        isWaitingForWiFi = networkBlocked && hasPendingNetworkReadableWork
        setCellularPromptPresented(false)

        let limits = executionLimits
        let needsBackfill = pickNextBatch(
            limit: limits.snapshotLimit,
            allowedSourceIDs: allowedSourceIDs
        )
        guard !needsBackfill.isEmpty else {
            finishContinuedProcessing(success: remainingCount(forSource: userInitiatedSourceID) == 0)
            updateWaitingForWiFiState(presentPrompt: networkBlocked)
            // Either every song has metadata OR every bare song is in
            // failedSongIDs. Surface both numbers so a "spinner stuck"
            // report can be triaged from the log without app-side
            // instrumentation.
            let sourceIDs = backfillableSourceIDs()
            let bareTotal = library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && Self.isBareSong($0)
            }.count
            plog("📥 Backfill: skip (no eligible bare songs — total=\(library.songs.count) bare=\(bareTotal) failed=\(failedSongIDs.count))")
            return
        }
        pendingCount = needsBackfill.count
        processedTotal = 0
        processedCount = 0
        throughputSampler.reset()
        isRunning = true
        workerGeneration += 1
        let generation = workerGeneration
        readProgressAccumulator.removeAll()
        readingProgress.removeAll()
        beginBackgroundTaskIfNeeded()
        // Diagnostic: prove that we only pick still-bare songs. If you see
        // this number stay >0 forever you can compare against
        // `library.songs.count` to confirm no infinite reprocessing.
        plog("📥 Backfill: gen=\(generation) mode=\(String(describing: executionMode)) bareInLib=\(remainingCount) batchHead=\(needsBackfill.count)")
        let previousWorker = drainingWorker
        drainingWorker = nil
        drainingWorkerGeneration = nil
        worker = Task { [weak self] in
            // Cancellation is cooperative. Let the previous parser release
            // its buffers and shared scheduler before admitting a new worker.
            await previousWorker?.value
            guard !Task.isCancelled else {
                // 还在等上一个 worker 收尾时就被 stop() 取消: 这个任务再也走不到
                // 下面的清理块, 而 stop() 已经把它挂到了 drainingWorker 上,
                // 所以那个句柄要在这里摘掉, 否则等待方只能一直等到宽限期。
                await MainActor.run { [weak self] in
                    guard let self,
                          self.drainingWorkerGeneration == generation else { return }
                    self.drainingWorker = nil
                    self.drainingWorkerGeneration = nil
                }
                return
            }
            await self?.runWorker()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A stopped worker parks itself in `drainingWorker`; clear that
                // handle here so a waiter can tell "still draining" from "done".
                if self.drainingWorkerGeneration == generation {
                    self.drainingWorker = nil
                    self.drainingWorkerGeneration = nil
                }
                guard self.workerGeneration == generation else { return }
                let processed = self.processedTotal
                self.processedCount = processed
                self.worker = nil
                self.isRunning = false
                self.activeSourceIDs.removeAll()
                self.readingProgress.removeAll()
                self.pendingCount = 0
                if self.statePersistenceTask != nil {
                    self.scheduleStatePersistence(immediate: true)
                }
                self.updateWaitingForWiFiState(presentPrompt: true)
                self.endBackgroundTaskIfHeld()
                self.finishContinuedProcessing(
                    success: self.remainingCount(forSource: self.userInitiatedSourceID) == 0
                )
                if self.executionMode == .foregroundAfterSourceScan {
                    self.setExecutionMode(.standard)
                }
                if self.executionMode == .foregroundDeviceLocal,
                   let sourceID = self.automaticDeviceLocalSourceID,
                   self.remainingCount(forSource: sourceID) == 0 {
                    self.automaticDeviceLocalSourceID = nil
                    self.setExecutionMode(.standard)
                }
                if self.executionMode == .userInitiated,
                   let sourceID = self.userInitiatedSourceID,
                   self.remainingCount(forSource: sourceID) == 0 {
                    self.userInitiatedSourceID = nil
                    self.setExecutionMode(.standard)
                }
                #if os(iOS)
                if self.executionMode == .standard,
                   UIApplication.shared.applicationState == .active {
                    _ = self.resumeAutomaticForegroundIfNeeded()
                }
                #endif
                // 完成通知 ── 处理 >= 5 首才发, 避免每次 worker 短跑都打扰用户。
                // hasPendingWork == false 表示当前没遗留 ── 队列全清才算"完成"。
                // postIfEnabled 内部会检查用户在设置页是否开了开关 + 系统是否已授权,
                // 不满足条件直接 noop。
                if processed >= 5 && !self.hasPendingWork {
                    let processedCount = processed
                    Task {
                        await UserNotificationService.shared.postLongTaskCompletion(
                            category: .rescrapeLibraryDone,
                            title: String(localized: "backfill_done_title"),
                            body: String(format: String(localized: "backfill_done_body"), processedCount)
                        )
                    }
                }
            }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        guard !hasContinuedProcessingTime, systemProcessingSessions.isEmpty else { return }
        guard executionMode != .backgroundDuringPlayback else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        guard backgroundTaskID == .invalid else { return }
        let assertionGeneration = UUID()
        backgroundAssertionGeneration = assertionGeneration
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "primuse.backfill") { [weak self] in
            // Runs on the main thread; release the assertion before the
            // expiration grace period ends instead of after a main-actor hop.
            MainActor.assumeIsolated {
                guard let self, self.backgroundAssertionGeneration == assertionGeneration,
                      !self.hasContinuedProcessingTime, self.systemProcessingSessions.isEmpty,
                      UIApplication.shared.applicationState != .active else { return }
                self.backgroundExecutionExpired = true
                self.stop()
            }
        }
        plog("📥 Backfill: beginBackgroundTask id=\(backgroundTaskID.rawValue)")
        #endif
    }

    private func endBackgroundTaskIfHeld() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundAssertionGeneration = nil
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        plog("📥 Backfill: endBackgroundTask id=\(id.rawValue)")
        #endif
    }

    /// Stop the worker after the in-flight song finishes. Safe to call on
    /// background-task expiration; nothing is left in a half-state because
    /// `replaceSong` is atomic. Bumping the generation here is what tells
    /// the in-flight worker's MainActor cleanup block to skip — it's no
    /// longer the "current" worker, so it must not touch shared state.
    func stop(preservingContinuation: Bool = false) {
        if !preservingContinuation { finishContinuedProcessing(success: false) }
        deferredQueueReconcileTask?.cancel()
        deferredQueueReconcileTask = nil
        // A hard stop ends any scene-transition pause: the parked worker is
        // being cancelled, and its final flush must be allowed to publish.
        isSceneTransitionPaused = false
        let drainedGeneration = workerGeneration
        workerGeneration += 1
        if let worker {
            drainingWorker = worker
            drainingWorkerGeneration = drainedGeneration
        }
        worker?.cancel()
        worker = nil
        isRunning = false
        activeSourceIDs.removeAll()
        readingProgress.removeAll()
        pendingCount = 0
        updateWaitingForWiFiState(presentPrompt: false)
        if statePersistenceTask != nil {
            scheduleStatePersistence(immediate: true)
        }
        endBackgroundTaskIfHeld()
        if executionMode == .foregroundAfterSourceScan {
            setExecutionMode(.standard)
        }
        // The live worker just became a draining one. Anyone parked on it is
        // now waiting on work this service no longer owns.
        releaseWorkerWaits()
    }

    /// Starts a source-scoped foreground job only after an explicit user
    /// action. It keeps taking bounded snapshots until this source's
    /// ordinary eligible queue drains. Terminal per-song failures are recorded
    /// and skipped; only source-wide unavailability parks the remaining rows.
    @discardableResult
    func startUserInitiated(sourceID: String) -> Bool {
        guard backfillableSourceIDs().contains(sourceID),
              !library.disabledSourceIDs.contains(sourceID) else {
            return false
        }
        if worker != nil { stop() }
        userInitiatedSourceID = sourceID
        setExecutionMode(.userInitiated)
        refreshRemainingCounts(force: true)
        guard remainingCount(forSource: sourceID) > 0 else {
            finishContinuedProcessing(success: true)
            userInitiatedSourceID = nil
            setExecutionMode(.standard)
            return false
        }
        start()
        continueInBackgroundForUserAction()
        return isRunning || isWaitingForWiFi
    }

    func pauseUserInitiated(sourceID: String? = nil) {
        guard sourceID == nil || userInitiatedSourceID == sourceID else { return }
        if let pausedSourceID = userInitiatedSourceID {
            automaticForegroundSourceIDs.remove(pausedSourceID)
            if automaticDeviceLocalSourceID == pausedSourceID { automaticDeviceLocalSourceID = nil }
        }
        userInitiatedSourceID = nil
        stop()
        setExecutionMode(.standard)
    }

    func isUserInitiated(forSource sourceID: String) -> Bool {
        userInitiatedSourceID == sourceID
    }

    /// Scene transitions suspend network work but preserve the user's intent.
    /// Resume only after the app is active again; background callbacks continue
    /// to use the separately bounded `.background` profiles.
    @discardableResult
    func resumeUserInitiatedIfNeeded() -> Bool {
        guard let sourceID = userInitiatedSourceID,
              backfillableSourceIDs().contains(sourceID),
              !library.disabledSourceIDs.contains(sourceID) else {
            userInitiatedSourceID = nil
            return false
        }
        // A bounded background wake may have drained this source while the
        // scene was inactive. Reconcile once before restoring the foreground
        // intent so an already-finished job does not remain presented as a
        // user-paused session with no eligible rows.
        refreshRemainingCounts(force: true)
        guard remainingCount(forSource: sourceID) > 0 else {
            finishContinuedProcessing(success: true)
            userInitiatedSourceID = nil
            setExecutionMode(.standard)
            return false
        }
        setExecutionMode(.userInitiated)
        start()
        return true
    }

    /// Keep the intent from a completed foreground scan through scene changes.
    /// Background callbacks keep draining while execution time is available.
    @discardableResult
    func resumeAutomaticForegroundIfNeeded() -> Bool {
        guard automaticDeviceLocalSourceID != nil || !automaticForegroundSourceIDs.isEmpty else { return false }
        // 后台档位起的 worker 作用域是全库 (`makeBatchSelectionInput` 只给
        // `.userInitiated` 缩过范围)。`start()` 遇到在跑的 worker 是幂等的,
        // 所以不先停掉的话, 前台自动续跑设的新作用域要等下一批快照才生效,
        // 等于白等一整批。场景切换的暂停/恢复不受影响: 那时的档位不是后台档。
        let wasBackgroundScoped = worker != nil
            && (executionMode == .background || executionMode == .backgroundDuringPlayback)
        refreshRemainingCounts(force: true)
        let readable = backfillableSourceIDs().subtracting(library.disabledSourceIDs)
        automaticForegroundSourceIDs = automaticForegroundSourceIDs.filter {
            readable.contains($0) && remainingCount(forSource: $0) > 0
        }
        if let sourceID = automaticDeviceLocalSourceID,
           readable.contains(sourceID),
           offlineReadableSourceIDs().contains(sourceID),
           remainingCount(forSource: sourceID) > 0 {
            setExecutionMode(.foregroundDeviceLocal)
        } else {
            automaticDeviceLocalSourceID = nil
            guard !automaticForegroundSourceIDs.isEmpty else { return false }
            setExecutionMode(.foregroundAfterSourceScan)
        }
        if wasBackgroundScoped { stop(preservingContinuation: true) }
        start()
        return true
    }

    /// Re-evaluate active work after a source was enabled or disabled. Only
    /// that source's transient circuit-breaker state is reset; changing one
    /// connector must not silently grant fresh retries to every other source.
    /// Permanently unparseable rows remain excluded by `failedSongIDs`.
    func sourceAvailabilityChanged(forSourceID sourceID: String) {
        stop()
        if userInitiatedSourceID == sourceID,
           (!backfillableSourceIDs().contains(sourceID)
                || library.disabledSourceIDs.contains(sourceID)) {
            userInitiatedSourceID = nil
            setExecutionMode(.standard)
        }
        if automaticDeviceLocalSourceID == sourceID,
           (!offlineReadableSourceIDs().contains(sourceID)
                || library.disabledSourceIDs.contains(sourceID)) {
            automaticDeviceLocalSourceID = nil
            setExecutionMode(.standard)
        }
        let songIDs = Set(library.songs.lazy.filter {
            $0.sourceID == sourceID
        }.map(\.id))
        sourceIssueSongIDs.subtract(songIDs)
        sessionGivenUpIDs.subtract(songIDs)
        sessionNetworkParkedIDs.subtract(songIDs)
        sessionStallParkedIDs.subtract(songIDs)
        for id in songIDs {
            switch diagnosticRecords[id]?.state {
            case .sourceUnavailable, .fileUnavailable, .retryPending, .stalled:
                diagnosticRecords[id] = nil
            case .unreadableTags, .playableIncomplete, .pendingInspection,
                 .waitingForWiFi, nil:
                break
            }
        }
        for id in songIDs { transientFailureCounts[id] = nil }
        sourceTransientFailureCounts[sourceID] = nil
        saveFailed()
        saveDiagnostics()
        saveRetryCounts()
        refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
    }

    /// A completed source scan proves that catalogue access has recovered and
    /// may also have committed brand-new bare rows. If an older outage exhausted
    /// the source-wide backfill circuit breaker, grant the unresolved rows one
    /// fresh bounded retry budget. Every successful scan with eligible rows
    /// refreshes the queue; an active iOS scene keeps running gentle serial
    /// snapshots until the eligible queue drains or the scene changes.
    func sourceScanSucceeded(forSourceID sourceID: String) {
        let retryableSongIDs = Set(library.songs.lazy.filter { [self] song in
            song.sourceID == sourceID
                && !failedSongIDs.contains(song.id)
                && !sourceIssueSongIDs.contains(song.id)
                && !sessionStallParkedIDs.contains(song.id)
                && needsBackfill(song)
        }.map(\.id))
        guard !retryableSongIDs.isEmpty else { return }

        let sourceAttemptCount = sourceTransientFailureCounts[sourceID] ?? 0
        if MetadataBackfillSourceRecoveryPolicy.shouldRenewRetryBudget(
            sourceAttemptCount: sourceAttemptCount,
            unresolvedSongCount: retryableSongIDs.count
        ) {
            sessionGivenUpIDs.subtract(retryableSongIDs)
            sessionNetworkParkedIDs.subtract(retryableSongIDs)
            for songID in retryableSongIDs {
                transientFailureCounts[songID] = nil
            }
            sourceTransientFailureCounts[sourceID] = nil
            saveRetryCounts()
            plog(
                "📥 Backfill: successful source scan renewed exhausted retry budget "
                    + "source=\(sourceID) unresolved=\(retryableSongIDs.count)"
            )
        }

        #if os(iOS)
        if UIApplication.shared.applicationState == .active {
            automaticForegroundSourceIDs.insert(sourceID)
            if offlineReadableSourceIDs().contains(sourceID) {
                automaticDeviceLocalSourceID = sourceID
            }
            if userInitiatedSourceID == sourceID {
                setExecutionMode(.userInitiated)
            } else if userInitiatedSourceID == nil,
                      automaticDeviceLocalSourceID == sourceID {
                setExecutionMode(.foregroundDeviceLocal)
            } else if userInitiatedSourceID == nil {
                setExecutionMode(.foregroundAfterSourceScan)
            }
            refreshQueue(startImmediately: true)
        } else {
            refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
        }
        #else
        if userInitiatedSourceID == sourceID {
            setExecutionMode(.userInitiated)
        } else {
            setExecutionMode(.foregroundAfterSourceScan)
        }
        refreshQueue()
        #endif
    }

    /// Drop queued work for a source that was removed. The
    /// worker processes fixed snapshots, so without stopping it a deleted
    /// 10K-song source can keep burning through stale rows until relaunch.
    func discardWork(forSourceID sourceID: String) {
        discardWork(forSourceIDs: [sourceID])
    }

    func discardWork(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        pendingDiscardSourceIDs.formUnion(sourceIDs)
        // Network work must stop immediately; only the potentially expensive
        // library/state sweep is debounced.
        stop()

        discardWorkTask?.cancel()
        discardWorkTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flushPendingDiscardWork()
        }
    }

    /// Used by the source-cleanup coordinator after MusicLibrary has prepared
    /// the removed IDs off-main. Supplying that set avoids another full-library
    /// sweep on the main actor while preserving every persisted retry cleanup.
    func discardWorkNow(
        forSourceIDs sourceIDs: Set<String>,
        knownSongIDs: Set<String>
    ) {
        guard !sourceIDs.isEmpty else { return }
        stop()
        pendingDiscardSourceIDs.subtract(sourceIDs)
        if pendingDiscardSourceIDs.isEmpty {
            discardWorkTask?.cancel()
            discardWorkTask = nil
        }
        discardPersistedWork(
            forSourceIDs: sourceIDs,
            songIDs: knownSongIDs
        )
    }

    private func flushPendingDiscardWork() {
        let sourceIDs = pendingDiscardSourceIDs
        pendingDiscardSourceIDs.removeAll(keepingCapacity: true)
        discardWorkTask = nil
        guard !sourceIDs.isEmpty else { return }

        let songIDs = Set(library.songs.lazy.filter {
            sourceIDs.contains($0.sourceID)
        }.map(\.id))
        discardPersistedWork(forSourceIDs: sourceIDs, songIDs: songIDs)
    }

    private func discardPersistedWork(
        forSourceIDs sourceIDs: Set<String>,
        songIDs: Set<String>
    ) {
        guard !sourceIDs.isEmpty else { return }
        // Even an empty removed source stopped the shared worker. Preserve
        // other sources' explicit intent and resume after cleanup completes.
        defer {
            markQueueDirty()
            resumeReadingAfterSourceRemoval()
        }
        automaticForegroundSourceIDs.subtract(sourceIDs)

        if let activeSourceID = userInitiatedSourceID,
           sourceIDs.contains(activeSourceID) {
            userInitiatedSourceID = nil
            setExecutionMode(.standard)
        }
        if let activeSourceID = automaticDeviceLocalSourceID,
           sourceIDs.contains(activeSourceID) {
            automaticDeviceLocalSourceID = nil
            setExecutionMode(.standard)
        }

        guard !songIDs.isEmpty else { return }
        failedSongIDs.subtract(songIDs)
        incompleteSongIDs.subtract(songIDs)
        sourceIssueSongIDs.subtract(songIDs)
        sessionGivenUpIDs.subtract(songIDs)
        sessionNetworkParkedIDs.subtract(songIDs)
        sessionStallParkedIDs.subtract(songIDs)
        mutateDeferredRetries { $0.subtract(songIDs) }
        for songID in songIDs { diagnosticRecords[songID] = nil }
        titleCheckedIDs.subtract(songIDs)
        albumArtistCheckedIDs.subtract(songIDs)
        artistCheckedIDs.subtract(songIDs)
        for id in songIDs { transientFailureCounts[id] = nil }
        for sourceID in sourceIDs { sourceTransientFailureCounts[sourceID] = nil }
        saveFailed()
        saveDeferredRetries()
        saveDiagnostics()
        saveInspectionState()
        saveRetryCounts()
    }

    private func resumeReadingAfterSourceRemoval() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        if !resumeUserInitiatedIfNeeded(), !resumeAutomaticForegroundIfNeeded() {
            #if !os(iOS)
            start()
            #endif
        }
    }

    /// Re-evaluate the queue every time the library changes (e.g. a fresh
    /// scan added new bare songs). Call after scan completion or song add.
    func refreshQueue(startImmediately: Bool = true) {
        markQueueDirty()
        switch MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: startImmediately,
            workerIsRunning: worker != nil,
            requiresSynchronousStart: hasBlockingBackgroundSession
        ) {
        case .markDirtyOnly:
            return
        case .synchronous:
            start()
        case .deferredOffMain:
            scheduleDeferredQueueReconcile()
        }
    }

    /// 后台处理会话 / continued-processing 授权期间, 调用方
    /// (`BackgroundProcessingDrain` 的 start() + waitUntilIdle) 只看
    /// `worker != nil`, 所以 start() 必须留在调用方这一个 turn 上。
    private var hasBlockingBackgroundSession: Bool {
        #if os(iOS)
        !systemProcessingSessions.isEmpty || continuedProcessingSession != nil
        #else
        false
        #endif
    }

    /// 资料库每发布一批扫描结果就会走一次 refreshQueue; 原来紧接着的 start()
    /// 会在调用方这一个主 actor turn 上跑整库对账 (每个未完成行还要建一个展示
    /// 项)。这里改成先跑已有的 off-main 变体, 回来时队列已经干净, start() 里的
    /// force 变成 false 并被 5 秒节流跳过 —— 计数与 UI 语义不变。连续多次发布
    /// 只有最后一次会真正把 worker 拉起来。
    private func scheduleDeferredQueueReconcile() {
        let generation = workerGeneration
        deferredQueueReconcileTask?.cancel()
        deferredQueueReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshRemainingCountsOffMain(force: true)
            guard !Task.isCancelled,
                  self.worker == nil,
                  self.workerGeneration == generation else { return }
            self.start()
        }
    }

    /// A genuinely new usable network path grants one more automatic attempt to
    /// work parked by transport failures, without resetting its persisted retry
    /// budget. Stalled state-application snapshots remain parked because a route
    /// change cannot make an in-memory library write start sticking.
    func networkPathChanged(startImmediately: Bool = true) {
        guard hasPendingWork || !sessionNetworkParkedIDs.isEmpty else { return }
        guard NetworkMonitor.shared.isReachable, !shouldBlockForCellular() else {
            updateWaitingForWiFiState(presentPrompt: true)
            if startImmediately, hasPendingOfflineReadableWork, worker == nil {
                start()
            }
            return
        }
        resumeNetworkParkedWork()
        if startImmediately, worker == nil { start() }
    }

    private func resumeNetworkParkedWork() {
        guard !sessionNetworkParkedIDs.isEmpty else { return }
        let retryableIDs = Set(sessionNetworkParkedIDs.filter { songID in
            guard let song = library.song(id: songID) else { return false }
            return !Self.automaticRetriesExhausted(
                songID: songID,
                sourceID: song.sourceID,
                retryCounts: transientFailureCounts,
                sourceRetryCounts: sourceTransientFailureCounts
            )
        })
        guard !retryableIDs.isEmpty else { return }
        sessionNetworkParkedIDs.subtract(retryableIDs)
        sessionGivenUpIDs.subtract(retryableIDs)
        refreshRemainingCounts(force: true)
        plog("📥 Backfill: network path changed; resumed \(retryableIDs.count) deferred inspections")
    }

    /// Called by scanners for IDs whose title source was already inspected in
    /// this scan. A usable server-catalog title does not prove that the file's
    /// album-artist tag was inspected, so that independent leg stays open.
    func acknowledgeScannerMetadataInspection(songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let previousTitleCount = titleCheckedIDs.count
        titleCheckedIDs.formUnion(songIDs)
        guard titleCheckedIDs.count != previousTitleCount else { return }
        saveInspectionState()
        refreshRemainingCounts(force: true)
    }

    /// True when the system background-processing window this service was
    /// running in has already expired, so the system is taking the execution
    /// time back regardless of what the scene is doing.
    private var hasExpiredSystemBackgroundProcessing: Bool {
        #if os(iOS)
        backgroundExecutionExpired
        #else
        false
        #endif
    }

    /// Single entry point for the scene handler: the policy decides, this
    /// applies. Keeping the decision in `MetadataBackfillSceneTransitionPolicy`
    /// is what makes the shipped behaviour the behaviour its suite exercises.
    func applySceneTransition(phase: ScenePhaseKind, isPlaybackActive: Bool) {
        switch MetadataBackfillSceneTransitionPolicy.disposition(
            phase: phase,
            isPlaybackActive: isPlaybackActive,
            isSystemBackgroundProcessing: hasExpiredSystemBackgroundProcessing
        ) {
        case .pause:
            pauseForSceneTransition()
        case .hardStop:
            // `stop()` also clears the pause flag, so an expired background
            // window returning through `.active` cannot leave a parked worker
            // behind with a zero budget.
            stop(preservingContinuation: true)
        case .resume:
            resumeAfterSceneTransition()
        }
    }

    /// Suspend reading for a scene transition that may not be a real
    /// backgrounding.
    ///
    /// Cancelling the worker on `.inactive` throws away the bytes of every read
    /// that completed microseconds earlier: the scheduler's consumer loop
    /// breaks on `Task.isCancelled` before it drains the queued events, so a
    /// finished read is converted to `.cancelled` and its `completed` callback
    /// never runs. Dropping the worker count to zero instead keeps the worker,
    /// the snapshot and the accumulated batch alive while admitting no new I/O.
    private func pauseForSceneTransition() {
        guard !isSceneTransitionPaused else { return }
        isSceneTransitionPaused = true
        activeScheduler?.configurationChanged()
        for other in batchSchedulers.values { other.configurationChanged() }
        plog("📥 Backfill: paused for scene transition (gen=\(workerGeneration))")
    }

    /// The scene is back in the foreground: re-admit readers and let the
    /// accumulated batch publish on the next completion.
    private func resumeAfterSceneTransition() {
        guard isSceneTransitionPaused else { return }
        isSceneTransitionPaused = false
        activeScheduler?.configurationChanged()
        for other in batchSchedulers.values { other.configurationChanged() }
        plog("📥 Backfill: resumed after scene transition (gen=\(workerGeneration))")
    }

    /// Block until the worker finishes draining the current queue. Used by
    /// the BGProcessingTask handler so iOS doesn't yank us mid-work.
    ///
    /// A live worker is awaited directly and without a bound, which is the
    /// historical meaning and removes the up-to-five-second gap between the
    /// worker's last flush and the handler's `finish()`. After `stop()` the
    /// live task is parked in `drainingWorker`, still running its in-flight
    /// reads and final flush; the old `worker != nil` test returned
    /// immediately there and let the handler complete on top of that work.
    /// That drain is waited out too, but only up to `drainGrace`, so an
    /// expired BGProcessing task can never be held open by it.
    func waitUntilIdle(drainGrace: TimeInterval = MetadataBackfillDrainWaitPolicy.drainGrace) async {
        // 宽限只约束"没有活着的 worker、只剩收尾任务"的那一段, 所以从观察到
        // 这个状态的那一刻开始计时, 而不是从进入等待开始。
        var drainStartedAt: ContinuousClock.Instant?
        while true {
            let liveWorker = worker
            if liveWorker != nil {
                drainStartedAt = nil
            } else if drainStartedAt == nil {
                drainStartedAt = ContinuousClock.now
            }
            guard MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
                hasWorker: liveWorker != nil,
                hasDrainingWorker: drainingWorker != nil,
                elapsedSinceStop: drainStartedAt.map { Self.seconds(since: $0) } ?? 0,
                grace: drainGrace,
                callerCancelled: Task.isCancelled
            ) else { return }
            if let live = liveWorker {
                await awaitWorkerCompletionOrRelease(live)
                continue
            }
            // The draining task is already cancelled; awaiting its value would
            // ignore the grace entirely (`Task<Void, Never>.value` cannot be
            // interrupted), so poll it at a sub-frame interval instead.
            try? await Task.sleep(
                for: .seconds(MetadataBackfillDrainWaitPolicy.drainPollInterval)
            )
        }
    }

    /// Wait for the live worker, but let `stop()` (which is what a
    /// BGProcessing expiry runs) and the caller's own cancellation end the wait
    /// immediately.
    ///
    /// `Task<Void, Never>.value` ignores the awaiting task's cancellation and
    /// takes no deadline, so a bare `await live.value` keeps standing guard over
    /// a worker that has already been moved aside and cancelled — the loop head,
    /// where the grace is enforced, is never reached again. Parking on a latch
    /// that `stop()` also releases keeps the completion itself as the primary
    /// signal while making "this is no longer my work" observable.
    private func awaitWorkerCompletionOrRelease(_ live: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let latch = MetadataBackfillWorkerWaitLatch(continuation)
                workerWaitLatches.append(latch)
                Task { @MainActor [weak self] in
                    await live.value
                    self?.workerWaitLatches.removeAll { $0 === latch }
                    latch.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseWorkerWaits() }
        }
    }

    /// Wake every parked `waitUntilIdle`; each one re-evaluates at its loop head.
    private func releaseWorkerWaits() {
        let latches = workerWaitLatches
        workerWaitLatches.removeAll()
        for latch in latches { latch.resume() }
    }

    private nonisolated static func seconds(since instant: ContinuousClock.Instant) -> TimeInterval {
        let components = (ContinuousClock.now - instant).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Duration is the load-bearing signal for legacy rows, but the worker also
    /// owns one-time title, embedded-artwork, and album-artist inspections.
    /// Each leg has its own completion marker so a legitimately absent optional
    /// tag never makes the song eligible forever.
    static func isBareSong(_ song: Song) -> Bool {
        song.duration <= 0
    }

    /// True if there are bare songs in the library that backfill could
    /// process. Reflects queue state, not just whether a worker is
    /// currently running — a cellular-paused service shows
    /// `isRunning == false` but still has pending work that should keep
    /// BGProcessingTask scheduled.
    var hasPendingWork: Bool {
        queueNeedsRefresh
            || reconciledQueueGeneration != queueMutationGeneration
            || cachedRemainingCount > 0
    }

    var activityState: MetadataBackfillActivityState {
        .resolve(
            hasPendingWork: hasPendingWork,
            isRunning: isRunning,
            isWaitingForWiFi: isWaitingForWiFi,
            hasDeferredRetryWork: hasDeferredRetryWork
        )
    }

    func activityState(forSource sourceID: String) -> MetadataBackfillActivityState {
        .resolve(
            hasPendingWork: remainingCount(forSource: sourceID) > 0,
            isRunning: isRunning && activeSourceIDs.contains(sourceID),
            isWaitingForWiFi: isWaitingForWiFi,
            hasDeferredRetryWork: deferredRetryCount(forSource: sourceID) > 0
        )
    }

    /// Number of songs currently waiting for backfill. Used by the UI to
    /// show "loading details · N remaining" — the older `pendingCount`
    /// was a snapshot at start time so it could disagree with reality
    /// after Phase A added more bare songs mid-backfill.
    var remainingCount: Int {
        cachedRemainingCount
    }

    /// Persisted transient retries overlap with the active queue after a
    /// relaunch. `statusCount` avoids double-counting that overlap while still
    /// keeping a parked retry visible after the current worker gives up.
    var statusCount: Int {
        cachedStatusCount
    }

    var hasDeferredRetryWork: Bool {
        cachedDeferredRetryCount > 0
    }

    func detailsState(for song: Song, isLocalSource: Bool) -> SongDetailsState {
        // The backing ID sets are intentionally observation-ignored: otherwise
        // completing one file invalidates every visible row that queried a
        // different ID. This coarse revision publishes the same state at the
        // existing batch/status cadence instead of once per network response.
        _ = statusRevision
        let waitingForSource = sourceIssueSongIDs.contains(song.id)
            || sessionGivenUpIDs.contains(song.id)
            || Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: transientFailureCounts,
                sourceRetryCounts: sourceTransientFailureCounts
            )
            || library.disabledSourceIDs.contains(song.sourceID)
            || (isWaitingForWiFi && needsBackfill(song))
        let confirmedFailure = failedSongIDs.contains(song.id)
        let incomplete = incompleteSongIDs.contains(song.id)
            || (isLocalSource && song.duration <= 0 && song.isPlayable)
        let reading = !waitingForSource
            && !confirmedFailure
            && needsBackfill(song)

        return .resolve(
            duration: song.duration,
            isStandaloneMusicVideo: song.isStandaloneMusicVideo,
            isPlayable: song.isPlayable,
            isReading: reading,
            isWaitingForSource: waitingForSource,
            isIncomplete: incomplete,
            hasConfirmedFailure: confirmedFailure
        )
    }

    /// Per-source variant — used by the source card so its "remaining"
    /// number matches the global storage page rather than counting
    /// songs that backfill has given up on.
    func remainingCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedRemainingCount }
        return remainingCountBySourceID[sourceID] ?? 0
    }

    func deferredRetryCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedDeferredRetryCount }
        return deferredRetryCountBySourceID[sourceID] ?? 0
    }

    func statusCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedStatusCount }
        return statusCountBySourceID[sourceID] ?? 0
    }

    func isDeferredRetry(songID: String) -> Bool {
        // 只依赖成员版本号。`statusRevision` 每次状态对账都会前进, 让每一行
        // 都跟着重绘; 这里关心的只是"这首歌在不在重试集合里"。
        _ = deferredRetryRevision
        return deferredRetryMembership.contains(songID)
    }

    func refreshStatusSnapshot() {
        refreshRemainingCounts(force: true)
    }

    func sourceStatusSummary(forSource sourceID: String) -> MetadataBackfillSourceSummary {
        sourceStatusSummaries[sourceID] ?? MetadataBackfillSourceSummary()
    }

    func statusDisplayItems(
        forSource sourceID: String
    ) -> [MetadataBackfillStatusDisplayItem] {
        statusDisplayItemsBySourceID[sourceID] ?? []
    }

    func hasStatusDisplaySnapshot(forSource sourceID: String) -> Bool {
        statusDisplayItemsBySourceID[sourceID] != nil
    }

    private struct RemainingCountsInput: Sendable {
        let sourceIDs: Set<String>
        let bareOnlySourceIDs: Set<String>
        let songs: [Song]
        let disabledSourceIDs: Set<String>
        let failedSongIDs: Set<String>
        let incompleteSongIDs: Set<String>
        let sourceIssueSongIDs: Set<String>
        let sessionGivenUpIDs: Set<String>
        let sessionNetworkParkedIDs: Set<String>
        let sessionStallParkedIDs: Set<String>
        let transientFailureCounts: [String: Int]
        let sourceTransientFailureCounts: [String: Int]
        let artworkGivenUpIDs: Set<String>
        let titleCheckedIDs: Set<String>
        let albumArtistCheckedIDs: Set<String>
        let artistCheckedIDs: Set<String>
        let deferredRetrySongIDs: Set<String>
        let diagnosticRecords: [String: MetadataBackfillDiagnosticRecord]
        let isWaitingForWiFi: Bool
    }

    private struct RemainingCountsComputation: Sendable {
        let remainingBySource: [String: Int]
        let deferredBySource: [String: Int]
        let statusBySource: [String: Int]
        let summaries: [String: MetadataBackfillSourceSummary]
        let displayItemsBySource: [String: [MetadataBackfillStatusDisplayItem]]
        /// 在这趟(通常在后台执行器上的)遍历里顺带折出的展示行指纹。主 actor
        /// 只比较这一个值, 不再对成千上万条带字符串的展示行做字典相等比较。
        let displayItemsSignature: MetadataBackfillStatusSignature
        let remainingTotal: Int
        let deferredTotal: Int
        let statusTotal: Int
        let failedTotal: Int
    }

    private func makeRemainingCountsInput() -> RemainingCountsInput {
        RemainingCountsInput(
            sourceIDs: backfillableSourceIDs(),
            bareOnlySourceIDs: bareOnlySourceIDs(),
            songs: library.songs,
            disabledSourceIDs: library.disabledSourceIDs,
            failedSongIDs: failedSongIDs,
            incompleteSongIDs: incompleteSongIDs,
            sourceIssueSongIDs: sourceIssueSongIDs,
            sessionGivenUpIDs: sessionGivenUpIDs,
            sessionNetworkParkedIDs: sessionNetworkParkedIDs,
            sessionStallParkedIDs: sessionStallParkedIDs,
            transientFailureCounts: transientFailureCounts,
            sourceTransientFailureCounts: sourceTransientFailureCounts,
            artworkGivenUpIDs: artworkGivenUpIDs,
            titleCheckedIDs: titleCheckedIDs,
            albumArtistCheckedIDs: albumArtistCheckedIDs,
            artistCheckedIDs: artistCheckedIDs,
            deferredRetrySongIDs: deferredRetrySongIDs,
            diagnosticRecords: diagnosticRecords,
            isWaitingForWiFi: isWaitingForWiFi
        )
    }

    private func refreshRemainingCounts(force: Bool = false) {
        // Stage 2b: 库还在准备时整库是空的, 这一轮会把"0 条待办"对账并把
        // `needsRefresh: false` 写进 backfill-queue-state.json —— 之后没有任何
        // 人会把队列重新标脏(后台唤醒的进程里根本没有 SwiftUI 场景)。保持脏
        // 状态原样返回, 发布之后的任意一次对账都会重算。
        guard library.isReady else { return }
        let now = Date()
        guard force
                || now.timeIntervalSince(lastRemainingCountRefreshAt)
                    >= remainingCountRefreshInterval else { return }
        lastRemainingCountRefreshAt = now
        remainingCountComputationGeneration &+= 1
        applyRemainingCounts(Self.computeRemainingCounts(makeRemainingCountsInput()))
    }

    private func refreshRemainingCountsOffMain(force: Bool = false) async {
        // 同 `refreshRemainingCounts`: 准备中的库不参与对账, 也不落盘。
        guard library.isReady else { return }
        let now = Date()
        guard force
                || now.timeIntervalSince(lastRemainingCountRefreshAt)
                    >= remainingCountRefreshInterval else { return }
        lastRemainingCountRefreshAt = now
        remainingCountComputationGeneration &+= 1
        let computationGeneration = remainingCountComputationGeneration
        let songMutationGeneration = library.songMutationGenerationForMaintenance
        let queueGeneration = queueMutationGeneration
        let input = makeRemainingCountsInput()
        let computation = await Task.detached(priority: .utility) {
            Self.computeRemainingCounts(input)
        }.value
        // 代次被顶替与"输入真的变了"必须分开: 被顶替时接管的那次刷新还在跑,
        // 把节流时间戳退回 .distantPast 会让它之后的 start() 再次整库同步对账。
        // "歌曲代次动了"又要再分出来: 扫描每 1.5 s 发布一次库, 整场扫描里
        // 几乎每一次 off-main 对账都会跨过一次发布。那只说明快照稍微旧了,
        // 数字仍然自洽, 可以发给源卡片; 队列则保持脏着, 下一轮照旧对账。
        let superseded = remainingCountComputationGeneration != computationGeneration
        let application = MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: superseded,
            songGenerationChanged:
                library.songMutationGenerationForMaintenance != songMutationGeneration,
            queueGenerationChanged: queueMutationGeneration != queueGeneration,
            semanticInputsChanged: backfillableSourceIDs() != input.sourceIDs
                || bareOnlySourceIDs() != input.bareOnlySourceIDs
                || library.disabledSourceIDs != input.disabledSourceIDs
                || isWaitingForWiFi != input.isWaitingForWiFi
        )
        switch application {
        case .discard:
            let staleReason: MetadataBackfillRemainingCountRefreshPolicy.StaleReason =
                superseded ? .supersededComputation : .inputsChanged
            if MetadataBackfillRemainingCountRefreshPolicy
                .throttleResetsAfterFailure(reason: staleReason) {
                lastRemainingCountRefreshAt = .distantPast
            }
        case .applyKeepingQueueDirty:
            // 这份快照算在一次资料库发布之前, 数字只能少算不会多算。发布给
            // 源卡片没问题, 但节流必须像 HEAD 上的 `.inputsChanged` 那样退回,
            // 否则接下来最多一个刷新间隔里, 谁都拿不到更新的数 —— 后台唤醒
            // 里没有 SwiftUI 场景去把队列重新标脏, 那就再没有别的信号了。
            lastRemainingCountRefreshAt = .distantPast
            applyRemainingCounts(computation, precedesLibraryPublication: true)
        case .apply:
            applyRemainingCounts(computation, precedesLibraryPublication: false)
        }
    }

    /// `trimmingCharacters(in:).isEmpty` 要为每个字段分配一个新字符串。整库
    /// 对账每首歌要问三个字段, 万首级曲库一轮就是几万次无谓分配, 而这一轮会
    /// 反复跑一整场回填。判定等价, 只是不分配。
    @inline(__always)
    private nonisolated static func hasVisibleContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains { !$0.isWhitespace && !$0.isNewline }
    }

    private nonisolated static func computeRemainingCounts(
        _ input: RemainingCountsInput
    ) -> RemainingCountsComputation {
        var bySource: [String: Int] = [:]
        var deferredBySource: [String: Int] = [:]
        var statusBySource: [String: Int] = [:]
        var summaries: [String: MetadataBackfillSourceSummary] = [:]
        var displayItemsBySource: [String: [MetadataBackfillStatusDisplayItem]] = [:]
        var displayItemsSignature = MetadataBackfillStatusSignature()
        bySource.reserveCapacity(input.sourceIDs.count)
        deferredBySource.reserveCapacity(input.sourceIDs.count)
        statusBySource.reserveCapacity(input.sourceIDs.count)
        summaries.reserveCapacity(input.sourceIDs.count)
        displayItemsBySource.reserveCapacity(input.sourceIDs.count)
        for sourceID in input.sourceIDs {
            displayItemsBySource[sourceID] = []
            // 来源集合本身无序, 用异或折叠, 使增删来源同样算作变化。
            displayItemsSignature.combine(sourceID: sourceID)
        }
        var total = 0
        var deferredTotal = 0
        var statusTotal = 0
        var failedTotal = 0
        for song in input.songs {
            guard input.sourceIDs.contains(song.sourceID) else { continue }

            let workReasons = Self.workReasons(
                restrictToBareRows: MetadataBackfillEligibilityPolicy.restrictsToBareRows(
                    sourceUsesBareInventory: input.bareOnlySourceIDs.contains(song.sourceID),
                    isStreamDescriptor: song.isStreamDescriptor
                ),
                duration: song.duration,
                format: song.fileFormat,
                hasCoverArt: !(song.coverArtFileName?.isEmpty ?? true),
                artworkGivenUp: input.artworkGivenUpIDs.contains(song.id),
                titleChecked: input.titleCheckedIDs.contains(song.id),
                durationInspectionComplete: input.incompleteSongIDs.contains(song.id),
                hasAlbumTitle: Self.hasVisibleContent(song.albumTitle),
                hasAlbumArtist: Self.hasVisibleContent(song.albumArtistName),
                albumArtistChecked: input.albumArtistCheckedIDs.contains(song.id),
                hasArtist: Self.hasVisibleContent(song.artistName),
                artistChecked: input.artistCheckedIDs.contains(song.id)
            )
            let stillNeedsDetails = !workReasons.isEmpty
            let hasTerminalOrSourceFailure = input.failedSongIDs.contains(song.id)
                || input.sourceIssueSongIDs.contains(song.id)
            let automaticRetriesExhausted = Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: input.transientFailureCounts,
                sourceRetryCounts: input.sourceTransientFailureCounts
            )
            let isDeferredRetry = input.deferredRetrySongIDs.contains(song.id)
                && !hasTerminalOrSourceFailure
                && stillNeedsDetails
            if isDeferredRetry {
                deferredBySource[song.sourceID, default: 0] += 1
                deferredTotal += 1
            }

            let hasDeferredRetryState = input.deferredRetrySongIDs.contains(song.id)
                || ((input.transientFailureCounts[song.id] ?? 0) > 0
                    && input.sessionGivenUpIDs.contains(song.id))
            let sourceUnavailable = input.disabledSourceIDs.contains(song.sourceID)
                || input.diagnosticRecords[song.id]?.state == .sourceUnavailable
                || (input.sessionNetworkParkedIDs.contains(song.id) && !hasDeferredRetryState)
                || ((input.sourceTransientFailureCounts[song.sourceID] ?? 0) > 0
                    && input.sessionGivenUpIDs.contains(song.id)
                    && !hasDeferredRetryState)
            if let itemState = MetadataBackfillItemStatePolicy.resolve(
                needsInspection: stillNeedsDetails,
                hasUnreadableTags: input.failedSongIDs.contains(song.id),
                hasPlayableIncompleteDetails: input.incompleteSongIDs.contains(song.id),
                hasFileIssue: input.sourceIssueSongIDs.contains(song.id),
                hasDeferredRetry: hasDeferredRetryState,
                isSourceUnavailable: sourceUnavailable,
                isStalled: input.sessionStallParkedIDs.contains(song.id),
                isWaitingForWiFi: input.isWaitingForWiFi
            ) {
                summaries[song.sourceID, default: MetadataBackfillSourceSummary()]
                    .record(itemState)
                let diagnostic = input.diagnosticRecords[song.id]
                let displayItem = MetadataBackfillStatusDisplayItem(
                    songID: song.id,
                    title: song.title,
                    artistName: song.artistName,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat.rawValue.uppercased(),
                    hasMissingDuration: song.duration <= 0,
                    state: itemState,
                    workReasons: workReasons,
                    diagnostic: diagnostic,
                    attemptCount: max(
                        diagnostic?.attemptCount ?? 0,
                        max(
                            input.transientFailureCounts[song.id] ?? 0,
                            input.sourceTransientFailureCounts[song.sourceID] ?? 0
                        )
                    )
                )
                displayItemsBySource[song.sourceID, default: []].append(displayItem)
                displayItemsSignature.combine(item: displayItem, sourceID: song.sourceID)
            }

            let hasFailed = hasTerminalOrSourceFailure
                || input.sessionGivenUpIDs.contains(song.id)
                || automaticRetriesExhausted
            // `statusCount` is the truthful unresolved-inspection total shown
            // on source cards. A source circuit breaker can park hundreds of
            // untouched rows after one real request fails; keep all those rows
            // in the total while `deferredRetryCount` reports only the request
            // IDs that actually failed.
            if stillNeedsDetails && !hasTerminalOrSourceFailure {
                statusBySource[song.sourceID, default: 0] += 1
                statusTotal += 1
            }
            if hasFailed {
                if stillNeedsDetails { failedTotal += 1 }
                continue
            }
            guard stillNeedsDetails else { continue }
            bySource[song.sourceID, default: 0] += 1
            total += 1
        }
        return RemainingCountsComputation(
            remainingBySource: bySource,
            deferredBySource: deferredBySource,
            statusBySource: statusBySource,
            summaries: summaries,
            displayItemsBySource: displayItemsBySource,
            displayItemsSignature: displayItemsSignature,
            remainingTotal: total,
            deferredTotal: deferredTotal,
            statusTotal: statusTotal,
            failedTotal: failedTotal
        )
    }

    /// - Parameter precedesLibraryPublication: pass `true` when the computation
    ///   ran across a library publication. The published numbers are then a
    ///   consistent past state — good enough for the source card — but the
    ///   queue stays dirty so `hasPendingWork` keeps answering honestly and the
    ///   next reconcile still runs, the queue-state file is not rewritten with a
    ///   total that is known to under-report, and a `0` total is not taken as
    ///   proof that there is nothing left to do.
    private func applyRemainingCounts(
        _ computation: RemainingCountsComputation,
        precedesLibraryPublication: Bool = false
    ) {
        let signpost = PrimuseSignposts.hitch.beginInterval("backfill.remainingCounts")
        defer { PrimuseSignposts.hitch.endInterval("backfill.remainingCounts", signpost) }
        var presentationChanged = false
        if remainingCountBySourceID != computation.remainingBySource {
            remainingCountBySourceID = computation.remainingBySource
            presentationChanged = true
        }
        if cachedRemainingCount != computation.remainingTotal {
            cachedRemainingCount = computation.remainingTotal
        }
        if deferredRetryCountBySourceID != computation.deferredBySource {
            deferredRetryCountBySourceID = computation.deferredBySource
            presentationChanged = true
        }
        if cachedDeferredRetryCount != computation.deferredTotal {
            cachedDeferredRetryCount = computation.deferredTotal
        }
        if statusCountBySourceID != computation.statusBySource {
            statusCountBySourceID = computation.statusBySource
            presentationChanged = true
        }
        if cachedStatusCount != computation.statusTotal {
            cachedStatusCount = computation.statusTotal
        }
        if cachedFailedCount != computation.failedTotal {
            cachedFailedCount = computation.failedTotal
        }
        if sourceStatusSummaries != computation.summaries {
            sourceStatusSummaries = computation.summaries
            presentationChanged = true
        }
        // 指纹相同就连赋值都省掉: 内容等价, 换一份新字典只会让主 actor 再去
        // 释放上一份的上千条展示行。
        if statusDisplayItemsSignature != computation.displayItemsSignature {
            statusDisplayItemsSignature = computation.displayItemsSignature
            statusDisplayItemsBySourceID = computation.displayItemsBySource
            presentationChanged = true
        }
        if presentationChanged {
            statusRevision = statusRevision == .max ? 1 : statusRevision + 1
        }
        guard !precedesLibraryPublication else {
            // 只把数字发出去。落盘会把这个偏小的总数写进 backfill-queue-state.json,
            // 而后台唤醒里那份文件就是唯一的信号; `remainingTotal == 0` 同理,
            // 不能拿一个已知偏小的零去收掉 Wi-Fi 等待与蜂窝提示。
            return
        }
        reconciledQueueGeneration = queueMutationGeneration
        queueNeedsRefresh = false
        persistQueueStateIfNeeded(needsRefresh: false)
        if computation.remainingTotal == 0 {
            isWaitingForWiFi = false
            setCellularPromptPresented(false)
        }
    }

    private func markQueueDirty() {
        queueMutationGeneration = queueMutationGeneration == .max
            ? 1
            : queueMutationGeneration + 1
        queueNeedsRefresh = true
        let defaults = UserDefaults.standard
        defaults.set(
            queueMutationGeneration,
            forKey: Self.queueMutationGenerationDefaultsKey
        )
        defaults.set(true, forKey: Self.queueDirtyDefaultsKey)
        persistQueueStateIfNeeded(needsRefresh: true)
    }

    private func persistQueueStateIfNeeded(needsRefresh: Bool) {
        let state = QueueState(
            needsRefresh: needsRefresh,
            reconciledGeneration: reconciledQueueGeneration,
            remainingCount: cachedRemainingCount,
            failedCount: cachedFailedCount,
            deferredRetryCount: cachedDeferredRetryCount,
            statusCount: cachedStatusCount,
            remainingCountBySourceID: remainingCountBySourceID,
            deferredRetryCountBySourceID: deferredRetryCountBySourceID,
            statusCountBySourceID: statusCountBySourceID
        )
        guard persistedQueueState != state else { return }
        persistedQueueState = state
        let url = queueStateURL
        let previous = queueStatePersistenceTask
        queueStatePersistenceTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            guard let data = try? JSONEncoder().encode(state) else { return }
            do {
                try data.write(to: url, options: .atomic)
                UserDefaults.standard.set(
                    state.needsRefresh,
                    forKey: Self.queueDirtyDefaultsKey
                )
            } catch {
                UserDefaults.standard.set(true, forKey: Self.queueDirtyDefaultsKey)
            }
        }
    }

    private static var canRunAutomaticMaintenance: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        true
        #endif
    }

    /// Number of songs whose remaining inspection work is currently blocked by
    /// a terminal error, an exhausted retry budget, or a session park.
    var failedCount: Int {
        cachedFailedCount
    }

    private func recordDiagnostic(
        songID: String,
        state: MetadataBackfillItemState,
        reason: String?,
        attemptCount: Int
    ) {
        let resolvedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = MetadataBackfillDiagnosticRecord(
            state: state,
            reason: (resolvedReason?.isEmpty == false ? resolvedReason : nil)
                ?? String(localized: "metadata_status_reason_unknown"),
            attemptCount: attemptCount,
            lastAttemptAt: Date()
        )
        guard diagnosticRecords[songID] != record else { return }
        diagnosticRecords[songID] = record
        saveDiagnostics()
    }

    private func clearDiagnostic(songID: String) {
        guard diagnosticRecords.removeValue(forKey: songID) != nil else { return }
        saveDiagnostics()
    }

    /// Explicit user retry resets both per-song and source-wide automatic retry
    /// budgets. Only rows that still have inspection work and are actually
    /// blocked are reopened.
    @discardableResult
    func retryFailed(
        forSource sourceID: String? = nil,
        startImmediately: Bool = true
    ) -> Int {
        let retrySongs = library.songs.filter { song in
            if let sourceID, song.sourceID != sourceID { return false }
            return MetadataBackfillRetrySelectionPolicy.shouldReopen(
                needsInspection: needsBackfill(song),
                hasConfirmedFailure: failedSongIDs.contains(song.id),
                hasFileIssue: sourceIssueSongIDs.contains(song.id),
                isSessionParked: sessionGivenUpIDs.contains(song.id),
                automaticRetriesExhausted: Self.automaticRetriesExhausted(
                    songID: song.id,
                    sourceID: song.sourceID,
                    retryCounts: transientFailureCounts,
                    sourceRetryCounts: sourceTransientFailureCounts
                )
            )
        }
        let retryIDs = Set(retrySongs.map(\.id))
        guard !retryIDs.isEmpty else { return 0 }
        let sourceIDs = Set(retrySongs.map(\.sourceID))
        failedSongIDs.subtract(retryIDs)
        incompleteSongIDs.subtract(retryIDs)
        sourceIssueSongIDs.subtract(retryIDs)
        sessionGivenUpIDs.subtract(retryIDs)
        sessionNetworkParkedIDs.subtract(retryIDs)
        sessionStallParkedIDs.subtract(retryIDs)
        // An explicit retry reopens the affected rows as ordinary pending
        // inspection. Keeping every source-parked row in the deferred set would
        // recreate the misleading "hundreds of retries" count after one
        // connector failure.
        mutateDeferredRetries { $0.subtract(retryIDs) }
        artworkGivenUpIDs.subtract(retryIDs)
        titleCheckedIDs.subtract(retryIDs)
        albumArtistCheckedIDs.subtract(retryIDs)
        artistCheckedIDs.subtract(retryIDs)
        for id in retryIDs { diagnosticRecords[id] = nil }
        for id in retryIDs { transientFailureCounts[id] = nil }
        for sourceID in sourceIDs { sourceTransientFailureCounts[sourceID] = nil }
        saveFailed()
        saveDeferredRetries()
        saveDiagnostics()
        saveInspectionState()
        saveRetryCounts()
        plog("📥 Backfill: retryFailed reopened \(retryIDs.count) blocked inspections")
        refreshRemainingCounts(force: true)
        if startImmediately {
            if let sourceID {
                startUserInitiated(sourceID: sourceID)
            } else {
                start()
            }
        }
        return retryIDs.count
    }

    func retry(songID: String) {
        guard reopenInspection(for: songID) else { return }
        refreshRemainingCounts(force: true)
        start()
    }

    func canRereadTags(for song: Song) -> Bool {
        !song.isCueTrack
            && !song.isStreamDescriptor
            && manuallyReadableSourceIDs().contains(song.sourceID)
            && !library.disabledSourceIDs.contains(song.sourceID)
    }

    func canRereadTags(songID: String, expectedSourceID: String) -> Bool {
        guard let song = library.song(id: songID),
              song.sourceID == expectedSourceID else {
            return false
        }
        return canRereadTags(for: song)
    }

    func isRereadingTags(songID: String) -> Bool {
        manuallyReadingSongIDs.contains(songID)
            || activeReadSongIDs.contains(songID)
    }

    func needsPlaybackTagRead(
        songID: String,
        expectedSourceID: String
    ) -> Bool {
        guard let song = library.song(id: songID),
              song.sourceID == expectedSourceID,
              canRereadTags(for: song),
              backfillableSourceIDs().contains(song.sourceID),
              !playbackTerminalFailureIdentities.contains(
                PlaybackTagReadIdentity(song)
              ) else {
            return false
        }
        return needsBackfill(song)
    }

    /// Playback uses the same bounded single-file reader as the explicit menu
    /// action without reopening the whole-library queue or resetting persisted
    /// retry budgets. A track switch cancels the caller task and is recorded as
    /// a neutral outcome.
    func rereadTagsForPlayback(
        songID: String,
        expectedSourceID: String
    ) async -> PlaybackSingleSongTagReadResult {
        guard let song = library.song(id: songID),
              song.sourceID == expectedSourceID,
              canRereadTags(for: song),
              backfillableSourceIDs().contains(song.sourceID) else {
            return .unsupported
        }
        guard needsPlaybackTagRead(
            songID: songID,
            expectedSourceID: expectedSourceID
        ) else {
            return .notNeeded
        }
        guard !activeReadSongIDs.contains(songID) else {
            return .alreadyReading
        }
        guard manuallyReadingSongIDs.insert(songID).inserted else {
            return .alreadyReading
        }
        defer { manuallyReadingSongIDs.remove(songID) }

        let outcome = await processOne(song, isExplicitReread: true)
        if outcome.cancelled { return .cancelled }
        let result = await applySingleSongTagReadOutcome(outcome, original: song)
        let identity = PlaybackTagReadIdentity(song)
        switch result {
        case .completed(let kind):
            playbackTerminalFailureIdentities.remove(identity)
            return .completed(kind)
        case .alreadyReading:
            return .alreadyReading
        case .unsupported:
            return .unsupported
        case .failed(let reason):
            if outcome.transientFailure {
                return .retryableFailure(reason: reason)
            }
            playbackTerminalFailureIdentities.insert(identity)
            return .failed(reason: reason)
        }
    }

    func rereadTags(
        songIDs: [String],
        expectedSourceID: String,
        progress: @escaping (MetadataTagRereadProgress) -> Void
    ) async -> MetadataTagRereadProgress {
        guard batchRereadingSourceIDs.insert(expectedSourceID).inserted else {
            var result = MetadataTagRereadProgress(total: Set(songIDs).count)
            result.skipped = result.total
            progress(result)
            return result
        }
        defer {
            batchRereadingSourceIDs.remove(expectedSourceID)
            library.flushDeferredLibraryMaintenance()
            refreshStatusSnapshot()
        }
        let scheduler = MetadataReadScheduler<String, MetadataTagRereadBatch.Outcome>()
        batchSchedulers[expectedSourceID] = scheduler
        activeScheduler?.configurationChanged()
        defer {
            batchSchedulers[expectedSourceID] = nil
            readingProgress[expectedSourceID] = nil
            readProgressAccumulator[expectedSourceID] = nil
            activeScheduler?.configurationChanged()
            for other in batchSchedulers.values { other.configurationChanged() }
        }
        let now = Date()
        readProgressAccumulator[expectedSourceID] = MetadataReadingRate(startedAt: now)
        readingProgress[expectedSourceID] = nil
        var lastProcessed = 0
        return await MetadataTagRereadBatch.run(
            songIDs: songIDs,
            scheduler: scheduler,
            limits: { [self] in
                let budget = MetadataBackfillExecutionPolicy.limits(
                    for: .userInitiated,
                    preference: readingMode,
                    environment: readingEnvironment(sourceID: expectedSourceID),
                    recentProcessingDuration: recentProcessingDuration
                )
                #if os(iOS)
                if UIApplication.shared.applicationState != .active {
                    return MetadataBackfillExecutionLimits(
                        workerCount: 0, snapshotLimit: budget.snapshotLimit,
                        interRequestDelay: budget.interRequestDelay, flushInterval: budget.flushInterval
                    )
                }
                #endif
                let occupied = (activeScheduler?.inFlightCount ?? 0)
                    + batchSchedulers.filter { $0.key != expectedSourceID }
                        .values.reduce(0) { $0 + $1.inFlightCount }
                return budget.withWorkerCount(max(0, budget.workerCount - occupied))
            }
        ) { songID in
            let result = await self.rereadTags(songID: songID, expectedSourceID: expectedSourceID)
            switch result {
            case .completed: return .completed
            case .failed: return .failed
            case .alreadyReading, .unsupported: return .skipped
            }
        } progress: { [self] value in
            if value.processed > lastProcessed {
                recordReadCompletion(sourceID: expectedSourceID)
            }
            lastProcessed = value.processed
            progress(value)
            for other in batchSchedulers.values { other.configurationChanged() }
        }
    }

    /// Immediately reads only the selected file. File-oriented remote sources
    /// reuse the bounded Range parser; local sources read their real file URL.
    /// This deliberately bypasses the whole-library queue so the action cannot
    /// disappear behind an older fixed snapshot.
    func rereadTags(
        songID: String,
        expectedSourceID: String? = nil
    ) async -> SingleSongTagReadResult {
        guard !Task.isCancelled else {
            return .failed(reason: String(localized: "reread_song_tags_failure_cancelled"))
        }
        guard let song = library.song(id: songID),
              expectedSourceID == nil || song.sourceID == expectedSourceID,
              canRereadTags(for: song) else {
            return .unsupported
        }
        guard !activeReadSongIDs.contains(songID) else {
            return .alreadyReading
        }
        guard manuallyReadingSongIDs.insert(songID).inserted else {
            return .alreadyReading
        }
        defer { manuallyReadingSongIDs.remove(songID) }

        if backfillableSourceIDs().contains(song.sourceID) {
            guard reopenInspection(for: songID) else {
                return .failed(reason: String(localized: "reread_song_tags_failure_song_changed"))
            }
            let outcome = await processOne(song, isExplicitReread: true)
            return await applySingleSongTagReadOutcome(outcome, original: song)
        }

        do {
            let connector = try await sourceManager.connectorForSong(song)
            let url = try await connector.localURL(for: song.filePath)
            let fallbackTitle = MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
            var metadata = await metadataService.loadMetadata(
                for: url,
                cacheKey: song.id,
                allowOnlineFetch: false,
                fallbackTitle: fallbackTitle
            )
            if song.fileFormat.requiresFFmpeg,
               let info = try? await FFmpegAudioDecoder().fileInfo(for: url) {
                if metadata.duration <= 0 { metadata.duration = info.duration }
                if (metadata.sampleRate ?? 0) <= 0 {
                    metadata.sampleRate = info.sampleRate.finiteInt()
                }
                if (metadata.bitRate ?? 0) <= 0 { metadata.bitRate = info.bitRate }
                if (metadata.bitDepth ?? 0) <= 0 { metadata.bitDepth = info.bitDepth }
                metadata.hasTechnicalProperties = metadata.hasTechnicalProperties
                    || info.duration > 0
                    || info.sampleRate > 0
                    || (info.bitRate ?? 0) > 0
                    || (info.bitDepth ?? 0) > 0
            }
            guard !MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
                providedByteCount: 0,
                expectedFileByteCount: song.fileSize,
                hasCompleteFileAccess: metadata.hasCompleteFileAccess,
                signature: metadata.detectedFileSignature,
                hasTechnicalProperties: metadata.hasTechnicalProperties
            ) else {
                return .failed(
                    reason: String(localized: "reread_song_tags_failure_unrecognized_audio")
                )
            }
            guard let live = library.song(id: song.id),
                  live.sourceID == song.sourceID,
                  live.filePath == song.filePath else {
                return .failed(reason: String(localized: "reread_song_tags_failure_song_changed"))
            }
            let merged = mergeSong(bare: live, metadata: metadata)
            if batchRereadingSourceIDs.contains(song.sourceID) {
                await library.replaceSongsPreparedOffMain([merged], maintenance: .deferred)
            } else {
                library.replaceSongs([merged])
            }
            return .completed(
                completionKind(for: metadata, original: live, merged: merged)
            )
        } catch {
            plog("⚠️ Single-song tag read failed for '\(song.title)': \(error.localizedDescription)")
            return .failed(reason: error.localizedDescription)
        }
    }

    @discardableResult
    private func reopenInspection(for songID: String) -> Bool {
        guard library.song(id: songID) != nil else { return false }
        failedSongIDs.remove(songID)
        incompleteSongIDs.remove(songID)
        sourceIssueSongIDs.remove(songID)
        sessionGivenUpIDs.remove(songID)
        sessionNetworkParkedIDs.remove(songID)
        sessionStallParkedIDs.remove(songID)
        mutateDeferredRetries { $0.insert(songID) }
        artworkGivenUpIDs.remove(songID)
        titleCheckedIDs.remove(songID)
        albumArtistCheckedIDs.remove(songID)
        artistCheckedIDs.remove(songID)
        transientFailureCounts[songID] = nil
        clearDiagnostic(songID: songID)
        if let sourceID = library.song(id: songID)?.sourceID {
            sourceTransientFailureCounts[sourceID] = nil
        }
        saveFailed()
        saveDeferredRetries()
        saveInspectionState()
        saveRetryCounts()
        return true
    }

    private func applySingleSongTagReadOutcome(
        _ outcome: BackfillOutcome,
        original song: Song
    ) async -> SingleSongTagReadResult {
        let songID = song.id
        guard !outcome.cancelled else {
            return .failed(reason: String(localized: "reread_song_tags_failure_cancelled"))
        }

        if outcome.markFailed {
            failedSongIDs.insert(songID)
            incompleteSongIDs.remove(songID)
            sourceIssueSongIDs.remove(songID)
            recordDiagnostic(
                songID: songID,
                state: .unreadableTags,
                reason: outcome.failureReason,
                attemptCount: max(1, transientFailureCounts[songID] ?? 0)
            )
        } else if outcome.detailsIncomplete {
            incompleteSongIDs.insert(songID)
            failedSongIDs.remove(songID)
            sourceIssueSongIDs.remove(songID)
            recordDiagnostic(
                songID: songID,
                state: .playableIncomplete,
                reason: outcome.failureReason,
                attemptCount: max(1, transientFailureCounts[songID] ?? 0)
            )
        } else if outcome.sourceIssue {
            sourceIssueSongIDs.insert(songID)
            failedSongIDs.remove(songID)
            incompleteSongIDs.remove(songID)
            recordDiagnostic(
                songID: songID,
                state: .fileUnavailable,
                reason: outcome.failureReason,
                attemptCount: max(1, transientFailureCounts[songID] ?? 0)
            )
        }
        if outcome.transientFailure {
            mutateDeferredRetries { $0.insert(songID) }
            sessionGivenUpIDs.insert(songID)
            sessionNetworkParkedIDs.insert(songID)
            transientFailureCounts[songID] = MetadataBackfillRetryPolicy
                .attemptCountAfterFailure(currentCount: transientFailureCounts[songID] ?? 0)
            recordDiagnostic(
                songID: songID,
                state: outcome.sourceUnavailable ? .sourceUnavailable : .retryPending,
                reason: outcome.failureReason,
                attemptCount: transientFailureCounts[songID] ?? 1
            )
        }
        if outcome.artworkGivenUp {
            artworkGivenUpIDs.insert(songID)
        }
        if outcome.titleInspected {
            markMetadataInspected(songID: songID)
        }
        if outcome.artistInspected, outcome.song == nil {
            markArtistInspected(songID: songID)
        }

        var applied = false
        if let updated = outcome.song,
           let validated = backfillResultForApply(updated) {
            if batchRereadingSourceIDs.contains(song.sourceID) {
                await library.replaceSongsPreparedOffMain([validated], maintenance: .deferred)
            } else {
                library.replaceSongs([validated])
            }
            if outcome.artistInspected { markArtistInspected(songID: songID) }
            markMetadataInspected(songID: songID)
            clearAutomaticRetryState(songID: songID, sourceID: song.sourceID)
            mutateDeferredRetries { $0.remove(songID) }
            if !outcome.markFailed && !outcome.detailsIncomplete && !outcome.sourceIssue {
                failedSongIDs.remove(songID)
                incompleteSongIDs.remove(songID)
                sourceIssueSongIDs.remove(songID)
                clearDiagnostic(songID: songID)
            }
            applied = true
        }

        let verifiedWithoutMutation = !applied
            && outcome.song == nil
            && outcome.titleInspected
            && !outcome.markFailed
            && !outcome.detailsIncomplete
            && !outcome.sourceIssue
            && !outcome.transientFailure
        if verifiedWithoutMutation {
            failedSongIDs.remove(songID)
            incompleteSongIDs.remove(songID)
            sourceIssueSongIDs.remove(songID)
            mutateDeferredRetries { $0.remove(songID) }
            clearAutomaticRetryState(songID: songID, sourceID: song.sourceID)
            clearDiagnostic(songID: songID)
        }

        saveFailed()
        saveArtworkGivenUp()
        saveDeferredRetries()
        saveInspectionState()
        saveRetryCounts()
        if batchRereadingSourceIDs.contains(song.sourceID) {
            await refreshRemainingCountsOffMain()
        } else {
            refreshRemainingCounts(force: true)
        }
        if applied || verifiedWithoutMutation {
            return .completed(outcome.completionKind)
        }
        return .failed(
            reason: outcome.failureReason
                ?? String(localized: "reread_song_tags_failure_no_update")
        )
    }

    // MARK: - Worker

    /// Flush cadence, batch size and worker count all come from
    /// MetadataBackfillExecutionPolicy. Standard work retains the historical
    /// three-worker throughput; iOS background modes are serial and throttled.
    /// Hard cap for a single song's metadata backfill. Some SMB/NAS stacks can
    /// leave a READ or AVFoundation metadata load suspended indefinitely for a
    /// damaged or locked file. Let that file go and keep the queue moving.
    private static let perSongTimeout: TimeInterval = 45
    /// A manual reread may materialize and probe one complete file after the
    /// bounded ranges prove insufficient.
    private static let explicitRereadTimeout: TimeInterval = 180
    private func runWorker() async {
        defer { library.flushDeferredLibraryMaintenance() }
        resetPendingFlushState()
        // Outer loop: take a snapshot of bare songs, process the snapshot
        // sequentially, flush in batches. We deliberately do NOT call
        // `pickNextBatch` per-song — until we flush the batch the
        // already-processed songs still look "bare" in the library and
        // would be picked again, causing duplicate Range fetches and a
        // weird-looking processedCount that grows past pendingCount.
        var lastSnapshotIDs: Set<String> = []
        var completedSnapshotPasses = 0
        while !Task.isCancelled {
            let (limits, allowedSourceIDs) = await MainActor.run { [self] in
                let limits = executionLimits
                let allowedSourceIDs = MetadataBackfillNetworkPolicy.allowedSourceIDs(
                    networkIsBlocked: shouldBlockForCellular(),
                    offlineReadableSourceIDs: offlineReadableSourceIDs()
                )
                return (limits, allowedSourceIDs)
            }
            if allowedSourceIDs?.isEmpty == true {
                plog("📥 Backfill: pausing network rows (cellular detected mid-flight)")
                break
            }
            if let snapshotPassLimit = limits.snapshotPassLimit,
               completedSnapshotPasses >= snapshotPassLimit {
                break
            }

            let snapshot = await pickNextBatchOffMain(
                limit: limits.snapshotLimit,
                allowedSourceIDs: allowedSourceIDs
            )
            if snapshot.isEmpty { break }

            // Oscillation guard: if pickNextBatch keeps returning the
            // exact same set of song IDs after we already processed
            // them, our writes aren't sticking — replaceSongs failed,
            // backfill returned duration=0 despite reporting "done", or
            // some other code path is silently overwriting the merged
            // result back to bare. Bail to avoid burning quota in an
            // infinite loop, and surface the diagnostic so we can
            // pinpoint where the round-trip drops the duration.
            let snapIDs = Set(snapshot.map(\.id))
            if MetadataBackfillStallPolicy.shouldParkRepeatedSnapshot(
                previousIDs: lastSnapshotIDs,
                currentIDs: snapIDs
            ) {
                sessionGivenUpIDs.formUnion(snapIDs)
                sessionStallParkedIDs.formUnion(snapIDs)
                let deferredIDs = MetadataBackfillDeferredRetryPolicy.idsToPersist(
                    failedSongID: nil,
                    snapshotSongIDs: snapIDs,
                    cause: .repeatedSnapshot
                )
                mutateDeferredRetries { $0.formUnion(deferredIDs) }
                if !deferredIDs.isEmpty { saveDeferredRetries() }
                await refreshRemainingCountsOffMain(force: true)
                plog("⚠️ Backfill: pickNextBatch returned the same \(snapIDs.count) IDs after a full round — parked for this session")
                break
            }
            lastSnapshotIDs = snapIDs

            activeSourceIDs = Set(snapshot.map(\.sourceID))
            await processSnapshot(snapshot)
            completedSnapshotPasses += 1
        }
        // 收尾这一批必须落地 —— 它横跨了好几个快照, 也可能是被 stop() 取消的。
        // 发布走的 detached 准备任务不继承取消, 所以这里仍然能走完。
        await publishPendingFlushIfDue(isFinal: true)
    }

    /// Process a fixed list of songs with the active bounded concurrency.
    /// Publication is owned by `publishPendingFlushIfDue` and deliberately
    /// outlives this snapshot. Each song in the snapshot is touched exactly once.
    private func processSnapshot(_ snapshot: [Song]) async {
        let environment = readingEnvironment()
        let limits = executionLimits
        plog("📥 processSnapshot: starting with \(snapshot.count) songs workers=\(limits.workerCount) delay=\(limits.interRequestDelay) thermal=\(environment.thermalState) speed=\(readingMode.rawValue) continued=\(hasContinuedProcessingTime)")

        // 预热阶段: 按 source 分组, 给每个 source 调一次 batch prefetchMetadata
        // (百度网盘会一次拿 100 个 dlink, 其他 connector 默认 noop)。后续每首
        // 的 fetchRange 走 dlink cache 命中, 省掉 1w 次 filemetas API 配额。
        let songsBySource: [String: [Song]] = Dictionary(grouping: snapshot) { $0.sourceID }
        for (_, sourceSongs) in songsBySource {
            guard !Task.isCancelled else { return }
            guard executionLimits.workerCount > 0 else { break }
            guard let representative = sourceSongs.first else { continue }
            guard isStillEligible(representative),
                  canDispatchUnderCurrentNetworkPolicy(representative) else { continue }
            if let connector = try? await sourceManager.auxiliaryConnector(for: representative) {
                let paths = sourceSongs.map(\.filePath)
                await connector.prefetchMetadata(paths: paths)
            }
        }

        let scheduler = MetadataReadScheduler<Song, BackfillOutcome>()
        activeScheduler = scheduler
        defer {
            if activeScheduler === scheduler { activeScheduler = nil }
            for other in batchSchedulers.values { other.configurationChanged() }
        }
        let startedAt = Date()
        for sourceID in activeSourceIDs where readProgressAccumulator[sourceID] == nil {
            readProgressAccumulator[sourceID] = MetadataReadingRate(startedAt: startedAt)
        }
        await scheduler.run(
            items: snapshot,
            limits: { [self] in executionLimits },
            shouldRead: { [self] song in
                !manuallyReadingSongIDs.contains(song.id)
                    && isStillEligible(song)
                    && canDispatchUnderCurrentNetworkPolicy(song)
            },
            priority: executionMode == .backgroundDuringPlayback && !hasContinuedProcessingTime ? .background : .utility,
            read: { [self] song in await processOne(song) }
        ) { [self] song, outcome in
                let result = (song: song, outcome: outcome)
                if !outcome.cancelled {
                    recordReadCompletion(sourceID: song.sourceID)
                    #if os(iOS)
                    continuedProcessingSession?.advance()
                    #endif
                }
                for other in batchSchedulers.values { other.configurationChanged() }
                processedTotal += 1
                logReadThroughputIfDue(totalCompleted: processedTotal)
                // UI progress does not need per-file granularity. Publishing
                // every ten results prevents an Observable invalidation storm
                // while retaining responsive feedback.
                if processedTotal.isMultiple(of: 10) || processedTotal == pendingCount {
                    processedCount = processedTotal
                }
                let songID = result.song.id
                let canRecordOutcome = isStillEligible(result.song)
                if result.outcome.sourceUnavailable, canRecordOutcome {
                    // A connection/authentication failure applies to the
                    // connector, not merely this 500-row snapshot. Park every
                    // unresolved row from the source so a large library emits
                    // one probe on this network path, not one probe per batch.
                    let sourceID = result.song.sourceID
                    let sourceSongIDs = Set(library.songs.lazy.filter { song in
                        song.sourceID == sourceID
                            && !self.failedSongIDs.contains(song.id)
                            && !self.sourceIssueSongIDs.contains(song.id)
                            && self.needsBackfill(song)
                    }.map(\.id))
                    let wasAlreadyParked = sourceSongIDs.isSubset(of: sessionNetworkParkedIDs)
                    sessionGivenUpIDs.formUnion(sourceSongIDs)
                    sessionNetworkParkedIDs.formUnion(sourceSongIDs)
                    let deferredIDs = MetadataBackfillDeferredRetryPolicy.idsToPersist(
                        failedSongID: songID,
                        snapshotSongIDs: sourceSongIDs,
                        cause: .sourceUnavailable
                    )
                    mutateDeferredRetries { $0.formUnion(deferredIDs) }
                    recordDiagnostic(
                        songID: songID,
                        state: .sourceUnavailable,
                        reason: result.outcome.failureReason,
                        attemptCount: MetadataBackfillRetryPolicy.attemptCountAfterFailure(
                            currentCount: sourceTransientFailureCounts[sourceID] ?? 0
                        )
                    )
                    if !deferredIDs.isEmpty { saveDeferredRetries() }
                    if !wasAlreadyParked {
                        let sourceAttempt = MetadataBackfillRetryPolicy.attemptCountAfterFailure(
                            currentCount: sourceTransientFailureCounts[sourceID] ?? 0
                        )
                        sourceTransientFailureCounts[sourceID] = sourceAttempt
                        saveRetryCounts()
                        let exhausted = MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(sourceAttempt)
                        plog("⚠️ Backfill: source \(sourceID) unavailable; parked \(sourceSongIDs.count) songs (attempt \(sourceAttempt), exhausted=\(exhausted))")
                    }
                }
                if result.outcome.markFailed, canRecordOutcome {
                    failedSongIDs.insert(songID)
                    incompleteSongIDs.remove(songID)
                    sourceIssueSongIDs.remove(songID)
                    mutateDeferredRetries { $0.remove(songID) }
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    recordDiagnostic(
                        songID: songID,
                        state: .unreadableTags,
                        reason: result.outcome.failureReason,
                        attemptCount: 1
                    )
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.detailsIncomplete, canRecordOutcome {
                    incompleteSongIDs.insert(songID)
                    failedSongIDs.remove(songID)
                    sourceIssueSongIDs.remove(songID)
                    mutateDeferredRetries { $0.remove(songID) }
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    recordDiagnostic(
                        songID: songID,
                        state: .playableIncomplete,
                        reason: result.outcome.failureReason,
                        attemptCount: 1
                    )
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.sourceIssue, canRecordOutcome {
                    sourceIssueSongIDs.insert(songID)
                    failedSongIDs.remove(songID)
                    incompleteSongIDs.remove(songID)
                    mutateDeferredRetries { $0.remove(songID) }
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    recordDiagnostic(
                        songID: songID,
                        state: .fileUnavailable,
                        reason: result.outcome.failureReason,
                        attemptCount: 1
                    )
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.transientFailure,
                   MetadataBackfillRetryPolicy.shouldCountTransientFailure(
                    isCancellation: result.outcome.cancelled,
                    isTransient: result.outcome.transientFailure
                   ),
                   canRecordOutcome {
                    mutateDeferredRetries { $0.insert(songID) }
                    sessionGivenUpIDs.insert(songID)
                    sessionNetworkParkedIDs.insert(songID)
                    let count = MetadataBackfillRetryPolicy.attemptCountAfterFailure(
                        currentCount: transientFailureCounts[songID] ?? 0
                    )
                    transientFailureCounts[songID] = count
                    recordDiagnostic(
                        songID: songID,
                        state: result.outcome.sourceUnavailable
                            ? .sourceUnavailable
                            : .retryPending,
                        reason: result.outcome.failureReason,
                        attemptCount: count
                    )
                    saveDeferredRetries()
                    saveRetryCounts()
                    let exhausted = MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(count)
                    plog("⚠️ Backfill: '\(result.song.title)' deferred after transient failure (attempt \(count), exhausted=\(exhausted))")
                }
                if result.outcome.artworkGivenUp {
                    // Stop re-fetching this song for artwork, but DON'T fail it —
                    // its duration update below still flushes and it stays playable.
                    artworkGivenUpIDs.insert(songID)
                    saveArtworkGivenUp()
                }
                if result.outcome.titleInspected, canRecordOutcome {
                    pendingMetadataInspectionIDs.insert(songID)
                }
                if result.outcome.artistInspected, canRecordOutcome {
                    pendingArtistInspectionIDs.insert(songID)
                    if result.outcome.song != nil {
                        // Persist this only after the matching replacement is
                        // applied. Otherwise a process exit between the marker
                        // write and the library flush could strand an unknown
                        // artist that is no longer eligible for repair.
                        artistInspectionIDsRequiringReplacement.insert(songID)
                    }
                }
                if let updated = result.outcome.song {
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    if !result.outcome.markFailed
                        && !result.outcome.detailsIncomplete
                        && !result.outcome.sourceIssue {
                        let removedFailed = failedSongIDs.remove(songID) != nil
                        let removedIncomplete = incompleteSongIDs.remove(songID) != nil
                        let removedSourceIssue = sourceIssueSongIDs.remove(songID) != nil
                        let removedSessionPark = sessionGivenUpIDs.remove(songID) != nil
                        clearDiagnostic(songID: songID)
                        if removedFailed
                            || removedIncomplete
                            || removedSourceIssue
                            || removedSessionPark {
                            saveFailed()
                        }
                    }
                    pendingFlush.append(updated)
                    pendingFlushSongIDs.insert(updated.id)
                }

                await publishPendingFlushIfDue()

        }

        // 快照边界不再强制发布: 攒下的结果跟着 worker 走到下一个快照。失败与
        // 重试计数仍要对账, 但走节流而不是强制 —— 强制一次就是一次整库扫描,
        // 而后台播放档位的快照只有 8 行。
        await refreshRemainingCountsOffMain()
    }

    /// 发布攒下的结果。`isFinal` 只在 worker 收尾时为真 —— 那一批必须落地,
    /// 哪怕正处在场景过渡的静默窗口里。
    private func publishPendingFlushIfDue(isFinal: Bool = false) async {
        guard !pendingFlush.isEmpty
                || !pendingMetadataInspectionIDs.isEmpty
                || !pendingArtistInspectionIDs.isEmpty else { return }
        guard MetadataBackfillSceneTransitionPolicy.shouldPublishFlush(
            isPaused: isSceneTransitionPaused,
            isFinalFlush: isFinal
        ) else { return }
        let limits = executionLimits
        // 主闸门是完成量, 时间间隔只是慢档位下的兜底。两者都远大于首页的
        // 重算节流窗口, 所以连续发布会被首页合并成一次整库重算。
        guard isFinal
                || pendingFlush.count >= limits.flushBatchSize
                || pendingMetadataInspectionIDs.count >= limits.flushBatchSize
                || pendingArtistInspectionIDs.count >= limits.flushBatchSize
                || Date().timeIntervalSince(lastFlushAt) >= limits.flushInterval else { return }

        // Partial metadata can be accompanied by markFailed=true (for example
        // TIT2 parsed but duration did not). Failure membership must stop
        // future network retries, not discard the useful result we already have.
        let flushSignpost = PrimuseSignposts.hitch.beginInterval("backfill.flushApply")
        let batch = pendingFlush.compactMap(backfillResultForApply)
        let batchIDs = Set(batch.map(\.id))
        pendingFlush.removeAll(keepingCapacity: true)
        pendingFlushSongIDs.removeAll(keepingCapacity: true)
        lastFlushAt = Date()
        if !batch.isEmpty {
            await library.replaceSongsPreparedOffMain(batch, maintenance: .deferred)
            clearDeferredRetries(in: batch)
            plog("📥 \(isFinal ? "final flush" : "flushed") \(batch.count) songs to library")
        }
        let artistIDsSafeToPersist = pendingArtistInspectionIDs
            .subtracting(artistInspectionIDsRequiringReplacement)
            .union(artistInspectionIDsRequiringReplacement.intersection(batchIDs))
        markArtistsInspected(songIDs: artistIDsSafeToPersist)
        pendingArtistInspectionIDs.subtract(artistIDsSafeToPersist)
        artistInspectionIDsRequiringReplacement.subtract(batchIDs)
        markMetadataInspected(songIDs: pendingMetadataInspectionIDs)
        pendingMetadataInspectionIDs.removeAll(keepingCapacity: true)
        PrimuseSignposts.hitch.endInterval("backfill.flushApply", flushSignpost)
        await refreshRemainingCountsOffMain(force: isFinal)
    }

    private func resetPendingFlushState() {
        pendingFlush.removeAll()
        pendingFlushSongIDs.removeAll()
        pendingMetadataInspectionIDs.removeAll()
        pendingArtistInspectionIDs.removeAll()
        artistInspectionIDsRequiringReplacement.removeAll()
        lastFlushAt = Date()
    }

    private func shouldBlockForCellular() -> Bool {
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        // 用户本次会话已明确同意蜂窝 → 不再拦。
        return wifiOnly && !cellularAllowedThisSession && !NetworkMonitor.shared.isOnUnmeteredNetwork
    }

    private func canDispatchUnderCurrentNetworkPolicy(_ song: Song) -> Bool {
        !shouldBlockForCellular() || offlineReadableSourceIDs().contains(song.sourceID)
    }

    private var hasPendingOfflineReadableWork: Bool {
        let offlineIDs = offlineReadableSourceIDs()
        return remainingCountBySourceID.contains { sourceID, count in
            count > 0 && offlineIDs.contains(sourceID)
        }
    }

    private var hasPendingNetworkReadableWork: Bool {
        let offlineIDs = offlineReadableSourceIDs()
        return remainingCountBySourceID.contains { sourceID, count in
            count > 0 && !offlineIDs.contains(sourceID)
        }
    }

    /// A mixed queue can wake without network and drain sandbox rows first.
    /// Once only connector/File Provider work remains, the next request asks
    /// BGTaskScheduler for network connectivity.
    var backgroundWakeRequiresNetworkConnectivity: Bool {
        // Stage 2b: 准备中的库走遍的是空模型。改用只读缓存的那个变体 —— 它对
        // "队列还脏着"给的是保守答案(需要网络), 不会把空对账固化下来。
        guard library.isReady else {
            return backgroundWakeRequiresNetworkConnectivityFromCachedCounts
        }
        if queueNeedsRefresh
            || reconciledQueueGeneration != queueMutationGeneration {
            refreshRemainingCounts(force: true)
        }
        return backgroundWakeRequiresNetworkConnectivityFromCachedCounts
    }

    /// 同一个判定, 但只读上一次对账/持久化下来的 `remainingCountBySourceID`,
    /// 不会触发整库遍历。scenePhase 提交与启动 .task 只是在决定 BGProcessing
    /// 请求要不要网络; 真正跑起来的路径 (2 秒延后任务、BGProcessing handler)
    /// 仍然用会强制刷新的那个属性, 稍旧的值会在那里被纠正。
    ///
    /// 队列已经标脏 (扫描刚发布一批歌, 对账被推到主 actor 之外) 时那份缓存
    /// 可能已经过期, 空的/上一轮的 pendingSourceIDs 会让判定一律回答"需要
    /// 网络"。这种情况下改用只看源集合的保守答案 —— 仍然不遍历资料库。
    var backgroundWakeRequiresNetworkConnectivityFromCachedCounts: Bool {
        let pendingSourceIDs = Set(remainingCountBySourceID.compactMap { sourceID, count in
            count > 0 ? sourceID : nil
        })
        return MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: queueNeedsRefresh
                || reconciledQueueGeneration != queueMutationGeneration,
            hasPendingWork: hasPendingWork,
            pendingSourceIDs: pendingSourceIDs,
            backfillableSourceIDs: backfillableSourceIDs(),
            offlineReadableSourceIDs: offlineReadableSourceIDs()
        )
    }

    private func updateWaitingForWiFiState(presentPrompt: Bool) {
        let waiting = hasPendingNetworkReadableWork && shouldBlockForCellular()
        if isWaitingForWiFi != waiting {
            isWaitingForWiFi = waiting
        }
        if presentPrompt {
            let shouldPresent = waiting
                && !hasPendingOfflineReadableWork
                && !isRunning
                && !cellularPromptDismissedThisSession
            setCellularPromptPresented(shouldPresent)
        } else if !waiting {
            setCellularPromptPresented(false)
        }
    }

    /// 用户在蜂窝提示里选择「继续」。persist=true 时永久关闭「仅 WiFi」开关,
    /// 否则只放行本次会话。随后立即恢复回填。
    func allowCellular(persist: Bool) {
        cellularAllowedThisSession = true
        if persist {
            UserDefaults.standard.set(false, forKey: Self.wifiOnlyDefaultsKey)
        }
        isWaitingForWiFi = false
        setCellularPromptPresented(false)
        resumeNetworkParkedWork()
        if worker == nil { start() }
    }

    /// 用户选择「仅 WiFi / 暂不」。本会话不再自动弹蜂窝提示。
    func dismissCellularPrompt() {
        cellularPromptDismissedThisSession = true
        setCellularPromptPresented(false)
    }

    /// 回填读取失败是否属于「瞬时、可重试」错误(连接/鉴权/超时/限流/网络/取消),
    /// 而非「永久」错误(文件已不存在、4xx 客户端错误)。瞬时错误不标 failed,
    /// 下一轮自动重试,避免重装/启动初期源未就绪时把歌永久钉成「无法读取」。
    static func isTransientBackfillError(_ error: Error) -> Bool {
        if error is BackfillHardTimeoutError { return true }
        if error is URLError { return true }
        if error is CancellationError { return true }
        switch error {
        case SourceError.connectionFailed, SourceError.credentialUnavailable,
             SourceError.authenticationFailed, SourceError.timeout:
            return true
        case SourceError.pathNotFound, SourceError.fileNotFound:
            return false // 文件确实不在了 —— 永久
        case CloudDriveError.notAuthenticated, CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed, CloudDriveError.rateLimited,
             CloudDriveError.invalidResponse, CloudDriveError.permissionDenied:
            return true
        case CloudDriveError.fileNotFound:
            return false
        case CloudDriveError.apiError(let code, _):
            // HTTP 408/425/429 are explicitly retryable. Provider body codes
            // may be negative, so they remain transient unless a connector
            // first maps a documented permanent code (such as Baidu -9) to
            // `fileNotFound`.
            return code < 0
                || code == 401
                || code == 403
                || code == 408
                || code == 425
                || code == 429
                || code >= 500
        default:
            return true // 未知的读取错误 → 当瞬时, 倾向重试而非永久卡死
        }
    }

    /// Only explicit account-wide failures park a source immediately. A failed
    /// file request needs independent endpoint evidence before doing so.
    static func isSourceUnavailableBackfillError(_ error: Error) -> Bool {
        if error is SourceConnectionTerminalError {
            return true
        }
        switch error {
        case SourceError.authenticationFailed, SourceError.credentialUnavailable,
             CloudDriveError.notAuthenticated,
             CloudDriveError.credentialTemporarilyUnavailable,
             CloudDriveError.credentialReadFailed,
             CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed,
             CloudDriveError.tokenPersistenceFailed,
             CloudDriveError.permissionDenied(.accountAccess),
             CloudDriveError.rateLimited:
            return true
        case CloudDriveError.apiError(let code, _):
            return code == 401 || code == 429
        default:
            return false
        }
    }

    static func needsSourceEndpointProbe(_ error: Error) -> Bool {
        switch error {
        case SourceError.connectionFailed, SourceError.timeout: return true
        default: return SourceNetworkFailurePolicy.isNetworkFailure(error)
        }
    }

    /// Outcome of one backfill attempt. `song` is the merged result to
    /// flush into the library when present (preserves whatever fields we
    /// did parse, e.g. artist+album when duration was unreadable).
    /// `markFailed` tells the caller to add the original ID to
    /// `failedSongIDs` so backfill stops retrying — set even on partial
    /// merges so a duration-less file isn't picked up next pass.
    struct BackfillOutcome: Sendable {
        var song: Song?
        var markFailed: Bool
        var completionKind: MetadataReadCompletionKind = .verifiedNoMetadata
        /// Header bytes were read, but a dynamic/complete-file playback path
        /// can remain playable without a duration from this bounded parser.
        var detailsIncomplete: Bool = false
        /// The path/object could not be read and should be checked at the source.
        var sourceIssue: Bool = false
        /// Exact failure surfaced by an explicit single-song reread. Automatic
        /// maintenance keeps this diagnostic in the log, while the user action
        /// presents it together with file, format, and source identity.
        var failureReason: String? = nil
        /// The worker generation was cancelled. This is a neutral outcome.
        var cancelled: Bool = false
        /// A bounded header read completed, even if it yielded no replacement
        /// fields. This closes the independent title-inspection leg.
        var titleInspected: Bool = false
        /// The bounded region capable of containing track-artist text was read.
        /// This remains false when an expanded FLAC read fails, allowing a
        /// later network session to resume that specific inspection.
        var artistInspected: Bool = false
        /// Set when the attempt failed with a *transient* error (timeout /
        /// network / throttle). The caller records one persisted attempt and
        /// parks the song until a later network session.
        var transientFailure: Bool = false
        /// The connector cannot currently be used on this path (for example,
        /// the network timed out or an SMB password is missing). The caller
        /// parks every unresolved song from that source until another path.
        var sourceUnavailable: Bool = false
        /// Song parsed fine (has a usable duration) but has no extractable
        /// embedded artwork. Stop retrying it *for artwork* without marking it
        /// permanently failed — its duration update is still saved and it stays
        /// playable & recoverable.
        var artworkGivenUp: Bool = false
    }

    private struct BackfillHardTimeoutError: LocalizedError, Sendable {
        let seconds: TimeInterval

        var errorDescription: String? {
            String(
                format: String(localized: "error_metadata_tag_read_timeout %@"),
                String(seconds.finiteInt())
            )
        }
    }

    struct BackfillRangeExpansionError: LocalizedError, Sendable {
        let format: String
        var errorDescription: String? {
            "\(format): \(String(localized: "relay_share_error_source_read"))"
        }
    }

    private final class AsyncTimeoutBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<T, Error>
        private var didFinish = false
        private var workTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func setTasks(workTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            if didFinish {
                lock.unlock()
                workTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.workTask = workTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func succeed(_ value: T) {
            finish(.success(value))
        }

        func fail(_ error: Error) {
            finish(.failure(error))
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<T, Error>) {
            let tasks: (work: Task<Void, Never>?, timeout: Task<Void, Never>?)
            lock.lock()
            if didFinish {
                lock.unlock()
                return
            }
            didFinish = true
            tasks = (workTask, timeoutTask)
            lock.unlock()

            tasks.work?.cancel()
            tasks.timeout?.cancel()

            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class AsyncTimeoutCancellationRelay<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var box: AsyncTimeoutBox<T>?
        private var isCancelled = false

        func install(_ box: AsyncTimeoutBox<T>) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                box.cancel()
                return
            }
            self.box = box
            lock.unlock()
        }

        func cancel() {
            let installed: AsyncTimeoutBox<T>?
            lock.lock()
            isCancelled = true
            installed = box
            lock.unlock()
            installed?.cancel()
        }
    }

    private nonisolated static func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let relay = AsyncTimeoutCancellationRelay<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = AsyncTimeoutBox<T>(continuation)
                relay.install(box)
                let timeoutNanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)

                let workTask = Task {
                    do {
                        box.succeed(try await operation())
                    } catch {
                        box.fail(error)
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        box.fail(BackfillHardTimeoutError(seconds: seconds))
                    } catch {
                        // The timeout task is cancelled when work finishes first.
                    }
                }

                box.setTasks(workTask: workTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            relay.cancel()
        }
    }

    /// Run one backfill against `song`. Returns a merged Song to flush
    /// (may be nil if extraction yielded nothing usable) and a flag
    /// indicating whether the attempt should be remembered as failed —
    /// the two are independent because some files parse partial tags
    /// (artist, album) but never expose duration.
    private func processOne(
        _ song: Song,
        isExplicitReread: Bool = false
    ) async -> BackfillOutcome {
        guard !Task.isCancelled else {
            return BackfillOutcome(song: nil, markFailed: false, cancelled: true)
        }
        guard isExplicitReread || !manuallyReadingSongIDs.contains(song.id) else {
            return BackfillOutcome(song: nil, markFailed: false)
        }
        guard activeReadSongIDs.insert(song.id).inserted else {
            return BackfillOutcome(song: nil, markFailed: false)
        }
        defer { activeReadSongIDs.remove(song.id) }
        let started = Date()
        do {
            let timeout = isExplicitReread
                ? Self.explicitRereadTimeout
                : Self.perSongTimeout
            return try await Self.withHardTimeout(seconds: timeout) { [self] in
                try await self.processOneCore(
                    song,
                    started: started,
                    isExplicitReread: isExplicitReread
                )
            }
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            let cancelled = error is CancellationError || Task.isCancelled
            if cancelled {
                plog("📥 Backfill: cancelled '\(song.title)' without consuming a retry")
                return BackfillOutcome(
                    song: nil,
                    markFailed: false,
                    cancelled: true
                )
            }
            let remainsReadable = isExplicitReread
                ? isStillReadable(song)
                : isStillEligible(song)
            if !remainsReadable {
                return BackfillOutcome(song: nil, markFailed: false)
            }
            // 只有「确定性永久」的错误(文件已不存在 / 4xx)才标记 failed —— 那种
            // 重试也没用,标记后不再浪费配额。连接/鉴权/超时/限流/网络这类是瞬时的
            // (常见于刚启动、源还没连上 / token 还没就绪),绝不能钉成永久失败,否则
            // 会一直卡在「无法读取歌曲详情」;不标记 → 下一轮回填自动重试。
            let transient = Self.isTransientBackfillError(error)
            var sourceUnavailable = Self.isSourceUnavailableBackfillError(error)
            if !sourceUnavailable, Self.needsSourceEndpointProbe(error) {
                sourceUnavailable = await sourceManager.metadataSourceEndpointsAreUnavailable(sourceID: song.sourceID)
            }
            guard !Task.isCancelled else {
                return BackfillOutcome(song: nil, markFailed: false, cancelled: true)
            }
            plog(String(format: "⚠️ Backfill failed for '%@' after %.2fs: %@ (%@)",
                        song.title, elapsed, error.localizedDescription,
                        transient ? "transient — will retry" : "permanent — marking failed"))
            return BackfillOutcome(
                song: nil,
                markFailed: false,
                sourceIssue: !transient,
                failureReason: error.localizedDescription,
                transientFailure: transient,
                sourceUnavailable: sourceUnavailable
            )
        }
    }

    private func processOneCore(
        _ song: Song,
        started: Date,
        isExplicitReread: Bool
    ) async throws -> BackfillOutcome {
        let remainsReadable = isExplicitReread
            ? isStillReadable(song)
            : isStillEligible(song)
        guard remainsReadable else {
            return BackfillOutcome(song: nil, markFailed: false)
        }
        // The cached auxiliary connector shares provider login/rate limits,
        // while SMB ranges use its separate background connection.
        let readSession = FileMetadataReader.RangeReadSession()
        let rangeReadIntent: MetadataRangeReadIntent = isExplicitReread
            ? .explicitSingleFileCompleteFallback
            : .bulkBounded
        var rangeElapsed: TimeInterval = 0
        var rangeCount = 0
        let cpuStarted = Self.processCPUTime()
        defer {
            if !Task.isCancelled {
                recordProcessingDuration(MetadataBackfillExecutionPolicy.processingDuration(
                    cpuTimeBefore: cpuStarted, cpuTimeAfter: Self.processCPUTime(),
                    fallback: max(0, Date().timeIntervalSince(started) - rangeElapsed)
                ))
            }
        }
        func fetchRange(offset: Int64, length: Int64) async throws -> Data {
            let rangeStarted = Date()
            defer {
                rangeElapsed += Date().timeIntervalSince(rangeStarted)
                rangeCount += 1
            }
            return try await sourceManager.fetchMetadataRange(
                for: song, offset: offset, length: length, intent: rangeReadIntent
            )
        }
        let fetchStarted = Date()
        let headData = try await fetchRange(offset: 0, length: Self.headBytes)
        let fetchElapsed = Date().timeIntervalSince(fetchStarted)

        // Do not turn metadata backfill into a whole-library playback-cache
        // prewarm. At 256 KB per song, a 10K-song source caused ~2.5 GB of
        // unnecessary writes and sustained I/O pressure while the user was
        // browsing. Playback already prewarms the current song and queue on
        // demand through SourceManager.

        var metadataInputData = headData
        var metadata = await extractMetadata(
            from: headData,
            song: song,
            readSession: readSession
        )
        let declaredExtension = song.fileFormat.rawValue.lowercased()
        var parserExtension = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: declaredExtension,
            signature: metadata.detectedFileSignature
        )
        let needsArtistInspection = (song.artistName?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !artistCheckedIDs.contains(song.id)
        var artistInspectionCompleted = !needsArtistInspection
            || metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if parserExtension == "mp3" {
            let id3ByteCount = FileMetadataReader.id3TagByteCount(in: headData)
            let hasTruncatedID3 = (id3ByteCount ?? 0) > headData.count
            let needsDurationExpansion = metadataLooksMissing(metadata)
            let needsArtworkExpansion = Self.needsEmbeddedArtworkBackfill(song)
                && metadata.coverArtFileName == nil && metadata.coverArtData == nil
            let needsArtistExpansion = needsArtistInspection
                && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            let expandedByteCount = RemoteMetadataReadPolicy.expandedReadSize(
                fileSize: song.fileSize,
                currentByteCount: headData.count,
                declaredID3ByteCount: id3ByteCount,
                metadataInsufficient: needsDurationExpansion && !hasTruncatedID3
            ).map { min($0, Self.maxMetadataHeadBytes) } ?? headData.count
            if (needsDurationExpansion || needsArtworkExpansion || needsArtistExpansion),
               expandedByteCount > headData.count {
                do {
                    let expandedHead = try await fetchRange(offset: 0, length: Int64(expandedByteCount))
                    metadataInputData = expandedHead
                    metadata = await extractMetadata(
                        from: expandedHead,
                        song: song,
                        readSession: readSession
                    )
                    if needsArtistExpansion,
                       metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        artistInspectionCompleted = true
                    }
                } catch {
                    throw error
                }
            }
        } else if parserExtension == "flac" {
            // FLAC metadata blocks declare their exact lengths. Walk only as
            // far as the visible block chain requires, so a 553 KB embedded
            // picture is recovered without charging every cover-less file the
            // full 4 MB ceiling.
            let needsFullTagInspection = !titleCheckedIDs.contains(song.id)
            var needsArtworkExpansion = Self.needsEmbeddedArtworkBackfill(song)
                && metadata.coverArtFileName == nil && metadata.coverArtData == nil
            var needsArtistExpansion = needsArtistInspection
                && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            while needsFullTagInspection || needsArtworkExpansion || needsArtistExpansion,
                  let expandedByteCount = RemoteMetadataReadPolicy.expandedFLACReadSize(
                    fileSize: song.fileSize,
                    currentData: metadataInputData
                  ) {
                let expandedHead = try await fetchRange(offset: 0, length: Int64(expandedByteCount))
                guard expandedHead.count > metadataInputData.count else {
                    throw BackfillRangeExpansionError(format: "FLAC")
                }
                metadataInputData = expandedHead
                metadata = await extractMetadata(
                    from: expandedHead,
                    song: song,
                    readSession: readSession
                )
                needsArtworkExpansion = Self.needsEmbeddedArtworkBackfill(song)
                    && metadata.coverArtFileName == nil && metadata.coverArtData == nil
                needsArtistExpansion = needsArtistInspection
                    && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }
            if needsArtistInspection { artistInspectionCompleted = true }
        } else if Self.boundedHeadTagExtensions.contains(parserExtension) {
            // ASF declares the complete header size and Ogg pages declare each
            // packet boundary. Expand only while the tag packet is visibly
            // incomplete, bounded by the same 4 MB metadata ceiling.
            while let expandedByteCount = EmbeddedTagMetadataParser.expandedHeadReadSize(
                fileSize: song.fileSize,
                currentData: metadataInputData,
                fileExtension: parserExtension
            ) {
                let expandedHead = try await fetchRange(offset: 0, length: Int64(expandedByteCount))
                guard expandedHead.count > metadataInputData.count else {
                    throw BackfillRangeExpansionError(format: parserExtension)
                }
                metadataInputData = expandedHead
                metadata = await extractMetadata(
                    from: expandedHead,
                    song: song,
                    readSession: readSession
                )
            }
            if needsArtistInspection { artistInspectionCompleted = true }
        } else if needsArtistInspection {
            artistInspectionCompleted = true
        }
        parserExtension = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: declaredExtension,
            signature: metadata.detectedFileSignature
        )
        let tailStrategy = RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: parserExtension,
            isExplicitReread: isExplicitReread
        )
        let needsSecondaryArtistRange = needsArtistInspection
            && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && (tailStrategy == .isoBaseMedia || tailStrategy == .mp3ID3)
        let needsSecondaryArtworkRange = tailStrategy == .isoBaseMedia
            && Self.needsEmbeddedArtworkBackfill(song)
            && metadata.coverArtFileName == nil && metadata.coverArtData == nil
        let needsSecondaryTagRange = tailStrategy != .none
            && (!titleCheckedIDs.contains(song.id)
                || needsArtistInspection
                || (Self.needsEmbeddedArtworkBackfill(song)
                    && metadata.coverArtFileName == nil && metadata.coverArtData == nil))
        var suffixMetadataUnavailable = false
        if metadataLooksMissing(metadata)
            || needsSecondaryArtistRange
            || needsSecondaryArtworkRange
            || needsSecondaryTagRange {
            do {
                if tailStrategy == .isoBaseMedia {
                    var readContainerTail = false
                    for tailSize in RemoteMetadataReadPolicy.containerTailReadSizes(fileSize: song.fileSize) {
                        do {
                            let tailData = try await fetchRange(offset: -Int64(tailSize), length: Int64(tailSize))
                            guard !tailData.isEmpty else { continue }
                            readContainerTail = true
                            metadata = await extractMetadata(
                                from: metadataInputData,
                                containerTailData: tailData,
                                song: song,
                                readSession: readSession
                            )
                            let foundArtist = metadata.artist?
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            let foundArtwork = metadata.coverArtFileName != nil || metadata.coverArtData != nil
                            if !metadataLooksMissing(metadata)
                                && (!needsSecondaryArtistRange || foundArtist)
                                && (!needsSecondaryArtworkRange || foundArtwork) {
                                break
                            }
                        } catch MetadataRangeReadError.suffixRangeUnsupported {
                            throw MetadataRangeReadError.suffixRangeUnsupported
                        } catch {
                            if needsSecondaryArtistRange || needsSecondaryArtworkRange { throw error }
                        }
                    }
                    if needsSecondaryArtistRange, readContainerTail {
                        artistInspectionCompleted = true
                    }
                } else if tailStrategy == .mp3ID3 {
                    do {
                        let tailData = try await fetchRange(offset: -Self.fallbackTailBytes, length: Self.fallbackTailBytes)
                        metadata = await extractMetadata(
                            from: metadataInputData,
                            id3TailData: tailData,
                            song: song,
                            readSession: readSession
                        )
                        if needsSecondaryArtistRange { artistInspectionCompleted = true }
                    } catch MetadataRangeReadError.suffixRangeUnsupported {
                        throw MetadataRangeReadError.suffixRangeUnsupported
                    } catch {
                        if needsSecondaryArtistRange { throw error }
                    }
                } else if tailStrategy == .apeV2 {
                    var tailData = try await fetchRange(offset: -Self.fallbackTailBytes, length: Self.fallbackTailBytes)
                    if let expanded = EmbeddedTagMetadataParser.expandedTailReadSize(
                        fileSize: song.fileSize,
                        currentData: tailData,
                        fileExtension: parserExtension
                    ), expanded > tailData.count {
                        tailData = try await fetchRange(offset: -Int64(expanded), length: Int64(expanded))
                    }
                    metadata = await extractMetadata(
                        from: metadataInputData,
                        id3TailData: tailData,
                        song: song,
                        readSession: readSession
                    )
                    if needsArtistInspection { artistInspectionCompleted = true }
                } else if tailStrategy == .dsfOffset,
                          let offset = EmbeddedTagMetadataParser.dsfMetadataOffset(in: metadataInputData),
                          offset < song.fileSize {
                    let header = try await fetchRange(offset: offset, length: 10)
                    let declared = EmbeddedTagMetadataParser.id3TagByteCount(in: header) ?? header.count
                    let available = max(0, song.fileSize - offset)
                    let byteCount = min(
                        Int64(RemoteMetadataReadPolicy.maximumHeadByteCount),
                        min(available, Int64(declared))
                    )
                    let tagData: Data
                    if byteCount > Int64(header.count) {
                        tagData = try await fetchRange(offset: offset, length: byteCount)
                    } else {
                        tagData = header
                    }
                    metadata = await extractMetadata(
                        from: metadataInputData,
                        id3TailData: tagData,
                        song: song,
                        readSession: readSession
                    )
                    if needsArtistInspection { artistInspectionCompleted = true }
                } else if tailStrategy == .containerID3 {
                    let tailData = try await fetchRange(offset: -Self.fallbackTailBytes, length: Self.fallbackTailBytes)
                    metadata = await extractMetadata(
                        from: metadataInputData,
                        id3TailData: tailData,
                        song: song,
                        readSession: readSession
                    )
                    if needsArtistInspection { artistInspectionCompleted = true }
                } else if tailStrategy == .genericEOF {
                    var tailData = try await fetchRange(offset: -Self.fallbackTailBytes, length: Self.fallbackTailBytes)
                    if let expanded = EmbeddedTagMetadataParser.expandedTailReadSize(
                        fileSize: song.fileSize,
                        currentData: tailData,
                        fileExtension: parserExtension
                    ), expanded > tailData.count {
                        tailData = try await fetchRange(offset: -Int64(expanded), length: Int64(expanded))
                    }
                    metadata = await extractMetadata(
                        from: metadataInputData,
                        id3TailData: tailData,
                        song: song,
                        readSession: readSession
                    )
                    if needsArtistInspection { artistInspectionCompleted = true }
                }
            } catch MetadataRangeReadError.suffixRangeUnsupported {
                if isExplicitReread {
                    throw MetadataRangeReadError.suffixRangeUnsupported
                }
                suffixMetadataUnavailable = true
                if needsArtistInspection {
                    artistInspectionCompleted = true
                }
                // Some WebDAV gateways ignore suffix Range requests and start
                // streaming the complete media object. Background scans keep
                // the already-read head metadata and skip the optional tail;
                // an explicit single-song reread may use the bounded complete-
                // file fallback selected by `rangeReadIntent` above.
            }
        }

        // Bounded ranges answer the common tag layouts. A user-initiated
        // reread may additionally materialize one complete file when the
        // format needs FFmpeg, the signature is still unknown, or no duration
        // was recoverable. This is the authoritative fallback for raw DTS and
        // other elementary streams; background maintenance never downloads a
        // whole library for this purpose.
        if isExplicitReread,
           (song.fileFormat.requiresFFmpeg
                || metadata.detectedFileSignature == .unknown
                || metadataLooksMissing(metadata)) {
            metadata = try await loadCompleteFileMetadata(for: song)
            artistInspectionCompleted = true
        }

        if MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: metadataInputData.count,
            expectedFileByteCount: song.fileSize,
            hasCompleteFileAccess: metadata.hasCompleteFileAccess,
            signature: metadata.detectedFileSignature,
            hasTechnicalProperties: metadata.hasTechnicalProperties
        ) {
            return BackfillOutcome(
                song: nil,
                markFailed: true,
                failureReason: String(
                    localized: "reread_song_tags_failure_unrecognized_audio"
                ),
                titleInspected: true,
                artistInspected: artistInspectionCompleted
            )
        }

        // Raw CBR MP3s and some OpenList-backed streams have valid MPEG frames
        // but no Xing/VBRI duration. FileMetadataReader still recovers their
        // bitrate from the bounded prefix, which is sufficient to estimate the
        // complete duration from the authoritative remote file size. This must
        // happen before the duration-missing failure gate below; the previous
        // correction ran afterwards and was therefore unreachable for exactly
        // these rows.
        if song.fileFormat == .mp3,
           metadata.duration <= 0,
           metadata.detectedFileSignature == .mpegAudio,
           (metadata.bitRate ?? 0) > 0 {
            let estimated = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: metadata.duration,
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate,
                providedByteCount: metadataInputData.count,
                leadingMetadataByteCount: FileMetadataReader.id3TagByteCount(in: metadataInputData) ?? 0
            )
            if estimated > 0 {
                metadata.duration = estimated
                metadata.hasTechnicalProperties = true
                plog(String(format: "📥 Backfill: '%@' recovered MP3 duration %.1fs from bounded metadata and file size", song.title, estimated))
            }
        }

        // Raw DTS and verified DTS-in-WAV streams do not publish their total
        // frame count in a bounded head/tail slice. Their complete remote byte
        // count and core bitrate still provide a stable provisional duration;
        // explicit rereads and playback use the complete file and therefore
        // keep their authoritative decoder duration instead.
        let hasVerifiedDTSCore = metadata.detectedFileSignature == .dts
            || metadata.detectedFileSignature == .dtsInWave
        if (song.fileFormat == .dts || song.fileFormat == .wav),
           (!metadata.duration.isFinite || metadata.duration <= 0),
           hasVerifiedDTSCore,
           let estimated = AudioDurationPolicy.provisionalStandaloneDTSDuration(
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate ?? song.bitRate,
                fileExtension: (song.filePath as NSString).pathExtension
           ) {
            metadata.duration = estimated
            metadata.hasTechnicalProperties = true
            plog(String(format: "📥 Backfill: '%@' recovered DTS duration %.1fs from bounded metadata and file size", song.title, estimated))
        }

        try Task.checkCancellation()
        metadata = await metadataService.storingEmbeddedAssets(in: metadata, cacheKey: song.id)

        // Duration can fail independently from the ID3 text frames. Preserve
        // any title/artist/album/cover we did recover, then mark the row failed
        // only to stop repeated network reads. Older code returned nil here,
        // so a valid TIT2 was silently thrown away and the filename remained
        // visible until an online scrape replaced the song.
        if metadataLooksMissing(metadata) {
            let partial = mergeSong(bare: song, metadata: metadata)
            let partialKind = completionKind(for: metadata, original: song, merged: partial)
            if partial != song
                || partialKind == .embeddedTags
                || partialKind == .sidecarMetadata
                || partialKind == .filenameInference {
                plog("⚠️ Backfill: '\(song.title)' has no duration after head+tail; saving verified partial tags as '\(partial.title)'")
                return BackfillOutcome(
                    song: partial,
                    markFailed: false,
                    completionKind: partialKind,
                    detailsIncomplete: true,
                    failureReason: String(
                        localized: "reread_song_tags_failure_requires_complete_technical_read"
                    ),
                    titleInspected: true,
                    artistInspected: artistInspectionCompleted,
                    artworkGivenUp: suffixMetadataUnavailable
                        && Self.needsEmbeddedArtworkBackfill(song)
                        && metadata.coverArtFileName == nil && metadata.coverArtData == nil
                )
            }
            if song.isStreamDescriptor || song.fileFormat.requiresFFmpeg {
                plog("📥 Backfill: '\(song.title)' remains playable with incomplete bounded metadata")
                return BackfillOutcome(
                    song: nil,
                    markFailed: false,
                    completionKind: partialKind,
                    detailsIncomplete: true,
                    failureReason: String(
                        localized: "reread_song_tags_failure_requires_complete_technical_read"
                    ),
                    titleInspected: true,
                    artistInspected: artistInspectionCompleted,
                    artworkGivenUp: suffixMetadataUnavailable
                        && Self.needsEmbeddedArtworkBackfill(song)
                        && metadata.coverArtFileName == nil && metadata.coverArtData == nil
                )
            }
            plog("⚠️ Backfill: '\(song.title)' bytes were read but details parsing failed")
            return BackfillOutcome(
                song: nil,
                markFailed: true,
                failureReason: String(
                    localized: "reread_song_tags_failure_no_supported_metadata"
                ),
                titleInspected: true,
                artistInspected: artistInspectionCompleted
            )
        }

        // After tightening `metadataLooksMissing` to require
        // duration > 0, reaching this point means head+tail
        // produced a usable duration. The old "merged.duration<=0
        // → markFailed" guard was firing on songs that just hadn't
        // had tail tried yet — removed.
        // Only reverse-compute for raw MP3. M4A/MP4/M4B carry
        // authoritative duration inside `moov.mvhd`; backfill's
        // tail-fetch already gets it correctly. Applying the
        // bytes-÷-bitrate heuristic to those formats wrongly
        // overwrites the correct value because m4a containers
        // often wrap data far larger than `bitRate × duration / 8`
        // (multiple tracks, padding, sidecar metadata) — observed
        // in the field as a 13MB / 198kbps m4a being "corrected"
        // from the real 177s to a bogus 562s.
        let ext = song.fileFormat.rawValue
        if ext == "mp3",
           metadata.detectedFileSignature == .mpegAudio,
           (metadata.bitRate ?? 0) > 0 {
            let originalDuration = metadata.duration
            metadata.duration = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: metadata.duration,
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate,
                providedByteCount: metadataInputData.count,
                leadingMetadataByteCount: FileMetadataReader.id3TagByteCount(in: metadataInputData) ?? 0
            )
            if metadata.duration != originalDuration {
                plog(String(format: "📥 Backfill: '%@' duration estimate %.1fs → %.1fs", song.title, originalDuration, metadata.duration))
            }
        } else if ext == "flac",
                  (metadata.bitRate ?? 0) <= 0,
                  metadata.duration > 0,
                  song.fileSize > 0 {
            metadata.bitRate = (Double(song.fileSize) * 8.0 / metadata.duration / 1000.0)
                .rounded()
                .finiteInt()
        }
        let merged = mergeSong(bare: song, metadata: metadata)
        let artworkStillMissing = Self.needsEmbeddedArtworkBackfill(song)
            && (merged.coverArtFileName?.isEmpty ?? true)
        let totalElapsed = Date().timeIntervalSince(started)
        // Include the parsed duration in the log line so an
        // infinite-loop case (pickNextBatch repeatedly handing back
        // the same songs) can be diagnosed without re-instrumenting:
        // duration=0 in the log means mergeSong didn't actually
        // capture a usable duration despite metadataLooksMissing
        // returning false → bug in the parser or the gate.
        plog(String(format: "📥 Backfill: '%@' done in %.2fs (fetch %.2fs, ranges %d in %.2fs) format=%@ duration=%.1fs", song.title, totalElapsed, fetchElapsed, rangeCount, rangeElapsed, parserExtension, merged.duration))
        if artworkStillMissing {
            plog("📥 Backfill: '\(song.title)' has no parseable embedded artwork; skipping future artwork-only retries")
        }
        // Missing artwork must NOT mark the song permanently failed — that
        // dropped its (just-parsed) duration at flush and stuck it bare. Keep
        // the duration, record the artwork give-up separately.
        return BackfillOutcome(
            song: merged,
            markFailed: false,
            completionKind: completionKind(for: metadata, original: song, merged: merged),
            titleInspected: true,
            artistInspected: artistInspectionCompleted,
            artworkGivenUp: artworkStillMissing
        )
    }

    private static func processCPUTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Keep parsing state local to this song; store assets only after all
    /// required ranges have contributed their tags.
    private func extractMetadata(
        from data: Data,
        containerTailData: Data? = nil,
        id3TailData: Data? = nil,
        song: Song,
        readSession: FileMetadataReader.RangeReadSession
    ) async -> MetadataService.SongMetadata {
        let ext = song.fileFormat.rawValue
        let pathTitle = MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
        let fallbackTitle = MediaMetadataTextRepair.preferred(
            embedded: song.title,
            fromFileName: pathTitle
        ) ?? song.title
        return await metadataService.loadEmbeddedMetadata(
            from: data,
            containerTailData: containerTailData,
            id3TailData: id3TailData,
            fileExtension: ext,
            fallbackTitle: fallbackTitle,
            readSession: readSession
        )
    }

    private func loadCompleteFileMetadata(
        for song: Song
    ) async throws -> MetadataService.SongMetadata {
        let url = try await sourceManager.resolveFullDownloadSourceURL(for: song)
        guard url.isFileURL else {
            throw SourceError.connectionFailed("Complete metadata read did not resolve a local file")
        }
        let fallbackTitle = MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
        var metadata = await metadataService.loadMetadata(
            for: url,
            cacheKey: song.id,
            allowOnlineFetch: false,
            fallbackTitle: fallbackTitle
        )
        if song.fileFormat.requiresFFmpeg || metadata.duration <= 0,
           let info = try? await FFmpegAudioDecoder().fileInfo(for: url) {
            if metadata.duration <= 0 { metadata.duration = info.duration }
            if (metadata.sampleRate ?? 0) <= 0 { metadata.sampleRate = info.sampleRate.finiteInt() }
            if (metadata.bitRate ?? 0) <= 0 { metadata.bitRate = info.bitRate }
            if (metadata.bitDepth ?? 0) <= 0 { metadata.bitDepth = info.bitDepth }
            metadata.hasTechnicalProperties = metadata.hasTechnicalProperties
                || info.duration > 0
                || info.sampleRate > 0
                || (info.bitRate ?? 0) > 0
                || (info.bitDepth ?? 0) > 0
        }
        metadata.hasCompleteFileAccess = true
        return metadata
    }

    private func metadataLooksMissing(_ m: MetadataService.SongMetadata) -> Bool {
        // Duration is the load-bearing field — without it the player
        // can't draw a progress bar and SFB streaming may decide the
        // song is shorter than it actually is. We treat duration alone
        // as the signal for "head fetch was insufficient, try tail".
        //
        // Why ignore artist/album: M4A/MP4/M4B commonly put `udta`
        // (artist/album tags) in the head but `moov` (which carries
        // duration via `mvhd`/`mdhd`) at the tail. The old rule only
        // fired tail-fetch when ALL of artist/album/duration were
        // missing — so these files passed with duration=0 and got
        // marked failed downstream. Failing on missing duration alone
        // costs one extra Range request for the small minority of
        // files that don't expose duration in head, and recovers the
        // common case where tail has it.
        !m.duration.isFinite || m.duration <= 0
    }

    private func resolvedIdentity(
        for song: Song,
        metadata: MetadataService.SongMetadata
    ) -> (title: MetadataResolvedText, artist: MetadataResolvedText) {
        let component = (song.filePath as NSString).lastPathComponent
        let rawStem = (component as NSString).deletingPathExtension
        let userEdited = song.userMetadataEditedAt != nil
        let mayInferFromFilename = hasVerifiedAudioEvidence(metadata)
        return (
            MetadataIdentityFallbackPolicy.resolve(
                existing: song.title,
                embedded: metadata.embeddedTitle,
                filenameInference: mayInferFromFilename
                    ? MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
                    : nil,
                rawFileStem: rawStem,
                isCueTrack: song.isCueTrack,
                userEdited: userEdited
            ),
            MetadataIdentityFallbackPolicy.resolve(
                existing: song.artistName,
                embedded: metadata.embeddedArtist,
                filenameInference: mayInferFromFilename
                    ? MediaMetadataTextRepair.fileNameArtist(from: song.filePath)
                    : nil,
                rawFileStem: nil,
                isCueTrack: song.isCueTrack,
                userEdited: userEdited
            )
        )
    }

    private func hasVerifiedAudioEvidence(
        _ metadata: MetadataService.SongMetadata
    ) -> Bool {
        MetadataReadEvidencePolicy.hasVerifiedAudioFile(
            signature: metadata.detectedFileSignature,
            hasTechnicalProperties: metadata.hasTechnicalProperties
        )
    }

    private func completionKind(
        for metadata: MetadataService.SongMetadata,
        original song: Song,
        merged _: Song
    ) -> MetadataReadCompletionKind {
        if metadata.hasEmbeddedDescriptiveMetadata { return .embeddedTags }
        if metadata.hasVerifiedSidecarMetadata || hasVerifiedSourceSidecarReference(in: song) {
            return .sidecarMetadata
        }
        let identity = resolvedIdentity(for: song, metadata: metadata)
        if identity.title.source == .filenameInference
            || identity.artist.source == .filenameInference {
            return .filenameInference
        }
        if metadata.hasTechnicalProperties { return .technicalProperties }
        return .verifiedNoMetadata
    }

    private func hasVerifiedSourceSidecarReference(in song: Song) -> Bool {
        let mediaParent = (song.filePath as NSString).deletingLastPathComponent
        return [song.coverArtFileName, song.lyricsFileName, song.mvPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { reference in
                guard !reference.isEmpty,
                      !reference.contains("://"),
                      reference.contains("/") else { return false }
                return (reference as NSString).deletingLastPathComponent == mediaParent
            }
    }

    private func restrictsToBareRows(
        _ song: Song,
        sourceIDs: Set<String>? = nil
    ) -> Bool {
        MetadataBackfillEligibilityPolicy.restrictsToBareRows(
            sourceUsesBareInventory: (sourceIDs ?? bareOnlySourceIDs()).contains(song.sourceID),
            isStreamDescriptor: song.isStreamDescriptor
        )
    }

    private func mergeSong(bare: Song, metadata: MetadataService.SongMetadata) -> Song {
        let isBareOnlySource = restrictsToBareRows(bare)
        let identity = resolvedIdentity(for: bare, metadata: metadata)
        let mergedTitle = identity.title.value ?? bare.title
        let mergedArtist = identity.artist.value ?? bare.artistName
        let mergedSourceArtistNames: [String]? = if bare.isCueTrack {
            bare.artistName != nil ? bare.sourceArtistNames : metadata.sourceArtistNames
        } else if identity.artist.source == .embedded {
            metadata.sourceArtistNames
        } else if mergedArtist == bare.artistName {
            bare.sourceArtistNames
        } else {
            nil
        }
        // 专辑名没有文件名兜底源 —— 目录名不可靠(常是 "音乐"、"新建文件夹"),
        // 拿它冒充专辑比留着乱码更糟。这里只做取舍不做替换。
        let mergedAlbum = bare.isCueTrack
            ? (bare.albumTitle ?? metadata.albumTitle)
            : MediaMetadataTextRepair.preferredAlbumTitle(
                current: bare.albumTitle, incoming: metadata.albumTitle,
                artist: bare.artistName, albumArtist: bare.albumArtistName
            )
        let mergedAlbumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: bare.isCueTrack
                ? (bare.albumArtistName ?? metadata.albumArtist)
                : (metadata.albumArtist ?? bare.albumArtistName),
            trackArtistName: mergedArtist
        )
        let artistID = mergedArtist.map { Self.hash($0.lowercased()) }
        let albumID: String? = if let albumArtist = mergedAlbumArtist, let album = mergedAlbum {
            Self.hash("\(albumArtist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        // Embedded assets are the first objective source. Verified sidecars
        // fill only missing embedded fields; CUE and local inventory references
        // stay authoritative because they already identify the exact sibling.
        let coverRef = bare.isCueTrack || isBareOnlySource
            ? (bare.coverArtFileName ?? metadata.coverArtFileName)
            : (metadata.coverArtFileName ?? bare.coverArtFileName)
        let lyricsRef = bare.isCueTrack || isBareOnlySource
            ? (bare.lyricsFileName ?? metadata.lyricsFileName)
            : (metadata.lyricsFileName ?? bare.lyricsFileName)
        let mvRef = bare.mvPath ?? metadata.mvPath
        let mergedFormat: AudioFormat = if bare.fileFormat == .wav,
                                             metadata.detectedFileSignature == .dts
                                                || metadata.detectedFileSignature == .dtsInWave {
            .dts
        } else {
            bare.fileFormat
        }

        let mergedDuration: TimeInterval = if bare.isCueTrack,
                                              let start = bare.cueStartTime {
            max(0, (bare.cueEndTime ?? metadata.duration) - start)
        } else {
            metadata.duration > 0 ? metadata.duration : bare.duration
        }

        let merged = Song(
            id: bare.id,
            title: mergedTitle,
            albumID: albumID,
            artistID: artistID,
            albumTitle: mergedAlbum,
            artistName: mergedArtist,
            sourceArtistNames: mergedSourceArtistNames,
            albumArtistName: mergedAlbumArtist,
            trackNumber: bare.isCueTrack ? bare.trackNumber : (metadata.trackNumber ?? bare.trackNumber),
            discNumber: metadata.discNumber ?? bare.discNumber,
            duration: mergedDuration,
            fileFormat: mergedFormat,
            filePath: bare.filePath,
            sourceID: bare.sourceID,
            fileSize: bare.fileSize,
            bitRate: metadata.bitRate ?? bare.bitRate,
            sampleRate: metadata.sampleRate ?? bare.sampleRate,
            bitDepth: metadata.bitDepth ?? bare.bitDepth,
            genre: metadata.genre ?? bare.genre,
            year: metadata.year ?? bare.year,
            lastModified: bare.lastModified,
            dateAdded: bare.dateAdded,
            serverPlayCount: bare.serverPlayCount,
            coverArtFileName: coverRef,
            artistArtworkFileName: bare.artistArtworkFileName,
            lyricsFileName: lyricsRef,
            mvPath: mvRef,
            replayGainTrackGain: metadata.replayGainTrackGain ?? bare.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak ?? bare.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain ?? bare.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak ?? bare.replayGainAlbumPeak,
            cueSheetPath: bare.cueSheetPath,
            cueStartTime: bare.cueStartTime,
            cueEndTime: bare.cueEndTime,
            revision: bare.revision,
            titlePinyin: mergedTitle == bare.title ? bare.titlePinyin : nil,
            artistPinyin: mergedArtist == bare.artistName ? bare.artistPinyin : nil,
            albumPinyin: mergedAlbum == bare.albumTitle ? bare.albumPinyin : nil,
            lyricsText: bare.lyricsText,
            userMetadataEditedAt: bare.userMetadataEditedAt
        )
        return SongUserMetadataPolicy.preservingUserEdits(from: bare, in: merged)
    }

    // MARK: - Queue selection

    /// `pickNextBatch` 的完整输入。全部是值语义快照 (Song 本身 Sendable),
    /// 所以同一段筛选既能在主 actor 上跑, 也能丢进 detached task。
    struct BatchSelectionInput: Sendable {
        let songs: [Song]
        let limit: Int
        let scopedSourceID: String?
        let allowedSourceIDs: Set<String>?
        let sourceIDs: Set<String>
        let bareOnlySourceIDs: Set<String>
        let disabledSourceIDs: Set<String>
        let manuallyReadingSongIDs: Set<String>
        let pendingFlushSongIDs: Set<String>
        let failedSongIDs: Set<String>
        let sourceIssueSongIDs: Set<String>
        let sessionGivenUpIDs: Set<String>
        let transientFailureCounts: [String: Int]
        let sourceTransientFailureCounts: [String: Int]
        let artworkGivenUpIDs: Set<String>
        let titleCheckedIDs: Set<String>
        let albumArtistCheckedIDs: Set<String>
        let artistCheckedIDs: Set<String>
        let incompleteSongIDs: Set<String>
    }

    private func makeBatchSelectionInput(
        limit: Int,
        allowedSourceIDs: Set<String>?
    ) -> BatchSelectionInput {
        let scopedSourceID: String?
        switch executionMode {
        case .userInitiated:
            scopedSourceID = userInitiatedSourceID
        case .foregroundDeviceLocal:
            scopedSourceID = automaticDeviceLocalSourceID
        case .background, .backgroundDuringPlayback:
            scopedSourceID = userInitiatedSourceID
        default:
            scopedSourceID = nil
        }
        return BatchSelectionInput(
            songs: library.songs,
            limit: limit,
            scopedSourceID: scopedSourceID,
            allowedSourceIDs: allowedSourceIDs,
            sourceIDs: backfillableSourceIDs(),
            bareOnlySourceIDs: bareOnlySourceIDs(),
            disabledSourceIDs: library.disabledSourceIDs,
            manuallyReadingSongIDs: manuallyReadingSongIDs,
            pendingFlushSongIDs: pendingFlushSongIDs,
            failedSongIDs: failedSongIDs,
            sourceIssueSongIDs: sourceIssueSongIDs,
            sessionGivenUpIDs: sessionGivenUpIDs,
            transientFailureCounts: transientFailureCounts,
            sourceTransientFailureCounts: sourceTransientFailureCounts,
            artworkGivenUpIDs: artworkGivenUpIDs,
            titleCheckedIDs: titleCheckedIDs,
            albumArtistCheckedIDs: albumArtistCheckedIDs,
            artistCheckedIDs: artistCheckedIDs,
            incompleteSongIDs: incompleteSongIDs
        )
    }

    /// 与旧实现同序、同结果, 但显式循环只会对每行求值一次谓词 ——
    /// `lazy.filter{}.prefix(n)` 先走一遍找结束下标, `Array(...)` 再走一遍。
    /// 仍然从 index 0 开始扫, 所以 runWorker 里「同一批 ID 反复出现就停摆」
    /// 的保护 (MetadataBackfillStallPolicy) 行为不变。
    nonisolated static func selectBatch(_ input: BatchSelectionInput) -> [Song] {
        let limit = max(1, input.limit)
        var selection: [Song] = []
        selection.reserveCapacity(min(limit, input.songs.count))
        for song in input.songs {
            if let scopedSourceID = input.scopedSourceID, song.sourceID != scopedSourceID { continue }
            if let allowedSourceIDs = input.allowedSourceIDs,
               !allowedSourceIDs.contains(song.sourceID) {
                continue
            }
            guard !input.manuallyReadingSongIDs.contains(song.id) else { continue }
            // 已读完但还没发布的歌在库里仍然是裸行; 再选一次就是重复下载。
            guard !input.pendingFlushSongIDs.contains(song.id) else { continue }
            guard !input.failedSongIDs.contains(song.id) else { continue }
            guard !input.sourceIssueSongIDs.contains(song.id) else { continue }
            guard !input.sessionGivenUpIDs.contains(song.id) else { continue }
            guard !Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: input.transientFailureCounts,
                sourceRetryCounts: input.sourceTransientFailureCounts
            ) else { continue }
            guard !input.disabledSourceIDs.contains(song.sourceID) else { continue }
            guard input.sourceIDs.contains(song.sourceID) else { continue }
            guard Self.needsBackfill(
                song,
                restrictToBareRows: MetadataBackfillEligibilityPolicy.restrictsToBareRows(
                    sourceUsesBareInventory: input.bareOnlySourceIDs.contains(song.sourceID),
                    isStreamDescriptor: song.isStreamDescriptor
                ),
                artworkGivenUpIDs: input.artworkGivenUpIDs,
                titleCheckedIDs: input.titleCheckedIDs,
                incompleteSongIDs: input.incompleteSongIDs,
                albumArtistCheckedIDs: input.albumArtistCheckedIDs,
                artistCheckedIDs: input.artistCheckedIDs
            ) else { continue }
            selection.append(song)
            if selection.count == limit { break }
        }
        return selection
    }

    /// A song needs backfill if it has none of the metadata that file-header
    /// extraction would produce (duration, bitRate). Songs in the failure
    /// set are skipped. Limited to a batch so the queue doesn't grow
    /// unbounded for huge libraries.
    private func pickNextBatch(
        limit: Int,
        allowedSourceIDs: Set<String>? = nil
    ) -> [Song] {
        Self.selectBatch(
            makeBatchSelectionInput(limit: limit, allowedSourceIDs: allowedSourceIDs)
        )
    }

    /// 与 `refreshRemainingCountsOffMain` 同一套路: 输入是 Sendable 快照,
    /// 整库筛选放到 detached task, 回到主 actor 再校验代次与源集合。期间资料库
    /// 或队列变过就退回同步选取, 结果与今天逐字一致。worker 每取一个快照
    /// (后台播放时只有 8 行) 就要扫一遍全库, 之前这一遍完全压在主 actor 上。
    private func pickNextBatchOffMain(
        limit: Int,
        allowedSourceIDs: Set<String>?
    ) async -> [Song] {
        let input = makeBatchSelectionInput(limit: limit, allowedSourceIDs: allowedSourceIDs)
        let songMutationGeneration = library.songMutationGenerationForMaintenance
        let queueGeneration = queueMutationGeneration
        let selection = await Task.detached(priority: .utility) {
            Self.selectBatch(input)
        }.value
        guard library.songMutationGenerationForMaintenance == songMutationGeneration,
              queueMutationGeneration == queueGeneration,
              backfillableSourceIDs() == input.sourceIDs,
              bareOnlySourceIDs() == input.bareOnlySourceIDs,
              library.disabledSourceIDs == input.disabledSourceIDs else {
            return pickNextBatch(limit: limit, allowedSourceIDs: allowedSourceIDs)
        }
        return selection
    }

    private func isStillEligible(_ song: Song) -> Bool {
        guard !failedSongIDs.contains(song.id) else { return false }
        guard !sourceIssueSongIDs.contains(song.id) else { return false }
        guard !sessionGivenUpIDs.contains(song.id) else { return false }
        guard !Self.automaticRetriesExhausted(
            songID: song.id,
            sourceID: song.sourceID,
            retryCounts: transientFailureCounts,
            sourceRetryCounts: sourceTransientFailureCounts
        ) else { return false }
        guard isStillReadable(song) else { return false }
        guard let live = library.song(id: song.id) else { return false }
        return self.needsBackfill(live)
    }

    private func isStillReadable(_ song: Song) -> Bool {
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return false }
        guard backfillableSourceIDs().contains(song.sourceID) else { return false }
        guard let live = library.song(id: song.id),
              live.sourceID == song.sourceID,
              live.filePath == song.filePath else {
            return false
        }
        if let liveRevision = live.revision, let expectedRevision = song.revision {
            guard liveRevision == expectedRevision else { return false }
        }
        if live.fileSize > 0, song.fileSize > 0 {
            guard live.fileSize == song.fileSize else { return false }
        }
        return true
    }

    /// Validate that an in-flight result still belongs to the live file. This
    /// deliberately ignores failedSongIDs: a partial result is marked failed
    /// before the coalesced flush, but its already-parsed tags must still land.
    private func backfillResultForApply(_ song: Song) -> Song? {
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return nil }
        guard backfillableSourceIDs().contains(song.sourceID) else { return nil }
        guard let live = library.song(id: song.id),
              live.sourceID == song.sourceID,
              live.filePath == song.filePath else {
            return nil
        }
        if let liveRevision = live.revision, let resultRevision = song.revision {
            guard liveRevision == resultRevision else { return nil }
        }
        if live.fileSize > 0, song.fileSize > 0 {
            guard live.fileSize == song.fileSize else { return nil }
        }
        return SongUserMetadataPolicy.preservingUserEdits(from: live, in: song)
    }

    /// A song still needs backfill if it's bare (no duration), or its supported
    /// embedded-tag container is missing a cover that has not been inspected. The
    /// artwork-give-up check keeps a duration-complete song from being re-picked
    /// forever just because its file has no embedded cover.
    private func needsBackfill(_ song: Song) -> Bool {
        Self.needsBackfill(
            song,
            restrictToBareRows: restrictsToBareRows(song),
            artworkGivenUpIDs: artworkGivenUpIDs,
            titleCheckedIDs: titleCheckedIDs,
            incompleteSongIDs: incompleteSongIDs,
            albumArtistCheckedIDs: albumArtistCheckedIDs,
            artistCheckedIDs: artistCheckedIDs
        )
    }

    private func workReasons(for song: Song) -> MetadataBackfillWorkReasons {
        Self.workReasons(
            restrictToBareRows: restrictsToBareRows(song),
            duration: song.duration,
            format: song.fileFormat,
            hasCoverArt: !(song.coverArtFileName?.isEmpty ?? true),
            artworkGivenUp: artworkGivenUpIDs.contains(song.id),
            titleChecked: titleCheckedIDs.contains(song.id),
            durationInspectionComplete: incompleteSongIDs.contains(song.id),
            hasAlbumTitle: !(song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasAlbumArtist: !(song.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            albumArtistChecked: albumArtistCheckedIDs.contains(song.id),
            hasArtist: !(song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            artistChecked: artistCheckedIDs.contains(song.id)
        )
    }

    private nonisolated static func needsBackfill(
        _ song: Song,
        restrictToBareRows: Bool,
        artworkGivenUpIDs: Set<String>,
        titleCheckedIDs: Set<String>,
        incompleteSongIDs: Set<String>,
        albumArtistCheckedIDs: Set<String>,
        artistCheckedIDs: Set<String>
    ) -> Bool {
        !workReasons(
            restrictToBareRows: restrictToBareRows,
            duration: song.duration,
            format: song.fileFormat,
            hasCoverArt: !(song.coverArtFileName?.isEmpty ?? true),
            artworkGivenUp: artworkGivenUpIDs.contains(song.id),
            titleChecked: titleCheckedIDs.contains(song.id),
            durationInspectionComplete: incompleteSongIDs.contains(song.id),
            hasAlbumTitle: !(song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasAlbumArtist: !(song.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            albumArtistChecked: albumArtistCheckedIDs.contains(song.id),
            hasArtist: !(song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            artistChecked: artistCheckedIDs.contains(song.id)
        ).isEmpty
    }

    private nonisolated static func workReasons(
        restrictToBareRows: Bool,
        duration: TimeInterval,
        format: AudioFormat,
        hasCoverArt: Bool,
        artworkGivenUp: Bool,
        titleChecked: Bool,
        durationInspectionComplete: Bool,
        hasAlbumTitle: Bool,
        hasAlbumArtist: Bool,
        albumArtistChecked: Bool,
        hasArtist: Bool,
        artistChecked: Bool
    ) -> MetadataBackfillWorkReasons {
        return MetadataBackfillEligibilityPolicy.reasons(
            duration: duration,
            format: format,
            hasCoverArt: hasCoverArt,
            artworkGivenUp: artworkGivenUp,
            titleChecked: titleChecked,
            restrictToBareRows: restrictToBareRows,
            durationInspectionComplete: durationInspectionComplete,
            hasAlbumTitle: hasAlbumTitle,
            hasAlbumArtist: hasAlbumArtist,
            albumArtistChecked: albumArtistChecked,
            hasArtist: hasArtist,
            artistChecked: artistChecked
        )
    }

    private static func needsEmbeddedArtworkBackfill(_ song: Song) -> Bool {
        MetadataBackfillEligibilityPolicy.embeddedArtworkFormats.contains(song.fileFormat)
            && (song.coverArtFileName?.isEmpty ?? true)
    }

    private nonisolated static func automaticRetriesExhausted(
        songID: String,
        sourceID: String,
        retryCounts: [String: Int],
        sourceRetryCounts: [String: Int]
    ) -> Bool {
        MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(retryCounts[songID] ?? 0)
            || MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(sourceRetryCounts[sourceID] ?? 0)
    }

    // MARK: - Failed-set persistence

    private func loadFailed() {
        guard let data = try? Data(contentsOf: failedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        failedSongIDs = Set(decoded)
    }

    private func loadIncomplete() {
        guard let data = try? Data(contentsOf: incompleteURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        incompleteSongIDs = Set(decoded)
    }

    private func loadSourceIssues() {
        guard let data = try? Data(contentsOf: sourceIssueURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        sourceIssueSongIDs = Set(decoded)
    }

    private func loadArtworkGivenUp() {
        guard let data = try? Data(contentsOf: artworkGivenUpURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        artworkGivenUpIDs = Set(decoded)
    }

    private func loadTitleChecked() {
        guard let data = try? Data(contentsOf: titleCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        titleCheckedIDs = Set(decoded)
    }

    private func loadAlbumArtistChecked() {
        guard let data = try? Data(contentsOf: albumArtistCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        albumArtistCheckedIDs = Set(decoded)
    }

    private func loadArtistChecked() {
        guard let data = try? Data(contentsOf: artistCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        artistCheckedIDs = Set(decoded)
    }

    private func loadDeferredRetries() {
        guard let data = try? Data(contentsOf: deferredRetryURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        mutateDeferredRetries { $0.replace(with: Set(decoded)) }
    }

    private func loadDiagnostics() {
        guard let data = try? Data(contentsOf: diagnosticsURL),
              let decoded = try? JSONDecoder().decode(
                [String: MetadataBackfillDiagnosticRecord].self,
                from: data
              ) else { return }
        diagnosticRecords = decoded
    }

    private func loadRetryCounts() {
        guard let data = try? Data(contentsOf: retryCountsURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        transientFailureCounts = Self.sanitizedRetryCounts(decoded)
    }

    private func loadSourceRetryCounts() {
        guard let data = try? Data(contentsOf: sourceRetryCountsURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        sourceTransientFailureCounts = Self.sanitizedRetryCounts(decoded)
    }

    private nonisolated static func sanitizedRetryCounts(
        _ counts: [String: Int]
    ) -> [String: Int] {
        counts.reduce(into: [:]) { result, entry in
            let (id, count) = entry
            guard !id.isEmpty, count > 0 else { return }
            result[id] = min(count, MetadataBackfillRetryPolicy.maximumAutomaticAttempts)
        }
    }

    private func saveArtworkGivenUp() {
        scheduleStatePersistence()
    }

    private func saveTitleChecked() {
        saveInspectionState()
    }

    private func saveInspectionState() {
        scheduleStatePersistence()
    }

    private func saveDeferredRetries() {
        scheduleStatePersistence()
    }

    private func saveDiagnostics() {
        scheduleStatePersistence()
    }

    private func saveRetryCounts() {
        scheduleStatePersistence()
    }

    private func clearDeferredRetries(in songs: [Song]) {
        var changed = false
        mutateDeferredRetries {
            changed = $0.subtract(songs.map(\.id))
            return changed
        }
        if changed {
            saveDeferredRetries()
        }
    }

    private func markMetadataInspected(songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let previousTitleCount = titleCheckedIDs.count
        let previousAlbumArtistCount = albumArtistCheckedIDs.count
        titleCheckedIDs.formUnion(songIDs)
        albumArtistCheckedIDs.formUnion(songIDs)
        if titleCheckedIDs.count != previousTitleCount
            || albumArtistCheckedIDs.count != previousAlbumArtistCount {
            saveInspectionState()
        }
    }

    private func markMetadataInspected(songID: String) {
        markMetadataInspected(songIDs: [songID])
    }

    private func markArtistInspected(songID: String) {
        markArtistsInspected(songIDs: [songID])
    }

    private func markArtistsInspected(songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let previousCount = artistCheckedIDs.count
        artistCheckedIDs.formUnion(songIDs)
        guard artistCheckedIDs.count != previousCount else { return }
        saveInspectionState()
    }

    private func clearAutomaticRetryState(songID: String, sourceID: String) {
        sessionGivenUpIDs.remove(songID)
        sessionNetworkParkedIDs.remove(songID)
        sessionStallParkedIDs.remove(songID)
        let songCountRemoved = transientFailureCounts.removeValue(forKey: songID) != nil
        let sourceCountRemoved = sourceTransientFailureCounts.removeValue(forKey: sourceID) != nil
        if songCountRemoved || sourceCountRemoved {
            saveRetryCounts()
        }
    }

    private func saveFailed() {
        scheduleStatePersistence()
    }

    private func scheduleStatePersistence(immediate: Bool = false) {
        // A busy backfill can touch several bookkeeping sets for every song.
        // Move one trailing deadline instead of cancelling and recreating a
        // MainActor task per result. The sets are copied only after the stream
        // of changes becomes quiet, preserving their copy-on-write fast path.
        let clock = ContinuousClock()
        statePersistenceDeadline = immediate
            ? clock.now
            : clock.now.advanced(by: Self.statePersistenceDebounce)
        if statePersistenceTask != nil, !immediate { return }

        let previous = statePersistenceTask
        previous?.cancel()
        statePersistenceTaskID &+= 1
        let taskID = statePersistenceTaskID
        statePersistenceTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.statePersistenceTaskID == taskID else { return }
            while !Task.isCancelled, self.statePersistenceTaskID == taskID {
                guard let deadline = self.statePersistenceDeadline else {
                    self.statePersistenceTask = nil
                    return
                }
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.statePersistenceTaskID == taskID else { return }
                if let movedDeadline = self.statePersistenceDeadline,
                   movedDeadline > clock.now {
                    continue
                }

                // Snapshot only after the debounce. Capturing every growing set on
                // every song kept old copy-on-write buffers alive and forced the
                // next mutation to copy them, which amplified CPU, memory, and disk
                // work during large WebDAV scans.
                self.statePersistenceDeadline = nil
                let failed = self.failedSongIDs
                let incomplete = self.incompleteSongIDs
                let sourceIssues = self.sourceIssueSongIDs
                let artworkGivenUp = self.artworkGivenUpIDs
                let titleChecked = self.titleCheckedIDs
                let albumArtistChecked = self.albumArtistCheckedIDs
                let artistChecked = self.artistCheckedIDs
                let deferredRetries = self.deferredRetrySongIDs
                let diagnostics = self.diagnosticRecords
                let retryCounts = self.transientFailureCounts
                let sourceRetryCounts = self.sourceTransientFailureCounts
                let failedURL = self.failedURL
                let incompleteURL = self.incompleteURL
                let sourceIssueURL = self.sourceIssueURL
                let artworkURL = self.artworkGivenUpURL
                let titleURL = self.titleCheckedURL
                let albumArtistURL = self.albumArtistCheckedURL
                let artistURL = self.artistCheckedURL
                let deferredRetryURL = self.deferredRetryURL
                let diagnosticsURL = self.diagnosticsURL
                let retryCountsURL = self.retryCountsURL
                let sourceRetryCountsURL = self.sourceRetryCountsURL

                await Task.detached(priority: .utility) {
                    Self.writeIDSet(failed, to: failedURL)
                    Self.writeIDSet(incomplete, to: incompleteURL)
                    Self.writeIDSet(sourceIssues, to: sourceIssueURL)
                    Self.writeIDSet(artworkGivenUp, to: artworkURL)
                    Self.writeIDSet(titleChecked, to: titleURL)
                    Self.writeIDSet(albumArtistChecked, to: albumArtistURL)
                    Self.writeIDSet(artistChecked, to: artistURL)
                    Self.writeIDSet(deferredRetries, to: deferredRetryURL)
                    Self.writeDiagnostics(diagnostics, to: diagnosticsURL)
                    Self.writeRetryCounts(retryCounts, to: retryCountsURL)
                    Self.writeRetryCounts(sourceRetryCounts, to: sourceRetryCountsURL)
                }.value

                guard self.statePersistenceTaskID == taskID else { return }
                if self.statePersistenceDeadline == nil {
                    self.statePersistenceTask = nil
                    return
                }
            }
        }
    }

    private nonisolated static func writeIDSet(_ ids: Set<String>, to url: URL) {
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func writeRetryCounts(_ counts: [String: Int], to url: URL) {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func writeDiagnostics(
        _ diagnostics: [String: MetadataBackfillDiagnosticRecord],
        to url: URL
    ) {
        guard let data = try? JSONEncoder().encode(diagnostics) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
