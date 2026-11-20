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
        let favorites = favoriteArtistIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        for (index, id) in favorites.enumerated() {
            affinity[id] = 1 + 3 * (1 - Double(index) / Double(max(favorites.count, 1)))
        }

        let scored = candidates.map { candidate -> (Candidate, Double) in
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
        .sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.id < rhs.0.id
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
