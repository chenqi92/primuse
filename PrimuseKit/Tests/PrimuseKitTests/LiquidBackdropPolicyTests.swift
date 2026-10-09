import Foundation
import Testing
@testable import PrimuseKit

@Suite struct LiquidBackdropPolicyTests {
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
