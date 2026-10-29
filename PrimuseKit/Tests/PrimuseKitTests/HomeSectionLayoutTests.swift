import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home section layout")
struct HomeSectionLayoutTests {
    @Test("在听样式和封面大小独立保存,旧配置保留其他首页设置")
    func listeningStylesRoundTrip() {
        var layout = HomeSectionLayoutConfiguration.decode(#"{"styles":{"playlists":"grid"},"coverSizes":{"booksInProgress":"small"}}"#)
        #expect(layout.booksInProgressStyle == .carousel)
        for style in SpokenWordContinueStyle.allCases {
            layout.booksInProgressStyle = style
            let restored = HomeSectionLayoutConfiguration.decode(layout.encoded())
            #expect(restored.booksInProgressStyle == style)
            #expect(restored.coverSize(for: .booksInProgress) == .small)
            #expect(restored.style(for: .playlists) == .grid)
            #expect(restored.supportsCoverSize(for: .booksInProgress) == (style != .list))
        }
        layout.styles[HomeSectionKind.booksInProgress.rawValue] = "future-style"
        #expect(layout.booksInProgressStyle == .carousel)
        #expect(layout.coverSize(for: .booksInProgress) == .small)
    }

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

    @Test("开始听铺开时可选 1–4 列,默认两列;横排没有列数")
    func startListeningColumns() {
        #expect(HomeSectionLayoutPolicy.columnsRange(for: .startListening, style: .grid) == 1...4)
        #expect(HomeSectionLayoutPolicy.columnsRange(for: .startListening, style: .carousel) == nil)
        #expect(HomeSectionLayoutPolicy.columnsRange(for: .recentlyAdded, style: .grid) == nil)
        #expect(HomeSectionLayoutPolicy.defaultColumns(for: .startListening) == 2)

        var configuration = HomeSectionLayoutConfiguration()
        #expect(configuration.columnCount(for: .startListening) == 2)
        configuration.advanceColumnCount(for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 3)
        configuration.advanceColumnCount(for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 4)
        configuration.advanceColumnCount(for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 1)
        configuration.advanceColumnCount(for: .startListening)
        // 回到默认两列时不留记录。
        #expect(configuration.columnCount(for: .startListening) == 2)
        #expect(configuration.columns.isEmpty)
        configuration.setColumnCount(9, for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 4)

        // 换成横排时列数不起作用,换回网格还是原来那个数。
        configuration.advanceStyle(for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 2)
        configuration.setColumnCount(3, for: .startListening)
        #expect(configuration.columns[HomeSectionKind.startListening.rawValue] == 4)
        configuration.advanceStyle(for: .startListening)
        #expect(configuration.columnCount(for: .startListening) == 4)
    }

    @Test("封面大小按块存,没调过的块跟着老版本的全局大小")
    func coverSizePerSection() {
        var configuration = HomeSectionLayoutConfiguration()
        #expect(configuration.coverSize(for: .playlists) == .large)
        #expect(configuration.coverSize(for: .playlists, following: .small) == .small)

        configuration.setCoverSize(.small, for: .radio)
        #expect(configuration.coverSize(for: .radio) == .small)
        #expect(configuration.coverSize(for: .podcasts) == .large)
        configuration.setCoverSize(.large, for: .radio)
        #expect(configuration.coverSizes.isEmpty)

        // 老版本调成过「小」:单独调回「大」的块要记下来,其余跟着「小」。
        configuration.setCoverSize(.large, for: .audiobooks, following: .small)
        #expect(configuration.coverSize(for: .audiobooks, following: .small) == .large)
        #expect(configuration.coverSize(for: .radio, following: .small) == .small)
        configuration.setCoverSize(.small, for: .audiobooks, following: .small)
        #expect(configuration.coverSizes.isEmpty)
    }

    @Test("只有封面卡边长固定的排布才给封面大小")
    func coverSizeSupport() {
        for section in [HomeSectionKind.continueSpaces, .radio, .booksInProgress, .audiobooks, .podcasts] {
            #expect(HomeSectionLayoutPolicy.supportsCoverSize(section, style: HomeSectionLayoutPolicy.defaultStyle(for: section)))
        }
        #expect(HomeSectionLayoutPolicy.supportsCoverSize(.playlists, style: .carousel))
        #expect(HomeSectionLayoutPolicy.supportsCoverSize(.playlists, style: .grid))
        #expect(!HomeSectionLayoutPolicy.supportsCoverSize(.playlists, style: .list))
        #expect(HomeSectionLayoutPolicy.supportsCoverSize(.folders, style: .grid))
        #expect(!HomeSectionLayoutPolicy.supportsCoverSize(.folders, style: .list))
        #expect(HomeSectionLayoutPolicy.supportsCoverSize(.recentlyAdded, style: .carousel))
        #expect(!HomeSectionLayoutPolicy.supportsCoverSize(.recentlyAdded, style: .grid))
        for section in [HomeSectionKind.startListening, .albumPick, .continueListening, .quickAccess,
                        .forYou, .listeningRanking, .topArtists, .stats] {
            for style in HomeSectionLayoutStyle.allCases {
                #expect(!HomeSectionLayoutPolicy.supportsCoverSize(section, style: style))
            }
        }
    }

    @Test("列数与封面大小随整份配置存取;老存档没有这两项照常解出来")
    func columnsAndCoverSizesRoundTrip() throws {
        var configuration = HomeSectionLayoutConfiguration()
        configuration.setColumnCount(3, for: .startListening)
        configuration.setCoverSize(.small, for: .playlists)
        configuration.setItemCount(8, for: .radio)
        let decoded = HomeSectionLayoutConfiguration.decode(configuration.encoded())
        #expect(decoded == configuration)
        #expect(decoded.columnCount(for: .startListening) == 3)
        #expect(decoded.coverSize(for: .playlists) == .small)

        let legacy = HomeSectionLayoutConfiguration.decode(#"{"styles":{"startListening":"carousel"},"itemCounts":{"radio":8},"rows":{}}"#)
        #expect(legacy.style(for: .startListening) == .carousel)
        #expect(legacy.itemCount(for: .radio) == 8)
        #expect(legacy.columns.isEmpty)
        #expect(legacy.coverSizes.isEmpty)
    }
}

@Suite("Home quick access carousel")
struct HomeQuickAccessCarouselMetricsTests {
    @Test("整数列铺满一屏,左右留白相等")
    func columnsFillTheViewportEvenly() {
        for width in [375.0, 393, 402, 430, 440, 820, 1024] {
            let metrics = HomeQuickAccessCarouselMetrics(viewportWidth: width)
            let columns = Double(metrics.columnsPerScreen)
            let rowWidth = metrics.itemWidth * columns + HomeQuickAccessCarouselMetrics.spacing * (columns - 1)
            #expect(abs(rowWidth + HomeQuickAccessCarouselMetrics.inset * 2 - width) < 0.001)
            #expect(metrics.itemWidth >= HomeQuickAccessCarouselMetrics.minimumItemWidth)
        }
    }

    @Test("常见手机竖屏一屏四列")
    func phonesShowFourColumns() {
        #expect(HomeQuickAccessCarouselMetrics(viewportWidth: 393).columnsPerScreen == 4)
        #expect(HomeQuickAccessCarouselMetrics(viewportWidth: 440).columnsPerScreen == 4)
        #expect(HomeQuickAccessCarouselMetrics(viewportWidth: 375).columnsPerScreen == 4)
    }

    @Test("下一列从屏幕右边缘之外开始")
    func nextColumnStartsOffScreen() {
        for width in [375.0, 393, 402, 440] {
            let metrics = HomeQuickAccessCarouselMetrics(viewportWidth: width)
            let columns = Double(metrics.columnsPerScreen)
            let nextColumnStart = HomeQuickAccessCarouselMetrics.inset
                + (metrics.itemWidth + HomeQuickAccessCarouselMetrics.spacing) * columns
            #expect(nextColumnStart >= width - 0.001)
        }
    }

    @Test("还没量到宽度时按原来的固定列宽排")
    func unmeasuredViewportKeepsTheFormerWidth() {
        let metrics = HomeQuickAccessCarouselMetrics(viewportWidth: 0)
        #expect(metrics.itemWidth == HomeQuickAccessCarouselMetrics.unmeasuredItemWidth)
        #expect(metrics.columnsPerScreen == 1)
    }

    @Test("条目不够一屏时行数跟着收")
    func rowCountShrinksToTheItems() {
        typealias Metrics = HomeQuickAccessCarouselMetrics
        #expect(Metrics.renderedRowCount(itemCount: 2, rows: 2, columnsPerScreen: 4) == 1)
        #expect(Metrics.renderedRowCount(itemCount: 4, rows: 2, columnsPerScreen: 4) == 1)
        #expect(Metrics.renderedRowCount(itemCount: 5, rows: 2, columnsPerScreen: 4) == 2)
        #expect(Metrics.renderedRowCount(itemCount: 30, rows: 2, columnsPerScreen: 4) == 2)
        #expect(Metrics.renderedRowCount(itemCount: 9, rows: 3, columnsPerScreen: 4) == 3)
        #expect(Metrics.renderedRowCount(itemCount: 0, rows: 2, columnsPerScreen: 4) == 1)
        #expect(Metrics.renderedRowCount(itemCount: 3, rows: 0, columnsPerScreen: 0) == 1)
    }

    @Test("页内先横后竖,空格占位,末尾不留空格")
    func cellsReadRowFirstWithinEachPage() {
        typealias Metrics = HomeQuickAccessCarouselMetrics
        #expect(Metrics.cellOrder(itemCount: 5, rows: 2, columnsPerScreen: 4) == [0, 4, 1, nil, 2, nil, 3])
        #expect(Metrics.cellOrder(itemCount: 8, rows: 2, columnsPerScreen: 4) == [0, 4, 1, 5, 2, 6, 3, 7])
        #expect(Metrics.cellOrder(itemCount: 10, rows: 2, columnsPerScreen: 4)
            == [0, 4, 1, 5, 2, 6, 3, 7, 8, nil, 9])
        #expect(Metrics.cellOrder(itemCount: 0, rows: 2, columnsPerScreen: 4).isEmpty)
    }

    @Test("两本书并排在第一行,不是一列两行")
    func twoItemsShareTheFirstRow() {
        #expect(HomeQuickAccessCarouselMetrics.cellOrder(itemCount: 2, rows: 2, columnsPerScreen: 4) == [0, 1])
        #expect(HomeQuickAccessCarouselMetrics.cellOrder(itemCount: 4, rows: 3, columnsPerScreen: 4) == [0, 1, 2, 3])
    }

    @Test("一行、或还没量到宽度只有一列时顺序不变")
    func singleRowOrSingleColumnKeepsTheOrder() {
        let sequential = Array(0..<7).map(Optional.some)
        #expect(HomeQuickAccessCarouselMetrics.cellOrder(itemCount: 7, rows: 1, columnsPerScreen: 4) == sequential)
        #expect(HomeQuickAccessCarouselMetrics.cellOrder(itemCount: 7, rows: 2, columnsPerScreen: 1) == sequential)
        #expect(HomeQuickAccessCarouselMetrics.cellOrder(itemCount: 7, rows: 3, columnsPerScreen: 0) == sequential)
    }
}
