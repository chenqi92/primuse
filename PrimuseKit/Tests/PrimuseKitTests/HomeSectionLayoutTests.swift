import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home section layout")
struct HomeSectionLayoutTests {
    @Test("常规高度照用用户配置的行数")
    func keepsConfiguredRowsOnRegularHeight() {
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 1, isCompactHeight: false) == 1)
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 2, isCompactHeight: false) == 2)
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 3, isCompactHeight: false) == 3)
    }

    @Test("手机横屏一律只铺一行")
    func clampsRowsOnCompactHeight() {
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 1, isCompactHeight: true) == 1)
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 2, isCompactHeight: true) == 1)
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 3, isCompactHeight: true) == 1)
    }

    @Test("行数至少是一行")
    func neverRendersFewerThanOneRow() {
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: 0, isCompactHeight: false) == 1)
        #expect(HomeSectionLayoutPolicy.renderedRowCount(configured: -2, isCompactHeight: true) == 1)
    }

    @Test("夹取不落到存档上")
    func doesNotTouchStoredConfiguration() {
        var configuration = HomeSectionLayoutConfiguration()
        configuration.setStyle(.carousel, for: .recentlyAdded)
        configuration.setRowCount(3, for: .recentlyAdded)
        let stored = configuration.rowCount(for: .recentlyAdded)
        #expect(stored == 3)
        let rendered = HomeSectionLayoutPolicy.renderedRowCount(configured: stored, isCompactHeight: true)
        #expect(rendered == 1)
        let storedAfterRender = configuration.rowCount(for: .recentlyAdded)
        #expect(storedAfterRender == 3)
    }

    @Test("开始听默认铺开成网格,可换横排;张数两种排布都能调,行数只有横排有")
    func startListeningLayout() {
        #expect(HomeSectionLayoutPolicy.supportedStyles(for: .startListening) == [.grid, .carousel])
        #expect(HomeSectionLayoutPolicy.defaultStyle(for: .startListening) == .grid)
        #expect(HomeSectionLayoutPolicy.isConfigurable(.startListening))
        #expect(HomeSectionLayoutPolicy.itemCountRange(for: .startListening) == 2...24)
        #expect(HomeSectionLayoutPolicy.defaultItemCount(for: .startListening) == 6)
        #expect(HomeSectionLayoutPolicy.rowsRange(for: .startListening, style: .grid) == nil)
        #expect(HomeSectionLayoutPolicy.rowsRange(for: .startListening, style: .carousel) == 1...3)

        var configuration = HomeSectionLayoutConfiguration()
        #expect(configuration.style(for: .startListening) == .grid)
        configuration.advanceStyle(for: .startListening)
        #expect(configuration.style(for: .startListening) == .carousel)
        configuration.setItemCount(40, for: .startListening)
        #expect(configuration.itemCount(for: .startListening) == 24)
        configuration.advanceStyle(for: .startListening)
        #expect(configuration.style(for: .startListening) == .grid)
        #expect(configuration.styles[HomeSectionKind.startListening.rawValue] == nil)
    }

    @Test("收藏不设上限之后,首页收藏区默认摆九个,能在三到三十之间调")
    func quickAccessCount() {
        #expect(HomeSectionLayoutPolicy.itemCountRange(for: .quickAccess) == 3...30)
        #expect(HomeSectionLayoutPolicy.defaultItemCount(for: .quickAccess) == 9)

        var configuration = HomeSectionLayoutConfiguration()
        #expect(configuration.itemCount(for: .quickAccess) == nil)
        configuration.setItemCount(50, for: .quickAccess)
        #expect(configuration.itemCount(for: .quickAccess) == 30)
    }

    @Test("情景推荐专辑默认一张,能调到十张,没有排布可换")
    func albumPickCount() {
        #expect(HomeSectionLayoutPolicy.itemCountRange(for: .albumPick) == 1...10)
        #expect(HomeSectionLayoutPolicy.defaultItemCount(for: .albumPick) == 1)
        #expect(!HomeSectionLayoutPolicy.isConfigurable(.albumPick))

        var configuration = HomeSectionLayoutConfiguration()
        #expect(configuration.itemCount(for: .albumPick) == nil)
        configuration.setItemCount(12, for: .albumPick)
        #expect(configuration.itemCount(for: .albumPick) == 10)
        configuration.setItemCount(0, for: .albumPick)
        #expect(configuration.itemCount(for: .albumPick) == 1)
    }
}
