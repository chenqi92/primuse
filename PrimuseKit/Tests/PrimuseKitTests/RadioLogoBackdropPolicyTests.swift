import Foundation
import Testing
@testable import PrimuseKit

/// 按 CoreGraphics `premultipliedLast` 的排布拼一张测试用位图。
private struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// 写入直通色（非预乘），落盘时按 alpha 预乘。
    mutating func fill(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        where include: (Int, Int) -> Bool = { _, _ in true }
    ) {
        for y in 0..<height {
            for x in 0..<width {
                guard include(x, y) else { continue }
                let base = (y * width + x) * 4
                bytes[base] = premultiplied(red, alpha)
                bytes[base + 1] = premultiplied(green, alpha)
                bytes[base + 2] = premultiplied(blue, alpha)
                bytes[base + 3] = byte(alpha)
            }
        }
    }

    private func premultiplied(_ value: Double, _ alpha: Double) -> UInt8 {
        byte(value * alpha)
    }

    private func byte(_ value: Double) -> UInt8 {
        let scaled = value * 255.0
        let clamped = min(max(scaled.rounded(), 0), 255)
        return UInt8(clamped)
    }
}

private func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.01) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func isEdge(_ x: Int, _ y: Int, side: Int) -> Bool {
    x == 0 || y == 0 || x == side - 1 || y == side - 1
}

@Suite("Radio logo backdrop")
struct RadioLogoBackdropPolicyTests {
    private let side = 24

    @Test("不透明纯色图直接用自身的颜色当衬底")
    func opaqueFlatImageKeepsItsOwnColor() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(isClose(backdrop.red, 0.2))
        #expect(isClose(backdrop.green, 0.4))
        #expect(isClose(backdrop.blue, 0.6))
    }

    @Test("不透明图只看最外一圈，不受中心色影响")
    func opaqueImageSamplesEdgeNotCenter() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0, green: 0, blue: 1, alpha: 1)
        canvas.fill(red: 1, green: 0, blue: 0, alpha: 1) { x, y in
            isEdge(x, y, side: self.side)
        }
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(isClose(backdrop.red, 1))
        #expect(isClose(backdrop.green, 0))
        #expect(isClose(backdrop.blue, 0))
    }

    @Test("边上少量透明格不影响“这是不透明图”的判断")
    func toleratesAFewTransparentEdgePixels() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
        canvas.fill(red: 0, green: 0, blue: 0, alpha: 0) { x, y in
            y == 0 && x < 4
        }
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(isClose(backdrop.red, 0.8))
        #expect(isClose(backdrop.green, 0.2))
        #expect(isClose(backdrop.blue, 0.2))
    }

    @Test("透明底的深色台标垫浅底")
    func darkLogoOnTransparentBackgroundGetsLightBackdrop() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.05, green: 0.05, blue: 0.05, alpha: 1) { x, y in
            (6..<18).contains(x) && (6..<18).contains(y)
        }
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(backdrop == RadioLogoBackdropPolicy.light)
    }

    @Test("透明底的浅色台标垫深底")
    func lightLogoOnTransparentBackgroundGetsDarkBackdrop() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.95, green: 0.95, blue: 0.95, alpha: 1) { x, y in
            (6..<18).contains(x) && (6..<18).contains(y)
        }
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(backdrop == RadioLogoBackdropPolicy.dark)
    }

    @Test("半透明边缘不当成不透明图")
    func translucentEdgeDoesNotCountAsOpaque() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        canvas.fill(red: 1, green: 1, blue: 1, alpha: 0.6) { x, y in
            isEdge(x, y, side: self.side)
        }
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        // 走的是亮度路径：整体偏暗 → 浅衬底；若误判成不透明图会取到近白色。
        #expect(backdrop == RadioLogoBackdropPolicy.light)
    }

    @Test("全透明的图退回浅衬底")
    func fullyTransparentFallsBackToLight() {
        let canvas = PixelCanvas(width: side, height: side)
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(backdrop == RadioLogoBackdropPolicy.light)
    }

    @Test("缓冲区长度或宽高不对就退回浅衬底")
    func rejectsMalformedBuffers() {
        var canvas = PixelCanvas(width: side, height: side)
        canvas.fill(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let truncated = Array(canvas.bytes.prefix(100))
        #expect(RadioLogoBackdropPolicy.backdrop(
            pixels: truncated,
            width: side,
            height: side
        ) == RadioLogoBackdropPolicy.light)
        #expect(RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: 0,
            height: side
        ) == RadioLogoBackdropPolicy.light)
        #expect(RadioLogoBackdropPolicy.backdrop(
            pixels: [],
            width: -4,
            height: -4
        ) == RadioLogoBackdropPolicy.light)
    }

    @Test("亮度按反预乘后的颜色算")
    func luminanceUsesUnpremultipliedColor() {
        var canvas = PixelCanvas(width: side, height: side)
        // 直通色 0.7 的灰、alpha 0.6：预乘后存下的是 0.42，
        // 不反预乘会把这张浅色台标误判成深色，垫成浅底。
        canvas.fill(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.6)
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(backdrop == RadioLogoBackdropPolicy.dark)
    }

    @Test("边缘取色也按反预乘后的颜色算")
    func edgeColorUsesUnpremultipliedColor() {
        var canvas = PixelCanvas(width: side, height: side)
        // alpha 0.95 仍算实心；预乘存下的是 0.95，反预乘后应该回到纯白。
        canvas.fill(red: 1, green: 1, blue: 1, alpha: 0.95)
        let backdrop = RadioLogoBackdropPolicy.backdrop(
            pixels: canvas.bytes,
            width: side,
            height: side
        )
        #expect(isClose(backdrop.red, 1, tolerance: 0.02))
        #expect(isClose(backdrop.green, 1, tolerance: 0.02))
        #expect(isClose(backdrop.blue, 1, tolerance: 0.02))
    }
}
