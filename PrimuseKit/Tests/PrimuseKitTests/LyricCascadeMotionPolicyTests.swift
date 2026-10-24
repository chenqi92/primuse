import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric cascade motion")
struct LyricCascadeMotionPolicyTests {
    typealias Policy = LyricCascadeMotionPolicy

    @Test("Rows above and at the current line move at once, rows below follow one after another")
    func rowsBelowFollowInTurn() {
        #expect(Policy.delay(forRow: 3, activeRow: 5) == 0)
        #expect(Policy.delay(forRow: 5, activeRow: 5) == 0)
        let next = Policy.delay(forRow: 6, activeRow: 5)
        let afterNext = Policy.delay(forRow: 7, activeRow: 5)
        #expect(next > 0)
        #expect(afterNext > next)
        #expect(abs(afterNext - next - Policy.rowDelayStep) < 1e-9)
    }

    @Test("Far rows stop adding delay")
    func delayIsCapped() {
        let capped = Double(Policy.maximumDelayedRows) * Policy.rowDelayStep
        #expect(abs(Policy.delay(forRow: 5 + Policy.maximumDelayedRows, activeRow: 5) - capped) < 1e-9)
        #expect(abs(Policy.delay(forRow: 60, activeRow: 5) - capped) < 1e-9)
        #expect(Policy.delay(forRow: 8, activeRow: -1) == 0)
    }

    @Test("Rows fade with their distance from the current line")
    func depthOpacityFallsWithDistance() {
        #expect(Policy.depthOpacity(forRow: 5, activeRow: 5) == 1)
        #expect(Policy.depthOpacity(forRow: 4, activeRow: 5) == 1)
        #expect(Policy.depthOpacity(forRow: 6, activeRow: 5) == 1)
        let two = Policy.depthOpacity(forRow: 7, activeRow: 5)
        let three = Policy.depthOpacity(forRow: 8, activeRow: 5)
        #expect(two < 1 && three < two)
        #expect(Policy.depthOpacity(forRow: 3, activeRow: 5) == two)
        #expect(Policy.depthOpacity(forRow: 40, activeRow: 5) == Policy.minimumDepthOpacity)
        #expect(Policy.depthOpacity(forRow: 40, activeRow: -1) == 1)
    }

    @Test("Only ordinary line changes cascade")
    func cascadeOnlyForShortRegularSteps() {
        #expect(Policy.shouldCascade(scrollDistance: 60, viewportHeight: 500, sinceLastCascade: 3))
        #expect(Policy.shouldCascade(scrollDistance: -60, viewportHeight: 500, sinceLastCascade: 3))
        // 换得太快：上一次还在路上。
        #expect(!Policy.shouldCascade(scrollDistance: 60, viewportHeight: 500, sinceLastCascade: 0.3))
        // 跳得太远：拖进度条、点了很远的一句。
        #expect(!Policy.shouldCascade(scrollDistance: 900, viewportHeight: 500, sinceLastCascade: 3))
        // 没动、量不到视口。
        #expect(!Policy.shouldCascade(scrollDistance: 0.2, viewportHeight: 500, sinceLastCascade: 3))
        #expect(!Policy.shouldCascade(scrollDistance: 60, viewportHeight: 0, sinceLastCascade: 3))
        #expect(!Policy.shouldCascade(scrollDistance: .nan, viewportHeight: 500, sinceLastCascade: 3))
    }
}
