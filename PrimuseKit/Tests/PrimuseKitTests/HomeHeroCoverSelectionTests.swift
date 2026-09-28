import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home Hero Cover Selection")
struct HomeHeroCoverSelectionTests {
    private let pool = (0..<40).map { "song-\($0)" }

    @Test("同一天同一候选池反复计算结果不变")
    func repeatedRefreshIsStable() {
        let first = HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260927, limit: 4)
        for _ in 0..<20 {
            #expect(HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260927, limit: 4) == first)
        }
        #expect(first.count == 4)
    }

    @Test("候选池顺序变化不影响结果")
    func orderIndependent() {
        let a = HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260927, limit: 4)
        let b = HomeHeroCoverSelection.pick(candidateIDs: pool.reversed(), dayStamp: 20260927, limit: 4)
        #expect(a == b)
    }

    @Test("候选池多一首最多换掉一张")
    func oneNewCandidateReplacesAtMostOne() {
        let before = HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260927, limit: 4)
        for extra in 0..<30 {
            let after = HomeHeroCoverSelection.pick(
                candidateIDs: pool + ["new-\(extra)"],
                dayStamp: 20260927,
                limit: 4
            )
            #expect(Set(before).subtracting(after).count <= 1)
        }
    }

    @Test("换一天会换一组")
    func differentDayRotates() {
        let today = HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260927, limit: 4)
        let tomorrow = HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 20260928, limit: 4)
        #expect(today != tomorrow)
    }

    @Test("去重、跳过空 id、候选不足时全给")
    func dedupesAndHandlesSmallPools() {
        let picked = HomeHeroCoverSelection.pick(
            candidateIDs: ["a", "", "a", "b"],
            dayStamp: 1,
            limit: 4
        )
        #expect(Set(picked) == ["a", "b"])
        #expect(picked.count == 2)
        #expect(HomeHeroCoverSelection.pick(candidateIDs: pool, dayStamp: 1, limit: 0).isEmpty)
    }
}
