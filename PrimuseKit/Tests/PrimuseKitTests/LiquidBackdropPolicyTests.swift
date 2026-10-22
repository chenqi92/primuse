import Foundation
import Testing
@testable import PrimuseKit

@Suite struct LiquidBackdropPolicyTests {

    @Test("Mesh preserves every representative color, including sparse palettes")
    func meshPaletteCoverage() {
        let palette = (0..<7).map { LiquidBackdropColor(red: Double($0) / 6, green: 0.3, blue: 0.8) }
        for count in 1...7 {
            let input = Array(palette.prefix(count))
            let output = MeshBackdropPalettePolicy.colors(for: input)
            #expect(output.count == 9)
            #expect(Set(output) == Set(input))
        }
        #expect(MeshBackdropPalettePolicy.colors(for: []).isEmpty)
    }

    @Test("Mesh motion keeps the edges covered and cells in order for a full cycle")
    func meshGeometry() {
        for step in 0...1000 {
            let points = MeshBackdropPalettePolicy.points(phase: Double(step) / 10, amplitude: 0.08)
            #expect(points.count == 9)
            #expect(points[0] == [0, 0] && points[2] == [1, 0])
            #expect(points[6] == [0, 1] && points[8] == [1, 1])
            #expect(points[1].y == 0 && points[7].y == 1)
            #expect(points[3].x == 0 && points[5].x == 1)
            for row in 0..<3 {
                #expect(points[row * 3].x < points[row * 3 + 1].x)
                #expect(points[row * 3 + 1].x < points[row * 3 + 2].x)
            }
            for column in 0..<3 {
                #expect(points[column].y < points[column + 3].y)
                #expect(points[column + 3].y < points[column + 6].y)
            }
        }
        #expect(MeshBackdropPalettePolicy.points(phase: 0, amplitude: 0)
            == MeshBackdropPalettePolicy.points(phase: 42, amplitude: 0))
    }

    @Test("Contrast bounds include bright and dark secondary palette colors")
    func meshContrastBounds() {
        let palette = [LiquidBackdropColor(red: 0.5, green: 0, blue: 0),
                       LiquidBackdropColor(red: 1, green: 1, blue: 1),
                       LiquidBackdropColor(red: 0, green: 0, blue: 0)]
        #expect(abs(MeshBackdropPalettePolicy.maximumLuminance(in: palette) - 1) < 1e-9)
        #expect(MeshBackdropPalettePolicy.minimumLuma(in: palette) == 0)
    }

    @Test("A dark mesh covering the full text region preserves the light appearance floor")
    func meshLightLegibility() {
        for contrast in [false, true] {
            for wash in [0.0, 0.08, 0.4, 1.0] {
                for gray in [0.0, 0.2, 0.5, 0.9, 1.0] {
                    let color = LiquidBackdropColor(red: gray, green: gray, blue: gray)
                    let opacity = MeshBackdropPalettePolicy.lightOpacity(
                        requested: 1, palette: [color], overlayOpacity: wash,
                        usesIncreasedContrast: contrast
                    )
                    let rendered = (0.94 * (1 - opacity) + gray * opacity) * (1 - wash) + wash
                    #expect(rendered >= NowPlayingLightAmbientPolicy.minimumLuma(usesIncreasedContrast: contrast) - 1e-9)
                }
            }
        }
    }
    private func image(_ parts: [((UInt8, UInt8, UInt8), Int)]) -> [(UInt8, UInt8, UInt8)] {
        parts.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test func picksSeveralRepresentativeColors() {
        let pixels = image([
            ((30, 60, 200), 700),    // 深蓝,最多
            ((230, 60, 120), 400),   // 玫红
            ((250, 200, 210), 200),  // 浅粉
            ((40, 20, 60), 200),     // 暗紫
            ((120, 120, 140), 100),  // 灰
        ])
        let palette = LiquidBackdropPalettePolicy.palette(fromRGB: pixels)
        #expect(palette.count >= 4)
        #expect(palette.count <= 7)
        // 主色在最前。
        let first = palette[0]
        #expect(first.blue > first.red && first.blue > first.green)
        // 玫红也在里面。
        #expect(palette.contains { $0.red > 0.7 && $0.green < 0.4 })
        #expect(Set(palette).count == palette.count)
    }

    @Test func everyLargeColorBlockGetsIn() {
        // 四块同样大小的鲜艳色块加一个黄圆:每种都要在调色板里。
        let pixels = image([
            ((30, 90, 220), 500),
            ((240, 120, 30), 500),
            ((20, 170, 120), 500),
            ((210, 40, 140), 500),
            ((250, 210, 60), 300),
        ])
        let palette = LiquidBackdropPalettePolicy.palette(fromRGB: pixels)
        func has(_ test: (LiquidBackdropColor) -> Bool) -> Bool { palette.contains(where: test) }
        #expect(has { $0.blue > 0.6 && $0.red < 0.3 })                     // 蓝
        #expect(has { $0.red > 0.8 && $0.green > 0.35 && $0.green < 0.6 }) // 橙
        #expect(has { $0.green > 0.5 && $0.red < 0.2 })                    // 绿
        #expect(has { $0.red > 0.7 && $0.blue > 0.4 && $0.green < 0.3 })   // 洋红
        #expect(has { $0.red > 0.8 && $0.green > 0.7 })                    // 黄
    }

    @Test func flatOrTinyImagesFallBack() {
        #expect(LiquidBackdropPalettePolicy.palette(fromRGB: image([((90, 90, 90), 1000)])).isEmpty)
        #expect(LiquidBackdropPalettePolicy.palette(fromRGB: image([((90, 10, 10), 4)])).isEmpty)
    }

    @Test func lightnessStaysInsideTheLegibleBand() {
        let pixels = image([((255, 255, 255), 600), ((0, 0, 0), 300), ((255, 0, 0), 300)])
        let palette = LiquidBackdropPalettePolicy.palette(fromRGB: pixels)
        #expect(!palette.isEmpty)
        for color in palette {
            let lightness = color.hsl.lightness
            #expect(lightness <= LiquidBackdropPalettePolicy.maximumLightness + 0.001)
            #expect(lightness >= LiquidBackdropPalettePolicy.minimumLightness - 0.001)
        }
    }

    @Test func blobColorsCycleThePalette() {
        let a = LiquidBackdropColor(red: 1, green: 0, blue: 0)
        let b = LiquidBackdropColor(red: 0, green: 0, blue: 1)
        let colors = LiquidBackdropPalettePolicy.blobColors(for: [a, b])
        #expect(colors.count == LiquidBackdropMotion.blobCount)
        #expect(colors[0] == a && colors[1] == b && colors[2] == a)
        #expect(LiquidBackdropPalettePolicy.blobColors(for: []).isEmpty)
    }

    @Test func baseColorIsDarkOrLight() {
        let palette = [LiquidBackdropColor(red: 0.9, green: 0.2, blue: 0.3), LiquidBackdropColor(red: 0.2, green: 0.3, blue: 0.9)]
        #expect(LiquidBackdropPalettePolicy.baseColor(for: palette, isLight: false).hsl.lightness < 0.2)
        #expect(LiquidBackdropPalettePolicy.baseColor(for: palette, isLight: true).hsl.lightness > 0.85)
    }

    @Test func hslRoundTrips() {
        for color in [
            LiquidBackdropColor(red: 0.8, green: 0.2, blue: 0.4),
            LiquidBackdropColor(red: 0.1, green: 0.7, blue: 0.3),
            LiquidBackdropColor(red: 0.2, green: 0.3, blue: 0.9),
        ] {
            let hsl = color.hsl
            let back = LiquidBackdropColor(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness)
            #expect(abs(back.red - color.red) < 0.001)
            #expect(abs(back.green - color.green) < 0.001)
            #expect(abs(back.blue - color.blue) < 0.001)
        }
    }

    @Test func blobsStayOnCanvasAndMoveSmoothly() {
        var previous = LiquidBackdropMotion.blobs(at: 0)
        #expect(previous.count == LiquidBackdropMotion.blobCount)
        var t = 0.0
        while t < 120 {
            t += 1.0 / 24
            let blobs = LiquidBackdropMotion.blobs(at: t)
            for (blob, before) in zip(blobs, previous) {
                #expect(blob.x >= 0.05 && blob.x <= 0.95)
                #expect(blob.y >= 0.05 && blob.y <= 0.95)
                #expect(blob.radius > 0.35 && blob.radius < 0.65)
                // 一帧里挪动不到画布的 2%:慢、不跳。
                #expect(abs(blob.x - before.x) < 0.02)
                #expect(abs(blob.y - before.y) < 0.02)
            }
            previous = blobs
        }
    }

    @Test func sameElapsedTimeGivesTheSameFrame() {
        // 暂停时时间不走,画面原地停住;换歌也不重置位置。
        #expect(LiquidBackdropMotion.blobs(at: 42.5) == LiquidBackdropMotion.blobs(at: 42.5))
        #expect(LiquidBackdropMotion.blobs(at: 0) != LiquidBackdropMotion.blobs(at: 9))
    }

    @Test func colorsMix() {
        let a = LiquidBackdropColor(red: 0, green: 0, blue: 0)
        let b = LiquidBackdropColor(red: 1, green: 0.5, blue: 0)
        #expect(a.mixed(with: b, amount: 0.5) == LiquidBackdropColor(red: 0.5, green: 0.25, blue: 0))
        #expect(a.mixed(with: b, amount: 2) == b)
    }

}
