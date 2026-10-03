import Foundation

// MARK: - The moment

/// The listening situation a moment of the week suggests. Drives the title of
/// the album pick ("On your commute", "Weekend afternoon", "Before bed") and
/// which kinds of albums it leans towards.
public enum ListeningSituation: String, CaseIterable, Codable, Hashable, Sendable {
    case morning
    case commute
    case workday
    case weekendAfternoon
    case tonight
    case bedtime
    case lateNight

    /// Localization key of the section title, e.g. `album_pick_title_tonight`.
    public var titleKey: String { "album_pick_title_" + rawValue }

    /// How much this situation likes each family (added to an album's score).
    public var familyWeights: [ListeningGenreFamily: Double] {
        switch self {
        case .morning:
            [.folk: 6, .jazz: 5, .easyListening: 5, .pop: 4, .classical: 3, .hipHop: -2, .electronic: -2]
        case .commute:
            [.pop: 6, .rock: 5, .electronic: 4, .hipHop: 4, .soundtrack: 2]
        case .workday:
            [.easyListening: 8, .classical: 8, .soundtrack: 6, .jazz: 4, .hipHop: -4]
        case .weekendAfternoon:
            [.jazz: 6, .folk: 6, .pop: 4, .soundtrack: 3, .easyListening: 3]
        case .tonight:
            [.jazz: 6, .pop: 3, .rock: 3, .folk: 3, .easyListening: 3, .electronic: 2]
        case .bedtime:
            [.easyListening: 10, .classical: 10, .jazz: 8, .folk: 7, .rock: -12, .electronic: -10, .hipHop: -12]
        case .lateNight:
            [.easyListening: 10, .classical: 7, .jazz: 6, .electronic: 2, .rock: -6, .hipHop: -6]
        }
    }

    /// Album length this situation suits, in minutes (nil: no preference).
    public var preferredMinutes: ClosedRange<Double>? {
        switch self {
        case .commute: 20...50
        case .weekendAfternoon, .tonight: 40...100
        case .workday: 35...120
        default: nil
        }
    }
}

/// Days worth a mention. Chinese festivals follow the lunar calendar.
public enum ListeningHoliday: String, CaseIterable, Codable, Hashable, Sendable {
    case newYear
    case springFestival
    case lanternFestival
    case valentines
    case dragonBoat
    case qixi
    case midAutumn
    case halloween
    case christmas

    public var titleKey: String { "album_pick_title_holiday_" + rawValue }

    /// Folded words that make an album title fit the day.
    var titleWords: [String] {
        switch self {
        case .christmas: ["christmas", "xmas", "noel", "navidad", "weihnacht"] + ListeningHolidayTerms.christmas
        case .newYear, .springFestival, .lanternFestival: ["new year"] + ListeningHolidayTerms.newYear
        case .midAutumn: ["moon"] + ListeningHolidayTerms.midAutumn
        case .halloween: ["halloween"] + ListeningHolidayTerms.halloween
        case .valentines, .qixi: ["valentine"] + ListeningHolidayTerms.love
        case .dragonBoat: []
        }
    }

    var isLunar: Bool {
        switch self {
        case .springFestival, .lanternFestival, .dragonBoat, .qixi, .midAutumn: true
        default: false
        }
    }
}

/// Now, as far as listening goes: the situation, any holiday, and how long
/// that holds. Picks are stable within one moment and change with it.
public struct ListeningMoment: Equatable, Hashable, Sendable {
    public let situation: ListeningSituation
    public let holiday: ListeningHoliday?
    public let isWeekend: Bool
    /// yyyymmdd in the calendar's time zone.
    public let dayStamp: Int
    /// When the next moment starts.
    public let validUntil: Date

    public init(situation: ListeningSituation, holiday: ListeningHoliday?, isWeekend: Bool, dayStamp: Int, validUntil: Date) {
        self.situation = situation
        self.holiday = holiday
        self.isWeekend = isWeekend
        self.dayStamp = dayStamp
        self.validUntil = validUntil
    }

    /// The section title. A holiday names the day, except around bedtime.
    public var titleKey: String {
        if let holiday, situation != .bedtime, situation != .lateNight { return holiday.titleKey }
        return situation.titleKey
    }

    /// Picks change when this changes.
    public var seedKey: String { "\(dayStamp)-\(situation.rawValue)-\(holiday?.rawValue ?? "-")" }

    /// - Parameter observesLunarFestivals: Chinese festivals only for
    ///   listeners who would expect them (Chinese locale or region).
    public static func resolve(
        at now: Date,
        calendar: Calendar = Calendar.current,
        observesLunarFestivals: Bool = true
    ) -> ListeningMoment {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let weekend = calendar.isDateInWeekend(now)
        let segments = Self.segments(weekend: weekend)
        var situation = segments[0].situation
        var nextStart: Int?
        for (index, segment) in segments.enumerated() where segment.start <= minute {
            situation = segment.situation
            nextStart = index + 1 < segments.count ? segments[index + 1].start : nil
        }
        let startOfDay = calendar.startOfDay(for: now)
        let validUntil: Date
        if let nextStart {
            validUntil = calendar.date(byAdding: .minute, value: nextStart, to: startOfDay)
                ?? now.addingTimeInterval(3_600)
        } else {
            validUntil = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                ?? now.addingTimeInterval(3_600)
        }
        let dayStamp = (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
        return ListeningMoment(
            situation: situation,
            holiday: holiday(on: now, calendar: calendar, observesLunarFestivals: observesLunarFestivals),
            isWeekend: weekend,
            dayStamp: dayStamp,
            validUntil: validUntil
        )
    }

    /// Minute of the day each situation starts at.
    static func segments(weekend: Bool) -> [(start: Int, situation: ListeningSituation)] {
        if weekend {
            return [
                (0, .lateNight), (5 * 60, .morning), (12 * 60, .weekendAfternoon),
                (18 * 60, .tonight), (22 * 60, .bedtime),
            ]
        }
        return [
            (0, .lateNight), (5 * 60, .morning), (7 * 60, .commute), (9 * 60 + 30, .workday),
            (17 * 60 + 30, .commute), (19 * 60 + 30, .tonight), (22 * 60, .bedtime),
        ]
    }

    public static func holiday(
        on date: Date,
        calendar: Calendar,
        observesLunarFestivals: Bool
    ) -> ListeningHoliday? {
        let components = calendar.dateComponents([.month, .day], from: date)
        switch (components.month, components.day) {
        case (1, 1), (12, 31): return .newYear
        case (2, 14): return .valentines
        case (10, 31): return .halloween
        case (12, 24), (12, 25): return .christmas
        default: break
        }
        guard observesLunarFestivals else { return nil }
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        func lunarDay(_ date: Date) -> (month: Int, day: Int)? {
            let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
            guard parts.isLeapMonth != true, let month = parts.month, let day = parts.day else { return nil }
            return (month, day)
        }
        if let today = lunarDay(date) {
            switch (today.month, today.day) {
            case (1, 1): return .springFestival
            case (1, 15): return .lanternFestival
            case (5, 5): return .dragonBoat
            case (7, 7): return .qixi
            case (8, 15): return .midAutumn
            default: break
            }
        }
        // New Year's Eve of the lunar calendar: tomorrow is the first day.
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
           let next = lunarDay(tomorrow), next.month == 1, next.day == 1 {
            return .springFestival
        }
        return nil
    }
}

// MARK: - Candidates

/// One album as the recommender sees it, aggregated from its songs.
public struct AlbumCandidate: Equatable, Sendable {
    public let albumID: String
    public let title: String
    public let artistName: String
    /// Folded album artist and track artists, for matching play history.
    public let artistKeys: [String]
    public let year: Int?
    public let trackCount: Int
    public let totalDuration: TimeInterval
    public let families: Set<ListeningGenreFamily>
    public let latestAdded: Date
    public let isCueAlbum: Bool
    /// A track with a cover, for the card's artwork.
    public let artworkSongID: String?

    public var primaryArtistKey: String { artistKeys.first ?? ListeningTextKey.folded(artistName) }
}

/// Whole albums worth recommending, built in one pass over the music library.
/// Build it off the main actor and keep it until the library changes.
public struct AlbumCandidateIndex: Sendable {
    /// A "complete album": at least this many tracks, or a CUE image split
    /// into at least two.
    public static let minimumTrackCount = 4
    public static let minimumCueTrackCount = 2

    public let candidates: [AlbumCandidate]
    public let libraryGeneration: UInt64

    public init(candidates: [AlbumCandidate], libraryGeneration: UInt64) {
        self.candidates = candidates
        self.libraryGeneration = libraryGeneration
    }

    struct Accumulator {
        var title: String
        var artistName: String
        var artistKeys: [String]
        var year: Int?
        var trackCount = 0
        var totalDuration: TimeInterval = 0
        var familyMask: UInt16 = 0
        var latestAdded = Date.distantPast
        var isCue = false
        var artworkSongID: String?
    }

    /// Nil when cancelled. Spoken word should already be left out by the caller.
    public static func build<Songs: Collection>(
        songs: Songs,
        libraryGeneration: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> AlbumCandidateIndex? where Songs.Element: ListeningSongTraits {
        var accumulators: [String: Accumulator] = [:]
        var order: [String] = []
        var memo = ListeningGenreClassifier.Memo()
        // Folding is the expensive step; an artist recurs on every track.
        var foldedNames: [String: String] = [:]
        func artistKey(_ name: String) -> String {
            if let key = foldedNames[name] { return key }
            let key = ListeningTextKey.folded(name)
            foldedNames[name] = key
            return key
        }
        var position = 0
        for song in songs {
            if position.isMultiple(of: 1_024), isCancelled() { return nil }
            position += 1
            guard song.isPlayable, let albumID = song.albumID, !albumID.isEmpty else { continue }
            if accumulators[albumID] == nil {
                guard let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { continue }
                let artist = [song.albumArtistName, song.artistName]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                accumulators[albumID] = Accumulator(
                    title: title,
                    artistName: artist,
                    artistKeys: artist.isEmpty ? [] : [artistKey(artist)]
                )
                order.append(albumID)
            }
            let mask = memo.mask(for: song.genre)
            var trackArtistKey: String?
            if let name = song.artistName, !name.isEmpty { trackArtistKey = artistKey(name) }
            accumulators[albumID]!.add(song, familyMask: mask, artistKey: trackArtistKey)
        }
        guard !isCancelled() else { return nil }
        var candidates: [AlbumCandidate] = []
        candidates.reserveCapacity(order.count / 4)
        for albumID in order {
            guard let album = accumulators[albumID] else { continue }
            let complete = album.trackCount >= minimumTrackCount
                || (album.isCue && album.trackCount >= minimumCueTrackCount)
            guard complete else { continue }
            candidates.append(AlbumCandidate(
                albumID: albumID,
                title: album.title,
                artistName: album.artistName,
                artistKeys: album.artistKeys,
                year: album.year,
                trackCount: album.trackCount,
                totalDuration: album.totalDuration,
                families: ListeningGenreFamily.families(inMask: album.familyMask),
                latestAdded: album.latestAdded,
                isCueAlbum: album.isCue,
                artworkSongID: album.artworkSongID
            ))
        }
        return AlbumCandidateIndex(candidates: candidates, libraryGeneration: libraryGeneration)
    }
}

private extension AlbumCandidateIndex.Accumulator {
    mutating func add<Song: ListeningSongTraits>(_ song: Song, familyMask: UInt16, artistKey: String?) {
        trackCount += 1
        let length = song.duration
        if length.isFinite, length > 0 { totalDuration += length }
        self.familyMask |= familyMask
        let added = song.dateAdded
        if added > latestAdded { latestAdded = added }
        if year == nil, let songYear = song.year, songYear > 0 { year = songYear }
        if !isCue, song.cueSheetPath?.isEmpty == false { isCue = true }
        if artworkSongID == nil, song.coverArtFileName?.isEmpty == false { artworkSongID = song.id }
        if artistKeys.count < 4, let artistKey, !artistKey.isEmpty, !artistKeys.contains(artistKey) {
            artistKeys.append(artistKey)
        }
    }
}

// MARK: - Recommending

/// A play from the history, resolved to its album by the caller.
public struct AlbumListeningEvent: Sendable {
    public let songID: String
    public let albumID: String?
    public let artistName: String?
    public let playedAt: Date

    public init(songID: String, albumID: String?, artistName: String?, playedAt: Date) {
        self.songID = songID
        self.albumID = albumID
        self.artistName = artistName
        self.playedAt = playedAt
    }
}

/// Why an album was picked; the app turns it into one line of copy.
public enum AlbumRecommendationReason: Equatable, Hashable, Sendable {
    case holiday(ListeningHoliday)
    case likedAlbum
    /// "You played 3 songs by X this week."
    case artistPlayedThisWeek(artist: String, count: Int)
    /// "You've been on jazz lately."
    case recentVibe(ListeningGenreFamily)
    case likedArtist(String)
    /// "Added 2 weeks ago and not played through yet"; 0 weeks: added this week.
    case addedNotHeard(weeks: Int)
    /// "You played X N times recently."
    case artistPlayedRecently(artist: String, count: Int)
    case notHeardInAWhile
    case fitsMoment(ListeningSituation)
    case libraryPick
}

public struct AlbumRecommendation: Equatable, Identifiable, Sendable {
    public let albumID: String
    public let title: String
    public let artistName: String
    public let year: Int?
    public let trackCount: Int
    public let totalDuration: TimeInterval
    public let isCueAlbum: Bool
    public let artworkSongID: String?
    public let reason: AlbumRecommendationReason
    public let score: Double

    public var id: String { albumID }
}

public struct AlbumRecommendationSet: Equatable, Sendable {
    public let moment: ListeningMoment
    /// The pick for now first, then the alternates "another one" steps through.
    public let picks: [AlbumRecommendation]

    public init(moment: ListeningMoment, picks: [AlbumRecommendation]) {
        self.moment = moment
        self.picks = picks
    }
}

/// What the recommender knows about the listener right now.
public struct AlbumRecommendationContext: Sendable {
    public var moment: ListeningMoment
    public var now: Date
    public var events: [AlbumListeningEvent]
    public var likedAlbumIDs: Set<String>
    /// Folded names (`ListeningTextKey.folded`).
    public var likedArtistKeys: Set<String>
    /// "Don't recommend this again" — kept on this device only.
    public var dismissedAlbumIDs: Set<String>

    public init(
        moment: ListeningMoment,
        now: Date,
        events: [AlbumListeningEvent],
        likedAlbumIDs: Set<String> = [],
        likedArtistKeys: Set<String> = [],
        dismissedAlbumIDs: Set<String> = []
    ) {
        self.moment = moment
        self.now = now
        self.events = events
        self.likedAlbumIDs = likedAlbumIDs
        self.likedArtistKeys = likedArtistKeys
        self.dismissedAlbumIDs = dismissedAlbumIDs
    }
}

/// Picks whole albums for the moment: the home "album for now" card on iPhone,
/// iPad and Mac, the Apple TV home hero, and the candidates an AI layer may
/// rerank. Pure and deterministic for a given moment, so the pick holds still
/// through the moment and changes with it; "another one" steps through the
/// alternates.
/// 首页「情景推荐专辑」一次摆几张,「换一批」怎么轮。
///
/// 一张时就是原来的大卡片和「换一张」;多张时横着滑,「换一批」整批往后换。
public enum AlbumPickBatchPolicy {
    /// 首页编辑里能调的张数。
    public static let visibleCountRange = 1...10

    /// 这个情景一共排出多少张:摆出来的那一批,后面再备一整批给「换一批」。
    /// 一张时仍是原来的一张加五张备选。
    public static func poolSize(visibleCount: Int) -> Int {
        let count = min(max(visibleCount, visibleCountRange.lowerBound), visibleCountRange.upperBound)
        return max(AlbumRecommender.pickCount, count * 2)
    }

    /// 从 `start` 起摆 `count` 张,排到尾就绕回开头,一张不重复。
    public static func indices(start: Int, count: Int, total: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        let first = min(max(start, 0), total - 1)
        return (0..<min(count, total)).map { (first + $0) % total }
    }

    /// 「换一批」之后从第几张起。整批都摆得下时原地不动。
    public static func nextStart(after start: Int, count: Int, total: Int) -> Int {
        guard total > count, count > 0 else { return 0 }
        return (min(max(start, 0), total - 1) + count) % total
    }
}

public enum AlbumRecommender {
    /// Current pick plus five alternates.
    public static let pickCount = 6
    /// An album counts as played through once this share of it was heard…
    public static let playedThroughShare = 0.6
    /// …within this many days, and is then skipped.
    public static let playedThroughWindowDays = 30
    /// Artists heard within this many days give their albums affinity.
    public static let artistAffinityWindowDays = 90

    struct AlbumHistory {
        var distinctRecentTracks = Set<String>()
        var lastPlayed: Date?
        var playedInLastDays3 = false
    }

    public static func recommend(
        index: AlbumCandidateIndex,
        context: AlbumRecommendationContext,
        limit: Int = pickCount
    ) -> AlbumRecommendationSet {
        AlbumRecommendationSet(
            moment: context.moment,
            picks: rankedCandidates(index: index, context: context, limit: limit, diversifyArtists: true)
        )
    }

    /// Ranked picks. `diversifyArtists` keeps one album per artist while it
    /// can; an AI layer reranking a longer list may want them all.
    public static func rankedCandidates(
        index: AlbumCandidateIndex,
        context: AlbumRecommendationContext,
        limit: Int,
        diversifyArtists: Bool = true
    ) -> [AlbumRecommendation] {
        guard limit > 0, !index.candidates.isEmpty else { return [] }
        let now = context.now
        let day: TimeInterval = 86_400

        // History, folded once.
        var albumHistory: [String: AlbumHistory] = [:]
        var artistPlays90: [String: Int] = [:]
        var artistPlays7: [String: Int] = [:]
        var recentAlbumIDs: [String] = []
        let sortedEvents = context.events.filter { $0.playedAt <= now }.sorted { $0.playedAt > $1.playedAt }
        for event in sortedEvents {
            let age = now.timeIntervalSince(event.playedAt)
            if let albumID = event.albumID {
                var history = albumHistory[albumID] ?? AlbumHistory()
                if history.lastPlayed == nil { history.lastPlayed = event.playedAt }
                if age <= Double(playedThroughWindowDays) * day { history.distinctRecentTracks.insert(event.songID) }
                if age <= 3 * day { history.playedInLastDays3 = true }
                albumHistory[albumID] = history
                if age <= 6 * 3_600, recentAlbumIDs.count < 10 { recentAlbumIDs.append(albumID) }
            }
            let artistKey = ListeningTextKey.folded(event.artistName)
            guard !artistKey.isEmpty else { continue }
            if age <= Double(artistAffinityWindowDays) * day { artistPlays90[artistKey, default: 0] += 1 }
            if age <= 7 * day { artistPlays7[artistKey, default: 0] += 1 }
        }

        let vibeFamily = recentVibe(recentAlbumIDs: recentAlbumIDs, candidates: index.candidates)
        let situation = context.moment.situation
        let weights = situation.familyWeights
        let holiday = context.moment.holiday
        let holidayWords = holiday?.titleWords ?? []
        let seedKey = context.moment.seedKey

        struct Scored {
            let candidate: AlbumCandidate
            let score: Double
            let reason: AlbumRecommendationReason
            let tier: Int
        }

        var scored: [Scored] = []
        scored.reserveCapacity(min(index.candidates.count, 4_096))
        for candidate in index.candidates {
            guard !context.dismissedAlbumIDs.contains(candidate.albumID) else { continue }
            let history = albumHistory[candidate.albumID]
            let playedThrough = Double(history?.distinctRecentTracks.count ?? 0)
                >= max(3, (Double(candidate.trackCount) * playedThroughShare).rounded(.up))
            let plays90 = candidate.artistKeys.reduce(0) { $0 + (artistPlays90[$1] ?? 0) }
            let plays7 = candidate.artistKeys.reduce(0) { $0 + (artistPlays7[$1] ?? 0) }
            let likedAlbum = context.likedAlbumIDs.contains(candidate.albumID)
            let likedArtist = candidate.artistKeys.contains { context.likedArtistKeys.contains($0) }
            // Tier 0: an artist they listen to or like, not played through
            // lately. Tier 1: anything not played through lately. Tier 2:
            // anything at all — the card is always there.
            let tier: Int
            if !playedThrough, plays90 > 0 || likedArtist || likedAlbum {
                tier = 0
            } else if !playedThrough {
                tier = 1
            } else {
                tier = 2
            }

            var score = 12 * log2(1 + Double(plays90))
            if likedArtist { score += 10 }
            if likedAlbum { score += 14 }
            let daysSincePlayed = history?.lastPlayed.map { now.timeIntervalSince($0) / day }
            let neverPlayed = daysSincePlayed == nil
            if neverPlayed {
                score += 8
            } else if let days = daysSincePlayed, days >= 120 {
                score += 6
            }
            let addedDays = now.timeIntervalSince(candidate.latestAdded) / day
            if neverPlayed, addedDays >= 0, addedDays <= 45 { score += 6 }
            if history?.playedInLastDays3 == true { score -= 10 }

            var best = 0.0
            var worst = 0.0
            for family in candidate.families {
                let weight = weights[family] ?? 0
                best = max(best, weight)
                worst = min(worst, weight)
            }
            let situationFit = best + worst
            score += situationFit
            if let preferred = situation.preferredMinutes, candidate.totalDuration > 0 {
                let minutes = candidate.totalDuration / 60
                if preferred.contains(minutes) { score += 4 }
            }
            if context.moment.isWeekend, candidate.totalDuration >= 45 * 60 { score += 2 }
            let vibeMatch = vibeFamily.map { candidate.families.contains($0) } ?? false
            if vibeMatch { score += 8 }
            var holidayMatch = false
            if !holidayWords.isEmpty {
                let title = candidate.title.lowercased()
                holidayMatch = holidayWords.contains { title.contains($0) }
                if holidayMatch { score += 40 }
            }
            score += ListeningSeededGenerator.unitNoise(candidate.albumID + "|" + seedKey) * 10

            let reason: AlbumRecommendationReason
            if holidayMatch, let holiday {
                reason = .holiday(holiday)
            } else if likedAlbum {
                reason = .likedAlbum
            } else if plays7 >= 2 {
                reason = .artistPlayedThisWeek(artist: candidate.artistName, count: plays7)
            } else if vibeMatch, let vibeFamily {
                reason = .recentVibe(vibeFamily)
            } else if likedArtist {
                reason = .likedArtist(candidate.artistName)
            } else if neverPlayed, addedDays >= 0, addedDays <= 60 {
                reason = .addedNotHeard(weeks: Int(addedDays / 7))
            } else if plays90 > 0 {
                reason = .artistPlayedRecently(artist: candidate.artistName, count: plays90)
            } else if let days = daysSincePlayed, days >= 120 {
                reason = .notHeardInAWhile
            } else if situationFit > 0 {
                reason = .fitsMoment(situation)
            } else {
                reason = .libraryPick
            }
            scored.append(Scored(candidate: candidate, score: score, reason: reason, tier: tier))
        }

        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.albumID < rhs.candidate.albumID
        }

        var picked: [Scored] = []
        var usedArtists = Set<String>()
        var usedAlbums = Set<String>()
        if diversifyArtists {
            for item in scored where picked.count < limit {
                let key = item.candidate.primaryArtistKey
                guard key.isEmpty || !usedArtists.contains(key) else { continue }
                usedArtists.insert(key)
                usedAlbums.insert(item.candidate.albumID)
                picked.append(item)
            }
        }
        for item in scored where picked.count < limit && !usedAlbums.contains(item.candidate.albumID) {
            usedAlbums.insert(item.candidate.albumID)
            picked.append(item)
        }

        return picked.map { item in
            AlbumRecommendation(
                albumID: item.candidate.albumID,
                title: item.candidate.title,
                artistName: item.candidate.artistName,
                year: item.candidate.year,
                trackCount: item.candidate.trackCount,
                totalDuration: item.candidate.totalDuration,
                isCueAlbum: item.candidate.isCueAlbum,
                artworkSongID: item.candidate.artworkSongID,
                reason: item.reason,
                score: item.score
            )
        }
    }

    /// The family most of the last few hours' plays share, if there is one.
    static func recentVibe(
        recentAlbumIDs: [String],
        candidates: [AlbumCandidate]
    ) -> ListeningGenreFamily? {
        guard recentAlbumIDs.count >= 4 else { return nil }
        let wanted = Set(recentAlbumIDs)
        var familiesByAlbum: [String: Set<ListeningGenreFamily>] = [:]
        for candidate in candidates where wanted.contains(candidate.albumID) {
            familiesByAlbum[candidate.albumID] = candidate.families
            if familiesByAlbum.count == wanted.count { break }
        }
        var counts: [ListeningGenreFamily: Int] = [:]
        for albumID in recentAlbumIDs {
            for family in familiesByAlbum[albumID] ?? [] { counts[family, default: 0] += 1 }
        }
        let threshold = (recentAlbumIDs.count + 1) / 2
        return counts
            .filter { $0.value >= threshold }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.rawValue < rhs.key.rawValue
            }
            .first?.key
    }
}

/// CJK and other non-Latin words for album titles that fit a holiday. Matched
/// against album titles, never shown as UI copy.
enum ListeningHolidayTerms {
    static let christmas: [String] = ["圣诞", "聖誕", "クリスマス"]
    static let newYear: [String] = ["新年", "春节", "春節", "贺岁", "賀歲", "过年", "過年", "新春"]
    static let midAutumn: [String] = ["中秋", "月亮", "明月"]
    static let halloween: [String] = ["万圣", "萬聖"]
    static let love: [String] = ["情人", "七夕"]
}
