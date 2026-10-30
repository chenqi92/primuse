import Foundation

public enum HomeHeroRecommendationContent: String, CaseIterable, Sendable {
    case albums
    case songs
}

public enum HomeHeroRecommendationTheme: String, CaseIterable, Hashable, Sendable {
    case daily
    case catalogRewind
    case recentCatalog

    public var intent: String? {
        switch self {
        case .daily: nil
        case .catalogRewind: AIRecommendationIntentPreset.catalogRewind.semanticIntent
        case .recentCatalog: AIRecommendationIntentPreset.recentCatalog.semanticIntent
        }
    }

    public var rotationOffset: Int {
        switch self {
        case .daily: 0
        case .catalogRewind: 17
        case .recentCatalog: 43
        }
    }

    public func candidatePool(from songs: [Song], minimumCount: Int) -> [Song] {
        guard self != .daily else { return songs }
        let dated = songs.enumerated().filter { ($0.element.year ?? 0) > 0 }.sorted {
            let lhs = $0.element.year ?? 0
            let rhs = $1.element.year ?? 0
            if lhs == rhs { return $0.offset < $1.offset }
            return self == .catalogRewind ? lhs < rhs : lhs > rhs
        }.map(\.element)
        guard !dated.isEmpty else { return songs }
        let windowSize = max(minimumCount, (dated.count + 1) / 2)
        let preferred = Array(dated.prefix(windowSize))
        let missingYear = songs.filter { ($0.year ?? 0) <= 0 }
        return preferred + missingYear.prefix(max(0, minimumCount - preferred.count))
    }
}

public enum HomeHeroRecommendationPolicy {
    public static let contentKey = "primuse.home.heroContent.v1"
    public static let songCountKey = "primuse.home.heroSongCount.v1"
    public static let albumCountKey = "primuse.home.heroAlbumCount.v1"
    public static let defaultSongCount = 24
    public static let defaultAlbumCount = 6

    public static func songCount(_ value: Int) -> Int { min(50, max(1, value)) }
    public static func albumCount(_ value: Int) -> Int { min(12, max(1, value)) }

    public static func dayStamp(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    /// Preserve the recommendation engine's ranking within a rotating window,
    /// preferring items that were absent from the previous batch.
    public static func candidates(
        rankedIDs: [String], day: Int, round: Int, excluding previous: Set<String>, limit: Int
    ) -> [String] {
        var seen = Set<String>()
        let unique = rankedIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty, limit > 0 else { return [] }
        let offset = Int((UInt64(max(0, day)) &* 7 &+ UInt64(max(0, round)) &* 31) % UInt64(unique.count))
        let rotated = Array(unique[offset...] + unique[..<offset])
        return Array((rotated.filter { !previous.contains($0) } + rotated.filter { previous.contains($0) }).prefix(limit))
    }

    public static func merged(preferred: [String], fallback: [String], limit: Int) -> [String] {
        let allowed = Set(fallback)
        var seen = Set<String>()
        return Array((preferred + fallback).filter {
            allowed.contains($0) && seen.insert($0).inserted
        }.prefix(max(0, limit)))
    }
}
