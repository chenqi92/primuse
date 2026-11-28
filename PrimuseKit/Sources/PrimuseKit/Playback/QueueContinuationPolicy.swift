import Foundation

/// What happens once a music queue has nothing left to play (issue #166).
///
/// A Siri, CarPlay or search request often installs a single song; without a
/// rule the music simply stops after it. With "keep playing similar songs" on,
/// the queue is topped up from the songs most like the last few it played, and
/// those songs sit under an "autoplay" divider in Up Next so a listener can
/// tell them from what they queued themselves.
///
/// Every decision here is a pure function of the player's state, so the iOS /
/// macOS / CarPlay player (`AudioPlayerService`) and the Apple TV player
/// (`TVStore`) follow the same rules.
public enum QueueContinuationPolicy {
    /// Songs at the end of the queue the similar songs are measured against.
    public static let seedCount = 3
    /// Songs added per top-up. When they run out the next top-up seeds from them.
    public static let batchSize = 20
    /// Songs a Siri request for one song gets after it, right away, so the
    /// CarPlay "Up Next" list is not empty while the first song plays.
    public static let siriSimilarCount = 20

    public enum Decision: Equatable, Sendable {
        /// Leave the queue alone: it still has songs, repeats, or is not music.
        case none
        /// Shuffle is on: the existing "continue shuffling from the library"
        /// path tops the queue up with random library songs.
        case shuffleFromLibrary
        /// Top the queue up with songs similar to its last few.
        case similarSongs
    }

    /// - Parameters:
    ///   - isEnabled: the "keep playing similar songs" setting.
    ///   - hasUpcomingSongs: the queue still has a song after the current one.
    ///   - hasPendingRequestSongs: a large request still owes songs to the
    ///     queue window (`QueueContinuation`); those come first.
    ///   - shuffleExtendsFromLibrary: the player has its own "keep shuffling"
    ///     path. The Apple TV player does not, so shuffle there falls through
    ///     to similar songs too.
    public static func decision(
        isEnabled: Bool,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool,
        space: ListeningSpace?,
        isMedley: Bool,
        isLiveRadio: Bool,
        hasUpcomingSongs: Bool,
        hasPendingRequestSongs: Bool,
        shuffleExtendsFromLibrary: Bool = true
    ) -> Decision {
        guard !hasUpcomingSongs, !hasPendingRequestSongs, repeatMode == .off,
              !isMedley, !isLiveRadio,
              ShuffleLibraryContinuationPolicy.continuesFromLibrary(currentSpace: space) else {
            return .none
        }
        if shuffleEnabled, shuffleExtendsFromLibrary { return .shuffleFromLibrary }
        return isEnabled ? .similarSongs : .none
    }

    /// The last `count` distinct songs of the queue up to and including the
    /// current one, most recent first.
    public static func seedIDs(queueIDs: [String], currentIndex: Int, count: Int = seedCount) -> [String] {
        guard count > 0, queueIDs.indices.contains(currentIndex) else { return [] }
        var seeds: [String] = []
        var seen = Set<String>()
        var index = currentIndex
        while index >= 0, seeds.count < count {
            let id = queueIDs[index]
            if !id.isEmpty, seen.insert(id).inserted { seeds.append(id) }
            index -= 1
        }
        return seeds
    }

    /// One seed's best `keep` candidates while the library is scanned in list
    /// order (position = index in the music list). Ties are common (same genre,
    /// similar length); a per-seed salt breaks them differently each time
    /// instead of by library order. The whole-table scan and the catalog stream
    /// both rank through this, so the same rows in the same order give the same
    /// list.
    public struct SeedRanking: Sendable {
        public let seedID: String
        public let keep: Int
        private let salt: UInt64
        public private(set) var entries: [Entry] = []

        public struct Entry: Sendable {
            public let score: Double
            public let position: Int
        }

        public init(seedID: String, keep: Int) {
            self.seedID = seedID
            self.keep = keep
            salt = UInt64(truncatingIfNeeded: seedID.hashValue)
            entries.reserveCapacity(keep + 1)
        }

        public func jitter(at position: Int) -> Double {
            var mixed = (UInt64(position) &+ salt) &* 0x9E37_79B9_7F4A_7C15
            mixed ^= mixed >> 29
            return Double(mixed % 1_000) / 1_000
        }

        /// Only songs that can still make the list pay for the string lookups.
        public func mayEnter(matchScore: Double, jitter: Double) -> Bool {
            !(entries.count == keep && matchScore + 4 + jitter <= entries[keep - 1].score)
        }

        /// Scores the candidate (`matchScore` > 0, playable) and keeps it when it
        /// ranks among the best `keep`. The seed itself and `excluded` never enter;
        /// not having played recently is worth 4.
        public mutating func offer(
            id: String, matchScore: Double, jitter: Double, position: Int,
            recentIDs: Set<String>, excluded: Set<String>
        ) {
            guard keep > 0, id != seedID, !excluded.contains(id) else { return }
            let score = matchScore + (recentIDs.contains(id) ? 0 : 4) + jitter
            if entries.count == keep, score <= entries[keep - 1].score { return }
            var low = 0
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].score >= score { low = middle + 1 } else { high = middle }
            }
            entries.insert(Entry(score: score, position: position), at: low)
            if entries.count > keep { entries.removeLast() }
        }
    }

    /// At most `maximum` songs per group (album, artist) in one top-up, so the
    /// songs after a single track are not just the rest of its album.
    public struct GroupLimit {
        public let maximum: Int
        public let key: (String) -> String?

        public init(maximum: Int, key: @escaping (String) -> String?) {
            self.maximum = maximum
            self.key = key
        }
    }

    /// Interleaves the per-seed rankings (best first) so every seed is heard,
    /// skipping songs already queued or just played and any repeat. Group
    /// limits apply first; if they leave the batch short, the best of what
    /// they held back fills it.
    public static func merge(
        rankedBySeed: [[String]],
        excluding excluded: Set<String>,
        limit: Int = batchSize,
        groupLimits: [GroupLimit] = []
    ) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var seen = excluded
        var heldBack: [String] = []
        var groupCounts = Array(repeating: [String: Int](), count: groupLimits.count)
        var cursors = Array(repeating: 0, count: rankedBySeed.count)
        var progressed = true
        while result.count < limit, progressed {
            progressed = false
            for seed in rankedBySeed.indices {
                let list = rankedBySeed[seed]
                while cursors[seed] < list.count {
                    let id = list[cursors[seed]]
                    cursors[seed] += 1
                    guard !id.isEmpty, seen.insert(id).inserted else { continue }
                    let keys = groupLimits.map { $0.key(id) }
                    let overLimit = groupLimits.indices.contains { index in
                        guard let key = keys[index] else { return false }
                        return groupCounts[index][key, default: 0] >= groupLimits[index].maximum
                    }
                    if overLimit {
                        heldBack.append(id)
                        continue
                    }
                    for index in groupLimits.indices {
                        if let key = keys[index] { groupCounts[index][key, default: 0] += 1 }
                    }
                    result.append(id)
                    progressed = true
                    break
                }
                if result.count == limit { break }
            }
        }
        if result.count < limit {
            result.append(contentsOf: heldBack.prefix(limit - result.count))
        }
        return result
    }

    /// Where a song the listener adds "to the end of the queue" goes: before
    /// the autoplay songs, so their own choice plays first. Nil means the end.
    /// - Parameter isAutoplay: whether the queue entry at an index was added
    ///   by this policy.
    public static func insertionIndexBeforeAutoplay(
        queueCount: Int,
        currentIndex: Int,
        isAutoplay: (Int) -> Bool
    ) -> Int? {
        guard queueCount > 0 else { return nil }
        var index = max(0, currentIndex + 1)
        while index < queueCount {
            if isAutoplay(index) { return index }
            index += 1
        }
        return nil
    }

    /// Splits Up Next into what the listener queued and the autoplay songs
    /// after it. Autoplay songs are always appended at the end, so the first
    /// one found starts the autoplay part.
    public static func splitUpcoming<Item>(
        _ upcoming: [Item],
        isAutoplay: (Item) -> Bool
    ) -> (queued: [Item], autoplay: [Item]) {
        guard let start = upcoming.firstIndex(where: isAutoplay) else { return (upcoming, []) }
        return (Array(upcoming[..<start]), Array(upcoming[start...]))
    }
}
