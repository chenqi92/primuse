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

    private func heard(_ id: String, position: Double? = nil, listened: Double? = nil,
                       finished: Double? = nil) -> (item: ListeningWidgetSnapshot.Item, record: ListeningWidgetPolicy.ListeningRecord) {
        (.init(id: id, title: id, subtitle: "Show"),
         .init(positionSavedAt: position.map { Date(timeIntervalSince1970: $0) },
               lastListenedAt: listened.map { Date(timeIntervalSince1970: $0) },
               finishedAt: finished.map { Date(timeIntervalSince1970: $0) }))
    }

    func testRecentlyPlayedListsHeardEpisodesNewestFirstIncludingFinished() {
        let recent = ListeningWidgetPolicy.recentlyPlayed([
            heard("in-progress", position: 100),
            heard("finished", listened: 50, finished: 120),
            heard("marked-played", finished: 200),
            heard("never"),
            heard("resumed", position: 90, listened: 80),
            heard("in-progress", listened: 10)
        ])
        XCTAssertEqual(recent.map(\.id), ["finished", "in-progress", "resumed"])
        XCTAssertEqual(ListeningWidgetPolicy.recentlyPlayed((0..<6).map { heard("e\($0)", listened: Double($0)) }).map(\.id),
                       ["e5", "e4", "e3", "e2"])
        XCTAssertEqual(ListeningWidgetPolicy.recentlyPlayed([heard("b", position: 5), heard("a", listened: 5)]).map(\.id),
                       ["a", "b"])
    }

    func testRecentPodcastsAddAWidgetWithoutMovingTheExistingOnes() {
        XCTAssertEqual(ListeningWidgetKind(rawValue: "podcast"), .podcast)
        XCTAssertEqual(ListeningWidgetKind(rawValue: "radio"), .radio)
        XCTAssertEqual(ListeningWidgetKind.podcast.widgetKind, "PodcastWidget")
        XCTAssertEqual(ListeningWidgetKind.radio.widgetKind, "RadioWidget")
        XCTAssertEqual(ListeningWidgetKind.recentPodcast.widgetKind, "RecentPodcastWidget")
        XCTAssertTrue(ListeningWidgetKind.recentPodcast.playsEpisodes)
        XCTAssertFalse(ListeningWidgetKind.radio.playsEpisodes)
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
