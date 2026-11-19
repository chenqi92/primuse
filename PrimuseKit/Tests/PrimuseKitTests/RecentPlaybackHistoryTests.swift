import XCTest
@testable import PrimuseKit

final class RecentPlaybackHistoryTests: XCTestCase {
    func testMixedKindsDeduplicateByEntityAndKeepNewestFirst() {
        let date = Date(timeIntervalSince1970: 100)
        let items: [RecentPlaybackItem] = [
            .init(kind: .album, entityID: "same", playedAt: date),
            .init(kind: .playlist, entityID: "same", playedAt: date.addingTimeInterval(2)),
            .init(kind: .song, entityID: "song", playedAt: date.addingTimeInterval(1)),
            .init(kind: .album, entityID: "same", playedAt: date.addingTimeInterval(3)),
            .init(kind: .artist, entityID: "artist", playedAt: date.addingTimeInterval(4))
        ]
        let result = RecentPlaybackHistory.merging(items)
        XCTAssertEqual(result.map(\.kind), [.artist, .album, .playlist, .song])
        XCTAssertEqual(result[1].playedAt, date.addingTimeInterval(3))
    }

    func testBoundedHistorySurvivesEncodingWithoutQueuePayloads() throws {
        let items = (0..<100).map {
            RecentPlaybackItem(kind: .playlist, entityID: "p\($0)", playedAt: Date(timeIntervalSince1970: Double($0)))
        }
        let history = RecentPlaybackHistory.merging(items)
        XCTAssertEqual(history.count, 40)
        XCTAssertEqual(history.first?.entityID, "p99")
        let data = try JSONEncoder().encode(history)
        XCTAssertLessThan(data.count, 10_000)
        XCTAssertEqual(try JSONDecoder().decode([RecentPlaybackItem].self, from: data), history)
    }
}
