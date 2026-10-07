import XCTest
@testable import PrimuseKit

final class ListeningWidgetPolicyTests: XCTestCase {
    private func candidate(_ id: String, played: Double? = nil, published: Double = 0, finished: Bool = false) -> ListeningWidgetPolicy.Candidate {
        .init(item: .init(id: id, title: id, subtitle: "Show"),
              lastPlayedAt: played.map { Date(timeIntervalSince1970: $0) },
              publishedAt: Date(timeIntervalSince1970: published), isFinished: finished)
    }

    func testContinuesRecentUnfinishedBeforeNewEpisodesAndDeduplicates() {
        let selected = ListeningWidgetPolicy.select([
            candidate("new", published: 100), candidate("older", played: 50),
            candidate("recent", played: 70), candidate("recent", published: 60),
            candidate("finished", played: 90, finished: true), candidate("old", published: 1),
            candidate("overflow")
        ])
        XCTAssertEqual(selected.map(\.id), ["recent", "older", "new", "old"])
    }

    func testStableOrderAndRemovedItemsNeverRetained() {
        XCTAssertEqual(ListeningWidgetPolicy.select([candidate("b"), candidate("a")]).map(\.id), ["a", "b"])
        XCTAssertTrue(ListeningWidgetPolicy.select([]).isEmpty)
        XCTAssertTrue(ListeningWidgetPolicy.select([candidate("finished", finished: true)]).isEmpty)
    }

    func testMinimalScopeRemovesArtworkAndListeningProgressFromEncodedSnapshot() throws {
        let original = ListeningWidgetSnapshot(items: [.init(id: "id", title: "Episode", subtitle: "Show",
                                                             coverImageName: "cover.jpg", fractionComplete: 0.4)])
        let minimal = original.limited(to: .minimal)
        let data = try JSONEncoder().encode(minimal)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap((json["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["id", "title", "subtitle"])
        XCTAssertEqual(try JSONDecoder().decode(ListeningWidgetSnapshot.self, from: data), minimal)
        XCTAssertEqual(original.limited(to: .titleArtistCoverProgress), original)
    }

    func testInvalidProgressCannotBreakSnapshotEncoding() throws {
        let snapshot = ListeningWidgetSnapshot(items: [
            .init(id: "nan", title: "", subtitle: "", fractionComplete: .nan),
            .init(id: "infinite", title: "", subtitle: "", fractionComplete: .infinity),
            .init(id: "negative", title: "", subtitle: "", fractionComplete: -0.5),
            .init(id: "over", title: "", subtitle: "", fractionComplete: 1.5)
        ])
        XCTAssertEqual(snapshot.items.map(\.fractionComplete), [nil, nil, 0, 1])
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }
}
