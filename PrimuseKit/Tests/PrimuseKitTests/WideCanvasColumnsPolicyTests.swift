import Foundation
import Testing
@testable import PrimuseKit

/// Duo 内屏:模拟器画面缓冲推算 951×669,官方像素推算 890×626;竖握时宽高互换。
@Suite("宽画布上的两栏重排")
struct WideCanvasColumnsPolicyTests {
    private typealias Policy = WideCanvasColumnsPolicy

    @Test("只有 iPhone 的常规宽度横向画布分两栏")
    func twoColumnDecision() {
        #expect(Policy.usesTwoColumns(isPhone: true, isRegularWidth: true, isCompactHeight: false, width: 951, height: 669))
        #expect(Policy.usesTwoColumns(isPhone: true, isRegularWidth: true, isCompactHeight: false, width: 890, height: 626))
        // 内屏竖握:比宽还高,保持单栏。
        #expect(!Policy.usesTwoColumns(isPhone: true, isRegularWidth: true, isCompactHeight: false, width: 669, height: 951))
        // 外屏:紧凑宽度。
        #expect(!Policy.usesTwoColumns(isPhone: true, isRegularWidth: false, isCompactHeight: false, width: 466, height: 678))
        #expect(!Policy.usesTwoColumns(isPhone: true, isRegularWidth: false, isCompactHeight: true, width: 678, height: 466))
        // Pro Max 横屏:常规宽度但紧凑高度。
        #expect(!Policy.usesTwoColumns(isPhone: true, isRegularWidth: true, isCompactHeight: true, width: 956, height: 440))
        // iPad 保持自己的版式。
        #expect(!Policy.usesTwoColumns(isPhone: false, isRegularWidth: true, isCompactHeight: false, width: 1180, height: 820))
        #expect(!Policy.usesTwoColumns(isPhone: true, isRegularWidth: true, isCompactHeight: false, width: .nan, height: 669))
    }

    @Test("详情页左栏按比例取宽,有上下限")
    func detailColumns() {
        #expect(abs(Policy.detailLeadingColumnWidth(pageWidth: 951) - 399.42) < 0.01)
        #expect(abs(Policy.detailLeadingColumnWidth(pageWidth: 890) - 373.8) < 0.01)
        #expect(Policy.detailLeadingColumnWidth(pageWidth: 1400) == 440)
        #expect(Policy.detailLeadingColumnWidth(pageWidth: 700) == 340)
        #expect(Policy.detailLeadingColumnWidth(pageWidth: 0) == 0)
    }

    @Test("首页区块交替分到两栏")
    func homeColumns() {
        let columns = Policy.homeColumns(sectionCount: 5)
        #expect(columns.leading == [0, 2, 4])
        #expect(columns.trailing == [1, 3])
        #expect(Policy.homeColumns(sectionCount: 0).leading.isEmpty)
    }
}
