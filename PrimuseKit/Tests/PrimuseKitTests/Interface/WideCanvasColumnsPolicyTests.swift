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

    @Test("首页区块一样高时一左一右交替")
    func homeColumnsAlternateWhenEven() {
        let columns = Policy.homeColumns(heights: Array(repeating: 200, count: 5), spacing: 24)
        #expect(columns.leading == [0, 2, 4])
        #expect(columns.trailing == [1, 3])
        let none = Policy.homeColumns(heights: [], spacing: 24)
        #expect(none.leading.isEmpty && none.trailing.isEmpty)
        let single = Policy.homeColumns(heights: [300], spacing: 24)
        #expect(single.leading == [0] && single.trailing.isEmpty)
        let pair = Policy.homeColumns(heights: [120, 900], spacing: 24)
        #expect(pair.leading == [0] && pair.trailing == [1])
    }

    @Test("大网格排在后面时两栏底部仍然齐平")
    func homeColumnsBalanceATallTrailingSection() {
        // 截图里的情形:横排、卡片几块之后是两列大封面的「最近添加」,最后是统计。
        let heights: [Double] = [300, 120, 260, 300, 800, 120]
        let columns = Policy.homeColumns(heights: heights, spacing: 24)
        expectValidSplit(columns, count: heights.count)
        // 头两块一左一右,首屏顺序不变。
        #expect(columns.leading.first == 0 && columns.trailing.first == 1)
        // 原来交替分:左栏 300+260+800,右栏 120+300+120,底下差出 820 点。现在差不过一块小区块。
        #expect(bottomDifference(columns, heights: heights, spacing: 24) <= 120)
    }

    @Test("两栏已经差不多齐时照「放进较矮那栏」排,不为再齐一点打乱顺序")
    func homeColumnsKeepTheGreedyOrderWithinTolerance() {
        let heights: [Double] = [200, 200, 100, 140]
        let columns = Policy.homeColumns(heights: heights, spacing: 24)
        #expect(columns.leading == [0, 2])
        #expect(columns.trailing == [1, 3])
        #expect(bottomDifference(columns, heights: heights, spacing: 24) <= Policy.homeColumnsBalanceTolerance)
    }

    @Test("一块比其余加起来还高时也给出合法的分法")
    func homeColumnsWithADominantSection() {
        let heights: [Double] = [100, 100, 3_000, 80]
        let columns = Policy.homeColumns(heights: heights, spacing: 24)
        expectValidSplit(columns, count: heights.count)
        // 大的那块和别的分开放,其余的都在另一栏。
        #expect(columns.leading.contains(2) != columns.trailing.contains(2))
        let tallColumn = columns.leading.contains(2) ? columns.leading : columns.trailing
        #expect(tallColumn.count <= 2)
        // 量不出的高度按零算,不会崩。
        let broken = Policy.homeColumns(heights: [.nan, 200, -5, .infinity, 100], spacing: .nan)
        expectValidSplit(broken, count: 5)
    }

    @Test("区块多、高矮不一时底部差不超过容差")
    func homeColumnsBalanceManySections() {
        let heights: [Double] = [420, 180, 260, 310, 150, 820, 240, 190, 360, 120, 640, 90]
        let columns = Policy.homeColumns(heights: heights, spacing: 24)
        expectValidSplit(columns, count: heights.count)
        #expect(bottomDifference(columns, heights: heights, spacing: 24) <= Policy.homeColumnsBalanceTolerance)
    }

    /// 每块恰好在一栏里,各栏保持原来的先后。
    private func expectValidSplit(_ columns: (leading: [Int], trailing: [Int]), count: Int) {
        #expect(columns.leading == columns.leading.sorted())
        #expect(columns.trailing == columns.trailing.sorted())
        #expect((columns.leading + columns.trailing).sorted() == Array(0..<count))
    }

    private func bottomDifference(
        _ columns: (leading: [Int], trailing: [Int]),
        heights: [Double],
        spacing: Double
    ) -> Double {
        func height(_ members: [Int]) -> Double {
            members.map { heights[$0] }.reduce(0, +) + Double(max(members.count - 1, 0)) * spacing
        }
        return abs(height(columns.leading) - height(columns.trailing))
    }
}
