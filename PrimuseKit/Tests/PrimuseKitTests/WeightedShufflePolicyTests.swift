import Foundation
import Testing
@testable import PrimuseKit

@Suite("Weighted shuffle preference")
struct WeightedShufflePolicyTests {
    /// SplitMix64: 同一个种子每次给出同一串数, 统计性用例因此可复现。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func candidates(_ plays: [Int], artist: (Int) -> String? = { _ in nil }) -> [ShuffleCandidate] {
        plays.indices.map { ShuffleCandidate(songID: "s\($0)", artistKey: artist($0), serverPlayCount: plays[$0]) }
    }

    private static func meanPosition(of ids: Set<String>, in order: [ShuffleCandidate]) -> Double {
        let positions = order.enumerated().filter { ids.contains($0.element.songID) }.map { Double($0.offset) }
        return positions.reduce(0, +) / Double(max(positions.count, 1))
    }

    @Test("Fully random is exactly the plain shuffle for the same seed")
    func uniformMatchesPlainShuffle() {
        let songs = Self.candidates(Array(repeating: 3, count: 40) + Array(repeating: 0, count: 40))
        var weightedGenerator = SeededGenerator(state: 7)
        var plainGenerator = SeededGenerator(state: 7)
        let weighted = WeightedShufflePolicy.shuffled(
            songs, preference: .uniform, counts: .empty, candidate: { $0 }, using: &weightedGenerator
        )
        let plain = songs.shuffled(using: &plainGenerator)
        #expect(weighted == plain)
    }

    @Test("Every preference keeps each song exactly once")
    func everyPreferenceIsAPermutation() {
        let songs = Self.candidates((0..<120).map { $0 % 7 * 3 }, artist: { "a\($0 % 5)" })
        let counts = ShufflePlayCounts(localCounts: ["s3": 40], countedSongs: songs)
        for preference in ShufflePreference.allCases {
            var generator = SeededGenerator(state: 11)
            let order = WeightedShufflePolicy.shuffled(
                songs, preference: preference, counts: counts, candidate: { $0 }, using: &generator
            )
            #expect(order.count == songs.count)
            #expect(Set(order.map(\.songID)) == Set(songs.map(\.songID)))
        }
    }

    @Test("The same seed gives the same weighted order, another seed a different one")
    func seededOrderIsReproducible() {
        let songs = Self.candidates((0..<60).map { $0 % 4 })
        var first = SeededGenerator(state: 42)
        var second = SeededGenerator(state: 42)
        var other = SeededGenerator(state: 43)
        let a = WeightedShufflePolicy.shuffled(songs, preference: .rareSongs, counts: .empty, candidate: { $0 }, using: &first)
        let b = WeightedShufflePolicy.shuffled(songs, preference: .rareSongs, counts: .empty, candidate: { $0 }, using: &second)
        let c = WeightedShufflePolicy.shuffled(songs, preference: .rareSongs, counts: .empty, candidate: { $0 }, using: &other)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Zero, negative, NaN and infinite weights do not crash and sort into tiers")
    func degenerateWeights() {
        let weights: [Double] = [0, -3, .nan, .infinity, 1, 2, 0, .infinity, -.infinity, 5]
        var generator = SeededGenerator(state: 3)
        let order = WeightedShufflePolicy.shuffled(Array(weights.indices), weight: { weights[$0] }, using: &generator)
        #expect(order.sorted() == Array(weights.indices))
        // 正无穷的两个在最前, 有限正权重的三个在中间, 0、负数、NaN 在最后。
        #expect(Set(order.prefix(2)) == [3, 7])
        #expect(Set(order.dropFirst(2).prefix(3)) == [4, 5, 9])
        #expect(Set(order.suffix(5)) == [0, 1, 2, 6, 8])
    }

    @Test("Extreme finite weights stay random instead of collapsing to input order")
    func extremeWeightsStayRandom() {
        let tiny = Array(repeating: Double.leastNonzeroMagnitude, count: 30)
        let huge = Array(repeating: Double.greatestFiniteMagnitude, count: 30)
        for weights in [tiny, huge] {
            var orders = Set<[Int]>()
            for seed in UInt64(1)...5 {
                var generator = SeededGenerator(state: seed)
                let order = WeightedShufflePolicy.shuffled(Array(weights.indices), weight: { weights[$0] }, using: &generator)
                #expect(order.sorted() == Array(weights.indices))
                orders.insert(order)
            }
            #expect(orders.count == 5)
            #expect(!orders.contains(Array(weights.indices)))
        }
    }

    @Test("Empty and single-element lists come back unchanged")
    func trivialLists() {
        var generator = SeededGenerator(state: 1)
        #expect(WeightedShufflePolicy.shuffled([Int](), weight: { _ in 1 }, using: &generator).isEmpty)
        #expect(WeightedShufflePolicy.shuffled([9], weight: { _ in .nan }, using: &generator) == [9])
    }

    @Test("Weights are finite, positive and ordered by preference")
    func weightCurve() {
        for preference in ShufflePreference.allCases {
            for plays in [-5, 0, 1, 20, Int.max] {
                let weight = WeightedShufflePolicy.weight(playCount: plays, preference: preference)
                #expect(weight.isFinite && weight > 0)
            }
            #expect(WeightedShufflePolicy.weight(playCount: 0, preference: preference) == 1)
            #expect(WeightedShufflePolicy.weight(playCount: -5, preference: preference) == 1)
        }
        #expect(WeightedShufflePolicy.weight(playCount: 20, preference: .frequentSongs) == 21)
        #expect(WeightedShufflePolicy.weight(playCount: 20, preference: .rareSongs) < WeightedShufflePolicy.weight(playCount: 1, preference: .rareSongs))
        #expect(WeightedShufflePolicy.weight(playCount: 99, preference: .frequentArtists) == 10)
        #expect(WeightedShufflePolicy.weight(playCount: 7, preference: .uniform) == 1)
    }

    @Test("Least-played first puts never-played songs ahead overall")
    func rareSongsFavorUnplayed() {
        let songs = Self.candidates(Array(repeating: 20, count: 50) + Array(repeating: 0, count: 50))
        let unplayed = Set(songs.filter { $0.serverPlayCount == 0 }.map(\.songID))
        var unplayedInFirstHalf = 0
        var meanUnplayed = 0.0
        var meanPlayed = 0.0
        for seed in UInt64(100)..<120 {
            var generator = SeededGenerator(state: seed)
            let order = WeightedShufflePolicy.shuffled(songs, preference: .rareSongs, counts: .empty, candidate: { $0 }, using: &generator)
            unplayedInFirstHalf += order.prefix(50).filter { unplayed.contains($0.songID) }.count
            meanUnplayed += Self.meanPosition(of: unplayed, in: order)
            meanPlayed += Self.meanPosition(of: Set(songs.map(\.songID)).subtracting(unplayed), in: order)
        }
        // 期望约 87% 的前一半是没听过的; 完全随机是 50%。
        #expect(Double(unplayedInFirstHalf) / (20 * 50) > 0.8)
        #expect(meanUnplayed / 20 < 35)
        #expect(meanPlayed / 20 > 64)
    }

    @Test("Most-played first leads with the most-played song")
    func frequentSongsFavorPlayed() {
        let songs = Self.candidates([100] + Array(repeating: 0, count: 99))
        var meanPosition = 0.0
        for seed in UInt64(200)..<230 {
            var generator = SeededGenerator(state: seed)
            let order = WeightedShufflePolicy.shuffled(songs, preference: .frequentSongs, counts: .empty, candidate: { $0 }, using: &generator)
            meanPosition += Double(order.firstIndex { $0.songID == "s0" } ?? 99)
        }
        #expect(meanPosition / 30 < 5)
    }

    @Test("Artist preferences weigh each song by its artist's total plays")
    func artistPreferencesUseArtistTotals() {
        // 歌手 a 每首都听过几次, b 一首也没有; 两边各 30 首。
        let songs = (0..<60).map {
            ShuffleCandidate(songID: "s\($0)", artistKey: $0 < 30 ? "a" : "b", serverPlayCount: $0 < 30 ? 2 : 0)
        }
        let counts = ShufflePlayCounts(localCounts: [:], countedSongs: songs)
        let artistA = Set((0..<30).map { "s\($0)" })
        var frequentMean = 0.0
        var rareMean = 0.0
        for seed in UInt64(300)..<320 {
            var frequent = SeededGenerator(state: seed)
            var rare = SeededGenerator(state: seed)
            frequentMean += Self.meanPosition(of: artistA, in: WeightedShufflePolicy.shuffled(
                songs, preference: .frequentArtists, counts: counts, candidate: { $0 }, using: &frequent))
            rareMean += Self.meanPosition(of: artistA, in: WeightedShufflePolicy.shuffled(
                songs, preference: .rareArtists, counts: counts, candidate: { $0 }, using: &rare))
        }
        // 完全随机时两组的平均位置都是 29.5。
        #expect(frequentMean / 20 < 22)
        #expect(rareMean / 20 > 37)
    }

    @Test("Song counts take the larger of local and server, artists add songs once")
    func playCounts() {
        let songs = [
            ShuffleCandidate(songID: "x", artistKey: "a", serverPlayCount: 5),
            ShuffleCandidate(songID: "y", artistKey: "a", serverPlayCount: nil),
            ShuffleCandidate(songID: "y", artistKey: "a", serverPlayCount: nil),
            ShuffleCandidate(songID: "z", artistKey: nil, serverPlayCount: -4),
        ]
        let counts = ShufflePlayCounts(localCounts: ["x": 3, "y": 4, "z": 6], countedSongs: songs)
        #expect(counts.songPlayCount(songs[0]) == 5)
        #expect(counts.songPlayCount(songs[1]) == 4)
        #expect(songs[3].serverPlayCount == 0)
        // x 取 5、y 取 4, 重复的 y 只算一次。
        #expect(counts.artistPlayCount(songs[0]) == 9)
        // 认不出歌手的按它自己的次数。
        #expect(counts.artistPlayCount(songs[3]) == 6)
        // 不在累计名单里的歌, 歌手次数至少是它自己的次数。
        let newcomer = ShuffleCandidate(songID: "w", artistKey: "c", serverPlayCount: 8)
        #expect(counts.artistPlayCount(newcomer) == 8)
        // 次数大到相加会溢出时封顶, 不崩。
        let overflowing = ShufflePlayCounts(localCounts: [:], countedSongs: [
            ShuffleCandidate(songID: "p", artistKey: "a", serverPlayCount: .max),
            ShuffleCandidate(songID: "q", artistKey: "a", serverPlayCount: .max),
        ])
        #expect(overflowing.artistPlayCount(newcomer.withArtist("a")) == .max)
    }

    @Test("Placeholder and missing artists are not an artist")
    func artistKeys() {
        var resolver = ShuffleArtistKeyResolver()
        #expect(resolver.artistKey(artistName: "Various Artists", artistID: "va") == nil)
        #expect(resolver.artistKey(artistName: "群星", artistID: "qx") == nil)
        #expect(resolver.artistKey(artistName: "  ", artistID: "blank") == nil)
        #expect(resolver.artistKey(artistName: "Adele", artistID: nil) == nil)
        #expect(resolver.artistKey(artistName: "Adele", artistID: "") == nil)
        #expect(resolver.artistKey(artistName: "Adele", artistID: "adele-id") == "adele-id")
        #expect(resolver.artistKey(artistName: "Adele", artistID: "adele-id") == "adele-id")
    }
}

private extension ShuffleCandidate {
    func withArtist(_ key: String) -> ShuffleCandidate {
        ShuffleCandidate(songID: songID, artistKey: key, serverPlayCount: serverPlayCount)
    }
}
