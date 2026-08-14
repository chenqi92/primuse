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

enum PrimuseAppSkin: String, CaseIterable, Identifiable {
    case system
    case nocturne

    static let storageKey = "primuse.appearance.appSkin"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "appearance_skin_system"
        case .nocturne: "appearance_skin_nocturne"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .system: "appearance_skin_system_description"
        case .nocturne: "appearance_skin_nocturne_description"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .nocturne: "sparkles.rectangle.stack"
        }
    }
}

enum PrimusePlayerStageStyle: String, CaseIterable, Identifiable {
    case followsSkin
    case sleeveIndex
    case lyricWell
    case coverStage
    case spectrumNebula
    case luminousField
    case typography

    static let storageKey = "primuse.appearance.playerStage"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .followsSkin: "player_stage_follows_skin"
        case .sleeveIndex: "player_stage_sleeve_index"
        case .lyricWell: "player_stage_lyric_well"
        case .coverStage: "player_stage_cover_stage"
        case .spectrumNebula: "player_stage_spectrum_nebula"
        case .luminousField: "player_stage_luminous_field"
        case .typography: "player_stage_typography"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .followsSkin: "player_stage_follows_skin_description"
        case .sleeveIndex: "player_stage_sleeve_index_description"
        case .lyricWell: "player_stage_lyric_well_description"
        case .coverStage: "player_stage_cover_stage_description"
        case .spectrumNebula: "player_stage_spectrum_nebula_description"
        case .luminousField: "player_stage_luminous_field_description"
        case .typography: "player_stage_typography_description"
        }
    }

    var icon: String {
        switch self {
        case .followsSkin: "wand.and.rays"
        case .sleeveIndex: "rectangle.portrait.tophalf.filled"
        case .lyricWell: "quote.bubble.fill"
        case .coverStage: "square.stack.3d.up.fill"
        case .spectrumNebula: "waveform.path.ecg.rectangle.fill"
        case .luminousField: "lightspectrum.horizontal"
        case .typography: "textformat.size.larger"
        }
    }
}

enum PrimuseNocturnePalette {
    static let canvas = Color(red: 0.025, green: 0.028, blue: 0.045)
    static let elevated = Color(red: 0.047, green: 0.050, blue: 0.074)
    static let ink = Color(red: 0.953, green: 0.957, blue: 0.996)
    static let muted = Color(red: 0.57, green: 0.56, blue: 0.64)
    static let violet = Color(red: 0.71, green: 0.66, blue: 0.99)
    static let peach = Color(red: 0.98, green: 0.55, blue: 0.39)

    private static let strips: [Color] = [
        Color(red: 0.98, green: 0.48, blue: 0.36),
        Color(red: 0.72, green: 0.62, blue: 0.98),
        Color(red: 0.38, green: 0.61, blue: 0.86),
        Color(red: 0.95, green: 0.69, blue: 0.35),
        Color(red: 0.55, green: 0.80, blue: 0.74),
        Color(red: 0.89, green: 0.54, blue: 0.68),
    ]

    static func stripColor(for identity: String) -> Color {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return strips[Int(value % UInt64(strips.count))]
    }
}

struct PrimuseNocturneBackdrop: View {
    var accent: Color = PrimuseNocturnePalette.violet
    var strength: Double = 1

    var body: some View {
        ZStack {
            PrimuseNocturnePalette.canvas

            RadialGradient(
                colors: [accent.opacity(0.34 * strength), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )

            RadialGradient(
                colors: [PrimuseNocturnePalette.peach.opacity(0.18 * strength), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 460
            )

            LinearGradient(
                colors: [.clear, PrimuseNocturnePalette.canvas.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct PrimuseScreenSkinModifier: ViewModifier {
    @AppStorage(PrimuseAppSkin.storageKey)
    private var skinRawValue = PrimuseAppSkin.system.rawValue

    private var usesNocturne: Bool {
        PrimuseAppSkin(rawValue: skinRawValue) == .nocturne
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesNocturne {
            content
                .scrollContentBackground(.hidden)
                .background(PrimuseNocturneBackdrop(strength: 0.68))
                .foregroundStyle(PrimuseNocturnePalette.ink)
                .tint(PrimuseNocturnePalette.violet)
                .toolbarBackground(PrimuseNocturnePalette.canvas.opacity(0.86), for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            content
        }
    }
}

extension View {
    func primuseScreenSkin() -> some View {
        modifier(PrimuseScreenSkinModifier())
    }
}

#endif
