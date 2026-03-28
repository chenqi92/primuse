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

            for song in songs {
                guard !Task.isCancelled else { return }

                currentSongTitle = song.title

                do {
                    let fileURL = try await sourceManager.resolveURL(for: song)
                    let placeholderTitle = fileURL.deletingPathExtension().lastPathComponent

                    guard forceRescrape || needsScrape(song: song, placeholderTitle: placeholderTitle) else {
                        processedCount += 1
                        skippedCount += 1
                        continue
                    }

                    let metadata = await metadataService.loadMetadata(for: fileURL, cacheKey: song.id)
                    let updatedSong = mergedSong(
                        song,
                        with: metadata,
                        placeholderTitle: placeholderTitle,
                        forceRescrape: forceRescrape
                    )

                    processedCount += 1

                    if updatedSong != song {
                        library.replaceSong(updatedSong)
                        updatedCount += 1
                    } else {
                        skippedCount += 1
                    }
                } catch {
                    processedCount += 1
                    failedCount += 1
                }
            }
        }
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
