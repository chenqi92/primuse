import Foundation
import Testing
@testable import PrimuseKit

@Suite("桌面半折上下两半的分栏")
struct TabletopColumnsPolicyTests {
    private typealias Policy = TabletopColumnsPolicy

    @Test("上半屏有歌词时左封面右歌词")
    func topHalfSplits() throws {
        // Duo 内屏竖握半折（模拟器 669 宽），上半屏留给封面约 400 高：封面按宽度比例取。
        let top = Policy.topHalf(width: 669, height: 400, wantsTextColumn: true)
        let text = try #require(top.textColumnWidth)
        #expect(top.artworkSide == 262)
        #expect(text == 335)
        // 两栏加间距和两侧留白正好铺满。
        #expect(top.artworkSide + text + Policy.columnGap + Policy.outerPadding * 2 == 669)
        // 按推算的 626 宽也放得下两栏。
        #expect(Policy.topHalf(width: 626, height: 400, wantsTextColumn: true).hasTextColumn)
    }

    @Test("上半屏很矮时封面按高度取，歌词那一栏变宽")
    func topHalfLimitedByHeight() {
        let top = Policy.topHalf(width: 669, height: 200, wantsTextColumn: true)
        #expect(top.artworkSide == 200)
        #expect(top.textColumnWidth == 397)
    }

    @Test("没有歌词、太窄或太矮时封面整幅居中")
    func topHalfFallsBackToCentered() {
        let noLyrics = Policy.topHalf(width: 669, height: 400, wantsTextColumn: false)
        #expect(noLyrics == .init(artworkSide: 400, textColumnWidth: nil))
        // 窄到歌词一栏不足 260：不分栏。
        #expect(!Policy.topHalf(width: 520, height: 400, wantsTextColumn: true).hasTextColumn)
        // 矮到封面不足 140：不分栏。
        #expect(!Policy.topHalf(width: 669, height: 120, wantsTextColumn: true).hasTextColumn)
        // 居中时左右各留 48。
        #expect(Policy.topHalf(width: 400, height: 500, wantsTextColumn: false).artworkSide == 304)
    }

    @Test("上半屏尺寸异常时什么都不摆")
    func topHalfDegenerate() {
        #expect(Policy.topHalf(width: 0, height: 400, wantsTextColumn: true) == .init(artworkSide: 0, textColumnWidth: nil))
        #expect(Policy.topHalf(width: 669, height: -10, wantsTextColumn: true).artworkSide == 0)
        #expect(Policy.topHalf(width: .nan, height: 400, wantsTextColumn: true).artworkSide == 0)
    }

    @Test("下半屏队列不止一首时左控件右列表")
    func bottomHalfSplits() throws {
        let bottom = Policy.bottomHalf(width: 669, wantsList: true)
        #expect(bottom.controlsWidth == 374)
        #expect(bottom.listWidth == 295)
        // 推算的 626 宽：控件一栏保底 360。
        let narrow = Policy.bottomHalf(width: 626, wantsList: true)
        #expect(narrow.controlsWidth == 360)
        #expect(narrow.listWidth == 266)
        // 很宽时控件一栏不超过 440，多出来的给列表。
        #expect(Policy.bottomHalf(width: 1000, wantsList: true).controlsWidth == 440)
    }

    @Test("下半屏没有列表可放或太窄时控件占满整幅")
    func bottomHalfFallsBack() {
        #expect(Policy.bottomHalf(width: 669, wantsList: false) == .init(controlsWidth: 669, listWidth: nil))
        // 列表一栏不足 220：不分栏。
        #expect(Policy.bottomHalf(width: 560, wantsList: true) == .init(controlsWidth: 560, listWidth: nil))
        #expect(Policy.bottomHalf(width: .infinity, wantsList: true).controlsWidth == 0)
    }
}
