#if os(iOS)
import SwiftUI
import UIKit
import WidgetKit
import PrimuseKit

/// User-facing theme color configuration.
///
/// `auto` keeps the historical behavior: the accent follows each song's cover
/// art and falls back to the selected app icon's tint. `fixed` pins the accent
/// to a palette color and stops cover-art extraction entirely.
@MainActor
@Observable
final class ThemeColorSettings {
    static let shared = ThemeColorSettings()

    enum Mode: String {
        case auto
        case fixed
    }

    /// One selectable palette entry. `id` doubles as the persisted hex value
    /// (uppercase, no leading `#`).
    struct Swatch: Identifiable, Equatable {
        let id: String
        let nameKey: LocalizedStringKey

        var color: Color { Color(hex: id) }
    }

    /// Predefined palette spanning the hue wheel plus a neutral slate, so a
    /// fixed accent can be picked without a full color picker. The first entry
    /// matches the app's brand teal.
    static let swatches: [Swatch] = [
        Swatch(id: "147D8A", nameKey: "theme_color_teal"),
        Swatch(id: "2AAA8A", nameKey: "theme_color_turquoise"),
        Swatch(id: "1F8A5B", nameKey: "theme_color_forest"),
        Swatch(id: "0A84FF", nameKey: "theme_color_blue"),
        Swatch(id: "5E5CE6", nameKey: "theme_color_indigo"),
        Swatch(id: "AF52DE", nameKey: "theme_color_purple"),
        Swatch(id: "FF2D55", nameKey: "theme_color_rose"),
        Swatch(id: "E8453C", nameKey: "theme_color_red"),
        Swatch(id: "C96442", nameKey: "theme_color_terracotta"),
        Swatch(id: "FF9500", nameKey: "theme_color_orange"),
        Swatch(id: "D4A017", nameKey: "theme_color_amber"),
        Swatch(id: "5E6B87", nameKey: "theme_color_slate"),
    ]

    static let defaultFixedHex = "147D8A"

    /// HSB working values for the custom picker. Channels are in 0...1.
    struct HSB {
        var hue: CGFloat
        var saturation: CGFloat
        var brightness: CGFloat
    }

    /// Parse an HSB value from the stored hex so the picker can reopen at the
    /// exact position that produced it.
    static func hsb(fromHex hex: String) -> HSB {
        let color = Color(hex: hex)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return HSB(hue: h, saturation: s, brightness: b)
    }

    /// Uppercase six-digit hex for the fixed color, without a leading `#`.
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

    private static let keyMode = "primuse.theme.colorMode"
    private static let keyFixedHex = "primuse.theme.fixedColorHex"

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.keyMode) }
    }

    /// Persisted fixed accent, kept even while `mode` is `.auto` so toggling
    /// back restores the user's previous pick.
    var fixedColorHex: String {
        didSet { UserDefaults.standard.set(fixedColorHex, forKey: Self.keyFixedHex) }
    }

    var fixedColor: Color { Color(hex: fixedColorHex) }

    /// True when cover art must not drive the global accent.
    var usesFixedColor: Bool { mode == .fixed }

    private init() {
        let defaults = UserDefaults.standard
        mode = Mode(rawValue: defaults.string(forKey: Self.keyMode) ?? "") ?? .auto
        let persistedHex = defaults.string(forKey: Self.keyFixedHex) ?? Self.defaultFixedHex
        // Any well-formed hex is valid — the palette is a shortcut, not the
        // full set of choices, so a custom color must survive relaunches.
        fixedColorHex = Self.isValidHex(persistedHex) ? persistedHex : Self.defaultFixedHex
    }

    /// Exactly six hex digits, matching the storage format written by
    /// `hex(fromHSB:)` and by the palette's swatch identifiers.
    static func isValidHex(_ hex: String) -> Bool {
        hex.count == 6 && hex.allSatisfy(\.isHexDigit)
    }

    /// Accent to use whenever no cover art is driving the theme: the fixed
    /// palette color, or the selected app icon's tint in `auto` mode.
    var baseAccent: Color {
        baseAccent(iconTint: AppIconService.shared.currentTint)
    }

    /// Same resolution as `baseAccent`, for callers that must not touch
    /// `AppIconService.shared` — notably `AppIconService.init`, where reentering
    /// its own `static let shared` would deadlock.
    func baseAccent(iconTint: Color) -> Color {
        mode == .fixed ? fixedColor : iconTint
    }

    /// Mirror the effective base accent into the App Group so the widget's next
    /// render matches the app, then refresh timelines immediately — without the
    /// reload the home-screen widget keeps its stale color until iOS wakes it.
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
