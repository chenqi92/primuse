import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playlist member order policy")
struct PlaylistMemberOrderPolicyTests {
    @Test("Sync forwarding keeps unresolved identities in their original slots and retains legacy pending entries")
    func forwardingPreservesPendingPositions() {
        func identity(_ id: String, title: String = "") -> SongIdentity {
            SongIdentity(songID: id, title: title, artistName: nil, duration: 180,
                         cloudAccountID: nil, filePath: "/\(id).flac")
        }
        let first = identity("c", title: "Charlie")
        let middle = identity("a", title: "Alpha")
        let last = identity("b", title: "Bravo")
        let legacy = identity("legacy", title: "Legacy")
        let result = PlaylistMemberOrderPolicy.syncIdentities(
            [identity("c"), middle, identity("b"), middle],
            pending: [first, last, legacy, first]
        )
        #expect(result == [first, middle, last, legacy])
    }

    @Test("Moving one song to the top keeps everything else in order")
    func movesOneSongToTop() {
        let result = PlaylistMemberOrderPolicy.movingToTop(["a", "b", "c", "d"], selected: ["c"])
        #expect(result == ["c", "a", "b", "d"])
    }

    @Test("Several songs move to the top in their playlist order, not the order they were picked")
    func movesSeveralSongsKeepingTheirRelativeOrder() {
        let members = ["a", "b", "c", "d", "e", "f", "g"]
        let result = PlaylistMemberOrderPolicy.movingToTop(members, selected: ["f", "b", "d"])
        #expect(result == ["b", "d", "f", "a", "c", "e", "g"])
    }

    @Test("The latest pin goes above the earlier ones")
    func latestPinGoesFirst() {
        let once = PlaylistMemberOrderPolicy.movingToTop(["a", "b", "c", "d"], selected: ["c"])
        let twice = PlaylistMemberOrderPolicy.movingToTop(once, selected: ["d"])
        #expect(twice == ["d", "c", "a", "b"])
    }

    @Test("Hidden members such as grayed entries stay and keep their order")
    func hiddenMembersStay() {
        let members = ["pending:1", "a", "episode", "b", "disabled-source", "c"]
        let result = PlaylistMemberOrderPolicy.movingToTop(members, selected: ["c"])
        #expect(result == ["c", "pending:1", "a", "episode", "b", "disabled-source"])
    }

    @Test("Ids that are not in the playlist are ignored and an empty pick changes nothing")
    func ignoresStrangersAndEmptyPicks() {
        let members = ["a", "b", "c"]
        let strangers = PlaylistMemberOrderPolicy.movingToTop(members, selected: ["x"])
        let empty = PlaylistMemberOrderPolicy.movingToTop(members, selected: [String]())
        let alreadyFirst = PlaylistMemberOrderPolicy.movingToTop(members, selected: ["a"])
        #expect(strangers == members)
        #expect(empty == members)
        #expect(alreadyFirst == members)
    }

    @Test("Reordering the listed songs keeps unlisted members in their slots")
    func reorderKeepsUnlistedSlots() {
        let members = ["a", "pending:1", "b", "disabled-source", "c"]
        let result = PlaylistMemberOrderPolicy.reordered(members, listedOrder: ["c", "a", "b"])
        #expect(result == ["c", "pending:1", "a", "disabled-source", "b"])
    }

    @Test("A reorder that lists everything is taken as is")
    func reorderListingEverything() {
        let result = PlaylistMemberOrderPolicy.reordered(["a", "b", "c"], listedOrder: ["b", "c", "a"])
        #expect(result == ["b", "c", "a"])
    }

    @Test("A reorder never adds strangers or duplicates and an empty list changes nothing")
    func reorderIgnoresStrangersAndDuplicates() {
        let members = ["a", "b", "c"]
        let result = PlaylistMemberOrderPolicy.reordered(members, listedOrder: ["c", "x", "c", "a"])
        let empty = PlaylistMemberOrderPolicy.reordered(members, listedOrder: [])
        #expect(result == ["c", "b", "a"])
        #expect(empty == members)
    }

    @Test("A server favorites refresh keeps the songs that stay liked where they are")
    func serverRefreshKeepsPositions() {
        // s1、s2 是这个源的歌，用户把 s2 置顶过；l1、l2 是本机或别的源的歌。
        let members = ["s2", "l1", "s1", "l2"]
        let source: Set<String> = ["s1", "s2", "s3", "s4"]
        let result = PlaylistMemberOrderPolicy.syncingSourceMembers(
            members,
            authoritative: ["s1", "s4", "s2", "s3"]
        ) { source.contains($0) }
        #expect(result == ["s2", "l1", "s1", "l2", "s4", "s3"])
    }

    @Test("A server favorites refresh drops the songs the server no longer stars")
    func serverRefreshDropsUnstarred() {
        let members = ["s2", "l1", "s1", "l2"]
        let source: Set<String> = ["s1", "s2"]
        let dropped = PlaylistMemberOrderPolicy.syncingSourceMembers(
            members,
            authoritative: ["s1"]
        ) { source.contains($0) }
        let emptied = PlaylistMemberOrderPolicy.syncingSourceMembers(
            members,
            authoritative: []
        ) { source.contains($0) }
        #expect(dropped == ["l1", "s1", "l2"])
        #expect(emptied == ["l1", "l2"])
    }

    @Test("An unchanged server favorites refresh changes nothing")
    func unchangedServerRefresh() {
        let members = ["s2", "l1", "s1"]
        let source: Set<String> = ["s1", "s2"]
        let result = PlaylistMemberOrderPolicy.syncingSourceMembers(
            members,
            authoritative: ["s1", "s2", "s1"]
        ) { source.contains($0) }
        #expect(result == members)
    }
}

@Suite("Playlist pinned songs policy")
struct PlaylistPinnedSongsPolicyTests {
    @Test("Pinned songs stay on top of any sort order, in pin order, and the rest keep the sort")
    func pinnedSongsLeadEverySort() {
        let byTitle = ["a", "b", "c", "d", "e"]
        let byDuration = ["e", "c", "a", "d", "b"]
        let pinned = ["d", "b"]
        let titleResult = PlaylistPinnedSongsPolicy.pinnedFirst(byTitle, pinned: pinned) { $0 }
        let durationResult = PlaylistPinnedSongsPolicy.pinnedFirst(byDuration, pinned: pinned) { $0 }
        #expect(titleResult == ["d", "b", "a", "c", "e"])
        #expect(durationResult == ["d", "b", "e", "c", "a"])
    }

    @Test("Newest-first date order puts pins on top and keeps the rest newest first")
    func pinnedSongsLeadReversedAddedOrder() {
        let members = ["old", "pinned", "mid", "new"]
        let newestFirst = Array(members.reversed())
        let result = PlaylistPinnedSongsPolicy.pinnedFirst(newestFirst, pinned: ["pinned"]) { $0 }
        #expect(result == ["pinned", "new", "mid", "old"])
    }

    @Test("Unpinning returns the song to its sorted place because members never moved")
    func unpinningRestoresSortedPlace() {
        let members = ["a", "b", "c", "d"]
        let pinned = PlaylistPinnedSongsPolicy.pinning(["c"], pinned: [], memberIDs: members)
        let pinnedOrder = PlaylistPinnedSongsPolicy.pinnedFirst(members, pinned: pinned) { $0 }
        let unpinned = PlaylistPinnedSongsPolicy.unpinning(["c"], pinned: pinned)
        let restored = PlaylistPinnedSongsPolicy.pinnedFirst(members, pinned: unpinned) { $0 }
        #expect(pinned == ["c"])
        #expect(pinnedOrder == ["c", "a", "b", "d"])
        #expect(unpinned.isEmpty)
        #expect(restored == members)
    }

    @Test("The latest pin goes above earlier ones; several picks keep their playlist order")
    func pinOrder() {
        let members = ["a", "b", "c", "d", "e"]
        let first = PlaylistPinnedSongsPolicy.pinning(["c"], pinned: [], memberIDs: members)
        let second = PlaylistPinnedSongsPolicy.pinning(["e", "b"], pinned: first, memberIDs: members)
        let repinned = PlaylistPinnedSongsPolicy.pinning(["c"], pinned: second, memberIDs: members)
        #expect(first == ["c"])
        #expect(second == ["b", "e", "c"])
        #expect(repinned == ["c", "b", "e"])
    }

    @Test("Pinning ignores strangers and drops pins of songs that left the playlist")
    func pinningIgnoresStrangers() {
        let members = ["a", "b", "c"]
        let stranger = PlaylistPinnedSongsPolicy.pinning(["x"], pinned: ["b"], memberIDs: members)
        let pruned = PlaylistPinnedSongsPolicy.pinning(["a"], pinned: ["gone", "b", "b"], memberIDs: members)
        let alreadyFirst = PlaylistPinnedSongsPolicy.pinning(["b"], pinned: ["b", "c"], memberIDs: members)
        #expect(stranger == ["b"])
        #expect(pruned == ["a", "b"])
        #expect(alreadyFirst == ["b", "c"])
    }

    @Test("Effective pins skip songs that are no longer members")
    func effectivePins() {
        let result = PlaylistPinnedSongsPolicy.effective(["gone", "b", "a", "b"], memberIDs: ["a", "b", "c"])
        #expect(result == ["b", "a"])
    }

    @Test("Without pinned songs in the list the order is returned untouched")
    func noPinsKeepsOrder() {
        let ordered = ["a", "b", "c"]
        let noPins = PlaylistPinnedSongsPolicy.pinnedFirst(ordered, pinned: []) { $0 }
        let strangerPins = PlaylistPinnedSongsPolicy.pinnedFirst(ordered, pinned: ["x"]) { $0 }
        #expect(noPins == ordered)
        #expect(strangerPins == ordered)
    }

    @Test("Reordering moves pins among themselves while members only reorder unpinned songs")
    func reorderingKeepsPinsApart() {
        let pinned = ["c", "a"]
        let listed = ["a", "c", "d", "b"]
        let newPins = PlaylistPinnedSongsPolicy.reordered(pinned, listedOrder: listed)
        let unpinnedListed = PlaylistPinnedSongsPolicy.unpinnedListedOrder(listed, pinned: pinned)
        let members = PlaylistMemberOrderPolicy.reordered(["a", "b", "c", "d"], listedOrder: unpinnedListed)
        #expect(newPins == ["a", "c"])
        #expect(unpinnedListed == ["d", "b"])
        #expect(members == ["a", "d", "c", "b"])
    }

    @Test("Another device's pins translate through the shared identities")
    func translatesRemotePins() {
        let result = PlaylistPinnedSongsPolicy.translated(
            ["remote-c", "remote-unknown", "remote-a", "remote-a2"],
            localIDs: ["remote-c": "local-c", "remote-a": "local-a", "remote-a2": "local-a"]
        )
        #expect(result == ["local-c", "local-a"])
    }

    @Test("Pinned songs survive a playlist record round trip and old records decode without pins")
    func codableRoundTrip() throws {
        let playlist = Playlist(id: "p", name: "P", pinnedSongIDs: ["b", "a"])
        let data = try JSONEncoder().encode(playlist)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(decoded.pinnedSongIDs == ["b", "a"])

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pinnedSongIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(Playlist.self, from: legacyData)
        #expect(legacy.pinnedSongIDs.isEmpty)
    }
}
