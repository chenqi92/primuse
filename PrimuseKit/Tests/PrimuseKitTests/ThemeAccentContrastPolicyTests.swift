import Foundation
import Testing
@testable import PrimuseKit

@Suite("主题强调色对比度下限")
struct ThemeAccentContrastPolicyTests {
    typealias Policy = ThemeAccentContrastPolicy

    private static func rgb(_ hex: UInt32) -> Policy.RGB {
        Policy.RGB(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// 封面取色可能给出的颜色：色相环一圈 × 饱和度 × 明度，覆盖取色时限定的区间以外。
    private static func sweep() -> [Policy.RGB] {
        var colors: [Policy.RGB] = []
        for hueStep in 0..<24 {
            let hue = Double(hueStep) / 24
            for saturation in [0.0, 0.2, 0.35, 0.6, 0.92, 1.0] {
                for brightness in [0.0, 0.1, 0.3, 0.5, 0.7, 0.85, 1.0] {
                    colors.append(Self.fromHSB(hue: hue, saturation: saturation, brightness: brightness))
                }
            }
        }
        return colors
    }

    private static func fromHSB(hue: Double, saturation: Double, brightness: Double) -> Policy.RGB {
        let sector = hue * 6
        let index = Int(sector.rounded(.down)) % 6
        let offset = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * offset)
        let t = brightness * (1 - saturation * (1 - offset))
        switch index {
        case 0: return Policy.RGB(red: brightness, green: t, blue: p)
        case 1: return Policy.RGB(red: q, green: brightness, blue: p)
        case 2: return Policy.RGB(red: p, green: brightness, blue: t)
        case 3: return Policy.RGB(red: p, green: q, blue: brightness)
        case 4: return Policy.RGB(red: t, green: p, blue: brightness)
        default: return Policy.RGB(red: brightness, green: p, blue: q)
        }
    }

    @Test("任何颜色调整后在对应底色上都够 4.5:1", arguments: [
        Policy.Appearance.light,
        Policy.Appearance.dark,
    ])
    func everyColorBecomesReadable(appearance: Policy.Appearance) {
        let ground = Policy.background(for: appearance)
        for color in Self.sweep() {
            let adjusted = Policy.legible(color, for: appearance)
            let ratio = Policy.contrastRatio(adjusted, ground)
            #expect(ratio >= Policy.minimumContrastRatio - 1e-6, "\(color) → \(adjusted): \(ratio)")
        }
    }

    @Test("已经读得清的颜色原样返回")
    func readableColorsAreUntouched() {
        // 品牌品红两档、深红、深蓝在白底上都过线
        for hex: UInt32 in [0xD6176F, 0xD91111, 0x1154D9, 0x147D8A] {
            #expect(Policy.legible(Self.rgb(hex), for: .light) == Self.rgb(hex))
        }
        // 图标品红、亮蓝、亮粉在黑底上都过线
        for hex: UInt32 in [0xEF1A7F, 0x0A84FF, 0xFF5FA2] {
            #expect(Policy.legible(Self.rgb(hex), for: .dark) == Self.rgb(hex))
        }
    }

    @Test("浅色外观只压暗、不变色相，且刚好压到线上")
    func lightAppearanceDarkensProportionally() {
        let yellow = Self.rgb(0xD9D957)   // 黄色封面取色，白底上约 1.5:1
        let adjusted = Policy.legible(yellow, for: .light)
        #expect(adjusted.red < yellow.red)
        // 等比缩放：各分量之比不变，色相与饱和度就不变
        #expect(abs(adjusted.red / adjusted.blue - yellow.red / yellow.blue) < 1e-6)
        #expect(abs(adjusted.red - adjusted.green) < 1e-9)
        let ratio = Policy.contrastRatio(adjusted, .white)
        #expect(ratio >= Policy.minimumContrastRatio - 1e-6 && ratio < Policy.minimumContrastRatio + 0.01)
    }

    @Test("深色外观先提亮度、不够再往白色混，色相不跑")
    func darkAppearanceLightensKeepingHue() {
        let navy = Self.rgb(0x0A2880)     // 深蓝封面，黑底上约 1.6:1
        let adjusted = Policy.legible(navy, for: .dark)
        #expect(adjusted.blue >= adjusted.green && adjusted.green >= adjusted.red)
        let ratio = Policy.contrastRatio(adjusted, .black)
        #expect(ratio >= Policy.minimumContrastRatio - 1e-6 && ratio < Policy.minimumContrastRatio + 0.01)

        // 纯黑没有色相可留，混成能读的灰
        let black = Policy.legible(.black, for: .dark)
        #expect(black.red == black.green && black.green == black.blue)
        #expect(Policy.contrastRatio(black, .black) >= Policy.minimumContrastRatio - 1e-6)
    }

    @Test("深色外观提亮到线上时压白字也还够 4.5:1")
    func minimalLiftKeepsWhiteTextReadable() {
        // 白字压在强调色上的地方（首页卡片等）不做二次判断，提亮只提到刚好过线才不会把白字逼糊
        for color in Self.sweep() where Policy.contrastRatio(color, .black) < Policy.minimumContrastRatio {
            let adjusted = Policy.legible(color, for: .dark)
            #expect(Policy.contrastRatio(.white, adjusted) >= 4.5, "\(color) → \(adjusted)")
        }
    }
}
