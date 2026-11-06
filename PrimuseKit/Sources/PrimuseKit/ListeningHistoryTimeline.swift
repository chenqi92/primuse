import Foundation

public struct ListeningHistoryTimeline<Entry: Identifiable & Sendable>: Sendable where Entry.ID: Comparable & Sendable {
    public struct Day: Identifiable, Sendable {
        public let date: Date
        public var entries: [Entry]
        public let playCount: Int
        public let listenedSeconds: TimeInterval
        public var id: Date { date }
    }

    public let days: [Day]
    public let count: Int

    public init(
        entries: [Entry], calendar: Calendar,
        playedAt: (Entry) -> Date,
        listenedSeconds: (Entry) -> TimeInterval
    ) {
        let sorted = entries.sorted {
            let lhs = playedAt($0), rhs = playedAt($1)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let grouped = Dictionary(grouping: sorted) { calendar.startOfDay(for: playedAt($0)) }
        days = grouped.keys.sorted(by: >).map { date in
            let records = grouped[date] ?? []
            return Day(date: date, entries: records, playCount: records.count,
                       listenedSeconds: records.reduce(0) {
                           let seconds = listenedSeconds($1)
                           return $0 + (seconds.isFinite ? max(0, seconds) : 0)
                       })
        }
        count = sorted.count
    }

    /// 分页只裁剪行，日期标题的次数和时长始终统计完整的一天。
    public func visibleDays(limit: Int) -> [Day] {
        var remaining = max(0, limit)
        var result: [Day] = []
        for day in days {
            guard remaining > 0 else { break }
            var visible = day
            if day.entries.count > remaining {
                visible.entries = Array(day.entries.prefix(remaining))
            }
            result.append(visible)
            remaining -= visible.entries.count
        }
        return result
    }

    public func paginationTriggerID(limit: Int, prefetchCount: Int = 10) -> Entry.ID? {
        guard limit > 0, limit < count else { return nil }
        var offset = max(0, limit - max(1, prefetchCount))
        for day in days {
            if offset < day.entries.count { return day.entries[offset].id }
            offset -= day.entries.count
        }
        return nil
    }
}
