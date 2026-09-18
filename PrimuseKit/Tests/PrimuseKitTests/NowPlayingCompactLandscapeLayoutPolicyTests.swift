import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now Playing compact landscape layout policy")
struct NowPlayingCompactLandscapeLayoutPolicyTests {
    private typealias Policy = NowPlayingCompactLandscapeLayoutPolicy
    private typealias Metrics = NowPlayingCompactLandscapeLayoutPolicy.Metrics

    /// iPhone SE 3 横屏：Home 键机型，四边都没有安全区。
    private var iPhoneSE: Metrics {
        Policy.metrics(
            viewportWidth: 667,
            viewportHeight: 375,
            safeAreaTop: 0,
            safeAreaBottom: 0,
            safeAreaLeading: 0,
            safeAreaTrailing: 0,
            prefersVolumeBar: true
        )
    }

    /// iPhone 15 / 16 横屏：左右各 59 的传感器区，底部 21 的 Home 指示条。
    private var iPhone15: Metrics {
        Policy.metrics(
            viewportWidth: 852,
            viewportHeight: 393,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 59,
            safeAreaTrailing: 59,
            prefersVolumeBar: true
        )
    }

    /// iPhone 16 Pro Max 横屏。
    private var iPhone16ProMax: Metrics {
        Policy.metrics(
            viewportWidth: 956,
            viewportHeight: 440,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 62,
            safeAreaTrailing: 62,
            prefersVolumeBar: true
        )
    }

    /// iPhone Duo 外屏横屏：左右安全区**不对称**，右侧为 0。
    private var iPhoneDuoCover: Metrics {
        Policy.metrics(
            viewportWidth: 678,
            viewportHeight: 466,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 20,
            safeAreaTrailing: 0,
            prefersVolumeBar: true
        )
    }

    private func horizontalTotal(_ metrics: Metrics) -> Double {
        metrics.leadingInset
            + metrics.artworkColumnWidth
            + metrics.columnSpacing
            + metrics.detailColumnWidth
            + metrics.trailingInset
    }

    @Test("四个目标视口横向都不超出：两侧内边距 + 封面列 + 间距 + 右栏 ≤ 视口宽")
    func horizontalBudgetFitsEveryViewport() {
        let seTotal = horizontalTotal(iPhoneSE)
        let seLimit = 667.5
        #expect(seTotal <= seLimit)

        let phoneTotal = horizontalTotal(iPhone15)
        let phoneLimit = 852.5
        #expect(phoneTotal <= phoneLimit)

        let maxTotal = horizontalTotal(iPhone16ProMax)
        let maxLimit = 956.5
        #expect(maxTotal <= maxLimit)

        let duoTotal = horizontalTotal(iPhoneDuoCover)
        let duoLimit = 678.5
        #expect(duoTotal <= duoLimit)
    }

    @Test("左右安全区按侧消费，不假设两侧相等")
    func asymmetricSafeAreaIsConsumedPerSide() {
        let duo = iPhoneDuoCover
        #expect(duo.leadingInset == 40)
        #expect(duo.trailingInset == 20)

        let phone = iPhone15
        #expect(phone.leadingInset == 79)
        #expect(phone.trailingInset == 79)
    }

    @Test("右栏宽度放得下判定为显示的那套传输键")
    func detailColumnFitsResolvedTransportRow() {
        for metrics in [iPhoneSE, iPhone15, iPhone16ProMax, iPhoneDuoCover] {
            let required = Policy.minimumTransportWidth(
                includesEdgeToggles: metrics.showsEdgeToggles
            )
            #expect(metrics.detailColumnWidth >= required)
        }
    }

    @Test("四个目标视口都放得下两端的随机 / 循环")
    func edgeTogglesFitOnEveryTargetViewport() {
        #expect(iPhoneSE.showsEdgeToggles)
        #expect(iPhone15.showsEdgeToggles)
        #expect(iPhone16ProMax.showsEdgeToggles)
        #expect(iPhoneDuoCover.showsEdgeToggles)
    }

    @Test("封面不超过可用高度，也不低于合理下限")
    func artworkStaysWithinHeightAndAboveFloor() {
        for metrics in [iPhoneSE, iPhone15, iPhone16ProMax, iPhoneDuoCover] {
            #expect(metrics.artworkSize <= metrics.availableContentHeight)
            #expect(metrics.artworkSize >= 180)
        }

        let se = iPhoneSE
        #expect(se.artworkSize > 238)
        #expect(se.artworkSize < 239)

        let proMax = iPhone16ProMax
        #expect(proMax.artworkSize > 300)
        #expect(proMax.artworkSize < 302)
    }

    @Test("可用高度很矮时封面由高度决定，不再吃满宽度")
    func artworkIsClampedByHeightOnShortViewports() {
        let shortViewport = Policy.metrics(
            viewportWidth: 900,
            viewportHeight: 220,
            safeAreaTop: 0,
            safeAreaBottom: 0,
            safeAreaLeading: 0,
            safeAreaTrailing: 0,
            prefersVolumeBar: false
        )
        #expect(shortViewport.availableContentHeight == 152)
        #expect(shortViewport.artworkSize == 152)
    }

    @Test("纵向各块之和不超过可用高度")
    func verticalBudgetFitsEveryViewport() {
        for metrics in [iPhoneSE, iPhone15, iPhone16ProMax, iPhoneDuoCover] {
            #expect(metrics.detailStackHeight <= metrics.availableContentHeight)
        }
    }

    @Test("四个目标视口都留得下当前歌词行")
    func lyricLineFitsOnEveryTargetViewport() {
        #expect(iPhoneSE.showsLyricLine)
        #expect(iPhone15.showsLyricLine)
        #expect(iPhone16ProMax.showsLyricLine)
        #expect(iPhoneDuoCover.showsLyricLine)
        #expect(iPhoneSE.lyricLineHeight == 24)
    }

    @Test("默认字号下四个目标视口的歌名都还能占两行")
    func titleKeepsTwoLinesAtDefaultTextSize() {
        #expect(iPhoneSE.titleLineLimit == 2)
        #expect(iPhone15.titleLineLimit == 2)
        #expect(iPhone16ProMax.titleLineLimit == 2)
        #expect(iPhoneDuoCover.titleLineLimit == 2)
    }

    @Test("SE 的高度装不下音量条，Pro Max 与 Duo 外屏装得下")
    func volumeBarOnlyAppearsWhereHeightAllows() {
        #expect(!iPhoneSE.showsVolumeBar)
        #expect(!iPhone15.showsVolumeBar)
        #expect(iPhone16ProMax.showsVolumeBar)
        #expect(iPhoneDuoCover.showsVolumeBar)
    }

    @Test("设置里关掉音量条时，再高的视口也不显示")
    func volumeBarStaysHiddenWhenSettingIsOff() {
        let withoutSetting = Policy.metrics(
            viewportWidth: 956,
            viewportHeight: 440,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 62,
            safeAreaTrailing: 62,
            prefersVolumeBar: false
        )
        #expect(!withoutSetting.showsVolumeBar)
    }

    @Test("更窄更矮的视口先丢两端开关，再丢歌词行")
    func narrowViewportDropsEdgeTogglesAndLyricLine() {
        let narrow = Policy.metrics(
            viewportWidth: 568,
            viewportHeight: 320,
            safeAreaTop: 0,
            safeAreaBottom: 0,
            safeAreaLeading: 0,
            safeAreaTrailing: 0,
            prefersVolumeBar: true
        )
        #expect(!narrow.showsEdgeToggles)
        #expect(!narrow.showsLyricLine)
        #expect(!narrow.showsVolumeBar)
        #expect(narrow.detailColumnWidth >= 236)
    }

    private func iPhone15Metrics(textScale: Double) -> Metrics {
        Policy.metrics(
            viewportWidth: 852,
            viewportHeight: 393,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 59,
            safeAreaTrailing: 59,
            prefersVolumeBar: true,
            textScale: textScale
        )
    }

    @Test("动态字号等级折算：默认档是 1，辅助功能档夹在上限")
    func dynamicTypeScaleTable() {
        #expect(Policy.textScale(forDynamicTypeIndex: 3) == 1)
        #expect(Policy.textScale(forDynamicTypeIndex: 0) < 1)
        #expect(Policy.textScale(forDynamicTypeIndex: 4) > 1)
        #expect(Policy.textScale(forDynamicTypeIndex: 11) == 2)
        // 越界（读不出等级）按默认档处理，不能把布局算崩。
        #expect(Policy.textScale(forDynamicTypeIndex: -1) == 1)
        #expect(Policy.textScale(forDynamicTypeIndex: 99) == 1)
        #expect(Policy.dynamicTypeTextScales.count == 12)
    }

    @Test("让步顺序：先丢音量条，再把歌名收一行，最后才丢歌词行")
    func concessionLadderOrder() {
        // Pro Max 默认档三样都在。
        let base = iPhone16ProMax
        #expect(base.showsVolumeBar)
        #expect(base.titleLineLimit == 2)
        #expect(base.showsLyricLine)

        // 大一档：音量条先走，歌名与歌词行都留着。
        let oneStepUp = Policy.metrics(
            viewportWidth: 956,
            viewportHeight: 440,
            safeAreaTop: 0,
            safeAreaBottom: 21,
            safeAreaLeading: 62,
            safeAreaTrailing: 62,
            prefersVolumeBar: true,
            textScale: 1.12
        )
        #expect(!oneStepUp.showsVolumeBar)
        #expect(oneStepUp.titleLineLimit == 2)
        #expect(oneStepUp.showsLyricLine)

        // 再大：歌名收成一行，歌词行还在。
        let squeezed = iPhone15Metrics(textScale: 1.12)
        #expect(!squeezed.showsVolumeBar)
        #expect(squeezed.titleLineLimit == 1)
        #expect(squeezed.showsLyricLine)
        #expect(squeezed.lyricLineHeight > 24)

        // 辅助功能档：歌词行才让出去。
        let accessibility = iPhone15Metrics(textScale: 1.65)
        #expect(accessibility.titleLineLimit == 1)
        #expect(!accessibility.showsLyricLine)
        #expect(!accessibility.showsVolumeBar)
    }

    @Test("最大字号下右栏仍然放得进可用高度")
    func largestTextScaleStillFits() {
        for scale in [1.0, 1.12, 1.35, 1.65, 2.0] {
            let metrics = iPhone15Metrics(textScale: scale)
            #expect(metrics.detailStackHeight <= metrics.availableContentHeight)
            let se = Policy.metrics(
                viewportWidth: 667,
                viewportHeight: 375,
                safeAreaTop: 0,
                safeAreaBottom: 0,
                safeAreaLeading: 0,
                safeAreaTrailing: 0,
                prefersVolumeBar: true,
                textScale: scale
            )
            #expect(se.detailStackHeight <= se.availableContentHeight)
        }
    }

    @Test("异常输入不会算出负数")
    func degenerateInputStaysNonNegative() {
        let degenerate = Policy.metrics(
            viewportWidth: 0,
            viewportHeight: 0,
            safeAreaTop: .nan,
            safeAreaBottom: -40,
            safeAreaLeading: .infinity,
            safeAreaTrailing: 0,
            prefersVolumeBar: true,
            textScale: .nan
        )
        #expect(degenerate.contentWidth == 0)
        #expect(degenerate.availableContentHeight == 0)
        #expect(degenerate.artworkSize == 0)
        #expect(degenerate.detailColumnWidth == 0)
        #expect(!degenerate.showsLyricLine)
        #expect(!degenerate.showsVolumeBar)
    }
}
