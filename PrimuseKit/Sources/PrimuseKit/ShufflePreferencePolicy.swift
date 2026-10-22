import Foundation

/// 随机播放怎么抽歌(#332)。不管哪一档, 一轮里每首都照样轮到一次、顺序照样随机;
/// 偏好只决定「谁更可能排在前面」, 按播放次数加权。
public enum ShufflePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 每首机会均等, 和没有这项设置之前一样。
    case uniform
    case frequentSongs
    case rareSongs
    case frequentArtists
    case rareArtists

    public static let defaultValue: ShufflePreference = .uniform

    public var id: String { rawValue }

    /// 按歌手累计的次数加权(而不是这首歌自己的次数)。
    public var weighsArtists: Bool {
        self == .frequentArtists || self == .rareArtists
    }
}

/// 一首歌参与加权时用到的信息。`artistKey` 是曲库给这首歌认定的歌手身份;
/// 「群星」这类占位署名、没有署名的歌为 nil, 按它自己的次数算。
public struct ShuffleCandidate: Sendable, Hashable {
    public var songID: String
    public var artistKey: String?
    /// 音乐服务器记下的播放次数, 没有记为 0。
    public var serverPlayCount: Int

    public init(songID: String, artistKey: String?, serverPlayCount: Int?) {
        self.songID = songID
        self.artistKey = artistKey
        self.serverPlayCount = max(0, serverPlayCount ?? 0)
    }
}

/// 把歌手署名换成加权用的歌手身份。同一个名字在曲库里出现成百上千次, 占位署名判一次就记下。
public struct ShuffleArtistKeyResolver: Sendable {
    private var placeholderByName: [String: Bool] = [:]

    public init() {}

    /// `artistID` 是曲库按第一位歌手算好的身份, 与艺人页、听歌排行同一套归一口径。
    public mutating func artistKey(artistName: String?, artistID: String?) -> String? {
        guard let artistID, !artistID.isEmpty,
              let artistName,
              !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let isPlaceholder = placeholderByName[artistName] ?? PlaceholderArtistPolicy.isPlaceholder(artistName)
        placeholderByName[artistName] = isPlaceholder
        return isPlaceholder ? nil : artistID
    }
}

/// 加权用的播放次数。一首歌的次数取本机听歌记录与音乐服务器记下的较大者:
/// 两边多半记的是同一批播放(本机播放也会上报给服务器), 相加会重复计;
/// 歌手的次数是名下各首歌这个较大者之和。
public struct ShufflePlayCounts: Sendable {
    public static let empty = ShufflePlayCounts(localCounts: [:], countedSongs: [])

    private let localCounts: [String: Int]
    private let artistTotals: [String: Int]

    /// - Parameters:
    ///   - localCounts: 本机记录里每首歌的播放次数。
    ///   - countedSongs: 用来累计歌手次数的歌, 即本机或服务器上有过播放的那些;
    ///     同一首出现多次只算一次。
    public init(localCounts: [String: Int], countedSongs: [ShuffleCandidate]) {
        self.localCounts = localCounts
        var totals: [String: Int] = [:]
        var seen = Set<String>()
        for song in countedSongs where seen.insert(song.songID).inserted {
            guard let key = song.artistKey else { continue }
            totals[key] = Self.saturatingSum(totals[key] ?? 0, Self.songPlayCount(song, localCounts: localCounts))
        }
        self.artistTotals = totals
    }

    public func songPlayCount(_ candidate: ShuffleCandidate) -> Int {
        Self.songPlayCount(candidate, localCounts: localCounts)
    }

    /// 歌手的累计次数; 认不出歌手的歌用它自己的次数。
    public func artistPlayCount(_ candidate: ShuffleCandidate) -> Int {
        let own = songPlayCount(candidate)
        guard let key = candidate.artistKey else { return own }
        // 这首歌不在累计名单里(刚入库、刚有服务器次数)时, 歌手至少有它这几次。
        return max(artistTotals[key] ?? 0, own)
    }

    private static func songPlayCount(_ candidate: ShuffleCandidate, localCounts: [String: Int]) -> Int {
        max(0, localCounts[candidate.songID] ?? 0, candidate.serverPlayCount)
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

/// 按偏好加权的随机排列(Efraimidis–Spirakis): 每个元素抽一个 (0, 1) 间的随机数 u,
/// 以 u^(1/w) 为键从大到小排。任意两首里权重 a 的排在权重 b 前面的概率是 a / (a + b),
/// 所以仍然是随机、每首都在, 只是权重大的更常排在前面。
public enum WeightedShufflePolicy {
    /// 一首歌在这一档偏好下的权重, 始终是有限正数。
    /// - 歌: 1 + 次数(少听优先取倒数)。听过 20 次与没听过的两首, 先轮到前者的机会约 95%。
    /// - 歌手: 名下次数相加后差距大得多, 取平方根, 免得前几位常听歌手把一整轮占满。
    public static func weight(playCount: Int, preference: ShufflePreference) -> Double {
        let plays = 1 + Double(max(0, playCount))
        switch preference {
        case .uniform: return 1
        case .frequentSongs: return plays
        case .rareSongs: return 1 / plays
        case .frequentArtists: return plays.squareRoot()
        case .rareArtists: return 1 / plays.squareRoot()
        }
    }

    /// 找不到这首歌的信息时按没有播放过算。
    public static func weight(
        of candidate: ShuffleCandidate?,
        preference: ShufflePreference,
        counts: ShufflePlayCounts
    ) -> Double {
        guard preference != .uniform else { return 1 }
        guard let candidate else { return weight(playCount: 0, preference: preference) }
        let plays = preference.weighsArtists
            ? counts.artistPlayCount(candidate)
            : counts.songPlayCount(candidate)
        return weight(playCount: plays, preference: preference)
    }

    /// 按偏好排好的随机顺序。`.uniform` 就是 `shuffled(using:)`, 与原来一模一样。
    public static func shuffled<Element, G: RandomNumberGenerator>(
        _ elements: [Element],
        preference: ShufflePreference,
        counts: ShufflePlayCounts,
        candidate: (Element) -> ShuffleCandidate?,
        using generator: inout G
    ) -> [Element] {
        guard preference != .uniform else { return elements.shuffled(using: &generator) }
        return shuffled(
            elements,
            weight: { weight(of: candidate($0), preference: preference, counts: counts) },
            using: &generator
        )
    }

    public static func shuffled<Element>(
        _ elements: [Element],
        preference: ShufflePreference,
        counts: ShufflePlayCounts,
        candidate: (Element) -> ShuffleCandidate?
    ) -> [Element] {
        var generator = SystemRandomNumberGenerator()
        return shuffled(elements, preference: preference, counts: counts, candidate: candidate, using: &generator)
    }

    /// 通用的加权随机排列。权重是 0、负数或 NaN 的排在所有正权重之后, 正无穷排在最前,
    /// 同一类里仍是随机次序; 极小或极大的权重不会让键下溢、上溢成同一个值而失去随机性。
    public static func shuffled<Element, G: RandomNumberGenerator>(
        _ elements: [Element],
        weight: (Element) -> Double,
        using generator: inout G
    ) -> [Element] {
        guard elements.count > 1 else { return elements }
        var keys: [Key] = []
        keys.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            let w = weight(element)
            let u = unitInterval(using: &generator)
            let tiebreak = generator.next()
            if w.isNaN || w <= 0 {
                keys.append(Key(tier: 2, value: u, tiebreak: tiebreak, index: index))
            } else if w.isInfinite {
                keys.append(Key(tier: 0, value: u, tiebreak: tiebreak, index: index))
            } else {
                // ln(u^(1/w)) = ln(u) / w, 同样的次序, 但不会因 1/w 太大而下溢成 0。
                keys.append(Key(tier: 1, value: log(u) / w, tiebreak: tiebreak, index: index))
            }
        }
        keys.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            if lhs.tiebreak != rhs.tiebreak { return lhs.tiebreak < rhs.tiebreak }
            return lhs.index < rhs.index
        }
        return keys.map { elements[$0.index] }
    }

    private struct Key {
        let tier: UInt8
        let value: Double
        let tiebreak: UInt64
        let index: Int
    }

    /// 开区间 (0, 1) 上的均匀随机数: u 取到 0 时 ln(u) 是负无穷, 和极小权重混在一起。
    private static func unitInterval<G: RandomNumberGenerator>(using generator: inout G) -> Double {
        (Double(generator.next() >> 11) + 0.5) * 0x1p-53
    }
}
