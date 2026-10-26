import Foundation
import Testing
@testable import PrimuseKit

@Suite("封面取主题色的候选像素")
struct ArtworkAccentPixelPolicyTests {
    private typealias Pixel = ArtworkAccentPixelPolicy.Pixel
    private static let white = Pixel(hue: 0, saturation: 0, brightness: 1)

    private func cover(_ parts: [(Pixel, Int)], total: Int = 1_600) -> [Pixel] {
        let colored = parts.flatMap { Array(repeating: $0.0, count: $0.1) }
        return colored + Array(repeating: Self.white, count: total - colored.count)
    }

    private func dominantHue(_ pixels: [Pixel]) -> Double? {
        ArtworkAccentPixelPolicy.candidateBuckets(pixels).max { $0.score < $1.score }?.hue
    }

    private func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    @Test("白底上的满亮度红字取红色,不当成接近白")
    func fullBrightnessRedOnWhite() throws {
        let red = Pixel(hue: 0.0, saturation: 1, brightness: 1)
        let pink = Pixel(hue: 0.99, saturation: 0.5, brightness: 1)
        let hue = try #require(dominantHue(cover([(red, 40), (pink, 20)])))
        #expect(hueDistance(hue, 0) < 0.03)
    }

    @Test("很小一块明显的颜色也认")
    func tinyColoredMark() throws {
        let red = Pixel(hue: 0.98, saturation: 0.9, brightness: 0.85)
        let hue = try #require(dominantHue(cover([(red, 5)])))
        #expect(hueDistance(hue, 0.98) < 0.03)
    }

    @Test("浅色封面取它自己的色相")
    func pastelCover() throws {
        let paleGreen = Pixel(hue: 0.37, saturation: 0.11, brightness: 0.93)
        let hue = try #require(dominantHue(cover([(paleGreen, 1_200)])))
        #expect(hueDistance(hue, 0.37) < 0.03)
    }

    @Test("有鲜艳色时浅色不抢主色")
    func vividBeatsPastel() throws {
        let paleGreen = Pixel(hue: 0.37, saturation: 0.11, brightness: 0.93)
        let blue = Pixel(hue: 0.62, saturation: 0.8, brightness: 0.7)
        let hue = try #require(dominantHue(cover([(paleGreen, 1_200), (blue, 60)])))
        #expect(hueDistance(hue, 0.62) < 0.03)
    }

    @Test("黑白封面仍然没有主色")
    func monochromeCoverStaysWithoutAccent() {
        var pixels: [Pixel] = []
        for index in 0..<1_600 {
            let brightness = Double(index % 100) / 100
            // 灰阶加一点冷暖偏色和暗部噪点。
            pixels.append(Pixel(hue: index % 2 == 0 ? 0.6 : 0.1, saturation: 0.04, brightness: brightness))
        }
        pixels += Array(repeating: Pixel(hue: 0.0, saturation: 0.5, brightness: 0.12), count: 6)
        #expect(ArtworkAccentPixelPolicy.candidateBuckets(pixels).isEmpty)
    }

    @Test("浅色只占一小块时不算封面的颜色")
    func smallPastelAreaIsIgnored() {
        let paleGreen = Pixel(hue: 0.37, saturation: 0.11, brightness: 0.93)
        #expect(ArtworkAccentPixelPolicy.candidateBuckets(cover([(paleGreen, 200)])).isEmpty)
    }
}
