import Testing
@testable import PrimuseKit

@Suite("App icon style")
struct AppIconStylePolicyTests {
    @Test("No stored theme means the default light icons")
    func missingThemeIsStandard() {
        #expect(AppIconStylePolicy.appearance(theme: nil, systemIsDark: true) == .standard)
        #expect(AppIconStylePolicy.appearance(theme: "Something", systemIsDark: true) == .standard)
    }

    @Test("Explicit light and dark themes ignore the system appearance")
    func explicitThemes() {
        #expect(AppIconStylePolicy.appearance(theme: "RegularDark", systemIsDark: false)
            == AppIconAppearance(style: .regular, isDark: true))
        #expect(AppIconStylePolicy.appearance(theme: "ClearLight", systemIsDark: true)
            == AppIconAppearance(style: .clear, isDark: false))
        #expect(AppIconStylePolicy.appearance(theme: "TintedDark", systemIsDark: false).assetSuffix == "TintedDark")
    }

    @Test("Automatic themes follow the system appearance")
    func automaticThemes() {
        #expect(AppIconStylePolicy.appearance(theme: "RegularAutomatic", systemIsDark: true).assetSuffix == "RegularDark")
        #expect(AppIconStylePolicy.appearance(theme: "ClearAutomatic", systemIsDark: false).assetSuffix == "ClearLight")
        #expect(AppIconStylePolicy.appearance(theme: "TintedAutomatic", systemIsDark: true).assetSuffix == "TintedDark")
    }

    @Test("Tint colour comes from the name, the custom colour, or the accent colour")
    func tintSources() {
        #expect(AppIconStylePolicy.tintSource(name: nil, custom: "0.1 0.2 0.3 1") == .accent)
        #expect(AppIconStylePolicy.tintSource(name: "Blue", custom: nil) == .named("Blue"))
        #expect(AppIconStylePolicy.tintSource(name: "Other", custom: "0.1 0.2 0.3 1.000000")
            == .custom(red: 0.1, green: 0.2, blue: 0.3))
        #expect(AppIconStylePolicy.tintSource(name: "Other", custom: "garbage") == .accent)
        #expect(AppIconStylePolicy.tintSource(name: "Other", custom: "2 -1 0.5 1")
            == .custom(red: 1, green: 0, blue: 0.5))
    }

    @Test("Grid hues map back to themselves through the display hues")
    func gridHueRoundTrip() {
        for (index, hue) in AppIconTintTable.hues.enumerated() {
            let recovered = AppIconStylePolicy.gridHue(forDisplayHue: AppIconTintTable.displayHues[index])
            let distance = min(abs(recovered - hue), 1 - abs(recovered - hue))
            #expect(distance < 0.001, "grid hue \(hue)")
        }
    }

    @Test("Grid points read straight from the table")
    func tableLookup() {
        // 表里的色相只写了 5 位小数，这里用精确的网格位置。
        let count = AppIconTintTable.hues.count
        for (s, strength) in AppIconTintTable.strengths.enumerated() {
            for h in 0..<count {
                let value = AppIconStylePolicy.tintFactor(gridHue: Double(h) / Double(count), strength: strength, isDark: true)
                let expected = AppIconTintTable.dark[s][h]
                #expect(abs(value.0 - expected[0]) < 1e-6 && abs(value.1 - expected[1]) < 1e-6
                    && abs(value.2 - expected[2]) < 1e-6)
            }
        }
    }

    @Test("Tinted icons take the hue of the chosen colour")
    func tintFollowsColour() {
        for isDark in [false, true] {
            let red = AppIconStylePolicy.tintFactor(red: 1, green: 0.23, blue: 0.19, isDark: isDark)
            let blue = AppIconStylePolicy.tintFactor(red: 0, green: 0.48, blue: 1, isDark: isDark)
            #expect(red.0 > red.2)
            #expect(blue.2 > blue.0)
            let gray = AppIconStylePolicy.tintFactor(red: 0.56, green: 0.56, blue: 0.58, isDark: isDark)
            let spread = max(gray.0, gray.1, gray.2) - min(gray.0, gray.1, gray.2)
            let blueSpread = max(blue.0, blue.1, blue.2) - min(blue.0, blue.1, blue.2)
            // 石墨（系统灰）着色出来接近中性灰，不会变成蓝紫。
            #expect(spread < blueSpread * 0.1)
        }
    }

    @Test("Composition decodes A and B, clamps to the pixel alpha and keeps transparent pixels empty")
    func composition() {
        let range = AppIconTintMapRange(aLow: -1, aHigh: 1, bLow: 0, bHigh: 2)
        // A = 0 (≈127.5)、B = 1 (≈127.5)、不透明；一个全透明像素；一个半透明像素。
        let map: [UInt8] = [128, 128, 255, 9, 200, 200, 0, 0, 128, 255, 128, 0]
        let output = AppIconStylePolicy.composeTinted(
            map: map, width: 3, height: 1, bytesPerPixel: 4, bytesPerRow: 12,
            tint: (0.2, 0.4, 0.6), range: range
        )
        #expect(output.count == 12)
        #expect(output[3] == 255)
        #expect(abs(Int(output[0]) - 51) <= 2 && abs(Int(output[1]) - 102) <= 2 && abs(Int(output[2]) - 153) <= 2)
        #expect(Array(output[4..<8]) == [0, 0, 0, 0])
        // 半透明像素颜色不超过透明度（预乘）。
        #expect(output[11] == 128)
        #expect(output[8] <= 128 && output[9] <= 128 && output[10] <= 128)
    }
}
