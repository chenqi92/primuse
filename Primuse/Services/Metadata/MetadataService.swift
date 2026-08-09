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
        fallbackTitle: String? = nil,
        forceOnlineRefresh: Bool = false
    ) async -> SongMetadata {
        // 1. Read embedded metadata
        let embedded = await FileMetadataReader.read(from: url)
        plog("📖 FileMetadataReader: title=\(embedded.title ?? "nil") cover=\(embedded.coverArtData?.count ?? 0)bytes lyrics=\(embedded.lyricsText?.prefix(30) ?? "nil") file=\(url.lastPathComponent)")

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
        //
        // 标签解码猜错时也走 fallback: 文件名是独立来源, 通常还是好的
        // (详见 MediaMetadataTextRepair.preferred)。之前只判空不判乱码,
        // 于是非空的乱码标签会盖掉正确的文件名。
        let trustedEmbeddedTitle: String? = {
            guard let t = embedded.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            guard t != rawURLBasedFallback, t != urlBasedFallback else { return nil }
            guard !MediaMetadataTextRepair.isSuspicious(t)
                    || MediaMetadataTextRepair.isSuspicious(titleFallback) else {
                return nil
            }
            return embedded.title
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

        if let mvURL = SidecarMetadataLoader.findMusicVideo(for: url) {
            result.mvPath = mvURL.lastPathComponent
        }

        // 2.5 Check embedded lyrics (lower priority than sidecar)
        if result.lyrics == nil, let lyricsText = embedded.lyricsText {
            result.lyrics = LyricsParser.parseText(lyricsText)
        }

        // 3. Try online sources as fallback
        let fieldsAreMissing = result.artist?.isEmpty != false
            || result.albumTitle?.isEmpty != false
            || result.year == nil
            || result.genre?.isEmpty != false
        let needsMetadata = ScrapeMetadataApplicationPolicy.shouldRequestMetadata(
            fieldsAreMissing: fieldsAreMissing,
            forceRefresh: forceOnlineRefresh
        )
        let needsCover = forceOnlineRefresh || result.coverArtData == nil
        let needsLyrics = forceOnlineRefresh || result.lyrics == nil

        if allowOnlineFetch && (needsMetadata || needsCover || needsLyrics) {
            await fetchOnlineMetadata(
                for: &result,
                needsMetadata: needsMetadata,
                needsCover: needsCover,
                needsLyrics: needsLyrics,
                overwriteMetadata: forceOnlineRefresh
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

    /// Loads embedded metadata from an already-bounded remote byte slice.
    /// Remote sidecars are represented by the source scanner and therefore do
    /// not need a local URL here. Keeping the `Data` in memory removes the
    /// temporary-file write that previously ran once per backfill song.
    func loadEmbeddedMetadata(
        from data: Data,
        containerTailData: Data? = nil,
        fileExtension: String,
        cacheKey: String? = nil,
        fallbackTitle: String
    ) async -> SongMetadata {
        var embedded = await FileMetadataReader.read(
            from: data,
            fileExtension: fileExtension
        )
        if let containerTailData,
           let tailMetadata = await FileMetadataReader.readISOBaseMediaMetadata(
            head: data,
            tail: containerTailData,
            fileExtension: fileExtension
           ) {
            embedded.fillMissing(from: tailMetadata)
        }
        let repairedFallback = FileMetadataReader.repairLegacyChineseMojibake(fallbackTitle)
        let embeddedTitle = embedded.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = SongMetadata(
            title: embeddedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? repairedFallback,
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

        if let lyricsText = embedded.lyricsText {
            let lyrics = LyricsParser.parseText(lyricsText)
            if !lyrics.isEmpty {
                result.lyrics = lyrics
            }
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
        needsLyrics: Bool = false,
        forceMetadataRefresh: Bool = false,
        overwriteMetadata: Bool = false
    ) async -> SongMetadata {
        var result = SongMetadata(
            title: title,
            artist: artist,
            albumTitle: album,
            year: year,
            genre: genre,
            duration: duration
        )
        let fieldsAreMissing = (artist?.isEmpty ?? true)
            || (album?.isEmpty ?? true)
            || year == nil
            || (genre?.isEmpty ?? true)
        let needsMetadata = ScrapeMetadataApplicationPolicy.shouldRequestMetadata(
            fieldsAreMissing: fieldsAreMissing,
            forceRefresh: forceMetadataRefresh
        )
        guard needsMetadata || needsCover || needsLyrics else { return result }
        await fetchOnlineMetadata(
            for: &result,
            needsMetadata: needsMetadata,
            needsCover: needsCover,
            needsLyrics: needsLyrics,
            overwriteMetadata: overwriteMetadata
        )
        return result
    }

    /// Fetch only lyrics through the configured lyrics-source chain.
    ///
    /// The macOS candidate-first scraper obtains metadata and artwork from the
    /// selected candidate's source, but lyrics are an independent asset: the
    /// selected source (for example iTunes) may not support them at all. Keep
    /// this path aligned with normal/iOS automatic scraping by delegating to
    /// ScraperManager with only the lyrics tier enabled.
    func fetchOnlineLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async -> [LyricLine]? {
        let settings = ScraperSettings.load()
        let scrapeResult = await scraperManager.scrapeMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            needs: ScraperManager.ScrapeNeeds(
                metadata: false,
                cover: false,
                lyrics: true
            ),
            settings: settings
        )
        return scrapeResult.lyrics
    }

    private func fetchOnlineMetadata(
        for result: inout SongMetadata,
        needsMetadata: Bool,
        needsCover: Bool,
        needsLyrics: Bool,
        overwriteMetadata: Bool = false
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
            result.title = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.title,
                scraped: detail.title,
                overwrite: overwriteMetadata
            ) ?? result.title
            result.artist = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.artist,
                scraped: detail.artist,
                overwrite: overwriteMetadata
            )
            result.albumTitle = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.albumTitle,
                scraped: detail.album,
                overwrite: overwriteMetadata
            )
            result.year = ScrapeMetadataApplicationPolicy.resolvedValue(
                original: result.year,
                scraped: detail.year,
                overwrite: overwriteMetadata
            )
            result.genre = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.genre,
                scraped: detail.genres?.prefix(3).joined(separator: ", "),
                overwrite: overwriteMetadata
            )
            result.trackNumber = ScrapeMetadataApplicationPolicy.resolvedValue(
                original: result.trackNumber,
                scraped: detail.trackNumber,
                overwrite: overwriteMetadata
            )
            result.discNumber = ScrapeMetadataApplicationPolicy.resolvedValue(
                original: result.discNumber,
                scraped: detail.discNumber,
                overwrite: overwriteMetadata
            )
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
