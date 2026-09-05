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

/// Calendar cells retain future dates as placeholders rather than zero-play days.
public struct ListeningActivityCalendar: Sendable {
    public struct Day: Identifiable, Sendable {
        public let date: Date
        public let count: Int?
        public var id: Date { date }
    }

    public let calendar: Calendar
    public let today: Date
    public let availableYears: [Int]
    private let counts: [Date: Int]

    public init(counts: [(date: Date, count: Int)], now: Date, calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        self.counts = Dictionary(counts.filter { $0.date <= now }.map {
            (calendar.startOfDay(for: $0.date), max(0, $0.count))
        }, uniquingKeysWith: +)
        let currentYear = calendar.component(.year, from: now)
        let firstYear = calendar.component(.year, from: self.counts.keys.min() ?? now)
        availableYears = Array((min(firstYear, currentYear)...currentYear).reversed())
    }

    public func days(in component: Calendar.Component, containing date: Date) -> [Day] {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return [] }
        var result: [Day] = []
        var cursor = interval.start
        while cursor < interval.end {
            result.append(Day(date: cursor, count: cursor > today ? nil : counts[cursor, default: 0]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    public func monthCells(containing date: Date) -> [Day?] {
        let days = days(in: .month, containing: date)
        guard let first = days.first else { return [] }
        let offset = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
        var cells: [Day?] = Array(repeating: nil, count: offset) + days.map(Optional.some)
        // Equal-height month blocks keep the year overview aligned, including six-week months.
        cells += Array(repeating: nil, count: max(0, 42 - cells.count))
        return cells
    }

    public func months(in year: Int) -> [Date] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let interval = calendar.dateInterval(of: .year, for: start) else { return [] }
        var months: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return months
    }
}
