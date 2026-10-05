#if os(tvOS)
import CryptoKit
import Foundation
import PrimuseKit

// Apple TV 上的刮削。
//
// 刮削引擎(`ScraperManager`)、刮削源设置(`ScraperSettings`,经 iCloud 键值同步或
// 扫码直传到电视)、候选排序与字段合并规则都和 iPhone 同一份。电视不改音乐源:
// 结果只写本机的封面 / 歌词缓存和曲库,另记一份本机改动台账,手机快照整份覆盖曲库
// 之后按台账补回来。

/// 手动匹配的一条搜索候选。
struct TVScrapeCandidate: Identifiable, Sendable {
    let id: String
    let item: ScraperSearchItem
    let sourceConfig: ScraperSourceConfig
    let rank: ScrapeCandidateRank
    let searchOrder: Int

    /// 0...1 的匹配度,与 iPhone 候选列表右侧的百分比同一个算法。
    var confidence: Double { rank.confidence }
    var sourceName: String { sourceConfig.displayName }
}

struct TVScrapeSearchOutcome: Sendable {
    var candidates: [TVScrapeCandidate]
    /// 实际去搜了几个源;0 表示一个能按关键词搜的源都没启用。
    var searchedSourceCount: Int
}

/// 选中候选之后的预览:原来的标签、候选给的标签,以及取到的封面和歌词。
struct TVScrapePreview: Sendable {
    let songID: String
    let original: ScrapedMetadataMergePolicy.Fields
    let proposed: ScrapedMetadataMergePolicy.Fields
    let coverData: Data?
    let lyrics: [LyricLine]?

    var tagsChanged: Bool { !TVMetadataScrapeService.sameVisibleTags(original, proposed) }

    func droppingCover() -> TVScrapePreview {
        TVScrapePreview(songID: songID, original: original, proposed: proposed, coverData: nil, lyrics: lyrics)
    }
}

struct TVAlbumScrapeProgress: Sendable, Equatable {
    let index: Int
    let total: Int
    let songTitle: String
}

struct TVAlbumScrapeResult: Sendable, Equatable {
    var total = 0
    /// 标签、封面、歌词至少补上了一样的歌。
    var updated = 0
    /// 没什么可补、或者没找到可信结果的歌。
    var unchanged = 0
    /// 一个刮削源都没启用,什么都没做。
    var noEnabledSource = false
    var cancelled = false
}

/// 「恢复文件标签」的进度与结果。
struct TVRestoreFileTagsProgress: Sendable, Equatable {
    /// 要按文件重读的首数。
    var total = 0
    var processed = 0
    var completed = 0
    var failed = 0
    /// 服务器曲库源、电视读不了文件的源,以及读的时候正在扫描的:只撤了改动标记。
    var skipped = 0
    var isFinished = false
}

@MainActor
final class TVMetadataScrapeService {
    private weak var store: TVStore?
    private let scraperManager = ScraperManager()
    private let overrides: TVMetadataOverrideStore
    private var artworkRestoreObserver: NSObjectProtocol?
    private var artworkReplayTask: Task<Void, Never>?

    /// 手动搜索每个源取多少条,与 iPhone 刮削页的默认值一致。
    private static let manualSearchLimit = 20

    init(store: TVStore, overrides: TVMetadataOverrideStore = .shared) {
        self.store = store
        self.overrides = overrides
    }

    // MARK: - 播放时的在线歌词兜底

    /// 源里、服务端都没有歌词时,按启用顺序向在线歌词源取一次并写入缓存。闸门与 iOS 的
    /// Tier4 相同:「找不到歌词时自动在线获取」开着、有能用的歌词源、不是有声内容、
    /// 同一首 6 小时内没问过。任务被取消或没取到 → nil。
    func automaticOnlineLyrics(for song: Song, source: MusicSource) async -> [LyricLine]? {
        guard let store, !Task.isCancelled else { return nil }
        // Apple Music 的歌词由系统播放器负责;有声内容的标题是章节名,搜到的只会是同名歌曲。
        guard source.type != .appleMusic, source.type != .appleMusicLibrary,
              !store.isSpokenWord(songID: song.id) else { return nil }
        let settings = ScraperSettings.load()
        guard AutomaticOnlineLyricsGate.allowsAutomaticFetch(settings: settings) else { return nil }
        guard await AutomaticOnlineLyricsLedger.shared.shouldAttempt(songID: song.id),
              !Task.isCancelled else { return nil }
        let result = await scraperManager.scrapeMetadata(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil,
            needs: ScraperManager.ScrapeNeeds(metadata: false, cover: false, lyrics: true),
            settings: settings
        )
        guard !Task.isCancelled, let lines = result.lyrics, !lines.isEmpty else { return nil }
        let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
            lines,
            forSongID: song.id,
            expectedFingerprint: nil,
            force: false
        )
        if wrote { return lines }
        // 并发的匹配 / 同步写入赢了:以缓存里最新的为准,不覆盖它。
        guard let latest = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
              !latest.isEmpty else { return nil }
        return latest
    }

    // MARK: - 手动匹配

    /// 搜索框的初始内容:「标题 艺人」,规则与 iPhone 刮削页相同
    /// (云盘无标签歌曲的「歌手 - 标题」文件名会先拆开,歌手已在标题里就不重复)。
    nonisolated static func suggestedQuery(title: String, artist: String?) -> String {
        let identity = ScraperManager.searchTitleArtist(title, artist: artist)
        var query = identity.title
        if let effectiveArtist = identity.artist,
           !effectiveArtist.isEmpty,
           ScraperManager.shouldAppendArtist(to: query, artist: effectiveArtist) {
            query += " \(effectiveArtist)"
        }
        return query
    }

    /// 按关键词搜所有启用的、支持元数据搜索的源,候选按与 iPhone 相同的规则排序。
    func searchCandidates(for song: Song, query: String) async -> TVScrapeSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = ScraperSettings.load().enabledSources.filter(Self.canSearchManually)
        guard !trimmed.isEmpty, !sources.isEmpty else {
            return TVScrapeSearchOutcome(candidates: [], searchedSourceCount: sources.count)
        }
        let identity = ScraperManager.searchTitleArtist(song.title, artist: song.artistName)
        let requestedTitle = identity.title.isEmpty ? song.title : identity.title
        let targetDurationMs: Int? = song.duration.isFinite && song.duration > 0
            ? Int((song.duration * 1000).rounded())
            : nil
        var candidates: [TVScrapeCandidate] = []
        var seenIDs = Set<String>()
        for config in sources {
            guard !Task.isCancelled else { break }
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let result = try await scraper.search(
                    query: trimmed, artist: nil, album: nil, limit: Self.manualSearchLimit
                )
                for item in result.items {
                    let id = "\(config.type.rawValue)_\(item.externalId)"
                    guard seenIDs.insert(id).inserted else { continue }
                    let rank = ScrapeCandidateRankingPolicy.rank(
                        requestedTitle: requestedTitle,
                        requestedArtist: identity.artist,
                        targetDurationMs: targetDurationMs,
                        candidateTitle: item.title,
                        candidateArtist: item.artist,
                        candidateDurationMs: item.durationMs,
                        candidateAlbum: item.album,
                        candidateYear: item.year,
                        candidateHasArtwork: item.coverUrl?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                        candidateTrackNumber: item.trackNumber,
                        candidateGenreCount: item.genres?.filter {
                            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }.count ?? 0
                    )
                    candidates.append(TVScrapeCandidate(
                        id: id,
                        item: item,
                        sourceConfig: config,
                        rank: rank,
                        searchOrder: candidates.count
                    ))
                }
            } catch {
                guard !Task.isCancelled else { break }
                plog("⚠️ TV scrape search failed for \(config.type.rawValue): \(ConfigurableScraper.describeNetworkError(error))")
            }
        }
        candidates.sort { lhs, rhs in
            if ScrapeCandidateRankingPolicy.isPreferred(lhs.rank, over: rhs.rank) { return true }
            if ScrapeCandidateRankingPolicy.isPreferred(rhs.rank, over: lhs.rank) { return false }
            return lhs.searchOrder < rhs.searchOrder
        }
        return TVScrapeSearchOutcome(candidates: candidates, searchedSourceCount: sources.count)
    }

    /// 取选中候选的详情、封面和歌词。歌词不看候选来自哪个源(iTunes、MusicBrainz 本身
    /// 不给歌词),与 iPhone 一样按候选的标题/歌手走启用的歌词源。
    func preview(_ candidate: TVScrapeCandidate, for song: Song) async throws -> TVScrapePreview {
        let scraper = MusicScraperFactory.create(for: candidate.sourceConfig)
        let detail = try await scraper.getDetail(externalId: candidate.item.externalId)
        try Task.checkCancellation()
        let item = candidate.item

        let title = Self.firstNonEmpty(detail?.title, item.title) ?? song.title
        let artist = Self.firstNonEmpty(detail?.artist, item.artist, song.artistName)
        let album = Self.firstNonEmpty(detail?.album, item.album, song.albumTitle)
        let coverURL = Self.firstNonEmpty(detail?.coverUrl, item.coverUrl)
        let genres = Self.firstNonEmptyGenres(detail?.genres, item.genres)
        let durationMs = Self.firstPositive(detail?.durationMs, item.durationMs)

        let original = song.scrapeFields
        var proposed = original
        proposed.title = title
        proposed.artist = artist
        if artist != song.artistName { proposed.sourceArtistNames = nil }
        proposed.albumTitle = album
        // 专辑艺术家:候选明确给了就用;原来只是「跟着曲目歌手」的回退值时跟着新歌手走。
        proposed.albumArtist = AlbumGroupingPolicy.updatedAlbumArtistName(
            existingAlbumArtistName: song.albumArtistName,
            previousTrackArtistName: song.artistName,
            updatedTrackArtistName: artist,
            incomingAlbumArtistName: detail?.albumArtist
        )
        proposed.genre = genres?.prefix(3).joined(separator: ", ") ?? song.genre
        proposed.year = Self.firstPositive(detail?.year, item.year, song.year)
        proposed.trackNumber = Self.firstPositive(detail?.trackNumber, item.trackNumber, song.trackNumber)
        proposed.discNumber = Self.firstPositive(detail?.discNumber, song.discNumber)
        // CUE 分轨的歌手、专辑、音轨号、碟号以 CUE 表为准;候选常是别的版本或合辑,
        // 勾「标签」时照搬会把这一首拆出专辑,只让年份、流派、标题跟着候选走。
        if song.isCueTrack {
            proposed.artist = ScrapeCueIdentityPolicy.resolvedOptionalText(
                original: original.artist, scraped: proposed.artist, isCueTrack: true
            )
            proposed.sourceArtistNames = proposed.artist == original.artist
                ? original.sourceArtistNames : proposed.sourceArtistNames
            proposed.trackNumber = original.trackNumber ?? proposed.trackNumber
            proposed = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(proposed, original: original)
        }

        var coverData: Data?
        if let coverURL {
            coverData = try? await ConfigurableScraper.downloadResource(
                from: coverURL,
                sourceConfig: candidate.sourceConfig,
                timeout: 10
            )
            if let data = coverData, data.isEmpty { coverData = nil }
        }
        try Task.checkCancellation()

        let lyricsDuration = durationMs.map { TimeInterval($0) / 1000 } ?? song.duration
        let lyricsResult = await scraperManager.scrapeMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: lyricsDuration > 0 ? lyricsDuration : nil,
            needs: ScraperManager.ScrapeNeeds(metadata: false, cover: false, lyrics: true),
            settings: ScraperSettings.load()
        )
        try Task.checkCancellation()
        let lyrics = lyricsResult.lyrics.flatMap { $0.isEmpty ? nil : $0 }

        return TVScrapePreview(
            songID: song.id,
            original: original,
            proposed: proposed,
            coverData: coverData,
            lyrics: lyrics
        )
    }

    /// 把预览里勾选的部分写进本机:封面、歌词进缓存,勾选的标签改曲库里这一行并打上用户
    /// 编辑的时间戳(电视自己重扫时保留)。不写回音乐源。返回是否真的改了什么。
    @discardableResult
    func apply(
        _ preview: TVScrapePreview,
        fields: Set<ScrapeTagField>,
        cover: Bool,
        lyrics: Bool
    ) async -> Bool {
        guard let store, var song = store.library.song(id: preview.songID) else { return false }
        let editedAt = Self.editTimestamp()
        var appliedCover: Data?
        var appliedLyrics: [LyricLine]?

        // 没勾的标签保持这一行现在的值(预览打开之后它可能已经变了)。
        let current = song.scrapeFields
        var chosen = current.applying(preview.proposed, fields: fields)
        // 勾了「艺术家」时专辑艺术家会跟着新艺术家走;CUE 分轨的专辑归属不能因此改变。
        if song.isCueTrack {
            chosen = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(chosen, original: current)
        }
        let appliedTags = !Self.sameVisibleTags(current, chosen)
        if appliedTags {
            song.applyScrapeFields(chosen)
        }
        if cover, let data = preview.coverData,
           await storeCover(data, forSongID: song.id) {
            song.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: song.id)
            appliedCover = data
        }
        if lyrics, let lines = preview.lyrics, !lines.isEmpty,
           await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: song.id, force: true) {
            song.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
            appliedLyrics = lines
        }
        guard appliedTags || appliedCover != nil || appliedLyrics != nil else { return false }
        if appliedTags || appliedCover != nil {
            song.userMetadataEditedAt = editedAt
        }
        store.library.replaceSong(song)
        await overrides.record(
            songID: song.id,
            kind: .chosen,
            editedAt: editedAt,
            fields: appliedTags ? song.scrapeFields : nil,
            cover: appliedCover,
            lyrics: appliedLyrics
        )
        store.refreshNowPlayingAfterMetadataEdit(song, lyrics: appliedLyrics)
        Self.postArtworkChanged(songs: [song])
        return true
    }

    // MARK: - 整张专辑补全

    /// 为一张专辑的每首歌补标签、封面和歌词。「只补全缺失字段」开着时只填空着的;关着时
    /// 用可信的在线结果覆盖(服务端曲库源的标签归服务端管,始终只补空缺,歌词也不去在线找)。
    /// 逐首串行,`progress` 在主线程上报当前是第几首。任务取消后停在当前这首。
    /// `parts`:只补歌词或只补封面时其余部分不请求、不写。
    func scrapeMissingMetadata(
        albumID: String,
        parts: ScrapeParts = .all,
        progress: @escaping @MainActor (TVAlbumScrapeProgress) -> Void
    ) async -> TVAlbumScrapeResult {
        guard let store else { return TVAlbumScrapeResult() }
        let songs = store.library.songs(forAlbum: albumID)
        var result = TVAlbumScrapeResult(total: songs.count)
        let settings = ScraperSettings.load()
        guard !settings.enabledSources.isEmpty else {
            result.noEnabledSource = true
            return result
        }
        for (index, original) in songs.enumerated() {
            guard !Task.isCancelled else {
                result.cancelled = true
                break
            }
            progress(TVAlbumScrapeProgress(index: index + 1, total: songs.count, songTitle: original.title))
            // 前面几首改了专辑名的话专辑会重新分组,这里按 id 取最新的一行。
            guard let song = store.library.song(id: original.id) else {
                result.unchanged += 1
                continue
            }
            if await fillMissing(song, settings: settings, parts: parts) {
                result.updated += 1
            } else {
                result.unchanged += 1
            }
        }
        if Task.isCancelled { result.cancelled = true }
        return result
    }

    private func fillMissing(_ song: Song, settings: ScraperSettings, parts: ScrapeParts) async -> Bool {
        guard let store else { return false }
        let sourceType = store.sourcesStore.source(id: song.sourceID)?.type
        let isServerLibrary = sourceType.map {
            TVLyricsLoadingPolicy.strategy(for: $0) != .sourceFile
        } ?? false
        let overwrite = !settings.onlyFillMissingFields && !isServerLibrary
        let fields = song.scrapeFields
        let fieldsAreMissing = fields.artist?.isEmpty != false
            || fields.albumTitle?.isEmpty != false
            || fields.year == nil
            || fields.genre?.isEmpty != false
        let needsMetadata = parts.contains(.metadata) && ScrapeMetadataApplicationPolicy.shouldRequestMetadata(
            fieldsAreMissing: fieldsAreMissing,
            forceRefresh: overwrite
        )
        let hasCover: Bool
        if song.coverArtFileName?.isEmpty == false {
            hasCover = true
        } else {
            hasCover = await MetadataAssetStore.shared.cachedCoverData(forSongID: song.id) != nil
        }
        let needsCover = parts.contains(.cover) && (overwrite || !hasCover)
        let hasLyrics: Bool
        if song.lyricsFileName?.isEmpty == false {
            hasLyrics = true
        } else {
            hasLyrics = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)?.isEmpty == false
        }
        let needsLyrics = parts.contains(.lyrics)
            && !isServerLibrary
            && !store.isSpokenWord(songID: song.id)
            && (overwrite || !hasLyrics)
        guard needsMetadata || needsCover || needsLyrics else { return false }

        let scraped = await scraperManager.scrapeMetadata(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil,
            needs: ScraperManager.ScrapeNeeds(metadata: needsMetadata, cover: needsCover, lyrics: needsLyrics),
            settings: settings
        )
        guard !Task.isCancelled,
              var updated = store.library.song(id: song.id) else { return false }
        let editedAt = Self.editTimestamp()

        var appliedTags = false
        if needsMetadata, let detail = scraped.detail {
            let current = updated.scrapeFields
            var merged = ScrapedMetadataMergePolicy.merged(
                current,
                with: ScrapedMetadataMergePolicy.Candidate(detail),
                overwrite: overwrite
            )
            // CUE 虚拟音轨的标题、歌手、专辑、专辑艺术家、轨号、碟号来自 CUE 表,
            // 在线结果描述的是整个音频文件,覆盖模式下也不能换。
            if updated.isCueTrack {
                merged = ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: current)
            }
            if !Self.sameVisibleTags(current, merged) {
                updated.applyScrapeFields(merged)
                appliedTags = true
            }
        }
        var appliedCover: Data?
        if needsCover, let data = scraped.coverData,
           await storeCover(data, forSongID: updated.id) {
            updated.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: updated.id)
            appliedCover = data
        }
        var appliedLyrics: [LyricLine]?
        if needsLyrics, let lines = scraped.lyrics, !lines.isEmpty,
           await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: updated.id, force: overwrite) {
            updated.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: updated.id)
            appliedLyrics = lines
        }
        guard appliedTags || appliedCover != nil || appliedLyrics != nil else { return false }
        // 覆盖模式改掉的是已有的标签,要像手动编辑一样挡住电视自己的重扫;只补空缺时
        // 不打标记,文件里后来补上的真标签重扫时还能读进来。
        if overwrite, appliedTags || appliedCover != nil {
            updated.userMetadataEditedAt = editedAt
        }
        store.library.replaceSong(updated)
        await overrides.record(
            songID: updated.id,
            kind: overwrite ? .chosen : .filledMissing,
            editedAt: editedAt,
            fields: appliedTags ? updated.scrapeFields : nil,
            cover: appliedCover,
            lyrics: appliedLyrics
        )
        store.refreshNowPlayingAfterMetadataEdit(updated, lyrics: appliedLyrics)
        Self.postArtworkChanged(songs: [updated])
        return true
    }

    // MARK: - 恢复文件标签

    /// 恢复文件标签:这些歌在电视上匹配 / 补全过的记录从本机台账删掉(之后装手机快照也不再
    /// 补回来),清掉「用户编辑」标记,电视能直接读文件的再按文件重读一遍 —— 标题、艺术家、
    /// 专辑、年份等换回文件里的标签,文件里有封面(内嵌或同目录的封面图)的也换回来;文件里
    /// 没有的字段保留现在的值,与 iPhone / Mac 一致。CUE 分轨按 CUE 表换回标题、艺术家、专辑
    /// 与轨号,同一张 CUE 的其它轨一起恢复:补全把专辑拆散过的话,散出去的那几首已经不在
    /// 这张专辑里了。服务器曲库源和电视读不了文件的源只撤标记和台账,下次同步 / 扫描跟随源。
    /// `progress` 在主线程上报。
    func restoreFileTags(
        songIDs: [String],
        progress: @escaping @MainActor (TVRestoreFileTagsProgress) -> Void
    ) async -> TVRestoreFileTagsProgress {
        guard let store else { return TVRestoreFileTagsProgress(isFinished: true) }
        let songs = Self.includingCueSiblings(
            songIDs.compactMap { store.library.song(id: $0) },
            library: store.library
        )
        for song in songs {
            await overrides.remove(songID: song.id)
        }
        let cleared = songs.filter { $0.userMetadataEditedAt != nil }.map { song -> Song in
            var song = song
            song.userMetadataEditedAt = nil
            return song
        }
        if !cleared.isEmpty { store.library.replaceSongs(cleared) }
        let rereadable = songs.filter { canRereadFileTags($0, store: store) }
        var state = TVRestoreFileTagsProgress(total: rereadable.count, skipped: songs.count - rereadable.count)
        progress(state)
        plog("🔁 TV restore file tags songs=\(songs.count) cleared=\(cleared.count) rereading=\(rereadable.count)")

        // 重读的结果攒到最后一次写回:同一张 CUE 的几轨分开写的话,先写的那首会跟还没恢复的
        // 兄弟轨一起按目录推断专辑艺术家,又落进别的专辑。
        var restored: [Song] = []
        var inspectionComplete: [String: Bool] = [:]
        for (sourceID, group) in Dictionary(grouping: rereadable, by: \.sourceID) {
            guard !Task.isCancelled, let source = store.sourcesStore.source(id: sourceID) else {
                state.skipped += group.count
                continue
            }
            let credential = TVCredentialStore.credential(for: source, bundle: store.credentialBundle)
            // 按「重读」开:专辑封面也按文件里的换回来,不留着刮削来的那张。
            let pool = TVMetadataReaderPool(source: source, credential: credential, rereadMetadata: true)
            let lister = TVFolderRescanPolicy.supports(source.type) ? store.makeLister(for: source) : nil
            var entriesByDirectory: [String: [TVDirEntry]] = [:]
            var cueSheets: [String: CueSheet] = [:]
            for original in group {
                defer {
                    state.processed += 1
                    progress(state)
                }
                // 以库里最新的一行为准;这期间又被改过(重新打了标记)就不动它。
                guard !Task.isCancelled,
                      var live = store.library.song(id: original.id), live.userMetadataEditedAt == nil else {
                    state.skipped += 1
                    continue
                }
                // 同目录的封面图、歌词(以及 CUE 表)也算文件标签的一部分:列一次目录,同一目录的歌共用。
                var entries: [TVDirEntry] = []
                if let lister,
                   let directory = TVFolderRescanPolicy.directory(containingFilePath: live.filePath, levelsAbove: 0) {
                    if let cached = entriesByDirectory[directory] {
                        entries = cached
                    } else if let listed = try? await lister.list(directory) {
                        entries = listed
                        entriesByDirectory[directory] = listed
                    }
                }
                var restoredCueIdentity = false
                if live.isCueTrack {
                    guard let fromSheet = await Self.restoringCueIdentity(
                        live, entries: entries, readerPool: pool, sheets: &cueSheets
                    ) else {
                        state.failed += 1
                        continue
                    }
                    restoredCueIdentity = fromSheet != live
                    live = fromSheet
                }
                let result = await TVMetadataEnricher.enrich(
                    song: live, sidecars: SidecarDirectoryIndex(entries), using: pool
                )
                switch result.status {
                case .enriched:
                    restored.append(result.song)
                    inspectionComplete[result.song.id] = result.inspectionComplete
                    state.completed += 1
                case .failed, .timedOut:
                    // CUE 表已经读到:标题、专辑这些照样换回来,只是封面没能重读。
                    if restoredCueIdentity {
                        restored.append(live)
                        state.completed += 1
                    } else {
                        state.failed += 1
                    }
                case .cancelled:
                    state.skipped += 1
                }
            }
            await pool.closeAll()
        }
        // 读的这段时间里又被改过(重新打了标记)的不动它。
        let writable = restored.filter { store.library.song(id: $0.id)?.userMetadataEditedAt == nil }
        state.completed -= restored.count - writable.count
        state.skipped += restored.count - writable.count
        if !writable.isEmpty {
            store.library.replaceSongs(writable)
            for song in writable {
                if let complete = inspectionComplete[song.id] {
                    await TVMetadataInspectionStore.shared.record(song, complete: complete)
                }
                store.refreshNowPlayingAfterMetadataEdit(song, lyrics: nil)
            }
            Self.postArtworkChanged(songs: writable)
        }
        state.isFinished = true
        progress(state)
        plog("🔁 TV restore file tags done completed=\(state.completed) failed=\(state.failed) skipped=\(state.skipped)")
        return state
    }

    /// 能按文件重读:电视能直接按段读的文件型源,这个源也没在扫描。CUE 分轨的标题等
    /// 来自 CUE 表,按它记下的 CUE 路径读回来。
    private func canRereadFileTags(_ song: Song, store: TVStore) -> Bool {
        guard let source = store.sourcesStore.source(id: song.sourceID),
              source.isEnabled, !source.isDeleted, !source.type.isServerLibrary,
              store.activeScanSourceID != source.id else { return false }
        return TVMetadataReaderPool.canRead(source)
    }

    /// 这些歌里有没有在电视上匹配 / 补全改过标签或封面的(本机台账里有记录)。「只补全缺失
    /// 字段」的改动不打「用户编辑」标记,专辑页靠这个决定要不要给「恢复文件标签」。
    func hasLocalTagChanges(songIDs: [String]) async -> Bool {
        let ids = Set(songIDs)
        return await overrides.allEntries().contains {
            ids.contains($0.songID) && ($0.fields != nil || $0.coverFile != nil)
        }
    }

    private struct CueImageKey: Hashable {
        let sourceID: String
        let filePath: String
        let cuePath: String
    }

    /// 加上与这些 CUE 分轨同一张 CUE、同一个音频文件的其它轨。
    private static func includingCueSiblings(_ songs: [Song], library: MusicLibrary) -> [Song] {
        let images = Set(songs.compactMap { song in
            song.cueSheetPath.map { CueImageKey(sourceID: song.sourceID, filePath: song.filePath, cuePath: $0) }
        })
        guard !images.isEmpty else { return songs }
        var seen = Set(songs.map(\.id))
        var result = songs
        for song in library.songs {
            guard let cuePath = song.cueSheetPath,
                  images.contains(CueImageKey(sourceID: song.sourceID, filePath: song.filePath, cuePath: cuePath)),
                  seen.insert(song.id).inserted else { continue }
            result.append(song)
        }
        return result
    }

    /// 按 CUE 表换回一轨的标题、艺术家、专辑、专辑艺术家与轨号,写法与扫描时建分轨一致:
    /// CUE 里没写的就空着,碟号 CUE 里没有也清掉;流派、年份 CUE 里有才换。
    /// CUE 读不到、太大或表里找不到这一轨 → nil。
    private static func restoringCueIdentity(
        _ song: Song,
        entries: [TVDirEntry],
        readerPool: TVMetadataReaderPool,
        sheets: inout [String: CueSheet]
    ) async -> Song? {
        guard let cuePath = song.cueSheetPath else { return nil }
        let sheet: CueSheet
        if let cached = sheets[cuePath] {
            sheet = cached
        } else {
            // 与扫描时一样最多读 1MB。按 ID 寻址的网盘列不了目录,不知道大小时先读 64KB。
            let size = entries.first(where: { !$0.isDir && $0.path == cuePath })?.size ?? 0
            guard size <= 1024 * 1024,
                  let data = try? await readerPool.read(
                    path: cuePath,
                    size: size,
                    offset: 0,
                    length: min(max(size, 64 * 1024), 1024 * 1024)
                  ),
                  let parsed = CueSheetParser.parse(data: data) else { return nil }
            sheets[cuePath] = parsed
            sheet = parsed
        }
        guard let track = sheet.track(
            audioFileName: (song.filePath as NSString).lastPathComponent,
            startTime: song.cueStartTime,
            number: song.trackNumber
        ) else { return nil }
        let identity = CueTrackIdentity(sheet: sheet, track: track)
        var restored = song
        restored.title = identity.title ?? PMString("cue_track_title_format", identity.trackNumber)
        if identity.artist != song.artistName { restored.sourceArtistNames = nil }
        restored.artistName = identity.artist
        restored.albumTitle = identity.albumTitle
        restored.albumArtistName = identity.albumArtist
        restored.trackNumber = identity.trackNumber
        restored.discNumber = nil
        restored.genre = identity.genre ?? song.genre
        restored.year = identity.year ?? song.year
        return restored
    }

    // MARK: - 本机改动台账的回放

    /// 装上别处来的曲库快照(或恢复中断的安装)之后调用:把电视上匹配 / 补全过的
    /// 标签、封面和歌词补回去。来源设备上有人在那之后又手动改过这首,就以那边为准。
    func replayOverrides() async {
        guard let store else { return }
        let entries = await overrides.allEntries()
        guard !entries.isEmpty else { return }
        await store.library.whenReady()
        var rows: [Song] = []
        for entry in entries {
            guard var song = store.library.song(id: entry.songID) else {
                // 快照里已经没有这首歌了(源里删了)。
                await overrides.remove(songID: entry.songID)
                continue
            }
            if LocalMetadataOverridePolicy.isSuperseded(
                localEditedAt: entry.editedAt,
                incomingUserEditedAt: song.userMetadataEditedAt
            ) {
                await overrides.remove(songID: entry.songID)
                continue
            }
            let before = song
            if let local = entry.fields {
                var replayed = LocalMetadataOverridePolicy.replayedFields(
                    incoming: song.scrapeFields,
                    local: local,
                    kind: entry.kind
                )
                // 旧版本补全时记下的 CUE 分轨标签可能带着在线结果的专辑艺术家、碟号,
                // 照着回放会在每次装完快照后再把专辑拆一遍。
                if song.isCueTrack {
                    replayed = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(
                        replayed, original: song.scrapeFields
                    )
                }
                if !Self.sameVisibleTags(song.scrapeFields, replayed) {
                    song.applyScrapeFields(replayed)
                }
            }
            // 挑过的候选要像手动编辑一样挡住电视自己的重扫。
            if entry.kind == .chosen, entry.fields != nil || entry.coverFile != nil,
               (song.userMetadataEditedAt ?? .distantPast) < entry.editedAt {
                song.userMetadataEditedAt = entry.editedAt
            }
            if entry.coverFile != nil {
                await replayCover(entry, into: &song)
            }
            if entry.lyricsFile != nil {
                await replayLyrics(entry, into: &song)
            }
            if song != before { rows.append(song) }
        }
        guard !rows.isEmpty else { return }
        store.library.replaceSongs(rows)
        Self.postArtworkChanged(songs: rows)
        plog("🏷️ TV metadata overrides replayed for \(rows.count) song(s)")
    }

    private func replayCover(_ entry: TVMetadataOverrideStore.Entry, into song: inout Song) async {
        guard let local = await overrides.coverData(for: entry) else {
            await overrides.dropCover(songID: entry.songID)
            return
        }
        let current = await MetadataAssetStore.shared.cachedCoverData(forSongID: entry.songID)
        let state: LocalMetadataOverridePolicy.AssetState = if let current {
            TVMetadataOverrideStore.contentName(of: current) == entry.coverFile ? .matchesLocalCopy : .differs
        } else {
            .missing
        }
        let action = LocalMetadataOverridePolicy.assetAction(kind: entry.kind, current: state)
        switch action {
        case .keep, .restore:
            if action == .restore {
                guard await storeCover(local, forSongID: entry.songID) else { return }
            }
            // 快照里这一行可能指着源端的封面引用(飞牛这类引用会先于本机缓存被读取):
            // 挑过的封面要把引用指回本机缓存,补空缺的只在这一行没有封面引用时补上。
            if entry.kind == .chosen || song.coverArtFileName?.isEmpty != false {
                song.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: entry.songID)
            }
        case .yieldToIncoming:
            await overrides.dropCover(songID: entry.songID)
        }
    }

    private func replayLyrics(_ entry: TVMetadataOverrideStore.Entry, into song: inout Song) async {
        guard let local = await overrides.lyrics(for: entry), !local.isEmpty else {
            await overrides.dropLyrics(songID: entry.songID)
            return
        }
        let current = await MetadataAssetStore.shared.cachedLyrics(forSongID: entry.songID)
        let state: LocalMetadataOverridePolicy.AssetState = if let current, !current.isEmpty {
            LyricsDocumentFingerprint(lines: current).rawValue == entry.lyricsFingerprint
                ? .matchesLocalCopy
                : .differs
        } else {
            .missing
        }
        let action = LocalMetadataOverridePolicy.assetAction(kind: entry.kind, current: state)
        switch action {
        case .keep, .restore:
            if action == .restore {
                guard await MetadataAssetStore.shared.cacheLyrics(local, forSongID: entry.songID, force: true) else {
                    return
                }
                if let written = await MetadataAssetStore.shared.cachedLyrics(forSongID: entry.songID) {
                    await overrides.updateLyricsFingerprint(
                        songID: entry.songID,
                        fingerprint: LyricsDocumentFingerprint(lines: written).rawValue
                    )
                }
            }
            if entry.kind == .chosen || song.lyricsFileName?.isEmpty != false {
                song.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: entry.songID)
            }
        case .yieldToIncoming:
            await overrides.dropLyrics(songID: entry.songID)
        }
    }

    /// 扫码直传的封面是一批一批到的,晚于曲库那一段,会把电视上挑的封面盖掉。批量装封面
    /// 之后都会发一条 `userInfo["all"] == true` 的通知,收到后稍等片刻把台账里的封面补回来。
    func startObservingArtworkRestores() {
        guard artworkRestoreObserver == nil else { return }
        artworkRestoreObserver = NotificationCenter.default.addObserver(
            forName: .primuseArtworkDidCache,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard note.userInfo?["all"] as? Bool == true else { return }
            MainActor.assumeIsolated { self?.scheduleArtworkReplay() }
        }
    }

    private func scheduleArtworkReplay() {
        artworkReplayTask?.cancel()
        artworkReplayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
            guard let self else { return }
            self.artworkReplayTask = nil
            await self.replayOverrides()
        }
    }

    // MARK: - 小工具

    /// 写进曲库的时间戳取整到秒:曲库 JSON 按 ISO 8601 存到秒,台账与曲库行才比得齐。
    private static func editTimestamp() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func storeCover(_ data: Data, forSongID songID: String) async -> Bool {
        await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
        // 不完整或解不开的图片会被缓存拒收,拒收了就不能把引用指过去。
        return await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) != nil
    }

    private static func postArtworkChanged(songs: [Song]) {
        let ids = songs.map(\.id)
        let albumIDs = songs.compactMap(\.albumID).filter { !$0.isEmpty }
        NotificationCenter.default.post(
            name: .primuseArtworkDidCache,
            object: nil,
            userInfo: ["songIDs": ids, "tokens": albumIDs]
        )
    }

    /// 能按关键词搜的源:内置源看是否支持元数据,自定义源还要配置了搜索接口。
    nonisolated static func canSearchManually(_ config: ScraperSourceConfig) -> Bool {
        switch config.type {
        case .custom(let configID):
            guard let scraperConfig = ScraperConfigStore.shared.config(for: configID) else { return false }
            return scraperConfig.supportsMetadata && scraperConfig.search != nil
        default:
            return config.type.supportsMetadata
        }
    }

    /// 界面上看得到的标签是否相同(多值歌手列表只跟着歌手变,不单独算一处改动)。
    nonisolated static func sameVisibleTags(
        _ lhs: ScrapedMetadataMergePolicy.Fields,
        _ rhs: ScrapedMetadataMergePolicy.Fields
    ) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.albumTitle == rhs.albumTitle
            && lhs.albumArtist == rhs.albumArtist
            && lhs.year == rhs.year
            && lhs.genre == rhs.genre
            && lhs.trackNumber == rhs.trackNumber
            && lhs.discNumber == rhs.discNumber
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func firstPositive(_ values: Int?...) -> Int? {
        values.first { ($0 ?? 0) > 0 } ?? nil
    }

    private static func firstNonEmptyGenres(_ values: [String]?...) -> [String]? {
        for value in values {
            let cleaned = (value ?? []).compactMap { genre -> String? in
                let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}

// MARK: - 本机改动台账

/// 电视上匹配 / 补全过的歌:改了哪些标签、封面和歌词各留一份副本。放在电视曲库文件的
/// 同一个目录(tvOS 上 Application Support 写不进去,曲库与播放会话也都在 Caches/Primuse)。
actor TVMetadataOverrideStore {
    static let shared = TVMetadataOverrideStore()

    struct Entry: Codable, Sendable, Equatable {
        var songID: String
        var kind: LocalMetadataOverridePolicy.Kind
        var editedAt: Date
        /// 改过标签时是改完之后的整组标签;只动了封面 / 歌词时为 nil。
        var fields: ScrapedMetadataMergePolicy.Fields?
        /// 封面副本的文件名(内容的 SHA-256),同一张封面只存一份。
        var coverFile: String?
        /// 歌词副本的文件名。
        var lyricsFile: String?
        /// 写进缓存之后读回来的歌词指纹,用来判断缓存里是不是还是这一份。
        var lyricsFingerprint: String?
    }

    private let indexURL: URL
    private let assetsURL: URL
    private var cachedEntries: [String: Entry]?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
        indexURL = base.appendingPathComponent("tv-metadata-overrides.json")
        assetsURL = base.appendingPathComponent("tv-metadata-overrides", isDirectory: true)
    }

    func allEntries() -> [Entry] {
        Array(loadedEntries().values).sorted { $0.songID < $1.songID }
    }

    /// 记一次改动。同一首歌的旧记录合并进来:挑过候选的不会被后来的「只补空缺」降级,
    /// 这次没动的封面 / 歌词沿用上一次的副本。
    func record(
        songID: String,
        kind: LocalMetadataOverridePolicy.Kind,
        editedAt: Date,
        fields: ScrapedMetadataMergePolicy.Fields?,
        cover: Data?,
        lyrics: [LyricLine]?
    ) async {
        // 先把要等的读完,下面改索引的那段不再让出 actor,免得并发的记录互相覆盖。
        var lyricsFingerprint: String?
        if lyrics != nil,
           let written = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID) {
            lyricsFingerprint = LyricsDocumentFingerprint(lines: written).rawValue
        }
        var entries = loadedEntries()
        let existing = entries[songID]
        var entry = existing ?? Entry(songID: songID, kind: kind, editedAt: editedAt)
        entry.kind = existing?.kind == .chosen ? .chosen : kind
        entry.editedAt = editedAt
        if let fields { entry.fields = fields }
        if let cover, let name = writeCover(cover) {
            entry.coverFile = name
        }
        if let lyrics, let name = writeLyrics(lyrics, songID: songID) {
            entry.lyricsFile = name
            entry.lyricsFingerprint = lyricsFingerprint
        }
        entries[songID] = entry
        save(entries)
    }

    func remove(songID: String) {
        var entries = loadedEntries()
        guard entries.removeValue(forKey: songID) != nil else { return }
        save(entries)
    }

    func dropCover(songID: String) {
        mutate(songID: songID) { $0.coverFile = nil }
    }

    func dropLyrics(songID: String) {
        mutate(songID: songID) {
            $0.lyricsFile = nil
            $0.lyricsFingerprint = nil
        }
    }

    func updateLyricsFingerprint(songID: String, fingerprint: String) {
        mutate(songID: songID) { $0.lyricsFingerprint = fingerprint }
    }

    func coverData(for entry: Entry) -> Data? {
        guard let name = entry.coverFile else { return nil }
        return try? Data(contentsOf: assetsURL.appendingPathComponent(name))
    }

    func lyrics(for entry: Entry) -> [LyricLine]? {
        guard let name = entry.lyricsFile,
              let data = try? Data(contentsOf: assetsURL.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode([LyricLine].self, from: data)
    }

    nonisolated static func contentName(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    // MARK: 读写

    private func mutate(songID: String, _ change: (inout Entry) -> Void) {
        var entries = loadedEntries()
        guard var entry = entries[songID] else { return }
        change(&entry)
        // 标签、封面、歌词都不剩了,这条记录也就没有意义。
        if entry.fields == nil, entry.coverFile == nil, entry.lyricsFile == nil {
            entries.removeValue(forKey: songID)
        } else {
            entries[songID] = entry
        }
        save(entries)
    }

    private func loadedEntries() -> [String: Entry] {
        if let cachedEntries { return cachedEntries }
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in entries { loaded[entry.songID] = entry }
        }
        cachedEntries = loaded
        return loaded
    }

    private func save(_ entries: [String: Entry]) {
        cachedEntries = entries
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sorted = entries.values.sorted { $0.songID < $1.songID }
        if let data = try? JSONEncoder().encode(sorted) {
            try? data.write(to: indexURL, options: .atomic)
        }
        removeUnreferencedAssets(keeping: entries)
    }

    private func writeCover(_ data: Data) -> String? {
        let name = Self.contentName(of: data)
        let url = assetsURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        return write(data, to: url) ? name : nil
    }

    private func writeLyrics(_ lines: [LyricLine], songID: String) -> String? {
        guard let data = try? JSONEncoder().encode(lines) else { return nil }
        let name = MetadataAssetStore.shared.expectedLyricsFileName(for: songID)
        return write(data, to: assetsURL.appendingPathComponent(name)) ? name : nil
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            plog("⚠️ TV metadata override asset write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func removeUnreferencedAssets(keeping entries: [String: Entry]) {
        let referenced = Set(entries.values.flatMap { [$0.coverFile, $0.lyricsFile].compactMap { $0 } })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - 与曲库的衔接

extension TVStore {
    /// 「匹配信息」只对曲库里的普通歌曲开放:电台、Apple Music、串烧播放中都不行。
    func canMatchMetadata(songID: String?) -> Bool {
        guard let songID, !isLiveRadio, !isMedleyActive,
              let song = library.song(id: songID),
              let source = sourcesStore.source(id: song.sourceID) else { return false }
        return source.type != .appleMusic && source.type != .appleMusicLibrary
    }

    /// 改的是正在播的这首时,「正在播放」、系统的正在播放信息和歌词跟着换。
    func refreshNowPlayingAfterMetadataEdit(_ song: Song, lyrics: [LyricLine]?) {
        guard currentSongID == song.id, nowPlaying.songID == song.id else { return }
        nowPlaying.title = song.title
        nowPlaying.artist = library.artistDisplayName(for: song) ?? PMString("ext.tv.unknownArtist")
        nowPlaying.album = song.albumTitle ?? ""
        nowPlaying.albumID = song.albumID ?? ""
        nowPlaying.coverRef = song.coverArtFileName
        engine.updateCatalogMetadata(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            duration: nowPlaying.duration
        )
        if let lyrics, !lyrics.isEmpty {
            applyLyrics(TVPlaybackCoordinator.toTVLyrics(lyrics, duration: song.duration), forSongID: song.id)
            TVLyricsTranslationController.shared.lyricsDidLoad(lyrics, forSongID: song.id, store: self)
        }
    }
}
#endif
