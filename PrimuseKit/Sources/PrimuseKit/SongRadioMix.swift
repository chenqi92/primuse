import Foundation

/// 「歌曲电台」「相似歌曲」的出歌顺序。
///
/// 几路候选(Last.fm 相似歌曲、Last.fm 相似艺人在曲库里的歌、本地按标签算的相似度)
/// 各自按相似程度从高到低排好,这里轮流从每一路取,同一张专辑、同一位艺人限量,
/// 最后把同一位艺人的歌拉开。只按本地标签打分时同专辑、同艺人的分数远高于其余,
/// 不限量的话电台就成了把这张专辑从头放一遍。
public enum SongRadioMixPolicy {
    public struct Limits: Equatable, Sendable {
        /// 同一张专辑最多几首,种子算一首。
        public var perAlbum: Int
        /// 种子以外的同一位艺人最多几首。
        public var perArtist: Int
        /// 种子的艺人最多几首,种子算一首。
        public var seedArtist: Int

        public init(perAlbum: Int, perArtist: Int, seedArtist: Int) {
            self.perAlbum = max(1, perAlbum)
            self.perArtist = max(1, perArtist)
            self.seedArtist = max(1, seedArtist)
        }

        /// 四五十首的电台。
        public static let radio = Limits(perAlbum: 2, perArtist: 3, seedArtist: 6)
        /// 二三十首的「相似歌曲」列表。
        public static let similarList = Limits(perAlbum: 3, perArtist: 3, seedArtist: 6)
    }

    /// 同一位艺人两首之间最少隔几首;往后最多看这么远找一首别的艺人。
    static let artistSpacingWindow = 6

    /// - Parameters:
    ///   - sources: 各路候选,每一路从最像到最不像。轮流各取一首。
    ///   - fallback: 各路都取完还不够时按顺序补的歌(比如每日推荐)。
    ///   - album / artist: 一首歌所属的专辑、艺人;nil 表示不限量。
    /// - Returns: 不含种子的歌曲 id,按播放顺序。限量之后仍不够 `limit` 时,
    ///   用被限量挡下的歌补齐,曲库里只有一两位艺人时电台也不会早早停下。
    public static func compose(
        seedID: String,
        sources: [[String]],
        fallback: [String] = [],
        excluding excluded: Set<String> = [],
        limit: Int,
        limits: Limits = .radio,
        album: (String) -> String?,
        artist: (String) -> String?
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = excluded
        seen.insert(seedID)
        let seedAlbum = album(seedID)
        let seedArtist = artist(seedID)
        var albumCounts: [String: Int] = [:]
        var artistCounts: [String: Int] = [:]
        if let seedAlbum { albumCounts[seedAlbum] = 1 }
        if let seedArtist { artistCounts[seedArtist] = 1 }

        var picked: [String] = []
        var heldBack: [String] = []

        func admit(_ id: String) -> Bool {
            let albumKey = album(id)
            let artistKey = artist(id)
            if let albumKey, albumCounts[albumKey, default: 0] >= limits.perAlbum { return false }
            if let artistKey {
                let cap = artistKey == seedArtist ? limits.seedArtist : limits.perArtist
                if artistCounts[artistKey, default: 0] >= cap { return false }
            }
            if let albumKey { albumCounts[albumKey, default: 0] += 1 }
            if let artistKey { artistCounts[artistKey, default: 0] += 1 }
            picked.append(id)
            return true
        }

        var cursors = Array(repeating: 0, count: sources.count)
        var progressed = true
        while picked.count < limit, progressed {
            progressed = false
            for index in sources.indices {
                let list = sources[index]
                while cursors[index] < list.count {
                    let id = list[cursors[index]]
                    cursors[index] += 1
                    guard !id.isEmpty, seen.insert(id).inserted else { continue }
                    if admit(id) {
                        progressed = true
                        break
                    }
                    heldBack.append(id)
                }
                if picked.count == limit { break }
            }
        }
        for id in fallback where picked.count < limit {
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            if !admit(id) { heldBack.append(id) }
        }
        if picked.count < limit {
            // 被限量挡下的按原顺序补,但种子那张专辑、种子的艺人排到最后:
            // 实在不够时先多放几首别的艺人,而不是又回到这张专辑。
            func closeness(_ id: String) -> Int {
                var rank = 0
                if let seedAlbum, album(id) == seedAlbum { rank += 2 }
                if let seedArtist, artist(id) == seedArtist { rank += 1 }
                return rank
            }
            let ordered = heldBack.enumerated()
                .map { (offset: $0.offset, id: $0.element, rank: closeness($0.element)) }
                .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
            picked.append(contentsOf: ordered.prefix(limit - picked.count).map(\.id))
        }
        return spacedOut(picked, after: seedArtist, artist: artist)
    }

    /// 同一位艺人尽量不连着放:轮到的这首和上一首同艺人时,往后几首里找一首别的艺人提前。
    /// 找不到就照原顺序放,不打乱整体的相似程度排序。
    static func spacedOut(
        _ ids: [String],
        after seedArtist: String?,
        artist: (String) -> String?
    ) -> [String] {
        guard ids.count > 1 else { return ids }
        var remaining = ids.map { (id: $0, artist: artist($0)) }
        var output: [String] = []
        output.reserveCapacity(ids.count)
        var previous = seedArtist
        while !remaining.isEmpty {
            let window = min(remaining.count, artistSpacingWindow)
            let index = (0..<window).first { offset in
                guard let previous, let key = remaining[offset].artist else { return true }
                return key != previous
            } ?? 0
            let next = remaining.remove(at: index)
            output.append(next.id)
            previous = next.artist
        }
        return output
    }
}

/// 电台限量用的专辑、艺人归属。只看名字(大小写、全半角、繁简不同算同一个),
/// 不看来源给的 id:同一位艺人在两个音乐源里 id 不同,名字是一样的。
public enum SongRadioGrouping {
    /// 「A feat. B」「A/B」「A、B」都按 A 算。
    public static func artistKey(_ artist: String?) -> String? {
        guard let artist else { return nil }
        let first = SimilarTrackLibraryMatcher.artistParts(artist).first ?? artist
        let key = SongDiscoveryMatching.artistKey(first)
        return key.isEmpty ? nil : key
    }

    /// 专辑名 + 专辑艺人(没有时用艺人):合辑「Greatest Hits」不会把不同艺人并成一张。
    public static func albumKey(album: String?, albumArtist: String?, artist: String?) -> String? {
        guard let album else { return nil }
        let title = SongDiscoveryMatching.key(album)
        guard !title.isEmpty else { return nil }
        let owner = artistKey(albumArtist) ?? artistKey(artist) ?? ""
        return title + "\u{1F}" + owner
    }
}

/// 把 Last.fm 的相似歌曲、相似艺人对到曲库里能播的歌。
///
/// 歌名去掉括号里的版本说明和「 - Live」这类后缀再比,艺人比主艺人,繁简算同一个;
/// 曲库只扫一遍,同一个艺人字段只折叠一次,大曲库上也只做字典查找。
public struct SimilarTrackLibraryMatcher {
    public struct Track: Equatable, Sendable {
        public var title: String
        public var artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }

    public struct LibrarySong: Equatable, Sendable {
        public var id: String
        public var title: String
        public var artist: String?

        public init(id: String, title: String, artist: String?) {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }

    public struct Result: Equatable, Sendable {
        /// 和 `tracks` 一一对应;曲库里没有这首时为 nil。
        public var trackSongIDs: [String?]
        /// 和 `artists` 一一对应;每位艺人在曲库里的歌,按 `ordering` 排,最多 `songsPerArtist` 首。
        public var artistSongIDs: [[String]]

        public init(trackSongIDs: [String?], artistSongIDs: [[String]]) {
            self.trackSongIDs = trackSongIDs
            self.artistSongIDs = artistSongIDs
        }
    }

    /// 一个艺人字段里写了几位艺人时拆开;「Simon & Garfunkel」这样的组合名不拆。
    static func artistParts(_ artist: String) -> [String] {
        let primary = SongDiscoveryMatching.primaryArtist(artist)
        let separators = CharacterSet(charactersIn: "/、;；")
        let parts = primary.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [primary] : parts
    }

    /// - Parameters:
    ///   - songs: 曲库里可以选的歌(调用方已去掉不能播、不喜欢的)。
    ///   - ordering: 同一位艺人的歌怎么排,小的在前;用来按天换着挑,而不是总给前几首。
    public static func match(
        tracks: [Track],
        artists: [String],
        songs: [LibrarySong],
        songsPerArtist: Int = 3,
        ordering: (String) -> UInt64 = { _ in 0 }
    ) -> Result {
        var lookupKeys = Set<String>()
        for track in tracks { lookupKeys.formUnion(SongDiscoveryMatching.artistLookupKeys(track.artist)) }
        for name in artists { lookupKeys.formUnion(SongDiscoveryMatching.artistLookupKeys(name)) }
        guard !lookupKeys.isEmpty else {
            return Result(
                trackSongIDs: Array(repeating: nil, count: tracks.count),
                artistSongIDs: Array(repeating: [], count: artists.count)
            )
        }

        // 原样的艺人字段 → 对得上的艺人键;对不上的记空数组,同一个字段只折叠一次。
        var artistCache: [String: [String]] = [:]
        var songByPair: [String: String] = [:]
        var songsByArtist: [String: [String]] = [:]
        for song in songs {
            guard let raw = song.artist, !song.id.isEmpty else { continue }
            let keys: [String]
            if let cached = artistCache[raw] {
                keys = cached
            } else {
                var resolved: [String] = []
                for part in artistParts(raw) where lookupKeys.contains(SongDiscoveryMatching.key(part)) {
                    let key = SongDiscoveryMatching.artistKey(part)
                    if !resolved.contains(key) { resolved.append(key) }
                }
                artistCache[raw] = resolved
                keys = resolved
            }
            guard !keys.isEmpty else { continue }
            let titleKey = SongDiscoveryMatching.titleKey(song.title)
            for key in keys {
                let pair = titleKey + "\u{1F}" + key
                if songByPair[pair] == nil { songByPair[pair] = song.id }
                songsByArtist[key, default: []].append(song.id)
            }
        }

        let trackSongIDs = tracks.map { track -> String? in
            let artistKey = SongDiscoveryMatching.artistKey(track.artist)
            guard !artistKey.isEmpty else { return nil }
            return songByPair[SongDiscoveryMatching.titleKey(track.title) + "\u{1F}" + artistKey]
        }
        let perArtist = max(0, songsPerArtist)
        let artistSongIDs = artists.map { name -> [String] in
            let key = SongDiscoveryMatching.artistKey(name)
            guard perArtist > 0, let ids = songsByArtist[key] else { return [] }
            let ordered = ids.enumerated().sorted { lhs, rhs in
                let left = ordering(lhs.element)
                let right = ordering(rhs.element)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            return Array(ordered.prefix(perArtist).map(\.element))
        }
        return Result(trackSongIDs: trackSongIDs, artistSongIDs: artistSongIDs)
    }

    /// 相似艺人的歌轮流排:每位艺人先各出一首,再各出第二首。
    public static func interleaved(_ groups: [[String]]) -> [String] {
        var output: [String] = []
        var round = 0
        var added = true
        while added {
            added = false
            for group in groups where group.indices.contains(round) {
                output.append(group[round])
                added = true
            }
            round += 1
        }
        return output
    }
}
