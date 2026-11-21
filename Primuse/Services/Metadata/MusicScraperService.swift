import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// Serializes sidecar writes per source and opens a session-only circuit after
/// a credential/permission failure. This prevents an eight-song publication
/// batch from creating eight SMB sessions and repeating the same rejected
/// write hundreds or thousands of times.
actor SidecarWriteCircuitBreaker {
    private struct SourceState {
        var isRunning = false
        var isUnavailable = false
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private var states: [String: SourceState] = [:]

    func acquire(sourceID: String) async -> Bool {
        var state = states[sourceID, default: SourceState()]
        if state.isUnavailable {
            return false
        }
        if !state.isRunning {
            state.isRunning = true
            states[sourceID] = state
            return true
        }
        return await withCheckedContinuation { continuation in
            state.waiters.append(continuation)
            states[sourceID] = state
        }
    }

    /// Returns true only for the operation that opened the circuit, allowing
    /// one concise diagnostic instead of one warning per song.
    func release(sourceID: String, sourceUnavailable: Bool) -> Bool {
        var state = states[sourceID, default: SourceState()]
        let didOpenCircuit = sourceUnavailable && !state.isUnavailable
        state.isUnavailable = state.isUnavailable || sourceUnavailable

        if state.isUnavailable {
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            state.isRunning = false
            states[sourceID] = state
            for waiter in waiters {
                waiter.resume(returning: false)
            }
        } else if !state.waiters.isEmpty {
            let next = state.waiters.removeFirst()
            states[sourceID] = state
            next.resume(returning: true)
        } else {
            state.isRunning = false
            states[sourceID] = state
        }
        return didOpenCircuit
    }

    /// A new user-initiated scrape is a new circuit-breaker run. Re-open only
    /// idle sources; an older sidecar task that is still finishing keeps its
    /// serialization state intact.
    func resetIdleUnavailableSources() {
        let sourceIDs = states.compactMap { sourceID, state in
            state.isUnavailable && !state.isRunning && state.waiters.isEmpty ? sourceID : nil
        }
        for sourceID in sourceIDs {
            states[sourceID] = nil
        }
    }
}

/// 续刮时"检查点已经没意义了, 可以删"的判定。抽成纯函数是为了让
/// Stage 2b 的回归(准备中的库永远不许清检查点)能被直接盯住 —— 服务本身
/// 要 MainActor 加一整套依赖, 单测里立不起来。
enum ScrapeResumePolicy {
    /// 只有库已经发布、并且检查点里的歌一首都没落回库里时, 才清检查点。
    /// 库还在 `.preparing` 时 `visibleSongs` 是空的, "一首都没匹配上"是假象。
    static func clearsCheckpoint(libraryIsReady: Bool, matchedSongs: Int) -> Bool {
        libraryIsReady && matchedSongs == 0
    }
}

@MainActor
@Observable
final class MusicScraperService {
    enum BatchScrapeStartResult: Equatable {
        case started(runID: UUID, songCount: Int)
        case busy
        case deferred
        case empty
        /// 一个刮削源都没启用 —— 调用方应引导用户去开启或导入刮削源。
        case noScraperSource
        /// 这一轮会往音频文件里嵌歌词，先等用户确认（根视图弹出说明代价的确认）。
        case awaitingConfirmation
    }

    /// 批量刮削开始前「会把歌词写进音频文件」的确认，根视图按它弹出。
    struct LyricsEmbeddingConfirmation: Identifiable, Equatable {
        let id = UUID()
        let songCount: Int
    }

    enum LyricsEmbeddingChoice: Sendable {
        /// 写进音频文件，并记下已知晓，以后批量刮削不再问。
        case embed
        /// 这一轮照常刮削，只是歌词不写进音频文件。
        case skipEmbedding
        case cancel
    }

    /// 发起批量刮削的入口对嵌歌词确认的要求。
    enum BatchLyricsEmbedding {
        /// 没确认过就先问。
        case ask
        /// 不能弹确认的入口（Siri 等）：确认过才嵌入，没确认过只写缓存和歌词文件。
        case onlyIfAcknowledged
        case decided(Bool)
    }

    nonisolated static let batchLyricsEmbeddingAcknowledgedKey = "primuse.scrape.batchLyricsEmbeddingAcknowledged"

    /// 任务 B 接线用：这首歌的歌词是不是用户主动清空的。为真时刮到的歌词不写，按「没去刮」算，不进失败清单。
    static var lyricsWereClearedByUser: (String) -> Bool = { _ in false }

    enum BatchScrapePhase: Equatable {
        case songs
        case artwork
    }

    /// 一轮批量刮削的结果。`updatedCount` 只数封面、歌词、标签至少补上一样并落了地的歌；
    /// 只有技术参数变了的算 `skippedCount`；有一部分刮到了却没存下、或整首出错的算 `failedCount`。
    /// `tally` 按部分细分，并带上这一轮自己发起的写回音乐源（嵌入、旁路文件、媒体服务器）的结果。
    struct BatchScrapeCompletion: Equatable {
        let runID: UUID
        let originPlaylistID: String?
        let songCount: Int
        let updatedCount: Int
        let skippedCount: Int
        let failedCount: Int
        let artworkTotalCount: Int
        let artworkAvailableCount: Int
        let artworkUnavailableCount: Int
        var tally = BatchScrapeTally()
        /// 从旧版本留下的断点续跑：分项计数只统计了续跑的那部分，摘要退回总数那一行。
        var tallyIsPartial = false

        var processedSongCount: Int {
            updatedCount + skippedCount + failedCount
        }
    }

    enum SingleScrapeStartResult: Equatable {
        case started(runID: UUID)
        case joined(runID: UUID)
        case busy
        case noScraperSource
    }

    struct SingleScrapeResult: Sendable {
        let originalSong: Song
        let song: Song
        let coverData: Data?
        let lyrics: [LyricLine]?
        var review = ScrapeReviewCatalog()
        /// 各部分落地的结局与写回音乐源的结果；预览（dry run）时为空。
        var outcome = SingleScrapeOutcome()
    }

    /// 快捷单曲刮削交给调用方的结局：封面、歌词存没存下，写回音乐源成没成。
    struct SingleScrapeOutcome: Sendable, Equatable {
        var parts: ScrapeSongParts?
        var writeback: ScrapeWritebackOutcome = .notAttempted
        /// 写回失败时音乐源报的错，可能为空。
        var writebackDetail: String?

        var coverSaveFailed: Bool { parts?.cover == .saveFailed }
        var lyricsSaveFailed: Bool { parts?.lyrics == .saveFailed }

        var writebackFailureReason: ScrapeWritebackFailureReason? {
            if case .failed(let reason) = writeback { return reason }
            return nil
        }
    }

    struct SingleScrapeCompletion: Sendable {
        let activity: SingleSongScrapeActivity
        let result: SingleScrapeResult?
        let errorMessage: String?
    }

    nonisolated static let sidecarCoverWriteEnabledKey = "primuse.sidecar.coverWriteEnabled"
    nonisolated static let sidecarLyricsWriteEnabledKey = "primuse.sidecar.lyricsWriteEnabled"
    nonisolated static let sidecarWriteTimeoutKey = "primuse.sidecar.writeTimeout"

    private let sourceManager: SourceManager
    private let sourceFileName: (Song) -> String?
    private let metadataService: MetadataService
    private let scrapeRetrySleep: @Sendable (TimeInterval) async throws -> Void
    private var scrapingTask: Task<Void, Never>?
    private var scrapingGeneration = 0
    private var backgroundEnrichmentTask: Task<Void, Never>?
    @ObservationIgnored var automaticWorkIsAllowed: () -> Bool = { true }
    private var enrichmentEnqueueTask: Task<Void, Never>?
    private var sidecarWriteTasks: [UUID: Task<Void, Never>] = [:]
    private let sidecarCircuitBreaker = SidecarWriteCircuitBreaker()
    private var singleScrapeTask: Task<SingleScrapeResult, Error>?
    private var pendingSingleScrapeCompletions: [SingleSongScrapeKey: SingleScrapeCompletion] = [:]
    private var singleScrapeCompletionOrder: [SingleSongScrapeKey] = []
    private var recentSingleScrapeCompletions: [UUID: SingleScrapeCompletion] = [:]
    private var singleScrapeRunOrder: [UUID] = []
    /// 联网补全的待办队列。只在动作里读、不进界面观察: 扫完一个上万首的源时逐首入队,
    /// 每加一首都会给观察者发一次通知。出队用游标, 不再每取一首就把整个数组往前挪一格。
    @ObservationIgnored private var pendingEnrichmentSongIDs: [String] = []
    @ObservationIgnored private var pendingEnrichmentHead = 0
    @ObservationIgnored private var pendingEnrichmentSongIDSet: Set<String> = []
    /// 这首歌的标签还没读、读标签那边还会去读它时为真(网盘、NAS 扫描入库时只有文件名,歌手、时长都是空的)。
    /// 后台补全先放着,等读完由 `tagReadsConcluded` 交回来:只凭文件名去搜,同名的别人的歌会被当成它,
    /// 封面、歌手、专辑一起配错。由 AppServices 接到 `MetadataBackfillService.willReadTags(of:)`。
    @ObservationIgnored var awaitsTagRead: ((Song) -> Bool)?
    @ObservationIgnored private var enrichmentAwaitingTagReadIDs: Set<String> = []
    /// 补全因为网络不通停下后, 正在等网络回来。
    @ObservationIgnored private var isWaitingForNetworkToEnrich = false

    private var hasPendingEnrichment: Bool {
        pendingEnrichmentHead < pendingEnrichmentSongIDs.count
    }
    private var isPausedForSceneTransition = false
    /// A batch scrape that the transition gate interrupted. Only that scrape
    /// restarts when the scene returns to the foreground without a background
    /// phase; the background continuation path handles the other case.
    private var sceneTransitionInterruptedScrape = false
    /// True while `pauseForSceneTransition()` holds new scraping work back.
    var isGatedForSceneTransition: Bool { isPausedForSceneTransition }
    /// Bound both observable full-library publications and checkpoint replay.
    /// A large library cannot afford a complete observable-array publication
    /// every few songs. Forty still bounds idempotent checkpoint replay, while
    /// the time gate below publishes slow network work at least every 5 seconds.
    private static let songPublicationBatchSize = 40
    private static let songPublicationInterval: TimeInterval = 5
    /// Sidecar writes run one at a time per source, and each queued write
    /// holds its scraped cover until it has written it. On a slow share
    /// (embedding covers rewrites whole audio files) lookups outrun the writes
    /// and covers used to pile up without bound; the batch waits instead.
    /// Two publication batches (`songPublicationBatchSize`).
    nonisolated static let maximumQueuedSidecarWrites = 80

    nonisolated static func sidecarBacklogIsFull(queuedWrites: Int) -> Bool {
        queuedWrites >= maximumQueuedSidecarWrites
    }
    private let scrapeCheckpointURL: URL
    private var scrapeCheckpoint: ScrapeCheckpoint?
    /// 断点是从盘上读来的、这个进程还没跑过它(被系统回收或闪退后重新打开)。
    @ObservationIgnored private var checkpointIsFromPreviousProcess = false
    /// 回到前台后隔一会儿再从断点续刮的那一次。场景又离开前台、用户停止时作废。
    @ObservationIgnored private var interruptedScrapeResumeTask: Task<Void, Never>?
    @ObservationIgnored private var interruptedScrapeResumeGeneration = 0
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    private struct ScrapeCheckpoint: Codable {
        var songIDs: [String]
        var forceRescrape: Bool
        var nextSongIndex: Int
        var updatedCount: Int?
        var skippedCount: Int?
        var failedCount: Int?
        var artworkTargetIDs: [String]?
        var runID: UUID?
        var originPlaylistID: String?
        /// 只补歌词 / 只补封面的一轮,续跑时范围不变。旧断点没有这一项 = 全部。
        var parts: ScrapeParts?
        /// 上一个进程留下的断点在前台自动续上时的起点。下次打开还停在这里 = 续上之后
        /// 一首都没往前走进程就没了,不再在前台自动续(`BatchScrapeForegroundResumePolicy`)。
        var launchResumeIndex: Int?
        /// 按部分的计数与失败清单。旧断点没有这一项，续跑时从空的开始。
        var tally: BatchScrapeTally?
        /// 分项计数只统计了续跑部分（旧断点续上的）。
        var tallyIsPartial: Bool?
        /// 这一轮开始时定下的：歌词要不要嵌进音频文件。旧断点没有这一项。
        var embedsLyrics: Bool?

        var hasPersistedSongCounts: Bool {
            updatedCount != nil && skippedCount != nil && failedCount != nil
        }
    }

    private(set) var isScraping = false { didSet { publishBatchActivity() } }
    private(set) var isBackgroundEnriching = false
    private(set) var currentSongTitle = ""
    private(set) var processedCount = 0 { didSet { publishBatchActivity() } }
    private(set) var totalCount = 0
    private(set) var updatedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0
    private(set) var batchPhase: BatchScrapePhase = .songs { didSet { publishBatchActivity() } }
    private(set) var songTotalCount = 0
    private(set) var artworkTotalCount = 0
    private(set) var artworkProcessedCount = 0 { didSet { publishBatchActivity() } }
    private(set) var artworkAvailableCount = 0
    private(set) var artworkUnavailableCount = 0
    /// 这一轮按部分的计数。只在完成和断点里读，不进界面观察：写回结果一首一首到，不该每到一首刷一次界面。
    @ObservationIgnored private var tally = BatchScrapeTally()
    @ObservationIgnored private var runTallyIsPartial = false
    /// 这一轮歌词要不要嵌进音频文件（批量刮削开始前确认过的结果）。
    @ObservationIgnored private var runEmbedsLyrics = false
    /// 这个进程里发起、还没结束的写回，按「轮次 + 歌曲」记。完成前等它们（`awaitRunWritebacks`），
    /// 被打断、等不到的从这里取出来记成失败；之后迟到的结果不再重复记。
    @ObservationIgnored private var inFlightWritebacks: [String: InFlightWriteback] = [:]
    /// 这个进程里最慢的一次写回用了多久，等写回的兜底按它放宽。
    @ObservationIgnored private var longestWritebackDuration: TimeInterval = 0
    /// 正在等这一轮的写回时为非空：这时点停止也要给出摘要。
    @ObservationIgnored private var awaitingRunContext: RunContext?
    @ObservationIgnored private var pendingBatchRequest: PendingBatchRequest?
    private(set) var pendingLyricsEmbeddingConfirmation: LyricsEmbeddingConfirmation?

    private struct InFlightWriteback {
        let runID: UUID
        let songID: String
        let title: String
        let startedAt: TimeInterval
    }

    private struct RunContext {
        let runID: UUID
        let originPlaylistID: String?
        let songCount: Int
        let forceRescrape: Bool
        let generation: Int
    }

    private struct PendingBatchRequest {
        let songs: [Song]
        let library: MusicLibrary
        let originPlaylistID: String?
        let parts: ScrapeParts
        let forceRescrape: Bool
    }

    private static func inFlightKey(runID: UUID, songID: String) -> String {
        runID.uuidString + "\u{1F}" + songID
    }
    private(set) var lastCompletion: BatchScrapeCompletion?
    private(set) var completionRevision: UInt = 0
    private(set) var activeRunID: UUID?
    private(set) var activeOriginPlaylistID: String?
    private(set) var activeSingleScrape: SingleSongScrapeActivity? {
        didSet {
            if let oldValue { PlayerActivityStore.shared.remove(oldValue.runID) }
            if let activeSingleScrape {
                PlayerActivityStore.shared.publish(.init(
                    id: activeSingleScrape.runID, songID: activeSingleScrape.key.songID,
                    title: String(localized: activeSingleScrape.key.purpose.requestedParts == .lyrics
                        ? "player_activity_lyrics" : "player_activity_scraping"), progress: nil
                ))
            }
        }
    }
    private let batchActivityID = UUID()

    private func publishBatchActivity() {
        guard isScraping else {
            PlayerActivityStore.shared.remove(batchActivityID)
            return
        }
        PlayerActivityStore.shared.publish(.init(
            id: batchActivityID, songID: nil,
            title: String(localized: batchPhase == .artwork || scrapeCheckpoint?.parts == .cover
                ? "player_activity_artwork"
                : (scrapeCheckpoint?.parts == .lyrics ? "player_activity_lyrics" : "player_activity_scraping")),
            progress: phaseTotalCount > 0 ? phaseProgress : nil
        ))
    }
    private(set) var singleScrapeCompletionRevision: UInt = 0
    private var pendingPlaylistCompletions: [String: BatchScrapeCompletion] = [:]
    private var artworkTargetIDs: [String] = []

    init(sourceManager: SourceManager, metadataService: MetadataService = MetadataService(),
         checkpointDirectory: URL? = nil,
         scrapeRetrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         sourceFileName: @escaping (Song) -> String? = { _ in nil }) {
        self.sourceManager = sourceManager
        self.metadataService = metadataService
        self.scrapeRetrySleep = scrapeRetrySleep
        self.sourceFileName = sourceFileName
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = checkpointDirectory ?? appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scrapeCheckpointURL = directory.appendingPathComponent("scrape-checkpoint.json")
        if let data = try? Data(contentsOf: scrapeCheckpointURL) {
            scrapeCheckpoint = try? JSONDecoder().decode(ScrapeCheckpoint.self, from: data)
        }
        checkpointIsFromPreviousProcess = scrapeCheckpoint?.songIDs.isEmpty == false
    }

    /// True when an interrupted batch scrape can be resumed after foregrounding
    /// or from the registered BGProcessingTask.
    var hasPendingScrape: Bool {
        scrapeCheckpoint?.songIDs.isEmpty == false
    }

    /// Includes the in-memory enrichment queue created by an explicit scrape.
    /// Ordinary launches have neither form of work and must stay completely
    /// silent when the scene moves to the background.
    var hasPendingBackgroundContinuation: Bool {
        hasPendingScrape
            || hasPendingEnrichment
            || isScraping
            || isBackgroundEnriching
    }

    var isSingleScraping: Bool {
        activeSingleScrape != nil
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }

    var phaseProcessedCount: Int {
        switch batchPhase {
        case .songs:
            return min(processedCount, songTotalCount)
        case .artwork:
            return artworkProcessedCount
        }
    }

    var phaseTotalCount: Int {
        switch batchPhase {
        case .songs:
            return songTotalCount
        case .artwork:
            return artworkTotalCount
        }
    }

    var phaseProgress: Double {
        guard phaseTotalCount > 0 else { return 0 }
        return min(Double(phaseProcessedCount) / Double(phaseTotalCount), 1)
    }

    /// Returns a playlist result once. Keeping it in the service lets a detail
    /// page recover feedback after navigation without replaying it every time.
    func consumeBatchCompletion(
        forPlaylistID playlistID: String,
        matching runID: UUID? = nil
    ) -> BatchScrapeCompletion? {
        guard let completion = pendingPlaylistCompletions[playlistID],
              runID == nil || completion.runID == runID else { return nil }
        pendingPlaylistCompletions[playlistID] = nil
        return completion
    }

    @discardableResult
    func scrapeMissingMetadata(in library: MusicLibrary) -> BatchScrapeStartResult {
        startScraping(in: library, forceRescrape: false)
    }

    /// `parts`:只补歌词或只补封面时,其余部分即使刮到了也不写。
    /// `askToEmbedLyrics`：不能弹确认的入口（Siri）传 false，没确认过就不往音频文件里嵌歌词。
    @discardableResult
    func scrapeMissingMetadata(
        songs: [Song],
        in library: MusicLibrary,
        originPlaylistID: String? = nil,
        parts: ScrapeParts = .all,
        askToEmbedLyrics: Bool = true
    ) -> BatchScrapeStartResult {
        startScraping(
            songs: songs,
            in: library,
            forceRescrape: false,
            originPlaylistID: originPlaylistID,
            parts: parts,
            lyricsEmbedding: askToEmbedLyrics ? .ask : .onlyIfAcknowledged
        )
    }

    /// 回应「会把歌词写进音频文件」的确认。选了写入就记下已知晓，以后批量刮削不再问。
    func resolveLyricsEmbeddingConfirmation(_ choice: LyricsEmbeddingChoice) {
        guard let request = pendingBatchRequest else {
            pendingLyricsEmbeddingConfirmation = nil
            return
        }
        pendingBatchRequest = nil
        pendingLyricsEmbeddingConfirmation = nil
        let embeds: Bool
        switch choice {
        case .cancel:
            plog("MusicScraperService: batch scrape cancelled at the lyrics embedding confirmation")
            return
        case .embed:
            UserDefaults.standard.set(true, forKey: Self.batchLyricsEmbeddingAcknowledgedKey)
            embeds = true
        case .skipEmbedding:
            embeds = false
        }
        plog("MusicScraperService: lyrics embedding confirmation answered embed=\(embeds) songs=\(request.songs.count)")
        startScraping(
            songs: request.songs,
            in: request.library,
            forceRescrape: request.forceRescrape,
            originPlaylistID: request.originPlaylistID,
            parts: request.parts,
            lyricsEmbedding: .decided(embeds)
        )
    }

    /// 这一轮会不会往音频文件里嵌歌词：选了歌词这部分、字段规则没跳过、「刮削后写回歌词」开着、
    /// 「歌词保存到」选了嵌入。具体每首还要按来源、格式收窄，这里只看设置。
    private static func batchWouldEmbedLyrics(parts: ScrapeParts, settings: ScraperSettings) -> Bool {
        BatchLyricsEmbeddingConsentPolicy.wouldEmbed(
            lyricsRequested: parts.contains(.lyrics) && settings.fieldRules[.lyrics].mode != .skip,
            lyricsWritebackEnabled: sidecarSettings().lyricsEnabled,
            embeddingMode: EmbeddedLyricsCopyPolicy.mode()
        )
    }

    @discardableResult
    func rescrapeLibrary(in library: MusicLibrary) -> BatchScrapeStartResult {
        startScraping(in: library, forceRescrape: true)
    }

    @discardableResult
    func startSingleScrape(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool = false, parts: ScrapeParts = .all
    ) -> SingleScrapeStartResult {
        let purpose: SingleSongScrapePurpose = dryRun ? .metadataPreview : .metadataApply
        let key = SingleSongScrapeKey(songID: song.id, purpose: purpose)
        return startManagedSingleScrape(key: key, in: library, parts: parts) { [self] in
            try await performSingleScrape(song: song, in: library, dryRun: dryRun, parts: parts)
        }
    }

    @discardableResult
    func startOnlineLyricsOnlyScrape(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool = false
    ) -> SingleScrapeStartResult {
        let purpose: SingleSongScrapePurpose = dryRun ? .lyricsPreview : .lyricsApply
        let key = SingleSongScrapeKey(songID: song.id, purpose: purpose)
        return startManagedSingleScrape(key: key, in: library) { [self] in
            await performOnlineLyricsOnlyScrape(song: song, in: library, dryRun: dryRun)
        }
    }

    func isSingleScrapeActive(
        songID: String,
        purposes: [SingleSongScrapePurpose]
    ) -> Bool {
        guard let key = activeSingleScrape?.key else { return false }
        return key.songID == songID && purposes.contains(key.purpose)
    }

    func consumeSingleScrapeCompletion(
        songID: String,
        purposes: [SingleSongScrapePurpose],
        matching runID: UUID? = nil
    ) -> SingleScrapeCompletion? {
        for purpose in purposes {
            let key = SingleSongScrapeKey(songID: songID, purpose: purpose)
            guard let completion = pendingSingleScrapeCompletions[key],
                  runID == nil || completion.activity.runID == runID else { continue }
            pendingSingleScrapeCompletions[key] = nil
            singleScrapeCompletionOrder.removeAll { $0 == key }
            return completion
        }
        return nil
    }

    private func startManagedSingleScrape(
        key: SingleSongScrapeKey,
        in library: MusicLibrary,
        parts: ScrapeParts? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> SingleScrapeResult
    ) -> SingleScrapeStartResult {
        guard !isScraping else {
            plog("MusicScraperService: rejected single scrape while batch scrape is active")
            return .busy
        }

        switch SingleSongScrapeSessionPolicy.admission(
            active: activeSingleScrape,
            request: key
        ) {
        case .join(let runID):
            plog("MusicScraperService: joined single scrape run=\(runID) song=\(key.songID.prefix(12))")
            return .joined(runID: runID)
        case .busy(let active):
            plog("MusicScraperService: rejected overlapping single scrape; active=\(active.runID)")
            return .busy
        case .start:
            break
        }

        // 只要歌词是用户点名要的(播放页「暂无歌词」)：只看有没有开着的歌词源，不看规则里的「跳过」。
        let requestedParts = parts ?? key.purpose.requestedParts
        let hasSource = requestedParts == .lyrics
            ? ScraperSettings.load().userRequestedSourceCount(for: .lyrics) > 0
            : ScraperAvailability.hasEnabledSource(for: requestedParts)
        guard hasSource else {
            plog("MusicScraperService: no enabled scraper source, single scrape aborted")
            return .noScraperSource
        }

        let activity = SingleSongScrapeActivity(runID: UUID(), key: key)
        pendingSingleScrapeCompletions[key] = nil
        singleScrapeCompletionOrder.removeAll { $0 == key }
        activeSingleScrape = activity

        let task = Task { @MainActor [weak self] () throws -> SingleScrapeResult in
            guard let self else { throw CancellationError() }
            do {
                let result = try await operation()
                finishSingleScrape(activity: activity, result: result, error: nil, in: library)
                return result
            } catch {
                finishSingleScrape(activity: activity, result: nil, error: error, in: library)
                throw error
            }
        }
        singleScrapeTask = task
        return .started(runID: activity.runID)
    }

    private func finishSingleScrape(
        activity: SingleSongScrapeActivity,
        result: SingleScrapeResult?,
        error: Error?,
        in library: MusicLibrary
    ) {
        guard activeSingleScrape?.runID == activity.runID else { return }

        let completion = SingleScrapeCompletion(
            activity: activity,
            result: result,
            errorMessage: error?.localizedDescription
        )
        pendingSingleScrapeCompletions[activity.key] = completion
        singleScrapeCompletionOrder.removeAll { $0 == activity.key }
        singleScrapeCompletionOrder.append(activity.key)
        while singleScrapeCompletionOrder.count > 8 {
            let expiredKey = singleScrapeCompletionOrder.removeFirst()
            pendingSingleScrapeCompletions[expiredKey] = nil
        }
        recentSingleScrapeCompletions[activity.runID] = completion
        singleScrapeRunOrder.removeAll { $0 == activity.runID }
        singleScrapeRunOrder.append(activity.runID)
        while singleScrapeRunOrder.count > 8 {
            let expiredRunID = singleScrapeRunOrder.removeFirst()
            recentSingleScrapeCompletions[expiredRunID] = nil
        }

        activeSingleScrape = nil
        singleScrapeTask = nil
        singleScrapeCompletionRevision &+= 1
        startBackgroundEnrichmentIfNeeded(in: library)
    }

    func awaitSingleScrape(runID: UUID) async throws -> SingleScrapeResult {
        if activeSingleScrape?.runID == runID, let singleScrapeTask {
            return try await singleScrapeTask.value
        }
        if let completion = recentSingleScrapeCompletions[runID] {
            if let result = completion.result {
                return result
            }
            throw ScraperError.networkError(
                completion.errorMessage ?? String(localized: "scrape_song_failed")
            )
        }
        throw ScraperError.busy
    }

    /// Scrape single song — never overwrites existing cover/lyrics with nil
    /// dryRun: if true, returns updated song without writing to library
    /// 刮削结果是按开始时取的那一行算的。那之后这首歌又被手改过(本机,或别的设备同步来的),
    /// 手改的字段以库里现在的为准,不能拿旧行盖回去、把标记也抹掉。
    static func rebasedOntoLatestUserEdits(
        _ songs: [Song], in library: MusicLibrary, preservingExistingArtwork: Bool = false,
        replacingArtworkReferences: [String: String] = [:]
    ) -> [Song] {
        songs.map { song in
            guard let live = library.storedSong(id: song.id) else { return song }
            var song = song
            // 刮削不改文件本身，文件身份以库里那一行为准：拿来刮的是开刮时的快照(可见集还可能是
            // 扫描提交前的旧行)，整行写回会把已经更新过的身份倒回去，之后嵌封面、改标签都被判成
            // 「源文件在编辑期间已发生变化」。单曲刮削在调用前已经这样做了，整批和后台补全同样要。
            song.filePath = live.filePath
            song.fileSize = live.fileSize
            song.lastModified = live.lastModified
            song.revision = live.revision
            if preservingExistingArtwork, live.coverArtFileName?.isEmpty == false,
               replacingArtworkReferences[song.id] != live.coverArtFileName {
                song.coverArtFileName = live.coverArtFileName
            }
            guard let liveMarker = live.userMetadataEditedAt,
                  (song.userMetadataEditedAt ?? .distantPast) < liveMarker else { return song }
            return SongUserMetadataPolicy.preservingUserEdits(from: live, in: song)
        }
    }

    func scrapeSingle(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool = false
    ) async throws -> (Song, Data?, [LyricLine]?) {
        let startResult = startSingleScrape(song: song, in: library, dryRun: dryRun)
        let runID: UUID
        switch startResult {
        case .started(let id), .joined(let id):
            runID = id
        case .busy:
            throw ScraperError.busy
        case .noScraperSource:
            throw ScraperError.noEnabledSource
        }
        let result = try await awaitSingleScrape(runID: runID)
        return (result.song, result.coverData, result.lyrics)
    }

    /// 同 `scrapeSingle`，交回完整结果：封面、歌词存没存下，写回音乐源成没成。
    func scrapeSingleResult(song: Song, in library: MusicLibrary) async throws -> SingleScrapeResult {
        switch startSingleScrape(song: song, in: library) {
        case .started(let runID), .joined(let runID):
            return try await awaitSingleScrape(runID: runID)
        case .busy:
            throw ScraperError.busy
        case .noScraperSource:
            throw ScraperError.noEnabledSource
        }
    }

    /// 只要歌词的单曲刮削是用户点名要歌词：规则里把歌词设成「跳过」也照样去找。
    /// 「跳过」只管批量刮削、后台自动补全和结果页的预选。
    private static func settingsForSingleScrape(parts: ScrapeParts) -> ScraperSettings {
        var settings = ScraperSettings.load()
        if parts == .lyrics, settings.fieldRules[.lyrics].mode == .skip {
            settings.fieldRules[.lyrics].mode = .inherit
        }
        return settings
    }

    private func performSingleScrape(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool, parts: ScrapeParts
    ) async throws -> SingleScrapeResult {
        await sidecarCircuitBreaker.resetIdleUnavailableSources()

        let settings = Self.settingsForSingleScrape(parts: parts)
        var scope = ScrapeScope()
        let processed = try await processedSongWithAssets(song, forceRescrape: true, storeAssets: !dryRun,
                                                        parts: parts, settings: settings, collectingReview: dryRun,
                                                        inspectsStaleReferences: !dryRun, scope: &scope)
        guard !dryRun else {
            guard let result = processed else {
                return SingleScrapeResult(originalSong: song, song: song, coverData: nil, lyrics: nil)
            }
            var preview = result.song
            // 预览不改任何东西：没刮到的封面、歌词不能显示成没有。
            if preview.coverArtFileName == nil { preview.coverArtFileName = song.coverArtFileName }
            if preview.lyricsFileName == nil { preview.lyricsFileName = song.lyricsFileName }
            return SingleScrapeResult(originalSong: song, song: preview, coverData: result.coverData,
                                      lyrics: result.lyricsLines, review: result.review)
        }

        // 单曲重新刮削是用户亲手点的：选中的封面按用户挑的记，在其它设备上也换；刮到的歌词算用户选的版本，
        // 之前清空过歌词的这次照写。文件型源刮到的值只存在资料库,不记用户编辑的话下次读标签就被换回(#173)。
        let isServerLibrary = await sourceManager.isServerLibrarySource(for: song)
        let applied = await applyScrapedResult(
            processed, scope: scope, to: song, parts: parts, coverOrigin: .selected,
            stampsUserEdit: !isServerLibrary, lyricsOrigin: .user
        )
        var outcome = SingleScrapeOutcome(parts: applied.parts)
        var updatedSong = applied.song
        guard applied.persists else {
            plog("MusicScraperService: single scrape left '\(song.title)' unchanged cover=\(applied.parts.cover.rawValue) lyrics=\(applied.parts.lyrics.rawValue) tags=\(applied.parts.tags.rawValue)")
            if let stale = applied.staleReferences {
                await clearStaleAssetReferences([stale], in: library)
            }
            return SingleScrapeResult(originalSong: song, song: library.storedSong(id: song.id) ?? song,
                                      coverData: nil, lyrics: nil, outcome: outcome)
        }

        // 文件身份以库里那一行为准：拿来刮削的可能是重扫前的旧行（正在播放那份），
        // 整行写回会把库里的版本倒回去，之后的写回都判成「编辑期间已发生变化」。
        if let stored = library.storedSong(id: updatedSong.id) {
            updatedSong.filePath = stored.filePath
            updatedSong.fileSize = stored.fileSize
            updatedSong.lastModified = stored.lastModified
            updatedSong.revision = stored.revision
        }
        library.replaceSong(Self.rebasedOntoLatestUserEdits([updatedSong], in: library)[0])
        // 失效的本机引用不在上面那一行里清（可能带着用户编辑标记），另外摘。
        if let stale = applied.staleReferences {
            await clearStaleAssetReferences([stale], in: library)
        }
        // 单曲重新刮削是用户亲手做的,刮到的封面在其它设备上也换;整张专辑、整库的补全不传图。
        if applied.storedCover != nil {
            SongTagEditStore.shared.recordUserChosenCovers(songIDs: [updatedSong.id])
        }
        plog("MusicScraperService: single scrape '\(song.title)' cover=\(applied.parts.cover.rawValue) lyrics=\(applied.parts.lyrics.rawValue) tags=\(applied.parts.tags.rawValue)")

        // 写回音乐源：媒体服务器走它的接口；文件型源按「封面保存到」「歌词保存到」写封面、歌词文件
        // 或嵌进音频文件，和刮削结果页的保存同一套规则。
        let serverWriteback = await writeBackToMediaServerIfSupported(
            original: song,
            updated: updatedSong,
            coverData: applied.storedCover,
            lyricsLines: applied.cachedLyrics
        )
        outcome.writeback = serverWriteback.outcome
        outcome.writebackDetail = serverWriteback.detail
        if let job = await scrapedAssetWritebackJob(for: updatedSong, applied: applied) {
            let sourceManager = self.sourceManager
            let circuitBreaker = self.sidecarCircuitBreaker
            let box = ScrapedAssetWritebackBox()
            let task = startSidecarWriteTask {
                let result = await MusicScraperService.performScrapedAssetWriteback(
                    job, sourceManager: sourceManager, library: library, circuitBreaker: circuitBreaker
                )
                await box.store(result)
            }
            // Keep the single-song operation inside the same gate until
            // its sidecar mutation finishes (or times out).
            await task?.value
            if let result = await box.result {
                outcome.writeback = outcome.writeback.combined(with: result.outcome)
                outcome.writebackDetail = outcome.writebackDetail ?? result.failureDetail
            }
        }
        if outcome.writeback != .notAttempted {
            plog("MusicScraperService: single scrape writeback '\(song.title)' result=\(String(describing: outcome.writeback))")
        }
        // 写回之后封面引用、文件身份、歌词来源标记可能都换了：交回库里和缓存里最新的那份。
        library.flushPendingAssetReferencePatches()
        var finalLyrics = applied.cachedLyrics
        if finalLyrics != nil, let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            finalLyrics = cached
        }
        return SingleScrapeResult(
            originalSong: song,
            song: library.storedSong(id: updatedSong.id) ?? updatedSong,
            coverData: applied.storedCover,
            lyrics: finalLyrics, review: processed?.review ?? ScrapeReviewCatalog(),
            outcome: outcome
        )
    }

    func suggestedScrapeTitle(for song: Song) async -> String {
        await resolvedScrapeFallbackTitle(for: song)
    }

    func suggestedSearchQuery(for song: Song) async -> String {
        let title = await suggestedScrapeTitle(for: song)
        return Self.searchQuery(title: title, artist: song.artistName)
    }

    func suggestedSidecarBaseName(for song: Song) async -> String {
        let local = Self.sidecarBaseName(for: song)
        guard Self.shouldUseOpaqueSidecarIdentity(for: song) else {
            return local
        }

        guard let remoteName = try? await sourceManager.remoteDisplayName(for: song) else {
            return local
        }
        let remoteBaseName = (remoteName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remoteBaseName.isEmpty ? local : remoteBaseName
    }

    /// Fetch lyrics independently of the source used for a metadata candidate.
    /// This is the same lyrics-only ScraperManager tier used by automatic
    /// scraping, exposed for the macOS candidate-first preview flow.
    func fetchOnlineLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async -> [LyricLine]? {
        await metadataService.fetchOnlineLyrics(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }

    func fieldReview(for song: Song, query: String, parts: ScrapeParts, searchLimit: Int) async -> ScrapeReviewCatalog {
        await metadataService.fieldReview(for: song, query: query, parts: parts, searchLimit: searchLimit)
    }

    func manualLyricsCandidates(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async -> [ScraperManager.ManualLyricsCandidate] {
        await metadataService.manualLyricsCandidates(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }

    /// Scrapes and stores lyrics without opening the source audio file.
    ///
    /// MusicKit cloud-library songs are playable by `ApplicationMusicPlayer`
    /// but intentionally have no filesystem URL that Primuse can decode. The
    /// regular metadata scrape starts by resolving such a URL, so it fails
    /// before reaching any online lyrics source. This lyrics-only path uses the
    /// metadata already supplied by Apple Music and writes the same hash cache
    /// as a regular successful scrape.
    func scrapeOnlineLyricsOnly(
        song: Song,
        in library: MusicLibrary
    ) async throws -> (song: Song, lyrics: [LyricLine]?) {
        let startResult = startOnlineLyricsOnlyScrape(song: song, in: library)
        let runID: UUID
        switch startResult {
        case .started(let id), .joined(let id):
            runID = id
        case .busy:
            throw ScraperError.busy
        case .noScraperSource:
            throw ScraperError.noEnabledSource
        }
        let result = try await awaitSingleScrape(runID: runID)
        return (result.song, result.lyrics)
    }

    private func performOnlineLyricsOnlyScrape(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool
    ) async -> SingleScrapeResult {
        let request = Self.settingsForSingleScrape(parts: .lyrics).request(for: song, parts: .lyrics, force: true)
        let unchanged = SingleScrapeResult(originalSong: song, song: song, coverData: nil, lyrics: nil)
        guard request.fields.contains(.lyrics) else { return unchanged }
        let fetched = await fetchOnlineLyrics(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil
        )
        guard let lyrics = fetched, !lyrics.isEmpty else {
            return SingleScrapeResult(
                originalSong: song,
                song: song,
                coverData: nil,
                lyrics: nil
            )
        }

        guard !dryRun else {
            return SingleScrapeResult(
                originalSong: song,
                song: song,
                coverData: nil,
                lyrics: lyrics
            )
        }

        var updated = library.storedSong(id: song.id) ?? song
        // 用户点名要的歌词：算用户选的版本，自动路径不再换掉它；之前清空过的这次照写（写进去即解除清空）。
        guard request.overwrites.contains(.lyrics) || updated.lyricsFileName?.isEmpty != false,
              await MetadataAssetStore.shared.cacheLyrics(
                lyrics, forSongID: song.id, force: request.overwrites.contains(.lyrics), origin: .user
              )
        else { return unchanged }
        updated.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
        library.replaceSong(updated)
        return SingleScrapeResult(
            originalSong: song,
            song: updated,
            coverData: nil,
            lyrics: lyrics
        )
    }

    nonisolated static func searchQuery(title: String, artist: String?) -> String {
        let identity = ScraperManager.searchTitleArtist(title, artist: artist, preservingVersionMarkers: true)
        var query = identity.title
        if let effectiveArtist = identity.artist,
           !effectiveArtist.isEmpty,
           ScraperManager.shouldAppendArtist(to: query, artist: effectiveArtist) {
            query += " \(effectiveArtist)"
        }
        return query
    }

    nonisolated static func sidecarBaseName(for song: Song) -> String {
        let base = pathBaseName(for: song)
        if !base.isEmpty { return base }

        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? song.id : title
    }

    nonisolated static func sidecarReferencePath(for song: Song, suffix: String) -> String? {
        guard shouldUseOpaqueSidecarIdentity(for: song) == false else {
            // OneDrive / Google Drive / Aliyun store Song.filePath as an
            // opaque item id. Their connector writes the sidecar beside the
            // real upstream file, but the generated "{id}-cover.jpg" path is
            // not readable later. Keep the local hash cache as the library ref.
            return nil
        }

        let songDir = (song.filePath as NSString).deletingLastPathComponent
        return (songDir as NSString).appendingPathComponent("\(sidecarBaseName(for: song))\(suffix)")
    }

    @discardableResult
    func enqueueBackgroundEnrichment(for songs: [Song], in library: MusicLibrary) -> Task<Void, Never>? {
        guard !songs.isEmpty else { return nil }
        let previous = enrichmentEnqueueTask
        enrichmentEnqueueTask = Task(priority: .utility) { [weak self, weak library] in
            await previous?.value
            guard let self, let library, !Task.isCancelled else { return }
            // Server catalogs stay authoritative until an explicit scrape. Resolve
            // once per source, not once per song in a large post-scan batch.
            var allowedSourceIDs: Set<String> = []
            for sourceID in Set(songs.map(\.sourceID)) {
                guard !Task.isCancelled else { return }
                if let source = await self.sourceManager.source(withID: sourceID),
                   source.isEnabled, !source.isDeleted, !source.type.isServerLibrary {
                    allowedSourceIDs.insert(sourceID)
                }
            }
            guard !allowedSourceIDs.isEmpty else { return }
            let eligibleSourceIDs = allowedSourceIDs
            let settings = ScraperSettings.load()
            let worker = Task.detached(priority: .utility) {
                var ids: [String] = []
                for (offset, song) in songs.enumerated() {
                    if offset % 512 == 0, Task.isCancelled { break }
                    if eligibleSourceIDs.contains(song.sourceID),
                       Self.shouldBackgroundEnrich(song, settings: settings) { ids.append(song.id) }
                }
                return ids
            }
            let ids = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            for start in stride(from: 0, to: ids.count, by: 256) {
                guard !Task.isCancelled else { return }
                while !self.automaticWorkIsAllowed() {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                for id in ids[start..<min(start + 256, ids.count)]
                    where self.pendingEnrichmentSongIDSet.insert(id).inserted {
                    self.pendingEnrichmentSongIDs.append(id)
                }
                self.startBackgroundEnrichmentIfNeeded(in: library)
                await Task.yield()
            }
        }
        return enrichmentEnqueueTask
    }

    /// 读标签那边不会再去读这些歌了(读好了、读不出、文件不在):在等它们的那几首放回补全队列。
    func tagReadsConcluded(songIDs: Set<String>, in library: MusicLibrary) {
        let concluded = enrichmentAwaitingTagReadIDs.intersection(songIDs)
        guard !concluded.isEmpty else { return }
        enrichmentAwaitingTagReadIDs.subtract(concluded)
        enqueueBackgroundEnrichment(for: concluded.compactMap { library.visibleSong(id: $0) }, in: library)
    }

    private func startBackgroundEnrichmentIfNeeded(in library: MusicLibrary) {
        guard !isPausedForSceneTransition,
              !isSingleScraping,
              backgroundEnrichmentTask == nil,
              hasPendingEnrichment else { return }
        backgroundEnrichmentTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.runBackgroundEnrichment(in: library)
        }
    }

    /// Briefly gates scraping while UIKit commits active → inactive →
    /// background. The work is resumed from its checkpoint shortly after the
    /// background phase arrives; this is not a policy pause. Without the gate,
    /// per-song library publications make SwiftUI recompute the 11k-song view
    /// graph inside UIKit's ten-second scene-update watchdog window.
    func pauseForSceneTransition() {
        guard !isPausedForSceneTransition else { return }
        isPausedForSceneTransition = true
        cancelInterruptedScrapeResume()
        let shouldHoldBackgroundWindow = isScraping
        sceneTransitionInterruptedScrape = isScraping
        plog("MusicScraperService: briefly gating publications for scene transition (scraping=\(isScraping))")

        if isScraping {
            cancel(preservingCheckpoint: true, reason: .sceneTransition)
        } else {
            cancelSidecarWriteTasks()
        }

        // cancel(preservingCheckpoint:) ends the old assertion. Re-acquire one
        // for the short transition gate so iOS keeps us runnable long enough
        // to restart from the checkpoint in the background phase.
        if shouldHoldBackgroundWindow {
            beginBackgroundTaskIfNeeded()
        }

        backgroundEnrichmentTask?.cancel()
        backgroundEnrichmentTask = nil
        isBackgroundEnriching = false
    }

    /// Counterpart of `pauseForSceneTransition()` for the inactive → active
    /// path (Control Center, notification shade, call banner, Face ID). Without
    /// it the gate stayed closed for the rest of the process whenever no
    /// background phase followed, so every later batch scrape was deferred and
    /// sidecar writes were dropped.
    func resumeAfterSceneTransition(in library: MusicLibrary) {
        if isPausedForSceneTransition {
            isPausedForSceneTransition = false
            let shouldResumeScrape = sceneTransitionInterruptedScrape
            sceneTransitionInterruptedScrape = false
            endBackgroundTaskIfHeld()
            plog("MusicScraperService: resuming after foreground scene transition (scrape=\(shouldResumeScrape))")
            if shouldResumeScrape {
                resumePendingScrape(in: library)
            }
            startBackgroundEnrichmentIfNeeded(in: library)
        }
        // 上面只接得回「这次切换当场打断的那一轮」。在后台被到期、挂起、回收打断的那一轮
        // 断点还在却没人续，界面上就是刮着刮着自己停了。
        scheduleInterruptedScrapeResume(in: library)
    }

    /// 回到前台(包括冷启动后第一次到前台)时，把停在断点上的批量刮削接着刮。
    /// 断点还在、又没在刮，就是被系统打断的：后台时间用完、进程被挂起或被回收、
    /// 后台放歌让路、刮削源一时不可用。用户点「停止」会连断点一起清掉，这里不会违背用户。
    /// 等曲库就绪、再让开回前台的头几秒才动手。
    func scheduleInterruptedScrapeResume(in library: MusicLibrary) {
        cancelInterruptedScrapeResume()
        guard hasPendingScrape, !isScraping else { return }
        let generation = interruptedScrapeResumeGeneration
        library.onReady { [weak self] in
            guard let self, self.interruptedScrapeResumeGeneration == generation else { return }
            self.interruptedScrapeResumeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(BatchScrapeForegroundResumePolicy.foregroundResumeDelay))
                guard !Task.isCancelled, let self,
                      self.interruptedScrapeResumeGeneration == generation else { return }
                self.interruptedScrapeResumeTask = nil
                self.resumeInterruptedScrapeInForeground(in: library)
            }
        }
    }

    private func cancelInterruptedScrapeResume() {
        interruptedScrapeResumeGeneration &+= 1
        interruptedScrapeResumeTask?.cancel()
        interruptedScrapeResumeTask = nil
    }

    /// `scheduleInterruptedScrapeResume` 等完之后的判定与执行；测试直接调，传入前台与安全模式状态。
    @discardableResult
    func resumeInterruptedScrapeInForeground(
        in library: MusicLibrary,
        isApplicationActive: Bool? = nil,
        isSafeModeActive: Bool? = nil
    ) -> BatchScrapeForegroundResumePolicy.Decision {
        let checkpoint = scrapeCheckpoint
        let resumeIndex = checkpoint.map { min(max($0.nextSongIndex, 0), $0.songIDs.count) } ?? 0
        let fromPreviousProcess = checkpointIsFromPreviousProcess
        let decision = BatchScrapeForegroundResumePolicy.decision(
            hasCheckpoint: hasPendingScrape,
            isBatchRunning: isScraping,
            isSingleRunning: isSingleScraping,
            isApplicationActive: (isApplicationActive ?? Self.applicationIsActive) && !isPausedForSceneTransition,
            isSafeModeActive: isSafeModeActive ?? Self.launchSafeModeIsActive,
            checkpointFromPreviousProcess: fromPreviousProcess,
            resumeIndex: resumeIndex,
            lastLaunchResumeIndex: checkpoint?.launchResumeIndex
        )
        let progress = "\(resumeIndex)/\(checkpoint?.songIDs.count ?? 0)"
        switch decision {
        case .skip(.noCheckpoint), .skip(.alreadyRunning), .skip(.leavingForeground):
            break
        case .skip(let reason):
            plog("MusicScraperService: interrupted batch scrape at \(progress) not resumed in foreground (\(reason.rawValue))")
        case .resume:
            if fromPreviousProcess, var checkpoint {
                checkpoint.launchResumeIndex = resumeIndex
                scrapeCheckpoint = checkpoint
                writeScrapeCheckpoint(checkpoint)
            }
            plog("MusicScraperService: resuming interrupted batch scrape in foreground at \(progress) (\(fromPreviousProcess ? "left by an earlier launch" : "stopped by the system in this launch"))")
            resumePendingScrape(in: library)
        }
        return decision
    }

    private static var applicationIsActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    private static var launchSafeModeIsActive: Bool {
        #if os(iOS)
        LaunchDiagnostics.isSafeModeActive
        #else
        false
        #endif
    }

    /// Continue the same scrape in the normal UIApplication background window
    /// once the scene transition itself has settled. BGProcessingTask remains
    /// the longer-running continuation after that finite window expires.
    func resumeBackgroundContinuation(in library: MusicLibrary) {
        guard hasPendingBackgroundContinuation else { return }
        isPausedForSceneTransition = false
        sceneTransitionInterruptedScrape = false
        plog("MusicScraperService: continuing scrape after background scene settled")
        resumePendingScrape(in: library, allowBackgroundExecution: true)
        startBackgroundEnrichmentIfNeeded(in: library)
    }

    /// 批量刮削为什么停在半路，只用于诊断日志：分得清是到期、让路还是用户自己停的。
    enum BatchScrapeStopReason: String {
        case userStopped = "user stopped"
        case sceneTransition = "scene transition"
        case backgroundTimeExpired = "background time expired"
        case backgroundProcessingExpired = "background processing expired"
        case backgroundPlayback = "background playback started"
    }

    /// 用户点「停止」：断点一起清掉，之后回到前台也不会自动续。
    func cancel() {
        cancelInterruptedScrapeResume()
        cancel(preservingCheckpoint: false, reason: .userStopped)
    }

    /// Used only when iOS expires a background execution window. The current
    /// task stops at an atomic song boundary, while the persisted request is
    /// retained so the next system/foreground opportunity can restart it.
    func cancelPreservingCheckpoint(reason: BatchScrapeStopReason) {
        cancel(preservingCheckpoint: true, reason: reason)
    }

    private func cancel(preservingCheckpoint: Bool, reason: BatchScrapeStopReason) {
        if isScraping {
            let phase = batchPhase == .artwork ? "artwork" : "songs"
            let keepsCheckpoint = preservingCheckpoint && scrapeCheckpoint != nil
            plog("MusicScraperService: batch scrape stopped (\(reason.rawValue)) at \(phaseProcessedCount)/\(phaseTotalCount) phase=\(phase) checkpoint=\(keepsCheckpoint ? "kept" : "cleared")")
        }
        // 用户在等写回时点停止：歌都处理完了，照样给出摘要（没写完的记成被打断）。
        let finishingRun = preservingCheckpoint ? nil : awaitingRunContext
        awaitingRunContext = nil
        scrapingGeneration += 1
        // 先把还在写的记成被打断，断点落盘时带上这份结果。
        cancelSidecarWriteTasks()
        if preservingCheckpoint, let scrapeCheckpoint {
            writeScrapeCheckpoint(scrapeCheckpoint)
        }
        scrapingTask?.cancel()
        scrapingTask = nil
        isScraping = false
        currentSongTitle = ""
        endBackgroundTaskIfHeld()
        if let finishingRun {
            finishBatchRun(finishingRun)
        }
        if !preservingCheckpoint {
            clearScrapeCheckpoint()
            activeRunID = nil
            activeOriginPlaylistID = nil
        }
    }

    func resumePendingScrape(
        in library: MusicLibrary,
        allowBackgroundExecution: Bool = false
    ) {
        // Stage 2b: 库还在准备时 `visibleSongs` 是空的, 检查点里的歌一首都匹配
        // 不上, 下面那一步会把上一轮批量刮削的检查点直接删掉 —— 而且没有任何
        // 人会把它恢复回来。守卫放在入口, 后台 settle / 场景切换 / BGProcessing
        // 所有调用方一起覆盖。
        guard library.isReady else {
            library.onReady { [weak self] in
                self?.resumePendingScrape(
                    in: library,
                    allowBackgroundExecution: allowBackgroundExecution
                )
            }
            return
        }
        if allowBackgroundExecution {
            isPausedForSceneTransition = false
        }
        guard allowBackgroundExecution || !isPausedForSceneTransition,
              !isScraping,
              let checkpoint = scrapeCheckpoint else { return }
        let songsByID = IndexedSongSnapshot(library.visibleSongs)
        // Checkpoints written before result counters were introduced cannot be
        // resumed with an accurate aggregate. Replaying them from the beginning
        // is idempotent and avoids reporting only the tail as the whole result.
        let startIndex = checkpoint.hasPersistedSongCounts
            ? min(max(checkpoint.nextSongIndex, 0), checkpoint.songIDs.count)
            : 0
        let songs = checkpoint.songIDs.compactMap { songsByID[$0] }
        let pendingSongs = checkpoint.songIDs.dropFirst(startIndex).compactMap { songsByID[$0] }
        if ScrapeResumePolicy.clearsCheckpoint(
            libraryIsReady: library.isReady,
            matchedSongs: songs.count
        ) {
            clearScrapeCheckpoint()
            return
        }
        // 上面的判定已经覆盖了"已就绪且一首都没匹配上"; 这一条只是不让空队列
        // 进入 `startScraping`。
        guard !songs.isEmpty else { return }
        plog("MusicScraperService: resuming batch scrape from checkpoint at \(startIndex)/\(checkpoint.songIDs.count) background=\(allowBackgroundExecution)")
        startScraping(
            songs: songs,
            pendingSongs: pendingSongs,
            in: library,
            forceRescrape: checkpoint.forceRescrape,
            saveCheckpoint: false,
            allowBackgroundExecution: allowBackgroundExecution,
            resumeCheckpoint: checkpoint
        )
    }

    func waitUntilScrapeIdle() async {
        while isScraping {
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func startScraping(
        in library: MusicLibrary,
        forceRescrape: Bool
    ) -> BatchScrapeStartResult {
        // 整库刮削只管音乐：有声内容按章节名去音乐库里匹配，拿回来的是同名
        // 歌曲的歌词、封面和专辑，只会把书弄乱。单独选中的有声条目仍照常刮。
        startScraping(songs: library.musicSongs, in: library, forceRescrape: forceRescrape)
    }

    @discardableResult
    private func startScraping(
        songs requestedSongs: [Song],
        pendingSongs requestedPendingSongs: [Song]? = nil,
        in library: MusicLibrary,
        forceRescrape: Bool,
        saveCheckpoint: Bool = true,
        allowBackgroundExecution: Bool = false,
        resumeCheckpoint: ScrapeCheckpoint? = nil,
        originPlaylistID: String? = nil,
        parts requestedParts: ScrapeParts = .all,
        lyricsEmbedding: BatchLyricsEmbedding = .ask
    ) -> BatchScrapeStartResult {
        guard !isScraping, !isSingleScraping else {
            plog("MusicScraperService: ignored overlapping batch scrape request")
            return .busy
        }
        guard ScraperAvailability.hasEnabledSource(
            for: resumeCheckpoint.map { $0.parts ?? .all } ?? requestedParts
        ) else {
            plog("MusicScraperService: no enabled scraper source, batch scrape not started")
            return .noScraperSource
        }
        guard allowBackgroundExecution || !isPausedForSceneTransition else {
            plog("MusicScraperService: deferred batch scrape during scene transition")
            return .deferred
        }

        let songs = requestedSongs.reduce(into: (ordered: [Song](), seen: Set<String>())) { result, song in
            guard result.seen.insert(song.id).inserted else { return }
            result.ordered.append(library.unobservedVisibleSong(id: song.id) ?? song)
        }.ordered
        guard !songs.isEmpty else { return .empty }
        let pendingSongs: [Song]
        if let requestedPendingSongs {
            pendingSongs = requestedPendingSongs.reduce(
                into: (ordered: [Song](), seen: Set<String>())
            ) { result, song in
                guard result.seen.insert(song.id).inserted else { return }
                result.ordered.append(library.unobservedVisibleSong(id: song.id) ?? song)
            }.ordered
        } else {
            pendingSongs = songs
        }
        let runID = resumeCheckpoint?.runID ?? UUID()
        let runOriginPlaylistID = resumeCheckpoint?.originPlaylistID ?? originPlaylistID
        let parts = resumeCheckpoint.map { $0.parts ?? .all } ?? requestedParts
        // 这一轮歌词要不要嵌进音频文件。没确认过的先问；续跑按开始时定下的，旧断点没记的只有知晓过才嵌入。
        let acknowledged = UserDefaults.standard.bool(forKey: Self.batchLyricsEmbeddingAcknowledgedKey)
        let embedsLyrics: Bool
        if let resumeCheckpoint {
            embedsLyrics = BatchLyricsEmbeddingConsentPolicy.resumedRunEmbeds(
                recordedChoice: resumeCheckpoint.embedsLyrics, acknowledged: acknowledged
            )
        } else {
            let wouldEmbed = Self.batchWouldEmbedLyrics(parts: parts, settings: ScraperSettings.load())
            switch lyricsEmbedding {
            case .decided(let choice):
                embedsLyrics = choice && wouldEmbed
            case .onlyIfAcknowledged:
                embedsLyrics = wouldEmbed && acknowledged
            case .ask:
                if BatchLyricsEmbeddingConsentPolicy.needsConfirmation(wouldEmbed: wouldEmbed, acknowledged: acknowledged) {
                    pendingBatchRequest = PendingBatchRequest(
                        songs: songs, library: library, originPlaylistID: runOriginPlaylistID,
                        parts: parts, forceRescrape: forceRescrape
                    )
                    pendingLyricsEmbeddingConfirmation = LyricsEmbeddingConfirmation(songCount: songs.count)
                    plog("MusicScraperService: batch scrape waits for the lyrics embedding confirmation songs=\(songs.count)")
                    return .awaitingConfirmation
                }
                embedsLyrics = wouldEmbed
            }
        }
        // 旧版本留下、只有总数的断点：分项计数只能从续跑处算起，摘要退回总数那一行。
        let tallyIsPartial = resumeCheckpoint.map { checkpoint in
            checkpoint.tallyIsPartial
                ?? (checkpoint.tally == nil && checkpoint.hasPersistedSongCounts && checkpoint.nextSongIndex > 0)
        } ?? false
        if saveCheckpoint {
            persistScrapeCheckpoint(
                songIDs: songs.map(\.id),
                forceRescrape: forceRescrape,
                runID: runID,
                originPlaylistID: runOriginPlaylistID,
                parts: parts,
                embedsLyrics: embedsLyrics
            )
        } else if var checkpoint = scrapeCheckpoint,
                  checkpoint.runID == nil || checkpoint.originPlaylistID != runOriginPlaylistID
                    || checkpoint.embedsLyrics == nil || checkpoint.tallyIsPartial == nil {
            // Upgrade checkpoints written by an older build so any later
            // lifecycle resume keeps the same run identity and UI ownership.
            checkpoint.runID = runID
            checkpoint.originPlaylistID = runOriginPlaylistID
            checkpoint.embedsLyrics = embedsLyrics
            checkpoint.tallyIsPartial = tallyIsPartial
            scrapeCheckpoint = checkpoint
            writeScrapeCheckpoint(checkpoint)
        }
        let logicalSongCount = resumeCheckpoint?.songIDs.count ?? songs.count
        updatedCount = resumeCheckpoint?.updatedCount ?? 0
        skippedCount = resumeCheckpoint?.skippedCount ?? 0
        failedCount = resumeCheckpoint?.failedCount ?? 0
        processedCount = updatedCount + skippedCount + failedCount
        tally = resumeCheckpoint?.tally ?? BatchScrapeTally()
        runTallyIsPartial = tallyIsPartial
        runEmbedsLyrics = embedsLyrics
        totalCount = logicalSongCount
        currentSongTitle = ""
        batchPhase = .songs
        songTotalCount = logicalSongCount
        artworkTotalCount = 0
        artworkTargetIDs = []
        artworkAvailableCount = 0
        artworkUnavailableCount = 0
        artworkProcessedCount = 0
        activeOriginPlaylistID = runOriginPlaylistID
        activeRunID = runID
        // 这个进程已经跑过这份断点(或开了新的一轮)：之后再被打断不是闪退留下的。
        checkpointIsFromPreviousProcess = false
        cancelInterruptedScrapeResume()
        isScraping = true
        scrapingGeneration += 1
        let generation = scrapingGeneration
        let runContext = RunContext(
            runID: runID, originPlaylistID: runOriginPlaylistID, songCount: logicalSongCount,
            forceRescrape: forceRescrape, generation: generation
        )
        beginBackgroundTaskIfNeeded()

        scrapingTask = Task {
            var deferredForSourceFailure = false
            await sidecarCircuitBreaker.resetIdleUnavailableSources()
            defer {
                let cancelled = Task.isCancelled
                if scrapingGeneration == generation {
                    awaitingRunContext = nil
                    isScraping = false
                    currentSongTitle = ""
                    scrapingTask = nil
                    endBackgroundTaskIfHeld()
                    // Fire the completion notification only when the run actually
                    // finished — cancellation (user hit "stop") shouldn't pop one.
                    if !cancelled && !deferredForSourceFailure {
                        finishBatchRun(runContext)
                    }
                    activeRunID = nil
                    activeOriginPlaylistID = nil
                }
            }

            let settings = ScraperSettings.load()
            let coverRule = settings.fieldRules.request(parts: .cover, overwriteByDefault: forceRescrape || !settings.onlyFillMissingFields)
            let overwriteCover = coverRule.overwrites.contains(.cover)
            let remoteMetadataSeeds = Self.preferredRemoteMetadataSeeds(in: songs)

            var pendingSongUpdates: [Song] = []
            var pendingSidecarOperations: [(songID: String, title: String, operation: @Sendable () async -> Void)] = []
            // 失效的本机引用不和这一批的行一起写（那一行可能带着用户编辑标记），发布之后另外摘。
            var pendingStaleClears: [StaleAssetReference] = []
            let sidecarCircuitBreaker = self.sidecarCircuitBreaker
            var lastCompletedSongID: String?
            var completedSongCountInBatch = 0
            var lastSongPublicationAt = ProcessInfo.processInfo.systemUptime

            // The checkpoint is committed only after every library mutation up
            // to that song has been published. Cancellation therefore replays
            // at most this small idempotent batch instead of skipping metadata
            // which existed only in a task-local buffer.
            @MainActor func publishPendingSongBatch() {
                guard let completedSongID = lastCompletedSongID else { return }
                if !pendingSongUpdates.isEmpty {
                    library.replaceSongs(Self.rebasedOntoLatestUserEdits(pendingSongUpdates, in: library))
                }
                if !pendingStaleClears.isEmpty {
                    let entries = pendingStaleClears
                    Task { @MainActor [weak self] in
                        await self?.clearStaleAssetReferences(entries, in: library)
                    }
                }
                for pending in pendingSidecarOperations {
                    if startSidecarWriteTask(pending.operation) != nil {
                        inFlightWritebacks[Self.inFlightKey(runID: runID, songID: pending.songID)] = InFlightWriteback(
                            runID: runID, songID: pending.songID, title: pending.title,
                            startedAt: ProcessInfo.processInfo.systemUptime
                        )
                    } else {
                        // 正在离开前台，写回没能开始：记成被打断，不悄悄丢掉。
                        recordBatchWriteback(.failed(.interrupted), detail: nil,
                                             songID: pending.songID, title: pending.title, runID: runID)
                    }
                }
                pendingSongUpdates.removeAll(keepingCapacity: true)
                pendingSidecarOperations.removeAll(keepingCapacity: true)
                pendingStaleClears.removeAll(keepingCapacity: true)
                lastCompletedSongID = nil
                completedSongCountInBatch = 0
                lastSongPublicationAt = ProcessInfo.processInfo.systemUptime
                advanceScrapeCheckpoint(afterCompleting: completedSongID)
            }

            // Phase 1: Scrape song metadata + write sidecar files
            for song in pendingSongs {
                guard !Task.isCancelled else { return }
                await waitForSidecarBacklog()
                guard !Task.isCancelled else { return }
                var completedCurrentSong = false
                defer {
                    // A lifecycle cancellation means this song may only be
                    // partially written. Leave the checkpoint at the beginning
                    // of its unpublished batch so resume repeats idempotent work
                    // instead of silently skipping task-local mutations.
                    if completedCurrentSong, !Task.isCancelled {
                        if pendingSongUpdates.isEmpty, pendingSidecarOperations.isEmpty, pendingStaleClears.isEmpty {
                            advanceScrapeCheckpoint(afterCompleting: song.id)
                        } else {
                            lastCompletedSongID = song.id
                            completedSongCountInBatch += 1
                            if pendingSongUpdates.count >= Self.songPublicationBatchSize
                                || completedSongCountInBatch >= Self.songPublicationBatchSize
                                || ProcessInfo.processInfo.systemUptime - lastSongPublicationAt
                                    >= Self.songPublicationInterval {
                                publishPendingSongBatch()
                            }
                        }
                    }
                }

                currentSongTitle = song.title

                do {
                    let remoteIdentitySeed = Self.batchRemoteIdentity(for: song)
                        .flatMap { remoteMetadataSeeds[$0] }
                    let (result, scope) = try await processedSongForBatchScoped(
                        song,
                        forceRescrape: forceRescrape,
                        remoteIdentitySeed: remoteIdentitySeed,
                        parts: parts, settings: settings
                    )
                    guard !Task.isCancelled else { return }

                    processedCount += 1
                    // 只补歌词 / 只补封面:其余部分刮到了也换回原值。封面、歌词只有存进本机缓存并核对过
                    // 才指过去；存不下的不改引用、记成保存失败。只有技术参数变了的照常保存，但不算更新。
                    // 同单曲刮削:文件型源刮到的值要记用户编辑,否则回填读标签会换回(#173)。
                    // 重新刮削是用户明确要换掉：刮到的歌词算用户选的版本，清空过的也照写；只补缺失的不钉住、不解除清空。
                    let isServerLibrary = await sourceManager.isServerLibrarySource(for: song)
                    let applied = await applyScrapedResult(
                        result, scope: scope, to: song, parts: parts,
                        coverOrigin: overwriteCover ? .selected : .scraped,
                        stampsUserEdit: !isServerLibrary,
                        lyricsOrigin: forceRescrape ? .user : .automatic
                    )
                    guard !Task.isCancelled else { return }
                    recordBatchSongOutcome(applied, for: song)

                    if applied.persists {
                        pendingSongUpdates.append(applied.song)
                    }
                    if let stale = applied.staleReferences {
                        pendingStaleClears.append(stale)
                    }
                    guard applied.storedCover != nil || applied.cachedLyrics != nil
                            || applied.parts.tags == .filled else {
                        completedCurrentSong = true
                        continue
                    }

                    let serverWriteback = await writeBackToMediaServerIfSupported(
                        original: song,
                        updated: applied.song,
                        coverData: applied.storedCover,
                        lyricsLines: applied.cachedLyrics
                    )
                    guard !Task.isCancelled else { return }

                    if let job = await scrapedAssetWritebackJob(for: applied.song, applied: applied,
                                                                embedsLyrics: runEmbedsLyrics) {
                        let sourceManager = self.sourceManager
                        let songID = song.id
                        let title = song.title
                        // Start sidecar work only after the matching
                        // library batch is visible. Otherwise a fast
                        // local sidecar write could publish its path and
                        // then be overwritten by the delayed song batch.
                        pendingSidecarOperations.append((songID: songID, title: title, operation: { [weak self] in
                            let result = await MusicScraperService.performScrapedAssetWriteback(
                                job, sourceManager: sourceManager, library: library,
                                circuitBreaker: sidecarCircuitBreaker
                            )
                            await self?.finishBatchWriteback(
                                serverWriteback.outcome.combined(with: result.outcome),
                                detail: serverWriteback.detail ?? result.failureDetail,
                                songID: songID, title: title, runID: runID
                            )
                        }))
                    } else {
                        recordBatchWriteback(
                            serverWriteback.outcome, detail: serverWriteback.detail,
                            songID: song.id, title: song.title, runID: runID
                        )
                    }
                } catch is BatchScrapeSourceUnavailable {
                    publishPendingSongBatch()
                    moveDeferredSongToEndOfCheckpoint(song.id)
                    deferredForSourceFailure = true
                    plog("Batch scrape deferred: sources unavailable at \(min(processedCount, songTotalCount))/\(songTotalCount); '\(song.title)' moved to the end, remaining checkpoint preserved")
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    processedCount += 1
                    failedCount += 1
                    tally.recordSongError(songID: song.id, title: song.title, detail: error.localizedDescription)
                    plog("MusicScraperService: batch scrape failed for '\(song.title)': \(error.localizedDescription)")
                }
                completedCurrentSong = true
            }

            // Publish a short tail before derived album/artist work and before
            // declaring the scrape complete.
            publishPendingSongBatch()
            finishScrapeSongPhaseCheckpoint()

            // Phase 2: Scrape album and artist covers
            guard !Task.isCancelled else { return }
            // 只补歌词的一轮不碰专辑 / 艺人封面。
            if parts.contains(.cover), coverRule.fields.contains(.cover) {
                await scrapeAlbumAndArtistArtworkPhase(
                    songs: songs, library: library, overwriteCover: overwriteCover,
                    resumedTargetIDs: resumeCheckpoint?.artworkTargetIDs
                )
            }

            // 这一轮自己发起的写回音乐源（嵌入、旁路文件）做完才算完成，结果要算进完成提示。
            guard !Task.isCancelled else { return }
            await awaitRunWritebacks(runContext, timeout: Self.sidecarSettings().timeout)
        }
        return .started(runID: runID, songCount: logicalSongCount)
    }

    /// 第二阶段：补专辑封面和艺人图。从批量刮削的任务里拆出来，阶段之后还要等这一轮的写回。
    private func scrapeAlbumAndArtistArtworkPhase(
        songs: [Song],
        library: MusicLibrary,
        overwriteCover: Bool,
        resumedTargetIDs: [String]?
    ) async {
        let assetStore = MetadataAssetStore.shared
        let isWholeVisibleLibrary = Set(songs.map(\.id)) == Set(library.visibleSongs.map(\.id))
        let targetAlbumIDs = Set(songs.compactMap(\.albumID))
        let targetArtistIDs = Set(songs.compactMap(\.artistID))
        let targetArtistNames = Set(
            songs.compactMap(\.artistName)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let albumsInScope = library.visibleAlbums.filter { album in
            isWholeVisibleLibrary || targetAlbumIDs.contains(album.id)
        }
        let artistsInScope = library.visibleArtists.filter { artist in
            let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (isWholeVisibleLibrary || targetArtistIDs.contains(artist.id) || targetArtistNames.contains(name))
        }

        let targetIDs: [String]
        if let resumedTargetIDs {
            targetIDs = resumedTargetIDs
        } else {
            let albumIDs = albumsInScope.compactMap { album -> String? in
                guard overwriteCover || !Self.albumHasArtwork(album.id, in: library) else { return nil }
                return Self.albumArtworkTargetID(album.id)
            }
            let artistIDs = artistsInScope.compactMap { artist -> String? in
                guard overwriteCover || !assetStore.hasArtistImage(forArtistID: artist.id) else { return nil }
                return Self.artistArtworkTargetID(artist.id)
            }
            targetIDs = albumIDs + artistIDs
        }

        let targetIDSet = Set(targetIDs)
        var availableIDs = Set<String>()
        if !overwriteCover {
            for targetID in targetIDs {
                if Self.isArtworkAvailable(targetID: targetID, in: assetStore, library: library) {
                    availableIDs.insert(targetID)
                }
            }
        }

        let albumsNeedingCover = albumsInScope.filter { album in
            let targetID = Self.albumArtworkTargetID(album.id)
            return targetIDSet.contains(targetID)
                && (overwriteCover || !availableIDs.contains(targetID))
        }
        let artistsNeedingImage = artistsInScope.filter { artist in
            let targetID = Self.artistArtworkTargetID(artist.id)
            return targetIDSet.contains(targetID)
                && (overwriteCover || !availableIDs.contains(targetID))
        }
        let pendingTargetIDs = Set(
            albumsNeedingCover.map { Self.albumArtworkTargetID($0.id) }
                + artistsNeedingImage.map { Self.artistArtworkTargetID($0.id) }
        )
        artworkTargetIDs = targetIDs
        artworkTotalCount = targetIDs.count
        artworkAvailableCount = availableIDs.count
        artworkUnavailableCount = targetIDSet.subtracting(availableIDs.union(pendingTargetIDs)).count
        artworkProcessedCount = artworkAvailableCount + artworkUnavailableCount
        if artworkTotalCount > 0 {
            batchPhase = .artwork
            totalCount += artworkTotalCount
            processedCount += artworkProcessedCount
            updateArtworkCheckpoint(forceWrite: true)
        }

        await scrapeAlbumAndArtistCovers(
            in: library,
            albumsNeedingCover: albumsNeedingCover,
            artistsNeedingImage: artistsNeedingImage,
            forceRescrape: overwriteCover
        )
    }

    private func persistScrapeCheckpoint(
        songIDs: [String],
        forceRescrape: Bool,
        runID: UUID,
        originPlaylistID: String?,
        parts: ScrapeParts,
        embedsLyrics: Bool
    ) {
        let checkpoint = ScrapeCheckpoint(
            songIDs: songIDs,
            forceRescrape: forceRescrape,
            nextSongIndex: 0,
            updatedCount: 0,
            skippedCount: 0,
            failedCount: 0,
            artworkTargetIDs: nil,
            runID: runID,
            originPlaylistID: originPlaylistID,
            parts: parts == .all ? nil : parts,
            tally: BatchScrapeTally(),
            tallyIsPartial: false,
            embedsLyrics: embedsLyrics
        )
        scrapeCheckpoint = checkpoint
        writeScrapeCheckpoint(checkpoint)
    }

    private func writeScrapeCheckpoint(_ checkpoint: ScrapeCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: scrapeCheckpointURL, options: .atomic)
    }

    private func advanceScrapeCheckpoint(afterCompleting songID: String) {
        // Songs complete in checkpoint order: look from the resume point first
        // instead of scanning the whole (possibly whole-library) list per song.
        guard var checkpoint = scrapeCheckpoint else { return }
        let resumePoint = min(checkpoint.nextSongIndex, checkpoint.songIDs.count)
        guard let completedIndex = checkpoint.songIDs[resumePoint...].firstIndex(of: songID)
                ?? checkpoint.songIDs[..<resumePoint].firstIndex(of: songID) else { return }

        checkpoint.nextSongIndex = min(completedIndex + 1, checkpoint.songIDs.count)
        checkpoint.updatedCount = updatedCount
        checkpoint.skippedCount = skippedCount
        checkpoint.failedCount = failedCount
        checkpoint.tally = tally
        scrapeCheckpoint = checkpoint

        // Network scraping is much slower than this write, but avoid rewriting
        // a potentially large ID list after every track. Expiration handling
        // flushes the latest in-memory index before cancelling.
        if completedIndex.isMultiple(of: 10) || completedIndex == checkpoint.songIDs.count - 1 {
            writeScrapeCheckpoint(checkpoint)
        }
    }

    /// 整批因源不可用挂起时,把卡住的这首挪到剩余队列最后:续跑先刮别的歌,
    /// 只因为这一首的问题时不会让后面的歌一直轮不到。它不算失败,轮到时照常再刮。
    private func moveDeferredSongToEndOfCheckpoint(_ songID: String) {
        guard var checkpoint = scrapeCheckpoint else { return }
        let reordered = Self.songIDsMovingDeferredSongToEnd(
            songID, in: checkpoint.songIDs, resumeIndex: checkpoint.nextSongIndex
        )
        guard reordered != checkpoint.songIDs else { return }
        checkpoint.songIDs = reordered
        scrapeCheckpoint = checkpoint
        writeScrapeCheckpoint(checkpoint)
    }

    nonisolated static func songIDsMovingDeferredSongToEnd(
        _ songID: String, in songIDs: [String], resumeIndex: Int
    ) -> [String] {
        let resumePoint = min(max(resumeIndex, 0), songIDs.count)
        guard let index = songIDs[resumePoint...].firstIndex(of: songID),
              index < songIDs.count - 1 else { return songIDs }
        var reordered = songIDs
        reordered.remove(at: index)
        reordered.append(songID)
        return reordered
    }

    /// Commits the completed song phase even when a resumed target no longer
    /// has a pending local row. A checkpoint at songIDs.count intentionally
    /// resumes directly into derived artwork work without replaying a sentinel
    /// song and double-counting its outcome.
    private func finishScrapeSongPhaseCheckpoint() {
        guard var checkpoint = scrapeCheckpoint else { return }
        checkpoint.nextSongIndex = checkpoint.songIDs.count
        checkpoint.updatedCount = updatedCount
        checkpoint.skippedCount = skippedCount
        checkpoint.failedCount = failedCount
        checkpoint.tally = tally
        scrapeCheckpoint = checkpoint
        writeScrapeCheckpoint(checkpoint)
    }

    private func updateArtworkCheckpoint(forceWrite: Bool = false) {
        guard var checkpoint = scrapeCheckpoint else { return }
        checkpoint.artworkTargetIDs = artworkTargetIDs
        checkpoint.tally = tally
        scrapeCheckpoint = checkpoint

        // The checkpoint includes the complete song-ID list, which can be large.
        // Keep in-memory results exact for lifecycle cancellation, and only flush
        // periodically during normal artwork work to avoid avoidable disk churn.
        if forceWrite
            || artworkProcessedCount.isMultiple(of: 10)
            || artworkProcessedCount == artworkTotalCount {
            writeScrapeCheckpoint(checkpoint)
        }
    }

    private func clearScrapeCheckpoint() {
        scrapeCheckpoint = nil
        try? FileManager.default.removeItem(at: scrapeCheckpointURL)
    }

    /// Tracks every unstructured sidecar write so lifecycle cancellation can
    /// stop the network/file work as well as the parent scraping loop. Detached
    /// tasks that were not retained previously survived `scrapingTask.cancel()`.
    @discardableResult
    private func startSidecarWriteTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !isPausedForSceneTransition else { return nil }

        let id = UUID()
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            await operation()
        }
        sidecarWriteTasks[id] = task

        Task { @MainActor [weak self] in
            await task.value
            self?.sidecarWriteTasks[id] = nil
        }
        return task
    }

    /// Waits for queued sidecar writes until the backlog is under its bound.
    /// Each awaited entry is dropped here: its own removal is a later main-actor
    /// job that would otherwise leave this loop awaiting the same finished task.
    private func waitForSidecarBacklog() async {
        while Self.sidecarBacklogIsFull(queuedWrites: sidecarWriteTasks.count), !Task.isCancelled,
              let oldest = sidecarWriteTasks.first {
            await oldest.value.value
            sidecarWriteTasks[oldest.key] = nil
        }
    }

    private func cancelSidecarWriteTasks() {
        let tasks = sidecarWriteTasks.values
        sidecarWriteTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }
        markInFlightWritebacksInterrupted()
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        // Foreground batches can legitimately run for minutes. Holding a
        // UIApplication background assertion for their whole lifetime makes
        // UIKit report a >30-second background-task fault even though the app
        // never left the foreground. The lifecycle handler stops/restarts the
        // scrape at an atomic checkpoint when the scene actually backgrounds,
        // so acquire the finite assertion only during that background window.
        guard UIApplication.shared.applicationState != .active else { return }
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "primuse.metadata-scrape") { [weak self] in
            // Runs on the main thread; end the assertion synchronously so the
            // checkpoint is preserved inside the expiration grace period.
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isScraping {
                    plog("MusicScraperService: background time expired with no batch scrape running")
                }
                self.cancelPreservingCheckpoint(reason: .backgroundTimeExpired)
            }
        }
        #endif
    }

    private func endBackgroundTaskIfHeld() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        #endif
    }

    /// Builds the user-visible "scrape finished" notification body and posts it.
    /// Split out so both manual scrape (B1) and full-library rescrape (B2) share
    /// the same wording / dedup behaviour.
    private static func postScrapeCompletionNotification(
        forceRescrape: Bool,
        completion: BatchScrapeCompletion
    ) async {
        let titleKey = forceRescrape
            ? "notify_rescrape_done_title"
            : "notify_scrape_missing_done_title"
        let title = String(localized: String.LocalizationValue(titleKey))
        let body = completion.summaryText
        await UserNotificationService.shared.postLongTaskCompletion(
            category: forceRescrape ? .rescrapeLibraryDone : .scrapeMissingDone,
            title: title,
            body: body,
            // Batch scrapes only start from the listener's action (or resume
            // one after an interruption).
            isUserInitiated: true,
            itemCount: completion.songCount
        )
    }

    /// Batch-fetch album covers and artist images for items missing artwork.
    private func scrapeAlbumAndArtistCovers(
        in library: MusicLibrary,
        albumsNeedingCover: [Album],
        artistsNeedingImage: [Artist],
        forceRescrape: Bool
    ) async {
        let artworkService = ArtworkFetchService.shared
        let assetStore = MetadataAssetStore.shared

        // Albums without cached cover
        if !albumsNeedingCover.isEmpty {
            plog("🎨 Scraping covers for \(albumsNeedingCover.count) albums...")
            currentSongTitle = String(localized: "scraping_album_covers")
            for album in albumsNeedingCover {
                guard !Task.isCancelled else { return }
                if !forceRescrape, Self.albumHasArtwork(album.id, in: library) {
                    recordArtworkResult(isAvailable: true)
                    continue
                }
                currentSongTitle = album.title
                _ = await artworkService.fetchAlbumCover(
                    albumTitle: album.title, artistName: album.artistName, albumID: album.id
                )
                guard !Task.isCancelled else { return }
                recordArtworkResult(
                    isAvailable: assetStore.hasAlbumCover(forAlbumID: album.id)
                )
            }
        }

        // Artists without cached image
        if !artistsNeedingImage.isEmpty {
            plog("🎨 Scraping images for \(artistsNeedingImage.count) artists...")
            currentSongTitle = String(localized: "scraping_artist_images")
            for artist in artistsNeedingImage {
                guard !Task.isCancelled else { return }
                // Apple 目录里的歌手照片只在显示时现取、不存盘，批量补全不再去取；这里只记音乐源给的头像在不在。
                currentSongTitle = artist.name
                recordArtworkResult(
                    isAvailable: assetStore.hasArtistImage(forArtistID: artist.id)
                )
            }
        }
    }

    private static func albumArtworkTargetID(_ albumID: String) -> String {
        "album:\(albumID)"
    }

    private static func artistArtworkTargetID(_ artistID: String) -> String {
        "artist:\(artistID)"
    }

    private static func isArtworkAvailable(
        targetID: String,
        in assetStore: MetadataAssetStore,
        library: MusicLibrary
    ) -> Bool {
        if targetID.hasPrefix("album:") {
            return albumHasArtwork(String(targetID.dropFirst(6)), in: library)
        }
        if targetID.hasPrefix("artist:") {
            return assetStore.hasArtistImage(forArtistID: String(targetID.dropFirst(7)))
        }
        return false
    }

    static func albumHasArtwork(_ albumID: String, in library: MusicLibrary) -> Bool {
        if library.preferredArtworkSong(forAlbumID: albumID)?.coverArtFileName?.isEmpty == false {
            return true
        }
        let presentation = library.artworkPresentation(for: LibraryArtworkOwner(kind: .album, id: albumID))
        return presentation.uploadedContentID != nil
            || presentation.selectedSong?.coverArtFileName?.isEmpty == false
            || MetadataAssetStore.shared.hasAlbumCover(forAlbumID: albumID)
    }

    private func recordArtworkResult(isAvailable: Bool) {
        processedCount += 1
        artworkProcessedCount += 1
        if isAvailable {
            artworkAvailableCount += 1
        } else {
            artworkUnavailableCount += 1
        }
        updateArtworkCheckpoint()
    }

    struct ProcessedResult {
        var review = ScrapeReviewCatalog()
        let song: Song
        let coverData: Data?
        let lyricsLines: [LyricLine]?
        var unavailableParts: ScrapeParts = []
        var retryAfter: TimeInterval = 5
        /// 封面是从这个文件里内嵌的图或旁边的封面图读出来的（不是在线刮到的）。
        var coverReadFromFile = false
    }

    struct BatchScrapeSourceUnavailable: Error { }

    func processedSongForBatch(
        _ song: Song, forceRescrape: Bool, remoteIdentitySeed: Song? = nil, parts: ScrapeParts = .all,
        settings: ScraperSettings = .load(), sleep: ((TimeInterval) async throws -> Void)? = nil
    ) async throws -> ProcessedResult? {
        try await processedSongForBatchScoped(song, forceRescrape: forceRescrape, remoteIdentitySeed: remoteIdentitySeed,
                                              parts: parts, settings: settings, sleep: sleep).result
    }

    /// 同 `processedSongForBatch`，另外交回这一首的刮削范围：哪些字段在范围里、哪些真的去刮了、
    /// 封面和歌词引用核对下来还在不在。批量刮削按它分部分结算，结果为 nil 时也要知道。
    func processedSongForBatchScoped(
        _ song: Song, forceRescrape: Bool, remoteIdentitySeed: Song? = nil, parts: ScrapeParts = .all,
        settings: ScraperSettings = .load(), sleep: ((TimeInterval) async throws -> Void)? = nil
    ) async throws -> (result: ProcessedResult?, scope: ScrapeScope) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var scope = ScrapeScope()
            let result = try await processedSongWithAssets(song, forceRescrape: forceRescrape,
                                                          storeAssets: false, remoteIdentitySeed: remoteIdentitySeed,
                                                          parts: parts, settings: settings,
                                                          inspectsStaleReferences: true, scope: &scope)
            guard let result, !result.unavailableParts.intersection(parts).isEmpty else { return (result, scope) }
            guard attempt < 2 else { throw BatchScrapeSourceUnavailable() }
            if let sleep { try await sleep(max(1, result.retryAfter)) }
            else { try await scrapeRetrySleep(max(1, result.retryAfter)) }
        }
        throw BatchScrapeSourceUnavailable()
    }

    /// Conservative per-run identity for byte-identical-looking copies. A
    /// basename alone is not enough (different albums often contain the same
    /// track name), while source + basename + exact byte size + format gives
    /// us a useful duplicate hint without reading or hashing the whole remote
    /// file. The key is used only to choose a search seed; song IDs, paths and
    /// asset references always remain independent.
    private struct BatchRemoteIdentity: Hashable {
        let sourceID: String
        let fileName: String
        let fileSize: Int64
        let fileFormat: AudioFormat
    }

    private nonisolated static func batchRemoteIdentity(for song: Song) -> BatchRemoteIdentity? {
        let fileName = (song.filePath as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard song.fileSize > 0, !fileName.isEmpty else { return nil }
        return BatchRemoteIdentity(
            sourceID: song.sourceID,
            fileName: fileName,
            fileSize: song.fileSize,
            fileFormat: song.fileFormat
        )
    }

    private nonisolated static func metadataSeedScore(_ song: Song) -> Int {
        var score = 0
        if song.duration > 0 { score += 32 }
        if song.artistName?.isEmpty == false { score += 16 }
        if song.albumTitle?.isEmpty == false { score += 8 }
        if song.year != nil { score += 4 }
        if song.genre?.isEmpty == false { score += 4 }
        if song.sampleRate != nil { score += 2 }
        if song.bitRate != nil { score += 2 }
        if song.bitDepth != nil { score += 1 }
        return score
    }

    /// Seeds only for identities shared by two or more songs of the batch. A
    /// song alone under its identity would seed itself, which is exactly what
    /// a missing seed means (`remoteIdentitySeed ?? song`), so leaving it out
    /// changes nothing — while keeping it held a `[identity: Song]` entry and a
    /// folded file name for every song of a whole-library run (~180 MB at 450K
    /// songs) until the run ended. Candidates are found by hash first, so the
    /// pre-pass holds 16 bytes per song instead of a full identity.
    private nonisolated static func preferredRemoteMetadataSeeds(
        in songs: [Song]
    ) -> [BatchRemoteIdentity: Song] {
        var hashCounts: [Int: UInt8] = [:]
        hashCounts.reserveCapacity(songs.count)
        for song in songs {
            guard let identity = batchRemoteIdentity(for: song) else { continue }
            let hash = identity.hashValue
            if hashCounts[hash, default: 0] < 2 { hashCounts[hash, default: 0] += 1 }
        }
        var seeds: [BatchRemoteIdentity: Song] = [:]
        var members: [BatchRemoteIdentity: Int] = [:]
        for song in songs {
            guard let identity = batchRemoteIdentity(for: song),
                  hashCounts[identity.hashValue, default: 0] >= 2 else { continue }
            members[identity, default: 0] += 1
            if let existing = seeds[identity],
               metadataSeedScore(existing) >= metadataSeedScore(song) {
                continue
            }
            seeds[identity] = song
        }
        // A hash collision between two different identities is not a copy.
        for (identity, count) in members where count < 2 { seeds[identity] = nil }
        return seeds
    }

    /// Song ID → ID of the song whose metadata seeds it (tests).
    nonisolated static func remoteMetadataSeedIDsForTesting(_ songs: [Song]) -> [String: String] {
        let seeds = preferredRemoteMetadataSeeds(in: songs)
        var result: [String: String] = [:]
        for song in songs {
            if let identity = batchRemoteIdentity(for: song), let seed = seeds[identity] {
                result[song.id] = seed.id
            }
        }
        return result
    }

    func processedSongWithAssets(
        _ song: Song,
        forceRescrape: Bool,
        storeAssets: Bool = true,
        remoteIdentitySeed: Song? = nil,
        parts: ScrapeParts = .all,
        settings: ScraperSettings = .load(),
        collectingReview: Bool = false
    ) async throws -> ProcessedResult? {
        var scope = ScrapeScope()
        return try await processedSongWithAssets(song, forceRescrape: forceRescrape, storeAssets: storeAssets,
                                                 remoteIdentitySeed: remoteIdentitySeed, parts: parts, settings: settings,
                                                 collectingReview: collectingReview, scope: &scope)
    }

    /// 这首歌这一轮的刮削范围。`considered`：在范围里的字段（选了这部分、字段规则不是跳过）；
    /// `fetched`：按歌曲已有的内容收窄后真的去刮的字段；`assets`：封面、歌词引用核对下来的状态。
    struct ScrapeScope: Sendable {
        var considered: Set<ScrapeField> = []
        var fetched: Set<ScrapeField> = []
        /// 真的去刮的字段里要覆盖已有内容的那些（其余是只补缺失）。
        var overwrites: Set<ScrapeField> = []
        var assets = ScrapeAssetPresence(cover: .absent, lyrics: .absent)
    }

    /// - Parameter inspectsStaleReferences: 用户发起的刮削传 true：引用还在、本机文件已经没了的
    ///   封面、歌词当缺失去刮。后台补全只补空着的，照旧当成有。
    func processedSongWithAssets(
        _ song: Song,
        forceRescrape: Bool,
        storeAssets: Bool = true,
        remoteIdentitySeed: Song? = nil,
        parts: ScrapeParts = .all,
        settings: ScraperSettings = .load(),
        collectingReview: Bool = false,
        inspectsStaleReferences: Bool = false,
        scope: inout ScrapeScope
    ) async throws -> ProcessedResult? {
        // 服务端曲库源(Subsonic/Navidrome、Jellyfin/Emby/Plex): 元数据以服务端为
        // 权威, 自动刮削只「补空缺、绝不覆盖」。不读(可能转码的)音频流 —— 用歌曲
        // 已有 title/artist/album 直接查在线源, 只填 nil/空 的 artist/album/year/
        // genre。封面(getCoverArt)/歌词(getLyricsBySongId)由服务端提供, 不让在线
        // 刮削用脏标题错配盖掉, 因此不补 cover/lyrics。即使是「重新刮削」(forceRescrape)
        // 也只补空缺, 不覆盖已有值。
        let server = await sourceManager.isServerLibrarySource(for: song)
        if server && !collectingReview {
            var request = settings.request(for: song, parts: parts.intersection(.metadata), fillOnly: true,
                                           assets: .referencesOnly(cover: song.coverArtFileName, lyrics: song.lyricsFileName))
            request.fields.remove(.title)
            scope.considered = settings.consideredFields(parts: parts.intersection(.metadata), fillOnly: true)
                .subtracting([.title])
            scope.fetched = request.fields
            scope.overwrites = request.overwrites
            guard !request.fields.isEmpty else { return nil }
            let metadata = await metadataService.fillMissingOnline(seed: song, title: song.title,
                                                                  request: request, settings: settings)
            var merged = song
            merged.applyScrapeFields(request.merging(song.scrapeFields, candidate: .init(metadata.scrapeFields)))
            guard merged != song || !metadata.unavailableScrapeParts.isEmpty else { return nil }
            return ProcessedResult(song: merged, coverData: nil, lyricsLines: nil,
                                   unavailableParts: metadata.unavailableScrapeParts, retryAfter: metadata.scrapeRetryAfter)
        }

        let fallbackTitle = await resolvedScrapeFallbackTitle(for: song)
        let filenameTitle = song.title == Self.pathBaseName(for: song) && song.userMetadataEditedAt == nil
        // 核对封面、歌词引用要读本机文件，放到后台；整库刮削时每首只多一次本机文件判断。
        let inspected: ScrapeAssetPresence
        if collectingReview {
            inspected = .referencesOnly(cover: song.coverArtFileName, lyrics: song.lyricsFileName)
        } else {
            inspected = await Task.detached(priority: .utility) { ScraperSettings.assetPresence(for: song) }.value
        }
        let assets = inspectsStaleReferences ? inspected : inspected.treatingStaleAsPresent
        let request = collectingReview ? settings.reviewFields(for: song, parts: parts)
            : settings.request(for: song, parts: parts, force: forceRescrape,
                               titleIsPlaceholder: filenameTitle && settings.fieldRules[.title].mode == .inherit,
                               assets: assets)
        scope.considered = settings.consideredFields(parts: parts, force: forceRescrape)
        scope.fetched = request.fields
        scope.overwrites = request.overwrites
        scope.assets = assets
        if assets.cover == .staleLocal || assets.lyrics == .staleLocal || assets.lyrics == .staleSource {
            plog("MusicScraperService: stale asset reference treated as missing song=\(song.id.prefix(12)) cover=\(assets.cover.rawValue) lyrics=\(assets.lyrics.rawValue)")
        }
        guard !request.fields.isEmpty else { return nil }
        let sourceSupportsRangeStreaming = await sourceManager.songSupportsRangeStreaming(song)
        let shouldResolvePlaybackURL = ScrapeAudioMaterializationPolicy.shouldResolvePlaybackURL(
            sourceSupportsRangeStreaming: sourceSupportsRangeStreaming,
            formatRequiresCompleteLocalFile: FileFormatRouter.requiresCompleteLocalFile(song.fileFormat)
        )
        // For a Range-capable remote source, resolving a DTS/DSD/FFmpeg-only
        // playback URL falls through to connector.localURL and downloads the
        // complete file. Background enrichment used to do that for every song
        // in a freshly scanned SMB library (several GiB for a 99-song folder)
        // even though scraping only needs the scanned/backfilled identity.
        // MusicKit identities are not file paths. Scrape their known catalogue
        // fields directly and keep the result in Primuse's metadata store.
        let fileURL = !server && song.sourceID != AppleMusicLibraryIdentity.sourceID && shouldResolvePlaybackURL
            ? try await sourceManager.resolveURL(for: song)
            : nil
        // trustedSource: false —— scrape 路径下 online 结果可能错配,
        // 不让 loadMetadata 直接写 hash cache。等 sidecar 写到 source
        // 成功后再回写 cache（在 scrapeSingle / startScraping 的 Task 里做）。
        // fallbackTitle 决定在线刮削 query。NAS / 本地源的 filePath 是真实路径,
        // 适合取 basename; OneDrive / Google Drive / Aliyun 等云盘的 filePath
        // 是 opaque item id, 必须回退到 scan 阶段保存的 song.title(真实文件名),
        // 否则会拿 uuid/id 搜歌词和封面导致错配。
        let metadata: MetadataService.SongMetadata
        if let fileURL, fileURL.isFileURL {
            metadata = await metadataService.loadMetadata(
                for: fileURL,
                cacheKey: storeAssets ? song.id : nil,
                trustedSource: false,
                fallbackTitle: fallbackTitle,
                forceOnlineRefresh: forceRescrape,
                // 失效的引用不算「已有封面」，不然在线封面会被它挡掉。
                existingCoverReference: assets.cover == .present ? song.coverArtFileName : nil,
                scrapeRequest: request, scraperSettings: settings, librarySong: song, collectingReview: collectingReview
            )
        } else {
            // Range/HTTP-backed sources resolve to a streaming URL, not a
            // readable local audio file. Feeding primuse-stream:// (or a
            // remote HTTP URL) into FileMetadataReader returns empty tags and
            // made batch scraping fall back to a weak first search result.
            // Keep the scanned/backfilled library metadata as the search seed
            // instead. Background enrichment remains fill-only; an explicit
            // rescrape may apply the confidence-checked online title/artist/
            // album and assets. This also keeps identical NAS copies
            // deterministic without downloading the complete audio file.
            let identitySeed = remoteIdentitySeed ?? song
            let correctedTitle = identitySeed.isCueTrack ? nil
                : MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
                    title: identitySeed.title, artist: identitySeed.artistName, fileStem: fallbackTitle
                )
            let searchTitle = identitySeed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata = await metadataService.fillMissingOnline(
                seed: identitySeed, title: correctedTitle ?? (searchTitle.isEmpty ? fallbackTitle : searchTitle),
                request: request, settings: settings, collectingReview: collectingReview
            )
        }
        var applied = request
        if fileURL?.isFileURL == true, metadata.embeddedTitle == nil, !metadata.hasMatchedTitle,
           !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applied.fields.remove(.title)
        }
        let merged = mergedSong(song, with: metadata, request: applied)
        let coverData = request.fields.contains(.cover) ? metadata.coverArtData : nil
        return ProcessedResult(
            review: metadata.review, song: merged, coverData: coverData,
            lyricsLines: request.fields.contains(.lyrics) ? metadata.lyrics : nil,
            unavailableParts: metadata.unavailableScrapeParts, retryAfter: metadata.scrapeRetryAfter,
            coverReadFromFile: coverData != nil && metadata.artworkOrigin != .scraped
        )
    }

    private func runBackgroundEnrichment(in library: MusicLibrary) async {
        isBackgroundEnriching = true

        var pendingSongUpdates: [Song] = []
        var replacingArtworkReferences: [String: String] = [:]
        @MainActor func publishPendingSongUpdates() {
            guard !pendingSongUpdates.isEmpty else { return }
            library.replaceSongs(Self.rebasedOntoLatestUserEdits(
                pendingSongUpdates, in: library, preservingExistingArtwork: true,
                replacingArtworkReferences: replacingArtworkReferences
            ))
            pendingSongUpdates.removeAll(keepingCapacity: true)
            replacingArtworkReferences.removeAll(keepingCapacity: true)
        }

        defer {
            if Task.isCancelled {
                // Scene-transition cancellation intentionally does not publish
                // a partial full-library batch. Put those ids back so the
                // resumed worker repeats the idempotent enrichment instead of
                // dropping results which were only task-local.
                for songID in pendingSongUpdates.map(\.id).reversed()
                    where pendingEnrichmentSongIDSet.insert(songID).inserted {
                    if pendingEnrichmentHead > 0 {
                        pendingEnrichmentHead -= 1
                        pendingEnrichmentSongIDs[pendingEnrichmentHead] = songID
                    } else {
                        pendingEnrichmentSongIDs.insert(songID, at: 0)
                    }
                }
            }
            backgroundEnrichmentTask = nil
            isBackgroundEnriching = false
        }

        await NetworkMonitor.shared.waitForInitialPath()
        var deferredSinceYield = 0
        while !Task.isCancelled {
            if !automaticWorkIsAllowed() {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                continue
            }
            if isScraping {
                // Don't leave completed enrichment results task-local while a
                // user-initiated scrape waits for this worker to yield.
                publishPendingSongUpdates()
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            // 文件里的标签和旁边的歌词/封面文件, 扫描和补读时已经读过, 这里要的是在线源。
            // 网络不通(没网, 或者用户不让这个 App 联网)就停下, 队列原样留着等网络回来:
            // 不停的话每首都发一次注定失败的请求, 不让联网时系统还会一遍遍弹提示。
            guard NetworkMonitor.shared.allowsAutomaticInternetRequests else {
                publishPendingSongUpdates()
                plog("⏸️ Background enrichment paused until the network is back (\(pendingEnrichmentSongIDs.count - pendingEnrichmentHead) songs kept)")
                resumeBackgroundEnrichmentWhenNetworkReturns(in: library)
                return
            }

            guard let song = nextSongForBackgroundEnrichment(in: library) else {
                publishPendingSongUpdates()
                return
            }
            if awaitsTagRead?(song) == true {
                enrichmentAwaitingTagReadIDs.insert(song.id)
                // 刚扫完的网盘源整批都在等标签:逐首放过去不发请求,隔一阵让出主线程。
                deferredSinceYield += 1
                if deferredSinceYield >= 256 {
                    deferredSinceYield = 0
                    await Task.yield()
                }
                continue
            }

            do {
                let settings = ScraperSettings.load()
                guard let result = try await processedSongWithAssets(song, forceRescrape: false, settings: settings) else {
                    continue
                }
                guard !Task.isCancelled else { return }

                if result.song != song || result.coverData != nil || result.lyricsLines?.isEmpty == false {
                    // processedSongWithAssets 用 trustedSource:false, merged song 里的
                    // coverArtFileName/lyricsFileName 只是占位 hash ref, 文件还没落盘。
                    // 必须在 replaceSong 前把 coverData/lyricsLines 真正写进 hash cache,
                    // 否则库里的 ref 会指向不存在的文件, 且数据被丢弃。
                    var enrichedSong = result.song
                    let latest = library.storedSong(id: song.id) ?? song
                    let existingCover = latest.coverArtFileName
                    let replaceCover = settings.fieldRules[.cover].mode == .overwrite && existingCover == song.coverArtFileName
                    var coverCached = false
                    if existingCover?.isEmpty != false || replaceCover, let coverData = result.coverData,
                       let reference = await MetadataAssetStore.shared.storeAttributedCover(coverData, songID: enrichedSong.id, origin: .scraped) {
                        enrichedSong.coverArtFileName = reference
                        coverCached = true
                        if replaceCover { replacingArtworkReferences[song.id] = existingCover }
                        CachedArtworkView.invalidateCache(for: enrichedSong.id)
                    } else {
                        // 没拿到新封面、或者图存不下 —— 别把占位 ref 持久化, 退回原始 ref。
                        enrichedSong.coverArtFileName = existingCover
                    }
                    var lyricsCached = false
                    let replaceLyrics = settings.fieldRules[.lyrics].mode == .overwrite && latest.lyricsFileName == song.lyricsFileName
                    if latest.lyricsFileName?.isEmpty != false || replaceLyrics, let lyricsLines = result.lyricsLines, !lyricsLines.isEmpty {
                        lyricsCached = await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: enrichedSong.id, force: replaceLyrics)
                    }
                    if lyricsCached {
                        enrichedSong.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: enrichedSong.id)
                    } else {
                        enrichedSong.lyricsFileName = latest.lyricsFileName
                    }

                    guard !Task.isCancelled else { return }
                    if enrichedSong != song || coverCached || lyricsCached {
                        pendingSongUpdates.append(enrichedSong)
                        await writeBackToMediaServerIfSupported(
                            original: song,
                            updated: enrichedSong,
                            coverData: coverCached ? result.coverData : nil,
                            lyricsLines: lyricsCached ? result.lyricsLines : nil
                        )
                        guard !Task.isCancelled else { return }
                        if pendingSongUpdates.count >= Self.songPublicationBatchSize {
                            publishPendingSongUpdates()
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                plog("⚠️ Background enrichment skipped for '\(song.title)': \(error.localizedDescription)")
            }

            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 网络回来(或者用户在系统设置里放开了联网)就接着补, 不用等下一次扫描或回到前台。
    private func resumeBackgroundEnrichmentWhenNetworkReturns(in library: MusicLibrary) {
        guard !isWaitingForNetworkToEnrich else { return }
        isWaitingForNetworkToEnrich = true
        withObservationTracking {
            _ = NetworkMonitor.shared.allowsAutomaticInternetRequests
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWaitingForNetworkToEnrich = false
                if NetworkMonitor.shared.allowsAutomaticInternetRequests {
                    self.startBackgroundEnrichmentIfNeeded(in: library)
                } else {
                    self.resumeBackgroundEnrichmentWhenNetworkReturns(in: library)
                }
            }
        }
    }

    private func nextSongForBackgroundEnrichment(in library: MusicLibrary) -> Song? {
        defer {
            // 取空了就清掉; 已取走的攒到一半再整理一次, 摊下来每首常数时间。
            if pendingEnrichmentHead >= pendingEnrichmentSongIDs.count {
                pendingEnrichmentSongIDs.removeAll(keepingCapacity: true)
                pendingEnrichmentHead = 0
            } else if pendingEnrichmentHead > 512,
                      pendingEnrichmentHead * 2 > pendingEnrichmentSongIDs.count {
                pendingEnrichmentSongIDs.removeFirst(pendingEnrichmentHead)
                pendingEnrichmentHead = 0
            }
        }
        while pendingEnrichmentHead < pendingEnrichmentSongIDs.count {
            let songID = pendingEnrichmentSongIDs[pendingEnrichmentHead]
            pendingEnrichmentHead += 1
            pendingEnrichmentSongIDSet.remove(songID)

            if let song = library.visibleSong(id: songID) {
                return song
            }
        }

        return nil
    }

    private nonisolated static func shouldBackgroundEnrich(_ song: Song, settings: ScraperSettings) -> Bool {
        !settings.request(for: song, checkingAssetCache: false).fields.isEmpty
    }

    private func resolvedScrapeFallbackTitle(for song: Song) async -> String {
        if song.sourceID == AppleMusicLibraryIdentity.sourceID { return song.title }
        // 服务端曲库源的歌名由服务端给出, 路径只是按条目 id 合成的传输标识
        // (Emby/Plex 是 `/items/823881.flac`), 拿它的文件名去搜一首也搜不到。
        let serverTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverTitle.isEmpty, await sourceManager.isServerLibrarySource(for: song) {
            return serverTitle
        }
        let local = Self.scrapeFallbackTitle(for: song)
        if !song.isCueTrack, let fileName = sourceFileName(song) {
            let stem = (fileName as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty { return stem }
        }
        guard Self.shouldResolveRemoteDisplayName(for: song, candidate: local) else {
            return local
        }

        guard let remoteName = try? await sourceManager.remoteDisplayName(for: song) else {
            return local
        }
        let remoteBaseName = (remoteName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteBaseName.isEmpty else { return local }

        let pathBaseName = Self.pathBaseName(for: song)
        return remoteBaseName == pathBaseName ? local : remoteBaseName
    }

    nonisolated static func scrapeFallbackTitle(for song: Song) -> String {
        let songTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathLastComponent = Self.pathLastComponent(for: song)
        let pathBaseName = Self.pathBaseName(for: song)

        guard !songTitle.isEmpty else { return pathBaseName }
        guard !pathBaseName.isEmpty else { return songTitle }

        if shouldPreferSongTitleForScrapeFallback(
            song: song,
            pathLastComponent: pathLastComponent,
            pathBaseName: pathBaseName
        ) {
            return songTitle
        }

        return pathBaseName
    }

    private nonisolated static func shouldResolveRemoteDisplayName(for song: Song, candidate: String) -> Bool {
        let pathLastComponent = Self.pathLastComponent(for: song)
        let pathBaseName = Self.pathBaseName(for: song)
        let pathExtension = (pathLastComponent as NSString)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let pathLooksOpaque = pathExtension.isEmpty
            || AudioFormat.from(fileExtension: pathExtension) == nil
            || looksLikeOpaqueSearchText(pathBaseName)
        guard pathLooksOpaque else { return false }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == pathBaseName
            || trimmed == pathLastComponent
            || trimmed == song.id
            || looksLikeOpaqueSearchText(trimmed)
    }

    private nonisolated static func shouldUseOpaqueSidecarIdentity(for song: Song) -> Bool {
        shouldResolveRemoteDisplayName(for: song, candidate: sidecarBaseName(for: song))
    }

    private nonisolated static func pathLastComponent(for song: Song) -> String {
        (song.filePath as NSString).lastPathComponent
    }

    private nonisolated static func pathBaseName(for song: Song) -> String {
        (pathLastComponent(for: song) as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func shouldPreferSongTitleForScrapeFallback(
        song: Song,
        pathLastComponent: String,
        pathBaseName: String
    ) -> Bool {
        let pathExtension = (pathLastComponent as NSString)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let expectedExtension = song.fileFormat.rawValue.lowercased()

        // Subsonic/Navidrome rows deliberately persist a stable transport path
        // (`/songs/{server-id}.{suffix}`), not the upstream filename. The
        // server-provided Song.title is authoritative for search; exposing the
        // transport identifier produces unusable scraper queries.
        let normalizedPath = song.filePath.replacingOccurrences(of: "\\", with: "/")
        if normalizedPath.hasPrefix("/songs/") { return true }

        // Cloud-drive identifiers (OneDrive item IDs, Google Drive IDs,
        // Aliyun file IDs) usually have no audio extension. A real audio
        // file path almost always does, so keep the scanned display title
        // as the query source in this case.
        if pathExtension.isEmpty { return true }

        // If the path has an extension but it is not an audio extension,
        // treat the basename as an identifier-ish token instead of a title.
        if AudioFormat.from(fileExtension: pathExtension) == nil,
           pathExtension != expectedExtension {
            return true
        }

        if looksLikeOpaqueSearchText(pathBaseName) { return true }
        if pathBaseName == song.id { return true }
        return false
    }

    private nonisolated static func looksLikeOpaqueSearchText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }

        let scalars = trimmed.unicodeScalars
        let opaqueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-!{}")
        guard scalars.allSatisfy({ opaqueAllowed.contains($0) }) else { return false }

        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let separators = scalars.filter { $0 == "_" || $0 == "-" || $0 == "!" }.count
        let uppercase = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let lowercase = scalars.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        let looksLikeCompactMixedCaseID = trimmed.count >= 20
            && digits >= 2
            && uppercase >= 2
            && lowercase >= 2
        return digits >= 6
            || separators >= 2
            || trimmed.count >= 24
            || looksLikeCompactMixedCaseID
    }

    private func mergedSong(_ song: Song, with metadata: MetadataService.SongMetadata,
                            request: ScrapeFieldRequest) -> Song {
        var merged = song
        var tags = request.merging(song.scrapeFields, candidate: .init(metadata.scrapeFields))
        if tags.artist != song.artistName { tags.sourceArtistNames = metadata.sourceArtistNames }
        if song.isCueTrack {
            tags = ScrapeCueIdentityPolicy.protectingCueIdentity(tags, original: song.scrapeFields)
        }
        merged.applyScrapeFields(tags)
        if request.fields.contains(.cover) {
            merged.coverArtFileName = metadata.coverArtFileName ?? song.coverArtFileName
        }
        if request.fields.contains(.lyrics) {
            merged.lyricsFileName = metadata.lyricsFileName ?? song.lyricsFileName
        }
        guard !request.fields.isDisjoint(with: ScrapeField.tags) else { return merged }
        // File metadata describes the physical image. It must never replace a
        // CUE virtual track's segment duration with the whole album duration.
        if !song.isCueTrack, metadata.duration > 0 {
            merged.duration = metadata.duration
        }
        // Some container readers express an unknown numeric field as zero
        // instead of nil (notably ALAC bit depth). Never let an online/file
        // scrape erase a valid value obtained from the FFmpeg scan.
        if let bitRate = metadata.bitRate, bitRate > 0 {
            merged.bitRate = bitRate
        }
        if let sampleRate = metadata.sampleRate, sampleRate > 0 {
            merged.sampleRate = sampleRate
        }
        if let bitDepth = metadata.bitDepth, bitDepth > 0 {
            merged.bitDepth = bitDepth
        }
        merged.mvPath = metadata.mvPath ?? song.mvPath
        return merged
    }

    nonisolated static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String? = nil,
        expectedLyricsTarget: SidecarWriteService.LyricsPreflightResult? = nil,
        createsLyricsFile: Bool = true,
        createsCoverFile: Bool = true
    ) async throws -> SidecarWriteService.WriteResult {
        try await withThrowingTaskGroup(of: SidecarWriteService.WriteResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                plog("📝 Sidecar: writing sidecars for '\(song.title)' filePath=\(song.filePath)")
                let writeResult = await SidecarWriteService.shared.writeSidecars(
                    for: song,
                    using: connector,
                    coverData: coverData,
                    lyricsLines: lyricsLines,
                    lyricsContent: lyricsContent,
                    expectedLyricsTarget: expectedLyricsTarget,
                    createsLyricsFile: createsLyricsFile,
                    createsCoverFile: createsCoverFile
                )
                await sourceManager.invalidateReadCachesAfterSidecarWrite(
                    for: song,
                    paths: writeResult.touchedRemotePaths
                )
                if writeResult.coverWritten || writeResult.lyricsWritten {
                    await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                }
                return writeResult
            }
            group.addTask {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    struct EmbeddedCoverOutcome: Sendable {
        /// The song with the replaced file's identity; nil when nothing was written.
        var updatedSong: Song?
        var sourceUnavailable = false
    }

    /// 把刮到的封面写进音频文件。要整首下载、改写、替换、回读，所以不套旁路文件的写入超时
    /// （半途取消可能停在替换阶段），也放进独立任务、不随刮削取消而中断：开始了的这一首总会做完。
    /// 成功后把替换后的文件身份记回资料库，否则下次扫描会把它当成被别处改过的文件，
    /// 下一次写入也会因为身份对不上而被拒绝。
    nonisolated static func embedScrapedCover(
        _ coverData: Data,
        for song: Song,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> EmbeddedCoverOutcome {
        let outcome = await embedScrapedAssets(
            coverData: coverData, lyricsText: nil, for: song,
            sourceManager: sourceManager, library: library
        )
        return EmbeddedCoverOutcome(updatedSong: outcome.updatedSong, sourceUnavailable: outcome.sourceUnavailable)
    }

    nonisolated static func preflightLyricsWriteWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song
    ) async throws -> SidecarWriteService.LyricsPreflightResult {
        try await AsyncOperationTimeout.run(seconds: seconds) {
            let connector = try await sourceManager.sidecarWriteConnector(for: song)
            return try await SidecarWriteService.shared.preflightLyricsWrite(
                for: song,
                using: connector
            )
        }
    }

    nonisolated static func removeLyricsSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        expectedLyricsTarget: SidecarWriteService.LyricsPreflightResult? = nil
    ) async throws -> SidecarWriteService.WriteResult {
        try await withThrowingTaskGroup(of: SidecarWriteService.WriteResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                let result = await SidecarWriteService.shared.removeLyrics(
                    for: song,
                    using: connector,
                    expectedLyricsTarget: expectedLyricsTarget
                )
                await sourceManager.invalidateReadCachesAfterSidecarWrite(
                    for: song,
                    paths: result.touchedRemotePaths
                )
                if result.lyricsRemoved {
                    await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                }
                return result
            }
            group.addTask {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CancellationError()
            }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Whether a lyric file of this name is still beside the song, as the
    /// write connector lists it right now.
    nonisolated static func lyricsDocumentExistsWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        named fileName: String
    ) async throws -> Bool {
        try await AsyncOperationTimeout.run(seconds: seconds) {
            let connector = try await sourceManager.sidecarWriteConnector(for: song)
            do {
                _ = try await SidecarWriteService.shared.lyricsDocumentTarget(
                    named: fileName,
                    for: song,
                    using: connector
                )
                return true
            } catch SidecarWriteService.LyricsDocumentWriteError.documentMissing {
                return false
            }
        }
    }

    /// The raw editor's save of one lyric file, on the write connector like
    /// every other sidecar write. The read connector forgets the paths it
    /// touched even when the readback fails, because the upload may already
    /// have landed.
    nonisolated static func replaceLyricsDocumentWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        named fileName: String,
        data: Data,
        expecting originalData: Data
    ) async throws -> LyricsSidecarTarget {
        try await AsyncOperationTimeout.run(seconds: seconds) {
            let connector = try await sourceManager.sidecarWriteConnector(for: song)
            let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
                named: fileName,
                for: song,
                using: connector
            )
            let touched = [target.targetPath, target.existingPath].compactMap { $0 }
            do {
                let receipt = try await SidecarWriteService.shared.writeLyricsDocument(
                    data,
                    to: target,
                    expecting: originalData,
                    using: connector
                )
                await sourceManager.invalidateReadCachesAfterSidecarWrite(
                    for: song,
                    paths: touched + [receipt.writtenPath]
                )
                await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                return target
            } catch {
                await sourceManager.invalidateReadCachesAfterSidecarWrite(for: song, paths: touched)
                throw error
            }
        }
    }

    private nonisolated static func isSourceUnavailableSidecarError(_ error: Error) -> Bool {
        MetadataWriteFailurePolicy.stopsSourceWrites(error)
    }

    // MARK: - 刮削结果落地与按部分结算

    /// 一首歌刮到的结果落地之后的样子。
    struct AppliedScrape: Sendable {
        /// 要写进资料库的那一行。
        var song: Song
        var parts: ScrapeSongParts
        /// 存进本机缓存并核对过的封面。
        var storedCover: Data?
        /// 存进本机缓存的歌词。
        var cachedLyrics: [LyricLine]?
        /// 这一行和原来不一样（含静默保存的技术参数），或者存了新的封面、歌词。
        var persists: Bool
        /// 引用失效而这一轮又没补上的，交给调用方在这一行写完之后另外摘（`clearStaleAssetReferences`）。
        var staleReferences: StaleAssetReference? = nil
        /// 封面、歌词是从这个文件自己（内嵌或旁边的文件）读出来的就不写回音乐源。
        var writesBackCover = true
        var writesBackLyrics = true
        /// 这一轮是覆盖还是只补缺失：只补缺失时，写进音频文件前文件里已有的不换。
        var overwritesCover = false
        var overwritesLyrics = false
        /// 覆盖歌词、又要写进音频文件时按字段替换用的：缓存换成新歌词之前，文件里正在用的那一份。
        var embeddedLyricsAnchor: LyricsWriteback.EmbeddedAnchor? = nil
        /// 歌词写进缓存时算谁的：用户点名的刮削是 `.user`（钉住、解除清空），只补缺失的是 `.automatic`。
        var lyricsOrigin: LyricsCacheWriteOrigin = .automatic
    }

    /// 封面只有存进本机缓存、引用指着的文件读得回来并能解码成图片时才指过去；歌词只有有有效行、
    /// 缓存也收下了才指过去。存不下的不改引用，记成保存失败。引用失效而这一轮又没补上时，失效的
    /// 本机引用不在这一行里清（这一行可能带着用户编辑标记，会被同步成「用户删了封面」），交给调用方
    /// 另外摘。批量刮削和快捷单曲共用这一份。
    ///
    /// - Parameter lyricsOrigin: 用户点名的刮削（快捷单曲、重新刮削覆盖）传 `.user`：刮到的歌词算用户选的版本，
    ///   自动路径不再换掉它，之前清空过歌词的也照写（写进去时解除清空）。只补缺失的传 `.automatic`。
    func applyScrapedResult(
        _ result: ProcessedResult?,
        scope: ScrapeScope,
        to song: Song,
        parts: ScrapeParts,
        coverOrigin: StoredArtworkOrigin,
        stampsUserEdit: Bool,
        lyricsOrigin: LyricsCacheWriteOrigin = .automatic
    ) async -> AppliedScrape {
        let coverConsidered = scope.considered.contains(.cover)
        // 用户主动清空过歌词的歌，只补缺失时刮到的歌词不写，按「没去刮」算，不进失败清单。
        // 用户点名的刮削不受它挡：`.user` 写进缓存时会解除清空，没刮到就还是清空着。
        var lyricsClearedByUser = false
        if lyricsOrigin != .user {
            let clearedInStore = await MetadataAssetStore.shared.hasUserClearedLyrics(forSongID: song.id)
            lyricsClearedByUser = clearedInStore || Self.lyricsWereClearedByUser(song.id)
        }
        let lyricsConsidered = scope.considered.contains(.lyrics) && !lyricsClearedByUser
        let tagsConsidered = !scope.considered.isDisjoint(with: ScrapeField.tags)
        let coverFetched = scope.fetched.contains(.cover)
        let lyricsFetched = scope.fetched.contains(.lyrics) && !lyricsClearedByUser
        let tagsFetched = !scope.fetched.isDisjoint(with: ScrapeField.tags)

        func staleReferences(coverStored: Bool, lyricsCached: Bool) -> StaleAssetReference? {
            var stale = StaleAssetReference(songID: song.id)
            if coverFetched, !coverStored, scope.assets.cover.clearsReferenceWhenMissed {
                stale.cover = song.coverArtFileName
            }
            if lyricsFetched, !lyricsCached, scope.assets.lyrics.clearsReferenceWhenMissed {
                stale.lyrics = song.lyricsFileName
            }
            return stale.cover == nil && stale.lyrics == nil ? nil : stale
        }

        guard let result else {
            let parts = ScrapeSongParts(
                cover: ScrapePartJudgment.outcome(considered: coverConsidered, fetched: coverFetched, received: false, stored: false),
                lyrics: ScrapePartJudgment.outcome(considered: lyricsConsidered, fetched: lyricsFetched, received: false, stored: false),
                tags: ScrapePartJudgment.outcome(considered: tagsConsidered, fetched: tagsFetched, received: false, stored: false)
            )
            return AppliedScrape(song: song, parts: parts, storedCover: nil, cachedLyrics: nil, persists: false,
                                 staleReferences: staleReferences(coverStored: false, lyricsCached: false))
        }

        var updated = ScrapeApplyPolicy.restricted(result.song, to: parts, original: song)

        var storedCover: Data?
        if let coverData = result.coverData {
            if let reference = await MetadataAssetStore.shared.storeAttributedCover(coverData, songID: song.id, origin: coverOrigin),
               await Self.storedCoverIsReadable(reference) {
                updated.coverArtFileName = reference
                storedCover = coverData
                CachedArtworkView.invalidateCache(for: song.id)
            } else {
                plog("MusicScraperService: scraped cover not saved song=\(song.id.prefix(12)) bytes=\(coverData.count)")
            }
        }
        if storedCover == nil {
            // 图存不下就别指过去: 引用一旦不空, 之后的刮削缺失都会跳过这首。
            updated.coverArtFileName = song.coverArtFileName
        }

        let scrapedLyrics = lyricsFetched ? result.lyricsLines : nil
        let lyricsReceived = scrapedLyrics?.isEmpty == false
        var cachedLyrics: [LyricLine]?
        var embeddedLyricsAnchor: LyricsWriteback.EmbeddedAnchor?
        if let lines = scrapedLyrics, !lines.isEmpty {
            let usable = ScrapedLyricsValidity.hasUsableLines(lines)
            // 覆盖歌词、又要写进音频文件时，按字段替换要认出文件里正在用的那一份：它按缓存里现在那份去对，
            // 所以必须在缓存换成新歌词之前取。
            var anchor: LyricsWriteback.EmbeddedAnchor?
            if usable, scope.overwrites.contains(.lyrics),
               EmbeddedLyricsCopyPolicy.mode(forSongID: song.id) != .off {
                anchor = await LyricsWriteback.embeddedReplacementAnchor(forSongID: song.id)
            }
            // 拿到歌词立即写本机缓存并把引用指到缓存：播放页马上重读时先读到的就是它，
            // 不必等写回音乐源。
            if usable,
               await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: song.id, force: true, origin: lyricsOrigin) {
                updated.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
                cachedLyrics = lines
                embeddedLyricsAnchor = anchor
            } else {
                plog("MusicScraperService: scraped lyrics not saved song=\(song.id.prefix(12)) lines=\(lines.count) usable=\(usable) origin=\(lyricsOrigin.rawValue)")
            }
        }
        if cachedLyrics == nil {
            updated.lyricsFileName = song.lyricsFileName
        }

        let changedTags = ScrapeTagChange.changedFields(from: song, to: updated)
        if stampsUserEdit {
            updated = SongUserMetadataPolicy.stampingUserEdit(original: song, updated: updated)
        }
        let parts = ScrapeSongParts(
            cover: ScrapePartJudgment.outcome(considered: coverConsidered, fetched: coverFetched,
                                              received: result.coverData != nil, stored: storedCover != nil),
            lyrics: ScrapePartJudgment.outcome(considered: lyricsConsidered, fetched: lyricsFetched,
                                               received: lyricsReceived, stored: cachedLyrics != nil),
            tags: ScrapePartJudgment.outcome(considered: tagsConsidered, fetched: tagsFetched,
                                             received: !changedTags.isEmpty, stored: true)
        )
        let lyricsSource = cachedLyrics.flatMap { LyricsDocumentSource.of($0)?.kind }
        return AppliedScrape(
            song: updated, parts: parts, storedCover: storedCover, cachedLyrics: cachedLyrics,
            persists: updated != song || storedCover != nil || cachedLyrics != nil,
            staleReferences: staleReferences(coverStored: storedCover != nil, lyricsCached: cachedLyrics != nil),
            writesBackCover: ScrapeWritebackSourcePolicy.writesBackCover(readFromFile: result.coverReadFromFile),
            writesBackLyrics: ScrapeWritebackSourcePolicy.writesBackLyrics(sourceKind: lyricsSource),
            overwritesCover: scope.overwrites.contains(.cover),
            overwritesLyrics: scope.overwrites.contains(.lyrics),
            embeddedLyricsAnchor: embeddedLyricsAnchor,
            lyricsOrigin: lyricsOrigin
        )
    }

    /// 存下的封面引用读得回来、能解码成图片。读文件放在后台。
    private nonisolated static func storedCoverIsReadable(_ reference: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let data = MetadataAssetStore.shared.readCoverData(named: reference) else { return false }
            return ArtworkImageCompatibility.isCompleteImage(data)
        }.value
    }

    private func recordBatchSongOutcome(_ applied: AppliedScrape, for song: Song) {
        tally.record(applied.parts)
        switch applied.parts.result {
        case .updated: updatedCount += 1
        case .unchanged: skippedCount += 1
        case .failed: failedCount += 1
        }
        if applied.parts.cover == .saveFailed {
            tally.recordFailure(.init(songID: song.id, title: song.title, part: .cover))
        }
        if applied.parts.lyrics == .saveFailed {
            tally.recordFailure(.init(songID: song.id, title: song.title, part: .lyrics))
        }
    }

    /// 写回音乐源的结果记进这一轮的账。断点里的分项计数只在推进断点时更新，这里只把写回这部分的
    /// 增量记进内存里的断点：被系统打断时随断点落盘；源不可达延后之后迟到的结果也记得进去。
    private func recordBatchWriteback(
        _ outcome: ScrapeWritebackOutcome,
        detail: String?,
        songID: String,
        title: String,
        runID: UUID
    ) {
        guard outcome != .notAttempted else { return }
        var failure: BatchScrapeFailureEntry?
        if case .failed(let reason) = outcome {
            failure = BatchScrapeFailureEntry(songID: songID, title: title, part: .writeback, reason: reason, detail: detail)
            plog("MusicScraperService: batch writeback failed song=\(songID.prefix(12)) reason=\(reason.rawValue)")
        }
        if activeRunID == runID {
            tally.recordWriteback(outcome)
            if let failure { tally.recordFailure(failure) }
        }
        if var checkpoint = scrapeCheckpoint, checkpoint.runID == runID {
            var persisted = checkpoint.tally ?? BatchScrapeTally()
            persisted.recordWriteback(outcome)
            if let failure { persisted.recordFailure(failure) }
            checkpoint.tally = persisted
            scrapeCheckpoint = checkpoint
        }
    }

    /// 后台写回任务结束。已经被记成被打断或超时的（不在「还在写」里了）不再重复记。
    private func finishBatchWriteback(
        _ outcome: ScrapeWritebackOutcome,
        detail: String?,
        songID: String,
        title: String,
        runID: UUID
    ) {
        let key = Self.inFlightKey(runID: runID, songID: songID)
        guard let entry = inFlightWritebacks.removeValue(forKey: key) else { return }
        longestWritebackDuration = max(longestWritebackDuration, ProcessInfo.processInfo.systemUptime - entry.startedAt)
        recordBatchWriteback(outcome, detail: detail, songID: songID, title: title, runID: runID)
    }

    /// 离开前台、后台时间用完、点了停止：还在写或排着没开始的写回记成被打断，进失败清单。
    private func markInFlightWritebacksInterrupted() {
        guard !inFlightWritebacks.isEmpty else { return }
        let entries = Array(inFlightWritebacks.values)
        inFlightWritebacks.removeAll()
        plog("MusicScraperService: \(entries.count) source writebacks interrupted")
        for entry in entries {
            recordBatchWriteback(.failed(.interrupted), detail: nil,
                                 songID: entry.songID, title: entry.title, runID: entry.runID)
        }
    }

    /// 等这一轮在这个进程里发起的写回都结束。一直有写完的就接着等；连着一段时间一首都没写完
    /// （按这一轮最慢的一首放宽，嵌入要整首下载上传），剩下的记成超时并进失败清单，不让完成卡死。
    private func awaitRunWritebacks(_ context: RunContext, timeout: TimeInterval) async {
        awaitingRunContext = context
        func remaining() -> [InFlightWriteback] {
            inFlightWritebacks.values.filter { $0.runID == context.runID }
        }
        var lastRemaining = remaining().count
        var lastProgressAt = ProcessInfo.processInfo.systemUptime
        while scrapingGeneration == context.generation, !Task.isCancelled, lastRemaining > 0 {
            currentSongTitle = String(format: String(localized: "scrape_tally_waiting_writeback_format"), lastRemaining)
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard scrapingGeneration == context.generation else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let count = remaining().count
            if count != lastRemaining {
                lastRemaining = count
                lastProgressAt = now
                continue
            }
            let limit = ScrapeWritebackWaitPolicy.stallLimit(
                sidecarTimeout: timeout, longestObservedWrite: longestWritebackDuration
            )
            if now - lastProgressAt >= limit {
                let stalled = remaining()
                plog("MusicScraperService: stopped waiting for \(stalled.count) source writebacks after \(Int(limit))s without progress; counted as timed out")
                for entry in stalled {
                    inFlightWritebacks[Self.inFlightKey(runID: entry.runID, songID: entry.songID)] = nil
                    recordBatchWriteback(.failed(.timeout), detail: nil,
                                         songID: entry.songID, title: entry.title, runID: entry.runID)
                }
                return
            }
        }
    }

    /// 一轮批量刮削做完：交出结果、发通知、清断点。正常结束和在等写回时点停止都走这里。
    private func finishBatchRun(_ context: RunContext) {
        let completion = BatchScrapeCompletion(
            runID: context.runID,
            originPlaylistID: context.originPlaylistID,
            songCount: context.songCount,
            updatedCount: updatedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            artworkTotalCount: artworkTotalCount,
            artworkAvailableCount: artworkAvailableCount,
            artworkUnavailableCount: artworkUnavailableCount,
            tally: tally,
            tallyIsPartial: runTallyIsPartial
        )
        let runTally = tally
        plog("MusicScraperService: batch scrape finished songs=\(context.songCount) updated=\(updatedCount) unchanged=\(skippedCount) failed=\(failedCount) cover=\(runTally.cover.filled)/\(runTally.cover.alreadyPresent)/\(runTally.cover.notFound)/\(runTally.cover.saveFailed) lyrics=\(runTally.lyrics.filled)/\(runTally.lyrics.alreadyPresent)/\(runTally.lyrics.notFound)/\(runTally.lyrics.saveFailed) tags=\(runTally.tags.filled) writeback=\(runTally.writebackWritten)ok/\(runTally.writebackFailed)failed partial=\(runTallyIsPartial)")
        lastCompletion = completion
        if let originPlaylistID = context.originPlaylistID {
            pendingPlaylistCompletions[originPlaylistID] = completion
        }
        completionRevision &+= 1
        clearScrapeCheckpoint()
        let forceRescrape = context.forceRescrape
        Task { @MainActor in
            await Self.postScrapeCompletionNotification(forceRescrape: forceRescrape, completion: completion)
        }
    }

    /// 一首歌失效的本机引用（引用还在、本机文件已经没了）。
    struct StaleAssetReference: Sendable, Equatable {
        let songID: String
        var cover: String?
        var lyrics: String?
    }

    /// 摘掉失效的本机引用。先在后台对每条再核一次（引用还是那个、确实读不到、不是被容量清理掉的），
    /// 再对库里当前那一行单独写一次：只改引用、不动用户编辑标记，同步那边不会当成「用户删了封面」。
    func clearStaleAssetReferences(_ entries: [StaleAssetReference], in library: MusicLibrary) async {
        guard !entries.isEmpty else { return }
        let verified = await Task.detached(priority: .utility) { () -> [StaleAssetReference] in
            entries.compactMap { entry in
                let cover = entry.cover.flatMap { ScraperSettings.coverReferenceIsDead($0) ? $0 : nil }
                let lyrics = entry.lyrics.flatMap {
                    ScraperSettings.lyricsReferenceIsDead($0, songID: entry.songID) ? $0 : nil
                }
                guard cover != nil || lyrics != nil else { return nil }
                return StaleAssetReference(songID: entry.songID, cover: cover, lyrics: lyrics)
            }
        }.value
        guard !verified.isEmpty else { return }
        library.flushPendingAssetReferencePatches()
        var rows: [Song] = []
        for entry in verified {
            guard var row = library.storedSong(id: entry.songID) else { continue }
            var changed = false
            if let cover = entry.cover, row.coverArtFileName == cover {
                row.coverArtFileName = nil
                changed = true
                CachedArtworkView.invalidateCache(for: row.id)
            }
            if let lyrics = entry.lyrics, row.lyricsFileName == lyrics {
                row.lyricsFileName = nil
                changed = true
            }
            if changed { rows.append(row) }
        }
        guard !rows.isEmpty else { return }
        library.replaceSongs(rows)
        plog("MusicScraperService: cleared \(rows.count) stale local asset references")
    }

    // MARK: - 写回音乐源（封面、歌词文件与嵌入）

    /// 一首歌要写回音乐源的内容，以及按「封面保存到」「歌词保存到」定下的去处。
    struct ScrapedAssetWriteback: Sendable {
        let song: Song
        /// 封面文件和嵌入用的封面；「刮削后写回封面」关着、或封面本来就是从这个文件读出来的时为 nil。
        let coverData: Data?
        /// 歌词文件用的歌词；「刮削后写回歌词」关着、或歌词本来就是从这个文件读出来的时为 nil。
        let lyricsLines: [LyricLine]?
        /// 嵌进音频文件的行级 LRC；歌词不嵌入（或这一轮批量刮削没同意嵌入）时为 nil。
        let embeddedLyricsText: String?
        let coverEmbeddingMode: CoverEmbeddingMode
        let lyricsEmbeddingMode: LyricsEmbeddingMode
        /// 写进音频文件时：只补缺失的部分文件里已有就不换；和现有的一样就不整首重写；文件里已有歌词又要换时
        /// 不整段写，按字段只换正在用的那一份（`lyricsFieldReplacement`）。
        let embedPolicy: EmbeddedAssetWritePolicy
        let timeout: TimeInterval
        /// 歌词缓存算谁写的；写回后给缓存打来源标记时照这个来，不把用户选的版本的钉住弄丢。
        var lyricsOrigin: LyricsCacheWriteOrigin = .automatic
    }

    struct ScrapedAssetWritebackResult: Sendable {
        var outcome: ScrapeWritebackOutcome = .notAttempted
        var failureDetail: String?

        mutating func record(_ next: ScrapeWritebackOutcome, detail: String? = nil) {
            if case .failed = next, failureDetail == nil, outcome == .written || outcome == .notAttempted {
                failureDetail = detail
            }
            outcome = outcome.combined(with: next)
        }
    }

    actor ScrapedAssetWritebackBox {
        private(set) var result: ScrapedAssetWritebackResult?
        func store(_ result: ScrapedAssetWritebackResult) { self.result = result }
    }

    /// 刮削后要不要写回音乐源、写到哪。三个入口同一套规则：开关（刮削后写回封面 / 歌词）、
    /// 「封面保存到」「歌词保存到」，后两项已按来源、格式、CUE 分轨收窄过。从文件自己读出来的封面、
    /// 歌词不写回。`embedsLyrics`：批量刮削这一轮有没有同意把歌词写进音频文件；快捷单曲总是 true。
    func scrapedAssetWritebackJob(
        for song: Song,
        applied: AppliedScrape,
        embedsLyrics: Bool = true
    ) async -> ScrapedAssetWriteback? {
        let settings = Self.sidecarSettings()
        let coverData = settings.coverEnabled && applied.writesBackCover ? applied.storedCover : nil
        let lyricsLines = settings.lyricsEnabled && applied.writesBackLyrics ? applied.cachedLyrics : nil
        guard coverData != nil || lyricsLines != nil else { return nil }
        guard await sourceManager.supportsSidecarWriting(for: song) else {
            plog("📝 Sidecar: source does not support writing, keeping local metadata cache for '\(song.title)'")
            return nil
        }
        let coverMode = coverData == nil ? CoverEmbeddingMode.off : await sourceManager.coverEmbeddingMode(for: song)
        let lyricsMode = lyricsLines == nil ? LyricsEmbeddingMode.off : await sourceManager.lyricsEmbeddingMode(for: song)
        // 嵌入字段只认行级 LRC，和刮削结果页的保存同一份文本。
        let embeddedText = embedsLyrics && lyricsMode != .off
            ? lyricsLines.map { LyricsWriteback.embeddedCopyContent($0) }
            : nil
        // 文件里已有歌词又要换时按字段只换正在用的那一份（锚点是缓存换掉之前取的）；换掉的那份是逐字或 TTML
        // 时照它的格式写。文件里没有歌词时仍然整段写进默认字段。
        var fieldRequest: EmbeddedLyricsFieldRequest?
        if embeddedText != nil, let lines = lyricsLines {
            let anchor = applied.embeddedLyricsAnchor
            fieldRequest = EmbeddedLyricsFieldRequest(.replace(
                text: LyricsWriteback.embeddedText(for: lines, anchor: anchor), anchor: anchor?.text
            ))
        }
        plog("📝 Sidecar: coverData=\(coverData?.count ?? 0)B lyricsLines=\(lyricsLines?.count ?? 0) coverMode=\(coverMode.rawValue) lyricsMode=\(lyricsMode.rawValue) embedsLyrics=\(embeddedText != nil) anchor=\(applied.embeddedLyricsAnchor?.text == nil ? "none" : "known") origin=\(applied.lyricsOrigin.rawValue) for '\(song.title)'")
        return ScrapedAssetWriteback(
            song: song, coverData: coverData, lyricsLines: lyricsLines, embeddedLyricsText: embeddedText,
            coverEmbeddingMode: coverMode, lyricsEmbeddingMode: lyricsMode,
            embedPolicy: EmbeddedAssetWritePolicy(
                keepsExistingCover: !applied.overwritesCover,
                keepsExistingLyrics: !applied.overwritesLyrics,
                skipsUnchanged: true,
                lyricsFieldReplacement: fieldRequest
            ),
            timeout: settings.timeout,
            lyricsOrigin: applied.lyricsOrigin
        )
    }

    /// 按定好的去处写回：要嵌入的（封面、歌词）合成一次整文件事务（文件里已有、只补缺失时不换，
    /// 一样时不重写；文件里已有歌词又要换时歌词改成随后单独按字段替换），再用替换后的文件身份写封面、
    /// 歌词文件。只嵌入时不新建文件，歌曲旁已有的照样更新。存进缓存的歌词按落到哪个文件标来源。
    /// 源只读或连不上时打开这一轮的熔断，后面的歌不再试。
    nonisolated static func performScrapedAssetWriteback(
        _ job: ScrapedAssetWriteback,
        sourceManager: SourceManager,
        library: MusicLibrary,
        circuitBreaker: SidecarWriteCircuitBreaker
    ) async -> ScrapedAssetWritebackResult {
        let song = job.song
        var result = ScrapedAssetWritebackResult()
        guard await circuitBreaker.acquire(sourceID: song.sourceID) else {
            result.record(.failed(.unavailable))
            return result
        }
        var songForSidecar = song
        // 这次真的写进音频文件的歌词文字；没写进去为 nil。
        var embeddedLyricsWritten: String?
        let embedsCover = job.coverEmbeddingMode != .off && job.coverData != nil
        let embedsLyrics = job.lyricsEmbeddingMode != .off && job.embeddedLyricsText != nil
        if embedsCover || embedsLyrics, !Task.isCancelled {
            let embedded = await embedScrapedAssets(
                coverData: embedsCover ? job.coverData : nil,
                lyricsText: embedsLyrics ? job.embeddedLyricsText : nil,
                policy: job.embedPolicy,
                for: song, sourceManager: sourceManager, library: library
            )
            if embedded.sourceUnavailable {
                if await circuitBreaker.release(sourceID: song.sourceID, sourceUnavailable: true) {
                    plog("⚠️ Sidecar: source \(song.sourceID) is read-only or unavailable; later writes are skipped")
                }
                result.record(.failed(.unavailable), detail: embedded.failureDetail)
                return result
            }
            if let written = embedded.updatedSong {
                // 有的网盘替换后文件换了 ID，之后的旁路文件要跟着新文件走。封面那次事务成了、随后按字段换歌词
                // 没成时也是这样：文件已经换过一次。
                songForSidecar = written
                if !embedded.unchanged {
                    embeddedLyricsWritten = embedded.writtenLyricsText
                    result.record(.written)
                }
            }
            if let failure = embedded.failure {
                // 冲突、认不准文件里要换哪一份歌词时不覆盖：音频文件（的这一部分）保持原样，记成失败。
                result.record(.failed(failure), detail: embedded.failureDetail)
            }
        }

        var lyricsFileName: String?
        var lyricsSidecarWrite: SidecarWriteService.WriteResult.VerifiedLyricsWrite?
        if job.coverData != nil || job.lyricsLines != nil {
            do {
                let writeResult = try await writeSidecarWithTimeout(
                    seconds: job.timeout,
                    sourceManager: sourceManager,
                    for: songForSidecar,
                    coverData: job.coverData, lyricsLines: job.lyricsLines,
                    createsLyricsFile: job.lyricsEmbeddingMode != .embedOnly,
                    createsCoverFile: job.coverEmbeddingMode != .embedOnly
                )
                if await circuitBreaker.release(sourceID: song.sourceID, sourceUnavailable: writeResult.sourceUnavailable) {
                    plog("⚠️ Sidecar: source \(song.sourceID) is read-only or unavailable; later writes are skipped")
                }
                plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten) errors=\(writeResult.errors)")
                if writeResult.coverWritten {
                    if let coverPath = sidecarReferencePath(for: songForSidecar, suffix: "-cover.jpg"),
                       !Task.isCancelled {
                        let coverRef = songForSidecar.coverArtFileName ?? coverPath
                        await MainActor.run {
                            library.updateAssetReferences(songID: songForSidecar.id, coverRef: coverRef)
                        }
                    }
                    // 旁路文件已落盘 —— 现在回写 hash cache 作为可信副本。
                    if let coverData = job.coverData {
                        await MetadataAssetStore.shared.cacheCover(coverData, forSongID: song.id)
                    }
                }
                if writeResult.lyricsWritten {
                    lyricsFileName = writeResult.verifiedLyricsWrite?.target.fileName
                    lyricsSidecarWrite = writeResult.verifiedLyricsWrite
                }
                if writeResult.sourceUnavailable {
                    result.record(.failed(.unavailable), detail: writeResult.errors.first)
                } else if writeResult.lyricsTargetChanged {
                    result.record(.failed(.conflict))
                } else if writeResult.coverError != nil || writeResult.lyricsError != nil {
                    result.record(.failed(.other), detail: writeResult.errors.first)
                } else if writeResult.coverWritten || writeResult.lyricsWritten {
                    result.record(.written)
                }
                if !writeResult.errors.isEmpty {
                    plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                }
            } catch is CancellationError {
                _ = await circuitBreaker.release(sourceID: song.sourceID, sourceUnavailable: false)
                // 外层任务被取消是刮削被打断；否则是写入超时。
                let interrupted = Task.isCancelled
                plog("⚠️ Sidecar write \(interrupted ? "interrupted" : "timed out (\(job.timeout.finiteInt())s)") for '\(song.title)'")
                result.record(.failed(interrupted ? .interrupted : .timeout))
            } catch {
                let unavailable = isSourceUnavailableSidecarError(error)
                if await circuitBreaker.release(sourceID: song.sourceID, sourceUnavailable: unavailable) {
                    plog("⚠️ Sidecar: source \(song.sourceID) is unavailable; later writes are skipped")
                }
                plog("⚠️ Sidecar write skipped for '\(song.title)': \(error.localizedDescription)")
                result.record(.failed(unavailable ? .unavailable : writebackFailureReason(for: error)),
                              detail: error.localizedDescription)
            }
        } else {
            _ = await circuitBreaker.release(sourceID: song.sourceID, sourceUnavailable: false)
        }

        // 存进了哪个文件,播放页的来源标签就照它写(#357)：歌词文件优先，只嵌入时标「内嵌」。
        // 只在缓存还是这次刮到的那份时改：写回可能排了很久，期间用户改过歌词、选了别的版本就不动。
        if let lines = job.lyricsLines, !Task.isCancelled {
            let source: LyricsDocumentSource?
            if let lyricsFileName {
                source = .file(lyricsFileName)
            } else if embeddedLyricsWritten != nil {
                source = .embedded
            } else {
                source = nil
            }
            if let source {
                let stamped = source.stamped(lines)
                // 按原来写缓存的身份写：用户点名刮到的那份钉住了，按 `.automatic` 写会被拦下、来源标不上。
                let cached = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    stamped, forSongID: song.id,
                    expectedFingerprint: LyricsDocumentFingerprint(lines: lines),
                    preservingSelection: true,
                    origin: job.lyricsOrigin
                )
                plog("MusicScraperService: scraped lyrics source=\(lyricsFileName == nil ? "embedded" : "file") stamped=\(cached) origin=\(job.lyricsOrigin.rawValue) song=\(song.id.prefix(12))")
                // 用户选的版本：记下写进源的那份（和歌词编辑器保存一样），之后从源读回它不算「别处更新」，
                // 不会拿文件里的那份把缓存换掉。缓存已经不是这一份时 `noteSavedSourceDocument` 不记。
                if cached, job.lyricsOrigin == .user {
                    var sourceDocument: [LyricLine]?
                    if let verified = lyricsSidecarWrite {
                        sourceDocument = LyricsParser.parseDocument(verified.content, fileName: verified.target.fileName)
                    } else if let embeddedLyricsWritten {
                        sourceDocument = LyricsContentParser.parseText(embeddedLyricsWritten)
                    }
                    if let sourceDocument, !sourceDocument.isEmpty {
                        await MetadataAssetStore.shared.noteSavedSourceDocument(sourceDocument, forSongID: song.id)
                    }
                }
            }
        }
        return result
    }

    struct EmbeddedAssetsOutcome: Sendable {
        /// 文件此刻的身份（替换过就是替换后的）；没写成时为 nil。
        var updatedSong: Song?
        /// 文件里已有（只补缺失）或一样，什么都没替换。
        var unchanged = false
        var failure: ScrapeWritebackFailureReason?
        var failureDetail: String?
        var sourceUnavailable = false
        /// 这次真的写进文件的歌词文字（文件里原来没有、随事务写进默认字段，或者按字段换掉了正在用的那一份）。
        var writtenLyricsText: String?
    }

    /// 把刮到的封面和（或）歌词写进音频文件，一次整文件事务。要整首下载、改写、替换、回读，所以不套
    /// 旁路文件的写入超时（半途取消可能停在替换阶段），也放进独立任务、不随刮削取消而中断。
    /// 冲突判断按库里记的文件身份做，文件被别处改过时不覆盖；替换前按 `policy` 看文件里已有的。
    /// 文件里已有歌词又要换时（`policy.lyricsFieldReplacement`）不整段写，按字段只换正在用的那一份：只有歌词
    /// 要写时就在这次事务里改，还要换封面时随后用事务交回的文件身份单独再写一次；认不准时文件不动、记成失败。
    /// 成功后把文件身份记回资料库，记下的「文件里有几份原文」跟着实际结果改。
    nonisolated static func embedScrapedAssets(
        coverData: Data?,
        lyricsText: String?,
        policy: EmbeddedAssetWritePolicy = .replace,
        for song: Song,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> EmbeddedAssetsOutcome {
        var embeddableCover: Data?
        if let coverData {
            embeddableCover = SidecarWriteService.embeddableCoverData(coverData)
            if embeddableCover == nil {
                plog("⚠️ Embedded cover: scraped artwork for '\(song.title)' is not a decodable image")
            }
        }
        guard embeddableCover != nil || lyricsText != nil else {
            return EmbeddedAssetsOutcome(failure: coverData == nil ? nil : .other)
        }
        // 冲突判断按库里记的文件身份做，刮削手里的快照可能已经旧了（比如刚嵌入过歌词）。
        let target = await MainActor.run { () -> Song in
            var target = song
            if let latest = library.storedSong(id: song.id) {
                target.filePath = latest.filePath
                target.fileSize = latest.fileSize
                target.lastModified = latest.lastModified
                target.revision = latest.revision
            }
            return target
        }
        let lyricsEdit: EmbeddedLyricsEdit = lyricsText.map { EmbeddedLyricsEdit.set($0) } ?? .keep
        let cover = embeddableCover
        let write = Task.detached(priority: .utility) {
            try await sourceManager.writeEmbeddedAssets(coverData: cover, lyrics: lyricsEdit, policy: policy, for: target)
        }
        let fieldRequest = policy.lyricsFieldReplacement
        do {
            let written = try await write.value
            let fieldReport = fieldRequest.flatMap { EmbeddedLyricsFieldReports.take($0.id) }
            await recordEmbeddedFileIdentity(written.song, songID: song.id, library: library)
            var outcome = EmbeddedAssetsOutcome(updatedSong: written.song, unchanged: written.unchanged)
            switch written.lyricsHandling {
            case .written:
                outcome.writtenLyricsText = lyricsText
                // 文件里原来没有歌词，现在只有刚写进默认字段的这一份：之前记下的几份原文、备用内嵌歌词作废，
                // 加载时按设置重挑不会挑到一份已经不在文件里的旧内容。
                await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                    forSongID: song.id, result: .wroteDefaultField, anchor: nil, text: lyricsText
                )
            case .replacedByField:
                if let fieldRequest {
                    outcome.writtenLyricsText = await recordFieldReplacement(fieldRequest, report: fieldReport, songID: song.id)
                }
            case .leftForFieldReplace:
                if let fieldRequest {
                    outcome = await replaceEmbeddedLyricsField(
                        fieldRequest, after: outcome, for: written.song,
                        sourceManager: sourceManager, library: library
                    )
                } else {
                    // 没带按字段替换的请求（不该发生）：不去动文件里的歌词，这首的歌词写回记成失败。
                    plog("Embedded scrape lyrics: the file already has lyrics and no field replacement was prepared song=\(song.id.prefix(12))")
                    outcome.failure = .lyricsNotLocated
                }
            case .notIncluded, .kept:
                break
            }
            return outcome
        } catch {
            let fieldReport = fieldRequest.flatMap { EmbeddedLyricsFieldReports.take($0.id) }
            if Self.fieldReportMeansNotLocated(fieldReport) {
                plog("Embedded scrape lyrics: could not tell which version in the file to replace report=\(String(describing: fieldReport)); file left as it was song=\(song.id.prefix(12))")
                return EmbeddedAssetsOutcome(failure: .lyricsNotLocated, failureDetail: error.localizedDescription)
            }
            plog("⚠️ Embedded scrape writeback failed for '\(song.title)' cover=\(cover != nil) lyrics=\(lyricsText != nil): \(error.localizedDescription)")
            return EmbeddedAssetsOutcome(
                failure: writebackFailureReason(for: error),
                failureDetail: error.localizedDescription,
                sourceUnavailable: isSourceUnavailableSidecarError(error)
            )
        }
    }

    /// 写入器说认不准是哪一份（或者写进去读回来选中的不是它）：文件没动，不是音乐源的错。
    nonisolated static func fieldReportMeansNotLocated(_ report: EmbeddedLyricsFieldReport?) -> Bool {
        switch report {
        case .notLocated?, .notPreferred?: return true
        case .done?, nil: return false
        }
    }

    /// 按字段改写成功后，记下的「文件里有几份原文」按写入器的实际回报跟上。交回写进文件的文字。
    private nonisolated static func recordFieldReplacement(
        _ request: EmbeddedLyricsFieldRequest,
        report: EmbeddedLyricsFieldReport?,
        songID: String
    ) async -> String? {
        guard case .replace(let text, let anchor) = request.operation else { return nil }
        let result: EmbeddedLyricsFieldEditor.Result
        if case .done(let done, _)? = report {
            result = done
        } else {
            // 写成了却没有回报（不该发生）：按「只写了默认字段」处理，记录作废、下次读标签重记。
            result = .wroteDefaultField
        }
        await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
            forSongID: songID, result: result, anchor: anchor, text: text
        )
        plog("Embedded scrape lyrics replaced by field result=\(String(describing: result)) anchor=\(anchor == nil ? "none" : "known") song=\(songID.prefix(12))")
        return text
    }

    /// 写进音频文件后把文件的新身份记回资料库里这首歌现在那一行。
    private nonisolated static func recordEmbeddedFileIdentity(_ written: Song, songID: String, library: MusicLibrary) async {
        await MainActor.run {
            library.flushPendingAssetReferencePatches()
            guard var latest = library.storedSong(id: songID) else { return }
            latest.filePath = written.filePath
            latest.fileSize = written.fileSize
            latest.lastModified = written.lastModified
            latest.revision = written.revision
            library.replaceSong(latest)
        }
    }

    /// 文件里已有歌词、这次还换了封面：封面那次事务之后，用它交回的文件身份按字段只换正在用的那一份，
    /// 别的原文、译文原样（`EmbeddedLyricsFieldEditor`）。认不准是哪一份、或者写进去读回来选中的不是它时，
    /// 写入器不动文件（或放回原样），这首的歌词写回记成失败，结果详情里能看到。
    private nonisolated static func replaceEmbeddedLyricsField(
        _ request: EmbeddedLyricsFieldRequest,
        after transaction: EmbeddedAssetsOutcome,
        for song: Song,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> EmbeddedAssetsOutcome {
        var outcome = transaction
        let target = song
        let write = Task.detached(priority: .utility) {
            try await sourceManager.writeEmbeddedLyrics(.field(request), for: target)
        }
        do {
            let written = try await write.value
            let report = EmbeddedLyricsFieldReports.take(request.id)
            await recordEmbeddedFileIdentity(written, songID: song.id, library: library)
            outcome.updatedSong = written
            outcome.unchanged = false
            outcome.writtenLyricsText = await recordFieldReplacement(request, report: report, songID: song.id)
            return outcome
        } catch {
            let report = EmbeddedLyricsFieldReports.take(request.id)
            if fieldReportMeansNotLocated(report) {
                plog("Embedded scrape lyrics: could not tell which version in the file to replace report=\(String(describing: report)); file left as it was song=\(song.id.prefix(12))")
                outcome.failure = .lyricsNotLocated
            } else {
                plog("Embedded scrape lyrics field write failed song=\(song.id.prefix(12)): \(error.localizedDescription)")
                outcome.failure = writebackFailureReason(for: error)
                outcome.sourceUnavailable = isSourceUnavailableSidecarError(error)
            }
            outcome.failureDetail = error.localizedDescription
            return outcome
        }
    }

    /// 写回失败归到哪一类：只读或不可达、与文件现状冲突、超时、其他。
    nonisolated static func writebackFailureReason(for error: Error) -> ScrapeWritebackFailureReason {
        if error is CancellationError { return .timeout }
        switch error {
        case EmbeddedMetadataCoordinatedWritebackError.conflict, EmbeddedMetadataWritebackSourceError.conflict:
            return .conflict
        case EmbeddedMetadataCoordinatedWritebackError.operationFailed(_, _, _, let isTransient) where isTransient:
            return .unavailable
        default:
            break
        }
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timeout }
        if isSourceUnavailableSidecarError(error) || MetadataWriteFailurePolicy.isTransient(error) { return .unavailable }
        return .other
    }

    /// 媒体服务器（Jellyfin 等）走它自己的写回接口。返回这首歌写回的结局，失败时带上服务器报的错。
    @discardableResult
    private func writeBackToMediaServerIfSupported(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?
    ) async -> (outcome: ScrapeWritebackOutcome, detail: String?) {
        guard await sourceManager.supportsMediaServerWriteback(for: updated) else {
            return (.notAttempted, nil)
        }
        let result = await sourceManager.writeScrapedMetadataToMediaServer(
            original: original,
            updated: updated,
            coverData: coverData,
            lyricsLines: lyricsLines
        )
        if !result.errors.isEmpty {
            plog("⚠️ Media-server writeback errors for '\(updated.title)': \(result.errors)")
        }
        if !result.unsupported.isEmpty {
            plog("ℹ️ Media-server writeback limitations for '\(updated.title)': \(result.unsupported)")
        }
        if !result.errors.isEmpty {
            return (.failed(.other), result.errors.first)
        }
        let wrote = result.metadataWritten || result.coverWritten || result.lyricsWritten
        return (wrote ? .written : .notAttempted, nil)
    }

    private nonisolated static func sidecarSettings() -> (coverEnabled: Bool, lyricsEnabled: Bool, timeout: TimeInterval) {
        let defaults = UserDefaults.standard
        let coverEnabled = defaults.object(forKey: sidecarCoverWriteEnabledKey) == nil
            ? true
            : defaults.bool(forKey: sidecarCoverWriteEnabledKey)
        let lyricsEnabled = defaults.object(forKey: sidecarLyricsWriteEnabledKey) == nil
            ? true
            : defaults.bool(forKey: sidecarLyricsWriteEnabledKey)
        let timeout = defaults.object(forKey: sidecarWriteTimeoutKey) == nil
            ? 30
            : defaults.double(forKey: sidecarWriteTimeoutKey)
        return (coverEnabled, lyricsEnabled, max(5, min(120, timeout)))
    }
}

// MARK: - 完成提示的文字

extension MusicScraperService.BatchScrapeCompletion {
    /// 完成提示按部分说清楚。系统通知、iPhone 和 Mac 的提示条、设置页共用这一份。
    var summaryLines: [String] {
        let summary = tally.summary
        var lines: [String] = []
        if tallyIsPartial {
            // 旧版本留下的断点续上的：分项计数只有续跑那部分，说总数那一行。
            lines.append(String(
                format: String(localized: "batch_scrape_completed_format"),
                processedSongCount, songCount, updatedCount, skippedCount, failedCount
            ))
        } else if summary.foundNothing {
            lines.append(String(localized: "scrape_tally_nothing"))
        } else {
            if !summary.cover.isEmpty {
                lines.append(String(format: String(localized: "scrape_tally_cover_line_format"),
                                    BatchScrapeSummaryText.segments(summary.cover)))
            }
            if !summary.lyrics.isEmpty {
                lines.append(String(format: String(localized: "scrape_tally_lyrics_line_format"),
                                    BatchScrapeSummaryText.segments(summary.lyrics)))
            }
            if summary.tagsFilled > 0 {
                lines.append(String(format: String(localized: "scrape_tally_tags_line_format"), summary.tagsFilled))
            }
            if summary.writebackWritten + summary.writebackFailed > 0 {
                var parts: [String] = []
                if summary.writebackWritten > 0 {
                    parts.append(String(format: String(localized: "scrape_tally_writeback_ok_format"), summary.writebackWritten))
                }
                if summary.writebackFailed > 0 {
                    parts.append(String(format: String(localized: "scrape_tally_writeback_failed_format"), summary.writebackFailed))
                }
                lines.append(String(format: String(localized: "scrape_tally_writeback_line_format"),
                                    parts.joined(separator: " · ")))
            }
            if summary.songErrors > 0 {
                lines.append(String(format: String(localized: "scrape_tally_errors_line_format"), summary.songErrors))
            }
        }
        if artworkTotalCount > 0 {
            lines.append(String(
                format: String(localized: "batch_scrape_completed_artwork_format"),
                artworkAvailableCount,
                artworkTotalCount,
                artworkUnavailableCount
            ))
        }
        return lines
    }

    var summaryText: String { summaryLines.joined(separator: "\n") }

    /// 有没有能点开看的失败清单。
    var hasFailureDetails: Bool { tally.hasFailures }

    /// 提示条的语气：全没成、部分没成、成了、什么都没找到。专辑、艺人图在线没找到不算失败。
    var hasAnyFailure: Bool {
        failedCount > 0 || tally.writebackFailed > 0 || tally.hasFailures
    }

    var appliedAnything: Bool {
        updatedCount > 0 || artworkAvailableCount > 0
    }
}

enum BatchScrapeSummaryText {
    static func segments(_ segments: [BatchScrapeSummary.Segment]) -> String {
        segments.map { segment -> String in
            switch segment {
            case .filled(let count): String(format: String(localized: "scrape_tally_filled_format"), count)
            case .alreadyPresent(let count): String(format: String(localized: "scrape_tally_present_format"), count)
            case .notFound(let count): String(format: String(localized: "scrape_tally_not_found_format"), count)
            case .saveFailed(let count): String(format: String(localized: "scrape_tally_save_failed_format"), count)
            }
        }.joined(separator: " · ")
    }

    static func reason(_ reason: ScrapeWritebackFailureReason) -> String {
        switch reason {
        case .unavailable: String(localized: "scrape_tally_reason_unavailable")
        case .conflict: String(localized: "scrape_tally_reason_conflict")
        case .timeout: String(localized: "scrape_tally_reason_timeout")
        case .interrupted: String(localized: "scrape_tally_reason_interrupted")
        case .other: String(localized: "scrape_tally_reason_other")
        case .lyricsNotLocated: String(localized: "scrape_tally_reason_lyrics_not_located")
        }
    }

    /// 失败清单里这一行说什么。
    static func description(of entry: BatchScrapeFailureEntry) -> String {
        switch entry.part {
        case .cover: String(localized: "scrape_tally_failure_cover")
        case .lyrics: String(localized: "scrape_tally_failure_lyrics")
        case .song: String(localized: "scrape_tally_failure_song")
        case .writeback:
            String(format: String(localized: "scrape_tally_writeback_failed_detail_format"), reason(entry.reason ?? .other))
        }
    }

    /// 快捷单曲刮削没成的部分，一句一行；全成了返回 nil。
    static func singleFailure(_ outcome: MusicScraperService.SingleScrapeOutcome) -> String? {
        var lines: [String] = []
        if outcome.coverSaveFailed { lines.append(String(localized: "scrape_tally_failure_cover")) }
        if outcome.lyricsSaveFailed { lines.append(String(localized: "scrape_tally_failure_lyrics")) }
        if let reason = outcome.writebackFailureReason {
            lines.append(String(format: String(localized: "scrape_tally_writeback_failed_detail_format"),
                                Self.reason(reason)))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
