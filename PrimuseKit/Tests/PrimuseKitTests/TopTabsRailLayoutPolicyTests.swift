import Foundation
import Testing
@testable import PrimuseKit

/// 数值取自 iPhone Duo 外屏模拟器(Xcode 27.1 beta,iOS 27.1)实测:
/// 竖握 466×678,系统竖栏在右,安全区 左 0 / 右 84 / 上 0 / 下 34;
/// 遮挡区是竖栏顶端 84×170(竖排状态栏)与其中直径 37 的摄像头。
/// 横握 678×466,竖栏在左,遮挡区是竖栏顶端 84×82 与摄像头,状态栏收起。
@Suite("极简 tab 条的侧边竖栏")
struct TopTabsRailLayoutPolicyTests {
    private typealias Policy = TopTabsRailLayoutPolicy

    @Test("系统让出一条竖栏才改成竖栏")
    func railDecision() {
        #expect(Policy.usesRail(hasVerticalBarEdge: true, verticalBarInset: 84))
        #expect(!Policy.usesRail(hasVerticalBarEdge: false, verticalBarInset: 84))
        // 普通 iPhone 横屏的刘海安全区不是竖栏:系统不给竖排的一侧。
        #expect(!Policy.usesRail(hasVerticalBarEdge: false, verticalBarInset: 59))
        #expect(!Policy.usesRail(hasVerticalBarEdge: true, verticalBarInset: 0))
        #expect(!Policy.usesRail(hasVerticalBarEdge: true, verticalBarInset: 20))
        #expect(!Policy.usesRail(hasVerticalBarEdge: true, verticalBarInset: .nan))
    }

    @Test("竖握:内容让开竖排的状态栏与摄像头")
    func portraitClearance() {
        let clearance = Policy.topClearance(
            occlusions: [(minY: 29.3, maxY: 66.3), (minY: 0, maxY: 170)],
            railHeight: 644
        )
        #expect(clearance == 178)
    }

    @Test("横握:状态栏收起,只让开摄像头那一段")
    func landscapeClearance() {
        let clearance = Policy.topClearance(
            occlusions: [(minY: 29.3, maxY: 66.3), (minY: 0, maxY: 82)],
            railHeight: 432
        )
        #expect(clearance == 90)
    }

    @Test("没有遮挡也不贴着顶端;下半截的遮挡不推整列内容")
    func clearanceFallbacks() {
        #expect(Policy.topClearance(occlusions: [], railHeight: 644) == Policy.minimumTopClearance)
        #expect(Policy.topClearance(occlusions: [(minY: 520, maxY: 600)], railHeight: 644)
            == Policy.minimumTopClearance)
        #expect(Policy.topClearance(occlusions: [(minY: 0, maxY: 2)], railHeight: 644)
            == Policy.minimumTopClearance)
        #expect(Policy.topClearance(occlusions: [(minY: .nan, maxY: 300)], railHeight: 644)
            == Policy.minimumTopClearance)
    }

    @Test("横握另一个方向(摄像头在右下角):底部按钮组贴着遮挡区上沿往上排,顶端不让")
    func bottomOcclusionClearance() {
        // 竖栏高 432(外屏横握 466 减去底部安全区 34);遮挡区在屏幕下沿 384…466,摄像头 405…442。
        let occlusions = [(minY: 384.0, maxY: 466.0), (minY: 405.0, maxY: 442.0)]
        #expect(Policy.bottomClearance(occlusions: occlusions, railHeight: 432) == 56)
        #expect(Policy.topClearance(occlusions: occlusions, railHeight: 432) == Policy.minimumTopClearance)
    }

    @Test("底部没有遮挡时按钮组照旧贴底;顶上的遮挡不抬底部")
    func bottomClearanceFallbacks() {
        #expect(Policy.bottomClearance(occlusions: [], railHeight: 644) == Policy.minimumBottomClearance)
        #expect(Policy.bottomClearance(occlusions: [(minY: 0, maxY: 170)], railHeight: 644)
            == Policy.minimumBottomClearance)
        #expect(Policy.bottomClearance(occlusions: [(minY: 700, maxY: 760)], railHeight: 644)
            == Policy.minimumBottomClearance)
        #expect(Policy.bottomClearance(occlusions: [(minY: .nan, maxY: 600)], railHeight: 644)
            == Policy.minimumBottomClearance)
        #expect(Policy.bottomClearance(occlusions: [(minY: 600, maxY: 700)], railHeight: .nan)
            == Policy.minimumBottomClearance)
    }

    @Test("根页顶部留白:竖握 16、横握 12")
    func contentTopInset() {
        #expect(Policy.contentTopInset(isCompactHeight: false) == 16)
        #expect(Policy.contentTopInset(isCompactHeight: true) == 12)
    }

    @Test("搜索与设置总在最后一行并排")
    func clusterRowsKeepSearchAndSettingsTogether() {
        // 只有搜索、设置。
        #expect(Policy.clusterRows(itemWidths: [40, 40], railWidth: 84) == [0..<2])
        // 页面动作 + 搜索 + 设置:动作单独一行在上面。
        #expect(Policy.clusterRows(itemWidths: [40, 40, 40], railWidth: 84) == [0..<1, 1..<3])
        // 筛选 + 页面动作 + 搜索 + 设置:两行两列。
        #expect(Policy.clusterRows(itemWidths: [40, 40, 40, 40], railWidth: 84) == [0..<2, 2..<4])
    }

    @Test("比竖栏还宽的文字按钮单独一行;窄竖栏每个一行")
    func clusterRowsOverflow() {
        #expect(Policy.clusterRows(itemWidths: [96, 40, 40], railWidth: 84) == [0..<1, 1..<3])
        #expect(Policy.clusterRows(itemWidths: [40, 40, 40], railWidth: 44) == [0..<1, 1..<2, 2..<3])
        #expect(Policy.clusterRows(itemWidths: [], railWidth: 84).isEmpty)
    }
}
