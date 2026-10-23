import Foundation
import PrimuseKit

/// 把 Last.fm 的 "相似歌曲" API 接到 Primuse: 拿一首 seed 歌, 调 API,
/// 在本地 library 里匹配到能播的, 返回 [Song]。
///
/// 缓存最近 50 个 seed 的结果, TTL 6 小时 — Last.fm 相似列表更新不频繁,
/// 不用每次都打网络。actor isolated, 不会撞 thread。
actor SimilarTracksService {
    struct SeedKey: Hashable {
        let artistLower: String
        let titleLower: String
    }

    struct CacheEntry {
        let candidates: [LastFmSimilarAPI.SimilarTrack]
        let fetchedAt: Date
    }

    private static let ttl: TimeInterval = 6 * 3600
    private static let cacheLimit = 50
    /// 一次就按接口上限取:歌曲电台要的比相似列表多,两边共用一份缓存。
    private static let fetchLimit = 100
    /// 相似歌曲在曲库里对上的少于这么多首时,电台再取相似艺人,用他们在曲库里的歌补。
    private static let radioArtistFallbackThreshold = 15

    private let api: LastFmSimilarAPI

    init(api: LastFmSimilarAPI = .init()) { self.api = api }

    /// 种子 → `track.getSimilar` 的结果;Last.fm 没收录这首歌时是相似艺人(歌名留空)。
    private var cache: [SeedKey: CacheEntry] = [:]
    private var lruOrder: [SeedKey] = []
    /// 艺人 → `artist.getSimilar` 的结果(歌名留空)。
    private var artistCache: [String: CacheEntry] = [:]
    private var artistLRUOrder: [String] = []

    /// 主入口: 给 seed 歌 (你正在播的, 或最近播的), 返回 library 内能播的
    /// 相似歌候选, 按 Last.fm match score 排序。Last.fm 没收录这首歌时按相似艺人给,
    /// 每位艺人一首。
    /// `includeUnmatched`=true 时会把 library 里没匹配到的也返回 (song 为 nil),
    /// UI 可以选择显示并提示 "未在你的库内"。
    func fetchSimilar(
        to seed: Song,
        limit: Int = 30,
        library: [Song],
        excluding excluded: Set<String> = [],
        includeUnmatched: Bool = false
    ) async throws -> [SimilarTracksCandidate] {
        guard let key = Self.seedKey(for: seed) else { return [] }
        let raws = try await similarTracks(for: key)
        let items = Array(raws.prefix(max(0, limit)))
        let tracks = items.filter { !$0.title.isEmpty }
        let artists = items.filter(\.title.isEmpty).map(\.artist)
        let pool = Self.matchPool(library, excluding: excluded.union([seed.id]))
        let matched = SimilarTrackLibraryMatcher.match(
            tracks: tracks.map { .init(title: $0.title, artist: $0.artist) },
            artists: artists,
            songs: pool,
            songsPerArtist: 1
        )
        let songsByID = Self.songs(
            withIDs: Set(matched.trackSongIDs.compactMap { $0 } + matched.artistSongIDs.joined()),
            in: library
        )
        var trackIDs = matched.trackSongIDs.makeIterator()
        var artistIDs = matched.artistSongIDs.makeIterator()
        let result = items.map { item in
            let songID: String? = item.title.isEmpty
                ? artistIDs.next()?.first
                : (trackIDs.next() ?? nil)
            return SimilarTracksCandidate(
                title: item.title,
                artist: item.artist,
                match: item.match,
                lastFmURL: item.lastFmURL,
                librarySong: songID.flatMap { songsByID[$0] }
            )
        }

        if includeUnmatched {
            return result
        } else {
            // 同一首歌可能被两条 Last.fm 结果(不同版本)对上,只留第一条。
            var seen = Set<String>()
            return result.filter { candidate in
                guard let id = candidate.librarySong?.id else { return false }
                return seen.insert(id).inserted
            }
        }
    }

    /// 歌曲电台用:Last.fm 认为相似的歌、相似艺人的歌,对到曲库里能播的。
    /// 相似歌曲对上的不多时才去取相似艺人,少花一次额度。
    /// - Parameter day: 相似艺人的歌按天换着挑。
    func radioCandidates(
        for seed: Song,
        library: [Song],
        excluding excluded: Set<String>,
        day: Int
    ) async throws -> SimilarRadioCandidates {
        guard let key = Self.seedKey(for: seed) else { return SimilarRadioCandidates() }
        let raws = try await similarTracks(for: key)
        let tracks = raws.filter { !$0.title.isEmpty }
        let pool = Self.matchPool(library, excluding: excluded.union([seed.id]))
        let trackMatches = SimilarTrackLibraryMatcher.match(
            tracks: tracks.map { .init(title: $0.title, artist: $0.artist) },
            artists: [],
            songs: pool
        )
        var seen = Set<String>()
        let trackSongIDs = trackMatches.trackSongIDs.compactMap { $0 }.filter { seen.insert($0).inserted }
        guard trackSongIDs.count < Self.radioArtistFallbackThreshold else {
            return SimilarRadioCandidates(trackSongIDs: trackSongIDs)
        }

        // Last.fm 没收录这首歌时,缓存里本来就是相似艺人。
        var artists = raws.filter(\.title.isEmpty)
        if artists.isEmpty {
            do {
                artists = try await similarArtists(of: key.artist)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 相似歌曲已经有了,相似艺人取不到就不补。
                return SimilarRadioCandidates(trackSongIDs: trackSongIDs)
            }
        }
        try Task.checkCancellation()
        let salt = UInt64(truncatingIfNeeded: day)
        let artistMatches = SimilarTrackLibraryMatcher.match(
            tracks: [],
            artists: artists.map(\.artist),
            songs: pool,
            songsPerArtist: 3,
            ordering: { Self.stableHash($0, salt: salt) }
        )
        return SimilarRadioCandidates(
            trackSongIDs: trackSongIDs,
            artistSongIDs: SimilarTrackLibraryMatcher.interleaved(artistMatches.artistSongIDs)
                .filter { seen.insert($0).inserted }
        )
    }

    func invalidate() {
        cache.removeAll()
        lruOrder.removeAll()
        artistCache.removeAll()
        artistLRUOrder.removeAll()
    }

    // MARK: - Private

    private struct NormalizedSeed {
        let key: SeedKey
        let artist: String
        let title: String
    }

    private static func seedKey(for seed: Song) -> NormalizedSeed? {
        let artist = (seed.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = seed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return NormalizedSeed(
            key: SeedKey(artistLower: artist.lowercased(), titleLower: title.lowercased()),
            artist: artist,
            title: title
        )
    }

    /// `track.getSimilar`,带缓存;没有结果时换成相似艺人(歌名留空)。
    /// Last.fm 没收录的歌 (error 6) 等失败照旧退回按艺人找; 限流和取消不退,
    /// 免得冷却中再花一次额度。两步都成功才进缓存,失败或取消的查询不进缓存。
    private func similarTracks(for seed: NormalizedSeed) async throws -> [LastFmSimilarAPI.SimilarTrack] {
        if let cached = cache[seed.key], Date().timeIntervalSince(cached.fetchedAt) < Self.ttl {
            promote(seed.key)
            return cached.candidates
        }
        var fetched: [LastFmSimilarAPI.SimilarTrack]
        do {
            fetched = try await api.similarTracks(artist: seed.artist, track: seed.title, limit: Self.fetchLimit)
        } catch let error where Self.allowsArtistFallback(after: error) {
            fetched = []
        }
        if fetched.isEmpty {
            fetched = try await similarArtists(of: seed.artist)
        }
        try Task.checkCancellation()
        cache[seed.key] = CacheEntry(candidates: fetched, fetchedAt: Date())
        promote(seed.key)
        while lruOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: lruOrder.removeFirst())
        }
        return fetched
    }

    /// `artist.getSimilar`,带缓存;歌名为空,调用方按艺人在曲库里找歌。
    private func similarArtists(of artist: String) async throws -> [LastFmSimilarAPI.SimilarTrack] {
        let key = artist.lowercased()
        if let cached = artistCache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.ttl {
            artistLRUOrder.removeAll { $0 == key }
            artistLRUOrder.append(key)
            return cached.candidates
        }
        let fetched = try await api.similarArtistTracks(artist: artist, limit: 30)
        try Task.checkCancellation()
        artistCache[key] = CacheEntry(candidates: fetched, fetchedAt: Date())
        artistLRUOrder.removeAll { $0 == key }
        artistLRUOrder.append(key)
        while artistLRUOrder.count > Self.cacheLimit {
            artistCache.removeValue(forKey: artistLRUOrder.removeFirst())
        }
        return fetched
    }

    private static func allowsArtistFallback(after error: Error) -> Bool {
        let response: HTTPResponseFailure
        switch error {
        case is CancellationError:
            return false
        case let urlError as URLError:
            return urlError.code != .cancelled
        case let failure as HTTPResponseFailure:
            response = failure
        case let similarError as LastFmSimilarAPI.SimilarError:
            switch similarError {
            case .missingAPIKey: return false
            case .api(_, _, let failure): response = failure
            case .decode: return true
            }
        default:
            return true
        }
        return !(response.isRateLimited || response.retryAfter != nil
            || [429, 503].contains(response.statusCode))
    }

    private func promote(_ key: SeedKey) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private static func matchPool(
        _ library: [Song],
        excluding excluded: Set<String>
    ) -> [SimilarTrackLibraryMatcher.LibrarySong] {
        library.compactMap { song in
            guard song.isPlayable, !excluded.contains(song.id) else { return nil }
            return .init(id: song.id, title: song.title, artist: song.artistName)
        }
    }

    private static func songs(withIDs ids: Set<String>, in library: [Song]) -> [String: Song] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: Song] = [:]
        for song in library where ids.contains(song.id) && result[song.id] == nil {
            result[song.id] = song
            if result.count == ids.count { break }
        }
        return result
    }

    private static func stableHash(_ id: String, salt: UInt64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 ^ salt
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}

/// 歌曲电台从 Last.fm 拿到、并在曲库里对上的歌。
struct SimilarRadioCandidates: Sendable {
    /// Last.fm 相似歌曲,从最像到最不像。
    var trackSongIDs: [String] = []
    /// Last.fm 相似艺人在曲库里的歌,各艺人轮流。
    var artistSongIDs: [String] = []

    var isEmpty: Bool { trackSongIDs.isEmpty && artistSongIDs.isEmpty }
}

struct SimilarTracksCandidate: Identifiable, Sendable {
    let title: String
    let artist: String
    /// 0~1 Last.fm match score。
    let match: Double
    let lastFmURL: URL?
    /// 本地 library 命中的歌。nil 表示库里没找到 (只展示不可播)。
    let librarySong: Song?

    var id: String { librarySong?.id ?? "\(artist)|\(title)" }
    var isPlayable: Bool { librarySong != nil }
}

/// 「歌曲电台」:Last.fm 相似歌曲、Last.fm 相似艺人的歌、本地按标签算的相似歌三路轮流,
/// 按专辑和艺人限量(`SongRadioMixPolicy`)。Last.fm 用不了(没配置、断网、限流、
/// 几秒内没回)时只用本地的,本地那一路同样限量。
@MainActor
enum SongRadioBuilder {
    /// 等 Last.fm 最多这么久;过了就先用本地的起播,结果照样进缓存,下次直接用。
    static let lastFmWait: Duration = .seconds(5)

    static func queue(from seed: Song, in library: MusicLibrary, limit: Int = 48) async -> [Song] {
        guard seed.isPlayable, limit > 0 else { return [] }
        // 先把 Last.fm 请求发出去,本地相似度在主线程上算的同时它在后台等网络。
        let fetch = lastFmFetch(for: seed, in: library)
        let local = MusicDiscoveryEngine.songRadio(from: seed, in: library, limit: limit)
        let fetched = await fetch?.value
        guard let lastFm = fetched ?? nil, !lastFm.isEmpty, !Task.isCancelled else {
            fetch?.cancel()
            return local.map(\.song)
        }
        func results(_ ids: [String]) -> [MusicDiscoveryResult] {
            ids.compactMap { library.song(id: $0) }
                .filter(\.isPlayable)
                .map { MusicDiscoveryResult(song: $0, score: 0, reasons: []) }
        }
        let mixed = MusicDiscoveryEngine.mixed(
            seed: seed,
            sources: [results(lastFm.trackSongIDs), Array(local.dropFirst()), results(lastFm.artistSongIDs)],
            excluding: library.dislikedSongIDs,
            limit: limit - 1,
            limits: .radio
        )
        return [seed] + mixed.map(\.song)
    }

    private static func lastFmFetch(
        for seed: Song,
        in library: MusicLibrary
    ) -> Task<SimilarRadioCandidates?, Never>? {
        guard !LastFmCredentialsStore.effectiveAPIKey().isEmpty else { return nil }
        let service = AppServices.shared.similarTracks
        let songs = library.musicSongs
        let excluded = library.dislikedSongIDs
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let wait = lastFmWait
        return Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: SimilarRadioCandidates?.self) { group in
                group.addTask {
                    try? await service.radioCandidates(for: seed, library: songs, excluding: excluded, day: day)
                }
                group.addTask {
                    try? await Task.sleep(for: wait)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }
}
