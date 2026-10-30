import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playlist grouping")
struct PlaylistGroupingTests {
    @Test func roundTripPreservesUnloadedPlaylistsAndKinds() throws {
        var grouping = PlaylistGrouping()
        let created = grouping.create(name: "  通勤  ")
        let commute = try #require(created)
        let ordinary = PlaylistGrouping.reference(id: "same")
        let smart = PlaylistGrouping.reference(id: "same", smart: true)
        grouping.move([ordinary, "playlist:not-loaded-on-this-device"], to: commute)
        let restored = PlaylistGrouping.decode(grouping.encoded())
        #expect(restored == grouping)
        #expect(restored.groups.first?.name == "通勤")
        #expect(restored.groupID(for: ordinary) == commute)
        #expect(restored.groupID(for: smart) == nil)
        #expect(restored.groupID(for: "playlist:not-loaded-on-this-device") == commute)
    }

    @Test func movingReplacesOneGroupAndDissolvingKeepsOtherGroups() throws {
        var grouping = PlaylistGrouping()
        let createdFirst = grouping.create(name: "通勤")
        let first = try #require(createdFirst)
        let createdSecond = grouping.create(name: "学习")
        let second = try #require(createdSecond)
        grouping.move(["a", "b"], to: first)
        grouping.move(["a"], to: second)
        grouping.move(["b"], to: "missing-group")
        #expect(grouping.groupID(for: "a") == second)
        #expect(grouping.groupID(for: "b") == first)
        grouping.dissolve(id: first)
        #expect(grouping.groupID(for: "a") == second)
        #expect(grouping.groupID(for: "b") == nil)
        #expect(grouping.groups.map(\.id) == [second])
        grouping.move(["a"], to: nil)
        #expect(grouping.memberships.isEmpty)
    }

    @Test func namesAreValidatedWithoutLosingAssignments() throws {
        var grouping = PlaylistGrouping()
        let created = grouping.create(name: "Focus")
        let id = try #require(created)
        let duplicate = grouping.create(name: " focus ")
        let empty = grouping.create(name: " \n ")
        #expect(duplicate == nil)
        #expect(empty == nil)
        grouping.move(["a"], to: id)
        grouping.rename(id: id, name: " Study ")
        #expect(grouping.groups.first?.name == "Study")
        #expect(grouping.groupID(for: "a") == id)
        grouping.rename(id: id, name: " ")
        #expect(grouping.groups.first?.name == "Study")
        #expect(PlaylistGrouping.decode("invalid").groups.isEmpty)
    }
}
