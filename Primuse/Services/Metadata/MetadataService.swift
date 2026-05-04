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
    ///
    /// `trustedSource`: 是否把结果直接写入 hash cache。
    /// - true（默认）: LibraryScanner / Backfill 路径,数据来自 embedded/sidecar,可信。
    /// - false: ScraperService 路径,可能错配,**不写 cache**。
    ///   等 sidecar 真正写到 source 成功后,由 ScraperService 自己回写 cache。
    ///   这样 hash cache 永远只是 sidecar 的镜像,杜绝错配数据污染缓存。
    func loadMetadata(
        for url: URL,
        cacheKey: String? = nil,
        allowOnlineFetch: Bool = true,
        trustedSource: Bool = true,
        fallbackTitle: String? = nil
    ) async -> SongMetadata {
        // 1. Read embedded metadata
        let embedded = await FileMetadataReader.read(from: url)
        NSLog("📖 FileMetadataReader: title=\(embedded.title ?? "nil") cover=\(embedded.coverArtData?.count ?? 0)bytes lyrics=\(embedded.lyricsText?.prefix(30) ?? "nil") file=\(url.lastPathComponent)")

        // url.lastPathComponent 在 scrape 路径下是 cache 的 sanitized 名
        // 丑名字。caller 传原始文件名当 fallbackTitle 优先用。
        let urlBasedFallback = url.deletingPathExtension().lastPathComponent
        let titleFallback = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? fallbackTitle!
            : urlBasedFallback

        // 防御: 历史上 FileMetadataReader 在没 TIT2 时会自动把 url basename
        // 塞进 embedded.title。这里再校一次, 万一别的读取路径返回 sanitized
        // 名 (如 "_music_xxx") 也当成空, 走真正的 fallback。
        let trustedEmbeddedTitle: String? = {
            guard let t = embedded.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t == urlBasedFallback ? nil : embedded.title
        }()

        var result = SongMetadata(
            title: trustedEmbeddedTitle ?? titleFallback,
            artist: embedded.artist,
            albumTitle: embedded.albumTitle,
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: embedded.genre,
            duration: TimeInterval.sanitized(embedded.duration),
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

        if allowOnlineFetch && (needsMetadata || needsCover || needsLyrics) {
            await fetchOnlineMetadata(
                for: &result,
                needsMetadata: needsMetadata,
                needsCover: needsCover,
                needsLyrics: needsLyrics
            )
        }

        if let cacheKey {
            if let coverArtData = result.coverArtData {
                if trustedSource {
                    result.coverArtFileName = await assetStore.storeCover(coverArtData, for: cacheKey)
                } else {
                    // 仅占位 ref,不写 cache 文件 —— 留给 ScraperService 在 sidecar
                    // 写到 source 成功后再回写,确保 hash cache 永远不存错配数据。
                    result.coverArtFileName = assetStore.expectedCoverFileName(for: cacheKey)
                }
            }
            if let lyrics = result.lyrics {
                if trustedSource {
                    result.lyricsFileName = await assetStore.storeLyrics(lyrics, for: cacheKey)
                } else {
                    result.lyricsFileName = assetStore.expectedLyricsFileName(for: cacheKey)
                }
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
