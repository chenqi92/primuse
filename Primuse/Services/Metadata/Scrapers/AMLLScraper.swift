import Foundation
import PrimuseKit

/// AMLL TTML DB 逐字歌词库（`api.amll.dev`）。只提供歌词：先按歌名、歌手搜，
/// 本地按 `AMLLLyricsLookupPolicy` 挑出可信的几份，再按 id 取 TTML、核对时长。
/// 返回的 TTML 交给现有的歌词解析，逐字、翻译、对唱与和声都照常读出。
actor AMLLScraper: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.amll

    private let session: URLSession
    private static let serviceRequests = RequestExecutor(
        policy: .init(minimumInterval: 0.2, maximumConcurrentRequests: 1)
    )
    private let requestExecutor: RequestExecutor

    init(session: URLSession? = nil, requestExecutor: RequestExecutor? = nil) {
        self.requestExecutor = requestExecutor ?? Self.serviceRequests
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    func isCoolingDown() async -> Bool {
        await requestExecutor.isCoolingDown
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        guard limit > 0 else { return .empty(.amll) }
        // 手动候选显示词库中的歌手，由用户确认别名；自动取词仍要求歌手匹配。
        let candidates = try await findCandidates(
            for: .init(title: query, artist: artist, album: album), allowArtistMismatch: true
        )
        return ScraperSearchResult(items: candidates.prefix(limit).map { song in
            ScraperSearchItem(
                externalId: "amll:\(song.id)", source: .amll,
                title: song.musicNames.first ?? query,
                artist: song.artistNames.isEmpty ? nil : song.artistNames.joined(separator: " / "),
                album: song.albumNames.first
            )
        }, source: .amll)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        nil
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        []
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        if externalId.hasPrefix("amll:") {
            guard let id = Int64(externalId.dropFirst(5)) else { return nil }
            return try await lyrics(id: id)
        }
        // externalId format: title|artist|album|duration（与 LRCLIB 相同）
        let parts = externalId.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard let title = parts.first, !title.isEmpty else { return nil }
        let artist = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let album = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let duration = parts.count > 3 ? TimeInterval(parts[3]) : nil
        return try await fetchLyrics(title: title, artist: artist, album: album, duration: duration)
    }

    func fetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> ScraperLyricsResult? {
        let query = AMLLLyricsLookupPolicy.Query(
            title: title,
            artist: artist,
            album: album,
            duration: duration?.sanitizedDuration
        )
        let candidates = try await findCandidates(for: query)
        let artistKnown = AMLLLyricsLookupPolicy.hasComparableArtist(query)

        for candidate in candidates.prefix(AMLLLyricsLookupPolicy.maximumLyricsFetches) {
            try Task.checkCancellation()
            guard let result = try await lyrics(id: candidate.id), let ttml = result.lrcContent else { continue }
            let lines = LyricsContentParser.parseText(ttml)
            let lastEnd = lines.compactMap(\.endTime).max()
            guard AMLLLyricsLookupPolicy.lyricsFit(
                lastLyricEnd: lastEnd,
                songDuration: query.duration,
                artistKnown: artistKnown
            ) else {
                plog("[AMLL] '\(title)' #\(candidate.id) lyrics end \(lastEnd ?? -1)s does not fit duration \(query.duration ?? -1)s")
                continue
            }
            return result
        }
        return nil
    }

    private func findCandidates(
        for query: AMLLLyricsLookupPolicy.Query,
        allowArtistMismatch: Bool = false
    ) async throws -> [AMLLLyricsLookupPolicy.SongItem] {
        let searchArtist = AMLLLyricsLookupPolicy.searchArtistName(query.artist)
        var items = try await search(title: query.title, artistName: searchArtist)
        var candidates = AMLLLyricsLookupPolicy.rankedCandidates(
            for: query, in: items, allowArtistMismatch: allowArtistMismatch
        )
        // 接口的模糊歌手筛选可能只返回不合版本的条目；没有可用候选时再按标题查。
        if candidates.isEmpty, searchArtist != nil {
            items = try await search(title: query.title, artistName: nil)
            candidates = AMLLLyricsLookupPolicy.rankedCandidates(
                for: query, in: items, allowArtistMismatch: allowArtistMismatch
            )
        }
        plog("[AMLL] '\(query.title)' search returned \(items.count), compatible candidates \(candidates.count)")
        return candidates
    }

    private func lyrics(id: Int64) async throws -> ScraperLyricsResult? {
        guard let url = AMLLLyricsLookupPolicy.lyricsURL(id: id) else { return nil }
        do {
            let data = try await throttledRequest(url: url)
            let song = try decoded(data, AMLLLyricsLookupPolicy.decodeSong)
            guard let ttml = song.lyrics, !ttml.isEmpty else { return nil }
            return ScraperLyricsResult(source: .amll, lrcContent: ttml)
        } catch ScraperError.notFound {
            return nil
        }
    }

    private func search(title: String, artistName: String?) async throws -> [AMLLLyricsLookupPolicy.SongItem] {
        guard let url = AMLLLyricsLookupPolicy.searchURL(title: title, artistName: artistName) else { return [] }
        do {
            let data = try await throttledRequest(url: url)
            return try decoded(data, AMLLLyricsLookupPolicy.decodeSearch)
        } catch ScraperError.notFound {
            return []
        }
    }

    private func decoded<T>(_ data: Data, _ decode: (Data) throws -> T) throws -> T {
        do {
            return try decode(data)
        } catch {
            throw ScraperError.parseError("AMLL returned an unexpected response")
        }
    }

    // MARK: - Rate Limiting

    private func throttledRequest(url: URL) async throws -> Data {
        do {
            return try await requestExecutor.execute { [session] in
                try await session.data(from: url)
            }.data
        } catch let failure as HTTPResponseFailure {
            switch failure.statusCode {
            // 400 只会是本地拼出的查询不合接口的意，不算服务不可用。
            case 400, 404: throw ScraperError.notFound
            case 429, 503:
                throw ScraperError.rateLimited(retryAfter: failure.retryAfter.map {
                    $0.rounded(.up).finiteInt(or: Int.max)
                })
            default: throw ScraperError.networkError("AMLL HTTP \(failure.statusCode)")
            }
        } catch RequestExecutor.AdmissionError.queueFull {
            throw ScraperError.busy
        } catch let error as URLError where error.code == .badServerResponse {
            throw ScraperError.networkError("AMLL returned a non-HTTP response")
        }
    }
}
