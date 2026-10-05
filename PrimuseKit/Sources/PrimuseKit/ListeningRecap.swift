import Foundation

/// 听歌回顾里的一次播放。只放音乐：有声内容由调用方先剔掉，回顾里的数字、
/// 人格和时刻都只说音乐。
public struct ListeningRecapEvent: Sendable, Equatable {
    public let songID: String
    public let title: String
    public let artist: String
    public let album: String
    public let playedAt: Date
    public let seconds: TimeInterval

    public init(
        songID: String,
        title: String,
        artist: String,
        album: String,
        playedAt: Date,
        seconds: TimeInterval
    ) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.playedAt = playedAt
        self.seconds = seconds.isFinite ? max(0, seconds) : 0
    }
}

/// 播放记录里没有的歌曲属性，从曲库查。查不到的歌不参与风格与年代判断。
public struct ListeningRecapSongTraits: Sendable, Equatable {
    public var genre: String?
    public var year: Int?

    public init(genre: String? = nil, year: Int? = nil) {
        self.genre = genre
        self.year = year
    }
}

/// 一天里的时段。正午起算下午，「多在上午听歌，13 时前后最常打开」这种话才不会自相矛盾。
public enum ListeningDaypart: String, Sendable, CaseIterable, Codable {
    case dawn
    case morning
    case afternoon
    case evening
    case lateNight = "late_night"

    public static func of(hour: Int) -> ListeningDaypart {
        switch hour {
        case 5...8: return .dawn
        case 9...11: return .morning
        case 12...17: return .afternoon
        case 18...22: return .evening
        default: return .lateNight
        }
    }
}

/// 音乐人格的四个维度。年度报告和听歌回顾用同一套门槛，同一段记录两边判出来一样。
public struct ListeningPersonalityTraits: Sendable, Equatable, Hashable {
    public enum Exploration: String, Sendable { case explorer, loyalist }
    public enum Diversity: String, Sendable { case omnivore, focused }
    public enum Recency: String, Sendable { case new, vintage }
    public enum DayCycle: String, Sendable { case day, moon }

    public let exploration: Exploration
    public let diversity: Diversity
    public let recency: Recency
    public let dayCycle: DayCycle

    /// 前五位艺人的播放占比低于这个值算「探索」。
    public static let explorerTopArtistShareCeiling = 0.35
    /// 听过这么多种风格算「杂食」。
    public static let omnivoreGenreFloor = 6
    /// 歌曲发行年份的中位数比参照年份早这么多年以上算「怀旧」。
    public static let vintageYearSpan = 5
    /// 傍晚六点到早上六点的听歌时长占比超过这个值算「夜行」。
    public static let moonNightShareFloor = 0.55

    public init(exploration: Exploration, diversity: Diversity, recency: Recency, dayCycle: DayCycle) {
        self.exploration = exploration
        self.diversity = diversity
        self.recency = recency
        self.dayCycle = dayCycle
    }

    /// 四个字母的代码，如 `EOND`。
    public var code: String {
        (exploration == .explorer ? "E" : "L")
            + (diversity == .omnivore ? "O" : "F")
            + (recency == .new ? "N" : "V")
            + (dayCycle == .day ? "D" : "M")
    }

    /// 没有年份可看时按「追新」算：大多数人新歌占多数。
    public static func classify(
        topFiveArtistShare: Double,
        genreCount: Int,
        medianReleaseYear: Int?,
        referenceYear: Int,
        nightShare: Double
    ) -> ListeningPersonalityTraits {
        let recency: Recency
        if let medianReleaseYear {
            recency = medianReleaseYear >= referenceYear - vintageYearSpan ? .new : .vintage
        } else {
            recency = .new
        }
        return ListeningPersonalityTraits(
            exploration: topFiveArtistShare < explorerTopArtistShareCeiling ? .explorer : .loyalist,
            diversity: genreCount >= omnivoreGenreFloor ? .omnivore : .focused,
            recency: recency,
            dayCycle: nightShare > moonNightShareFloor ? .moon : .day
        )
    }
}

/// 一段时间的听歌回顾：只有数字和事实，不画图。
public struct ListeningRecap: Sendable, Equatable {
    public struct Totals: Sendable, Equatable {
        public var plays = 0
        public var seconds: TimeInterval = 0
        public var activeDays = 0
        public var uniqueSongs = 0
        public var uniqueArtists = 0
        public var uniqueAlbums = 0

        public init() {}
    }

    /// 上一个等长周期。只有周、月、年才有。
    public struct Comparison: Sendable, Equatable {
        public let plays: Int
        public let seconds: TimeInterval

        public init(plays: Int, seconds: TimeInterval) {
            self.plays = plays
            self.seconds = seconds
        }

        /// 听歌时长的变化比例；上一周期一首没听时为 nil（「多了无穷倍」没有意义）。
        public func secondsChange(to current: TimeInterval) -> Double? {
            guard seconds > 0 else { return nil }
            return (current - seconds) / seconds
        }
    }

    public struct Day: Sendable, Equatable {
        public let date: Date
        public let seconds: TimeInterval
        public let plays: Int
    }

    public struct Session: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let seconds: TimeInterval
        public let songs: Int
    }

    public struct Streak: Sendable, Equatable {
        public let start: Date
        public let days: Int
    }

    public struct Genre: Sendable, Equatable {
        public let name: String
        public let share: Double
    }

    public var totals = Totals()
    public var previous: Comparison?
    /// 听得最久的那个钟点（0–23）。
    public var peakHour: Int?
    public var peakDaypart: ListeningDaypart?
    /// 傍晚六点到早上六点的时长占比。
    public var nightShare: Double = 0
    public var busiestDay: Day?
    public var longestSession: Session?
    public var longestStreak: Streak?
    /// 这段时间里第一次听到的歌。早于这段时间没有任何记录时说不清哪些是「第一次」，为 nil。
    public var discoveries: Int?
    public var topGenres: [Genre] = []
    public var genreCount = 0
    public var topFiveArtistShare: Double = 0
    public var medianReleaseYear: Int?
    /// 播放太少时不判人格，免得几首歌就给人贴标签。
    public var personality: ListeningPersonalityTraits?

    public init() {}

    public var isEmpty: Bool { totals.plays == 0 }
}

public enum ListeningRecapBuilder {
    public static let personalityMinimumPlays = 20
    /// 两次播放之间空出不超过这么久算同一段连听。
    public static let sessionGap: TimeInterval = 5 * 60
    public static let topGenreCount = 3

    /// - Parameters:
    ///   - events: 全部音乐播放记录，顺序不限。「第一次听」要往这段时间之前看。
    ///   - interval: 回顾的时间段；nil 表示全部。
    ///   - previousInterval: 用来对比的上一个等长周期。
    ///   - referenceYear: 判断「追新/怀旧」的参照年份。
    public static func build(
        events: [ListeningRecapEvent],
        interval: DateInterval?,
        previousInterval: DateInterval?,
        traits: [String: ListeningRecapSongTraits],
        calendar: Calendar,
        referenceYear: Int
    ) -> ListeningRecap {
        var recap = ListeningRecap()
        let scoped = events
            .filter { interval?.contains($0.playedAt) ?? true }
            .sorted { $0.playedAt < $1.playedAt }

        if let previousInterval {
            var plays = 0
            var seconds: TimeInterval = 0
            for event in events where previousInterval.start <= event.playedAt && event.playedAt < previousInterval.end {
                plays += 1
                seconds += event.seconds
            }
            recap.previous = .init(plays: plays, seconds: seconds)
        }
        guard !scoped.isEmpty else { return recap }

        var totals = ListeningRecap.Totals()
        totals.plays = scoped.count
        totals.seconds = scoped.reduce(0) { $0 + $1.seconds }
        totals.uniqueSongs = Set(scoped.map(\.songID)).count
        var artistKeys = ArtistKeyMemo()
        totals.uniqueArtists = Set(scoped.compactMap { artistKeys.key($0.artist) }).count
        totals.uniqueAlbums = Set(scoped.compactMap { event -> String? in
            normalizedKey(event.album).map { $0 + "\u{1F}" + (normalizedKey(event.artist) ?? "") }
        }).count

        // 按天
        var days: [Date: (seconds: TimeInterval, plays: Int)] = [:]
        for event in scoped {
            let day = calendar.startOfDay(for: event.playedAt)
            days[day, default: (0, 0)].seconds += event.seconds
            days[day, default: (0, 0)].plays += 1
        }
        totals.activeDays = days.count
        recap.totals = totals
        recap.busiestDay = days
            .max { lhs, rhs in
                if lhs.value.seconds != rhs.value.seconds { return lhs.value.seconds < rhs.value.seconds }
                if lhs.value.plays != rhs.value.plays { return lhs.value.plays < rhs.value.plays }
                return lhs.key < rhs.key
            }
            .map { .init(date: $0.key, seconds: $0.value.seconds, plays: $0.value.plays) }
        recap.longestStreak = longestStreak(days: Set(days.keys), calendar: calendar)

        // 按钟点
        var hours = Array(repeating: 0.0, count: 24)
        for event in scoped {
            let hour = calendar.component(.hour, from: event.playedAt)
            if hours.indices.contains(hour) { hours[hour] += event.seconds }
        }
        if totals.seconds > 0 {
            let peak = hours.indices.max { hours[$0] < hours[$1] } ?? 0
            recap.peakHour = peak
            recap.peakDaypart = .of(hour: peak)
            let night = hours[18..<24].reduce(0, +) + hours[0..<6].reduce(0, +)
            recap.nightShare = night / totals.seconds
        }

        recap.longestSession = longestSession(scoped)
        recap.discoveries = discoveries(events: events, scoped: scoped, interval: interval)

        // 艺人集中度
        var artistPlays: [String: Int] = [:]
        for event in scoped {
            guard let key = artistKeys.key(event.artist) else { continue }
            artistPlays[key, default: 0] += 1
        }
        let artistTotal = artistPlays.values.reduce(0, +)
        if artistTotal > 0 {
            let topFive = artistPlays.values.sorted(by: >).prefix(5).reduce(0, +)
            recap.topFiveArtistShare = Double(topFive) / Double(artistTotal)
        }

        // 风格
        var genrePlays: [String: Int] = [:]
        var genreNames: [String: String] = [:]
        var years: [Int] = []
        for event in scoped {
            let songTraits = traits[event.songID]
            if let genre = songTraits?.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
               !genre.isEmpty {
                let key = genre.lowercased()
                genreNames[key] = genreNames[key] ?? genre
                genrePlays[key, default: 0] += 1
            }
            if let year = songTraits?.year, year > 1900, year <= referenceYear {
                years.append(year)
            }
        }
        let genreTotal = genrePlays.values.reduce(0, +)
        recap.genreCount = genrePlays.count
        if genreTotal > 0 {
            recap.topGenres = genrePlays
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(topGenreCount)
                .map { .init(name: genreNames[$0.key] ?? $0.key, share: Double($0.value) / Double(genreTotal)) }
        }
        if !years.isEmpty {
            let sorted = years.sorted()
            recap.medianReleaseYear = sorted[sorted.count / 2]
        }

        if totals.plays >= personalityMinimumPlays {
            recap.personality = .classify(
                topFiveArtistShare: recap.topFiveArtistShare,
                genreCount: recap.genreCount,
                medianReleaseYear: recap.medianReleaseYear,
                referenceYear: referenceYear,
                nightShare: recap.nightShare
            )
        }
        return recap
    }

    /// 相邻两次播放（上一首听完到下一首开始）间隔不超过 `sessionGap` 算同一段。
    /// - Parameter events: 已按时间升序。
    public static func longestSession(_ events: [ListeningRecapEvent]) -> ListeningRecap.Session? {
        guard let first = events.first else { return nil }
        var best = ListeningRecap.Session(
            start: first.playedAt,
            end: first.playedAt.addingTimeInterval(first.seconds),
            seconds: first.seconds,
            songs: 1
        )
        var current = best
        for event in events.dropFirst() {
            if event.playedAt.timeIntervalSince(current.end) <= sessionGap {
                current = .init(
                    start: current.start,
                    end: max(current.end, event.playedAt.addingTimeInterval(event.seconds)),
                    seconds: current.seconds + event.seconds,
                    songs: current.songs + 1
                )
            } else {
                current = .init(
                    start: event.playedAt,
                    end: event.playedAt.addingTimeInterval(event.seconds),
                    seconds: event.seconds,
                    songs: 1
                )
            }
            if current.seconds > best.seconds { best = current }
        }
        return best
    }

    /// 连续有播放的天数最长的一段；并列时取最近的一段。
    public static func longestStreak(days: Set<Date>, calendar: Calendar) -> ListeningRecap.Streak? {
        let sorted = days.sorted()
        guard let first = sorted.first else { return nil }
        var best = ListeningRecap.Streak(start: first, days: 1)
        var runStart = first
        var runLength = 1
        var previous = first
        for day in sorted.dropFirst() {
            let expected = calendar.date(byAdding: .day, value: 1, to: previous)
                .map { calendar.startOfDay(for: $0) }
            if expected == day {
                runLength += 1
            } else {
                runStart = day
                runLength = 1
            }
            if runLength >= best.days { best = .init(start: runStart, days: runLength) }
            previous = day
        }
        return best
    }

    private static func discoveries(
        events: [ListeningRecapEvent],
        scoped: [ListeningRecapEvent],
        interval: DateInterval?
    ) -> Int? {
        guard let interval,
              let earliest = events.lazy.map(\.playedAt).min(),
              earliest < interval.start else { return nil }
        var firstPlay: [String: Date] = [:]
        for event in events {
            if let known = firstPlay[event.songID], known <= event.playedAt { continue }
            firstPlay[event.songID] = event.playedAt
        }
        return Set(scoped.map(\.songID)).filter { songID in
            (firstPlay[songID] ?? .distantPast) >= interval.start
        }.count
    }

    private static func normalizedKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 算作一位艺人的键;「群星」这类占位署名不算。同一个名字出现很多次,判一次就记下。
    private struct ArtistKeyMemo {
        private var keys: [String: String?] = [:]

        mutating func key(_ value: String) -> String? {
            if let known = keys[value] { return known }
            let key = ListeningRecapBuilder.normalizedKey(value).flatMap { PlaceholderArtistPolicy.isPlaceholder($0) ? nil : $0 }
            keys[value] = .some(key)
            return key
        }
    }
}
