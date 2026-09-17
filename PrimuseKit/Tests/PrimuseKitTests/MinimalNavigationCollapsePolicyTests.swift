import Foundation
import Testing
@testable import PrimuseKit

@Suite("Minimal navigation collapse resolver")
struct MinimalNavigationCollapsePolicyTests {
    private let chromeHeight = MinimalNavigationChromeMetrics.collapsibleHeight

    /// `#expect` 的宏展开会把接收者当成不可变值,mutating 方法只能先在外面调用。
    private func feed(
        _ resolver: inout MinimalNavigationCollapseResolver,
        distance: CGFloat,
        now: TimeInterval,
        chromeHeight: CGFloat
    ) -> Bool {
        resolver.update(
            scrolledDistance: distance,
            collapsibleChromeHeight: chromeHeight,
            now: now
        )
    }

    @Test("折叠要滚过一段距离,不是刚离开顶部就收起")
    func collapsesOnlyAfterRealTravel() {
        var resolver = MinimalNavigationCollapseResolver()
        let nearTop = feed(&resolver, distance: 30, now: 0, chromeHeight: chromeHeight)
        let midway = feed(&resolver, distance: 80, now: 0.1, chromeHeight: chromeHeight)
        let past = feed(&resolver, distance: 120, now: 0.2, chromeHeight: chromeHeight)
        #expect(!nearTop)
        #expect(!midway)
        #expect(past)
    }

    @Test("折叠让出的顶栏高度不会把状态弹回展开")
    func survivesTheInsetJump() {
        var resolver = MinimalNavigationCollapseResolver()
        let collapsed = feed(&resolver, distance: 90, now: 0, chromeHeight: chromeHeight)
        // 顶栏收起后安全区缩掉一整行,已滚距离随之跳水。
        let afterJump = feed(
            &resolver,
            distance: 90 - chromeHeight,
            now: 1,
            chromeHeight: chromeHeight
        )
        #expect(collapsed)
        #expect(afterJump)
    }

    @Test("反复采样不会在折叠与展开之间振荡")
    func doesNotOscillate() {
        var resolver = MinimalNavigationCollapseResolver()
        var distance: CGFloat = 96
        var toggles = 0
        var previous = resolver.isCollapsed
        for step in 0..<60 {
            let collapsed = feed(
                &resolver,
                distance: distance,
                now: TimeInterval(step) * 0.5,
                chromeHeight: chromeHeight
            )
            if collapsed != previous {
                toggles += 1
                previous = collapsed
                // 顶栏收放直接改写已滚距离,这正是抽搐的来源。
                distance += collapsed ? -chromeHeight : chromeHeight
            }
        }
        #expect(toggles == 1)
        #expect(resolver.isCollapsed)
    }

    @Test("结算窗口内不做二次判定")
    func holdsStateWhileChromeAnimates() {
        var resolver = MinimalNavigationCollapseResolver()
        let collapsed = feed(&resolver, distance: 200, now: 0, chromeHeight: chromeHeight)
        // 收起动画进行中的中间尺寸会让距离一路往下掉,窗口内一律维持折叠。
        let midAnimation = feed(&resolver, distance: 180, now: 0.05, chromeHeight: chromeHeight)
        let atTopInsideWindow = feed(&resolver, distance: 0, now: 0.2, chromeHeight: chromeHeight)
        let afterWindow = feed(&resolver, distance: 0, now: 0.5, chromeHeight: chromeHeight)
        #expect(collapsed)
        #expect(midAnimation)
        #expect(atTopInsideWindow)
        #expect(!afterWindow)
    }

    @Test("回到接近顶部才展开")
    func expandsNearTheTop() {
        var resolver = MinimalNavigationCollapseResolver()
        let collapsed = feed(&resolver, distance: 300, now: 0, chromeHeight: chromeHeight)
        let stillCollapsed = feed(&resolver, distance: 40, now: 1, chromeHeight: chromeHeight)
        let expanded = feed(&resolver, distance: 4, now: 2, chromeHeight: chromeHeight)
        #expect(collapsed)
        #expect(stillCollapsed)
        #expect(!expanded)
    }

    @Test("手动展开后要再向下滚一段才会自动折回")
    func respectsManualExpansion() {
        var resolver = MinimalNavigationCollapseResolver()
        let collapsed = feed(&resolver, distance: 400, now: 0, chromeHeight: chromeHeight)
        resolver.markManuallyExpanded(at: 400, now: 1)
        let staysExpanded = feed(&resolver, distance: 430, now: 2, chromeHeight: chromeHeight)
        let collapsesAgain = feed(&resolver, distance: 520, now: 3, chromeHeight: chromeHeight)
        #expect(collapsed)
        #expect(!staysExpanded)
        #expect(collapsesAgain)
    }

    @Test("动态字体撑高分类行时滞回带宽跟着抬高")
    func scalesWithChromeHeight() {
        let large = MinimalNavigationCollapseResolver.collapseDistance(collapsibleChromeHeight: 120)
        let regular = MinimalNavigationCollapseResolver.collapseDistance(
            collapsibleChromeHeight: MinimalNavigationChromeMetrics.collapsibleHeight
        )
        #expect(large == 156)
        #expect(regular == 84)

        var resolver = MinimalNavigationCollapseResolver()
        let belowThreshold = feed(&resolver, distance: 140, now: 0, chromeHeight: 120)
        let collapsed = feed(&resolver, distance: 170, now: 0.1, chromeHeight: 120)
        let afterJump = feed(&resolver, distance: 50, now: 1, chromeHeight: 120)
        #expect(!belowThreshold)
        #expect(collapsed)
        #expect(afterJump)
    }

    @Test("复位回到展开并清掉结算窗口")
    func resetsCleanly() {
        var resolver = MinimalNavigationCollapseResolver()
        let collapsed = feed(&resolver, distance: 300, now: 0, chromeHeight: chromeHeight)
        resolver.reset()
        let afterReset = resolver.isCollapsed
        let collapsesAgain = feed(&resolver, distance: 300, now: 0.1, chromeHeight: chromeHeight)
        #expect(collapsed)
        #expect(!afterReset)
        #expect(collapsesAgain)
    }
}
