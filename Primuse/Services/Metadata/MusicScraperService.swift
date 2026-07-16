import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class MusicScraperService {
    nonisolated static let sidecarCoverWriteEnabledKey = "primuse.sidecar.coverWriteEnabled"
    nonisolated static let sidecarLyricsWriteEnabledKey = "primuse.sidecar.lyricsWriteEnabled"
    nonisolated static let sidecarWriteTimeoutKey = "primuse.sidecar.writeTimeout"

    private let sourceManager: SourceManager
    private let metadataService = MetadataService()
    private var scrapingTask: Task<Void, Never>?
    private var scrapingGeneration = 0
    private var backgroundEnrichmentTask: Task<Void, Never>?
    private var pendingEnrichmentSongIDs: [String] = []
    private var pendingEnrichmentSongIDSet: Set<String> = []
    private let scrapeCheckpointURL: URL
    private var scrapeCheckpoint: ScrapeCheckpoint?
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    private struct ScrapeCheckpoint: Codable {
        var songIDs: [String]
        var forceRescrape: Bool
        var nextSongIndex: Int
    }

    private(set) var isScraping = false
    private(set) var isBackgroundEnriching = false
    private(set) var currentSongTitle = ""
    private(set) var processedCount = 0
    private(set) var totalCount = 0
    private(set) var updatedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0

    init(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }

    func scrapeMissingMetadata(in library: MusicLibrary) {
        startScraping(in: library, forceRescrape: false)
    }

    func scrapeMissingMetadata(songs: [Song], in library: MusicLibrary) {
        startScraping(songs: songs, in: library, forceRescrape: false)
    }

    func rescrapeLibrary(in library: MusicLibrary) {
        startScraping(in: library, forceRescrape: true)
    }

    /// Scrape single song — never overwrites existing cover/lyrics with nil
    /// dryRun: if true, returns updated song without writing to library
    func scrapeSingle(song: Song, in library: MusicLibrary, dryRun: Bool = false) async throws -> (Song, Data?, [LyricLine]?) {
        guard let result = try await processedSongWithAssets(song, forceRescrape: true, storeAssets: !dryRun) else {
            return (song, nil, nil)
        }
        var updatedSong = result.song

        // NEVER overwrite existing cover or lyrics with nil
        if updatedSong.coverArtFileName == nil && song.coverArtFileName != nil {
            updatedSong = Song(
                id: updatedSong.id, title: updatedSong.title,
                albumID: updatedSong.albumID, artistID: updatedSong.artistID,
                albumTitle: updatedSong.albumTitle, artistName: updatedSong.artistName,
                trackNumber: updatedSong.trackNumber, discNumber: updatedSong.discNumber,
                duration: updatedSong.duration, fileFormat: updatedSong.fileFormat,
                filePath: updatedSong.filePath, sourceID: updatedSong.sourceID,
                fileSize: updatedSong.fileSize, bitRate: updatedSong.bitRate,
                sampleRate: updatedSong.sampleRate, bitDepth: updatedSong.bitDepth,
                genre: updatedSong.genre, year: updatedSong.year,
                dateAdded: updatedSong.dateAdded,
                coverArtFileName: song.coverArtFileName,
                lyricsFileName: updatedSong.lyricsFileName ?? song.lyricsFileName,
                mvPath: updatedSong.mvPath ?? song.mvPath,
                revision: updatedSong.revision ?? song.revision
            )
        }
        if updatedSong.lyricsFileName == nil && song.lyricsFileName != nil {
            updatedSong = Song(
                id: updatedSong.id, title: updatedSong.title,
                albumID: updatedSong.albumID, artistID: updatedSong.artistID,
                albumTitle: updatedSong.albumTitle, artistName: updatedSong.artistName,
                trackNumber: updatedSong.trackNumber, discNumber: updatedSong.discNumber,
                duration: updatedSong.duration, fileFormat: updatedSong.fileFormat,
                filePath: updatedSong.filePath, sourceID: updatedSong.sourceID,
                fileSize: updatedSong.fileSize, bitRate: updatedSong.bitRate,
                sampleRate: updatedSong.sampleRate, bitDepth: updatedSong.bitDepth,
                genre: updatedSong.genre, year: updatedSong.year,
                dateAdded: updatedSong.dateAdded,
                coverArtFileName: updatedSong.coverArtFileName,
                lyricsFileName: song.lyricsFileName,
                mvPath: updatedSong.mvPath ?? song.mvPath,
                revision: updatedSong.revision ?? song.revision
            )
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
                    Task.detached(priority: .utility) {
                        do {
                            let writeResult = try await MusicScraperService.writeSidecarWithTimeout(
                                seconds: sidecarSettings.timeout,
                                sourceManager: sourceManager,
                                for: songForWrite,
                                coverData: sidecarCoverData, lyricsLines: sidecarLyricsLines
                            )
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

                        if needsUpdate {
                            await MainActor.run {
                                library.updateAssetReferences(songID: refSong.id, coverRef: refSong.coverArtFileName)
                            }
                        }

                            if !writeResult.errors.isEmpty {
                                plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                            }
                        } catch is CancellationError {
                            plog("⚠️ Sidecar write timed out (\(Int(sidecarSettings.timeout))s) for '\(songForWrite.title)'")
                        } catch {
                            plog("⚠️ Sidecar write skipped for '\(songForWrite.title)': \(error.localizedDescription)")
                        }
                    }
                } else {
                    plog("📝 Sidecar: source does not support writing, keeping local metadata cache for '\(updatedSong.title)'")
                }
            }
        }
        return (updatedSong, result.coverData, result.lyricsLines)
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

    nonisolated static func searchQuery(title: String, artist: String?) -> String {
        var query = ScraperManager.searchTitle(title, artist: artist)
        if let artist,
           !artist.isEmpty,
           ScraperManager.shouldAppendArtist(to: query, artist: artist) {
            query += " \(artist)"
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

        guard backgroundEnrichmentTask == nil else { return }
        backgroundEnrichmentTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.runBackgroundEnrichment(in: library)
        }
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
        isScraping = false
        currentSongTitle = ""
        endBackgroundTaskIfHeld()
        if !preservingCheckpoint {
            clearScrapeCheckpoint()
        }
    }

    func resumePendingScrape(in library: MusicLibrary) {
        guard !isScraping, let checkpoint = scrapeCheckpoint else { return }
        let songsByID = Dictionary(uniqueKeysWithValues: library.visibleSongs.map { ($0.id, $0) })
        let startIndex = min(max(checkpoint.nextSongIndex, 0), checkpoint.songIDs.count)
        let songs = checkpoint.songIDs.dropFirst(startIndex).compactMap { songsByID[$0] }
        guard !songs.isEmpty else {
            clearScrapeCheckpoint()
            return
        }
        startScraping(
            songs: songs,
            in: library,
            forceRescrape: checkpoint.forceRescrape,
            saveCheckpoint: false
        )
    }

    func waitUntilScrapeIdle() async {
        while isScraping {
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func startScraping(in library: MusicLibrary, forceRescrape: Bool) {
        startScraping(songs: library.visibleSongs, in: library, forceRescrape: forceRescrape)
    }

    private func startScraping(
        songs requestedSongs: [Song],
        in library: MusicLibrary,
        forceRescrape: Bool,
        saveCheckpoint: Bool = true
    ) {
        guard !isScraping else { return }

        let latestByID = Dictionary(library.visibleSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let songs = requestedSongs.reduce(into: (ordered: [Song](), seen: Set<String>())) { result, song in
            guard result.seen.insert(song.id).inserted else { return }
            result.ordered.append(latestByID[song.id] ?? song)
        }.ordered
        guard !songs.isEmpty else { return }
        if saveCheckpoint {
            persistScrapeCheckpoint(songIDs: songs.map(\.id), forceRescrape: forceRescrape)
        }
        totalCount = songs.count
        processedCount = 0
        updatedCount = 0
        skippedCount = 0
        failedCount = 0
        currentSongTitle = ""
        isScraping = true
        scrapingGeneration += 1
        let generation = scrapingGeneration
        beginBackgroundTaskIfNeeded()

        scrapingTask = Task {
            defer {
                let cancelled = Task.isCancelled
                let updated = updatedCount
                let failed = failedCount
                if scrapingGeneration == generation {
                    isScraping = false
                    currentSongTitle = ""
                    scrapingTask = nil
                    endBackgroundTaskIfHeld()
                    // Fire the completion notification only when the run actually
                    // finished — cancellation (user hit "stop") shouldn't pop one.
                    if !cancelled {
                        clearScrapeCheckpoint()
                        Task { @MainActor in
                            await Self.postScrapeCompletionNotification(
                                forceRescrape: forceRescrape,
                                updatedCount: updated,
                                failedCount: failed
                            )
                        }
                    }
                }
            }

            let settings = ScraperSettings.load()
            let onlyFillMissing = settings.onlyFillMissingFields && !forceRescrape

            // Phase 1: Scrape song metadata + write sidecar files
            for song in songs {
                guard !Task.isCancelled else { return }
                defer { advanceScrapeCheckpoint(afterCompleting: song.id) }

                currentSongTitle = song.title

                do {
                    guard let result = try await processedSongWithAssets(song, forceRescrape: forceRescrape) else {
                        processedCount += 1
                        skippedCount += 1
                        continue
                    }

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

                        library.replaceSong(updatedSong)
                        updatedCount += 1

                        if sidecarCoverData != nil || sidecarLyricsLines != nil {
                            let songForWrite = updatedSong
                            let sourceManager = self.sourceManager
                            let songID = updatedSong.id

                            let canWriteSidecar = await sourceManager.supportsSidecarWriting(for: songForWrite)
                            guard canWriteSidecar else {
                                plog("📝 Batch sidecar: source does not support writing for '\(songForWrite.title)'")
                                continue
                            }

                            // Write sidecar files to source asynchronously (don't block scraping loop)
                            Task.detached(priority: .utility) {
                                do {
                                    let writeResult = try await MusicScraperService.writeSidecarWithTimeout(
                                        seconds: sidecarSettings.timeout,
                                        sourceManager: sourceManager,
                                        for: songForWrite,
                                        coverData: sidecarCoverData, lyricsLines: sidecarLyricsLines
                                    )

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

                                    if needsUpdate {
                                        await MainActor.run {
                                            library.updateAssetReferences(songID: refSong.id, coverRef: refSong.coverArtFileName)
                                        }
                                    }

                                    if !writeResult.errors.isEmpty {
                                        plog("⚠️ Batch sidecar errors for '\(songForWrite.title)': \(writeResult.errors)")
                                    }
                                } catch is CancellationError {
                                    plog("⚠️ Batch sidecar timed out (\(Int(sidecarSettings.timeout))s) for '\(songForWrite.title)'")
                                } catch {
                                    plog("⚠️ Batch sidecar skipped for '\(songForWrite.title)': \(error.localizedDescription)")
                                }
                            }
                        }
                    } else {
                        skippedCount += 1
                    }
                } catch {
                    processedCount += 1
                    failedCount += 1
                }

            }

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
            let albumsNeedingCover = library.visibleAlbums.filter { album in
                (isWholeVisibleLibrary || targetAlbumIDs.contains(album.id))
                    && !assetStore.hasAlbumCover(forAlbumID: album.id)
            }
            let artistsNeedingImage = library.visibleArtists.filter { artist in
                let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return (isWholeVisibleLibrary || targetArtistIDs.contains(artist.id) || targetArtistNames.contains(name))
                    && !assetStore.hasArtistImage(forArtistID: artist.id)
            }
            totalCount += albumsNeedingCover.count + artistsNeedingImage.count

            await scrapeAlbumAndArtistCovers(
                in: library,
                albumsNeedingCover: albumsNeedingCover,
                artistsNeedingImage: artistsNeedingImage
            )
        }
    }

    private func persistScrapeCheckpoint(songIDs: [String], forceRescrape: Bool) {
        let checkpoint = ScrapeCheckpoint(songIDs: songIDs, forceRescrape: forceRescrape, nextSongIndex: 0)
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

        // Keep the final song as a lightweight sentinel while album/artist
        // artwork is still being processed. If iOS kills us in phase 2, the
        // next run repeats at most that one song and then safely resumes the
        // derived artwork pass.
        checkpoint.nextSongIndex = min(completedIndex + 1, max(checkpoint.songIDs.count - 1, 0))
        scrapeCheckpoint = checkpoint

        // Network scraping is much slower than this write, but avoid rewriting
        // a potentially large ID list after every track. Expiration handling
        // flushes the latest in-memory index before cancelling.
        if completedIndex.isMultiple(of: 10) || completedIndex == checkpoint.songIDs.count - 1 {
            writeScrapeCheckpoint(checkpoint)
        }
    }

    private func clearScrapeCheckpoint() {
        scrapeCheckpoint = nil
        try? FileManager.default.removeItem(at: scrapeCheckpointURL)
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
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
        updatedCount: Int,
        failedCount: Int
    ) async {
        let titleKey = forceRescrape
            ? "notify_rescrape_done_title"
            : "notify_scrape_missing_done_title"
        let title = String(localized: String.LocalizationValue(titleKey))
        let body: String
        if failedCount > 0 {
            let format = String(localized: "notify_scrape_done_body_with_failures")
            body = String(format: format, updatedCount, failedCount)
        } else {
            let format = String(localized: "notify_scrape_done_body")
            body = String(format: format, updatedCount)
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
                processedCount += 1
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
                processedCount += 1
            }
        }
    }

    private struct ProcessedResult {
        let song: Song
        let coverData: Data?
        let lyricsLines: [LyricLine]?
    }

    private func processedSongWithAssets(_ song: Song, forceRescrape: Bool, storeAssets: Bool = true) async throws -> ProcessedResult? {
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

        let fileURL = try await sourceManager.resolveURL(for: song)
        let placeholderTitle = fileURL.deletingPathExtension().lastPathComponent

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
        let fallbackTitle = await resolvedScrapeFallbackTitle(for: song)
        let metadata = await metadataService.loadMetadata(
            for: fileURL,
            cacheKey: storeAssets ? song.id : nil,
            trustedSource: false,
            fallbackTitle: fallbackTitle
        )
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

        defer {
            backgroundEnrichmentTask = nil
            isBackgroundEnriching = false
        }

        while !Task.isCancelled {
            if isScraping {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard let song = nextSongForBackgroundEnrichment(in: library) else {
                return
            }

            do {
                guard let result = try await processedSongWithAssets(song, forceRescrape: false) else {
                    continue
                }

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

                    if enrichedSong != song {
                        library.replaceSong(enrichedSong)
                    }
                }
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

            if let song = library.visibleSongs.first(where: { $0.id == songID }) {
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
        let resolvedTitle = candidateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? song.title
            : candidateTitle

        return Song(
            id: song.id,
            title: resolvedTitle,
            albumID: song.albumID,
            artistID: song.artistID,
            albumTitle: onlyFillMissing ? (albumNeedsUpdate ? metadata.albumTitle ?? song.albumTitle : song.albumTitle) : (metadata.albumTitle ?? song.albumTitle),
            artistName: onlyFillMissing ? (artistNeedsUpdate ? metadata.artist ?? song.artistName : song.artistName) : (metadata.artist ?? song.artistName),
            trackNumber: song.trackNumber ?? metadata.trackNumber,
            discNumber: song.discNumber ?? metadata.discNumber,
            duration: metadata.duration > 0 ? metadata.duration : song.duration,
            fileFormat: song.fileFormat,
            filePath: song.filePath,
            sourceID: song.sourceID,
            fileSize: song.fileSize,
            bitRate: metadata.bitRate ?? song.bitRate,
            sampleRate: metadata.sampleRate ?? song.sampleRate,
            bitDepth: metadata.bitDepth ?? song.bitDepth,
            genre: onlyFillMissing ? (genreNeedsUpdate ? metadata.genre ?? song.genre : song.genre) : (metadata.genre ?? song.genre),
            year: onlyFillMissing ? (yearNeedsUpdate ? metadata.year ?? song.year : song.year) : (metadata.year ?? song.year),
            lastModified: song.lastModified,
            dateAdded: song.dateAdded,
            coverArtFileName: coverNeedsUpdate ? (metadata.coverArtFileName ?? song.coverArtFileName) : song.coverArtFileName,
            lyricsFileName: lyricsNeedsUpdate ? (metadata.lyricsFileName ?? song.lyricsFileName) : song.lyricsFileName,
            mvPath: metadata.mvPath ?? song.mvPath,
            revision: song.revision
        )
    }

    private nonisolated static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        for song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?
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
                    lyricsLines: lyricsLines
                )
                if writeResult.coverWritten || writeResult.lyricsWritten {
                    await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                }
                return writeResult
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
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
