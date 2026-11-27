import Foundation
import Testing
@testable import PrimuseKit

@Suite("封面取色的歌词颜色")
struct LyricsArtworkTintPolicyTests {
    typealias Policy = LyricsArtworkTintPolicy
    typealias RGB = LyricsArtworkTintPolicy.RGB

    /// 封面取色可能给出的颜色：色相环一圈 × 饱和度 × 明度。
    private static func sweep() -> [RGB] {
        var colors: [RGB] = []
        for hueStep in 0..<24 {
            let hue = Double(hueStep) / 24
            for saturation in [0.1, 0.2, 0.35, 0.6, 0.92, 1.0] {
                for brightness in [0.05, 0.3, 0.5, 0.7, 0.85, 1.0] {
                    colors.append(Policy.rgb(hue: hue, saturation: saturation, brightness: brightness))
                }
            }
        }
        return colors
    }

    private static func hueDistance(_ lhs: RGB, _ rhs: RGB) throws -> Double {
        let a = try #require(Policy.hsb(of: lhs)).hue
        let b = try #require(Policy.hsb(of: rhs)).hue
        let distance = abs(a - b)
        return min(distance, 1 - distance)
    }

    @Test("黑白灰封面没有可跟的颜色")
    func grayscaleArtworkFallsBackToDefault() {
        for gray in [0.0, 0.2, 0.5, 0.9, 1.0] {
            let color = RGB(red: gray, green: gray, blue: gray)
            #expect(Policy.lyricColor(for: color, onDarkBackdrop: true) == nil)
            #expect(Policy.lyricColor(for: color, onDarkBackdrop: false) == nil)
        }
        // 只带一点点偏色的灰也算灰。
        let nearlyGray = RGB(red: 0.52, green: 0.5, blue: 0.5)
        #expect(Policy.lyricColor(for: nearlyGray, onDarkBackdrop: true) == nil)
    }

    @Test("深色底：够亮、看得出颜色、色相不变")
    func darkBackdropIsBrightButStillColored() throws {
        for artwork in Self.sweep() {
            let lyric = try #require(Policy.lyricColor(for: artwork, onDarkBackdrop: true))
            #expect(Policy.luminance(lyric) >= Policy.minimumLuminanceOnDarkBackdrop - 1e-6)
            // 对播放页常见的深色背景(近黑带一点色)大号字至少 3:1。
            let backdrop = RGB(red: 0.08, green: 0.08, blue: 0.1)
            #expect(ThemeAccentContrastPolicy.contrastRatio(lyric, backdrop) >= 3)
            // 不能被洗成白色:饱和度留在三成以上。
            let hsb = try #require(Policy.hsb(of: lyric))
            #expect(hsb.saturation >= 0.3)
            let hueShift = try Self.hueDistance(lyric, artwork)
            #expect(hueShift < 0.001)
        }
    }

    @Test("浅色底：够暗、看得出颜色、色相不变")
    func lightBackdropIsDarkButStillColored() throws {
        for artwork in Self.sweep() {
            let lyric = try #require(Policy.lyricColor(for: artwork, onDarkBackdrop: false))
            #expect(Policy.luminance(lyric) <= Policy.maximumLuminanceOnLightBackdrop + 1e-6)
            #expect(ThemeAccentContrastPolicy.contrastRatio(lyric, .white) >= 4.5)
            let hsb = try #require(Policy.hsb(of: lyric))
            #expect(hsb.saturation >= Policy.lightBackdropMinimumSaturation - 1e-6)
            let hueShift = try Self.hueDistance(lyric, artwork)
            #expect(hueShift < 0.001)
        }
    }

    @Test("鲜艳的封面色在深色底上一眼看得出是哪种颜色")
    func vividArtworkKeepsItsCharacterOnDarkBackdrop() throws {
        let red = try #require(Policy.lyricColor(for: RGB(red: 0.85, green: 0.1, blue: 0.1), onDarkBackdrop: true))
        #expect(red.red > 0.95 && red.green < 0.6 && red.blue < 0.6)
        let blue = try #require(Policy.lyricColor(for: RGB(red: 0.1, green: 0.2, blue: 0.85), onDarkBackdrop: true))
        #expect(blue.blue > 0.95 && blue.red < 0.7)
        let green = try #require(Policy.lyricColor(for: RGB(red: 0.1, green: 0.7, blue: 0.2), onDarkBackdrop: true))
        #expect(green.green > 0.95 && green.red < 0.5 && green.blue < 0.6)
    }

    @Test("已经够用的颜色不再多调")
    func alreadyLegibleColorsAreNotWashedOut() throws {
        // 亮黄在深色底上本来就够亮,不往白色混。
        let yellow = try #require(Policy.lyricColor(for: RGB(red: 0.85, green: 0.8, blue: 0.1), onDarkBackdrop: true))
        let hsb = try #require(Policy.hsb(of: yellow))
        #expect(abs(hsb.brightness - 1) < 1e-9)
        #expect(hsb.saturation >= Policy.darkBackdropSaturation.upperBound - 1e-9)
        // 深蓝在浅色底上本来就够暗,只按起步明度画,不再压。
        let navy = try #require(Policy.lyricColor(for: RGB(red: 0.1, green: 0.2, blue: 0.85), onDarkBackdrop: false))
        let navyHSB = try #require(Policy.hsb(of: navy))
        #expect(abs(navyHSB.brightness - Policy.lightBackdropBrightness.upperBound) < 1e-9)
    }

    @Test("HSB 与 RGB 来回换算一致")
    func hsbRoundTrips() throws {
        for color in Self.sweep() {
            let hsb = try #require(Policy.hsb(of: color))
            let back = Policy.rgb(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
            #expect(abs(back.red - color.red) < 1e-9)
            #expect(abs(back.green - color.green) < 1e-9)
            #expect(abs(back.blue - color.blue) < 1e-9)
        }
    }
}
