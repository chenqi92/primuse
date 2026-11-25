import Foundation
import Testing
@testable import PrimuseKit

@Suite struct LiquidBackdropPolicyTests {

    @Test("Repeated bass attacks rise above a sustained bassline at different frame rates and gains")
    func bassPulseEnvelope() {
        for fps in [15, 30, 60] {
            for gain in [0.01, 0.5] {
                var pulse = PlayerBackdropBassPulse()
                let dt = 1.0 / Double(fps)
                for _ in 0..<fps { pulse.update(power: gain, elapsed: dt) }
                for _ in 0..<8 {
                    pulse.update(power: 4 * gain, elapsed: dt)
                    #expect(pulse.intensity(sensitivity: 0.5) > 0.45)
                    #expect(pulse.intensity(sensitivity: 1) > pulse.intensity(sensitivity: 0))
                    for _ in 1..<fps / 2 { pulse.update(power: gain, elapsed: dt) }
                    #expect(pulse.intensity(sensitivity: 0.5) < 0.05)
                }
            }
        }
    }

    @Test("Silence, low-level noise and a sustained bass note settle at rest")
    func bassPulseNoiseFloor() {
        var pulse = PlayerBackdropBassPulse()
        for power in [0.0, 1e-7, 2e-6, .nan, .infinity] {
            pulse.update(power: power, elapsed: 1.0 / 30)
            #expect(pulse.intensity(sensitivity: 1) == 0)
        }
        for _ in 0..<90 { pulse.update(power: 0.16, elapsed: 1.0 / 30) }
        pulse.update(power: .nan, elapsed: .nan)
        #expect(pulse.intensity(sensitivity: .nan) == 0)
    }

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

    @Test("Liquid mesh moves visibly and smoothly without opening gaps at the edges")
    func liquidMeshMotion() {
        let first = MeshBackdropPalettePolicy.liquidPoints(at: 0)
        let later = MeshBackdropPalettePolicy.liquidPoints(at: 12)
        #expect(abs(first[4].x - later[4].x) > 0.15)
        var previous = first
        for frame in 1...2880 {
            let points = MeshBackdropPalettePolicy.liquidPoints(at: Double(frame) / 24)
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
            for (point, before) in zip(points, previous) {
                #expect(abs(point.x - before.x) < 0.003)
                #expect(abs(point.y - before.y) < 0.003)
            }
            previous = points
        }
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

    @Test func darkOliveGreenAndWarmBrownStayDistinctInPalette() {
        // 模拟深绿树丛 + 暖米/暗棕人像 + 浅灰天空的封面：暗绿与暗棕即使 RGB 欧氏距离较小也应同时保留。
        let pixels = image([
            ((220, 224, 220), 600), // 浅灰白天空
            ((42, 66, 30), 500),    // 深黄绿树影
            ((62, 48, 32), 450),    // 暗棕阴影
            ((205, 185, 148), 350), // 浅米黄衣物
        ])
        let palette = LiquidBackdropPalettePolicy.palette(fromRGB: pixels)
        // 主导色不应被浅灰天空占掉，且黄绿色调必须保留在调色板里。
        #expect(palette.contains { $0.green > $0.red && $0.green > $0.blue })
        #expect(palette.first.map { $0.hsl.saturation >= 0.16 } == true)
    }

    @Test func solidArtworkKeepsItsColorAndTinyImagesFallBack() {
        let gray = LiquidBackdropPalettePolicy.palette(fromRGB: image([((90, 90, 90), 1000)]))
        #expect(gray.count == 1)
        #expect(abs(gray[0].red - 90.0 / 255) < 0.00001)
        #expect(gray[0].red == gray[0].green && gray[0].green == gray[0].blue)
        #expect(LiquidBackdropPalettePolicy.palette(fromRGB: image([((90, 10, 10), 4)])).isEmpty)
    }

    @Test func vividArtworkRetainsBlueCyanAndPurpleWithoutWhiteDominating() {
        let palette = LiquidBackdropPalettePolicy.palette(fromRGB: image([
            ((240, 240, 240), 1000), ((20, 55, 145), 500),
            ((30, 150, 190), 350), ((150, 110, 190), 200)
        ]))
        let vivid = MeshBackdropPalettePolicy.vividPalette(from: palette)
        #expect(vivid.count >= 3)
        #expect(vivid.count <= 4)
        #expect(vivid.allSatisfy { $0.hsl.saturation > 0.18 })
        #expect(vivid.contains { $0.blue > $0.green && $0.green > $0.red })
        #expect(vivid.contains { $0.blue > $0.red && $0.red > $0.green })
    }

    @Test func vividMonochromeStaysNeutral() {
        let palette = [0.0, 0.2, 0.7, 1.0].map { LiquidBackdropColor(red: $0, green: $0, blue: $0) }
        for color in MeshBackdropPalettePolicy.vividPalette(from: palette) {
            #expect(abs(color.red - color.green) < 1e-9)
            #expect(abs(color.green - color.blue) < 1e-9)
        }
        #expect(MeshBackdropPalettePolicy.vividPalette(from: []).isEmpty)
    }

    @Test func vividStopsProtectWhiteTextWithoutAFullScreenScrim() {
        for contrast in [false, true] {
            for red in stride(from: 0.0, through: 1.0, by: 0.1) {
                for green in stride(from: 0.0, through: 1.0, by: 0.1) {
                    for blue in stride(from: 0.0, through: 1.0, by: 0.1) {
                        let vivid = MeshBackdropPalettePolicy.vividPalette(
                            from: [.init(red: red, green: green, blue: blue)], usesIncreasedContrast: contrast)
                        #expect(MeshBackdropPalettePolicy.maximumLuminance(in: vivid) <= (contrast ? 0.06 : 0.12) + 1e-9)
                    }
                }
            }
        }
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


    // MARK: - 进度条

    @Test("Progress artwork gradient keeps the dominant hue at the play head and skips grey covers")
    func progressGradientOrder() throws {
        let red = LiquidBackdropColor(red: 0.85, green: 0.12, blue: 0.1)
        let blue = LiquidBackdropColor(red: 0.1, green: 0.2, blue: 0.9)
        let green = LiquidBackdropColor(red: 0.1, green: 0.7, blue: 0.25)
        let yellow = LiquidBackdropColor(red: 0.95, green: 0.85, blue: 0.1)
        let grey = LiquidBackdropColor(red: 0.5, green: 0.5, blue: 0.52)
        for dark in [true, false] {
            let stops = ProgressArtworkGradientPolicy.stops(from: [red, grey, blue, green, yellow], onDarkBackdrop: dark)
            #expect(stops.count == ProgressArtworkGradientPolicy.maximumStops)
            let head = try #require(stops.last).hsl.hue
            #expect(min(head, 1 - head) < 0.03)
            #expect(ProgressArtworkGradientPolicy.stops(from: [grey, LiquidBackdropColor(red: 0.1, green: 0.1, blue: 0.1)],
                                                         onDarkBackdrop: dark).isEmpty)
        }
        #expect(ProgressArtworkGradientPolicy.stops(from: [], onDarkBackdrop: true).isEmpty)
    }

    @Test("A single-colour cover still gets a two-stop gradient with a neighbouring hue")
    func progressGradientCompanion() {
        let teal = LiquidBackdropColor(red: 0.1, green: 0.6, blue: 0.6)
        let near = LiquidBackdropColor(red: 0.12, green: 0.62, blue: 0.58)
        let stops = ProgressArtworkGradientPolicy.stops(from: [teal, near], onDarkBackdrop: true)
        #expect(stops.count == 2)
        let shift = stops[0].hsl.hue - stops[1].hsl.hue
        #expect(abs(shift - ProgressArtworkGradientPolicy.companionHueShift) < 0.02)
    }

    @Test("Progress gradient colours stay legible on the player backdrop")
    func progressGradientLegibility() {
        let palette = [
            LiquidBackdropColor(red: 0.05, green: 0.05, blue: 0.4),
            LiquidBackdropColor(red: 0.98, green: 0.95, blue: 0.3),
            LiquidBackdropColor(red: 0.4, green: 0.05, blue: 0.1),
        ]
        for color in ProgressArtworkGradientPolicy.stops(from: palette, onDarkBackdrop: true) {
            #expect(ProgressArtworkGradientPolicy.relativeLuminance(color)
                    >= ProgressArtworkGradientPolicy.minimumLuminanceOnDarkBackdrop - 0.001)
        }
        for color in ProgressArtworkGradientPolicy.stops(from: palette, onDarkBackdrop: false) {
            #expect(ProgressArtworkGradientPolicy.relativeLuminance(color)
                    <= ProgressArtworkGradientPolicy.maximumLuminanceOnLightBackdrop + 0.001)
            #expect(color.hsl.saturation >= 0.5)
        }
    }

    @Test("Flow bands cover the track plus one period and repeat seamlessly")
    func progressFlowPattern() {
        for layer in ProgressFlowPattern.layers {
            for width in [0.0, 1, 95, 96, 97, 350, 1024] {
                let count = ProgressFlowPattern.periodCount(trackWidth: width, period: layer.period)
                #expect(Double(count) * layer.period >= width + layer.period)
                let stops = ProgressFlowPattern.stops(periodCount: count)
                #expect(stops.count == count * (ProgressFlowPattern.band.count - 1) + 1)
                #expect(stops.first?.location == 0 && stops.last?.location == 1)
                #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location })
                #expect(stops.first?.opacity == stops.last?.opacity)
                #expect(stops.filter { $0.opacity == 1 }.count == count)
            }
            #expect(layer.duration > 1 && layer.duration < 3)
        }
        #expect(ProgressFlowPattern.periodCount(trackWidth: .infinity, period: 96) == 1)
    }

    @Test("Breath level eases between dim and bright once per cycle")
    func progressBreathLevel() {
        let cycle = ProgressBreathPolicy.cycle
        #expect(abs(ProgressBreathPolicy.level(at: 0)) < 1e-9)
        #expect(abs(ProgressBreathPolicy.level(at: cycle / 2) - 1) < 1e-9)
        #expect(ProgressBreathPolicy.level(at: cycle * 7) < 1e-6)
        #expect(ProgressBreathPolicy.level(at: .nan) == 0)
        for step in 0...100 {
            let level = ProgressBreathPolicy.level(at: Double(step) * 0.137)
            #expect(level >= 0 && level <= 1)
        }
        #expect(abs(ProgressBreathPolicy.interpolate(0.2...0.8, 0.5) - 0.5) < 1e-12)
        #expect(ProgressBreathPolicy.interpolate(0.2...0.8, 3) == 0.8)
    }


    @Test("A custom backdrop colour leads its palette and spreads into lighter, darker and neighbouring tones")
    func customBackdropPalette() {
        let indigo = LiquidBackdropColor(red: 0.37, green: 0.36, blue: 0.9)
        let palette = CustomBackdropPalettePolicy.palette(for: indigo)
        #expect(palette.count == 5)
        let lead = palette[0].hsl
        #expect(abs(lead.hue - indigo.hsl.hue) < 0.01)
        #expect(Set(palette).count == palette.count)
        #expect(palette.contains { $0.hsl.lightness > lead.lightness + 0.05 })
        #expect(palette.contains { $0.hsl.lightness < lead.lightness - 0.05 })
        for color in palette {
            #expect(color.hsl.lightness <= LiquidBackdropPalettePolicy.maximumLightness + 0.001)
            #expect(color.hsl.lightness >= LiquidBackdropPalettePolicy.minimumLightness - 0.001)
        }
        // 纯黑、纯白也排得出一组(灰阶),不会是空的。
        #expect(!CustomBackdropPalettePolicy.palette(for: LiquidBackdropColor(red: 0, green: 0, blue: 0)).isEmpty)
        #expect(!CustomBackdropPalettePolicy.palette(for: LiquidBackdropColor(red: 1, green: 1, blue: 1)).isEmpty)
    }

}
