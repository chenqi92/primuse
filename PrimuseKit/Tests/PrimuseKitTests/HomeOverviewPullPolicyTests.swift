import Testing
@testable import PrimuseKit

@Suite("Home overview pull")
struct HomeOverviewPullPolicyTests {
    @Test("顶部拉住达到时长只触发一次，并拦截同一次刷新")
    func heldPullTriggersOnce() {
        var policy = HomeOverviewPullPolicy()
        let activated1 = policy.update(pullDistance: 70, isInteracting: true, isEnabled: true, now: 10)
        #expect(!activated1)
        let activated2 = policy.update(pullDistance: 70, isInteracting: true, isEnabled: true, now: 11)
        #expect(!activated2)
        let activated3 = policy.update(pullDistance: 70, isInteracting: true, isEnabled: true, now: 11.3)
        #expect(activated3)
        #expect(policy.suppressesRefresh)
        let activated4 = policy.update(pullDistance: 90, isInteracting: true, isEnabled: true, now: 13)
        #expect(!activated4)
        #expect(policy.holdStartedAt == nil)
        policy.update(pullDistance: 0, isInteracting: false, isEnabled: false, now: 14)
        #expect(policy.suppressesRefresh)
        policy.update(pullDistance: 70, isInteracting: true, isEnabled: false, now: 15)
        #expect(!policy.suppressesRefresh)
    }

    @Test("短拉和松手不返回首页，不阻止普通刷新")
    func shortPullRemainsRefreshable() {
        var policy = HomeOverviewPullPolicy()
        policy.update(pullDistance: 80, isInteracting: true, isEnabled: true, now: 0)
        let activated5 = policy.update(pullDistance: 80, isInteracting: false, isEnabled: true, now: 0.6)
        #expect(!activated5)
        let activated6 = policy.update(pullDistance: 80, isInteracting: false, isEnabled: true, now: 2)
        #expect(!activated6)
        #expect(policy.holdStartedAt == nil)
        #expect(!policy.suppressesRefresh)
    }

    @Test("滚回阈值内会重新计时，未到顶部和停用时不激活")
    func cancelsAndRequiresTopOverscroll() {
        var policy = HomeOverviewPullPolicy()
        for distance in [-100.0, 0, 63] {
            let activated7 = policy.update(pullDistance: distance, isInteracting: true, isEnabled: true, now: 0)
            #expect(!activated7)
            #expect(policy.holdStartedAt == nil)
        }
        policy.update(pullDistance: 80, isInteracting: true, isEnabled: true, now: 1)
        policy.update(pullDistance: 30, isInteracting: true, isEnabled: true, now: 2)
        #expect(policy.holdStartedAt == nil)
        policy.update(pullDistance: 80, isInteracting: true, isEnabled: true, now: 2.1)
        let activated8 = policy.update(pullDistance: 80, isInteracting: true, isEnabled: true, now: 3)
        #expect(!activated8)
        let activated9 = policy.update(pullDistance: 80, isInteracting: true, isEnabled: false, now: 4)
        #expect(!activated9)
        #expect(policy.holdStartedAt == nil)
        #expect(!policy.suppressesRefresh)
    }
}
