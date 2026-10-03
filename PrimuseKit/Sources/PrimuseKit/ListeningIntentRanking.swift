import Foundation

// MARK: - Usage

/// When the listener started which intent, and in what situation of the day.
/// Kept on this device; the ranking learns from it ("jazz in the evening").
public struct ListeningIntentUsage: Codable, Equatable, Sendable {
    public struct Start: Codable, Equatable, Sendable {
        public var at: Date
        public var situation: ListeningSituation

        public init(at: Date, situation: ListeningSituation) {
            self.at = at
            self.situation = situation
        }
    }

    public static let storageKey = "primuse.listeningIntents.usage.v1"
    /// Older starts no longer say much about what someone likes now.
    public static let keptDays = 60
    public static let perIntentLimit = 30

    public private(set) var starts: [String: [Start]]

    public init(starts: [String: [Start]] = [:]) {
        self.starts = starts
    }

    public mutating func record(_ intentID: String, at date: Date, situation: ListeningSituation) {
        var list = starts[intentID] ?? []
        list.append(Start(at: date, situation: situation))
        if list.count > Self.perIntentLimit { list.removeFirst(list.count - Self.perIntentLimit) }
        starts[intentID] = list
        prune(now: date)
    }

    public mutating func prune(now: Date) {
        let since = now.addingTimeInterval(-Double(Self.keptDays) * 86_400)
        starts = starts.compactMapValues { list in
            // Only age drops a start; a clock set back must not wipe recent ones.
            let kept = list.filter { $0.at >= since }
            return kept.isEmpty ? nil : kept
        }
    }

    public func starts(of intentID: String) -> [Start] { starts[intentID] ?? [] }

    public static func decode(_ data: Data?) -> ListeningIntentUsage {
        guard let data, let decoded = try? JSONDecoder().decode(ListeningIntentUsage.self, from: data) else {
            return ListeningIntentUsage()
        }
        return decoded
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

// MARK: - Ranking

/// Orders the shelf's suggestions the way a person would: what this listener
/// actually plays (the lighting score), what suits this moment of the day,
/// what they tend to start from the shelf (especially at this time of day),
/// not the one they just played, a little variety from day to day, and not
/// four cards of the same kind in a row.
public enum ListeningIntentRankingPolicy {
    /// How far the moment of the day can lift or sink an intent.
    static let contextWeight = 0.22
    /// The most a listener's own habit of starting an intent adds.
    static let usageCap = 0.24
    /// Played from the shelf a moment ago: show something else first.
    static let recentlyStartedPenalty = 0.12
    static let recentlyStartedWindow: TimeInterval = 2 * 3_600
    /// Day-to-day variety; small enough never to outvote a real preference.
    static let dailyJitter = 0.04
    /// Each card of the same kind already placed costs the next one this much.
    static let samenessPenalty = 0.1

    public static func rank(
        _ intents: [ListeningIntent],
        availability: ListeningIntentAvailability,
        moment: ListeningMoment,
        usage: ListeningIntentUsage,
        now: Date
    ) -> [ListeningIntent] {
        var pool: [(intent: ListeningIntent, score: Double, group: String, offset: Int)] = intents
            .enumerated()
            .map { offset, intent in
                (intent, adjustedScore(intent, availability: availability, moment: moment, usage: usage, now: now), group(of: intent), offset)
            }
        var ranked: [ListeningIntent] = []
        var placed: [String: Int] = [:]
        while !pool.isEmpty {
            var best = 0
            var bestValue = -Double.infinity
            for (index, entry) in pool.enumerated() {
                let value = entry.score - samenessPenalty * Double(placed[entry.group] ?? 0)
                if value > bestValue + 1e-12
                    || (abs(value - bestValue) <= 1e-12 && entry.offset < pool[best].offset) {
                    best = index
                    bestValue = value
                }
            }
            let chosen = pool.remove(at: best)
            ranked.append(chosen.intent)
            placed[chosen.group, default: 0] += 1
        }
        return ranked
    }

    static func adjustedScore(
        _ intent: ListeningIntent,
        availability: ListeningIntentAvailability,
        moment: ListeningMoment,
        usage: ListeningIntentUsage,
        now: Date
    ) -> Double {
        var score = availability.score(for: intent)
        score += contextWeight * contextAffinity(intent, situation: moment.situation, isWeekend: moment.isWeekend)
        score += usageBoost(usage.starts(of: intent.id), situation: moment.situation, now: now)
        let jitterSeed = "\(moment.dayStamp)-\(moment.situation.rawValue)-\(intent.id)"
        score += dailyJitter * ListeningSeededGenerator.unitNoise(jitterSeed)
        return score
    }

    /// -1...1: how well the intent suits this moment.
    static func contextAffinity(_ intent: ListeningIntent, situation: ListeningSituation, isWeekend: Bool) -> Double {
        if case .builtIn(let builtIn) = intent.source {
            switch builtIn {
            case .bedtime:
                switch situation {
                case .bedtime: return 1
                case .lateNight: return 0.9
                case .tonight: return 0.2
                case .morning, .commute, .workday: return -0.8
                case .weekendAfternoon: return -0.4
                }
            case .focus:
                switch situation {
                case .workday: return 1
                case .morning: return 0.3
                case .weekendAfternoon: return 0.1
                case .bedtime, .lateNight: return -0.5
                case .commute, .tonight: return -0.2
                }
            case .workout:
                switch situation {
                case .commute: return 0.8
                case .morning: return 0.6
                case .weekendAfternoon: return 0.4
                case .tonight, .workday: return -0.1
                case .bedtime, .lateNight: return -1
                }
            case .calm:
                switch situation {
                case .bedtime, .lateNight: return 0.7
                case .tonight: return 0.5
                case .morning: return 0.3
                case .workday: return 0.2
                case .commute, .weekendAfternoon: return 0
                }
            case .newlyAdded:
                return isWeekend ? 0.3 : 0.1
            case .longUnplayed:
                return situation == .weekendAfternoon ? 0.4 : 0
            case .resume, .anything:
                return 0
            default:
                break
            }
        }
        if case .personal(let personalID) = intent.source, personalID == "rotation" {
            return situation == .commute || situation == .morning ? 0.3 : 0.1
        }
        // Genre-led intents (and personal ones that carry genres) follow the
        // same family weights the album pick of the moment uses.
        guard let families = intent.rule?.genreFamilies, !families.isEmpty else { return 0 }
        let weights = situation.familyWeights
        let average = families.reduce(0.0) { $0 + (weights[$1] ?? 0) } / Double(families.count)
        return max(-1, min(1, average / 10))
    }

    /// Starts in the last two months, counted more when they happened at this
    /// moment of the day; the one started in the last couple of hours drops.
    static func usageBoost(_ starts: [ListeningIntentUsage.Start], situation: ListeningSituation, now: Date) -> Double {
        guard !starts.isEmpty else { return 0 }
        let since = now.addingTimeInterval(-Double(ListeningIntentUsage.keptDays) * 86_400)
        var weighted = 0.0
        var justPlayed = false
        for start in starts where start.at >= since && start.at <= now {
            // A start from a week ago counts half as much as one today.
            let ageDays = now.timeIntervalSince(start.at) / 86_400
            let decay = pow(0.5, ageDays / 7)
            weighted += decay * (start.situation == situation ? 2 : 1)
            if now.timeIntervalSince(start.at) < recentlyStartedWindow { justPlayed = true }
        }
        // Just played from the shelf: it steps aside whatever its habit says.
        if justPlayed { return -recentlyStartedPenalty }
        return min(usageCap, 0.08 * log2(1 + weighted))
    }

    /// Cards of one kind: the decades are one kind, genres another, and so on;
    /// each personal kind (artists, folders, …) is its own.
    static func group(of intent: ListeningIntent) -> String {
        switch intent.source {
        case .builtIn(let builtIn):
            return "builtin:" + builtIn.category.rawValue
        case .personal(let personalID):
            let kind = personalID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? personalID
            return "personal:" + kind
        case .smartPlaylist:
            return "smart"
        case .scene:
            return "scene"
        }
    }
}
