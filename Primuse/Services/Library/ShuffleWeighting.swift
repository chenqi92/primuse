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

    /// 找不到的歌、没播放过的歌的权重。
    var defaultWeight: Double {
        WeightedShufflePolicy.weight(of: nil, preference: preference, counts: counts)
    }

    /// 一首歌的权重, 与 `weights(_:song:)` 同一算法; 整库请求在目录上逐首遍历时用,
    /// 同一个 `resolver` 跨整趟复用(它只缓存占位署名的判断)。
    func weight(of song: Song?, resolver: inout ShuffleArtistKeyResolver) -> Double {
        let candidate = song.map { Self.candidate(for: $0, resolver: &resolver) }
        return WeightedShufflePolicy.weight(of: candidate, preference: preference, counts: counts)
    }

    /// 同 `shuffled(ids:lookup:)`, 权重事先算好: `sparseWeights` 只记与 `defaultWeight` 不同的歌,
    /// 其余按默认权重。目录上的整库请求用(不为整库建查找表)。
    func shuffled(ids: [String], sparseWeights: [String: Double]) -> [String] {
        guard ids.count > 1 else { return ids }
        let fallback = defaultWeight
        let elementWeights = ids.map { sparseWeights[$0] ?? fallback }
        var generator = SystemRandomNumberGenerator()
        return WeightedShufflePolicy.shuffled(
            Array(ids.indices),
            weight: { elementWeights[$0] },
            using: &generator
        ).map { ids[$0] }
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
        /// 歌曲模型在不在内存里: 不在时算出的那份(服务器播放次数沿用上一次扫出来的)不留给装回来之后用。
        let songModelLoaded: Bool
    }

    private var cached: (key: CacheKey, counts: ShufflePlayCounts)?
    /// 服务器上有播放次数的那些歌, 曲库换一版才重新扫。
    private var serverCounted: (library: ObjectIdentifier, revision: UInt64, songs: [ShuffleCandidate])?
    /// 歌曲模型不在内存里时, 本机有播放次数的歌按 id 问过曲库目录的结果(值为 nil: 不在可见曲库里)。
    /// 每放一首只多查新出现的那几首, 不把听歌记录里的几千首重新按 id 查一遍。条数以听歌记录为界。
    private var localCandidatesWithoutTheModel: (
        library: ObjectIdentifier, revision: UInt64, candidates: [String: ShuffleCandidate?]
    )?
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
        let songModelLoaded = library.map(Self.songModelIsLoaded) ?? true
        let key = CacheKey(
            historyVersion: history.playCountsVersion,
            archiveGeneration: archiveGeneration,
            library: library.map(ObjectIdentifier.init),
            libraryRevision: library?.musicSongsRevision,
            songModelLoaded: songModelLoaded
        )
        if let cached, cached.key == key { return cached.counts }

        let local = localPlayCounts(history: history)
        var counted: [ShuffleCandidate] = []
        if let library {
            counted = serverCountedSongs(in: library)
            var resolver = ShuffleArtistKeyResolver()
            counted.reserveCapacity(counted.count + local.count)
            if songModelLoaded {
                localCandidatesWithoutTheModel = nil
                for songID in local.keys {
                    guard let song = library.unobservedVisibleSong(id: songID) else { continue }
                    counted.append(ShuffleWeighting.candidate(for: song, resolver: &resolver))
                }
            } else if library.canAnswerSongLookups {
                // 歌曲模型不在内存里: 按 id 读问的是曲库目录。问过的记着, 这一轮只问新出现的。
                let identity = ObjectIdentifier(library)
                let revision = library.musicSongsRevision
                var memo = localCandidatesWithoutTheModel.flatMap {
                    $0.library == identity && $0.revision == revision ? $0.candidates : nil
                } ?? [:]
                for songID in local.keys {
                    if let known = memo[songID] {
                        if let known { counted.append(known) }
                        continue
                    }
                    let candidate = library.unobservedVisibleSong(id: songID).map {
                        ShuffleWeighting.candidate(for: $0, resolver: &resolver)
                    }
                    memo.updateValue(candidate, forKey: songID)
                    if let candidate { counted.append(candidate) }
                }
                // 问到一半目录答不了了: 这一轮里的「不在」不可信, 不留。
                localCandidatesWithoutTheModel = library.canAnswerSongLookups ? (identity, revision, memo) : nil
            } else {
                // 模型不在、目录这条路也答不了: 查不到不是「这些歌都不在了」。沿用上一次算好的, 不把这一轮记下来。
                return cached?.counts ?? ShufflePlayCounts(localCounts: local, countedSongs: counted)
            }
        }
        let counts = ShufflePlayCounts(localCounts: local, countedSongs: counted)
        cached = (key, counts)
        return counts
    }

    func localPlayCounts(history: PlayHistoryStore = .shared) -> [String: Int] {
        var local = history.playCountsBySongID
        #if !os(tvOS)
        loadArchivedCountsIfNeeded(history: history)
        if let archived, archived.clearedAt == history.clearedAt {
            local.merge(archived.counts, uniquingKeysWith: +)
        }
        #endif
        return local
    }

    private func serverCountedSongs(in library: MusicLibrary) -> [ShuffleCandidate] {
        let identity = ObjectIdentifier(library)
        let revision = library.musicSongsRevision
        if let serverCounted, serverCounted.library == identity, serverCounted.revision == revision {
            return serverCounted.songs
        }
        // 歌曲模型不在内存里时这趟整库遍历读到的是空的。沿用这个库上一次扫出来的那份(服务器播放次数只在扫描时变,
        // 扫描会把模型装回来), 不把空结果记成这一版的答案, 也不为它去装模型。
        guard Self.songModelIsLoaded(library) else {
            return serverCounted.flatMap { $0.library == identity ? $0.songs : nil } ?? []
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

extension ShufflePlayCountStore {
    /// 整库数组此刻读不读得到。电视端的曲库一直常驻, 重装快照期间旧数组也还在。
    fileprivate static func songModelIsLoaded(_ library: MusicLibrary) -> Bool {
        #if os(tvOS)
        true
        #else
        library.isReady
        #endif
    }
}
