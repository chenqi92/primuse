import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song list tile grid")
struct SongTileGridPolicyTests {
    @Test("竖屏手机两列，最窄的屏也是两列")
    func portraitPhonesUseTwoColumns() {
        // 320（SE 一代）、375、393、440 点宽，各减去左右留白。
        for width in [320.0, 375, 393, 402, 440] {
            let available = CGFloat(width) - SongTileGridPolicy.horizontalInset * 2
            #expect(SongTileGridPolicy.columnCount(availableWidth: available, accessibilitySize: false) == 2)
        }
    }

    @Test("横屏与 iPad 按最小块宽加列，宽屏封顶")
    func widerContainersAddColumnsByMinimumTileWidth() {
        let landscape = SongTileGridPolicy.columnCount(availableWidth: 734 - 32, accessibilitySize: false)
        #expect(landscape == 4)
        let padPortrait = SongTileGridPolicy.columnCount(availableWidth: 820 - 32, accessibilitySize: false)
        #expect(padPortrait == 4)
        let padLandscape = SongTileGridPolicy.columnCount(availableWidth: 1180 - 32, accessibilitySize: false)
        #expect(padLandscape == 6)
        let huge = SongTileGridPolicy.columnCount(availableWidth: 5000, accessibilitySize: false)
        #expect(huge == SongTileGridPolicy.maximumColumns)
        for width in stride(from: 300.0, through: 2000, by: 7) {
            let columns = SongTileGridPolicy.columnCount(availableWidth: CGFloat(width), accessibilitySize: false)
            let side = SongTileGridPolicy.tileSide(availableWidth: CGFloat(width), columns: columns)
            if columns > 2 && columns < SongTileGridPolicy.maximumColumns {
                #expect(side >= SongTileGridPolicy.minimumTileWidth)
            }
            let used = side * CGFloat(columns) + SongTileGridPolicy.spacing * CGFloat(columns - 1)
            #expect(used <= CGFloat(width) + 0.001)
        }
    }

    @Test("辅助功能字号一列；宽度异常时退回两列")
    func accessibilityAndDegenerateWidths() {
        #expect(SongTileGridPolicy.columnCount(availableWidth: 1200, accessibilitySize: true) == 1)
        #expect(SongTileGridPolicy.columnCount(availableWidth: 0, accessibilitySize: false) == 2)
        #expect(SongTileGridPolicy.columnCount(availableWidth: .nan, accessibilitySize: false) == 2)
        #expect(SongTileGridPolicy.columnCount(availableWidth: .infinity, accessibilitySize: false) == 2)
        #expect(SongTileGridPolicy.tileSide(availableWidth: .nan, columns: 2) == 0)
        #expect(SongTileGridPolicy.tileSide(availableWidth: 10, columns: 4) == 0)
    }

    @Test("按行填列")
    func columnsFillRowByRow() {
        #expect(SongTileGridPolicy.column(forIndex: 0, columns: 2) == 0)
        #expect(SongTileGridPolicy.column(forIndex: 3, columns: 2) == 1)
        #expect(SongTileGridPolicy.column(forIndex: 7, columns: 4) == 3)
        #expect(SongTileGridPolicy.column(forIndex: 5, columns: 0) == 0)
        #expect(SongTileGridPolicy.column(forIndex: -1, columns: 3) == 2)
    }
}

@Suite("Song tile scroll motion")
struct SongTileScrollMotionTests {
    private let tile: CGFloat = 180
    private let viewport: CGFloat = 640

    private func motion(_ top: CGFloat, column: Int = 0, columns: Int = 2, reduce: Bool = false) -> SongTileScrollMotion {
        SongTileScrollMotion(tileMinY: top, tileHeight: tile, viewportHeight: viewport,
                             column: column, columnCount: columns, reduceMotion: reduce)
    }

    @Test("完全在可视区中部的块原样不动")
    func settledTileIsIdentity() {
        let settled = motion(220)
        #expect(settled.scale == 1)
        #expect(settled.tilt == 0)
        #expect(settled.opacity == 1)
        #expect(settled.dim == 0)
    }

    @Test("从底部进入：由小放大、前倾回正、由半透明变实")
    func enteringTilesGrowAndStraighten() {
        let entering = motion(viewport)
        #expect(abs(entering.scale - SongTileScrollMotion.enteringScale) < 0.0001)
        #expect(abs(entering.tilt - SongTileScrollMotion.enteringTilt) < 0.0001)
        #expect(abs(entering.opacity - SongTileScrollMotion.enteringOpacity) < 0.0001)
        var previous = entering
        for top in stride(from: viewport, through: 200, by: -4) {
            let current = motion(top)
            #expect(current.scale >= previous.scale - 0.0001)
            #expect(current.tilt <= previous.tilt + 0.0001)
            #expect(current.opacity >= previous.opacity - 0.0001)
            previous = current
        }
        #expect(previous.scale == 1)
        #expect(previous.tilt == 0)
        #expect(previous.opacity == 1)
    }

    @Test("停在最上面的第一排保持原样，滑进顶栏下面才开始离开")
    func restingFirstRowIsUntouched() {
        for column in 0..<2 {
            for top in [0.0, 12] {
                let resting = motion(CGFloat(top), column: column)
                #expect(resting.scale == 1)
                #expect(resting.tilt == 0)
                #expect(resting.dim == 0)
            }
        }
        #expect(motion(-20).dim > 0)
    }

    @Test("靠近顶部离开：轻微缩小、压暗、后仰")
    func leavingTilesShrinkDimAndLeanBack() {
        let leaving = motion(-tile)
        #expect(leaving.scale < 1)
        #expect(leaving.scale >= SongTileScrollMotion.leavingScale - 0.0001)
        #expect(leaving.dim > 0)
        #expect(leaving.tilt < 0)
        #expect(leaving.opacity == 1)
    }

    @Test("同一排后几列晚一点，读起来像一道波")
    func laterColumnsLagBehind() {
        let top = viewport - tile * 0.6
        let first = motion(top, column: 0)
        let second = motion(top, column: 1)
        #expect(second.scale < first.scale)
        #expect(second.tilt > first.tilt)
        // 一列时没有相位差。
        #expect(motion(top, column: 3, columns: 1) == motion(top, column: 0, columns: 1))
        // 列号越界按最后一列算。
        #expect(motion(top, column: 9, columns: 4) == motion(top, column: 3, columns: 4))
    }

    @Test("缩放加透视也画不出自己的格子；视差不露底")
    func motionStaysInsideItsCell() {
        for columns in 1...6 {
            for column in 0..<columns {
                for top in stride(from: -tile * 2, through: viewport + tile, by: 3) {
                    let current = motion(top, column: column, columns: columns)
                    #expect(current.scale <= 1)
                    #expect(current.projectedExtent <= 1)
                    let margin = tile * (SongTileScrollMotion.artworkOverscan - 1) / 2
                    #expect(abs(current.parallax) <= margin)
                }
            }
        }
    }

    @Test("视差上下对称：块在下半部封面偏上，上半部偏下")
    func parallaxIsSymmetric() {
        let below = SongTileScrollMotion.parallax(tileMidY: viewport / 2 + 150, tileHeight: tile, viewportHeight: viewport)
        let above = SongTileScrollMotion.parallax(tileMidY: viewport / 2 - 150, tileHeight: tile, viewportHeight: viewport)
        #expect(below < 0)
        #expect(abs(below + above) < 0.0001)
        #expect(SongTileScrollMotion.parallax(tileMidY: viewport / 2, tileHeight: tile, viewportHeight: viewport) == 0)
    }

    @Test("输入夹取、NaN 安全；减少动态效果时完全静止")
    func degenerateInputsAndReducedMotion() {
        for top in [CGFloat.nan, .infinity, -.infinity] {
            #expect(motion(top) == .identity)
        }
        #expect(SongTileScrollMotion(tileMinY: 10, tileHeight: 0, viewportHeight: viewport,
                                     column: 0, columnCount: 2, reduceMotion: false) == .identity)
        #expect(SongTileScrollMotion(tileMinY: 10, tileHeight: tile, viewportHeight: .nan,
                                     column: 0, columnCount: 2, reduceMotion: false) == .identity)
        #expect(motion(-100_000) == motion(-10_000))
        #expect(motion(100_000).scale == motion(10_000).scale)
        for top in stride(from: -400.0, through: 1200, by: 37) {
            #expect(motion(CGFloat(top), column: 1, reduce: true) == .identity)
        }
        #expect(SongTileScrollMotion.parallax(tileMidY: .nan, tileHeight: tile, viewportHeight: viewport) == 0)
    }
}

@Suite("Song focus scroll motion")
struct SongFocusScrollMotionTests {
    private func motion(_ midY: CGFloat, pitch: CGFloat = 94, card: CGFloat = 84,
                        viewport: CGFloat = 640, reduce: Bool = false) -> SongFocusScrollMotion {
        SongFocusScrollMotion(rowMidY: midY, rowPitch: pitch, cardHeight: card,
                              viewportHeight: viewport, reduceMotion: reduce)
    }

    @Test("正中的一两行完整大小，封面带阴影")
    func centerRowsAreFullSize() {
        for offset in [-40.0, 0, 40] {
            let centered = motion(320 + CGFloat(offset))
            #expect(centered.scale == 1)
            #expect(centered.opacity == 1)
            #expect(centered.coverTurn == 0)
            #expect(centered.offset == 0)
        }
        #expect(motion(320).emphasis == 1)
        #expect(motion(40).emphasis == 0)
    }

    @Test("离中心越远越小、越淡、转得越开，上下对称")
    func motionGrowsWithDistanceAndIsSymmetric() {
        var previous = motion(320)
        for distance in stride(from: 0.0, through: 420, by: 5) {
            let below = motion(320 + CGFloat(distance))
            let above = motion(320 - CGFloat(distance))
            #expect(abs(below.scale - above.scale) < 0.0001)
            #expect(abs(below.opacity - above.opacity) < 0.0001)
            #expect(abs(below.coverTurn - above.coverTurn) < 0.0001)
            #expect(abs(below.offset + above.offset) < 0.0001)
            #expect(below.offset <= 0)
            #expect(above.offset >= 0)
            #expect(below.scale <= previous.scale + 0.0001)
            #expect(below.coverTurn >= previous.coverTurn - 0.0001)
            #expect(below.scale >= SongFocusScrollMotion.minimumScale - 0.0001)
            #expect(below.opacity >= SongFocusScrollMotion.minimumOpacity - 0.0001)
            #expect(below.coverTurn <= SongFocusScrollMotion.maximumCoverTurn + 0.0001)
            previous = below
        }
        // 边缘几行确实往中心收拢了。
        #expect(motion(620).offset < -8)
        #expect(motion(20).offset > 8)
    }

    @Test("收拢不压邻：任意位置相邻两张卡之间至少留出最小间隙")
    func adjacentCardsNeverOverlap() {
        for viewport in [120.0, 200, 260, 300, 420, 560, 640, 760, 900, 1300] {
            for card in [84.0, 110, 160, 230] {
                let pitch = CGFloat(card) + 10
                var midY = -pitch * 3
                while midY < CGFloat(viewport) + pitch * 3 {
                    let upper = motion(midY, pitch: pitch, card: CGFloat(card), viewport: CGFloat(viewport))
                    let lower = motion(midY + pitch, pitch: pitch, card: CGFloat(card), viewport: CGFloat(viewport))
                    let upperBottom = midY + upper.offset + upper.scale * CGFloat(card) / 2
                    let lowerTop = midY + pitch + lower.offset - lower.scale * CGFloat(card) / 2
                    #expect(lowerTop - upperBottom >= SongFocusScrollMotion.minimumGap - 0.5,
                            "viewport \(viewport) card \(card) midY \(midY)")
                    midY += 2
                }
            }
        }
    }

    @Test("输入夹取、NaN 安全；减少动态效果时完全静止")
    func degenerateInputsAndReducedMotion() {
        for value in [CGFloat.nan, .infinity, -.infinity] {
            #expect(motion(value) == .identity)
            #expect(motion(100, pitch: value) == .identity)
            #expect(motion(100, viewport: value) == .identity)
        }
        #expect(motion(100, pitch: 0) == .identity)
        #expect(motion(100, card: 0) == .identity)
        for midY in stride(from: -300.0, through: 1000, by: 23) {
            #expect(motion(CGFloat(midY), reduce: true) == .identity)
        }
        // 卡比行距还高时按行距算，不会因此算出负间隙。
        let tall = motion(600, pitch: 90, card: 200)
        #expect(tall.scale >= SongFocusScrollMotion.minimumScale)
        #expect(motion(10_000).scale == motion(100_000).scale)
    }
}
