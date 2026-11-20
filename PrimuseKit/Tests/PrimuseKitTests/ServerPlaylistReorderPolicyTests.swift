import Foundation
import Testing
@testable import PrimuseKit

@Suite("Server playlist reorder policy")
struct ServerPlaylistReorderPolicyTests {
    private func reordered(_ members: [String], _ listed: [String]) -> [String]? {
        ServerPlaylistReorderPolicy.reorderedPositions(memberIDs: members, listedOrder: listed)
            .map { $0.map { members[$0] } }
    }

    private func firstOccurrences(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    @Test("Listed songs take the new order and unchanged orders write nothing")
    func basicReorder() {
        #expect(reordered(["a", "b", "c", "d"], ["c", "a", "b", "d"]) == ["c", "a", "b", "d"])
        #expect(reordered(["a", "b", "c"], ["a", "b", "c"]) == nil)
        #expect(reordered(["a", "b", "c"], []) == nil)
        #expect(reordered(["a", "b", "c"], ["x", "c", "c", "b", "a"]) == ["c", "b", "a"])
    }

    @Test("Entries hidden on this device keep their place on the server")
    func hiddenEntriesStay() {
        #expect(reordered(["hidden", "a", "b", "disabled", "c"], ["c", "b", "a"]) == ["hidden", "c", "b", "disabled", "a"])
    }

    @Test("Duplicates are kept and never end up ahead of their song's new place")
    func duplicatesFollowTheirSong() {
        #expect(reordered(["a", "b", "a", "c", "d"], ["b", "c", "d", "a"]) == ["b", "c", "d", "a", "a"])
        #expect(reordered(["a", "b", "c", "a"], ["b", "a", "c"]) == ["b", "a", "c", "a"])
        #expect(reordered(["a", "a", "b"], ["b", "a"]) == ["b", "a", "a"])
    }

    @Test("Any reorder is a permutation of the server list and reads back in the listed order")
    func randomReordersStayPermutations() {
        var generator = ReorderTestGenerator(seed: 0x449)
        for _ in 0..<300 {
            let alphabet = (0..<Int.random(in: 1...8, using: &generator)).map { "s\($0)" }
            let members = (0..<Int.random(in: 1...14, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let unique = firstOccurrences(members)
            let listed = unique.filter { _ in Bool.random(using: &generator) }.shuffled(using: &generator)
            guard let positions = ServerPlaylistReorderPolicy.reorderedPositions(memberIDs: members, listedOrder: listed) else {
                #expect(firstOccurrences(members).filter(listed.contains) == listed)
                continue
            }
            #expect(positions.sorted() == Array(members.indices))
            let result = positions.map { members[$0] }
            #expect(ServerPlaylistReorderPolicy.isPermutation(result, of: members))
            let shown = firstOccurrences(result)
            #expect(shown.filter(listed.contains) == listed)
            // 没列出来的彼此先后不变。
            let hidden = Set(unique).subtracting(listed)
            #expect(shown.filter(hidden.contains) == unique.filter(hidden.contains))
        }
    }

    @Test("Permutation check counts duplicates")
    func permutationCountsDuplicates() {
        #expect(ServerPlaylistReorderPolicy.isPermutation(["a", "b", "a"], of: ["a", "a", "b"]))
        #expect(!ServerPlaylistReorderPolicy.isPermutation(["a", "b", "b"], of: ["a", "a", "b"]))
        #expect(!ServerPlaylistReorderPolicy.isPermutation(["a", "b"], of: ["a", "a", "b"]))
        #expect(ServerPlaylistReorderPolicy.isPermutation([], of: []))
    }

    @Test("Track multiset ignores order and counts duplicates")
    func trackMultiset() {
        typealias Multiset = ServerPlaylistReorderPolicy.TrackMultiset
        #expect(Multiset(["a", "b", "a"]) == Multiset(["a", "a", "b"]))
        #expect(Multiset(["a", "b", "a"]) != Multiset(["a", "b", "b"]))
        #expect(Multiset(["a", "b", "a"]) != Multiset(["a", "b"]))
        #expect(Multiset(["a", "b", "a"]).count == 3)
    }

    @Test("A server changed elsewhere does not match the mirror")
    func serverMatchesMirror() {
        let recorded = ServerPlaylistReorderPolicy.TrackMultiset(["1", "2", "2"])
        #expect(ServerPlaylistReorderPolicy.serverMatchesMirror(
            serverTrackIDs: ["2", "1", "2"], serverMemberIDs: ["b", "a", "b"],
            recorded: recorded, mirrorMemberIDs: ["a", "b"]))
        // 别处又加了一份重复项: 成员一样, 多重集不一样。
        #expect(!ServerPlaylistReorderPolicy.serverMatchesMirror(
            serverTrackIDs: ["1", "2", "2", "2"], serverMemberIDs: ["a", "b", "b", "b"],
            recorded: recorded, mirrorMemberIDs: ["a", "b"]))
        // 没记过摘要时只比成员。
        #expect(ServerPlaylistReorderPolicy.serverMatchesMirror(
            serverTrackIDs: ["1", "2", "2", "2"], serverMemberIDs: ["a", "b", "b", "b"],
            recorded: nil, mirrorMemberIDs: ["b", "a"]))
        #expect(!ServerPlaylistReorderPolicy.serverMatchesMirror(
            serverTrackIDs: ["1", "2", "3"], serverMemberIDs: ["a", "b", "c"],
            recorded: nil, mirrorMemberIDs: ["a", "b"]))
        #expect(!ServerPlaylistReorderPolicy.serverMatchesMirror(
            serverTrackIDs: ["1"], serverMemberIDs: ["a"],
            recorded: nil, mirrorMemberIDs: ["a", "b"]))
    }

    private func applying(_ step: ServerPlaylistReorderPolicy.MoveToEndStep, to list: [String]) -> [String] {
        let removed = Set(step.removedIndices)
        return list.indices.filter { !removed.contains($0) }.map { list[$0] } + step.appendedIDs
    }

    @Test("Move-to-end steps keep the in-order head and move each batch in one request")
    func moveToEndSteps() throws {
        let steps = try #require(ServerPlaylistReorderPolicy.moveToEndSteps(
            from: ["a", "b", "c", "d"], to: ["d", "a", "b", "c"], batchSize: 2))
        #expect(steps.map(\.removedIndices) == [[1, 0], [0]])
        #expect(steps.map(\.appendedIDs) == [["a", "b"], ["c"]])
        #expect(steps.map(\.expectedTrackIDs) == [["c", "d", "a", "b"], ["d", "a", "b", "c"]])
        #expect(ServerPlaylistReorderPolicy.moveToEndSteps(from: ["a", "b"], to: ["a", "b"], batchSize: 2) == [])
        #expect(ServerPlaylistReorderPolicy.moveToEndSteps(from: ["a", "b"], to: ["a", "c"], batchSize: 2) == nil)
        #expect(ServerPlaylistReorderPolicy.moveToEndSteps(from: ["a", "b"], to: ["b", "a"], batchSize: 0) == nil)
    }

    @Test("Every move-to-end step keeps the same songs and the last one reaches the target")
    func randomMoveToEndSteps() throws {
        var generator = ReorderTestGenerator(seed: 0x162)
        for _ in 0..<200 {
            let alphabet = (0..<Int.random(in: 1...6, using: &generator)).map { "t\($0)" }
            let current = (0..<Int.random(in: 0...16, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let target = current.shuffled(using: &generator)
            let batchSize = Int.random(in: 1...5, using: &generator)
            let steps = try #require(ServerPlaylistReorderPolicy.moveToEndSteps(from: current, to: target, batchSize: batchSize))
            var list = current
            for step in steps {
                #expect(step.appendedIDs.count <= batchSize)
                #expect(step.removedIndices == step.removedIndices.sorted(by: >))
                #expect(step.removedIndices.map { list[$0] }.sorted() == step.appendedIDs.sorted())
                list = applying(step, to: list)
                #expect(list == step.expectedTrackIDs)
                #expect(ServerPlaylistReorderPolicy.isPermutation(list, of: current))
            }
            #expect(list == target)
        }
    }
}

/// 可复现的随机数: 用例失败时每次都是同一组输入。
private struct ReorderTestGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
