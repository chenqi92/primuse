import PrimuseKit
import SwiftUI

/// How each listening space presents itself: one colour, one name, one
/// symbol, used everywhere a space is named (tabs, the player bar's dot,
/// home cards, search groups) so the three read the same on every screen.
extension ListeningSpace {
    /// Music follows the app's accent; radio and spoken word have fixed hues
    /// that stay apart from any accent the user picks.
    var tint: Color {
        switch self {
        case .music:
            return .accentColor
        case .radio:
            return Color(light: (0xD9, 0x48, 0x0F), dark: (0xFF, 0x8A, 0x4C))
        case .spokenWord:
            return Color(light: (0x0F, 0x8A, 0x6A), dark: (0x3F, 0xD1, 0xA6))
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .music: "listening_space_music"
        case .radio: "listening_space_radio"
        case .spokenWord: "listening_space_spoken_word"
        }
    }

    var title: String {
        switch self {
        case .music: String(localized: "listening_space_music")
        case .radio: String(localized: "listening_space_radio")
        case .spokenWord: String(localized: "listening_space_spoken_word")
        }
    }

    var systemImage: String {
        switch self {
        case .music: "music.note"
        case .radio: "dot.radiowaves.left.and.right"
        case .spokenWord: "books.vertical.fill"
        }
    }
}

private extension Color {
    /// A colour with separate light and dark values.
    init(light: (Int, Int, Int), dark: (Int, Int, Int)) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
            return NSColor(
                srgbRed: CGFloat(rgb.0) / 255,
                green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255,
                alpha: 1
            )
        })
        #else
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(rgb.0) / 255,
                green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255,
                alpha: 1
            )
        })
        #endif
    }
}
