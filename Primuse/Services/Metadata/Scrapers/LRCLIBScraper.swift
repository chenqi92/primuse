import Foundation
import PrimuseKit

actor LRCLIBScraper: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lrclib

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

    func cooldownRemaining() async -> TimeInterval { await requestExecutor.cooldownRemaining }

    // MARK: - MusicScraper

    private var lyricCache: [String: ScraperLyricsResult] = [:]

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        guard limit > 0 else { return .empty(.lrclib) }
        let rows = try await searchRows(title: query, artist: artist)
        let items = rows.filter { row in
            guard let title = row.trackName else { return false }
            return ScraperIdentity.titleMatches(query, title) && row.lyrics != nil
        }.prefix(limit).compactMap { row -> ScraperSearchItem? in
            guard let id = row.id, let title = row.trackName, let lyrics = row.lyrics else { return nil }
            let externalID = "lrclib:\(id)"
            if lyricCache.count >= 100 { lyricCache.removeAll(keepingCapacity: true) }
            lyricCache[externalID] = lyrics
            return ScraperSearchItem(externalId: externalID, source: .lrclib, title: title,
                                     artist: row.artistName, album: row.albumName,
                                     durationMs: row.duration.flatMap { $0 > 0 && $0.isFinite ? Int($0 * 1000) : nil })
        }
        return ScraperSearchResult(items: items, source: .lrclib)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        if let cached = lyricCache[externalId] { return cached }
        if externalId.hasPrefix("lrclib:"), let id = Int64(externalId.dropFirst(7)), id >= 0 {
            let data = try await throttledRequest(url: URL(string: "https://lrclib.net/api/get/\(id)")!)
            return try JSONDecoder().decode(LRCLibSearchItem.self, from: data).lyrics
        }
        let parts = externalId.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return try await fetchLyrics(title: parts[0], artist: parts[1].isEmpty ? nil : parts[1],
                                     album: parts.count > 2 ? parts[2] : nil,
                                     duration: parts.count > 3 ? TimeInterval(parts[3]) : nil)
    }

    func fetchLyrics(title: String, artist: String?, album: String? = nil, duration: TimeInterval? = nil) async throws -> ScraperLyricsResult? {
        let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artist, !artist.isEmpty {
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(URLQueryItem(name: "album_name", value: album))
            }
            if let duration, duration.isFinite, duration > 0 {
                items.append(URLQueryItem(name: "duration", value: String(duration.rounded())))
            }
            components.queryItems = items
            do {
                let data = try await throttledRequest(url: components.url!)
                let row = try JSONDecoder().decode(LRCLibSearchItem.self, from: data)
                if let lyrics = row.lyrics { return lyrics }
                if row.instrumental == true { return nil }
            } catch ScraperError.notFound {
                // A signature miss is recoverable; transport/rate-limit failures are not.
            }
        }
        let rows = try await searchRows(title: title, artist: artist)
        let matching = rows.filter { row in
            guard let name = row.trackName, ScraperIdentity.titleMatches(title, name) else { return false }
            if let artist, !artist.isEmpty, !ScraperIdentity.artistMatches(artist, row.artistName) { return false }
            if let duration, duration.isFinite, duration > 0 {
                guard let found = row.duration, found.isFinite, abs(found - duration) <= 5 else { return false }
            }
            return true
        }.sorted { lhs, rhs in
            let lhsTimed = Self.hasText(lhs.syncedLyrics)
            let rhsTimed = Self.hasText(rhs.syncedLyrics)
            if lhsTimed != rhsTimed { return lhsTimed }
            if let duration {
                return abs((lhs.duration ?? .infinity) - duration) < abs((rhs.duration ?? .infinity) - duration)
            }
            return false
        }
        return matching.compactMap(\.lyrics).first
    }

    private func searchRows(title: String, artist: String?) async throws -> [LRCLibSearchItem] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        func request(artist: String?) async throws -> [LRCLibSearchItem] {
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            var items = [URLQueryItem(name: "track_name", value: title)]
            if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
            components.queryItems = items
            let data = try await throttledRequest(url: components.url!)
            return try JSONDecoder().decode([LRCLibSearchItem].self, from: data)
        }
        let rows = try await request(artist: artist)
        if rows.contains(where: { row in
            row.trackName.map { ScraperIdentity.titleMatches(title, $0) } == true
                && (artist?.isEmpty != false || ScraperIdentity.artistMatches(artist, row.artistName)) && row.lyrics != nil
        }) || artist?.isEmpty != false { return rows }
        // Broaden retrieval only; automatic callers still verify artist/version/duration.
        return try await request(artist: nil)
    }

    private static func hasText(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: - Rate Limiting

    private func throttledRequest(url: URL) async throws -> Data {
        do {
            // Keep one attempt per lookup; later songs share the same cooldown.
            return try await requestExecutor.execute { [session] in
                try await session.data(from: url)
            }.data
        } catch let failure as HTTPResponseFailure {
            switch failure.statusCode {
            case 404: throw ScraperError.notFound
            case 429, 503:
                throw ScraperError.rateLimited(retryAfter: failure.retryAfter.map {
                    $0.rounded(.up).finiteInt(or: Int.max)
                })
            default: throw ScraperError.networkError("LRCLIB HTTP \(failure.statusCode)")
            }
        } catch RequestExecutor.AdmissionError.queueFull {
            throw ScraperError.busy
        } catch let error as URLError where error.code == .badServerResponse {
            throw ScraperError.networkError("LRCLIB returned a non-HTTP response")
        }
    }

    // MARK: - Models

    private struct LRCLibSearchItem: Decodable {
        let id: Int64?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?

        var lyrics: ScraperLyricsResult? {
            guard instrumental != true, LRCLIBScraper.hasText(syncedLyrics) || LRCLIBScraper.hasText(plainLyrics) else { return nil }
            return ScraperLyricsResult(source: .lrclib,
                                       lrcContent: LRCLIBScraper.hasText(syncedLyrics) ? syncedLyrics : nil,
                                       plainText: LRCLIBScraper.hasText(plainLyrics) ? plainLyrics : nil)
        }
    }
}
