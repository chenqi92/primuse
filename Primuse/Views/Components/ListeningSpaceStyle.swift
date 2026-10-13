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

/// Where a widget tap outside the play keys asks the app to go: the page of
/// one listening space (`ListeningSpaceLink`). The link lands here first and
/// the root view picks it up — on a cold launch only a placeholder may be
/// mounted when the URL arrives.
@MainActor
@Observable
final class ListeningSpaceOpenRequest {
    static let shared = ListeningSpaceOpenRequest()

    private(set) var pending: ListeningSpace?

    private init() {}

    /// True when `url` is such a link; the request is then recorded.
    func handle(_ url: URL) -> Bool {
        guard let space = ListeningSpaceLink.space(from: url) else { return false }
        pending = space
        return true
    }

    func consume() -> ListeningSpace? {
        defer { pending = nil }
        return pending
    }
}

extension LibrarySection {
    /// The library page of a space; music has no single page.
    init?(listeningSpace space: ListeningSpace) {
        switch space {
        case .music: return nil
        case .radio: self = .radio
        case .spokenWord: self = .spokenWord
        case .podcast: self = .podcasts
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
