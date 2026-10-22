import Testing
@testable import PrimuseKit

@Suite("Playlist member order policy")
struct PlaylistMemberOrderPolicyTests {
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
