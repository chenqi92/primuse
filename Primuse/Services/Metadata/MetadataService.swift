import Foundation
import PrimuseKit

actor MetadataService {
    private let scraperManager = ScraperManager()
    private let assetStore = MetadataAssetStore.shared

    struct SongMetadata {
        var title: String
        var artist: String? = nil
        /// Trustworthy identity values that came from the media bytes. `title`
        /// itself may be a display fallback and must not be reported as a tag.
        var embeddedTitle: String? = nil
        var embeddedArtist: String? = nil
        var sourceArtistNames: [String]? = nil
        var albumTitle: String? = nil
        var albumArtist: String? = nil
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
        /// True only when descriptive fields came from bytes inside the media
        /// file. Duration/sample rate/bitrate never set this flag.
        var hasEmbeddedDescriptiveMetadata = false
        var hasTechnicalProperties = false
        var hasVerifiedSidecarMetadata = false
        var detectedFileSignature: AudioFileSignatureKind = .unknown
        /// The connector exposed a complete local file. Metadata parsers may
        /// still inspect only the format-defined tag regions of that file.
        var hasCompleteFileAccess = false
    }

    /// Load metadata with priority: embedded → verified sidecar → online
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
        plog(
            "📖 FileMetadataReader: title=\(embedded.title ?? "nil") "
                + "cover=\(embedded.coverArtData?.count ?? 0)bytes "
                + "lyrics=\(embedded.lyricsText == nil ? "absent" : "present") "
                + "file=\(url.lastPathComponent)"
        )

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
            embeddedTitle: MediaMetadataTextRepair.repaired(trustedEmbeddedTitle),
            embeddedArtist: MediaMetadataTextRepair.repaired(embedded.artist),
            sourceArtistNames: embedded.sourceArtistNames,
            albumTitle: embedded.albumTitle,
            albumArtist: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: embedded.albumArtist,
                trackArtistName: embedded.artist
            ),
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
            replayGainAlbumPeak: embedded.replayGainAlbumPeak,
            hasEmbeddedDescriptiveMetadata: embedded.hasDescriptiveMetadata,
            hasTechnicalProperties: embedded.hasTechnicalProperties,
            detectedFileSignature: FileMetadataReader.signature(from: url),
            hasCompleteFileAccess: true
        )

        // 2. Verified sidecars fill fields absent from embedded metadata.
        if result.coverArtData == nil,
           let coverURL = SidecarMetadataLoader.findCoverArt(for: url) {
            result.coverArtFileName = coverURL.lastPathComponent
            if let data = try? Data(contentsOf: coverURL) {
                result.coverArtData = data
                result.hasVerifiedSidecarMetadata = true
            }
        }

        if embedded.lyricsText == nil,
           let lyricsURL = SidecarMetadataLoader.findLyrics(for: url) {
            result.lyricsFileName = lyricsURL.lastPathComponent
            result.lyrics = try? LyricsParser.parse(from: lyricsURL)
            if result.lyrics?.isEmpty == false {
                result.hasVerifiedSidecarMetadata = true
            }
        }

        if let mvURL = SidecarMetadataLoader.findMusicVideo(for: url) {
            result.mvPath = mvURL.lastPathComponent
            result.hasVerifiedSidecarMetadata = true
        }

        // 2.5 Parse embedded lyrics when present.
        if result.lyrics == nil {
            result.lyrics = Self.parsedEmbeddedLyrics(from: embedded)
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
        id3TailData: Data? = nil,
        fileExtension: String,
        cacheKey: String? = nil,
        fallbackTitle: String
    ) async -> SongMetadata {
        let signature = AudioFileSignaturePolicy.inspect(data)
        let parserFileExtension = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: fileExtension,
            signature: signature
        )
        var embedded = await FileMetadataReader.read(
            from: data,
            fileExtension: parserFileExtension,
            id3TailData: id3TailData
        )
        if let containerTailData,
           let tailMetadata = await FileMetadataReader.readISOBaseMediaMetadata(
            head: data,
            tail: containerTailData,
            fileExtension: parserFileExtension
           ) {
            embedded.fillMissing(from: tailMetadata)
        }
        let repairedFallback = FileMetadataReader.repairLegacyChineseMojibake(fallbackTitle)
        let preferredTitle = MediaMetadataTextRepair.preferred(
            embedded: embedded.title,
            fromFileName: repairedFallback
        ) ?? repairedFallback

        var result = SongMetadata(
            title: preferredTitle,
            artist: MediaMetadataTextRepair.repaired(embedded.artist),
            embeddedTitle: MediaMetadataTextRepair.repaired(embedded.title),
            embeddedArtist: MediaMetadataTextRepair.repaired(embedded.artist),
            sourceArtistNames: embedded.sourceArtistNames?.compactMap {
                MediaMetadataTextRepair.repaired($0)
            },
            albumTitle: MediaMetadataTextRepair.repaired(embedded.albumTitle),
            albumArtist: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: MediaMetadataTextRepair.repaired(embedded.albumArtist),
                trackArtistName: MediaMetadataTextRepair.repaired(embedded.artist)
            ),
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: MediaMetadataTextRepair.repaired(embedded.genre),
            duration: TimeInterval.sanitized(embedded.duration),
            sampleRate: embedded.sampleRate,
            bitRate: embedded.bitRate,
            bitDepth: embedded.bitDepth,
            coverArtData: embedded.coverArtData,
            replayGainTrackGain: embedded.replayGainTrackGain,
            replayGainTrackPeak: embedded.replayGainTrackPeak,
            replayGainAlbumGain: embedded.replayGainAlbumGain,
            replayGainAlbumPeak: embedded.replayGainAlbumPeak,
            hasEmbeddedDescriptiveMetadata: embedded.hasDescriptiveMetadata,
            hasTechnicalProperties: embedded.hasTechnicalProperties,
            detectedFileSignature: signature
        )

        if let lyrics = Self.parsedEmbeddedLyrics(from: embedded) {
            result.lyrics = lyrics
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

    /// Builds the lyric document once, then attaches every authored embedded
    /// translation without placing it in the machine-translation cache. A
    /// dedicated translation field is preferred over language-qualified
    /// alternates; bilingual LRC detected in the original body remains the
    /// fallback for rows that the dedicated field does not cover.
    private static func parsedEmbeddedLyrics(
        from embedded: FileMetadataReader.Metadata
    ) -> [LyricLine]? {
        guard let originalText = embedded.lyricsText else { return nil }
        var lines = LyricsParser.parseText(originalText)
        guard !lines.isEmpty else { return nil }

        let sourceLanguageCode = embedded.lyricsLanguageCode
            ?? embedded.languageTaggedLyrics.first(where: {
                $0.value == originalText
            })?.key
        if let sourceLanguageCode,
           LyricTranslationGroupingPolicy.declaredLanguageCode(
               in: lines.first?.metadataLines ?? []
           ) == nil {
            var metadataLines = lines[0].metadataLines ?? []
            metadataLines.append("[la:\(sourceLanguageCode)]")
            lines[0].metadataLines = metadataLines
        }

        struct TranslationDocument {
            let text: String
            let languageCode: String?
            let makePreferred: Bool
        }
        var translationDocuments: [TranslationDocument] = []
        var seenDocuments: Set<String> = []

        func appendTranslation(
            _ text: String?,
            languageCode: String?,
            makePreferred: Bool
        ) {
            guard let text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != originalText else { return }
            let normalizedLanguage = languageCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let identity = normalizedLanguage + "\u{0}" + trimmed
            guard seenDocuments.insert(identity).inserted else { return }
            translationDocuments.append(
                TranslationDocument(
                    text: trimmed,
                    languageCode: languageCode,
                    makePreferred: makePreferred
                )
            )
        }

        let explicitTranslationLanguage = embedded.translatedLyricsLanguageCode
            ?? embedded.languageTaggedTranslations.first(where: {
                $0.value == embedded.translatedLyricsText
            })?.key
        appendTranslation(
            embedded.translatedLyricsText,
            languageCode: explicitTranslationLanguage,
            makePreferred: true
        )
        let taggedTranslations = embedded.languageTaggedTranslations.sorted(by: {
            $0.key < $1.key
        })
        let prefersOnlyTaggedTranslation = embedded.translatedLyricsText == nil
            && taggedTranslations.count == 1
        for (languageCode, text) in taggedTranslations {
            appendTranslation(
                text,
                languageCode: languageCode,
                makePreferred: prefersOnlyTaggedTranslation
            )
        }
        let taggedLyricAlternates = embedded.languageTaggedLyrics
            .sorted(by: { $0.key < $1.key })
            .filter { entry in
                entry.key.caseInsensitiveCompare(sourceLanguageCode ?? "") != .orderedSame
            }
        for (languageCode, text) in taggedLyricAlternates {
            appendTranslation(
                text,
                languageCode: languageCode,
                // An alternate language-tagged original (notably a second
                // unmarked ID3 USLT) may be a duet or romanization rather than
                // a translation. Retain it for exact target-language lookup,
                // but never make it the editor/presentation default.
                makePreferred: false
            )
        }

        for document in translationDocuments {
            let translatedLines = LyricsContentParser.parseText(
                document.text,
                options: .literal
            )
            guard !translatedLines.isEmpty else { continue }
            lines = LyricManualTranslationPolicy.merging(
                originalLines: lines,
                translatedLines: translatedLines,
                translationLanguageCode: document.languageCode,
                source: .embeddedField,
                makePreferred: document.makePreferred
            )
        }
        return lines
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
            let previousArtist = result.artist
            let previousAlbumArtist = result.albumArtist
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
            if result.artist != previousArtist {
                result.sourceArtistNames = nil
            }
            result.albumTitle = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.albumTitle,
                scraped: detail.album,
                overwrite: overwriteMetadata
            )
            let scrapedAlbumArtist = ScrapeMetadataApplicationPolicy.resolvedText(
                original: result.albumArtist,
                scraped: detail.albumArtist,
                overwrite: overwriteMetadata
            )
            if detail.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                result.albumArtist = scrapedAlbumArtist
            } else {
                result.albumArtist = AlbumGroupingPolicy.updatedAlbumArtistName(
                    existingAlbumArtistName: previousAlbumArtist,
                    previousTrackArtistName: previousArtist,
                    updatedTrackArtistName: result.artist
                )
            }
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
