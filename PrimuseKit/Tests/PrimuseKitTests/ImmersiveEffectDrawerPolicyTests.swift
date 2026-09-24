import Foundation
import Testing
@testable import PrimuseKit

@Suite("Immersive effect drawer policy")
struct ImmersiveEffectDrawerPolicyTests {

    // MARK: - 贴边

    @Test("视口宽于高时贴尾侧，否则贴底部")
    func placementFollowsViewportOrientation() {
        #expect(ImmersiveEffectDrawerPolicy.placement(viewportWidth: 852, viewportHeight: 393) == .trailing)
        #expect(ImmersiveEffectDrawerPolicy.placement(viewportWidth: 393, viewportHeight: 852) == .bottom)
        // 正方形视口按竖屏处理：右侧抽屉此时同样会遮掉大半舞台。
        #expect(ImmersiveEffectDrawerPolicy.placement(viewportWidth: 500, viewportHeight: 500) == .bottom)
    }

    @Test("贴尾侧时转轮纵向滚，贴底部时横向滚")
    func scrollAxisFollowsPlacement() {
        #expect(ImmersiveEffectDrawerPlacement.trailing.scrollsVertically)
        #expect(!ImmersiveEffectDrawerPlacement.bottom.scrollsVertically)
    }

    // MARK: - 目标视口

    @Test("iPhone SE 横屏：没有安全区时抽屉与转轮的尺寸")
    func seLandscapeGeometry() {
        let layout = ImmersiveEffectDrawerPolicy.layout(viewportWidth: 667, viewportHeight: 375)
        #expect(layout.placement == .trailing)
        #expect(layout.panelWidth == 240)
        #expect(layout.panelHeight == 375)
        #expect(layout.contentLeading == 16)
        #expect(layout.contentTrailing == 16)
        #expect(layout.contentTop == 14)
        #expect(layout.contentBottom == 14)
        #expect(layout.cardWidth == 208)
        #expect(layout.cardHeight == 117)
        #expect(layout.wheelLength == 217)
        #expect(layout.wheelMargin == 38)
    }

    @Test("iPhone SE 竖屏：抽屉贴底，转轮横向")
    func sePortraitGeometry() {
        let layout = ImmersiveEffectDrawerPolicy.layout(viewportWidth: 375, viewportHeight: 667)
        #expect(layout.placement == .bottom)
        #expect(layout.panelWidth == 375)
        #expect(layout.panelHeight == 190)
        #expect(layout.contentTop == 14)
        #expect(layout.contentBottom == 10)
        #expect(layout.cardWidth == 149)
        #expect(layout.cardHeight == 84)
        #expect(layout.wheelLength == 375)
        #expect(layout.wheelMargin == 113)
    }

    @Test("iPhone 15 横屏：尾侧安全区加在内边距上，内容不压在灵动岛下")
    func dynamicIslandLandscapeConsumesTrailingInset() {
        let layout = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 852,
            viewportHeight: 393,
            safeAreaLeading: 59,
            safeAreaTrailing: 59,
            safeAreaTop: 0,
            safeAreaBottom: 21
        )
        #expect(layout.panelWidth == 359)
        #expect(layout.contentTrailing == 75)
        #expect(layout.contentLeading == 16)
        #expect(layout.contentBottom == 21)
        #expect(layout.cardWidth == 224)
        #expect(layout.cardHeight == 126)
        #expect(layout.wheelLength == 228)
        #expect(layout.wheelMargin == 39)
    }

    /// 折叠屏外屏按 Duo 模拟器实测:竖握系统竖栏在右(右 84),横握在左(左 84),顶部 0、底部 34。
    @Test("左右安全区不相等时按侧分别消费")
    func asymmetricSafeAreaIsConsumedPerSide() {
        let bottom = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 466,
            viewportHeight: 678,
            safeAreaLeading: 0,
            safeAreaTrailing: 84,
            safeAreaTop: 0,
            safeAreaBottom: 34
        )
        #expect(bottom.placement == .bottom)
        #expect(bottom.contentLeading == 0)
        #expect(bottom.contentTrailing == 84)
        #expect(bottom.contentBottom == 44)
        #expect(bottom.wheelLength == 382)

        // 横屏时只有尾侧安全区影响抽屉，首侧安全区落在舞台上，不该被抽屉吃掉。
        let trailing = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 678,
            viewportHeight: 466,
            safeAreaLeading: 84,
            safeAreaTrailing: 0,
            safeAreaTop: 0,
            safeAreaBottom: 34
        )
        #expect(trailing.placement == .trailing)
        #expect(trailing.contentTrailing == 16)
        #expect(trailing.contentLeading == 16)
    }

    // MARK: - 不变量

    @Test("四种目标视口下缩略图都保持 16:9，单元都短于转轮")
    func cardsStayWideAndFitTheWheel() {
        // 宽、高、首侧、尾侧、底部安全区。折叠屏外屏两行是实测值(竖栏那一侧 84)。
        let viewports: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (667, 375, 0, 0, 0),
            (852, 393, 59, 59, 21),
            (956, 440, 62, 62, 21),
            (678, 466, 84, 0, 34),
            (375, 667, 0, 0, 0),
            (393, 852, 0, 0, 34),
            (466, 678, 0, 84, 34),
        ]
        for viewport in viewports {
            let layout = ImmersiveEffectDrawerPolicy.layout(
                viewportWidth: viewport.0,
                viewportHeight: viewport.1,
                safeAreaLeading: viewport.2,
                safeAreaTrailing: viewport.3,
                safeAreaTop: 0,
                safeAreaBottom: viewport.4
            )
            // 两侧都取整之后 16:9 最多差一个点。
            let aspectDrift = abs(layout.cardWidth * 9 - layout.cardHeight * 16)
            #expect(aspectDrift <= 16)
            #expect(layout.cardWidth > 0)
            #expect(layout.cardHeight > 0)
            #expect(layout.wheelMargin >= 0)

            let cellExtent = layout.placement.scrollsVertically
                ? layout.cardHeight + 24
                : layout.cardWidth
            #expect(cellExtent <= layout.wheelLength)
            // 首尾项也要能停在正中：两端留白加上单元长度正好铺满转轮，取整误差不超过 2 点。
            let spannedLength = layout.wheelMargin * 2 + cellExtent
            let tolerantWheelLength = layout.wheelLength + 2
            #expect(spannedLength <= tolerantWheelLength)
        }
    }

    @Test("抽屉连安全区一起算也不会占满视口")
    func drawerNeverSwallowsTheStage() {
        let wide = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 956,
            viewportHeight: 440,
            safeAreaLeading: 62,
            safeAreaTrailing: 62,
            safeAreaTop: 0,
            safeAreaBottom: 21
        )
        #expect(wide.panelWidth == 362)
        #expect(wide.panelWidth < 526)

        // 极端窄横屏：比例算出来的宽度低于下限时用下限，但仍不越过视口的一半多一点。
        let narrow = ImmersiveEffectDrawerPolicy.layout(viewportWidth: 320, viewportHeight: 300)
        #expect(narrow.panelWidth == 176)
        #expect(narrow.panelWidth < 300)
    }

    @Test("退化尺寸不产生负数或非有限值")
    func degenerateViewportsStayFinite() {
        let empty = ImmersiveEffectDrawerPolicy.layout(viewportWidth: 0, viewportHeight: 0)
        #expect(empty.panelWidth.isFinite)
        #expect(empty.panelHeight.isFinite)
        #expect(empty.cardWidth >= 54)
        #expect(empty.wheelMargin >= 0)

        let broken = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: .nan,
            viewportHeight: .infinity,
            safeAreaLeading: .nan,
            safeAreaTrailing: -40,
            safeAreaTop: .nan,
            safeAreaBottom: -12
        )
        #expect(broken.panelWidth.isFinite)
        #expect(broken.panelHeight.isFinite)
        #expect(broken.cardWidth.isFinite)
        #expect(broken.cardHeight.isFinite)
        #expect(broken.wheelMargin >= 0)
        #expect(broken.contentLeading >= 0)
        #expect(broken.contentBottom >= 0)
    }

    // MARK: - 初始居中

    @Test("打开时停在当前效果上，当前效果不在列表里就停在第一项")
    func initialCenterFallsBackToTheFirstCard() {
        let ids = ["coverFlow", "coverGallery", "starryNight"]
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: ids, currentID: "coverGallery") == "coverGallery")
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: ids, currentID: "native") == "coverFlow")
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: [], currentID: "native") == nil)
    }

    // MARK: - 是否应用

    @Test("滚停够久才应用，路过不算")
    func settlingAppliesOnlyAfterTheDelay() {
        let tooSoon = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: "starryNight",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 0.1
        )
        #expect(!tooSoon)

        let settled = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: "starryNight",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 0.25
        )
        #expect(settled)
    }

    @Test("居中项就是当前效果时不重复应用")
    func centeringTheCurrentEffectChangesNothing() {
        let sameOnSettle = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: "coverFlow",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 3
        )
        #expect(!sameOnSettle)

        let sameOnTap = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: "coverFlow",
            trigger: .tapped,
            appliesOnSettle: true,
            secondsSinceCenterChange: 0
        )
        #expect(!sameOnTap)
    }

    @Test("浏览模式下只有点卡片才写回效果")
    func browsingModeAppliesOnTapOnly() {
        let settled = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "native",
            candidateID: "starryNight",
            trigger: .settled,
            appliesOnSettle: false,
            secondsSinceCenterChange: 5
        )
        #expect(!settled)

        let tapped = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "native",
            candidateID: "starryNight",
            trigger: .tapped,
            appliesOnSettle: false,
            secondsSinceCenterChange: 0
        )
        #expect(tapped)
    }

    @Test("还没有居中项时什么都不做")
    func missingCandidateIsIgnored() {
        let missing = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: nil,
            trigger: .tapped,
            appliesOnSettle: true,
            secondsSinceCenterChange: 9
        )
        #expect(!missing)

        let blank = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverFlow",
            candidateID: "",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 9
        )
        #expect(!blank)
    }
}
