import Foundation
import Testing
@testable import PrimuseKit

/// 数值取自 iPhone Duo 外屏模拟器(Xcode 27.1 beta,iOS 27.1)实测的遮挡区:
/// 竖握 466×678,竖排状态栏在右上 {382,0,84,170},摄像头 {399.7,29.3,37,37};
/// 横握 678×466,在左上 {0,0,84,82} 与 {29.3,29.3,37,37}(状态栏收起)。
@Suite("整屏居中界面让开遮挡区")
struct OcclusionAvoidancePolicyTests {
    private typealias Policy = OcclusionAvoidancePolicy
    private typealias Region = OcclusionAvoidancePolicy.Region

    private let portraitRegions = [
        Region(x: 382, y: 0, width: 84, height: 170),
        Region(x: 399.7, y: 29.3, width: 37, height: 37),
    ]
    private let landscapeRegions = [
        Region(x: 0, y: 0, width: 84, height: 82),
        Region(x: 29.3, y: 29.3, width: 37, height: 37),
    ]

    @Test("只有与这段高度相交的遮挡区才要让")
    func clearanceFollowsBand() {
        let top = Policy.sideClearance(regions: portraitRegions, bandMinY: 20, bandMaxY: 280, width: 466)
        #expect(top == .init(leading: 0, trailing: 84))
        let below = Policy.sideClearance(regions: portraitRegions, bandMinY: 300, bandMaxY: 640, width: 466)
        #expect(below == .zero)
        let landscape = Policy.sideClearance(regions: landscapeRegions, bandMinY: 8, bandMaxY: 52, width: 678)
        #expect(landscape == .init(leading: 84, trailing: 0))
    }

    @Test("竖握:居中的封面在遮挡区那段高度里两边各让出遮挡宽度")
    func centeredArtworkLimit() {
        let limit = Policy.centeredWidthLimit(
            regions: portraitRegions, bandMinY: 21, bandMaxY: 279, width: 466, gap: 16
        )
        #expect(limit == 266)
        // 外屏竖握播放页的封面按高度取 0.38 × 678 ≈ 258,本来就放得下,居中后不用缩。
        #expect(678 * 0.38 < limit)
        // 这段高度上没有遮挡时不设限。
        #expect(Policy.centeredWidthLimit(regions: portraitRegions, bandMinY: 200, bandMaxY: 400, width: 466, gap: 16) == 466)
        #expect(Policy.centeredWidthLimit(regions: [], bandMinY: 0, bandMaxY: 400, width: 466, gap: 16) == 466)
    }

    @Test("灵动岛展开后遮挡区变长,下面几行也要让")
    func expandedIsland() {
        let expanded = [Region(x: 382, y: 0, width: 84, height: 320)]
        #expect(Policy.lowestEdge(of: expanded) == 320)
        #expect(Policy.sideClearance(regions: expanded, bandMinY: 279, bandMaxY: 640, width: 466).trailing == 84)
        #expect(Policy.lowestEdge(of: []) == 0)
    }

    @Test("调试用的假遮挡区")
    func debugSpecification() {
        let regions = Policy.debugRegions(from: "trailing,84,170; leading,84,82", width: 466)
        #expect(regions == [
            Region(x: 382, y: 0, width: 84, height: 170),
            Region(x: 0, y: 0, width: 84, height: 82),
        ])
        #expect(Policy.debugRegions(from: nil, width: 466).isEmpty)
        #expect(Policy.debugRegions(from: "top,84,82", width: 466).isEmpty)
        #expect(Policy.debugRegions(from: "trailing,x,82", width: 466).isEmpty)
    }

    @Test("横握播放页:状态栏收起时两栏整屏居中,只有顶部圆钮排让开遮挡区")
    func compactLandscapeCentersWhenClear() {
        let insets = NowPlayingCompactLandscapeLayoutPolicy.centeredSideSafeArea(
            viewportWidth: 678, viewportHeight: 466,
            safeAreaTop: 0, safeAreaBottom: 34, safeAreaLeading: 84, safeAreaTrailing: 0,
            occlusions: landscapeRegions, prefersVolumeBar: true
        )
        #expect(insets.leading == 0)
        #expect(insets.trailing == 0)
        let metrics = NowPlayingCompactLandscapeLayoutPolicy.metrics(
            viewportWidth: 678, viewportHeight: 466,
            safeAreaTop: 0, safeAreaBottom: 34, safeAreaLeading: 0, safeAreaTrailing: 0,
            prefersVolumeBar: true
        )
        #expect(metrics.leadingInset == metrics.trailingInset)
        #expect(metrics.showsEdgeToggles)
    }

    @Test("横握播放页:遮挡区长到封面那段高度时退回按安全区让位")
    func compactLandscapeFallsBackWhenArtworkCollides() {
        let insets = NowPlayingCompactLandscapeLayoutPolicy.centeredSideSafeArea(
            viewportWidth: 678, viewportHeight: 466,
            safeAreaTop: 0, safeAreaBottom: 34, safeAreaLeading: 84, safeAreaTrailing: 0,
            occlusions: [Region(x: 0, y: 0, width: 84, height: 170)], prefersVolumeBar: true
        )
        #expect(insets.leading == 84)
        #expect(insets.trailing == 0)
        // 没有遮挡区(普通手机)时不存在居中这回事,调用方不会走这条路;这里也不假装让位。
        let none = NowPlayingCompactLandscapeLayoutPolicy.centeredSideSafeArea(
            viewportWidth: 852, viewportHeight: 393,
            safeAreaTop: 0, safeAreaBottom: 21, safeAreaLeading: 59, safeAreaTrailing: 59,
            occlusions: [], prefersVolumeBar: true
        )
        #expect(none.leading == 0)
    }
}
