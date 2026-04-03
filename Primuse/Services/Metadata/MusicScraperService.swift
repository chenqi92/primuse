import Foundation
import PrimuseKit

@MainActor
@Observable
final class MusicScraperService {
    private let sourceManager: SourceManager
    private let metadataService = MetadataService()
    private var scrapingTask: Task<Void, Never>?

    private(set) var isScraping = false
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
                lyricsFileName: updatedSong.lyricsFileName ?? song.lyricsFileName
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
                lyricsFileName: song.lyricsFileName
            )
        }

        if !dryRun && updatedSong != song {
            library.replaceSong(updatedSong)

            // Write sidecar files to source (cover.jpg, .lrc) and update Song refs
            let coverData = result.coverData
            let lyricsLines = result.lyricsLines
            plog("📝 Sidecar: coverData=\(coverData?.count ?? 0)B lyricsLines=\(lyricsLines?.count ?? 0) for '\(updatedSong.title)'")
            if coverData != nil || lyricsLines != nil {
                let songForWrite = updatedSong
                let sourceManager = self.sourceManager
                let songID = updatedSong.id
                Task { @MainActor in
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
                            // Invalidate both disk and memory cache so views refetch from source
                            await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                            CachedArtworkView.invalidateCache(for: songID)
                            needsUpdate = true
                        }
                        if writeResult.lyricsWritten {
                            let lrcPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt).lrc")
                            refSong.lyricsFileName = lrcPath
                            needsUpdate = true
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

    func cancel() {
        scrapingTask?.cancel()
        scrapingTask = nil
        isScraping = false
        currentSongTitle = ""
    }

    private func startScraping(in library: MusicLibrary, forceRescrape: Bool) {
        guard !isScraping else { return }

        let songs = library.songs
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
                    var updatedSong = result.song

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
                                        // Invalidate both disk and memory cache so views refetch from source
                                        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                                        CachedArtworkView.invalidateCache(for: songID)
                                        needsUpdate = true
                                    }
                                    if writeResult.lyricsWritten {
                                        let lrcPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt).lrc")
                                        refSong.lyricsFileName = lrcPath
                                        needsUpdate = true
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
            await scrapeAlbumAndArtistCovers(in: library)
        }
    }

    /// Batch-fetch album covers and artist images for items missing artwork.
    private func scrapeAlbumAndArtistCovers(in library: MusicLibrary) async {
        let assetStore = MetadataAssetStore.shared
        let artworkService = ArtworkFetchService.shared

        // Albums without cached cover
        let albumsNeedingCover = library.albums.filter { album in
            !assetStore.hasAlbumCover(forAlbumID: album.id)
        }
        if !albumsNeedingCover.isEmpty {
            plog("🎨 Scraping covers for \(albumsNeedingCover.count) albums...")
            currentSongTitle = String(localized: "scraping_album_covers")
            for album in albumsNeedingCover {
                guard !Task.isCancelled else { return }
                currentSongTitle = album.title
                _ = await artworkService.fetchAlbumCover(
                    albumTitle: album.title, artistName: album.artistName, albumID: album.id
                )
            }
        }

        // Artists without cached image
        let artistsNeedingImage = library.artists.filter { artist in
            !assetStore.hasArtistImage(forArtistID: artist.id)
        }
        if !artistsNeedingImage.isEmpty {
            plog("🎨 Scraping images for \(artistsNeedingImage.count) artists...")
            currentSongTitle = String(localized: "scraping_artist_images")
            for artist in artistsNeedingImage {
                guard !Task.isCancelled else { return }
                currentSongTitle = artist.name
                _ = await artworkService.fetchArtistImage(
                    artistName: artist.name, artistID: artist.id
                )
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

        let metadata = await metadataService.loadMetadata(for: fileURL, cacheKey: storeAssets ? song.id : nil)
        let merged = mergedSong(
            song,
            with: metadata,
            placeholderTitle: placeholderTitle,
            forceRescrape: forceRescrape
        )
        return ProcessedResult(song: merged, coverData: metadata.coverArtData, lyricsLines: metadata.lyrics)
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
            lyricsFileName: lyricsNeedsUpdate ? (metadata.lyricsFileName ?? song.lyricsFileName) : song.lyricsFileName
        )
    }
}
