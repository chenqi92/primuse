import Foundation
import Testing
@testable import PrimuseKit

@Suite("Floating input panel clearance policy")
struct FloatingInputPanelClearancePolicyTests {
    /// 一块竖屏 iPad 大小的窗口,原点在 0 —— 键盘 frame 转换过来之后就是这个坐标系。
    private let window = CGRect(x: 0, y: 0, width: 1024, height: 1366)

    @Test("停靠键盘由系统让位,策略不再补")
    func dockedKeyboardNeedsNoExtraClearance() {
        let docked = CGRect(x: 0, y: 1366 - 360, width: 1024, height: 360)
        #expect(FloatingInputPanelClearancePolicy.isDocked(
            panelFrameInWindow: docked,
            windowBounds: window
        ))
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: docked,
            windowBounds: window
        ) == 0)
    }

    @Test("贴底的浮动面板按它盖住的高度让位")
    func undockedPanelSittingOnTheBottomEdge() {
        // 宽度只有窗口一半 —— 停靠判定不成立,系统不会让位。
        let panel = CGRect(x: 240, y: 1366 - 300, width: 512, height: 300)
        #expect(!FloatingInputPanelClearancePolicy.isDocked(
            panelFrameInWindow: panel,
            windowBounds: window
        ))
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: window
        ) == 300)
    }

    @Test("悬空的手写浮窗让位到窗口底边,而不是只让面板自己的高度")
    func floatingPanelAboveTheBottomEdge() {
        // Apple Pencil 手写浮窗常常停在内容区中间偏下,下面还留着一段空白。
        let panel = CGRect(x: 180, y: 900, width: 600, height: 220)
        let clearance = FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: window
        )
        #expect(clearance == 466)
    }

    @Test("面板停在上半屏时不动布局")
    func panelInTheUpperHalfIsLeftAlone() {
        let panel = CGRect(x: 180, y: 200, width: 600, height: 220)
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: window
        ) == 0)
    }

    @Test("键盘收起或面板落在窗口之外都不让位")
    func dismissedOrOffscreenPanel() {
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: nil,
            windowBounds: window
        ) == 0)
        // 收起动画的终点 frame 正好落在窗口下缘之外。
        let offscreen = CGRect(x: 0, y: 1366, width: 1024, height: 360)
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: offscreen,
            windowBounds: window
        ) == 0)
    }

    @Test("分屏窗口只认落进自己范围的那部分面板")
    func splitScreenCountsOnlyTheIntersection() {
        // 右半屏的窗口:键盘浮窗横跨两个 app,但只有一部分压在自己身上。
        let splitWindow = CGRect(x: 0, y: 0, width: 512, height: 1366)
        let panel = CGRect(x: 300, y: 1100, width: 600, height: 266)
        let clearance = FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: splitWindow
        )
        #expect(clearance == 266)
        // 宽度没铺满窗口,不能当成停靠键盘。
        #expect(!FloatingInputPanelClearancePolicy.isDocked(
            panelFrameInWindow: panel,
            windowBounds: splitWindow
        ))
    }

    @Test("1pt 级别的重叠忽略掉,免得布局抖动")
    func hairlineOverlapIsIgnored() {
        let panel = CGRect(x: 240, y: 1366 - 3, width: 512, height: 300)
        #expect(FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: window
        ) == 0)
    }

    @Test("让位高度封顶在窗口高度的给定比例")
    func clearanceIsCapped() {
        let tall = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        // 顶边贴着窗口顶、底边越过窗口底:交集从 midY 之下开始才会进入计算,
        // 这里用一个顶边刚好在 midY 的面板压到极限。
        let panel = CGRect(x: 100, y: 683, width: 512, height: 900)
        let clearance = FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panel,
            windowBounds: tall,
            maximumFraction: 0.4
        )
        #expect(clearance == 546.4)
    }
}
