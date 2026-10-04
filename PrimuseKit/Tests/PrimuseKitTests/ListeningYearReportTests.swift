import Foundation
import Testing
@testable import PrimuseKit

struct ListeningYearReportTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func event(_ songID: String, at playedAt: Date, seconds: TimeInterval = 180) -> ListeningRecapEvent {
        ListeningRecapEvent(
            songID: songID, title: "Song \(songID)", artist: "Artist", album: "Album",
            playedAt: playedAt, seconds: seconds
        )
    }

    @Test func reportYearsSkipThinYearsAndStartLastYearInJanuary() {
        let plays = [2026: 25, 2025: 300, 2024: 19, 2023: 40, 2027: 50]
        let october = ListeningYearReportPolicy.years(playsByYear: plays, currentYear: 2026, currentMonth: 10)
        #expect(october == .init(years: [2026, 2025, 2023], initial: 2026))

        let january = ListeningYearReportPolicy.years(playsByYear: plays, currentYear: 2026, currentMonth: 1)
        #expect(january?.initial == 2025)

        // 今年还没听够：先看最近够数的一年。
        let thin = ListeningYearReportPolicy.years(playsByYear: [2026: 5, 2024: 80], currentYear: 2026, currentMonth: 6)
        #expect(thin == .init(years: [2024], initial: 2024))

        #expect(ListeningYearReportPolicy.years(playsByYear: [2026: 3], currentYear: 2026, currentMonth: 6) == nil)
    }

    @Test func thisYearComparesWithTheSameStretchOfLastYear() throws {
        let now = Self.date(2026, 10, 4, 15)
        let thisYear = try #require(ListeningYearReportPolicy.interval(year: 2026, now: now, calendar: Self.calendar))
        #expect(thisYear.start == Self.date(2026, 1, 1, 0))
        #expect(thisYear.end == now)
        #expect(ListeningYearReportPolicy.isInProgress(thisYear, year: 2026, calendar: Self.calendar))

        let lastYearSoFar = try #require(ListeningYearReportPolicy.comparisonInterval(for: thisYear, calendar: Self.calendar))
        #expect(lastYearSoFar.start == Self.date(2025, 1, 1, 0))
        #expect(lastYearSoFar.end == Self.date(2025, 10, 4, 15))

        let past = try #require(ListeningYearReportPolicy.interval(year: 2025, now: now, calendar: Self.calendar))
        #expect(past.end == Self.date(2026, 1, 1, 0))
        #expect(!ListeningYearReportPolicy.isInProgress(past, year: 2025, calendar: Self.calendar))
        #expect(ListeningYearReportPolicy.comparisonInterval(for: past, calendar: Self.calendar)?.start == Self.date(2024, 1, 1, 0))

        #expect(ListeningYearReportPolicy.interval(year: 2027, now: now, calendar: Self.calendar) == nil)
    }

    @Test func highlightsFindTheFirstSongTheLatestNightAndThePeakMonth() throws {
        let year = DateInterval(start: Self.date(2026, 1, 1, 0), end: Self.date(2027, 1, 1, 0))
        let events = [
            Self.event("old", at: Self.date(2025, 12, 31, 23, 50)),
            Self.event("first", at: Self.date(2026, 1, 1, 0, 5)),
            Self.event("late", at: Self.date(2026, 3, 9, 3, 40)),
            Self.event("evening", at: Self.date(2026, 3, 10, 22, 0)),
            Self.event("morning", at: Self.date(2026, 7, 2, 6, 0)),
            Self.event("loop", at: Self.date(2026, 8, 1, 10), seconds: 200),
            Self.event("loop", at: Self.date(2026, 8, 2, 10), seconds: 200),
            Self.event("other", at: Self.date(2026, 8, 3, 10), seconds: 300),
        ]
        let highlights = ListeningYearHighlights.build(events: events, interval: year, calendar: Self.calendar)

        #expect(highlights.firstPlay?.songID == "first")
        // 凌晨三点四十比前一晚十点、元旦零点零五都晚。
        #expect(highlights.latestNight?.songID == "late")

        let peak = try #require(highlights.peakMonth)
        #expect(peak.month == 8)
        #expect(peak.plays == 3)
        #expect(peak.seconds == 700)
        #expect(peak.topSong?.songID == "loop")
        #expect(peak.topSong?.playedAt == Self.date(2026, 8, 1, 10))
        #expect(peak.topSongPlays == 2)
    }

    @Test func noNightPlaysMeansNoLatestNight() {
        let year = DateInterval(start: Self.date(2026, 1, 1, 0), end: Self.date(2027, 1, 1, 0))
        let events = [Self.event("a", at: Self.date(2026, 5, 1, 9)), Self.event("b", at: Self.date(2026, 5, 1, 20, 59))]
        let highlights = ListeningYearHighlights.build(events: events, interval: year, calendar: Self.calendar)
        #expect(highlights.latestNight == nil)
        #expect(highlights.peakMonth?.month == 5)
        #expect(ListeningYearHighlights.build(events: [], interval: year, calendar: Self.calendar) == ListeningYearHighlights())
    }
}
