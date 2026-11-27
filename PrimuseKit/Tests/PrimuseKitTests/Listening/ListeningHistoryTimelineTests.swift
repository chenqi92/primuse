import Foundation
import Testing
@testable import PrimuseKit

struct ListeningHistoryTimelineTests {
    struct Entry: Identifiable, Sendable {
        let id: String
        let songID: String
        let date: Date
        let seconds: TimeInterval
    }

    private func entry(_ id: String, _ timestamp: String, seconds: TimeInterval = 60) -> Entry {
        Entry(id: id, songID: "same-song", date: ISO8601DateFormatter().date(from: timestamp)!, seconds: seconds)
    }

    private func timeline(_ entries: [Entry], timeZone: String = "Asia/Shanghai") -> ListeningHistoryTimeline<Entry> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return ListeningHistoryTimeline(entries: entries, calendar: calendar,
                                        playedAt: { $0.date }, listenedSeconds: { $0.seconds })
    }

    @Test func localMidnightAndRepeatedSongsStayAsSeparatePlays() {
        let value = timeline([
            entry("older", "2026-11-05T15:59:00Z", seconds: 45),
            entry("newer", "2026-11-05T16:01:00Z", seconds: 90),
            entry("latest", "2026-11-05T17:00:00Z", seconds: 180)
        ])
        #expect(value.count == 3)
        #expect(value.days.map(\.entries).map { $0.map(\.id) } == [["latest", "newer"], ["older"]])
        #expect(value.days.map(\.listenedSeconds) == [270, 45])
    }

    @Test func paginationPreservesWholeDaySummaryAndNeverDropsRows() {
        let entries = (0..<205).map { index in
            Entry(id: String(index), songID: "same-song", date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), seconds: 30)
        }
        let value = timeline(entries)
        let first = value.visibleDays(limit: 100)
        #expect(first.flatMap(\.entries).count == 100)
        #expect(first.first?.playCount == 205)
        #expect(first.first?.listenedSeconds == 6150)
        #expect(value.visibleDays(limit: 200).flatMap(\.entries).count == 200)
        #expect(value.visibleDays(limit: 300).flatMap(\.entries).map(\.id) == entries.reversed().map(\.id))
        #expect(value.visibleDays(limit: 0).isEmpty)
    }

    @Test func pageCanEndWithinTheNextDay() {
        let value = timeline([
            entry("a", "2026-11-06T01:00:00Z"),
            entry("b", "2026-11-05T01:00:00Z"),
            entry("c", "2026-11-05T00:00:00Z")
        ])
        let page = value.visibleDays(limit: 2)
        #expect(page.map { $0.entries.map(\.id) } == [["a"], ["b"]])
        #expect(page.last?.playCount == 2)
        #expect(page.last?.listenedSeconds == 120)
    }

    @Test func daylightSavingRepeatedHourBelongsToTheSameDate() {
        let value = timeline([
            entry("first", "2026-11-01T05:30:00Z"),
            entry("second", "2026-11-01T06:30:00Z")
        ], timeZone: "America/New_York")
        #expect(value.days.count == 1)
        #expect(value.days[0].entries.map(\.id) == ["second", "first"])
    }

    @Test func timeZoneChangeRegroupsExistingEntries() {
        let entries = [entry("a", "2026-11-05T15:59:00Z"), entry("b", "2026-11-05T16:01:00Z")]
        #expect(timeline(entries).days.count == 2)
        #expect(timeline(entries, timeZone: "UTC").days.count == 1)
    }

    @Test func emptyHistoryAndInvalidDurationsRemainDisplayable() {
        #expect(timeline([]).visibleDays(limit: 100).isEmpty)
        let value = timeline([
            entry("a", "2026-11-05T01:00:00Z", seconds: .infinity),
            entry("b", "2026-11-05T01:00:00Z", seconds: -1),
            entry("c", "2026-11-05T01:00:00Z", seconds: 45)
        ])
        #expect(value.days[0].entries.map(\.id) == ["a", "b", "c"])
        #expect(value.days[0].listenedSeconds == 45)
    }

    @Test func automaticPaginationMovesItsTriggerAndStopsAtTheLastPage() throws {
        let entries = (0..<205).map { index in
            Entry(id: String(index), songID: "same-song", date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), seconds: 30)
        }
        let value = timeline(entries)
        let firstTrigger = try #require(value.paginationTriggerID(limit: 100))
        #expect(firstTrigger == "114")
        let secondTrigger = try #require(value.paginationTriggerID(limit: 200))
        #expect(secondTrigger == "14")
        #expect(firstTrigger != secondTrigger, "Reappearing rows from the previous page must not load another page")
        #expect(value.paginationTriggerID(limit: 205) == nil)
        #expect(value.paginationTriggerID(limit: 300) == nil)
        #expect(value.paginationTriggerID(limit: 0) == nil)
    }

    @Test func largeHistoryOnlyExposesTheRequestedPageAcrossDateBoundaries() throws {
        let entries = (0..<20_005).map { index in
            Entry(id: String(index), songID: "same-song", date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 600), seconds: 30)
        }
        let value = timeline(entries)
        #expect(value.count == 20_005)
        for limit in [100, 200, 1000] {
            let page = value.visibleDays(limit: limit)
            let rows = page.flatMap(\.entries)
            #expect(rows.count == limit)
            #expect(value.paginationTriggerID(limit: limit) == rows[limit - 10].id)
            #expect(Set(rows.map(\.id)).count == limit)
        }
        let lastPage = value.visibleDays(limit: 20_100)
        #expect(lastPage.flatMap(\.entries).count == 20_005)
        #expect(value.paginationTriggerID(limit: 20_100) == nil)
    }
}
