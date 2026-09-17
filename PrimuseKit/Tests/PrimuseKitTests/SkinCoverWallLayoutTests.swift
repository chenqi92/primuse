import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cover wall layout")
struct SkinCoverWallLayoutTests {
    private let covers = (1...24).map { "cover-\($0)" }

    @Test("每张模板恰好铺满 5×5,无空洞无重叠")
    func templatesTileTheGridExactly() {
        for step in 0..<CoverWallLayoutPolicy.compositionCount {
            let composition = CoverWallLayoutPolicy.composition(coverIDs: covers, step: step)
            var occupied: [Int: Int] = [:]
            for tile in composition.tiles {
                #expect(tile.span == 1 || tile.span == 2)
                for column in tile.column..<(tile.column + tile.span) {
                    for row in tile.row..<(tile.row + tile.span) {
                        #expect((0..<composition.columns).contains(column))
                        #expect((0..<composition.rows).contains(row))
                        occupied[row * composition.columns + column, default: 0] += 1
                    }
                }
            }
            #expect(occupied.count == composition.columns * composition.rows, "第 \(step) 张模板有空洞")
            #expect(occupied.values.allSatisfy { $0 == 1 }, "第 \(step) 张模板有重叠")
        }
    }

    @Test("封面够用时一面墙里不重复,视图身份唯一")
    func largePoolsDoNotRepeat() {
        for step in 0..<6 {
            let composition = CoverWallLayoutPolicy.composition(coverIDs: covers, step: step)
            let coverIDs = composition.tiles.map(\.coverID)
            #expect(Set(coverIDs).count == coverIDs.count)
            #expect(Set(composition.tiles.map(\.id)).count == composition.tiles.count)
        }
    }

    @Test("封面不够时循环取用,相邻格尽量不重复,身份仍然唯一")
    func smallPoolsCycleWithoutTouching() {
        let few = ["a", "b", "c", "d", "e", "f"]
        for step in 0..<3 {
            let composition = CoverWallLayoutPolicy.composition(coverIDs: few, step: step)
            #expect(Set(composition.tiles.map(\.id)).count == composition.tiles.count)
            for first in composition.tiles {
                for second in composition.tiles where first.id != second.id {
                    guard first.coverID == second.coverID else { continue }
                    let firstSlot = CoverWallLayoutPolicy.Slot(column: first.column, row: first.row, span: first.span)
                    let secondSlot = CoverWallLayoutPolicy.Slot(column: second.column, row: second.row, span: second.span)
                    #expect(
                        !CoverWallLayoutPolicy.areAdjacent(firstSlot, secondSlot),
                        "\(first.coverID) 在第 \(step) 拍相邻出现"
                    )
                }
            }
        }
    }

    @Test("正在播放的封面占焦点位,并且只出现一次")
    func focusTakesTheLeadSlot() {
        for step in 0..<3 {
            let composition = CoverWallLayoutPolicy.composition(coverIDs: covers, step: step, focusID: "cover-9")
            let focused = composition.tiles.filter(\.isFocus)
            #expect(focused.count == 1)
            #expect(focused.first?.coverID == "cover-9")
            #expect(focused.first?.span == 2)
            #expect(composition.tiles.filter { $0.coverID == "cover-9" }.count == 1)
        }
        // 不在这面墙里的歌不抢焦点。
        let none = CoverWallLayoutPolicy.composition(coverIDs: covers, step: 0, focusID: "elsewhere")
        #expect(none.tiles.allSatisfy { !$0.isFocus })
    }

    @Test("同样的输入得到同样的构图,换拍才变")
    func compositionIsDeterministic() {
        let first = CoverWallLayoutPolicy.composition(coverIDs: covers, step: 1)
        let again = CoverWallLayoutPolicy.composition(coverIDs: covers, step: 1)
        let next = CoverWallLayoutPolicy.composition(coverIDs: covers, step: 2)
        #expect(first == again)
        #expect(first != next)
        // 负数拍与重复 id 都不应崩。
        _ = CoverWallLayoutPolicy.composition(coverIDs: covers + covers, step: -4)
        #expect(CoverWallLayoutPolicy.composition(coverIDs: [], step: 0).tiles.isEmpty)
    }

    @Test("封面太少不铺墙")
    func wallNeedsEnoughCovers() {
        #expect(!CoverWallLayoutPolicy.prefersWall(distinctCoverCount: 1))
        #expect(!CoverWallLayoutPolicy.prefersWall(distinctCoverCount: 3))
        #expect(CoverWallLayoutPolicy.prefersWall(distinctCoverCount: 4))
    }

    @Test("倾斜后的墙面盖满头图,各种屏宽都不露底")
    func geometryCoversTheHero() {
        let design = CoverWallLayoutPolicy.geometry(width: 390, height: 400)
        #expect(abs(design.cellSize - 118) < 0.001)
        #expect(abs(design.gap - 8) < 0.001)
        #expect(abs(design.originX - (-150)) < 0.001)
        #expect(abs(design.originY - (-170)) < 0.001)

        for (width, height) in [(320.0, 360.0), (390.0, 400.0), (430.0, 420.0), (744.0, 420.0),
                                (1024.0, 440.0), (1366.0, 460.0), (390.0, 844.0)] {
            let geometry = CoverWallLayoutPolicy.geometry(width: width, height: height)
            #expect(
                CoverWallLayoutPolicy.covers(width: width, height: height, geometry: geometry),
                "\(width)×\(height) 露底"
            )
        }
        #expect(CoverWallLayoutPolicy.geometry(width: 0, height: 0).cellSize == 0)
    }

    @Test("上墙的封面:每张专辑一格,没封面的不上,顺序跟着集合走")
    func poolPicksOneCoverPerGroup() {
        let candidates = [
            CoverWallCandidate(songID: "s1", groupKey: "album-a", hasKnownArtwork: true),
            CoverWallCandidate(songID: "s2", groupKey: "album-a", hasKnownArtwork: true),
            CoverWallCandidate(songID: "s3", groupKey: "album-b", hasKnownArtwork: false),
            CoverWallCandidate(songID: "s4", groupKey: "album-c", hasKnownArtwork: true),
            CoverWallCandidate(songID: "s5", groupKey: "album-b", hasKnownArtwork: true),
        ]
        let pool = CoverWallLayoutPolicy.pool(from: candidates)
        #expect(pool.map(\.songID) == ["s1", "s4", "s5"])
    }

    @Test("长歌单只取前面一段,但正在播放的那张一定在墙上")
    func poolKeepsTheFocusGroup() {
        let candidates = (0..<2000).map {
            CoverWallCandidate(songID: "s\($0)", groupKey: "album-\($0)", hasKnownArtwork: true)
        }
        let plain = CoverWallLayoutPolicy.pool(from: candidates, limit: 24)
        #expect(plain.count == 24)
        #expect(plain.last?.songID == "s23")

        let focused = CoverWallLayoutPolicy.pool(from: candidates, focusGroupKey: "album-900", limit: 24)
        #expect(focused.count == 24)
        #expect(focused.contains { $0.groupKey == "album-900" })
        #expect(Set(focused.map(\.groupKey)).count == 24)

        // 焦点已经在前 24 张里时不重复加入。
        let early = CoverWallLayoutPolicy.pool(from: candidates, focusGroupKey: "album-3", limit: 24)
        #expect(early.filter { $0.groupKey == "album-3" }.count == 1)
        #expect(early.count == 24)

        // 找不到焦点也要收手,不能把几万首扫到底。
        let missing = CoverWallLayoutPolicy.pool(
            from: candidates,
            focusGroupKey: "not-here",
            limit: 24,
            scanLimit: 100
        )
        #expect(missing.count == 24)
        #expect(CoverWallLayoutPolicy.pool(from: candidates, limit: 0).isEmpty)
    }

    @Test("一格在墙平面里的位置")
    func tileFrames() {
        let geometry = CoverWallLayoutPolicy.geometry(width: 390, height: 400)
        let tile = CoverWallTile(id: "x", coverID: "x", column: 1, row: 2, span: 2, isFocus: false)
        let frame = geometry.frame(of: tile)
        #expect(abs(frame.x - 126) < 0.001)
        #expect(abs(frame.y - 252) < 0.001)
        #expect(abs(frame.side - 244) < 0.001)
    }

    // MARK: - 铺满整屏

    @Test("整屏墙面由两张模板拼成,铺满且无重叠;竖屏上下拼、横屏左右拼")
    func stageCompositionTilesTheWholePlane() {
        for isLandscape in [false, true] {
            for step in 0..<(CoverWallLayoutPolicy.compositionCount * 2) {
                let composition = CoverWallLayoutPolicy.stageComposition(
                    coverIDs: covers,
                    step: step,
                    isLandscape: isLandscape
                )
                #expect(composition.columns == (isLandscape ? 10 : 5))
                #expect(composition.rows == (isLandscape ? 5 : 10))
                var occupied: [Int: Int] = [:]
                for tile in composition.tiles {
                    for column in tile.column..<(tile.column + tile.span) {
                        for row in tile.row..<(tile.row + tile.span) {
                            #expect((0..<composition.columns).contains(column))
                            #expect((0..<composition.rows).contains(row))
                            occupied[row * composition.columns + column, default: 0] += 1
                        }
                    }
                }
                #expect(occupied.count == composition.columns * composition.rows)
                #expect(occupied.values.allSatisfy { $0 == 1 })
                #expect(Set(composition.tiles.map(\.id)).count == composition.tiles.count)
                #expect(composition.tiles.allSatisfy { !$0.isFocus })
            }
        }
    }

    @Test("整屏墙面里同一张封面不挨着出现,接缝两侧也一样")
    func stageCompositionKeepsRepeatsApart() {
        // 全屏效果拿到的封面通常只有十来张,远少于三十来个格子,重复是常态。
        let dozen = (1...12).map { "cover-\($0)" }
        for isLandscape in [false, true] {
            for step in 0..<CoverWallLayoutPolicy.compositionCount {
                let composition = CoverWallLayoutPolicy.stageComposition(
                    coverIDs: dozen,
                    step: step,
                    isLandscape: isLandscape
                )
                for first in composition.tiles {
                    for second in composition.tiles where first.id != second.id {
                        guard first.coverID == second.coverID else { continue }
                        let firstSlot = CoverWallLayoutPolicy.Slot(column: first.column, row: first.row, span: first.span)
                        let secondSlot = CoverWallLayoutPolicy.Slot(column: second.column, row: second.row, span: second.span)
                        #expect(
                            !CoverWallLayoutPolicy.areAdjacent(firstSlot, secondSlot),
                            "\(first.coverID) 在第 \(step) 拍相邻出现(横屏: \(isLandscape))"
                        )
                    }
                }
            }
        }
    }

    @Test("整屏墙面每一拍都换构图,没有封面时不出格子")
    func stageCompositionChangesEveryStep() {
        let first = CoverWallLayoutPolicy.stageComposition(coverIDs: covers, step: 0, isLandscape: false)
        let next = CoverWallLayoutPolicy.stageComposition(coverIDs: covers, step: 1, isLandscape: false)
        #expect(first != next)
        #expect(first == CoverWallLayoutPolicy.stageComposition(coverIDs: covers, step: 0, isLandscape: false))
        let empty = CoverWallLayoutPolicy.stageComposition(coverIDs: [], step: 0, isLandscape: true)
        #expect(empty.tiles.isEmpty)
        #expect(empty.columns == 10)
    }

    @Test("倾斜之后仍盖满各种屏幕,漂移的余量也算在内")
    func stageGeometryCoversEveryScreen() {
        let screens: [(Double, Double)] = [
            (390, 844), (844, 390), (375, 667), (466, 678), (430, 932),
            (820, 1180), (1180, 820), (1366, 1024), (1728, 1080), (1920, 1080), (2560, 1080),
        ]
        for (width, height) in screens {
            let isLandscape = width > height
            let columns = isLandscape ? 10 : 5
            let rows = isLandscape ? 5 : 10
            let overscan = min(width, height) * 0.04
            let geometry = CoverWallLayoutPolicy.stageGeometry(
                width: width,
                height: height,
                columns: columns,
                rows: rows,
                overscan: overscan
            )
            #expect(
                CoverWallLayoutPolicy.covers(
                    width: width,
                    height: height,
                    geometry: geometry,
                    columns: columns,
                    rows: rows,
                    margin: overscan
                ),
                "\(Int(width))×\(Int(height)) 露底"
            )
            // 墙面中心就是画面中心。
            let centerX = geometry.originX + geometry.planeLength(cells: columns) / 2
            let centerY = geometry.originY + geometry.planeLength(cells: rows) / 2
            #expect(abs(centerX - width / 2) < 0.001)
            #expect(abs(centerY - height / 2) < 0.001)
            // 格子保持在「一面墙」的尺度:不小到认不出封面,也不大到一格占掉半个屏幕。
            let shortSide = min(width, height)
            #expect(geometry.cellSize > shortSide * 0.18, "\(Int(width))×\(Int(height)) 格子过小")
            #expect(geometry.cellSize < shortSide * 0.40, "\(Int(width))×\(Int(height)) 格子过大")
        }
        let degenerate = CoverWallLayoutPolicy.stageGeometry(width: 0, height: 100, columns: 5, rows: 10)
        #expect(degenerate.cellSize == 0)
    }
}
