import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playlist list order")
struct PlaylistListOrderTests {
    private func playlist(
        _ id: String,
        name: String? = nil,
        created: TimeInterval = 0,
        updated: TimeInterval = 0
    ) -> Playlist {
        Playlist(
            id: id,
            name: name ?? id,
            createdAt: Date(timeIntervalSince1970: 1_000_000 + created),
            updatedAt: Date(timeIntervalSince1970: 1_000_000 + updated)
        )
    }

    private func ids(_ order: PlaylistListOrder, _ playlists: [Playlist], counts: [String: Int] = [:]) -> [String] {
        order.sorted(playlists) { counts[$0] ?? 0 }.map(\.id)
    }

    @Test("Custom order keeps the manual order it is given")
    func customKeepsInputOrder() {
        let playlists = [playlist("c"), playlist("a"), playlist("b")]
        #expect(ids(.custom, playlists) == ["c", "a", "b"])
    }

    @Test("Name order ignores case and puts blank names last in both directions")
    func nameOrder() {
        let playlists = [
            playlist("1", name: "rock"),
            playlist("2", name: " "),
            playlist("3", name: "Ambient"),
            playlist("4", name: "jazz"),
        ]
        #expect(ids(.name, playlists) == ["3", "4", "1", "2"])
        #expect(ids(.nameDescending, playlists) == ["1", "4", "3", "2"])
    }

    @Test("Date orders read creation and update times separately")
    func dateOrders() {
        let playlists = [
            playlist("old", created: 10, updated: 300),
            playlist("new", created: 30, updated: 100),
            playlist("mid", created: 20, updated: 200),
        ]
        #expect(ids(.dateAdded, playlists) == ["new", "mid", "old"])
        #expect(ids(.dateAddedOldest, playlists) == ["old", "mid", "new"])
        #expect(ids(.dateUpdated, playlists) == ["old", "mid", "new"])
        #expect(ids(.dateUpdatedOldest, playlists) == ["new", "mid", "old"])
    }

    @Test("Song count order uses the counts it is handed and keeps ties in manual order")
    func songCountOrder() {
        let playlists = [playlist("a"), playlist("b"), playlist("c"), playlist("d")]
        let counts = ["a": 5, "b": 12, "c": 5, "d": 0]
        #expect(ids(.songCount, playlists, counts: counts) == ["b", "a", "c", "d"])
        #expect(ids(.songCountFewest, playlists, counts: counts) == ["d", "a", "c", "b"])
    }

    @Test("Choosing a criterion starts from its natural direction and keeps the current one on reselect")
    func selectingAndDirection() {
        #expect(PlaylistListOrder.custom.selecting(.name) == .name)
        #expect(PlaylistListOrder.custom.selecting(.dateAdded) == .dateAdded)
        #expect(PlaylistListOrder.custom.selecting(.songCount) == .songCount)
        #expect(PlaylistListOrder.nameDescending.selecting(.name) == .nameDescending)
        #expect(PlaylistListOrder.nameDescending.selecting(nil) == .custom)
        #expect(PlaylistListOrder.dateAdded.withAscending(true) == .dateAddedOldest)
        #expect(PlaylistListOrder.dateUpdatedOldest.withAscending(false) == .dateUpdated)
        #expect(PlaylistListOrder.songCount.withAscending(true) == .songCountFewest)
        #expect(PlaylistListOrder.custom.withAscending(false) == .custom)
        for order in PlaylistListOrder.allCases {
            #expect(order.withAscending(order.isAscending) == order)
            #expect(PlaylistListOrder.defaultOrder(for: order.criterion).criterion == order.criterion)
        }
    }

    @Test("Unknown stored values fall back to the custom order")
    func resolvedFallsBack() {
        #expect(PlaylistListOrder.resolved("songCountFewest") == .songCountFewest)
        #expect(PlaylistListOrder.resolved("") == .custom)
        #expect(PlaylistListOrder.resolved("bogus") == .custom)
    }
}
