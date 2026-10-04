import Foundation

/// 年度报告看哪几年、和哪一段比。
public enum ListeningYearReportPolicy {
    /// 一年至少听这么多次，报告才有东西可讲（也是判听歌人格的门槛）。
    public static let minimumPlays = ListeningRecapBuilder.personalityMinimumPlays

    public struct Years: Sendable, Equatable {
        /// 有报告的年份，新的在前。
        public let years: [Int]
        /// 打开时先看的那一年。
        public let initial: Int
    }

    /// 一月里今年还没听几首，先看去年的；否则看最近的一年。
    public static func years(playsByYear: [Int: Int], currentYear: Int, currentMonth: Int) -> Years? {
        let eligible = playsByYear
            .filter { $0.key <= currentYear && $0.value >= minimumPlays }
            .keys
            .sorted(by: >)
        guard let latest = eligible.first else { return nil }
        let initial = currentMonth == 1 && eligible.contains(currentYear - 1) ? currentYear - 1 : latest
        return Years(years: eligible, initial: initial)
    }

    /// 一年的回顾区间：过完的年份是整年，今年是一月一日到现在。
    public static func interval(year: Int, now: Date, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = calendar.date(byAdding: .year, value: 1, to: start),
              start <= now else { return nil }
        return DateInterval(start: start, end: min(next, now))
    }

    /// 还没过完的一年只和去年的同一段比（十月初对去年十月初），过完的年份和去年整年比。
    public static func comparisonInterval(for interval: DateInterval, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(byAdding: .year, value: -1, to: interval.start),
              let end = calendar.date(byAdding: .year, value: -1, to: interval.end),
              start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// 这一年是否还没过完。
    public static func isInProgress(_ interval: DateInterval, year: Int, calendar: Calendar) -> Bool {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = calendar.date(byAdding: .year, value: 1, to: start) else { return false }
        return interval.end < next
    }
}

/// 年度报告里听歌回顾之外的几个时刻：这一年的第一首、夜里最晚的一首、听得最多的月份。
public struct ListeningYearHighlights: Sendable, Equatable {
    public struct Play: Sendable, Equatable {
        public let songID: String
        public let title: String
        public let artist: String
        public let playedAt: Date
    }

    public struct Month: Sendable, Equatable {
        /// 1–12。
        public let month: Int
        public let seconds: TimeInterval
        public let plays: Int
        /// 这个月听得最多的歌。
        public let topSong: Play?
        public let topSongPlays: Int
    }

    public var firstPlay: Play?
    /// 晚上九点到凌晨五点之间、钟点最晚的一次（凌晨的算在前一晚之后）。
    public var latestNight: Play?
    public var peakMonth: Month?

    public init() {}

    /// 夜里从几点算起、到几点为止。
    public static let nightStartHour = 21
    public static let nightEndHour = 5

    public static func build(events: [ListeningRecapEvent], interval: DateInterval, calendar: Calendar) -> ListeningYearHighlights {
        var result = ListeningYearHighlights()
        let scoped = events
            .filter { interval.contains($0.playedAt) }
            .sorted { $0.playedAt < $1.playedAt }
        guard let first = scoped.first else { return result }
        result.firstPlay = Play(first)

        var latest: (lateness: Int, event: ListeningRecapEvent)?
        for event in scoped {
            guard let lateness = nightLateness(event.playedAt, calendar: calendar) else { continue }
            // 同样晚的取最近的一次。
            if latest.map({ lateness >= $0.lateness }) ?? true {
                latest = (lateness, event)
            }
        }
        result.latestNight = latest.map { Play($0.event) }

        var months: [Int: (seconds: TimeInterval, plays: Int)] = [:]
        for event in scoped {
            let month = calendar.component(.month, from: event.playedAt)
            months[month, default: (0, 0)].seconds += event.seconds
            months[month, default: (0, 0)].plays += 1
        }
        let peak = months.max { lhs, rhs in
            if lhs.value.seconds != rhs.value.seconds { return lhs.value.seconds < rhs.value.seconds }
            return lhs.key > rhs.key
        }
        if let peak, peak.value.seconds > 0 {
            let inMonth = scoped.filter { calendar.component(.month, from: $0.playedAt) == peak.key }
            var songs: [String: (plays: Int, seconds: TimeInterval, first: ListeningRecapEvent)] = [:]
            for event in inMonth {
                if let known = songs[event.songID] {
                    songs[event.songID] = (known.plays + 1, known.seconds + event.seconds, known.first)
                } else {
                    songs[event.songID] = (1, event.seconds, event)
                }
            }
            let top = songs.values.max { lhs, rhs in
                if lhs.plays != rhs.plays { return lhs.plays < rhs.plays }
                if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
                return lhs.first.playedAt > rhs.first.playedAt
            }
            result.peakMonth = Month(
                month: peak.key,
                seconds: peak.value.seconds,
                plays: peak.value.plays,
                topSong: top.map { Play($0.first) },
                topSongPlays: top?.plays ?? 0
            )
        }
        return result
    }

    /// 夜里的钟点换算成「过了晚上九点多少秒」，凌晨接在午夜之后；不在夜里为 nil。
    static func nightLateness(_ date: Date, calendar: Calendar) -> Int? {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour else { return nil }
        let clock = (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        if hour >= nightStartHour { return (hour - nightStartHour) * 3_600 + clock }
        if hour < nightEndHour { return (hour + 24 - nightStartHour) * 3_600 + clock }
        return nil
    }
}

private extension ListeningYearHighlights.Play {
    init(_ event: ListeningRecapEvent) {
        self.init(songID: event.songID, title: event.title, artist: event.artist, playedAt: event.playedAt)
    }
}
