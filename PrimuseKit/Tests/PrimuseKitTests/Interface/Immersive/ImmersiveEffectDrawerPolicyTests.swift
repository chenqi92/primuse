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

    @Test("左右安全区不相等时按侧分别消费")
    func asymmetricSafeAreaIsConsumedPerSide() {
        let bottom = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 466,
            viewportHeight: 678,
            safeAreaLeading: 20,
            safeAreaTrailing: 0,
            safeAreaTop: 0,
            safeAreaBottom: 21
        )
        #expect(bottom.placement == .bottom)
        #expect(bottom.contentLeading == 20)
        #expect(bottom.contentTrailing == 0)
        #expect(bottom.contentBottom == 31)
        #expect(bottom.wheelLength == 446)

        // 横屏时只有尾侧安全区影响抽屉，首侧安全区落在舞台上，不该被抽屉吃掉。
        let trailing = ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: 678,
            viewportHeight: 466,
            safeAreaLeading: 20,
            safeAreaTrailing: 0,
            safeAreaTop: 0,
            safeAreaBottom: 21
        )
        #expect(trailing.placement == .trailing)
        #expect(trailing.contentTrailing == 16)
        #expect(trailing.contentLeading == 16)
    }

    // MARK: - 不变量

    @Test("四种目标视口下缩略图都保持 16:9，单元都短于转轮")
    func cardsStayWideAndFitTheWheel() {
        let viewports: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (667, 375, 0, 0),
            (852, 393, 59, 21),
            (956, 440, 62, 21),
            (678, 466, 20, 21),
            (375, 667, 0, 0),
            (393, 852, 0, 34),
            (466, 678, 20, 21),
        ]
        for viewport in viewports {
            let layout = ImmersiveEffectDrawerPolicy.layout(
                viewportWidth: viewport.0,
                viewportHeight: viewport.1,
                safeAreaLeading: viewport.2,
                safeAreaTrailing: viewport.2,
                safeAreaTop: 0,
                safeAreaBottom: viewport.3
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
        let ids = ["coverGallery", "flowingLines", "auroraVeil"]
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: ids, currentID: "flowingLines") == "flowingLines")
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: ids, currentID: "native") == "coverGallery")
        #expect(ImmersiveEffectDrawerPolicy.initialCenterID(effectIDs: [], currentID: "native") == nil)
    }

    @Test("缩略卡从停在中间的那张起往两边依次换上真实画面")
    func previewSequenceStartsAtTheCenterAndAlternates() {
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 5, centerIndex: 2) == [4, 2, 0, 1, 3])
        // 停在第一张:只能往后排。
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 4, centerIndex: 0) == [0, 1, 2, 3])
        // 停在最后一张:只能往前排。
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 4, centerIndex: 3) == [3, 2, 1, 0])
        // 偏向一边时,另一边排完后剩下的按距离接着排。
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 6, centerIndex: 1) == [2, 0, 1, 3, 4, 5])
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 1, centerIndex: 0) == [0])
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 0, centerIndex: 0).isEmpty)
        // 越界的中心按最近的一张算。
        #expect(ImmersiveEffectDrawerPolicy.previewSequence(count: 3, centerIndex: 9) == [2, 1, 0])
    }

    @Test("每张卡都排到且名次不重复")
    func previewSequenceIsAPermutation() {
        for count in 1...14 {
            for center in 0..<count {
                let ranks = ImmersiveEffectDrawerPolicy.previewSequence(count: count, centerIndex: center)
                #expect(ranks.sorted() == Array(0..<count))
                #expect(ranks[center] == 0)
            }
        }
    }

    // MARK: - 首尾相接

    @Test("两种以上的效果排三遍转圈，只有一种时不转圈")
    func wheelLoopRepeatsTheListThreeTimes() {
        let loop = ImmersiveEffectWheelLoop(itemCount: 13)
        #expect(loop.loops)
        #expect(loop.copies == 3)
        #expect(loop.slotCount == 39)
        #expect(loop.homeCopy == 1)

        let pair = ImmersiveEffectWheelLoop(itemCount: 2)
        #expect(pair.loops)
        #expect(pair.slotCount == 6)

        let single = ImmersiveEffectWheelLoop(itemCount: 1)
        #expect(!single.loops)
        #expect(single.slotCount == 1)
        #expect(single.homeSlot(forItem: 0) == 0)
        #expect(single.isHomeSlot(0))
        #expect(single.recenteredSlot(for: 0) == nil)

        let empty = ImmersiveEffectWheelLoop(itemCount: 0)
        #expect(!empty.loops)
        #expect(empty.slotCount == 0)
        #expect(empty.homeSlot(forItem: 0) == nil)
        #expect(empty.itemIndex(forSlot: 0) == nil)

        // 负数按没有算。
        #expect(ImmersiveEffectWheelLoop(itemCount: -3).slotCount == 0)
    }

    @Test("格子换算回第几种效果，打开时停在中间那一遍")
    func wheelLoopMapsSlotsBackToItems() {
        let loop = ImmersiveEffectWheelLoop(itemCount: 13)
        #expect(loop.itemIndex(forSlot: 0) == 0)
        #expect(loop.itemIndex(forSlot: 12) == 12)
        #expect(loop.itemIndex(forSlot: 13) == 0)
        #expect(loop.itemIndex(forSlot: 27) == 1)
        #expect(loop.itemIndex(forSlot: 38) == 12)
        #expect(loop.itemIndex(forSlot: 39) == nil)
        #expect(loop.itemIndex(forSlot: -1) == nil)

        #expect(loop.homeSlot(forItem: 0) == 13)
        #expect(loop.homeSlot(forItem: 12) == 25)
        #expect(loop.homeSlot(forItem: 13) == nil)
        #expect(loop.homeSlot(forItem: -1) == nil)

        #expect(!loop.isHomeSlot(12))
        #expect(loop.isHomeSlot(13))
        #expect(loop.isHomeSlot(25))
        #expect(!loop.isHomeSlot(26))
        #expect(!loop.isHomeSlot(39))
    }

    @Test("滚过最后一张接着是第一张，滚停后换回中间那一遍的同一张")
    func wheelLoopWrapsPastBothEnds() {
        let loop = ImmersiveEffectWheelLoop(itemCount: 13)
        let last = loop.homeSlot(forItem: 12)!
        let first = loop.homeSlot(forItem: 0)!

        // 中间那遍的最后一张再往后一格：下一遍的第一张，停稳后换回中间那遍的第一张。
        #expect(loop.itemIndex(forSlot: last + 1) == 0)
        #expect(loop.recenteredSlot(for: last + 1) == first)
        // 中间那遍的第一张再往前一格：上一遍的最后一张，停稳后换回中间那遍的最后一张。
        #expect(loop.itemIndex(forSlot: first - 1) == 12)
        #expect(loop.recenteredSlot(for: first - 1) == last)

        // 停在中间那遍里不动；两端的格子也都能换回来。
        #expect(loop.recenteredSlot(for: first) == nil)
        #expect(loop.recenteredSlot(for: last) == nil)
        #expect(loop.recenteredSlot(for: 0) == 13)
        #expect(loop.recenteredSlot(for: 38) == 25)
        #expect(loop.recenteredSlot(for: 39) == nil)
        #expect(loop.recenteredSlot(for: -1) == nil)

        // 不管停在哪一格，换回来的都是同一种效果、落在中间那遍里。
        for slot in 0..<loop.slotCount {
            let target = loop.recenteredSlot(for: slot) ?? slot
            #expect(loop.isHomeSlot(target))
            #expect(loop.itemIndex(forSlot: target) == loop.itemIndex(forSlot: slot))
        }
    }

    @Test("三遍的缩略卡从停着的那格往两边排，替身那格的中间同一张紧跟着排")
    func wheelLoopPreviewSequenceLoadsTheHomeTwinRightAfter() {
        let loop = ImmersiveEffectWheelLoop(itemCount: 4)
        // 停在第一种（格子 4）：往前一格是上一遍的最后一张（格子 3），它在中间那遍的同一张（格子 7）紧跟着排。
        #expect(loop.previewSequence(centerItem: 0) == [8, 6, 5, 2, 0, 1, 4, 3, 7, 9, 10, 11])
        // 停在最后一种（格子 7）：往后一格是下一遍的第一张（格子 8），紧跟着是中间那遍的第一张（格子 4）。
        #expect(loop.previewSequence(centerItem: 3) == [11, 10, 9, 8, 2, 5, 3, 0, 1, 4, 6, 7])
        #expect(loop.previewSequence(centerItem: 1) == [10, 8, 6, 4, 2, 0, 1, 3, 5, 7, 9, 11])
        // 越界的中心按最近的一种算。
        #expect(loop.previewSequence(centerItem: 9) == loop.previewSequence(centerItem: 3))
        #expect(ImmersiveEffectWheelLoop(itemCount: 1).previewSequence(centerItem: 0) == [0])
        #expect(ImmersiveEffectWheelLoop(itemCount: 0).previewSequence(centerItem: 0).isEmpty)
    }

    @Test("三遍的每一格都排到、名次不重复，换回去的那张不晚于替身")
    func wheelLoopPreviewSequenceIsAPermutation() {
        for count in 1...14 {
            let loop = ImmersiveEffectWheelLoop(itemCount: count)
            for center in 0..<count {
                let ranks = loop.previewSequence(centerItem: center)
                #expect(ranks.sorted() == Array(0..<loop.slotCount))
                #expect(ranks[loop.homeSlot(forItem: center)!] == 0)
                for slot in 0..<loop.slotCount {
                    guard let home = loop.recenteredSlot(for: slot) else { continue }
                    #expect(ranks[home] <= ranks[slot] + 1)
                }
            }
        }
    }

    // MARK: - 是否应用

    @Test("普通全屏必须点选，滚停不能切换宿主")
    func nativeFullscreenRequiresAnExplicitTap() {
        for appliesOnSettle in [false, true] {
            #expect(!ImmersiveEffectDrawerPolicy.shouldApply(
                currentEffectID: "flowingLines", candidateID: "native",
                trigger: .settled, appliesOnSettle: appliesOnSettle,
                secondsSinceCenterChange: 5
            ))
            #expect(ImmersiveEffectDrawerPolicy.shouldApply(
                currentEffectID: "flowingLines", candidateID: "native",
                trigger: .tapped, appliesOnSettle: appliesOnSettle,
                secondsSinceCenterChange: 0
            ))
        }
    }

    @Test("滚停够久才应用，路过不算")
    func settlingAppliesOnlyAfterTheDelay() {
        let tooSoon = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: "flowingLines",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 0.1
        )
        #expect(!tooSoon)

        let settled = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: "flowingLines",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 0.25
        )
        #expect(settled)
    }

    @Test("居中项就是当前效果时不重复应用")
    func centeringTheCurrentEffectChangesNothing() {
        let sameOnSettle = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: "coverGallery",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 3
        )
        #expect(!sameOnSettle)

        let sameOnTap = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: "coverGallery",
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
            candidateID: "flowingLines",
            trigger: .settled,
            appliesOnSettle: false,
            secondsSinceCenterChange: 5
        )
        #expect(!settled)

        let tapped = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "native",
            candidateID: "flowingLines",
            trigger: .tapped,
            appliesOnSettle: false,
            secondsSinceCenterChange: 0
        )
        #expect(tapped)
    }

    @Test("还没有居中项时什么都不做")
    func missingCandidateIsIgnored() {
        let missing = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: nil,
            trigger: .tapped,
            appliesOnSettle: true,
            secondsSinceCenterChange: 9
        )
        #expect(!missing)

        let blank = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: "coverGallery",
            candidateID: "",
            trigger: .settled,
            appliesOnSettle: true,
            secondsSinceCenterChange: 9
        )
        #expect(!blank)
    }
}
