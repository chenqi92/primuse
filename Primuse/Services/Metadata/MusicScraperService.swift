import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// Serializes sidecar writes per source and opens a session-only circuit after
/// a credential/permission failure. This prevents an eight-song publication
/// batch from creating eight SMB sessions and repeating the same rejected
/// write hundreds or thousands of times.
private actor SidecarWriteCircuitBreaker {
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
    }

    enum BatchScrapePhase: Equatable {
        case songs
        case artwork
    }

    /// Reports metadata committed to the app library and artwork cache. Optional
    /// media-server sidecar writes continue independently and are not included.
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
    private let metadataService = MetadataService()
    private var scrapingTask: Task<Void, Never>?
    private var scrapingGeneration = 0
    private var backgroundEnrichmentTask: Task<Void, Never>?
    private var sidecarWriteTasks: [UUID: Task<Void, Never>] = [:]
    private let sidecarCircuitBreaker = SidecarWriteCircuitBreaker()
    private var singleScrapeTask: Task<SingleScrapeResult, Error>?
    private var pendingSingleScrapeCompletions: [SingleSongScrapeKey: SingleScrapeCompletion] = [:]
    private var singleScrapeCompletionOrder: [SingleSongScrapeKey] = []
    private var recentSingleScrapeCompletions: [UUID: SingleScrapeCompletion] = [:]
    private var singleScrapeRunOrder: [UUID] = []
    private var pendingEnrichmentSongIDs: [String] = []
    private var pendingEnrichmentSongIDSet: Set<String> = []
    private var isPausedForSceneTransition = false
    /// Bound both observable full-library publications and checkpoint replay.
    /// Eight items is large enough to collapse the repeated 10K-song array
    /// churn while remaining a small, idempotent unit after interruption.
    private static let songPublicationBatchSize = 8
    private let scrapeCheckpointURL: URL
    private var scrapeCheckpoint: ScrapeCheckpoint?
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

        var hasPersistedSongCounts: Bool {
            updatedCount != nil && skippedCount != nil && failedCount != nil
        }
    }

    private(set) var isScraping = false
    private(set) var isBackgroundEnriching = false
    private(set) var currentSongTitle = ""
    private(set) var processedCount = 0
    private(set) var totalCount = 0
    private(set) var updatedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0
    private(set) var batchPhase: BatchScrapePhase = .songs
    private(set) var songTotalCount = 0
    private(set) var artworkTotalCount = 0
    private(set) var artworkProcessedCount = 0
    private(set) var artworkAvailableCount = 0
    private(set) var artworkUnavailableCount = 0
    private(set) var lastCompletion: BatchScrapeCompletion?
    private(set) var completionRevision: UInt = 0
    private(set) var activeRunID: UUID?
    private(set) var activeOriginPlaylistID: String?
    private(set) var activeSingleScrape: SingleSongScrapeActivity?
    private(set) var singleScrapeCompletionRevision: UInt = 0
    private var pendingPlaylistCompletions: [String: BatchScrapeCompletion] = [:]
    private var artworkTargetIDs: [String] = []

    init(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scrapeCheckpointURL = directory.appendingPathComponent("scrape-checkpoint.json")
        if let data = try? Data(contentsOf: scrapeCheckpointURL) {
            scrapeCheckpoint = try? JSONDecoder().decode(ScrapeCheckpoint.self, from: data)
        }
    }

    /// True when an interrupted batch scrape can be resumed after foregrounding
    /// or from the registered BGProcessingTask.
    var hasPendingScrape: Bool {
        scrapeCheckpoint?.songIDs.isEmpty == false
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

    @discardableResult
    func scrapeMissingMetadata(
        songs: [Song],
        in library: MusicLibrary,
        originPlaylistID: String? = nil
    ) -> BatchScrapeStartResult {
        startScraping(
            songs: songs,
            in: library,
            forceRescrape: false,
            originPlaylistID: originPlaylistID
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
        dryRun: Bool = false
    ) -> SingleScrapeStartResult {
        let purpose: SingleSongScrapePurpose = dryRun ? .metadataPreview : .metadataApply
        let key = SingleSongScrapeKey(songID: song.id, purpose: purpose)
        return startManagedSingleScrape(key: key, in: library) { [self] in
            try await performSingleScrape(song: song, in: library, dryRun: dryRun)
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
        purposes: [SingleSongScrapePurpose]
    ) -> SingleScrapeCompletion? {
        for purpose in purposes {
            let key = SingleSongScrapeKey(songID: songID, purpose: purpose)
            guard let completion = pendingSingleScrapeCompletions.removeValue(forKey: key) else {
                continue
            }
            singleScrapeCompletionOrder.removeAll { $0 == key }
            return completion
        }
        return nil
    }

    private func startManagedSingleScrape(
        key: SingleSongScrapeKey,
        in library: MusicLibrary,
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

        guard ScraperAvailability.hasEnabledSource else {
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

    private func performSingleScrape(
        song: Song,
        in library: MusicLibrary,
        dryRun: Bool
    ) async throws -> SingleScrapeResult {
        await sidecarCircuitBreaker.resetIdleUnavailableSources()

        guard let result = try await processedSongWithAssets(song, forceRescrape: true, storeAssets: !dryRun) else {
            return SingleScrapeResult(
                originalSong: song,
                song: song,
                coverData: nil,
                lyrics: nil
            )
        }
        var updatedSong = result.song

        // NEVER overwrite existing cover or lyrics with nil
        if updatedSong.coverArtFileName == nil && song.coverArtFileName != nil {
            updatedSong.coverArtFileName = song.coverArtFileName
        }
        if updatedSong.lyricsFileName == nil && song.lyricsFileName != nil {
            updatedSong.lyricsFileName = song.lyricsFileName
        }

        // 重新刮削已有 hash ref 的歌曲时, mergedSong 生成的占位 ref 与现存 ref 完全
        // 相同 (cover/lyrics 文件名是 song.id 的确定性 hash), 且 fillMissingOnline 只补
        // nil 不覆盖 ——  于是 updatedSong == song。但 result 里可能带着刚下载的新封面/
        // 歌词。只要刮到了新资产就必须走缓存/sidecar 写回, 否则用户点「重新刮削」实为无操作。
        let hasNewAssets = result.coverData != nil || (result.lyricsLines?.isEmpty == false)
        if !dryRun && (updatedSong != song || hasNewAssets) {
            // 拿到 lyrics 立即写 hash JSON cache + 把 song.lyricsFileName 改成
            // hash filename (不是 NAS .lrc path) —— 否则 NowPlayingView.loadLyrics
            // 立即跑时, Tier1a cache miss + Tier1b 看 lyricsFileName 含 "/" 走
            // Tier3 从 NAS 拉 line-level .lrc, 用户看到 line-level, 等后续 sidecar
            // task 写 cache 已经晚了 (UI 不会再 reload)。
            let lyricsLines = result.lyricsLines
            let coverData = result.coverData
            let sidecarSettings = Self.sidecarSettings()
            let sidecarCoverData = sidecarSettings.coverEnabled ? coverData : nil
            let sidecarLyricsLines = sidecarSettings.lyricsEnabled ? lyricsLines : nil
            if let coverData {
                await MetadataAssetStore.shared.cacheCover(coverData, forSongID: updatedSong.id)
                updatedSong.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: updatedSong.id)
                CachedArtworkView.invalidateCache(for: updatedSong.id)
            }
            if let lyricsLines, !lyricsLines.isEmpty {
                await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: updatedSong.id, force: true)
                updatedSong.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: updatedSong.id)
            }
            library.replaceSong(updatedSong)

            // Write sidecar files to source (cover.jpg, .lrc) and update Song refs
            plog("📝 Sidecar: coverData=\(sidecarCoverData?.count ?? 0)B lyricsLines=\(sidecarLyricsLines?.count ?? 0) for '\(updatedSong.title)'")
            if sidecarCoverData != nil || sidecarLyricsLines != nil {
                let canWriteSidecar = await sourceManager.supportsSidecarWriting(for: updatedSong)
                if canWriteSidecar {
                    let songForWrite = updatedSong
                    let sourceManager = self.sourceManager
                    let songID = updatedSong.id
                    let sidecarCircuitBreaker = self.sidecarCircuitBreaker
                    let sidecarTask = startSidecarWriteTask {
                        guard await sidecarCircuitBreaker.acquire(sourceID: songForWrite.sourceID) else {
                            return
                        }
                        do {
                            let writeResult = try await MusicScraperService.writeSidecarWithTimeout(
                                seconds: sidecarSettings.timeout,
                                sourceManager: sourceManager,
                                for: songForWrite,
                                coverData: sidecarCoverData, lyricsLines: sidecarLyricsLines
                            )
                            let didOpenCircuit = await sidecarCircuitBreaker.release(
                                sourceID: songForWrite.sourceID,
                                sourceUnavailable: writeResult.sourceUnavailable
                            )
                            if didOpenCircuit {
                                plog("⚠️ Sidecar: source \(songForWrite.sourceID) is read-only or unavailable; later writes are skipped")
                            }
                            plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten) errors=\(writeResult.errors)")

                            var needsUpdate = false
                            var refSong = songForWrite

                            if writeResult.coverWritten {
                                if let coverPath = Self.sidecarReferencePath(for: songForWrite, suffix: "-cover.jpg") {
                                    refSong.coverArtFileName = coverPath
                                    needsUpdate = true
                                }
                                // sidecar 已落盘 —— 现在回写 hash cache 作为可信 mirror
                                if let coverData {
                                    await MetadataAssetStore.shared.cacheCover(coverData, forSongID: songID)
                                }
                            }
                            if writeResult.lyricsWritten, let lyricsLines {
                                // 不让 song.lyricsFileName 指向 NAS .lrc —— .lrc
                                // 是行级备份, 字级数据只在本地 hash JSON 里。
                                // 仍把内容回写到本地 cache 让 hash JSON 跟 NAS
                                // 一致。
                                // 用户动作 (scrape) 触发的 sidecar 镜像写回, 强制覆盖
                                await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: songID, force: true)
                            }

                            guard !Task.isCancelled else { return }
                            if needsUpdate {
                                await MainActor.run {
                                    library.updateAssetReferences(songID: refSong.id, coverRef: refSong.coverArtFileName)
                                }
                            }

                            if !writeResult.errors.isEmpty {
                                plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                            }
                        } catch is CancellationError {
                            _ = await sidecarCircuitBreaker.release(
                                sourceID: songForWrite.sourceID,
                                sourceUnavailable: false
                            )
                            plog("⚠️ Sidecar write timed out (\(sidecarSettings.timeout.finiteInt())s) for '\(songForWrite.title)'")
                        } catch {
                            _ = await sidecarCircuitBreaker.release(
                                sourceID: songForWrite.sourceID,
                                sourceUnavailable: MusicScraperService.isSourceUnavailableSidecarError(error)
                            )
                            plog("⚠️ Sidecar write skipped for '\(songForWrite.title)': \(error.localizedDescription)")
                        }
                    }
                    // Keep the single-song operation inside the same gate until
                    // its sidecar mutation finishes (or times out).
                    await sidecarTask?.value
                } else {
                    plog("📝 Sidecar: source does not support writing, keeping local metadata cache for '\(updatedSong.title)'")
                }
            }

            await writeBackToMediaServerIfSupported(
                original: song,
                updated: updatedSong,
                coverData: result.coverData,
                lyricsLines: result.lyricsLines
            )
        }
        return SingleScrapeResult(
            originalSong: song,
            song: updatedSong,
            coverData: result.coverData,
            lyrics: result.lyricsLines
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

        await MetadataAssetStore.shared.cacheLyrics(lyrics, forSongID: song.id, force: true)
        var updated = song
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
        let identity = ScraperManager.searchTitleArtist(title, artist: artist)
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

    func enqueueBackgroundEnrichment(for songs: [Song], in library: MusicLibrary) {
        let candidates = songs.filter(shouldBackgroundEnrich)
        guard !candidates.isEmpty else { return }

        for song in candidates where pendingEnrichmentSongIDSet.insert(song.id).inserted {
            pendingEnrichmentSongIDs.append(song.id)
        }

        startBackgroundEnrichmentIfNeeded(in: library)
    }

    private func startBackgroundEnrichmentIfNeeded(in library: MusicLibrary) {
        guard !isPausedForSceneTransition,
              !isSingleScraping,
              backgroundEnrichmentTask == nil,
              !pendingEnrichmentSongIDs.isEmpty else { return }
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
        let shouldHoldBackgroundWindow = isScraping
        plog("MusicScraperService: briefly gating publications for scene transition (scraping=\(isScraping))")

        if isScraping {
            cancel(preservingCheckpoint: true)
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

    func resumeAfterSceneTransition(in library: MusicLibrary) {
        isPausedForSceneTransition = false
        plog("MusicScraperService: resuming after foreground scene transition")
        resumePendingScrape(in: library)
        startBackgroundEnrichmentIfNeeded(in: library)
    }

    /// Continue the same scrape in the normal UIApplication background window
    /// once the scene transition itself has settled. BGProcessingTask remains
    /// the longer-running continuation after that finite window expires.
    func resumeBackgroundContinuation(in library: MusicLibrary) {
        isPausedForSceneTransition = false
        plog("MusicScraperService: continuing scrape after background scene settled")
        resumePendingScrape(in: library, allowBackgroundExecution: true)
        startBackgroundEnrichmentIfNeeded(in: library)
    }

    func cancel() {
        cancel(preservingCheckpoint: false)
    }

    /// Used only when iOS expires a background execution window. The current
    /// task stops at an atomic song boundary, while the persisted request is
    /// retained so the next system/foreground opportunity can restart it.
    func cancelPreservingCheckpoint() {
        cancel(preservingCheckpoint: true)
    }

    private func cancel(preservingCheckpoint: Bool) {
        scrapingGeneration += 1
        if preservingCheckpoint, let scrapeCheckpoint {
            writeScrapeCheckpoint(scrapeCheckpoint)
        }
        scrapingTask?.cancel()
        scrapingTask = nil
        cancelSidecarWriteTasks()
        isScraping = false
        currentSongTitle = ""
        endBackgroundTaskIfHeld()
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
        if allowBackgroundExecution {
            isPausedForSceneTransition = false
        }
        guard allowBackgroundExecution || !isPausedForSceneTransition,
              !isScraping,
              let checkpoint = scrapeCheckpoint else { return }
        let songsByID = Dictionary(
            library.visibleSongs.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        // Checkpoints written before result counters were introduced cannot be
        // resumed with an accurate aggregate. Replaying them from the beginning
        // is idempotent and avoids reporting only the tail as the whole result.
        let startIndex = checkpoint.hasPersistedSongCounts
            ? min(max(checkpoint.nextSongIndex, 0), checkpoint.songIDs.count)
            : 0
        let songs = checkpoint.songIDs.compactMap { songsByID[$0] }
        let pendingSongs = checkpoint.songIDs.dropFirst(startIndex).compactMap { songsByID[$0] }
        guard !songs.isEmpty else {
            clearScrapeCheckpoint()
            return
        }
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
        startScraping(songs: library.visibleSongs, in: library, forceRescrape: forceRescrape)
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
        originPlaylistID: String? = nil
    ) -> BatchScrapeStartResult {
        guard !isScraping, !isSingleScraping else {
            plog("MusicScraperService: ignored overlapping batch scrape request")
            return .busy
        }
        guard ScraperAvailability.hasEnabledSource else {
            plog("MusicScraperService: no enabled scraper source, batch scrape not started")
            return .noScraperSource
        }
        guard allowBackgroundExecution || !isPausedForSceneTransition else {
            plog("MusicScraperService: deferred batch scrape during scene transition")
            return .deferred
        }

        let latestByID = Dictionary(library.visibleSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let songs = requestedSongs.reduce(into: (ordered: [Song](), seen: Set<String>())) { result, song in
            guard result.seen.insert(song.id).inserted else { return }
            result.ordered.append(latestByID[song.id] ?? song)
        }.ordered
        guard !songs.isEmpty else { return .empty }
        let pendingSongs = (requestedPendingSongs ?? songs).reduce(
            into: (ordered: [Song](), seen: Set<String>())
        ) { result, song in
            guard result.seen.insert(song.id).inserted else { return }
            result.ordered.append(latestByID[song.id] ?? song)
        }.ordered
        let runID = resumeCheckpoint?.runID ?? UUID()
        let runOriginPlaylistID = resumeCheckpoint?.originPlaylistID ?? originPlaylistID
        if saveCheckpoint {
            persistScrapeCheckpoint(
                songIDs: songs.map(\.id),
                forceRescrape: forceRescrape,
                runID: runID,
                originPlaylistID: runOriginPlaylistID
            )
        } else if var checkpoint = scrapeCheckpoint,
                  checkpoint.runID == nil || checkpoint.originPlaylistID != runOriginPlaylistID {
            // Upgrade checkpoints written by an older build so any later
            // lifecycle resume keeps the same run identity and UI ownership.
            checkpoint.runID = runID
            checkpoint.originPlaylistID = runOriginPlaylistID
            scrapeCheckpoint = checkpoint
            writeScrapeCheckpoint(checkpoint)
        }
        let logicalSongCount = resumeCheckpoint?.songIDs.count ?? songs.count
        updatedCount = resumeCheckpoint?.updatedCount ?? 0
        skippedCount = resumeCheckpoint?.skippedCount ?? 0
        failedCount = resumeCheckpoint?.failedCount ?? 0
        processedCount = updatedCount + skippedCount + failedCount
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
        isScraping = true
        scrapingGeneration += 1
        let generation = scrapingGeneration
        beginBackgroundTaskIfNeeded()

        scrapingTask = Task {
            await sidecarCircuitBreaker.resetIdleUnavailableSources()
            defer {
                let cancelled = Task.isCancelled
                let updated = updatedCount
                let skipped = skippedCount
                let failed = failedCount
                let availableArtwork = artworkAvailableCount
                let unavailableArtwork = artworkUnavailableCount
                let totalArtwork = artworkTotalCount
                if scrapingGeneration == generation {
                    isScraping = false
                    currentSongTitle = ""
                    scrapingTask = nil
                    endBackgroundTaskIfHeld()
                    // Fire the completion notification only when the run actually
                    // finished — cancellation (user hit "stop") shouldn't pop one.
                    if !cancelled {
                        let completion = BatchScrapeCompletion(
                            runID: runID,
                            originPlaylistID: runOriginPlaylistID,
                            songCount: logicalSongCount,
                            updatedCount: updated,
                            skippedCount: skipped,
                            failedCount: failed,
                            artworkTotalCount: totalArtwork,
                            artworkAvailableCount: availableArtwork,
                            artworkUnavailableCount: unavailableArtwork
                        )
                        lastCompletion = completion
                        if let runOriginPlaylistID {
                            pendingPlaylistCompletions[runOriginPlaylistID] = completion
                        }
                        completionRevision &+= 1
                        clearScrapeCheckpoint()
                        Task { @MainActor in
                            await Self.postScrapeCompletionNotification(
                                forceRescrape: forceRescrape,
                                completion: completion
                            )
                        }
                    }
                    activeRunID = nil
                    activeOriginPlaylistID = nil
                }
            }

            let settings = ScraperSettings.load()
            let onlyFillMissing = settings.onlyFillMissingFields && !forceRescrape
            let remoteMetadataSeeds = Self.preferredRemoteMetadataSeeds(in: songs)

            var pendingSongUpdates: [Song] = []
            var pendingSidecarOperations: [@Sendable () async -> Void] = []
            let sidecarCircuitBreaker = self.sidecarCircuitBreaker
            var lastCompletedSongID: String?
            var completedSongCountInBatch = 0

            // The checkpoint is committed only after every library mutation up
            // to that song has been published. Cancellation therefore replays
            // at most this small idempotent batch instead of skipping metadata
            // which existed only in a task-local buffer.
            @MainActor func publishPendingSongBatch() {
                guard let completedSongID = lastCompletedSongID else { return }
                if !pendingSongUpdates.isEmpty {
                    library.replaceSongs(pendingSongUpdates)
                }
                for operation in pendingSidecarOperations {
                    startSidecarWriteTask(operation)
                }
                pendingSongUpdates.removeAll(keepingCapacity: true)
                pendingSidecarOperations.removeAll(keepingCapacity: true)
                lastCompletedSongID = nil
                completedSongCountInBatch = 0
                advanceScrapeCheckpoint(afterCompleting: completedSongID)
            }

            // Phase 1: Scrape song metadata + write sidecar files
            for song in pendingSongs {
                guard !Task.isCancelled else { return }
                var completedCurrentSong = false
                defer {
                    // A lifecycle cancellation means this song may only be
                    // partially written. Leave the checkpoint at the beginning
                    // of its unpublished batch so resume repeats idempotent work
                    // instead of silently skipping task-local mutations.
                    if completedCurrentSong, !Task.isCancelled {
                        if pendingSongUpdates.isEmpty, pendingSidecarOperations.isEmpty {
                            advanceScrapeCheckpoint(afterCompleting: song.id)
                        } else {
                            lastCompletedSongID = song.id
                            completedSongCountInBatch += 1
                            if pendingSongUpdates.count >= Self.songPublicationBatchSize
                                || completedSongCountInBatch >= Self.songPublicationBatchSize {
                                publishPendingSongBatch()
                            }
                        }
                    }
                }

                currentSongTitle = song.title

                do {
                    let remoteIdentitySeed = Self.batchRemoteIdentity(for: song)
                        .flatMap { remoteMetadataSeeds[$0] }
                    guard let result = try await processedSongWithAssets(
                        song,
                        forceRescrape: forceRescrape,
                        remoteIdentitySeed: remoteIdentitySeed
                    ) else {
                        guard !Task.isCancelled else { return }
                        processedCount += 1
                        skippedCount += 1
                        completedCurrentSong = true
                        continue
                    }
                    guard !Task.isCancelled else { return }

                    processedCount += 1
                    var updatedSong = result.song

                    // Determine which assets should be committed based on fill/overwrite mode.
                    let shouldWriteCover: Bool
                    let shouldWriteLyrics: Bool
                    if onlyFillMissing {
                        // Only write if the song was missing cover/lyrics before
                        shouldWriteCover = song.coverArtFileName == nil && result.coverData != nil
                        shouldWriteLyrics = song.lyricsFileName == nil && result.lyricsLines != nil
                    } else {
                        // Overwrite mode: write if we got new data
                        shouldWriteCover = result.coverData != nil
                        shouldWriteLyrics = (result.lyricsLines?.isEmpty == false)
                    }

                    // 重新刮削时占位 hash ref 与现存 ref 相同 → updatedSong == song, 但
                    // 仍可能刮到了新封面/歌词。只要本次模式会落盘新资产, 就进入写回分支,
                    // 否则用户「重新刮削整库」对已有 ref 的歌曲实为无操作。
                    if updatedSong != song || shouldWriteCover || shouldWriteLyrics {
                        let sidecarSettings = Self.sidecarSettings()
                        // 本地 hash cache 写入只看 fill/overwrite 模式, 与 sidecar 写回
                        // 开关解耦 —— 关掉「写 sidecar 封面/歌词」不该让刮到的数据连本地
                        // 缓存都丢失。sidecar 镜像写回另用 *Enabled 开关过滤(对齐 scrapeSingle)。
                        let coverData = shouldWriteCover ? result.coverData : nil
                        let lyricsLines = shouldWriteLyrics ? result.lyricsLines : nil
                        let sidecarCoverData = sidecarSettings.coverEnabled ? coverData : nil
                        let sidecarLyricsLines = sidecarSettings.lyricsEnabled ? lyricsLines : nil

                        if let coverData {
                            await MetadataAssetStore.shared.cacheCover(coverData, forSongID: updatedSong.id)
                            updatedSong.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: updatedSong.id)
                            CachedArtworkView.invalidateCache(for: updatedSong.id)
                        }
                        if let lyricsLines, !lyricsLines.isEmpty {
                            await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: updatedSong.id, force: true)
                            updatedSong.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: updatedSong.id)
                        }

                        guard !Task.isCancelled else { return }
                        pendingSongUpdates.append(updatedSong)
                        updatedCount += 1

                        await writeBackToMediaServerIfSupported(
                            original: song,
                            updated: updatedSong,
                            coverData: coverData,
                            lyricsLines: lyricsLines
                        )
                        guard !Task.isCancelled else { return }

                        if sidecarCoverData != nil || sidecarLyricsLines != nil {
                            let songForWrite = updatedSong
                            let sourceManager = self.sourceManager
                            let songID = updatedSong.id

                            let canWriteSidecar = await sourceManager.supportsSidecarWriting(for: songForWrite)
                            if !canWriteSidecar {
                                plog("📝 Batch sidecar: source does not support writing for '\(songForWrite.title)'")
                            } else {
                                // Start sidecar work only after the matching
                                // library batch is visible. Otherwise a fast
                                // local sidecar write could publish its path and
                                // then be overwritten by the delayed song batch.
                                pendingSidecarOperations.append {
                                    guard await sidecarCircuitBreaker.acquire(sourceID: songForWrite.sourceID) else {
                                        return
                                    }
                                    do {
                                        let writeResult = try await MusicScraperService.writeSidecarWithTimeout(
                                            seconds: sidecarSettings.timeout,
                                            sourceManager: sourceManager,
                                            for: songForWrite,
                                            coverData: sidecarCoverData, lyricsLines: sidecarLyricsLines
                                        )
                                        let didOpenCircuit = await sidecarCircuitBreaker.release(
                                            sourceID: songForWrite.sourceID,
                                            sourceUnavailable: writeResult.sourceUnavailable
                                        )

                                        if didOpenCircuit {
                                            plog("⚠️ Batch sidecar: source \(songForWrite.sourceID) is read-only or unavailable; remaining writes skipped for this run")
                                        }

                                        var needsUpdate = false
                                        var refSong = songForWrite

                                        if writeResult.coverWritten {
                                            if let coverPath = Self.sidecarReferencePath(for: songForWrite, suffix: "-cover.jpg") {
                                                refSong.coverArtFileName = coverPath
                                                needsUpdate = true
                                            }
                                            if let coverData {
                                                await MetadataAssetStore.shared.cacheCover(coverData, forSongID: songID)
                                            }
                                        }
                                        if writeResult.lyricsWritten, let lyricsLines {
                                            // 同上: 不指向 NAS .lrc, 字级数据只在
                                            // 本地 hash JSON。
                                            // 用户动作 (scrape) 触发的 sidecar 镜像写回, 强制覆盖
                                            await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: songID, force: true)
                                        }

                                        guard !Task.isCancelled else { return }
                                        if needsUpdate {
                                            await MainActor.run {
                                                library.updateAssetReferences(songID: refSong.id, coverRef: refSong.coverArtFileName)
                                            }
                                        }

                                        if !writeResult.errors.isEmpty {
                                            plog("⚠️ Batch sidecar errors for '\(songForWrite.title)': \(writeResult.errors)")
                                        }
                                    } catch is CancellationError {
                                        _ = await sidecarCircuitBreaker.release(
                                            sourceID: songForWrite.sourceID,
                                            sourceUnavailable: false
                                        )
                                        plog("⚠️ Batch sidecar timed out (\(sidecarSettings.timeout.finiteInt())s) for '\(songForWrite.title)'")
                                    } catch {
                                        let sourceUnavailable = MusicScraperService.isSourceUnavailableSidecarError(error)
                                        let didOpenCircuit = await sidecarCircuitBreaker.release(
                                            sourceID: songForWrite.sourceID,
                                            sourceUnavailable: sourceUnavailable
                                        )
                                        if didOpenCircuit {
                                            plog("⚠️ Batch sidecar: source \(songForWrite.sourceID) is unavailable; remaining writes skipped for this run")
                                        }
                                        plog("⚠️ Batch sidecar skipped for '\(songForWrite.title)': \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                    } else {
                        skippedCount += 1
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    processedCount += 1
                    failedCount += 1
                }
                completedCurrentSong = true
            }

            // Publish a short tail before derived album/artist work and before
            // declaring the scrape complete.
            publishPendingSongBatch()
            finishScrapeSongPhaseCheckpoint()

            // Phase 2: Scrape album and artist covers
            guard !Task.isCancelled else { return }

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

            let resumedTargetIDs = resumeCheckpoint?.artworkTargetIDs
            let targetIDs: [String]
            if let resumedTargetIDs {
                targetIDs = resumedTargetIDs
            } else {
                let albumIDs = albumsInScope.compactMap { album -> String? in
                    guard forceRescrape || !assetStore.hasAlbumCover(forAlbumID: album.id) else { return nil }
                    return Self.albumArtworkTargetID(album.id)
                }
                let artistIDs = artistsInScope.compactMap { artist -> String? in
                    guard forceRescrape || !assetStore.hasArtistImage(forArtistID: artist.id) else { return nil }
                    return Self.artistArtworkTargetID(artist.id)
                }
                targetIDs = albumIDs + artistIDs
            }

            let targetIDSet = Set(targetIDs)
            var availableIDs = Set<String>()
            if !forceRescrape {
                for targetID in targetIDs {
                    if Self.isArtworkAvailable(targetID: targetID, in: assetStore) {
                        availableIDs.insert(targetID)
                    }
                }
            }

            let albumsNeedingCover = albumsInScope.filter { album in
                let targetID = Self.albumArtworkTargetID(album.id)
                return targetIDSet.contains(targetID)
                    && (forceRescrape || !availableIDs.contains(targetID))
            }
            let artistsNeedingImage = artistsInScope.filter { artist in
                let targetID = Self.artistArtworkTargetID(artist.id)
                return targetIDSet.contains(targetID)
                    && (forceRescrape || !availableIDs.contains(targetID))
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
                artistsNeedingImage: artistsNeedingImage
            )
        }
        return .started(runID: runID, songCount: logicalSongCount)
    }

    private func persistScrapeCheckpoint(
        songIDs: [String],
        forceRescrape: Bool,
        runID: UUID,
        originPlaylistID: String?
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
            originPlaylistID: originPlaylistID
        )
        scrapeCheckpoint = checkpoint
        writeScrapeCheckpoint(checkpoint)
    }

    private func writeScrapeCheckpoint(_ checkpoint: ScrapeCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: scrapeCheckpointURL, options: .atomic)
    }

    private func advanceScrapeCheckpoint(afterCompleting songID: String) {
        guard var checkpoint = scrapeCheckpoint,
              let completedIndex = checkpoint.songIDs.firstIndex(of: songID) else { return }

        checkpoint.nextSongIndex = min(completedIndex + 1, checkpoint.songIDs.count)
        checkpoint.updatedCount = updatedCount
        checkpoint.skippedCount = skippedCount
        checkpoint.failedCount = failedCount
        scrapeCheckpoint = checkpoint

        // Network scraping is much slower than this write, but avoid rewriting
        // a potentially large ID list after every track. Expiration handling
        // flushes the latest in-memory index before cancelling.
        if completedIndex.isMultiple(of: 10) || completedIndex == checkpoint.songIDs.count - 1 {
            writeScrapeCheckpoint(checkpoint)
        }
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
        scrapeCheckpoint = checkpoint
        writeScrapeCheckpoint(checkpoint)
    }

    private func updateArtworkCheckpoint(forceWrite: Bool = false) {
        guard var checkpoint = scrapeCheckpoint else { return }
        checkpoint.artworkTargetIDs = artworkTargetIDs
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

    private func cancelSidecarWriteTasks() {
        let tasks = sidecarWriteTasks.values
        sidecarWriteTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }
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
            Task { @MainActor [weak self] in
                self?.cancelPreservingCheckpoint()
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
        var body = String(
            format: String(localized: "batch_scrape_completed_format"),
            completion.processedSongCount,
            completion.songCount,
            completion.updatedCount,
            completion.skippedCount,
            completion.failedCount
        )
        if completion.artworkTotalCount > 0 {
            body += "\n" + String(
                format: String(localized: "batch_scrape_completed_artwork_format"),
                completion.artworkAvailableCount,
                completion.artworkTotalCount,
                completion.artworkUnavailableCount
            )
        }
        await UserNotificationService.shared.postLongTaskCompletion(
            category: forceRescrape ? .rescrapeLibraryDone : .scrapeMissingDone,
            title: title,
            body: body
        )
    }

    /// Batch-fetch album covers and artist images for items missing artwork.
    private func scrapeAlbumAndArtistCovers(
        in library: MusicLibrary,
        albumsNeedingCover: [Album],
        artistsNeedingImage: [Artist]
    ) async {
        let artworkService = ArtworkFetchService.shared
        let assetStore = MetadataAssetStore.shared

        // Albums without cached cover
        if !albumsNeedingCover.isEmpty {
            plog("🎨 Scraping covers for \(albumsNeedingCover.count) albums...")
            currentSongTitle = String(localized: "scraping_album_covers")
            for album in albumsNeedingCover {
                guard !Task.isCancelled else { return }
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
                currentSongTitle = artist.name
                _ = await artworkService.fetchArtistImage(
                    artistName: artist.name, artistID: artist.id
                )
                guard !Task.isCancelled else { return }
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
        in assetStore: MetadataAssetStore
    ) -> Bool {
        if targetID.hasPrefix("album:") {
            return assetStore.hasAlbumCover(forAlbumID: String(targetID.dropFirst(6)))
        }
        if targetID.hasPrefix("artist:") {
            return assetStore.hasArtistImage(forArtistID: String(targetID.dropFirst(7)))
        }
        return false
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

    private struct ProcessedResult {
        let song: Song
        let coverData: Data?
        let lyricsLines: [LyricLine]?
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

    private nonisolated static func preferredRemoteMetadataSeeds(
        in songs: [Song]
    ) -> [BatchRemoteIdentity: Song] {
        var seeds: [BatchRemoteIdentity: Song] = [:]
        for song in songs {
            guard let identity = batchRemoteIdentity(for: song) else { continue }
            if let existing = seeds[identity],
               metadataSeedScore(existing) >= metadataSeedScore(song) {
                continue
            }
            seeds[identity] = song
        }
        return seeds
    }

    private func processedSongWithAssets(
        _ song: Song,
        forceRescrape: Bool,
        storeAssets: Bool = true,
        remoteIdentitySeed: Song? = nil
    ) async throws -> ProcessedResult? {
        // 服务端曲库源(Subsonic/Navidrome、Jellyfin/Emby/Plex): 元数据以服务端为
        // 权威, 自动刮削只「补空缺、绝不覆盖」。不读(可能转码的)音频流 —— 用歌曲
        // 已有 title/artist/album 直接查在线源, 只填 nil/空 的 artist/album/year/
        // genre。封面(getCoverArt)/歌词(getLyricsBySongId)由服务端提供, 不让在线
        // 刮削用脏标题错配盖掉, 因此不补 cover/lyrics。即使是「重新刮削」(forceRescrape)
        // 也只补空缺, 不覆盖已有值。
        if await sourceManager.isServerLibrarySource(for: song) {
            let needsMeta = (song.artistName?.isEmpty ?? true)
                || (song.albumTitle?.isEmpty ?? true)
                || song.year == nil
                || (song.genre?.isEmpty ?? true)
            guard needsMeta else { return nil }
            let metadata = await metadataService.fillMissingOnline(
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                year: song.year,
                genre: song.genre,
                duration: song.duration
            )
            let merged = filledServerSong(song, with: metadata)
            guard merged != song else { return nil }
            return ProcessedResult(song: merged, coverData: nil, lyricsLines: nil)
        }

        let fallbackTitle = await resolvedScrapeFallbackTitle(for: song)
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
        let fileURL = shouldResolvePlaybackURL
            ? try await sourceManager.resolveURL(for: song)
            : nil
        let placeholderTitle = fileURL?.deletingPathExtension().lastPathComponent ?? fallbackTitle

        guard forceRescrape || needsScrape(song: song, placeholderTitle: placeholderTitle) else {
            return nil
        }

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
                forceOnlineRefresh: forceRescrape
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
            var seededMetadata = await metadataService.fillMissingOnline(
                title: identitySeed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackTitle
                    : identitySeed.title,
                artist: identitySeed.artistName,
                album: identitySeed.albumTitle,
                year: identitySeed.year,
                genre: identitySeed.genre,
                duration: identitySeed.duration,
                needsCover: forceRescrape || song.coverArtFileName == nil,
                needsLyrics: forceRescrape || song.lyricsFileName == nil,
                forceMetadataRefresh: forceRescrape,
                overwriteMetadata: forceRescrape
            )
            seededMetadata.duration = identitySeed.duration
            seededMetadata.sampleRate = identitySeed.sampleRate
            seededMetadata.bitRate = identitySeed.bitRate
            seededMetadata.bitDepth = identitySeed.bitDepth
            metadata = seededMetadata
        }
        let merged = mergedSong(
            song,
            with: metadata,
            placeholderTitle: placeholderTitle,
            forceRescrape: forceRescrape
        )
        return ProcessedResult(song: merged, coverData: metadata.coverArtData, lyricsLines: metadata.lyrics)
    }

    private func runBackgroundEnrichment(in library: MusicLibrary) async {
        isBackgroundEnriching = true

        var pendingSongUpdates: [Song] = []
        @MainActor func publishPendingSongUpdates() {
            guard !pendingSongUpdates.isEmpty else { return }
            library.replaceSongs(pendingSongUpdates)
            pendingSongUpdates.removeAll(keepingCapacity: true)
        }

        defer {
            if Task.isCancelled {
                // Scene-transition cancellation intentionally does not publish
                // a partial full-library batch. Put those ids back so the
                // resumed worker repeats the idempotent enrichment instead of
                // dropping results which were only task-local.
                for songID in pendingSongUpdates.map(\.id).reversed()
                    where pendingEnrichmentSongIDSet.insert(songID).inserted {
                    pendingEnrichmentSongIDs.insert(songID, at: 0)
                }
            }
            backgroundEnrichmentTask = nil
            isBackgroundEnriching = false
        }

        while !Task.isCancelled {
            if isScraping {
                // Don't leave completed enrichment results task-local while a
                // user-initiated scrape waits for this worker to yield.
                publishPendingSongUpdates()
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard let song = nextSongForBackgroundEnrichment(in: library) else {
                publishPendingSongUpdates()
                return
            }

            do {
                guard let result = try await processedSongWithAssets(song, forceRescrape: false) else {
                    continue
                }
                guard !Task.isCancelled else { return }

                if result.song != song {
                    // processedSongWithAssets 用 trustedSource:false, merged song 里的
                    // coverArtFileName/lyricsFileName 只是占位 hash ref, 文件还没落盘。
                    // 必须在 replaceSong 前把 coverData/lyricsLines 真正写进 hash cache,
                    // 否则库里的 ref 会指向不存在的文件, 且数据被丢弃。
                    var enrichedSong = result.song
                    if let coverData = result.coverData {
                        await MetadataAssetStore.shared.cacheCover(coverData, forSongID: enrichedSong.id)
                        enrichedSong.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: enrichedSong.id)
                        CachedArtworkView.invalidateCache(for: enrichedSong.id)
                    } else {
                        // 没拿到新封面 —— 别把占位 ref 持久化, 退回原始 ref。
                        enrichedSong.coverArtFileName = song.coverArtFileName
                    }
                    var lyricsCached = false
                    if let lyricsLines = result.lyricsLines, !lyricsLines.isEmpty {
                        lyricsCached = await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: enrichedSong.id, force: false)
                    }
                    if lyricsCached {
                        enrichedSong.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: enrichedSong.id)
                    } else {
                        enrichedSong.lyricsFileName = song.lyricsFileName
                    }

                    guard !Task.isCancelled else { return }
                    if enrichedSong != song {
                        pendingSongUpdates.append(enrichedSong)
                        await writeBackToMediaServerIfSupported(
                            original: song,
                            updated: enrichedSong,
                            coverData: result.coverData,
                            lyricsLines: result.lyricsLines
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

    private func nextSongForBackgroundEnrichment(in library: MusicLibrary) -> Song? {
        while let songID = pendingEnrichmentSongIDs.first {
            pendingEnrichmentSongIDs.removeFirst()
            pendingEnrichmentSongIDSet.remove(songID)

            if let song = library.visibleSong(id: songID) {
                return song
            }
        }

        return nil
    }

    private func shouldBackgroundEnrich(_ song: Song) -> Bool {
        let settings = ScraperSettings.load()
        if settings.onlyFillMissingFields == false {
            return true
        }

        return song.artistName?.isEmpty ?? true
            || song.albumTitle?.isEmpty ?? true
            || song.year == nil
            || song.genre?.isEmpty ?? true
            || song.coverArtFileName == nil
            || song.lyricsFileName == nil
    }

    private func processedSong(_ song: Song, forceRescrape: Bool) async throws -> Song? {
        guard let result = try await processedSongWithAssets(song, forceRescrape: forceRescrape) else {
            return nil
        }
        return result.song
    }

    private func needsScrape(song: Song, placeholderTitle: String) -> Bool {
        let settings = ScraperSettings.load()

        let needsTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || song.title == placeholderTitle
        let needsArtist = (song.artistName?.isEmpty ?? true)
        let needsAlbum = (song.albumTitle?.isEmpty ?? true)
        let needsYear = song.year == nil
        let needsGenre = (song.genre?.isEmpty ?? true)
        let needsCover = song.coverArtFileName == nil
        let needsLyrics = song.lyricsFileName == nil

        if settings.onlyFillMissingFields == false {
            return true
        }

        return needsTitle || needsArtist || needsAlbum || needsYear || needsGenre || needsCover || needsLyrics
    }

    private func resolvedScrapeFallbackTitle(for song: Song) async -> String {
        let local = Self.scrapeFallbackTitle(for: song)
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
        return digits >= 6 || separators >= 2 || trimmed.count >= 24
    }

    /// 服务端源专用的严格「只补空缺」合并 —— 只填 nil/空 的
    /// artist/album/year/genre/track/disc。标题、时长、采样率等服务端权威字段
    /// 一律不动; 封面/歌词也不碰(由服务端提供)。
    private func filledServerSong(_ song: Song, with m: MetadataService.SongMetadata) -> Song {
        var s = song
        if (s.artistName?.isEmpty ?? true), let v = m.artist, !v.isEmpty { s.artistName = v }
        if (s.albumTitle?.isEmpty ?? true), let v = m.albumTitle, !v.isEmpty { s.albumTitle = v }
        if s.year == nil { s.year = m.year }
        if (s.genre?.isEmpty ?? true), let v = m.genre, !v.isEmpty { s.genre = v }
        if s.trackNumber == nil { s.trackNumber = m.trackNumber }
        if s.discNumber == nil { s.discNumber = m.discNumber }
        return s
    }

    private func mergedSong(
        _ song: Song,
        with metadata: MetadataService.SongMetadata,
        placeholderTitle: String,
        forceRescrape: Bool
    ) -> Song {
        let settings = ScraperSettings.load()
        let onlyFillMissing = settings.onlyFillMissingFields && !forceRescrape

        let titleNeedsUpdate = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || song.title == placeholderTitle
        let artistNeedsUpdate = song.artistName == nil || song.artistName?.isEmpty == true
        let albumNeedsUpdate = song.albumTitle == nil || song.albumTitle?.isEmpty == true
        let yearNeedsUpdate = song.year == nil
        let genreNeedsUpdate = song.genre == nil || song.genre?.isEmpty == true
        let coverNeedsUpdate = song.coverArtFileName == nil || onlyFillMissing == false
        let lyricsNeedsUpdate = song.lyricsFileName == nil || onlyFillMissing == false
        let candidateTitle = onlyFillMissing
            ? (titleNeedsUpdate ? metadata.title : song.title)
            : metadata.title
        let scrapedTitle = candidateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? song.title
            : candidateTitle
        // A CUE row is a virtual track inside a shared physical audio file.
        // File/online metadata describes that physical image and must not turn
        // every segment into the same basename during a forced library scrape.
        // Keep the CUE sheet's non-empty title/artist/album identity while still
        // allowing missing optional values and artwork/lyrics to be filled.
        let resolvedTitle = ScrapeCueIdentityPolicy.resolvedTitle(
            original: song.title,
            scraped: scrapedTitle,
            isCueTrack: song.isCueTrack
        )

        // Mutate the original value instead of reconstructing Song. Besides
        // being safer when the model gains fields, this preserves CUE virtual
        // track boundaries and ReplayGain/search metadata during scraping.
        var merged = song
        merged.title = resolvedTitle
        let scrapedAlbum = onlyFillMissing
            ? (albumNeedsUpdate ? metadata.albumTitle ?? song.albumTitle : song.albumTitle)
            : (metadata.albumTitle ?? song.albumTitle)
        merged.albumTitle = ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: song.albumTitle,
            scraped: scrapedAlbum,
            isCueTrack: song.isCueTrack
        )
        let scrapedArtist = onlyFillMissing
            ? (artistNeedsUpdate ? metadata.artist ?? song.artistName : song.artistName)
            : (metadata.artist ?? song.artistName)
        merged.artistName = ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: song.artistName,
            scraped: scrapedArtist,
            isCueTrack: song.isCueTrack
        )
        merged.trackNumber = song.trackNumber ?? metadata.trackNumber
        merged.discNumber = song.discNumber ?? metadata.discNumber
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
        merged.genre = onlyFillMissing
            ? (genreNeedsUpdate ? metadata.genre ?? song.genre : song.genre)
            : (metadata.genre ?? song.genre)
        merged.year = onlyFillMissing
            ? (yearNeedsUpdate ? metadata.year ?? song.year : song.year)
            : (metadata.year ?? song.year)
        merged.coverArtFileName = coverNeedsUpdate
            ? (metadata.coverArtFileName ?? song.coverArtFileName)
            : song.coverArtFileName
        merged.lyricsFileName = lyricsNeedsUpdate
            ? (metadata.lyricsFileName ?? song.lyricsFileName)
            : song.lyricsFileName
        merged.mvPath = metadata.mvPath ?? song.mvPath
        return merged
    }

    nonisolated static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String? = nil
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
                    lyricsContent: lyricsContent
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

    nonisolated static func preflightLyricsWriteWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song
    ) async throws -> SidecarWriteService.LyricsPreflightResult {
        try await withThrowingTaskGroup(of: SidecarWriteService.LyricsPreflightResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                return try await SidecarWriteService.shared.preflightLyricsWrite(
                    for: song,
                    using: connector
                )
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

    nonisolated static func removeLyricsSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song
    ) async throws -> SidecarWriteService.WriteResult {
        try await withThrowingTaskGroup(of: SidecarWriteService.WriteResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                let result = await SidecarWriteService.shared.removeLyrics(for: song, using: connector)
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

    private nonisolated static func isSourceUnavailableSidecarError(_ error: Error) -> Bool {
        guard let sourceError = error as? SourceError else { return false }
        if case .authenticationFailed = sourceError {
            return true
        }
        return false
    }

    private func writeBackToMediaServerIfSupported(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?
    ) async {
        guard await sourceManager.supportsMediaServerWriteback(for: updated) else {
            return
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
