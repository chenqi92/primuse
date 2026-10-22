import Foundation
import PrimuseKit

extension ShufflePreference {
    /// 设置页、播放页长按菜单与电视设置里的档位名。
    var displayName: String {
        switch self {
        case .uniform: String(localized: "shuffle_preference_uniform")
        case .frequentSongs: String(localized: "shuffle_preference_frequent_songs")
        case .rareSongs: String(localized: "shuffle_preference_rare_songs")
        case .frequentArtists: String(localized: "shuffle_preference_frequent_artists")
        case .rareArtists: String(localized: "shuffle_preference_rare_artists")
        }
    }
}

/// 按抽歌偏好排随机顺序时用的一份快照(#332)。只是值, 可以带进后台任务里给整库请求排序。
struct ShuffleWeighting: Sendable {
    let preference: ShufflePreference
    let counts: ShufflePlayCounts

    static func candidate(for song: Song, resolver: inout ShuffleArtistKeyResolver) -> ShuffleCandidate {
        ShuffleCandidate(
            songID: song.id,
            artistKey: resolver.artistKey(artistName: song.artistName, artistID: song.artistID),
            serverPlayCount: song.serverPlayCount
        )
    }

    /// 每个元素的权重; 找不到歌的按没播放过算。
    func weights<Element>(_ elements: [Element], song: (Element) -> Song?) -> [Double] {
        var resolver = ShuffleArtistKeyResolver()
        return elements.map { element in
            let candidate = song(element).map { Self.candidate(for: $0, resolver: &resolver) }
            return WeightedShufflePolicy.weight(of: candidate, preference: preference, counts: counts)
        }
    }

    func shuffled<Element>(_ elements: [Element], song: (Element) -> Song?) -> [Element] {
        guard elements.count > 1 else { return elements }
        let elementWeights = weights(elements, song: song)
        var generator = SystemRandomNumberGenerator()
        return WeightedShufflePolicy.shuffled(
            Array(elements.indices),
            weight: { elementWeights[$0] },
            using: &generator
        ).map { elements[$0] }
    }

    /// 整库这类只有 ID 的请求, 在后台按快照里的歌排。
    func shuffled(ids: [String], lookup: VisibleSongLookup) -> [String] {
        shuffled(ids, song: { lookup.song(id: $0) })
    }
}

/// 随机播放加权用的播放次数(#332)。一首歌取本机听歌记录与音乐服务器记下的次数中较大的那个,
/// 歌手按名下各首累加(见 `ShufflePlayCounts`)。
///
/// 本机记录只留最近 5000 条, 更早的在年归档里(`PlayHistoryArchiver`, 只有 iPhone / iPad / Mac 有):
/// 归档要读文件, 第一次用到时在后台读一遍, 读好之前先只按本机记录算。电视只按本机记录。
/// 只读不登记观察的曲库入口, 播放器在视图取值的过程中排下一轮随机时, 不会让视图跟着曲库变动重算。
@MainActor
final class ShufflePlayCountStore {
    static let shared = ShufflePlayCountStore()

    private struct CacheKey: Equatable {
        let historyVersion: UInt64
        let archiveGeneration: UInt64
        let library: ObjectIdentifier?
        let libraryRevision: UInt64?
    }

    private var cached: (key: CacheKey, counts: ShufflePlayCounts)?
    /// 服务器上有播放次数的那些歌, 曲库换一版才重新扫。
    private var serverCounted: (library: ObjectIdentifier, revision: UInt64, songs: [ShuffleCandidate])?
    private var archiveGeneration: UInt64 = 0
    #if !os(tvOS)
    /// 年归档里、本机记录之外的播放次数。清空听歌记录(也可能是别的设备清的)之后要重读。
    private var archived: (clearedAt: Date?, counts: [String: Int])?
    private var archiveLoad: (clearedAt: Date?, task: Task<Void, Never>)?
    #endif

    private init() {}

    /// 完全随机时为 nil: 调用方照原来的 `shuffled()` 走, 不碰播放次数。
    func weighting(for preference: ShufflePreference, library: MusicLibrary?) -> ShuffleWeighting? {
        guard preference != .uniform else { return nil }
        return ShuffleWeighting(preference: preference, counts: playCounts(library: library))
    }

    func playCounts(library: MusicLibrary?, history: PlayHistoryStore = .shared) -> ShufflePlayCounts {
        #if !os(tvOS)
        loadArchivedCountsIfNeeded(history: history)
        #endif
        let key = CacheKey(
            historyVersion: history.playCountsVersion,
            archiveGeneration: archiveGeneration,
            library: library.map(ObjectIdentifier.init),
            libraryRevision: library?.musicSongsRevision
        )
        if let cached, cached.key == key { return cached.counts }

        var local = history.playCountsBySongID
        #if !os(tvOS)
        if let archived, archived.clearedAt == history.clearedAt, !archived.counts.isEmpty {
            local.merge(archived.counts, uniquingKeysWith: +)
        }
        #endif
        var counted: [ShuffleCandidate] = []
        if let library {
            counted = serverCountedSongs(in: library)
            var resolver = ShuffleArtistKeyResolver()
            counted.reserveCapacity(counted.count + local.count)
            for songID in local.keys {
                guard let song = library.unobservedVisibleSong(id: songID) else { continue }
                counted.append(ShuffleWeighting.candidate(for: song, resolver: &resolver))
            }
        }
        let counts = ShufflePlayCounts(localCounts: local, countedSongs: counted)
        cached = (key, counts)
        return counts
    }

    private func serverCountedSongs(in library: MusicLibrary) -> [ShuffleCandidate] {
        let identity = ObjectIdentifier(library)
        let revision = library.musicSongsRevision
        if let serverCounted, serverCounted.library == identity, serverCounted.revision == revision {
            return serverCounted.songs
        }
        var resolver = ShuffleArtistKeyResolver()
        var songs: [ShuffleCandidate] = []
        library.visibleSongLookup().forEachSong { song in
            guard let plays = song.serverPlayCount, plays > 0 else { return }
            songs.append(ShuffleWeighting.candidate(for: song, resolver: &resolver))
        }
        serverCounted = (identity, revision, songs)
        return songs
    }

    #if !os(tvOS)
    /// 在后台读年归档。已经读好(且清空听歌记录的时刻没变)时什么也不做; 返回的任务可以等它读完。
    @discardableResult
    func loadArchivedCountsIfNeeded(history: PlayHistoryStore = .shared) -> Task<Void, Never>? {
        let clearedAt = history.clearedAt
        if let archived, archived.clearedAt == clearedAt { return nil }
        if let archiveLoad, archiveLoad.clearedAt == clearedAt { return archiveLoad.task }
        // 当年的归档和本机记录有重叠, 按记录 id 去掉已经在本机记录里的。
        let liveIDs = Set(history.entries.map(\.id))
        let task = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { () -> [String: Int] in
                var counts: [String: Int] = [:]
                for entry in PlayHistoryArchiver.completeHistory(live: [], clearedAt: clearedAt)
                where !liveIDs.contains(entry.id) {
                    counts[entry.songID, default: 0] += 1
                }
                return counts
            }.value
            guard let self else { return }
            if self.archiveLoad?.clearedAt == clearedAt { self.archiveLoad = nil }
            guard history.clearedAt == clearedAt else { return }
            self.archived = (clearedAt, counts)
            self.archiveGeneration &+= 1
        }
        archiveLoad = (clearedAt, task)
        return task
    }
    #endif
}
