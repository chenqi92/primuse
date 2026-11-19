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
        var years = SongsByReleaseYear<Int>()
        for index in songs.indices { years.append(index, year: songs[index].year) }
        return years.window(for: self, minimumCount: minimumCount).map { songs[$0] }
    }
}

private struct SongsByReleaseYear<Element> {
    var dated: [Int: [Element]] = [:]
    var undated: [Element] = []
    var datedCount = 0

    mutating func append(_ element: Element, year: Int?) {
        guard let year, year > 0 else { undated.append(element); return }
        dated[year, default: []].append(element)
        datedCount += 1
    }

    func window(for theme: HomeHeroRecommendationTheme, minimumCount: Int) -> [Element] {
        guard datedCount > 0 else { return undated }
        let count = min(datedCount, max(minimumCount, (datedCount + 1) / 2))
        let years = dated.keys.sorted(by: theme == .catalogRewind ? (<) : (>))
        var result: [Element] = []
        result.reserveCapacity(count + min(undated.count, max(0, minimumCount - count)))
        for year in years {
            guard result.count < count else { break }
            if let group = dated[year] { result.append(contentsOf: group.prefix(count - result.count)) }
        }
        result.append(contentsOf: undated.prefix(max(0, minimumCount - count)))
        return result
    }
}

public enum HomeHeroRecommendationPolicy {
    public static let contentKey = "primuse.home.heroContent.v1"
    public static let songCountKey = "primuse.home.heroSongCount.v1"
    public static let albumCountKey = "primuse.home.heroAlbumCount.v1"
    public static let defaultSongCount = 24
    public static let defaultAlbumCount = 6
    public static let rankedSongLimit = 200

    public static func songCount(_ value: Int) -> Int { min(50, max(1, value)) }
    public static func albumCount(_ value: Int) -> Int { min(12, max(1, value)) }

    public static func dayStamp(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    /// Keep positions into the two input snapshots until the final selection, including for tied years.
    public static func songCandidates(
        ranked: [Song], librarySongs: [Song], excludedSongIDs: Set<String>,
        theme: HomeHeroRecommendationTheme, minimumCount: Int, day: Int, round: Int,
        previous: Set<String>, isCancelled: () -> Bool = { false }
    ) -> [Song] {
        guard !isCancelled() else { return [] }
        func song(at position: Int) -> Song {
            position < ranked.count ? ranked[position] : librarySongs[position - ranked.count]
        }
        var pool = Array(ranked.indices)
        var years = SongsByReleaseYear<Int>()
        if theme != .daily {
            for index in ranked.indices { years.append(index, year: ranked[index].year) }
        }
        if theme != .daily || pool.count < AIRecommendationRequest.maximumCandidates {
            var seen = Set(ranked.map(\.id))
            for (index, song) in librarySongs.enumerated() {
                if index.isMultiple(of: 512), isCancelled() { return [] }
                guard song.isPlayable, !excludedSongIDs.contains(song.id) else { continue }
                if theme == .daily {
                    if seen.insert(song.id).inserted { pool.append(ranked.count + index) }
                    if pool.count >= rankedSongLimit { break }
                } else if let year = song.year, year > 0, seen.insert(song.id).inserted {
                    years.append(ranked.count + index, year: year)
                }
            }
        }
        guard !isCancelled() else { return [] }
        if theme != .daily { pool = years.window(for: theme, minimumCount: minimumCount) }
        let maximum = AIRecommendationRequest.maximumCandidates
        let freshCount = pool.lazy.filter { !previous.contains(song(at: $0).id) }.prefix(maximum).count
        let selected = candidates(in: pool, day: day + theme.rotationOffset, round: round, excluding: previous,
                                  limit: min(maximum, max(minimumCount, freshCount)), id: { song(at: $0).id })
        return isCancelled() ? [] : selected.map(song(at:))
    }

    /// Preserve the recommendation engine's ranking within a rotating window,
    /// preferring items that were absent from the previous batch.
    public static func candidates(
        rankedIDs: [String], day: Int, round: Int, excluding previous: Set<String>, limit: Int
    ) -> [String] {
        candidates(in: rankedIDs, day: day, round: round, excluding: previous, limit: limit, id: { $0 })
    }

    private static func candidates<Element>(
        in ranked: [Element], day: Int, round: Int, excluding previous: Set<String>, limit: Int, id: (Element) -> String
    ) -> [Element] {
        var seen = Set<String>()
        let unique = ranked.filter {
            let key = id($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
        guard !unique.isEmpty, limit > 0 else { return [] }
        let offset = Int((UInt64(max(0, day)) &* 7 &+ UInt64(max(0, round)) &* 31) % UInt64(unique.count))
        var fresh: [Element] = []
        var repeats: [Element] = []
        for index in unique.indices {
            let item = unique[(offset + index) % unique.count]
            if previous.contains(id(item)) {
                if repeats.count < limit { repeats.append(item) }
            } else {
                fresh.append(item)
                if fresh.count == limit { return fresh }
            }
        }
        return fresh + repeats.prefix(limit - fresh.count)
    }

    public static func merged(preferred: [String], fallback: [String], limit: Int) -> [String] {
        let allowed = Set(fallback)
        var seen = Set<String>()
        return Array((preferred + fallback).filter {
            allowed.contains($0) && seen.insert($0).inserted
        }.prefix(max(0, limit)))
    }
}
