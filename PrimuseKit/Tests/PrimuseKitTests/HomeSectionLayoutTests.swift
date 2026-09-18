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
}
