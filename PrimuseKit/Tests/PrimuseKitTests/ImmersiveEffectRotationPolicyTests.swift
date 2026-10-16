import Foundation
import Testing
@testable import PrimuseKit

@Suite("Immersive effect rotation")
struct ImmersiveEffectRotationPolicyTests {
    /// 固定种子的线性同余发生器,让洗牌结果可复现。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test("Modes read stored values, default to off and give their intervals")
    func modes() {
        #expect(ImmersiveEffectRotationMode(storedValue: nil) == .off)
        #expect(ImmersiveEffectRotationMode(storedValue: "minutes5") == .minutes5)
        #expect(ImmersiveEffectRotationMode(storedValue: "every-90s") == .off)
        #expect(ImmersiveEffectRotationMode.off.interval == nil)
        #expect(ImmersiveEffectRotationMode.perSong.interval == nil)
        #expect(ImmersiveEffectRotationMode.minutes2.interval == 120)
        #expect(ImmersiveEffectRotationMode.minutes10.minutes == 10)
        #expect(!ImmersiveEffectRotationMode.off.isEnabled)
        #expect(ImmersiveEffectRotationMode.perSong.isEnabled)
        #expect(ImmersiveEffectRotationScope(storedValue: nil) == .audioReactive)
        #expect(ImmersiveEffectRotationScope(storedValue: "all") == .all)
    }

    @Test("A round plays every other effect once before any repeats")
    func fullRounds() throws {
        var queue = ImmersiveEffectRotationQueue()
        var generator = SeededGenerator(state: 7)
        let pool = ["a", "b", "c", "d", "e"]
        var current = "a"
        var round: [String] = []
        for _ in 0..<4 {
            let next = try #require(queue.next(after: current, pool: pool, using: &generator))
            #expect(next != current)
            round.append(next)
            current = next
        }
        #expect(Set(round) == ["b", "c", "d", "e"])

        // 往后很多轮:永远不原地换成自己。
        for _ in 0..<200 {
            let next = try #require(queue.next(after: current, pool: pool, using: &generator))
            #expect(next != current)
            current = next
        }
    }

    @Test("Changing the pool drops what no longer qualifies; nothing to switch to gives nil")
    func poolChanges() {
        var queue = ImmersiveEffectRotationQueue()
        var generator = SeededGenerator(state: 42)
        _ = queue.next(after: "a", pool: ["a", "b", "c", "d"], using: &generator)
        for _ in 0..<10 {
            let next = queue.next(after: "x", pool: ["x", "y"], using: &generator)
            #expect(next == "y")
        }
        #expect(queue.next(after: "a", pool: ["a"], using: &generator) == nil)
        #expect(queue.next(after: "a", pool: [], using: &generator) == nil)
        #expect(queue.next(after: "a", pool: ["b", "b", "a"], using: &generator) == "b")
    }
}
