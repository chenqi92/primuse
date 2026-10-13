import PrimuseKit
import SwiftUI

/// How each listening space presents itself: one colour, one name, one
/// symbol, used everywhere a space is named (tabs, the player bar's dot,
/// home cards, search groups) so they read the same on every screen.
extension ListeningSpace {
    /// Music follows the app's accent; radio, spoken word and podcasts have
    /// fixed hues (`fixedTint`, shared with Apple TV and the widgets) that
    /// stay apart from any accent the user picks.
    var tint: Color {
        guard let fixed = fixedTint else { return .accentColor }
        return Color(light: fixed.light, dark: fixed.dark)
    }

    /// The deeper, light-appearance shade in both appearances: under a white
    /// glyph (the library's icon tiles) the dark-mode shade is too pale to
    /// read against.
    var glyphTileTint: Color {
        guard let fixed = fixedTint else { return .accentColor }
        return Color(light: fixed.light, dark: fixed.light)
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .music: "listening_space_music"
        case .radio: "listening_space_radio"
        case .spokenWord: "listening_space_spoken_word"
        case .podcast: "listening_space_podcast"
        }
    }

    var title: String {
        switch self {
        case .music: String(localized: "listening_space_music")
        case .radio: String(localized: "listening_space_radio")
        case .spokenWord: String(localized: "listening_space_spoken_word")
        case .podcast: String(localized: "listening_space_podcast")
        }
    }
}

private extension Color {
    /// A colour with separate light and dark values, each 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = ListeningSpaceTint.components(
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
            )
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let rgb = ListeningSpaceTint.components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }
}
