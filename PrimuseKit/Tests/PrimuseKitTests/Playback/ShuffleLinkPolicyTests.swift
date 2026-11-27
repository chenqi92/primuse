import Foundation
import Testing
@testable import PrimuseKit

@Suite("Shuffle linked songs (#335)")
struct ShuffleLinkPolicyTests {
    /// SplitMix64: 同一个种子每次给出同一串数。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 专辑 a1…a5 里 a2 接着放 a3、a4 先放 a3(于是 a2 → a3 → a4 连成一串), b1 接着放 b2。
    private static let graph = ShuffleLinkGraph(
        nextLinks: ["a2": "a3", "b1": "b2"],
        previousLinks: ["a4": "a3"]
    )

    private static func isContiguous(_ run: [String], in order: [String]) -> Bool {
        guard let start = order.firstIndex(of: run[0]), start + run.count <= order.count else { return false }
        return Array(order[start..<(start + run.count)]) == run
    }

    @Test("Either switch links the two album neighbours in album order")
    func graphFromBothDirections() {
        let graph = Self.graph
        #expect(graph.isLinked("a2", to: "a3"))
        #expect(graph.isLinked("a3", to: "a4"))
        #expect(graph.successor(of: "a4") == nil)
        #expect(graph.predecessor(of: "a3") == "a2")
        #expect(graph.brings("a2", .next))
        #expect(!graph.brings("a3", .next))
        #expect(graph.brings("a4", .previous))
        #expect(!graph.brings("a3", .previous))
        #expect(!graph.isEmpty)
        #expect(ShuffleLinkGraph.empty.isEmpty)
    }

    @Test("Both switches on one pair make a single link")
    func bothSwitchesOnOnePair() {
        let graph = ShuffleLinkGraph(nextLinks: ["x": "y"], previousLinks: ["y": "x"])
        #expect(graph.isLinked("x", to: "y"))
        #expect(graph.brings("x", .next))
        #expect(graph.brings("y", .previous))
    }

    @Test("Conflicting or circular links are dropped instead of looping")
    func conflictsAndCycles() {
        let conflicting = ShuffleLinkGraph(nextLinks: ["a": "b", "c": "b"], previousLinks: [:])
        #expect(conflicting.isLinked("a", to: "b"))
        #expect(conflicting.successor(of: "c") == nil)
        let circular = ShuffleLinkGraph(nextLinks: ["a": "b", "b": "a", "s": "s"], previousLinks: [:])
        #expect(circular.isLinked("a", to: "b"))
        #expect(circular.successor(of: "b") == nil)
        #expect(circular.successor(of: "s") == nil)
        let units = ShuffleLinkPolicy.units(["b", "a"], graph: circular, id: { $0 })
        #expect(units == [["a", "b"]])
    }

    @Test("Units group linked songs in order, the rest one by one")
    func unitsGroupChains() {
        let units = ShuffleLinkPolicy.units(["a4", "x", "a2", "b2", "a3", "b1"], graph: Self.graph, id: { $0 })
        #expect(units == [["a2", "a3", "a4"], ["x"], ["b1", "b2"]])
    }

    @Test("A missing middle song breaks the chain where it is missing")
    func missingMiddleSong() {
        let units = ShuffleLinkPolicy.units(["a2", "a4", "x"], graph: Self.graph, id: { $0 })
        #expect(units == [["a2"], ["a4"], ["x"]])
    }

    @Test("Only the first copy of a repeated song takes part in a link")
    func repeatedSongs() {
        let units = ShuffleLinkPolicy.units(["b1", "b1", "b2"], graph: Self.graph, id: { $0 })
        #expect(units == [["b1", "b2"], ["b1"]])
    }

    @Test("Shuffling keeps every song once and every chain together")
    func shuffleKeepsChains() {
        let songs = ["a1", "a2", "a3", "a4", "a5", "b1", "b2"] + (0..<30).map { "s\($0)" }
        for seed in 0..<40 {
            var generator = SeededGenerator(state: UInt64(seed))
            let order = ShuffleLinkPolicy.shuffled(songs, graph: Self.graph, id: { $0 }) {
                $0.shuffled(using: &generator)
            }
            #expect(order.count == songs.count)
            #expect(Set(order) == Set(songs))
            #expect(Self.isContiguous(["a2", "a3", "a4"], in: order))
            #expect(Self.isContiguous(["b1", "b2"], in: order))
        }
    }

    @Test("The shuffle only orders block heads")
    func shuffleSeesHeads() {
        var seen: [String] = []
        let order = ShuffleLinkPolicy.shuffled(["a3", "x", "a2", "a4"], graph: Self.graph, id: { $0 }) { heads in
            seen = heads
            return heads.reversed()
        }
        #expect(seen == ["a2", "x"])
        #expect(order == ["x", "a2", "a3", "a4"])
    }

    @Test("The lead and what follows it go first; songs before it shuffle on their own")
    func leadStartsTheOrder() {
        let order = ShuffleLinkPolicy.shuffled(["a2", "a3", "a4", "x", "y"], graph: Self.graph, id: { $0 },
                                               leading: "a3") { $0.reversed() }
        #expect(Array(order.prefix(2)) == ["a3", "a4"])
        #expect(Set(order) == ["a2", "a3", "a4", "x", "y"])
        #expect(order.count == 5)
        let unlinked = ShuffleLinkPolicy.shuffled(["x", "y", "z"], graph: Self.graph, id: { $0 },
                                                  leading: "z") { $0 }
        #expect(unlinked == ["z", "x", "y"])
    }

    @Test("Queue positions with repeated songs stay a permutation")
    func positionsWithRepeats() {
        let ids = ["b1", "x", "b2", "b1", "x"]
        let order = ShuffleLinkPolicy.shuffled(Array(ids.indices), graph: Self.graph, id: { ids[$0] },
                                               leading: 3) { $0.reversed() }
        #expect(order.sorted() == Array(ids.indices))
        #expect(order.first == 3)
        let first = order.firstIndex(of: 0)!
        #expect(order[first + 1] == 2)
    }

    @Test("A switched-on song brings its neighbour along, the other side does not")
    func bringsByDirection() {
        let includeAll: (String) -> Bool = { _ in true }
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["x", "a2"], graph: Self.graph, includes: includeAll)
            == ["x", "a2", "a3"])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["a4"], graph: Self.graph, includes: includeAll)
            == ["a3", "a4"])
        // a3 自己没开开关: 只抽到它时谁也不带。
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["a3"], graph: Self.graph, includes: includeAll) == ["a3"])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["b2"], graph: Self.graph, includes: includeAll) == ["b2"])
    }

    @Test("Bringing follows switches along the chain and respects exclusions")
    func bringsAlongChain() {
        let graph = ShuffleLinkGraph(nextLinks: ["t1": "t2", "t2": "t3"], previousLinks: [:])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["t1"], graph: graph, includes: { _ in true })
            == ["t1", "t2", "t3"])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["t1"], graph: graph, excluding: ["t2"], includes: { _ in true })
            == ["t1"])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["t1"], graph: graph, includes: { $0 != "t3" })
            == ["t1", "t2"])
        #expect(ShuffleLinkPolicy.bringingLinkedSongs(["t1", "t2"], graph: graph, includes: { _ in true })
            == ["t1", "t2", "t3"])
    }

    @Test("A prefix never cuts a chain in half")
    func prefixKeepsChains() {
        let order = ["x", "a2", "a3", "a4", "y"]
        #expect(Array(ShuffleLinkPolicy.prefix(order, maxCount: 2, graph: Self.graph, id: { $0 })) == ["x", "a2", "a3", "a4"])
        #expect(Array(ShuffleLinkPolicy.prefix(order, maxCount: 1, graph: Self.graph, id: { $0 })) == ["x"])
        #expect(Array(ShuffleLinkPolicy.prefix(order, maxCount: 9, graph: Self.graph, id: { $0 })) == order)
        #expect(Array(ShuffleLinkPolicy.prefix(order, maxCount: 2, graph: .empty, id: { $0 })) == ["x", "a2"])
    }

    @Test("Appended blocks join an upcoming neighbour, never before the playing slot")
    func appendingJoinsUpcoming() {
        // 正在放 p(位置 1), a2 还没放到: 新来的 a3 a4 接到 a2 后面。
        let joined = ShuffleLinkPolicy.appending(["y", "a3", "a4"], to: ["h", "p", "a2", "z"], anchor: 1,
                                                 graph: Self.graph, id: { $0 })
        #expect(joined == ["h", "p", "a2", "a3", "a4", "z", "y"])
        // b2 还没放到: 新来的 b1 插在它前面。
        let before = ShuffleLinkPolicy.appending(["b1"], to: ["p", "x", "b2"], anchor: 0,
                                                 graph: Self.graph, id: { $0 })
        #expect(before == ["p", "x", "b1", "b2"])
        // 正在放的就是 a2: 接在它后面。
        let afterCurrent = ShuffleLinkPolicy.appending(["q", "a3"], to: ["h", "a2"], anchor: 1,
                                                       graph: Self.graph, id: { $0 })
        #expect(afterCurrent == ["h", "a2", "a3", "q"])
        // a2 已经放过: 不往回插, 接在末尾。
        let played = ShuffleLinkPolicy.appending(["a3"], to: ["a2", "p", "z"], anchor: 1,
                                                 graph: Self.graph, id: { $0 })
        #expect(played == ["a2", "p", "z", "a3"])
        // 正在放 b2: 不插到它前面。
        let current = ShuffleLinkPolicy.appending(["b1"], to: ["h", "b2"], anchor: 1,
                                                  graph: Self.graph, id: { $0 })
        #expect(current == ["h", "b2", "b1"])
    }

    @Test("Appending without links is a plain append")
    func appendingWithoutLinks() {
        #expect(ShuffleLinkPolicy.appending([3, 4], to: [0, 1, 2], anchor: 1, graph: .empty, id: { "\($0)" })
            == [0, 1, 2, 3, 4])
    }

    @Test("The next round moves its whole leading block, never splitting another")
    func movingLeadingBlock() {
        let order = ["b1", "b2", "a2", "a3", "a4", "x"]
        for seed in 0..<20 {
            var generator = SeededGenerator(state: UInt64(seed))
            let moved = ShuffleLinkPolicy.movingLeadingBlock(awayFrom: "b1", in: order, graph: Self.graph,
                                                             id: { $0 }, using: &generator)
            #expect(moved.first != "b1")
            #expect(Set(moved) == Set(order))
            #expect(Self.isContiguous(["b1", "b2"], in: moved))
            #expect(Self.isContiguous(["a2", "a3", "a4"], in: moved))
        }
        var generator = SeededGenerator(state: 1)
        #expect(ShuffleLinkPolicy.movingLeadingBlock(awayFrom: "x", in: order, graph: Self.graph,
                                                     id: { $0 }, using: &generator) == order)
        #expect(ShuffleLinkPolicy.movingLeadingBlock(awayFrom: "b1", in: ["b1", "b2"], graph: Self.graph,
                                                     id: { $0 }, using: &generator) == ["b1", "b2"])
    }

    @Test("Whole-library shuffle keeps chains and brings a missing neighbour")
    func plannerShuffles() {
        // a4 设了「先放上一首」, 带上 a3; b1 设了「接着放下一首」, 带上 b2; a3 自己没开, 不带 a2。
        let ids = ["a4", "x", "b1", "y"]
        let plan = LargeQueueRequestPlanner.plan(
            ids: ids, startIndex: 0, order: .shuffled,
            includes: { _ in true }, resolve: { $0 },
            linkGraph: Self.graph, shuffle: { $0.reversed() }
        )
        let items = plan?.items ?? []
        #expect(items.count == 6)
        #expect(Set(items) == Set(ids + ["a3", "b2"]))
        #expect(Self.isContiguous(["a3", "a4"], in: items))
        #expect(Self.isContiguous(["b1", "b2"], in: items))
    }

    @Test("Shuffling from a chosen song starts with it and what it links to")
    func plannerShufflesAfterStart() {
        let ids = ["x", "a3", "y", "a2", "a4", "z"]
        let plan = LargeQueueRequestPlanner.plan(
            ids: ids, startIndex: 3, order: .shuffledAfterStart,
            includes: { _ in true }, resolve: { $0 },
            linkGraph: Self.graph, shuffle: { $0 }
        )
        let items = plan?.items ?? []
        #expect(Array(items.prefix(3)) == ["a2", "a3", "a4"])
        #expect(plan?.selectedIndex == 0)
        #expect(Set(items) == Set(ids))
    }

    @Test("Without links the planner shuffles exactly as before")
    func plannerWithoutLinks() {
        let ids = ["a", "b", "c", "d"]
        let plan = LargeQueueRequestPlanner.plan(
            ids: ids, startIndex: 2, order: .shuffledAfterStart,
            includes: { _ in true }, resolve: { $0 },
            shuffle: { $0.reversed() }
        )
        #expect(plan?.items == ["c", "d", "b", "a"])
    }
}
