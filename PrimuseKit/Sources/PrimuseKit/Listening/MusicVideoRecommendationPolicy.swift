import Foundation

/// 首页「MV」一排、智能推荐里那一排 MV 挑哪几支。
///
/// 常听的艺人排前面,新加进来的往前提一点,最近刚看过的排到最后;同分时按天轮换,
/// 每天打开不是同一排。同一位艺人前面最多连着出两支,其余的排到后面,一排不会被一个人占满。
public enum MusicVideoRecommendationPolicy {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let artistID: String?
        public let dateAdded: Date

        public init(id: String, artistID: String?, dateAdded: Date) {
            self.id = id
            self.artistID = artistID
            self.dateAdded = dateAdded
        }
    }

    public struct Request: Equatable, Sendable {
        private let catalogRevision: UInt64
        private let favoriteArtistIDs: [String]
        private let recentlyPlayedIDs: Set<String>
        private let day: Int
        private let limit: Int

        public init(catalogRevision: UInt64, favoriteArtistIDs: [String], recentlyPlayedIDs: Set<String>,
                    day: Int, limit: Int) {
            self.catalogRevision = catalogRevision
            self.favoriteArtistIDs = favoriteArtistIDs
            self.recentlyPlayedIDs = recentlyPlayedIDs
            self.day = day
            self.limit = limit
        }

        @concurrent
        public func picks(from songs: [Song], now: Date) async -> [Song] {
            guard limit > 0, !songs.isEmpty, !Task.isCancelled else { return [] }
            let ids = pickIDs(
                from: songs.map { Candidate(id: $0.id, artistID: $0.artistID, dateAdded: $0.dateAdded) }, now: now
            )
            var missing = Set(ids)
            var picksByID: [String: Song] = [:]
            for song in songs where missing.remove(song.id) != nil {
                picksByID[song.id] = song
                if missing.isEmpty { break }
            }
            return ids.compactMap { picksByID[$0] }
        }

        /// 只按候选(id、艺人、加入时间)挑,给不在内存里的整份 MV 用(候选从曲库目录读,挑中的再按 id 取歌)。
        /// 候选的先后与 `picks(from:)` 交的歌一样(`musicVideoSongs` 的先后)时结果相同。
        public func pickIDs(from candidates: [Candidate], now: Date) -> [String] {
            guard limit > 0, !candidates.isEmpty else { return [] }
            return MusicVideoRecommendationPolicy.recommended(
                candidates, favoriteArtistIDs: favoriteArtistIDs, recentlyPlayedIDs: recentlyPlayedIDs,
                now: now, day: day, limit: limit
            )
        }
    }

    /// 同一位艺人在前面最多出几支。
    public static let perArtistLimit = 2
    /// 加进来多少天以内算新的。
    public static let freshnessWindow: TimeInterval = 30 * 86_400

    /// - Parameters:
    ///   - favoriteArtistIDs: 常听的艺人,越靠前越常听。
    ///   - recentlyPlayedIDs: 最近放过的歌(含 MV),往后放,换点没看过的。
    ///   - day: 第几天(`HomeHeroRecommendationPolicy.dayStamp` 那种),同分时按它轮换。
    public static func recommended(
        _ candidates: [Candidate],
        favoriteArtistIDs: [String],
        recentlyPlayedIDs: Set<String>,
        now: Date,
        day: Int,
        limit: Int
    ) -> [String] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        var affinity: [String: Double] = [:]
        var seenArtists: Set<String> = []
        let favorites = favoriteArtistIDs.filter { seenArtists.insert($0).inserted }
        for (index, id) in favorites.enumerated() {
            affinity[id] = 1 + 3 * (1 - Double(index) / Double(max(favorites.count, 1)))
        }

        var scored = candidates.map { candidate -> (candidate: Candidate, score: Double) in
            var score = candidate.artistID.flatMap { affinity[$0] } ?? 0
            let age = now.timeIntervalSince(candidate.dateAdded)
            if age >= 0, age < freshnessWindow {
                score += 1.5 * (1 - age / freshnessWindow)
            }
            // 刚看过的排到所有没看过的后面。
            if recentlyPlayedIDs.contains(candidate.id) {
                score -= 7
            }
            score += jitter(id: candidate.id, day: day)
            return (candidate, score)
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.id < rhs.candidate.id
        }

        var picked: [String] = []
        var deferred: [String] = []
        var perArtist: [String: Int] = [:]
        for (candidate, _) in scored {
            let key = candidate.artistID ?? "id:" + candidate.id
            let count = perArtist[key, default: 0]
            if count < perArtistLimit {
                perArtist[key] = count + 1
                picked.append(candidate.id)
            } else {
                deferred.append(candidate.id)
            }
            if picked.count == limit { return picked }
        }
        return Array((picked + deferred).prefix(limit))
    }

    /// 0..<0.9 的稳定扰动:同一天同一支每次一样,换一天换个次序。
    static func jitter(id: String, day: Int) -> Double {
        var value: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(day)|\(id)".utf8 {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Double(value % 900) / 1000
    }
}
