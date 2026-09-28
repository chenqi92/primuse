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

    // MARK: - 剥元数据

    /// 拼一段 JPEG 标记段：FF xx + 两字节长度 + 负载。
    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    private var scanTail: [UInt8] {
        // SOS 头 + 几个熵编码字节（含一个 FF00 填充）+ EOI
        segment(0xDA, [0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]) + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD9]
    }

    @Test("EXIF、XMP、Photoshop 段与注释被去掉，JFIF、ICC、Adobe 与像素数据保留")
    func stripsDescriptiveSegmentsOnly() throws {
        let jfif = segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0])
        let exif = segment(0xE1, Array("Exif\0\0MM".utf8))
        let exifAgain = segment(0xE1, Array("Exif\0\0MM".utf8) + [0x00, 0x2A])
        let icc = segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1])
        let photoshop = segment(0xED, Array("Photoshop 3.0\0".utf8))
        let adobe = segment(0xEE, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1])
        let comment = segment(0xFE, Array("hello".utf8))
        let quant = segment(0xDB, [0x00] + Array(repeating: 1, count: 64))
        let frame = segment(0xC0, [8, 0x01, 0x2C, 0x01, 0x2C, 1, 1, 0x11, 0])
        let input = [0xFF, 0xD8] + jfif + exif + exifAgain + icc + photoshop + adobe + comment
            + quant + frame + scanTail

        let stripped = try #require(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(input)))
        #expect([UInt8](stripped) == [0xFF, 0xD8] + jfif + icc + adobe + quant + frame + scanTail)
    }

    @Test("没有可剥的段时返回 nil，调用方照用原数据")
    func cleanJPEGIsLeftAlone() {
        let frame = segment(0xC0, [8, 0, 16, 0, 16, 1, 1, 0x11, 0])
        let input = [0xFF, 0xD8] + segment(0xE0, Array("JFIF\0".utf8)) + frame + scanTail
        #expect(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(input)) == nil)
    }

    @Test("不是 JPEG、或段长度越界时返回 nil，不产出半截数据")
    func malformedInputReturnsNil() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(png)) == nil)

        // EXIF 段声明 0x1000 字节，实际文件到此为止。
        let truncated: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x00, 0x45, 0x78]
        #expect(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(truncated)) == nil)

        // 扫描还没开始就遇到 EOI。
        let early = [0xFF, 0xD8] + segment(0xE1, [1, 2, 3]) + [0xFF, 0xD9]
        #expect(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(early)) == nil)
    }

    @Test("段之间的 0xFF 填充不影响解析")
    func toleratesFillBytesBetweenSegments() throws {
        let exif = segment(0xE1, [1, 2, 3])
        let frame = segment(0xC0, [8, 0, 16, 0, 16, 1, 1, 0x11, 0])
        let input: [UInt8] = [0xFF, 0xD8] + exif + [0xFF] + frame + scanTail
        let stripped = try #require(ArtworkImageNormalizationPolicy.strippingJPEGMetadata(Data(input)))
        #expect([UInt8](stripped) == [0xFF, 0xD8] + frame + scanTail)
    }

    // MARK: - 结果校验

    @Test("尺寸允许 1 像素取整误差，差得多就判为不可用")
    func expectedSizeTolerance() {
        let expected = (width: 300, height: 300)
        #expect(ArtworkImageNormalizationPolicy.matchesExpectedSize(width: 300, height: 299, expected: expected))
        #expect(!ArtworkImageNormalizationPolicy.matchesExpectedSize(width: 1, height: 1, expected: expected))
        #expect(!ArtworkImageNormalizationPolicy.matchesExpectedSize(width: 96, height: 96, expected: expected))
    }

    @Test("亮度起伏不超过 2 算作纯色")
    func uniformityThreshold() {
        #expect(ArtworkImageNormalizationPolicy.looksUniform(minimumLuma: 106, maximumLuma: 108))
        #expect(!ArtworkImageNormalizationPolicy.looksUniform(minimumLuma: 33, maximumLuma: 214))
    }
}
