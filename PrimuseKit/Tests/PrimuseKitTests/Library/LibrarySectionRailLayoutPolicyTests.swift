import Foundation
import Testing
@testable import PrimuseKit

/// 空当取自 iPhone Duo 外屏竖握(466×678)实测:资料库首页竖排状态栏以下到标签栏约 170–428,
/// 专辑页多了返回和一颗页面按钮约 220–428,歌曲页收成返回 +「⋯」后约 280–428;
/// 各扣掉上下与系统胶囊之间的 12。分类是常见的六个(歌曲、专辑、艺人、流派、发行日期、歌单)。
@Suite("Duo 竖栏里资料库分类的排法")
struct LibrarySectionRailLayoutPolicyTests {
    private typealias Policy = LibrarySectionRailLayoutPolicy

    @Test("首页空当够:六个分类全部露出,不滑")
    func hubShowsEverything() throws {
        let layout = try #require(Policy.layout(available: 258 - 24, itemCount: 6))
        #expect(layout.pitch == 37)
        #expect(layout.visibleCount == 6)
        #expect(!layout.scrolls)
        #expect(layout.height == 230)
        #expect(layout.maximumOffset == 0)
    }

    @Test("空当很宽裕时格距不超过系统标签栏那一档")
    func roomyCapsAtPreferredPitch() throws {
        let layout = try #require(Policy.layout(available: 400, itemCount: 6))
        #expect(layout.pitch == Policy.preferredPitch)
        #expect(layout.height == 6 * Policy.preferredPitch + 2 * Policy.inset)
    }

    @Test("专辑页压到最小格距也放不下:露五格整格,能滑一格")
    func albumsPageScrollsByWholeItems() throws {
        let layout = try #require(Policy.layout(available: 208 - 24, itemCount: 6))
        #expect(layout.visibleCount == 5)
        #expect(layout.pitch == 35)
        #expect(layout.scrolls)
        #expect(layout.height == 183)
        #expect(layout.maximumOffset == 35)
    }

    @Test("歌曲页只剩一百二十来点:露三格,格距回到宽松那一档")
    func songsPageShowsThree() throws {
        let layout = try #require(Policy.layout(available: 148 - 24, itemCount: 6))
        #expect(layout.visibleCount == 3)
        #expect(layout.pitch == 38)
        #expect(layout.height <= 124)
        #expect(layout.maximumOffset == 3 * 38)
    }

    @Test("露不出三格就不摆在竖栏里;分类本来就少时按分类数算")
    func tooShortFallsBack() {
        #expect(Policy.layout(available: 90, itemCount: 6) == nil)
        #expect(Policy.layout(available: 70, itemCount: 2)?.visibleCount == 2)
        #expect(Policy.layout(available: 0, itemCount: 6) == nil)
        #expect(Policy.layout(available: 300, itemCount: 0) == nil)
        #expect(Policy.layout(available: .infinity, itemCount: 6) == nil)
    }

    @Test("选中的分类停在露出那几格的中间,靠头靠尾时贴边")
    func selectionStaysCentered() throws {
        let layout = try #require(Policy.layout(available: 124, itemCount: 6))
        #expect(Policy.firstVisibleIndex(selectedIndex: 0, layout: layout) == 0)
        #expect(Policy.firstVisibleIndex(selectedIndex: 1, layout: layout) == 0)
        #expect(Policy.firstVisibleIndex(selectedIndex: 2, layout: layout) == 1)
        #expect(Policy.firstVisibleIndex(selectedIndex: 4, layout: layout) == 3)
        #expect(Policy.firstVisibleIndex(selectedIndex: 5, layout: layout) == 3)
        #expect(Policy.firstVisibleIndex(selectedIndex: nil, layout: layout) == 0)
        #expect(Policy.offset(selectedIndex: 3, layout: layout) == 2 * 38)

        let all = try #require(Policy.layout(available: 400, itemCount: 6))
        #expect(Policy.firstVisibleIndex(selectedIndex: 5, layout: all) == 0)
    }

    @Test("松手后停在最近的整格上,不越过两头")
    func snapsToWholeItems() throws {
        let layout = try #require(Policy.layout(available: 124, itemCount: 6))
        #expect(Policy.snappedOffset(20, layout: layout) == 38)
        #expect(Policy.snappedOffset(18, layout: layout) == 0)
        #expect(Policy.snappedOffset(-40, layout: layout) == 0)
        #expect(Policy.snappedOffset(1000, layout: layout) == layout.maximumOffset)
        #expect(Policy.snappedOffset(.nan, layout: layout) == 0)
    }
}
