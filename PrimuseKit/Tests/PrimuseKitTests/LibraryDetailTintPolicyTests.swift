import Foundation
import Testing
@testable import PrimuseKit

/// 扫一遍色相环 × 饱和度 × 明度，用来验证"任何封面都得出能用的底色"这类不变量。
private func sweepTints(
    appearance: LibraryDetailTintPolicy.Appearance
) -> [(input: (hue: Double, saturation: Double, brightness: Double), tint: LibraryDetailTint)] {
    var results:
        [(input: (hue: Double, saturation: Double, brightness: Double), tint: LibraryDetailTint)] = []
    for hueStep in 0..<12 {
        let hue = Double(hueStep) / 12
        for saturation in [0.12, 0.35, 0.68, 1.0] {
            for brightness in [0.05, 0.4, 0.75, 1.0] {
                let tint = LibraryDetailTintPolicy.tint(
                    hue: hue,
                    saturation: saturation,
                    brightness: brightness,
                    appearance: appearance
                )
                results.append(((hue, saturation, brightness), tint))
            }
        }
    }
    return results
}

@Suite("详情页底色")
struct LibraryDetailTintPolicyTests {
    @Test("任何封面色算出的底色都够白字读", arguments: [
        LibraryDetailTintPolicy.Appearance.light,
        LibraryDetailTintPolicy.Appearance.dark,
    ])
    func contrastHoldsForEveryArtworkColor(appearance: LibraryDetailTintPolicy.Appearance) {
        for entry in sweepTints(appearance: appearance) {
            let top = LibraryDetailTintPolicy.contrastRatioAgainstWhite(entry.tint.top)
            let bottom = LibraryDetailTintPolicy.contrastRatioAgainstWhite(entry.tint.bottom)
            #expect(
                top >= LibraryDetailTintPolicy.minimumContrastRatio,
                "顶部底色对比度不足: \(entry.input) → \(top)"
            )
            #expect(
                bottom >= LibraryDetailTintPolicy.minimumContrastRatio,
                "底部底色对比度不足: \(entry.input) → \(bottom)"
            )
        }
    }

    @Test("中性底同样满足对比度，且看不出偏色")
    func neutralTintIsReadableAndAchromatic() {
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            let tint = LibraryDetailTintPolicy.neutralTint(appearance: appearance)
            let contrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(tint.top)
            #expect(contrast >= LibraryDetailTintPolicy.minimumContrastRatio)
            #expect(tint.top.saturation <= 0.1)
        }
    }

    @Test("灰度封面走中性底，不硬凑颜色")
    func achromaticArtworkFallsBackToNeutral() {
        let tint = LibraryDetailTintPolicy.tint(
            hue: 0.08,
            saturation: 0.03,
            brightness: 0.62,
            appearance: .dark
        )
        let neutral = LibraryDetailTintPolicy.neutralTint(appearance: .dark)
        #expect(tint == neutral)
    }

    @Test("页尾比页首深，但不会塌成纯黑")
    func bottomIsDeeperThanTop() {
        for entry in sweepTints(appearance: .dark) {
            #expect(entry.tint.bottom.brightness < entry.tint.top.brightness)
            #expect(entry.tint.bottom.brightness > 0)
        }
    }

    @Test("封面的色相是页面身份，原样保留")
    func hueSurvives() {
        for entry in sweepTints(appearance: .light) {
            guard entry.input.saturation >= 0.12 else { continue }
            #expect(abs(entry.tint.top.hue - entry.input.hue) < 0.0001)
            #expect(abs(entry.tint.bottom.hue - entry.input.hue) < 0.0001)
        }
    }

    @Test("饱和度收进区间：霓虹封面压下来，寡淡封面抬上去")
    func saturationIsClamped() {
        let neon = LibraryDetailTintPolicy.tint(
            hue: 0.33,
            saturation: 1.0,
            brightness: 0.9,
            appearance: .dark
        )
        #expect(neon.top.saturation <= 0.58)

        let faint = LibraryDetailTintPolicy.tint(
            hue: 0.33,
            saturation: 0.14,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(faint.top.saturation >= 0.24)
    }

    @Test("深色外观比浅色外观更深")
    func darkAppearanceIsDeeper() {
        let light = LibraryDetailTintPolicy.tint(
            hue: 0.52,
            saturation: 0.45,
            brightness: 0.6,
            appearance: .light
        )
        let dark = LibraryDetailTintPolicy.tint(
            hue: 0.52,
            saturation: 0.45,
            brightness: 0.6,
            appearance: .dark
        )
        #expect(dark.top.brightness < light.top.brightness)
    }

    @Test("越亮的封面给越亮的页面，但幅度有限")
    func brighterArtworkGivesBrighterPageWithinBounds() {
        let dim = LibraryDetailTintPolicy.tint(
            hue: 0.75,
            saturation: 0.4,
            brightness: 0.1,
            appearance: .dark
        )
        let bright = LibraryDetailTintPolicy.tint(
            hue: 0.75,
            saturation: 0.4,
            brightness: 1.0,
            appearance: .dark
        )
        #expect(bright.top.brightness > dim.top.brightness)
        #expect(bright.top.brightness / dim.top.brightness < 1.3)
    }

    @Test("底色深浅落在同一条带里，不会一页发白一页全黑")
    func luminanceStaysInBand() {
        // 白字要读得清的相对亮度上限，和 minimumContrastRatio 是同一件事的两种说法。
        let ceiling = 1.05 / LibraryDetailTintPolicy.minimumContrastRatio - 0.05
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            for entry in sweepTints(appearance: appearance) {
                let luminance = LibraryDetailTintPolicy.relativeLuminance(of: entry.tint.top)
                #expect(luminance <= ceiling, "底色过亮: \(entry.input)")
                #expect(luminance >= 0.005, "底色塌成纯黑: \(entry.input)")
            }
        }
    }

    @Test("色相越界与非法输入都不会算出坏颜色")
    func outOfRangeInputsAreNormalized() {
        let wrapped = LibraryDetailTintPolicy.tint(
            hue: 1.4,
            saturation: 0.5,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(abs(wrapped.top.hue - 0.4) < 0.0001)

        let negative = LibraryDetailTintPolicy.tint(
            hue: -0.25,
            saturation: 0.5,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(abs(negative.top.hue - 0.75) < 0.0001)

        let broken = LibraryDetailTintPolicy.tint(
            hue: .nan,
            saturation: .infinity,
            brightness: .nan,
            appearance: .dark
        )
        #expect(broken.top.hue.isFinite)
        #expect(broken.top.brightness > 0)
        let brokenContrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(broken.top)
        #expect(brokenContrast >= LibraryDetailTintPolicy.minimumContrastRatio)
    }

    @Test("HSB 转 RGB 与标准换算一致")
    func hsbToRGBMatchesReference() {
        let red = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0, saturation: 1, brightness: 1)
        )
        #expect(abs(red.red - 1) < 0.0001)
        #expect(abs(red.green) < 0.0001)
        #expect(abs(red.blue) < 0.0001)

        let cyan = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0.5, saturation: 1, brightness: 1)
        )
        #expect(abs(cyan.red) < 0.0001)
        #expect(abs(cyan.green - 1) < 0.0001)
        #expect(abs(cyan.blue - 1) < 0.0001)

        let gray = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0.3, saturation: 0, brightness: 0.42)
        )
        #expect(abs(gray.red - 0.42) < 0.0001)
        #expect(abs(gray.green - 0.42) < 0.0001)
        #expect(abs(gray.blue - 0.42) < 0.0001)
    }

    @Test("副色同样够白字读，第二色是灰调时退回主色")
    func accentFollowsSameContrastRules() {
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            for entry in sweepTints(appearance: appearance) {
                let accent = LibraryDetailTintPolicy.accentTint(
                    primary: (0.08, 0.7, 0.8),
                    secondary: entry.input,
                    appearance: appearance
                )
                #expect(LibraryDetailTintPolicy.contrastRatioAgainstWhite(accent.top) >= LibraryDetailTintPolicy.minimumContrastRatio)
                #expect(LibraryDetailTintPolicy.contrastRatioAgainstWhite(accent.bottom) >= LibraryDetailTintPolicy.minimumContrastRatio)
            }
        }
        let primary = LibraryDetailTintPolicy.tint(hue: 0.6, saturation: 0.5, brightness: 0.5, appearance: .dark)
        let gray = LibraryDetailTintPolicy.accentTint(
            primary: (0.6, 0.5, 0.5),
            secondary: (0.1, 0.02, 0.7),
            appearance: .dark
        )
        #expect(gray == primary)
        let missing = LibraryDetailTintPolicy.accentTint(primary: (0.6, 0.5, 0.5), secondary: nil, appearance: .dark)
        #expect(missing == primary)
        let teal = LibraryDetailTintPolicy.accentTint(
            primary: (0.6, 0.5, 0.5),
            secondary: (0.45, 0.6, 0.6),
            appearance: .dark
        )
        #expect(abs(teal.top.hue - 0.45) < 0.0001)
    }
}
