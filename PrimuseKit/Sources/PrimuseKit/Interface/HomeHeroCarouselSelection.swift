import Foundation

/// 首页顶部封面轮播放哪几张。
///
/// 候选只来自音乐:有声书、相声、播客单集与电台都不进来(调用方传的是 `musicSongs`
/// 与已经去掉有声内容的播放记录)。一张专辑只出一张卡,否则同一张专辑的几首歌会排成
/// 一串一模一样的封面。三组各占一份名额:
/// - 最近听过:打底的熟悉感;
/// - 好久没听:整个音乐曲库里近 30 天没放过的专辑,轮播值得滑主要靠这一组;
/// - 最近添加。
/// 某一组不够时由其余组补满。这三组配额只管正中那几张「今天的」封面,再往两边
/// 三组轮流接着摆,轮播首尾相接循环滑动,一圈要够长才滑不腻(见 `HomeHeroCarouselLoop`)。
///
/// 按「种子 + 专辑」的稳定哈希排名,不直接 `shuffled()`:冷启动期间资料库、播放记录、回填
/// 每变一次首页就重算一次,以前用 `shuffled()` 时每次都换一组,封面跟着换人、从占位淡入,
/// 看起来一直在闪,「相同结果不写快照」也拦不住。种子和候选不变结果就不变,候选进出一张
/// 也最多换掉一张。种子每次打开 App 换一个(`HomeHeroCarouselSeeds`);以前按日期定,
/// 同一天怎么重开正中都是同一张(#185)。
///
/// 结果从中间往两边摆,轮播一出现两边都有卡。正中那张出自哪一组也由种子定,
/// 不总是最近听过的那张。
public enum HomeHeroCarouselSelection {
    public struct Candidate: Equatable, Sendable {
        public let songID: String
        /// 去重用的专辑键,见 `albumKey(albumID:coverRef:)`。
        public let albumKey: String

        public init(songID: String, albumKey: String) {
            self.songID = songID
            self.albumKey = albumKey
        }
    }

    /// 一圈最多这么多张。
    public static let cardCount = 48
    /// 正中按三组配额挑的「今天的」几张。
    public static let featuredCount = 8
    /// 少于这么多张时首页仍用原来的欢迎卡片,两三张撑不起一条轮播。
    public static let minimumCardCount = 3
    /// 「好久没听」看的是这么多天里有没有放过。
    public static let rediscoveryWindowDays = 30

    static let recentQuota = 3
    static let rediscoveryQuota = 3
    static let addedQuota = 2

    /// 专辑 id 本身就是键(不另拼字符串,整库扫描时每首歌省一次分配);没有专辑的歌
    /// 按封面文件去重。专辑 id 是十六进制摘要,不会和带前缀的封面键撞上。
    public static func albumKey(albumID: String?, coverRef: String?) -> String? {
        if let albumID, !albumID.isEmpty { return albumID }
        if let coverRef, !coverRef.isEmpty { return "cover:" + coverRef }
        return nil
    }

    /// 轮播一出现时居中的位置,即 `pick` 排在第一的那张。
    public static func initialIndex(count: Int) -> Int {
        max(0, (count - 1) / 2)
    }

    /// - Parameters:
    ///   - recent: 最近听过的歌,越近越靠前。
    ///   - added: 最近添加的歌,越新越靠前。
    ///   - rediscovery: `RediscoveryPool.candidates()`。
    /// - Returns: 按轮播从左到右的顺序排好的歌曲 id。
    public static func pick(
        recent: [Candidate],
        added: [Candidate],
        rediscovery: [Candidate],
        seed: UInt64,
        count: Int = cardCount
    ) -> [String] {
        guard count > 0 else { return [] }
        let featured = min(count, featuredCount)
        var used = Set<String>()
        let groups = [
            ranked(recent, seed: seed),
            ranked(rediscovery, seed: seed),
            ranked(added, seed: seed),
        ]
        let quotas = [recentQuota, rediscoveryQuota, addedQuota]
        var taken: [[Candidate]] = [[], [], []]
        for (index, group) in groups.enumerated() {
            for candidate in group where taken[index].count < quotas[index] {
                guard used.count < featured, used.insert(candidate.albumKey).inserted else { continue }
                taken[index].append(candidate)
            }
        }
        // 名额没用完:先从好久没听补,再最近添加,最后最近听过。
        for index in [1, 2, 0] {
            for candidate in groups[index] where used.count < featured {
                guard used.insert(candidate.albumKey).inserted else { continue }
                taken[index].append(candidate)
            }
        }

        // 三组轮流排,摆到轮播上时相邻的卡来自不同的组。哪一组领头、落在正中由种子定。
        let lead = Int(seed % 3)
        let turns = (0..<3).map { (lead + $0) % 3 }
        var ordered: [String] = []
        ordered.reserveCapacity(count)
        var cursor = 0
        while ordered.count < used.count {
            for index in turns where cursor < taken[index].count {
                ordered.append(taken[index][cursor].songID)
            }
            cursor += 1
        }

        // 「今天的」几张之后,好久没听、最近添加、最近听过轮流各接一张,直到一圈摆满。
        var next = [0, 0, 0]
        var progressed = true
        while ordered.count < count, progressed {
            progressed = false
            for index in [1, 2, 0] where ordered.count < count {
                while next[index] < groups[index].count {
                    let candidate = groups[index][next[index]]
                    next[index] += 1
                    guard used.insert(candidate.albumKey).inserted else { continue }
                    ordered.append(candidate.songID)
                    progressed = true
                    break
                }
            }
        }
        return centerOut(ordered)
    }

    /// 第一个放正中,其后依次右、左、右、左往外摆。
    static func centerOut(_ ordered: [String]) -> [String] {
        guard ordered.count > 2 else { return ordered }
        let center = initialIndex(count: ordered.count)
        var slots = [String?](repeating: nil, count: ordered.count)
        var next = 0
        var distance = 0
        while next < ordered.count {
            for slot in distance == 0 ? [center] : [center + distance, center - distance]
            where slots.indices.contains(slot) && next < ordered.count {
                slots[slot] = ordered[next]
                next += 1
            }
            distance += 1
        }
        return slots.compactMap { $0 }
    }

    /// 组内去重(同一张专辑留最先出现的那首),再按种子定的排名排。
    static func ranked(_ candidates: [Candidate], seed: UInt64) -> [Candidate] {
        var seen = Set<String>()
        var scored: [(candidate: Candidate, rank: UInt64)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates where !candidate.songID.isEmpty && !candidate.albumKey.isEmpty {
            guard seen.insert(candidate.albumKey).inserted else { continue }
            scored.append((candidate, rank(albumKey: candidate.albumKey, seed: seed)))
        }
        scored.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.candidate.albumKey < rhs.candidate.albumKey
        }
        return scored.map(\.candidate)
    }

    static func rank(albumKey: String, seed: UInt64) -> UInt64 {
        StableFNV1a64.hash("\(seed)|\(albumKey)")
    }

    /// 整个音乐曲库扫一遍,留下按种子排名最靠前、近期没放过的若干张专辑。
    ///
    /// 不排序整库:只维护一个 `limit` 大小的候选表,每首歌只做一次表查找;新专辑要进表时
    /// 才算排名、查是不是近期放过。一张专辑挑轨号最小的那首当代表(同号取 id 小的),
    /// 和遍历顺序无关,曲库顺序变了代表曲也不变。
    public struct RediscoveryPool {
        private struct Entry {
            let rank: UInt64
            var songID: String
            var trackNumber: Int
        }

        public let limit: Int
        private let seed: UInt64
        private let playedAlbumKeys: Set<String>
        private var best: [String: Entry] = [:]
        private var worst: (key: String, rank: UInt64)?

        /// - Parameter playedAlbumKeys: 近 `rediscoveryWindowDays` 天放过的专辑键。
        public init(seed: UInt64, playedAlbumKeys: Set<String>, limit: Int = 64) {
            self.limit = max(1, limit)
            self.playedAlbumKeys = playedAlbumKeys
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in "\(seed)|".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            self.seed = hash
            best.reserveCapacity(self.limit)
        }

        /// - Returns: 这首歌刚成了它那张专辑在候选表里的代表(专辑新进表,或换了代表曲)。
        ///   调用方据此记下歌曲本身,挑完后按专辑键取回,不必再扫一遍整库。
        @discardableResult
        public mutating func consider(songID: String, albumKey: String, trackNumber: Int?) -> Bool {
            guard !songID.isEmpty, !albumKey.isEmpty else { return false }
            let track = trackNumber ?? Int.max
            if var entry = best[albumKey] {
                guard track < entry.trackNumber || (track == entry.trackNumber && songID < entry.songID) else {
                    return false
                }
                entry.songID = songID
                entry.trackNumber = track
                best[albumKey] = entry
                return true
            }
            let rank = rank(of: albumKey)
            if best.count >= limit {
                let worst = worstEntry()
                guard rank < worst.rank || (rank == worst.rank && albumKey < worst.key) else { return false }
                guard !playedAlbumKeys.contains(albumKey) else { return false }
                best[worst.key] = nil
            } else {
                guard !playedAlbumKeys.contains(albumKey) else { return false }
            }
            best[albumKey] = Entry(rank: rank, songID: songID, trackNumber: track)
            self.worst = nil
            return true
        }

        public func candidates() -> [Candidate] {
            let ordered = best.sorted { (lhs: (key: String, value: Entry), rhs: (key: String, value: Entry)) -> Bool in
                if lhs.value.rank != rhs.value.rank { return lhs.value.rank < rhs.value.rank }
                return lhs.key < rhs.key
            }
            return ordered.map { Candidate(songID: $0.value.songID, albumKey: $0.key) }
        }

        private func rank(of albumKey: String) -> UInt64 {
            var hash = seed
            for byte in albumKey.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return hash
        }

        private mutating func worstEntry() -> (key: String, rank: UInt64) {
            if let worst { return worst }
            var found: (key: String, rank: UInt64)?
            for (key, entry) in best {
                if let current = found,
                   entry.rank < current.rank || (entry.rank == current.rank && key < current.key) {
                    continue
                }
                found = (key, entry.rank)
            }
            // best 满了才会来这里,found 一定有值。
            let resolved = found ?? ("", 0)
            worst = resolved
            return resolved
        }
    }
}

/// 首页顶部封面轮播用哪个种子挑(`HomeHeroCarouselSelection.pick`):每次打开 App 换一组(#185)。
///
/// 冷启动首帧画的是上次存下的那一组,后台再按这次的种子重算;两边种子不同,封面刚亮出来就会
/// 整组换掉。所以下一次的种子这一次就定好:存首页快照时顺手按 `next` 挑好一组存下,
/// 下次打开拿存下的种子当 `current`,首帧与重算出来的是同一组。
/// 一直开着跨了天也换一组 —— 后台一直放歌的人可能好几天都不冷启动。
public struct HomeHeroCarouselSeeds: Equatable, Sendable {
    public private(set) var current: UInt64
    public private(set) var next: UInt64
    public private(set) var dayStamp: Int

    /// - Parameter prepared: 上次给这次准备的种子;没有(第一次打开、快照是旧版本)就新抽一个。
    public init(
        prepared: UInt64?,
        dayStamp: Int,
        random: () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) {
        let current = prepared ?? random()
        self.current = current
        self.next = Self.draw(differentFrom: current, random)
        self.dayStamp = dayStamp
    }

    /// 跨了天:换成给下次准备的那组,再抽一个新的下次。同一天什么都不动。
    @discardableResult
    public mutating func advance(
        toDay dayStamp: Int,
        random: () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) -> Bool {
        guard dayStamp != self.dayStamp else { return false }
        self.dayStamp = dayStamp
        current = next
        next = Self.draw(differentFrom: current, random)
        return true
    }

    private static func draw(differentFrom current: UInt64, _ random: () -> UInt64) -> UInt64 {
        let value = random()
        return value == current ? value &+ 1 : value
    }
}

/// 首页轮播只维护固定数量的卡片，移出视野的卡片循环复用。
public enum HomeHeroCarouselLoop {
    public static let capacity = 13

    public static func slotCount(itemCount: Int) -> Int {
        itemCount > 0 ? capacity : 0
    }

    public static func index(ofSlot slot: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let remainder = slot % itemCount
        return remainder >= 0 ? remainder : remainder + itemCount
    }
}
