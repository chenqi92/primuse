import Foundation
import Testing
@testable import PrimuseKit

struct ArtworkContentLayoutTests {
    @Test func portraitAndLandscapeCoversKeepAllEdges() {
        #expect(ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 200, height: 400),
                    in: CGRect(x: 0, y: 0, width: 300, height: 300))
                == CGRect(x: 75, y: 0, width: 150, height: 300))
        #expect(ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 400, height: 200),
                    in: CGRect(x: 0, y: 0, width: 300, height: 300))
                == CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    @Test func fullBleedFitsBetweenChromeAndFade() {
        let rect = ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 100, height: 400),
                    in: CGRect(x: 0, y: 120, width: 400, height: 300))
        #expect(rect == CGRect(x: 162.5, y: 120, width: 75, height: 300))
        #expect(!ArtworkContentLayout.isRectangular(CGSize(width: 601, height: 600)))
        #expect(ArtworkContentLayout.isRectangular(CGSize(width: 300, height: 600)))
        #expect(ArtworkContentLayout.fittedRect(imageSize: .zero,
                    in: CGRect(x: 0, y: 0, width: 300, height: 300)) == .zero)
    }
}

struct ArtworkSlotFillTests {
    @Test("铺满的长槽位里长方形封面盖满整个槽位,方槽位里整张放进去")
    func slotShapeDecidesFill() {
        #expect(ArtworkContentLayout.slotFillAmount(slotSize: CGSize(width: 300, height: 300)) == 0)
        #expect(ArtworkContentLayout.slotFillAmount(slotSize: CGSize(width: 302, height: 300)) == 0)
        // 竖屏铺满:393 宽、600 高的槽位完全铺满,横屏的扁槽位也一样。
        #expect(ArtworkContentLayout.slotFillAmount(slotSize: CGSize(width: 393, height: 600)) == 1)
        #expect(ArtworkContentLayout.slotFillAmount(slotSize: CGSize(width: 500, height: 300)) == 1)
        // 飞向小方框途中按形状连续收回。
        let midway = ArtworkContentLayout.slotFillAmount(slotSize: CGSize(width: 100, height: 109))
        #expect(midway > 0 && midway < 1)
        #expect(ArtworkContentLayout.slotFillAmount(slotSize: .zero) == 0)
    }

    @Test("盖满时等比放大、居中裁两头")
    func filledRectCoversBounds() {
        let slot = CGRect(x: 0, y: 0, width: 400, height: 600)
        let wide = ArtworkContentLayout.filledRect(imageSize: CGSize(width: 1600, height: 900), in: slot)
        #expect(abs(wide.height - 600) < 0.001)
        #expect(abs(wide.width - 1066.6667) < 0.001)
        #expect(abs(wide.midX - 200) < 0.001 && abs(wide.midY - 300) < 0.001)
        #expect(ArtworkContentLayout.filledRect(imageSize: .zero, in: slot) == .zero)

        let fitted = ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 1600, height: 900), in: slot)
        #expect(ArtworkContentLayout.interpolate(from: fitted, to: wide, fraction: 0) == fitted)
        #expect(ArtworkContentLayout.interpolate(from: fitted, to: wide, fraction: 1) == wide)
        let half = ArtworkContentLayout.interpolate(from: fitted, to: wide, fraction: 0.5)
        #expect(abs(half.width - (fitted.width + wide.width) / 2) < 0.001)
    }
}

struct VolumeScrubSessionTests {
    @Test func tapsJitterAndVerticalDismissalNeverChangeVolume() {
        var session = VolumeScrubSession(initialValue: 0.65, trackWidth: 200)
        #expect(session.update(horizontalTranslation: 0, verticalTranslation: 0) == nil)
        #expect(session.update(horizontalTranslation: 3, verticalTranslation: 2) == nil)
        #expect(session.update(horizontalTranslation: 4, verticalTranslation: 20) == nil)
        #expect(session.update(horizontalTranslation: -150, verticalTranslation: 80) == nil)
    }

    @Test func horizontalDragStartsAtCurrentVolumeAndLocksDirection() {
        var session = VolumeScrubSession(initialValue: 0.65, trackWidth: 200)
        #expect(session.update(horizontalTranslation: 20, verticalTranslation: 2) == 0.75)
        #expect(session.update(horizontalTranslation: 20, verticalTranslation: 100) == 0.75)
        #expect(session.update(horizontalTranslation: -400, verticalTranslation: 0) == 0)
        #expect(session.update(horizontalTranslation: 400, verticalTranslation: 0) == 1)
    }

    @Test func newGestureResetsIntentAndSupportsReversedTracks() {
        var session = VolumeScrubSession(initialValue: 0.5, trackWidth: -200)
        #expect(session.update(horizontalTranslation: -20, verticalTranslation: 0) == 0.6)
        var invalid = VolumeScrubSession(initialValue: 0.5, trackWidth: 0)
        #expect(invalid.update(horizontalTranslation: 20, verticalTranslation: 0) == nil)
    }

    @Test("方框里的长方形封面短边至少盖住框的 78%,两头少裁一点")
    func narrowCoversAreEnlargedInsideSquares() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 16:9:整张放进去只有 56.25 高,放大到 78 高,宽 138.67,左右各裁掉约 19。
        let wide = ArtworkContentLayout.displayRect(imageSize: CGSize(width: 1600, height: 900), in: box)
        #expect(abs(wide.height - 78) < 0.001)
        #expect(abs(wide.width - 138.6667) < 0.001)
        #expect(abs(wide.midX - 50) < 0.001 && abs(wide.midY - 50) < 0.001)
        // 竖的 2:3:宽 66.67 放大到 78,上下裁一点。
        let tall = ArtworkContentLayout.displayRect(imageSize: CGSize(width: 200, height: 300), in: box)
        #expect(abs(tall.width - 78) < 0.001)
        #expect(abs(tall.height - 117) < 0.001)
    }

    @Test("特别扁的封面最多放大 1.6 倍,留下大半张")
    func veryWideCoversStopAtTheMaximumBoost() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let banner = ArtworkContentLayout.displayRect(imageSize: CGSize(width: 900, height: 300), in: box)
        #expect(abs(banner.height - 160) < 0.001)
        #expect(abs(banner.width - 480) < 0.001)
    }

    @Test("短边已经够宽的长方形照旧整张放进去")
    func nearlySquareCoversStayWhole() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fourThree = ArtworkContentLayout.displayRect(imageSize: CGSize(width: 400, height: 320), in: box)
        #expect(fourThree == ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 400, height: 320), in: box))
    }
}
