#if os(iOS)
import SwiftUI
import UIKit
import WidgetKit
import PrimuseKit

/// iOS 主题偏好。固定主题色负责全局控件，封面取色只负责播放相关氛围；
/// 两者可以同时开启，不再使用旧版互斥的 auto / fixed 模式。
@MainActor
@Observable
final class ThemeColorSettings {
    static let shared = ThemeColorSettings()

    typealias Swatch = AppThemePreferences.Swatch
    static let swatches = AppThemePreferences.swatches
    static let defaultFixedHex = AppThemePreferences.defaultAccentHex

    struct HSB {
        var hue: CGFloat
        var saturation: CGFloat
        var brightness: CGFloat
    }

    var fixedColorHex: String {
        didSet {
            UserDefaults.standard.set(
                AppThemePreferences.normalizedHex(fixedColorHex),
                forKey: AppThemePreferences.accentHexKey
            )
        }
    }

    var coverDrivenAmbient: Bool {
        didSet {
            UserDefaults.standard.set(
                coverDrivenAmbient,
                forKey: AppThemePreferences.coverDrivenAmbientKey
            )
        }
    }

    var ambientStrength: Double {
        didSet {
            UserDefaults.standard.set(
                AppThemePreferences.normalizedAmbientStrength(ambientStrength),
                forKey: AppThemePreferences.ambientStrengthKey
            )
        }
    }

    var fixedColor: Color { Color(hex: fixedColorHex) }
    var baseAccent: Color { fixedColor }

    private static let legacyModeKey = "primuse.theme.colorMode"

    private init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: AppThemePreferences.coverDrivenAmbientKey) == nil {
            // 旧版 auto 表示允许封面取色，fixed 表示关闭；只迁移一次，之后
            // 两个设置完全独立。
            let legacyMode = defaults.string(forKey: Self.legacyModeKey)
            defaults.set(
                legacyMode != "fixed",
                forKey: AppThemePreferences.coverDrivenAmbientKey
            )
        }

        if defaults.object(forKey: AppThemePreferences.accentHexKey) == nil {
            // 旧版安装迁移原图标对应的回退色；全新安装直接采用三端一致的
            // 默认色。直接读取稳定图标 id，避免两个 shared 初始化互相递归。
            let iconKey = "primuse.appIconChoice"
            let hasLegacyPreference = defaults.object(forKey: Self.legacyModeKey) != nil
                || defaults.object(forKey: iconKey) != nil
            let iconID = defaults.string(forKey: iconKey) ?? ""
            defaults.set(
                hasLegacyPreference
                    ? Self.legacyIconAccentHex(iconID)
                    : Self.defaultFixedHex,
                forKey: AppThemePreferences.accentHexKey
            )
        }

        let storedHex = defaults.string(forKey: AppThemePreferences.accentHexKey)
            ?? Self.defaultFixedHex
        fixedColorHex = AppThemePreferences.normalizedHex(storedHex)
        coverDrivenAmbient = defaults.object(forKey: AppThemePreferences.coverDrivenAmbientKey) as? Bool
            ?? AppThemePreferences.defaultCoverDrivenAmbient
        ambientStrength = AppThemePreferences.normalizedAmbientStrength(
            defaults.object(forKey: AppThemePreferences.ambientStrengthKey) as? Double
                ?? AppThemePreferences.defaultAmbientStrength
        )

        // 把可能来自早期版本的非法值归一，确保其它端直接读取同一键也安全。
        defaults.set(fixedColorHex, forKey: AppThemePreferences.accentHexKey)
        defaults.set(coverDrivenAmbient, forKey: AppThemePreferences.coverDrivenAmbientKey)
        defaults.set(ambientStrength, forKey: AppThemePreferences.ambientStrengthKey)
    }

    private static func legacyIconAccentHex(_ iconID: String) -> String {
        switch iconID {
        case "AppIcon12": return "F6406C"
        case "AppIcon11": return "2DA6E3"
        case "AppIcon6": return "40D5C8"
        case "AppIcon9": return "147D8A"
        default: return "E95043"
        }
    }

    static func isValidHex(_ hex: String) -> Bool {
        AppThemePreferences.isValidHex(hex)
    }

    static func hsb(fromHex hex: String) -> HSB {
        let color = Color(hex: hex)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return HSB(hue: h, saturation: s, brightness: b)
    }

    static func hex(fromHSB hsb: HSB) -> String {
        let color = UIColor(
            hue: hsb.hue,
            saturation: hsb.saturation,
            brightness: hsb.brightness,
            alpha: 1
        )
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "%02X%02X%02X",
            Int(round(r * 255)),
            Int(round(g * 255)),
            Int(round(b * 255))
        )
    }

    static func publishBaseAccentToWidget(_ color: Color) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return
        }
        BrandTintStore.save(
            BrandTintStore.RGB(red: Double(red), green: Double(green), blue: Double(blue))
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#endif
