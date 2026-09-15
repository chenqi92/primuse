import Foundation
import Testing
@testable import PrimuseKit

@Suite("Artwork image normalization policy")
struct ArtworkImageNormalizationPolicyTests {

    // MARK: - 尺寸

    @Test("小图不放大 —— 300×300 在 1200 的方框里还是 300×300")
    func smallImageIsNeverUpscaled() {
        let size = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 300, height: 300, longSide: 1200
        )
        #expect(size?.width == 300)
        #expect(size?.height == 300)
    }

    @Test("长边正好等于方框时原样返回")
    func exactFitIsUnchanged() {
        let size = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 1200, height: 800, longSide: 1200
        )
        #expect(size?.width == 1200)
        #expect(size?.height == 800)
    }

    @Test("超出方框时按长边等比缩小")
    func oversizedImageScalesOnTheLongEdge() {
        let landscape = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 4000, height: 3000, longSide: 1000
        )
        #expect(landscape?.width == 1000)
        #expect(landscape?.height == 750)

        let portrait = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 3000, height: 4000, longSide: 1000
        )
        #expect(portrait?.width == 750)
        #expect(portrait?.height == 1000)
    }

    @Test("极端长条缩小后短边不会变成 0")
    func extremeAspectRatioKeepsAtLeastOnePixel() {
        let size = ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 8000, height: 3, longSide: 640
        )
        #expect(size?.width == 640)
        #expect(size?.height == 1)
    }

    @Test("非法尺寸返回 nil")
    func invalidInputReturnsNil() {
        #expect(ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 0, height: 100, longSide: 640
        ) == nil)
        #expect(ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 100, height: -1, longSide: 640
        ) == nil)
        #expect(ArtworkImageNormalizationPolicy.boundedPixelSize(
            width: 100, height: 100, longSide: 0
        ) == nil)
    }

    // MARK: - 是否需要重画

    @Test("普通 8 bit 不透明 RGB 直接编码，不必重画")
    func plainOpaqueRGBNeedsNoRedraw() {
        #expect(!ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: false,
            bitsPerComponent: 8,
            usesFloatComponents: false,
            isJPEGCompatibleColorModel: true
        ))
    }

    @Test("带 alpha 的图必须重画 —— 这正是贴纸类 PNG 选了没反应的原因")
    func alphaForcesRedraw() {
        #expect(ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: true,
            bitsPerComponent: 8,
            usesFloatComponents: false,
            isJPEGCompatibleColorModel: true
        ))
    }

    @Test("16 bit、浮点分量、CMYK 各自都要重画")
    func deepFloatAndExoticColorModelsForceRedraw() {
        #expect(ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: false,
            bitsPerComponent: 16,
            usesFloatComponents: false,
            isJPEGCompatibleColorModel: true
        ))
        #expect(ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: false,
            bitsPerComponent: 8,
            usesFloatComponents: true,
            isJPEGCompatibleColorModel: true
        ))
        #expect(ArtworkImageNormalizationPolicy.requiresOpaqueRedraw(
            hasAlpha: false,
            bitsPerComponent: 8,
            usesFloatComponents: false,
            isJPEGCompatibleColorModel: false
        ))
    }

    // MARK: - EXIF 摆正

    @Test("orientation 1 不用动")
    func uprightOrientationIsIdentity() {
        let steps = ArtworkImageNormalizationPolicy.orientationSteps(forExif: 1)
        #expect(steps.quarterTurnsClockwise == 0)
        #expect(!steps.mirroredHorizontally)
        #expect(!ArtworkImageNormalizationPolicy.swapsDimensions(forExif: 1))
    }

    @Test("相机竖拍的 6 是顺时针 90°，8 是 270°")
    func cameraRotationsMapToQuarterTurns() {
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 6)
            == (quarterTurnsClockwise: 1, mirroredHorizontally: false))
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 8)
            == (quarterTurnsClockwise: 3, mirroredHorizontally: false))
    }

    @Test("180° 与两种轴镜像")
    func flipsAndHalfTurn() {
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 2)
            == (quarterTurnsClockwise: 0, mirroredHorizontally: true))
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 3)
            == (quarterTurnsClockwise: 2, mirroredHorizontally: false))
        // 垂直镜像 = 180° 再水平镜像
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 4)
            == (quarterTurnsClockwise: 2, mirroredHorizontally: true))
    }

    @Test("5 是主对角线翻转，7 是副对角线翻转")
    func transposeAndTransverse() {
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 5)
            == (quarterTurnsClockwise: 3, mirroredHorizontally: true))
        #expect(ArtworkImageNormalizationPolicy.orientationSteps(forExif: 7)
            == (quarterTurnsClockwise: 1, mirroredHorizontally: true))
    }

    @Test("5…8 交换宽高，1…4 不换")
    func onlyOddQuarterTurnsSwapDimensions() {
        for value in 1...4 {
            #expect(!ArtworkImageNormalizationPolicy.swapsDimensions(forExif: value))
        }
        for value in 5...8 {
            #expect(ArtworkImageNormalizationPolicy.swapsDimensions(forExif: value))
        }
    }

    @Test("越界或缺失的 orientation 当作摆正，不能因此丢图")
    func outOfRangeOrientationFallsBackToUpright() {
        for value in [0, 9, -3, 999] {
            let steps = ArtworkImageNormalizationPolicy.orientationSteps(forExif: value)
            #expect(steps.quarterTurnsClockwise == 0)
            #expect(!steps.mirroredHorizontally)
        }
    }
}
