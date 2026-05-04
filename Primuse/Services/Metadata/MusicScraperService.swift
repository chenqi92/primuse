import Foundation
import PrimuseKit

@MainActor
@Observable
final class MusicScraperService {
    private let sourceManager: SourceManager
    private let metadataService = MetadataService()
    private var scrapingTask: Task<Void, Never>?
    private var backgroundEnrichmentTask: Task<Void, Never>?
    private var pendingEnrichmentSongIDs: [String] = []
    private var pendingEnrichmentSongIDSet: Set<String> = []

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
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }

    func scrapeMissingMetadata(in library: MusicLibrary) {
        startScraping(in: library, forceRescrape: false)
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
                revision: updatedSong.revision ?? song.revision
            )
        }

        if !dryRun && updatedSong != song {
            // 拿到 lyrics 立即写 hash JSON cache + 把 song.lyricsFileName 改成
            // hash filename (不是 NAS .lrc path) —— 否则 NowPlayingView.loadLyrics
            // 立即跑时, Tier1a cache miss + Tier1b 看 lyricsFileName 含 "/" 走
            // Tier3 从 NAS 拉 line-level .lrc, 用户看到 line-level, 等后续 sidecar
            // task 写 cache 已经晚了 (UI 不会再 reload)。
            let lyricsLines = result.lyricsLines
            let coverData = result.coverData
            if let lyricsLines, !lyricsLines.isEmpty {
                await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: updatedSong.id, force: true)
                updatedSong.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: updatedSong.id)
            }
            library.replaceSong(updatedSong)

            // Write sidecar files to source (cover.jpg, .lrc) and update Song refs
            plog("📝 Sidecar: coverData=\(coverData?.count ?? 0)B lyricsLines=\(lyricsLines?.count ?? 0) for '\(updatedSong.title)'")
            if coverData != nil || lyricsLines != nil {
                let songForWrite = updatedSong
                let sourceManager = self.sourceManager
                let songID = updatedSong.id
                Task { @MainActor in
                    // 之前刮削过的 cover cache 可能仍然存在, 在 sidecar 写完前
                    // 失效避免 UI 拿到上次的污染数据。lyrics 不在这里 invalidate
                    // 因为我们刚刚已经写过新的字级 cache (上面那段)。
                    await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                    CachedArtworkView.invalidateCache(for: songID)

                    do {
                        plog("📝 Sidecar: getting auxiliary connector for '\(songForWrite.title)' source=\(songForWrite.sourceID)")
                        let connector = try await sourceManager.auxiliaryConnector(for: songForWrite)
                        plog("📝 Sidecar: writing sidecars for '\(songForWrite.title)' filePath=\(songForWrite.filePath)")
                        let writeResult = await SidecarWriteService.shared.writeSidecars(
                            for: songForWrite, using: connector,
                            coverData: coverData, lyricsLines: lyricsLines
                        )
                        plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten) errors=\(writeResult.errors)")

                        // Update Song refs to point to sidecar paths on source
                        let songDir = (songForWrite.filePath as NSString).deletingLastPathComponent
                        let baseNameNoExt = ((songForWrite.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                        var needsUpdate = false
                        var refSong = songForWrite

                        if writeResult.coverWritten {
                            let coverPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt)-cover.jpg")
                            refSong.coverArtFileName = coverPath
                            // sidecar 已落盘 —— 现在回写 hash cache 作为可信 mirror
                            if let coverData {
                                await MetadataAssetStore.shared.cacheCover(coverData, forSongID: songID)
                            }
                            needsUpdate = true
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
                            library.replaceSong(refSong)
                        }

                        if !writeResult.errors.isEmpty {
                            plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                        }
                    } catch {
                        plog("⚠️ Sidecar write skipped for '\(songForWrite.title)': \(error.localizedDescription)")
                    }
                }
            }
        }
        return (updatedSong, result.coverData, result.lyricsLines)
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
        scrapingTask?.cancel()
        scrapingTask = nil
        isScraping = false
        currentSongTitle = ""
    }

    private func startScraping(in library: MusicLibrary, forceRescrape: Bool) {
        guard !isScraping else { return }

        let songs = library.visibleSongs
        totalCount = songs.count
        processedCount = 0
        updatedCount = 0
        skippedCount = 0
        failedCount = 0
        currentSongTitle = ""
        isScraping = true

        scrapingTask = Task {
            defer {
                isScraping = false
                currentSongTitle = ""
                scrapingTask = nil
            }

            let settings = ScraperSettings.load()
            let onlyFillMissing = settings.onlyFillMissingFields && !forceRescrape

            // Phase 1: Scrape song metadata + write sidecar files
            for song in songs {
                guard !Task.isCancelled else { return }

                currentSongTitle = song.title

                do {
                    guard let result = try await processedSongWithAssets(song, forceRescrape: forceRescrape) else {
                        processedCount += 1
                        skippedCount += 1
                        continue
                    }

                    processedCount += 1
                    let updatedSong = result.song

                    if updatedSong != song {
                        library.replaceSong(updatedSong)
                        updatedCount += 1

                        // Determine which sidecar data to write based on fill/overwrite mode
                        let shouldWriteCover: Bool
                        let shouldWriteLyrics: Bool
                        if onlyFillMissing {
                            // Only write if the song was missing cover/lyrics before
                            shouldWriteCover = song.coverArtFileName == nil && result.coverData != nil
                            shouldWriteLyrics = song.lyricsFileName == nil && result.lyricsLines != nil
                        } else {
                            // Overwrite mode: write if we got new data
                            shouldWriteCover = result.coverData != nil
                            shouldWriteLyrics = result.lyricsLines != nil
                        }

                        let coverData = shouldWriteCover ? result.coverData : nil
                        let lyricsLines = shouldWriteLyrics ? result.lyricsLines : nil

                        if coverData != nil || lyricsLines != nil {
                            let songForWrite = updatedSong
                            let sourceManager = self.sourceManager
                            let songID = updatedSong.id

                            // Write sidecar files to source asynchronously (don't block scraping loop)
                            Task { @MainActor in
                                // 同 scrapeSingle:写 sidecar 前清旧 cache、写后回写
                                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                                await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
                                CachedArtworkView.invalidateCache(for: songID)

                                do {
                                    let connector = try await sourceManager.auxiliaryConnector(for: songForWrite)
                                    let writeResult = await SidecarWriteService.shared.writeSidecars(
                                        for: songForWrite, using: connector,
                                        coverData: coverData, lyricsLines: lyricsLines
                                    )

                                    // Update Song refs to point to sidecar paths on source
                                    let songDir = (songForWrite.filePath as NSString).deletingLastPathComponent
                                    let baseNameNoExt = ((songForWrite.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                                    var needsUpdate = false
                                    var refSong = songForWrite

                                    if writeResult.coverWritten {
                                        let coverPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt)-cover.jpg")
                                        refSong.coverArtFileName = coverPath
                                        if let coverData {
                                            await MetadataAssetStore.shared.cacheCover(coverData, forSongID: songID)
                                        }
                                        needsUpdate = true
                                    }
                                    if writeResult.lyricsWritten, let lyricsLines {
                                        // 同上: 不指向 NAS .lrc, 字级数据只在
                                        // 本地 hash JSON。
                                        // 用户动作 (scrape) 触发的 sidecar 镜像写回, 强制覆盖
                            await MetadataAssetStore.shared.cacheLyrics(lyricsLines, forSongID: songID, force: true)
                                    }

                                    if needsUpdate {
                                        library.replaceSong(refSong)
                                    }

                                    if !writeResult.errors.isEmpty {
                                        plog("⚠️ Batch sidecar errors for '\(songForWrite.title)': \(writeResult.errors)")
                                    }
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
            let albumsNeedingCover = library.albums.filter { album in
                !assetStore.hasAlbumCover(forAlbumID: album.id)
            }
            let artistsNeedingImage = library.artists.filter { artist in
                !assetStore.hasArtistImage(forArtistID: artist.id)
            }
            totalCount += albumsNeedingCover.count + artistsNeedingImage.count

            await scrapeAlbumAndArtistCovers(
                in: library,
                albumsNeedingCover: albumsNeedingCover,
                artistsNeedingImage: artistsNeedingImage
            )
        }
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
        let fileURL = try await sourceManager.resolveURL(for: song)
        let placeholderTitle = fileURL.deletingPathExtension().lastPathComponent

        guard forceRescrape || needsScrape(song: song, placeholderTitle: placeholderTitle) else {
            return nil
        }

        // trustedSource: false —— scrape 路径下 online 结果可能错配,
        // 不让 loadMetadata 直接写 hash cache。等 sidecar 写到 source
        // 成功后再回写 cache（在 scrapeSingle / startScraping 的 Task 里做）。
        let metadata = await metadataService.loadMetadata(
            for: fileURL,
            cacheKey: storeAssets ? song.id : nil,
            trustedSource: false
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
                    library.replaceSong(result.song)
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
            revision: song.revision
        )
    }
}
