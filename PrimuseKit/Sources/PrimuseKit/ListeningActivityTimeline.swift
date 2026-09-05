import Foundation

public struct ListeningActivityTimeline: Sendable {
    public struct Event: Sendable {
        public let date: Date
        public let seconds: TimeInterval

        public init(date: Date, seconds: TimeInterval) {
            self.date = date
            self.seconds = seconds
        }
    }

    public struct Day: Identifiable, Sendable {
        public let date: Date
        public let count: Int
        public let totalSec: TimeInterval
        public var id: Date { date }
    }

    public let selectedStart: Date
    public let dailyStats: [Day]
    public let calendarDays: [Day]
    public let yearInterval: DateInterval
    public let availableYears: [Int]
    public let hourlyCounts: [Int]
    public let trend: [Day]
    public let trendUsesMonths: Bool

    public init(events: [Event], selectedStart: Date?, displayYear: Int?, now: Date, calendar: Calendar) {
        let validEvents = events.filter { $0.date <= now }
        let today = calendar.startOfDay(for: now)
        let firstDate = validEvents.map(\.date).min() ?? now
        let start = calendar.startOfDay(for: selectedStart ?? firstDate)
        self.selectedStart = start
        let buckets = Dictionary(grouping: validEvents) { calendar.startOfDay(for: $0.date) }
        let selected = validEvents.filter { $0.date >= start }
        var hours = [Int](repeating: 0, count: 24)
        for event in selected {
            hours[calendar.component(.hour, from: event.date)] += 1
        }
        hourlyCounts = hours

        func days(from start: Date, through end: Date) -> [Day] {
            var result: [Day] = []
            var cursor = start
            while cursor <= end {
                let events = buckets[cursor] ?? []
                result.append(Day(date: cursor, count: events.count, totalSec: events.reduce(0) {
                    $0 + ($1.seconds.isFinite ? max(0, $1.seconds) : 0)
                }))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }
            return result
        }

        dailyStats = days(from: start, through: today)
        let currentYear = calendar.component(.year, from: now)
        let firstYear = min(currentYear, calendar.component(.year, from: min(firstDate, start)))
        let years = Array((firstYear...currentYear).reversed())
        availableYears = years
        let year = displayYear.flatMap { years.contains($0) ? $0 : nil } ?? currentYear
        let yearDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let interval = calendar.dateInterval(of: .year, for: yearDate) ?? DateInterval(start: today, end: today)
        yearInterval = interval
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? today
        // Include adjacent week days so a selected week crossing New Year stays visible.
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
        let lastWeekEnd = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? interval.end
        let lastCell = calendar.date(byAdding: .day, value: -1, to: lastWeekEnd) ?? lastDay
        calendarDays = days(from: firstWeek, through: lastCell)

        trendUsesMonths = dailyStats.count > 62
        if trendUsesMonths {
            let months = Dictionary(grouping: dailyStats) {
                calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date
            }
            trend = months.keys.sorted().map { date in
                let values = months[date] ?? []
                return Day(date: date, count: values.reduce(0) { $0 + $1.count },
                           totalSec: values.reduce(0) { $0 + $1.totalSec })
            }
        } else {
            trend = dailyStats
        }
    }
}
