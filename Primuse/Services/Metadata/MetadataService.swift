import Foundation
import PrimuseKit

actor MetadataService {
    private let scraperManager = ScraperManager()
    private let assetStore = MetadataAssetStore.shared

    struct SongMetadata {
        var title: String
        var artist: String?
        var albumTitle: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?
        var coverArtData: Data?
        var coverArtFileName: String?
        var lyricsFileName: String?
        var lyrics: [LyricLine]?
    }

    /// Load metadata with priority: sidecar → embedded → online
    func loadMetadata(for url: URL, cacheKey: String? = nil) async -> SongMetadata {
        // 1. Read embedded metadata
        let embedded = await FileMetadataReader.read(from: url)
        NSLog("📖 FileMetadataReader: title=\(embedded.title ?? "nil") cover=\(embedded.coverArtData?.count ?? 0)bytes lyrics=\(embedded.lyricsText?.prefix(30) ?? "nil") file=\(url.lastPathComponent)")

        var result = SongMetadata(
            title: embedded.title ?? url.deletingPathExtension().lastPathComponent,
            artist: embedded.artist,
            albumTitle: embedded.albumTitle,
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: embedded.genre,
            duration: embedded.duration ?? 0,
            sampleRate: embedded.sampleRate,
            bitRate: embedded.bitRate,
            bitDepth: embedded.bitDepth,
            coverArtData: embedded.coverArtData
        )

        // 2. Check sidecar files (higher priority for cover & lyrics)
        if let coverURL = SidecarMetadataLoader.findCoverArt(for: url) {
            result.coverArtFileName = coverURL.lastPathComponent
            if let data = try? Data(contentsOf: coverURL) {
                result.coverArtData = data
            }
        }

        if let lyricsURL = SidecarMetadataLoader.findLyrics(for: url) {
            result.lyricsFileName = lyricsURL.lastPathComponent
            result.lyrics = try? LyricsParser.parse(from: lyricsURL)
        }

        // 2.5 Check embedded lyrics (lower priority than sidecar)
        if result.lyrics == nil, let lyricsText = embedded.lyricsText {
            result.lyrics = LyricsParser.parseText(lyricsText)
        }

        // 3. Try online sources as fallback
        let needsMetadata = result.artist == nil || result.albumTitle == nil || result.year == nil
        let needsCover = result.coverArtData == nil
        let needsLyrics = result.lyrics == nil

        if needsMetadata || needsCover || needsLyrics {
            await fetchOnlineMetadata(
                for: &result,
                needsMetadata: needsMetadata,
                needsCover: needsCover,
                needsLyrics: needsLyrics
            )
        }

        if let cacheKey {
            if let coverArtData = result.coverArtData {
                result.coverArtFileName = await assetStore.storeCover(coverArtData, for: cacheKey)
            }
            if let lyrics = result.lyrics {
                result.lyricsFileName = await assetStore.storeLyrics(lyrics, for: cacheKey)
            }
        }

        return result
    }

    private func fetchOnlineMetadata(
        for result: inout SongMetadata,
        needsMetadata: Bool,
        needsCover: Bool,
        needsLyrics: Bool
    ) async {
        let settings = ScraperSettings.load()

        let scrapeResult = await scraperManager.scrapeMetadata(
            title: result.title,
            artist: result.artist,
            album: result.albumTitle,
            duration: result.duration,
            needs: ScraperManager.ScrapeNeeds(
                metadata: needsMetadata,
                cover: needsCover,
                lyrics: needsLyrics
            ),
            settings: settings
        )

        // Apply metadata from detail
        if let detail = scrapeResult.detail {
            if result.artist == nil { result.artist = detail.artist }
            if result.albumTitle == nil { result.albumTitle = detail.album }
            if result.year == nil { result.year = detail.year }
            if result.genre == nil || result.genre?.isEmpty == true {
                result.genre = detail.genres?.prefix(3).joined(separator: ", ")
            }
            if result.trackNumber == nil { result.trackNumber = detail.trackNumber }
            if result.discNumber == nil { result.discNumber = detail.discNumber }
        }

        // Apply cover data
        if let coverData = scrapeResult.coverData {
            result.coverArtData = coverData
        }

        // Apply lyrics
        if let lyrics = scrapeResult.lyrics {
            result.lyrics = lyrics
        }
    }
}
