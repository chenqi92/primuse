import Foundation
import PrimuseKit

actor LRCLIBScraper: MusicScraper {
    let type = MusicScraperType.lrclib

    private let session: URLSession
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration = .milliseconds(200)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .empty(.lrclib) // Lyrics only, no search
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        nil
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        []
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        // externalId format: title|artist|album|duration
        let parts = externalId.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }

        let title = parts[0]
        let artist: String? = parts[1].isEmpty ? nil : parts[1]
        let album = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let duration = parts.count > 3 ? TimeInterval(parts[3]) : nil

        return try await fetchLyrics(title: title, artist: artist, album: album, duration: duration)
    }

    /// Direct lyrics fetch (used by ScraperManager)
    /// 有歌手走精确的 `/api/get`；没有歌手（无标签的网盘文件常见）改走 `/api/search`
    /// 按标题找，再用标题与时长在本地筛选，不再整个跳过。
    func fetchLyrics(title: String, artist: String?, album: String? = nil, duration: TimeInterval? = nil) async throws -> ScraperLyricsResult? {
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedArtist.isEmpty else {
            return try await searchLyricsWithoutArtist(title: title, album: album, duration: duration)
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: trimmedArtist),
        ]
        if let album {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        let safeDuration = duration?.sanitizedDuration ?? 0
        if safeDuration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(safeDuration.rounded(.down).finiteInt())))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(LRCLibResponse.self, from: data)

        guard result.syncedLyrics != nil || result.plainLyrics != nil else {
            return nil
        }

        return ScraperLyricsResult(
            source: .lrclib,
            lrcContent: result.syncedLyrics,
            plainText: result.plainLyrics
        )
    }

    private func searchLyricsWithoutArtist(title: String, album: String?, duration: TimeInterval?) async throws -> ScraperLyricsResult? {
        let wantedTitle = Self.normalizedTitle(title)
        guard !wantedTitle.isEmpty,
              var components = URLComponents(string: "https://lrclib.net/api/search")
        else { return nil }
        var queryItems = [URLQueryItem(name: "track_name", value: title)]
        if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        let data = try await throttledRequest(url: url)
        let results = try JSONDecoder().decode([LRCLibSearchItem].self, from: data)

        let safeDuration = duration?.sanitizedDuration ?? 0
        let matching = results.filter { item in
            guard let trackName = item.trackName,
                  Self.normalizedTitle(trackName) == wantedTitle
            else { return false }
            if safeDuration > 0 {
                guard let itemDuration = item.duration, itemDuration.isFinite,
                      abs(itemDuration - safeDuration) <= 5
                else { return false }
            }
            return true
        }

        if let synced = matching.first(where: { Self.hasText($0.syncedLyrics) }) {
            return ScraperLyricsResult(
                source: .lrclib,
                lrcContent: synced.syncedLyrics,
                plainText: Self.hasText(synced.plainLyrics) ? synced.plainLyrics : nil
            )
        }
        if let plain = matching.first(where: { Self.hasText($0.plainLyrics) }) {
            return ScraperLyricsResult(source: .lrclib, lrcContent: nil, plainText: plain.plainLyrics)
        }
        return nil
    }

    /// 小写、去首尾空白、折叠连续空白。
    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Rate Limiting

    private func throttledRequest(url: URL) async throws -> Data {
        let now = ContinuousClock.now
        let nextAllowed = lastRequestTime?.advanced(by: minInterval) ?? now
        let reservedTime = nextAllowed > now ? nextAllowed : now
        lastRequestTime = reservedTime
        if reservedTime > now {
            try await Task.sleep(for: now.duration(to: reservedTime))
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScraperError.notFound
        }
        return data
    }

    // MARK: - Models

    private struct LRCLibResponse: Codable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private struct LRCLibSearchItem: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }
}
