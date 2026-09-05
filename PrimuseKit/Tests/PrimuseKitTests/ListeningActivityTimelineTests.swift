import Foundation
import Testing
@testable import PrimuseKit

struct ListeningActivityTimelineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func periodChangesPreserveFullLeapYearCalendarAndHistoricalCounts() {
        let now = date(2024, 3, 12)
        let events: [ListeningActivityTimeline.Event] = [
            .init(date: date(2024, 2, 29), seconds: 90),
            .init(date: date(2024, 3, 12, 8), seconds: 60),
            .init(date: date(2024, 3, 13), seconds: 100)
        ]
        let week = ListeningActivityTimeline(events: events, selectedStart: date(2024, 3, 11, 0),
                                             displayYear: nil, now: now, calendar: calendar)
        let year = ListeningActivityTimeline(events: events, selectedStart: date(2024, 1, 1, 0),
                                             displayYear: nil, now: now, calendar: calendar)
        #expect(week.calendarDays.map(\.date) == year.calendarDays.map(\.date))
        #expect(week.calendarDays.filter { $0.date >= week.yearInterval.start && $0.date < week.yearInterval.end }.count == 366)
        #expect(week.calendarDays.first { calendar.isDate($0.date, inSameDayAs: date(2024, 2, 29)) }?.count == 1)
        #expect(week.dailyStats.map(\.count) == [0, 1])
        #expect(week.hourlyCounts[8] == 1)
        #expect(week.hourlyCounts.reduce(0, +) == 1)
        #expect(year.dailyStats.reduce(0) { $0 + $1.totalSec } == 150)
        #expect(year.calendarDays.filter { $0.date > now }.allSatisfy { $0.count == 0 })
    }

    @Test func newYearWeekIncludesPreviousYearAndFutureDaysStayEmpty() {
        let now = date(2026, 1, 2)
        let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let timeline = ListeningActivityTimeline(events: [.init(date: date(2025, 12, 31), seconds: 120)],
            selectedStart: start, displayYear: nil, now: now, calendar: calendar)
        #expect(timeline.calendarDays.first?.date == start)
        #expect(timeline.dailyStats.reduce(0) { $0 + $1.count } == 1)
        #expect(timeline.calendarDays.first { calendar.isDate($0.date, inSameDayAs: date(2025, 12, 31)) }?.count == 1)
        #expect(timeline.calendarDays.filter { $0.date >= timeline.yearInterval.start && $0.date < timeline.yearInterval.end }.count == 365)
        #expect(timeline.availableYears == [2026, 2025])
    }

    @Test func allHistoryKeepsCoverageDenominatorAndMonthTotalsBeyond740Days() {
        let now = date(2026, 9, 5)
        let events: [ListeningActivityTimeline.Event] = [
            .init(date: date(2023, 1, 1), seconds: 30),
            .init(date: date(2026, 9, 5, 7), seconds: 90)
        ]
        let timeline = ListeningActivityTimeline(events: events, selectedStart: nil,
            displayYear: 2023, now: now, calendar: calendar)
        #expect(timeline.dailyStats.count == 1344)
        #expect(timeline.trendUsesMonths)
        #expect(timeline.trend.count == 45)
        #expect(timeline.trend.reduce(0) { $0 + $1.totalSec } == 120)
        #expect(timeline.trend.reduce(0) { $0 + $1.count } == 2)
        #expect(calendar.component(.year, from: timeline.yearInterval.start) == 2023)
    }

    @Test func emptyPeriodAndDSTProduceZeroFilledCalendarDays() {
        let timeline = ListeningActivityTimeline(events: [], selectedStart: date(2024, 3, 9, 0),
            displayYear: nil, now: date(2024, 3, 11), calendar: calendar)
        #expect(timeline.dailyStats.count == 3)
        #expect(timeline.dailyStats.allSatisfy { $0.count == 0 && $0.totalSec == 0 })
        #expect(timeline.hourlyCounts == [Int](repeating: 0, count: 24))
        #expect(!timeline.trendUsesMonths)
        #expect(timeline.dailyStats[2].date.timeIntervalSince(timeline.dailyStats[1].date) == 23 * 3600)
    }
}
