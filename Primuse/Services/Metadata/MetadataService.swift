import Foundation
import PrimuseKit

actor MetadataService {
    private let scraperManager: ScraperManager
    private let assetStore = MetadataAssetStore.shared

    init(scraperManager: ScraperManager = ScraperManager()) {
        self.scraperManager = scraperManager
    }

    struct SongMetadata {
        var unavailableScrapeParts: ScrapeParts = []
        var scrapeRetryAfter: TimeInterval = 5
        var contentMetadata: SongContentMetadata? = nil
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
        /// 音轨编码（ALAC / AAC…），只有读到音轨格式时才有。
        var audioCodec: AudioFormat? = nil
        /// FLAC 查出的实际位深,只有读到音频帧时才有。
        var effectiveBitDepth: Int? = nil
        var coverArtData: Data? = nil
        var artworkOrigin: StoredArtworkOrigin? = nil
        var coverArtFileName: String? = nil
        var lyricsFileName: String? = nil
        var mvPath: String? = nil
        var lyrics: [LyricLine]? = nil
        /// 文件里同一首歌的原文歌词不止一份时的全貌，跟内嵌歌词一起存，改了设置按它重挑。
        var embeddedLyricsAlternatives: EmbeddedLyricsAlternatives? = nil
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
        var review = ScrapeReviewCatalog()
        var hasMatchedTitle = false

        var scrapeFields: ScrapedMetadataMergePolicy.Fields {
            .init(title: title, artist: artist, sourceArtistNames: sourceArtistNames,
                  albumTitle: albumTitle, albumArtist: albumArtist, year: year, genre: genre,
                  trackNumber: trackNumber, discNumber: discNumber)
        }
    }

    /// Load metadata with priority: embedded → verified sidecar → online
    ///
    /// `trustedSource`: 是否把结果直接写入 hash cache。
    /// - true（默认）: 扫描 / Backfill 路径,数据来自 embedded/sidecar,可信。
    /// - false: ScraperService 路径,可能错配,**不写 cache**。
    ///   由 ScraperService 在用户确认/应用刮削结果时写入本地 cache；dry-run
    ///   路径只返回预期文件名,不会提前污染现有缓存。
    func loadMetadata(
        for url: URL,
        cacheKey: String? = nil,
        allowOnlineFetch: Bool = true,
        trustedSource: Bool = true,
        fallbackTitle: String? = nil,
        forceOnlineRefresh: Bool = false,
        existingCoverReference: String? = nil,
        discoverSidecars: Bool = true,
        storesLyrics: Bool = true,
        scrapeRequest: ScrapeFieldRequest? = nil,
        scraperSettings: ScraperSettings? = nil,
        librarySong: Song? = nil,
        collectingReview: Bool = false
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
            // GBK bytes read as EUC-KR are valid Hangul and pass the suspicion
            // check; a scrape then stamps them as a user edit, which shields
            // them from the library's own file-name repair for good.
            if let confirmed = MediaMetadataTextRepair.fileNameCorroboratedTitle(t, fileStem: titleFallback) {
                return confirmed
            }
            guard !MediaMetadataTextRepair.isSuspicious(t)
                    || MediaMetadataTextRepair.isSuspicious(titleFallback) else {
                return nil
            }
            return embedded.title
        }()
        let embeddedArtist = MediaMetadataTextRepair.fileNameCorroboratedArtist(
            embedded.artist, fileStem: titleFallback
        ) ?? embedded.artist
        let embeddedSourceArtists = embedded.sourceArtistNames.map { names in
            names.map { $0 == embedded.artist ? embeddedArtist ?? $0 : $0 }
        }

        let correctedTitle = MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: trustedEmbeddedTitle, artist: embeddedArtist, fileStem: titleFallback
        )
        let correctedArtist = MetadataTitleResolutionPolicy.artistCorrectingDuplicatedArtist(
            title: trustedEmbeddedTitle, artist: embeddedArtist, fileStem: titleFallback
        )
        var result = SongMetadata(
            contentMetadata: embedded.contentMetadata,
            title: correctedTitle ?? trustedEmbeddedTitle ?? titleFallback,
            artist: correctedArtist ?? embeddedArtist,
            embeddedTitle: MediaMetadataTextRepair.repaired(trustedEmbeddedTitle),
            embeddedArtist: MediaMetadataTextRepair.repaired(embeddedArtist),
            sourceArtistNames: correctedArtist.map { [$0] } ?? embeddedSourceArtists,
            albumTitle: embedded.albumTitle,
            albumArtist: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: embedded.albumArtist,
                trackArtistName: correctedArtist ?? embeddedArtist
            ),
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: embedded.genre,
            duration: TimeInterval.sanitized(embedded.duration),
            sampleRate: embedded.sampleRate,
            bitRate: embedded.bitRate,
            bitDepth: embedded.bitDepth,
            audioCodec: embedded.audioCodec,
            effectiveBitDepth: embedded.effectiveBitDepth,
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
        if discoverSidecars,
           result.coverArtData == nil,
           let coverURL = SidecarMetadataLoader.findCoverArt(for: url, albumTitle: result.albumTitle) {
            result.coverArtFileName = coverURL.lastPathComponent
            if let data = try? Data(contentsOf: coverURL) {
                result.coverArtData = data
                result.artworkOrigin = .sidecar
                result.hasVerifiedSidecarMetadata = true
            }
        }

        // 歌旁边的歌词文件优先于内嵌歌词; 文件读不出内容时才退回内嵌的那份。
        var sidecarSupersedesEmbeddedLyrics = false
        if discoverSidecars,
           let lyricsURL = SidecarMetadataLoader.findLyrics(for: url) {
            let parsed = SidecarMetadataLoader.loadLyrics(at: lyricsURL)
            sidecarSupersedesEmbeddedLyrics = embedded.lyricsText != nil && parsed?.isEmpty == false
            if embedded.lyricsText == nil || parsed?.isEmpty == false {
                result.lyricsFileName = lyricsURL.lastPathComponent
                result.lyrics = parsed
                if parsed?.isEmpty == false {
                    result.hasVerifiedSidecarMetadata = true
                }
            }
        }

        if discoverSidecars,
           let mvURL = SidecarMetadataLoader.findMusicVideo(for: url) {
            result.mvPath = mvURL.lastPathComponent
            result.hasVerifiedSidecarMetadata = true
        }

        // 2.5 Parse embedded lyrics when present.
        result.embeddedLyricsAlternatives = embedded.embeddedLyricsAlternatives
        if result.lyrics == nil {
            result.lyrics = FileMetadataReader.parsedEmbeddedLyrics(from: embedded)
        }

        // 3. Try online sources as fallback
        let preservesExistingCover = existingCoverReference?.isEmpty == false
            && !(scrapeRequest?.overwrites.contains(.cover) ?? forceOnlineRefresh)
        if allowOnlineFetch {
            let settings = scraperSettings ?? ScraperSettings.load()
            let requested = scrapeRequest ?? settings.fieldRules.request(overwriteByDefault: forceOnlineRefresh)
            if scrapeRequest != nil { result.albumArtist = embedded.albumArtist }
            let online = collectingReview ? requested : requested.needed(
                for: result.scrapeFields, hasCover: preservesExistingCover || result.coverArtData != nil,
                hasLyrics: result.lyrics?.isEmpty == false, titleIsPlaceholder: trustedEmbeddedTitle == nil
            )
            await fetchOnlineMetadata(for: &result, request: online, settings: settings, librarySong: librarySong, collectingReview: collectingReview)
        }

        // A cached audio file may have no neighbouring image even though the
        // library already points to a cover in the source directory.
        if preservesExistingCover {
            result.coverArtFileName = existingCoverReference
            result.coverArtData = nil
            result.artworkOrigin = nil
        }

        if let cacheKey {
            if let coverArtData = result.coverArtData {
                if trustedSource {
                    result.coverArtFileName = await assetStore.storeAttributedCover(coverArtData, songID: cacheKey, origin: result.artworkOrigin ?? .embedded)
                } else {
                    // 仅占位 ref,不写 cache 文件 —— dry-run 预览和直接刮削都需要
                    // 先知道最终 ref,实际写入由 ScraperService 在应用结果时完成。
                    result.coverArtFileName = assetStore.expectedCoverFileName(for: cacheKey)
                }
            }
            if storesLyrics, trustedSource, sidecarSupersedesEmbeddedLyrics,
               let embeddedLyrics = FileMetadataReader.parsedEmbeddedLyrics(from: embedded) {
                // 歌词文件不在了再用。
                await assetStore.storeEmbeddedFallbackLyrics(embeddedLyrics, forSongID: cacheKey)
                await assetStore.storeEmbeddedLyricsAlternatives(result.embeddedLyricsAlternatives, forSongID: cacheKey)
            }
            if storesLyrics, let lyrics = result.lyrics {
                if trustedSource {
                    result.lyricsFileName = await assetStore.storeLyrics(lyrics, for: cacheKey)
                    if LyricsDocumentSource.of(lyrics)?.kind == .embedded {
                        await assetStore.storeEmbeddedLyricsAlternatives(result.embeddedLyricsAlternatives, forSongID: cacheKey)
                    }
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
        fallbackTitle: String,
        readSession: FileMetadataReader.RangeReadSession? = nil
    ) async -> SongMetadata {
        let signature = AudioFileSignaturePolicy.inspect(data)
        let parserFileExtension = RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: fileExtension,
            signature: signature
        )
        var embedded: FileMetadataReader.Metadata
        if let readSession {
            embedded = await readSession.read(from: data, fileExtension: parserFileExtension,
                                              id3TailData: id3TailData)
        } else {
            embedded = await FileMetadataReader.read(from: data, fileExtension: parserFileExtension,
                                                     id3TailData: id3TailData)
        }
        if let containerTailData,
           let tailMetadata = await FileMetadataReader.readISOBaseMediaMetadata(
            head: data,
            tail: containerTailData,
            fileExtension: parserFileExtension
           ) {
            embedded.fillMissing(from: tailMetadata)
        }
        let repairedFallback = FileMetadataReader.repairLegacyChineseMojibake(fallbackTitle)
        let correctedTitle = MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: embedded.title, artist: embedded.artist, fileStem: repairedFallback
        )
        let correctedArtist = MetadataTitleResolutionPolicy.artistCorrectingDuplicatedArtist(
            title: embedded.title, artist: embedded.artist, fileStem: repairedFallback
        )
        let preferredTitle = correctedTitle ?? MediaMetadataTextRepair.preferred(
            embedded: embedded.title,
            fromFileName: repairedFallback
        ) ?? repairedFallback

        var result = SongMetadata(
            contentMetadata: embedded.contentMetadata,
            title: preferredTitle,
            artist: correctedArtist ?? MediaMetadataTextRepair.repaired(embedded.artist),
            embeddedTitle: MediaMetadataTextRepair.repaired(embedded.title),
            embeddedArtist: MediaMetadataTextRepair.repaired(embedded.artist),
            sourceArtistNames: correctedArtist.map { [$0] } ?? embedded.sourceArtistNames?.compactMap {
                MediaMetadataTextRepair.repaired($0)
            },
            albumTitle: MediaMetadataTextRepair.repairedAlbumTitle(
                embedded.albumTitle, artist: embedded.artist, albumArtist: embedded.albumArtist
            ),
            albumArtist: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: MediaMetadataTextRepair.repaired(embedded.albumArtist),
                trackArtistName: correctedArtist ?? MediaMetadataTextRepair.repaired(embedded.artist)
            ),
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: MediaMetadataTextRepair.repaired(embedded.genre),
            duration: TimeInterval.sanitized(embedded.duration),
            sampleRate: embedded.sampleRate,
            bitRate: embedded.bitRate,
            bitDepth: embedded.bitDepth,
            audioCodec: embedded.audioCodec,
            effectiveBitDepth: embedded.effectiveBitDepth,
            coverArtData: embedded.coverArtData,
            replayGainTrackGain: embedded.replayGainTrackGain,
            replayGainTrackPeak: embedded.replayGainTrackPeak,
            replayGainAlbumGain: embedded.replayGainAlbumGain,
            replayGainAlbumPeak: embedded.replayGainAlbumPeak,
            hasEmbeddedDescriptiveMetadata: embedded.hasDescriptiveMetadata,
            hasTechnicalProperties: embedded.hasTechnicalProperties,
            detectedFileSignature: signature
        )

        if let lyrics = FileMetadataReader.parsedEmbeddedLyrics(from: embedded) {
            result.lyrics = lyrics
            result.embeddedLyricsAlternatives = embedded.embeddedLyricsAlternatives
        }

        if let cacheKey {
            result = await storingEmbeddedAssets(in: result, cacheKey: cacheKey)
        }
        return result
    }

    /// - Parameter storesLyrics: false keeps the file's lyrics out of this
    ///   key's cache — a CUE virtual track with its own lyric file must not
    ///   inherit the whole image's embedded lyrics.
    func storingEmbeddedAssets(
        in metadata: SongMetadata,
        cacheKey: String,
        storesLyrics: Bool = true
    ) async -> SongMetadata {
        var result = metadata
        if result.coverArtFileName == nil, let coverArtData = result.coverArtData {
            result.coverArtFileName = await assetStore.storeAttributedCover(coverArtData, songID: cacheKey, origin: .embedded)
        }
        if storesLyrics, result.lyricsFileName == nil, let lyrics = result.lyrics {
            result.lyricsFileName = await assetStore.storeLyrics(lyrics, for: cacheKey)
            if LyricsDocumentSource.of(lyrics)?.kind == .embedded {
                await assetStore.storeEmbeddedLyricsAlternatives(result.embeddedLyricsAlternatives, forSongID: cacheKey)
            }
        }
        return result
    }

    /// Range-backed and server libraries already supply a search identity without reading audio.
    func fillMissingOnline(seed: Song, title: String, request: ScrapeFieldRequest,
                           settings: ScraperSettings, collectingReview: Bool = false) async -> SongMetadata {
        var result = SongMetadata(
            title: title, artist: seed.artistName, sourceArtistNames: seed.sourceArtistNames,
            albumTitle: seed.albumTitle, albumArtist: seed.albumArtistName,
            trackNumber: seed.trackNumber, discNumber: seed.discNumber,
            year: seed.year, genre: seed.genre, duration: seed.duration,
            sampleRate: seed.sampleRate, bitRate: seed.bitRate, bitDepth: seed.bitDepth
        )
        await fetchOnlineMetadata(for: &result, request: request, settings: settings, collectingReview: collectingReview)
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

    func fieldReview(for song: Song, query: String, parts: ScrapeParts, searchLimit: Int) async -> ScrapeReviewCatalog {
        await scraperManager.review(for: song, query: query, settings: .load(), parts: parts, searchLimit: searchLimit)
    }

    func manualLyricsCandidates(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async -> [ScraperManager.ManualLyricsCandidate] {
        await scraperManager.manualLyricsCandidates(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            settings: ScraperSettings.load()
        )
    }

    private func fetchOnlineMetadata(
        for result: inout SongMetadata,
        request: ScrapeFieldRequest,
        settings: ScraperSettings,
        librarySong: Song? = nil,
        collectingReview: Bool = false
    ) async {
        guard !request.fields.isEmpty else { return }
        let tags = request.fields.intersection(ScrapeField.tags)
        let segment = librarySong?.isCueTrack == true
        let seedTitle = (segment || result.embeddedTitle == nil) && librarySong?.title.isEmpty == false
            ? librarySong?.title : nil
        let scrapeResult = await scraperManager.scrapeMetadata(
            title: seedTitle ?? result.title,
            artist: segment ? librarySong?.artistName : (result.artist ?? librarySong?.artistName),
            album: segment ? librarySong?.albumTitle : (result.albumTitle ?? librarySong?.albumTitle),
            duration: segment || result.duration <= 0 ? (librarySong?.duration ?? result.duration) : result.duration,
            needs: ScraperManager.ScrapeNeeds(
                metadata: !tags.isEmpty,
                cover: request.fields.contains(.cover),
                lyrics: request.fields.contains(.lyrics),
                metadataFields: tags
            ),
            settings: settings, collectingReview: collectingReview
        )

        result.review = scrapeResult.review
        result.unavailableScrapeParts = scrapeResult.unavailableParts
        result.scrapeRetryAfter = scrapeResult.retryAfter
        // Apply metadata from detail. 合并规则与 Apple TV 共用 (`ScrapedMetadataMergePolicy`)。
        if let detail = scrapeResult.detail {
            let merged = request.merging(result.scrapeFields, candidate: .init(detail))
            result.hasMatchedTitle = request.fields.contains(.title) && !detail.title.isEmpty
            result.title = merged.title
            result.artist = merged.artist
            result.sourceArtistNames = merged.sourceArtistNames
            result.albumTitle = merged.albumTitle
            result.albumArtist = merged.albumArtist
            result.year = merged.year
            result.genre = merged.genre
            result.trackNumber = merged.trackNumber
            result.discNumber = merged.discNumber
        }

        // Apply cover data
        if let coverData = scrapeResult.coverData {
            result.coverArtData = coverData
            result.artworkOrigin = .scraped
        }

        // Apply lyrics
        if let lyrics = scrapeResult.lyrics {
            result.lyrics = lyrics
        }
    }
}
