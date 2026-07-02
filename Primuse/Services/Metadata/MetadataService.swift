import Foundation
import PrimuseKit

actor MetadataService {
    private let scraperManager = ScraperManager()
    private let assetStore = MetadataAssetStore.shared

    struct SongMetadata {
        var title: String
        var artist: String? = nil
        var albumTitle: String? = nil
        var trackNumber: Int? = nil
        var discNumber: Int? = nil
        var year: Int? = nil
        var genre: String? = nil
        var duration: TimeInterval = 0
        var sampleRate: Int? = nil
        var bitRate: Int? = nil
        var bitDepth: Int? = nil
        var coverArtData: Data? = nil
        var coverArtFileName: String? = nil
        var lyricsFileName: String? = nil
        var mvPath: String? = nil
        var lyrics: [LyricLine]? = nil
        var replayGainTrackGain: Double? = nil
        var replayGainTrackPeak: Double? = nil
        var replayGainAlbumGain: Double? = nil
        var replayGainAlbumPeak: Double? = nil
    }

    /// Load metadata with priority: sidecar → embedded → online
    ///
    /// `trustedSource`: 是否把结果直接写入 hash cache。
    /// - true（默认）: LibraryScanner / Backfill 路径,数据来自 embedded/sidecar,可信。
    /// - false: ScraperService 路径,可能错配,**不写 cache**。
    ///   由 ScraperService 在用户确认/应用刮削结果时写入本地 cache；dry-run
    ///   路径只返回预期文件名,不会提前污染现有缓存。
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
        let rawURLBasedFallback = url.deletingPathExtension().lastPathComponent
        let urlBasedFallback = FileMetadataReader.repairLegacyChineseMojibake(rawURLBasedFallback)
        let repairedFallbackTitle = fallbackTitle.map(FileMetadataReader.repairLegacyChineseMojibake)
        let titleFallback: String = if let repairedFallbackTitle,
                                       !repairedFallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            repairedFallbackTitle
        } else {
            urlBasedFallback
        }

        // 防御: 历史上 FileMetadataReader 在没 TIT2 时会自动把 url basename
        // 塞进 embedded.title。这里再校一次, 万一别的读取路径返回 sanitized
        // 名 (如 "_music_xxx") 也当成空, 走真正的 fallback。
        let trustedEmbeddedTitle: String? = {
            guard let t = embedded.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t == rawURLBasedFallback || t == urlBasedFallback ? nil : embedded.title
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
            coverArtData: embedded.coverArtData,
            replayGainTrackGain: embedded.replayGainTrackGain,
            replayGainTrackPeak: embedded.replayGainTrackPeak,
            replayGainAlbumGain: embedded.replayGainAlbumGain,
            replayGainAlbumPeak: embedded.replayGainAlbumPeak
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

        if let mvURL = SidecarMetadataLoader.findMusicVideo(for: url),
           VideoFormat.from(fileExtension: mvURL.pathExtension)?.isNativelyPlayable == true {
            result.mvPath = mvURL.lastPathComponent
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
                    // 仅占位 ref,不写 cache 文件 —— dry-run 预览和直接刮削都需要
                    // 先知道最终 ref,实际写入由 ScraperService 在应用结果时完成。
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

    /// 只用已知元数据查在线源补缺,**不读音频文件**。给服务端曲库源
    /// (Subsonic/Navidrome 等)用 —— 它们 title/artist/album 由服务端权威提供,
    /// 既不该为读 embedded tag 去拉(可能转码的)音频流, 也只补空缺字段。
    /// `needsCover`/`needsLyrics` 默认 false: 服务端源的封面/歌词由服务端
    /// (getCoverArt / getLyricsBySongId)提供, 不让在线刮削用脏标题错配盖掉。
    func fillMissingOnline(
        title: String,
        artist: String?,
        album: String?,
        year: Int?,
        genre: String?,
        duration: TimeInterval,
        needsCover: Bool = false,
        needsLyrics: Bool = false
    ) async -> SongMetadata {
        var result = SongMetadata(
            title: title,
            artist: artist,
            albumTitle: album,
            year: year,
            genre: genre,
            duration: duration
        )
        let needsMetadata = (artist?.isEmpty ?? true)
            || (album?.isEmpty ?? true)
            || year == nil
            || (genre?.isEmpty ?? true)
        guard needsMetadata || needsCover || needsLyrics else { return result }
        await fetchOnlineMetadata(
            for: &result,
            needsMetadata: needsMetadata,
            needsCover: needsCover,
            needsLyrics: needsLyrics
        )
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
