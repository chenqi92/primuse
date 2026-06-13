import Foundation
import PrimuseKit

/// 把 Last.fm 的 "相似歌曲" API 接到 Primuse: 拿一首 seed 歌, 调 API,
/// 在本地 library 里 fuzzy match 找到能播的, 返回 [Song]。
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

    private var cache: [SeedKey: CacheEntry] = [:]
    private var lruOrder: [SeedKey] = []

    /// 主入口: 给 seed 歌 (你正在播的, 或最近播的), 返回 library 内能播的
    /// 相似歌候选, 按 Last.fm match score 排序。
    /// `includeUnmatched`=true 时会把 library 里没匹配到的也返回 (song 为 nil),
    /// UI 可以选择显示并提示 "未在你的库内"。
    func fetchSimilar(
        to seed: Song,
        limit: Int = 30,
        library: [Song],
        includeUnmatched: Bool = false
    ) async throws -> [SimilarTracksCandidate] {
        let artist = (seed.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = seed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return [] }
        let key = SeedKey(artistLower: artist.lowercased(), titleLower: title.lowercased())

        // 取缓存
        var raws: [LastFmSimilarAPI.SimilarTrack]
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.ttl {
            raws = cached.candidates
            promote(key)
        } else {
            // 先 track.getSimilar, 没结果或失败再 fallback 到 artist.getSimilar。
            // 区分"API 成功返回空"与"请求失败": 只要有一次 API 成功返回 (即使为空)
            // 就把结果写入正常缓存; 两个端点都抛错时不写缓存并把最后一次错误抛给调用方,
            // 避免一次临时断网/超时把空结果当成功缓存 6 小时。
            var fetched: [LastFmSimilarAPI.SimilarTrack] = []
            var succeeded = false
            var lastError: Error?
            do {
                fetched = try await LastFmSimilarAPI.similarTracks(artist: artist, track: title, limit: limit)
                succeeded = true
            } catch {
                // track 失败也尝试 artist
                lastError = error
            }
            if fetched.isEmpty {
                do {
                    fetched = try await LastFmSimilarAPI.similarArtistTracks(artist: artist, limit: limit)
                    succeeded = true
                } catch {
                    lastError = error
                }
            }
            // 两个端点都失败 (missingAPIKey / 断网 / HTTP 错误等): 不污染缓存, 直接抛出。
            if !succeeded, let lastError {
                throw lastError
            }
            raws = fetched
            cache[key] = CacheEntry(candidates: raws, fetchedAt: Date())
            promote(key)
            evictIfNeeded()
        }

        // 本地 library 模糊匹配
        let result: [SimilarTracksCandidate] = raws.map { item in
            let matched = Self.matchInLibrary(item: item, library: library, seedID: seed.id)
            return SimilarTracksCandidate(
                title: item.title,
                artist: item.artist,
                match: item.match,
                lastFmURL: item.lastFmURL,
                librarySong: matched
            )
        }

        if includeUnmatched {
            return result
        } else {
            return result.filter { $0.librarySong != nil }
        }
    }

    func invalidate() {
        cache.removeAll()
        lruOrder.removeAll()
    }

    // MARK: - Private

    private func promote(_ key: SeedKey) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func evictIfNeeded() {
        while lruOrder.count > Self.cacheLimit {
            let drop = lruOrder.removeFirst()
            cache.removeValue(forKey: drop)
        }
    }

    /// title + artist 模糊匹配。优先精确 (case-insensitive equal),
    /// 然后 contains, 最后只用 title 匹配 (artist 不一致放低权重)。
    /// 返回最佳候选 (Song)。
    private static func matchInLibrary(
        item: LastFmSimilarAPI.SimilarTrack,
        library: [Song],
        seedID: String
    ) -> Song? {
        let tLower = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let aLower = item.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // artist.getSimilar 模式下 title 为空, 用 artist 命中任意一首歌
        if tLower.isEmpty {
            return library.first(where: {
                $0.id != seedID && ($0.artistName ?? "").lowercased() == aLower
            })
        }

        var bestExact: Song?
        var bestContains: Song?
        for song in library where song.id != seedID {
            let songT = song.title.lowercased()
            let songA = (song.artistName ?? "").lowercased()
            if songT == tLower && (aLower.isEmpty || songA == aLower) {
                bestExact = song
                break
            }
            if bestContains == nil {
                if songT.contains(tLower) && (aLower.isEmpty || songA.contains(aLower) || aLower.contains(songA)) {
                    bestContains = song
                }
            }
        }
        return bestExact ?? bestContains
    }
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
