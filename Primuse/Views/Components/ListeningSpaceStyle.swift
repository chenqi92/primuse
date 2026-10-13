import PrimuseKit
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// How each listening space presents itself: one colour, one name, one
/// symbol, used everywhere a space is named (tabs, the player bar's dot,
/// home cards, search groups) so they read the same on every screen.
extension ListeningSpace {
    /// Music follows the app's accent. Radio, spoken word and podcasts have
    /// their own hues (`fixedTint`, shared with Apple TV and the widgets),
    /// which the user can swap for the theme colour, the cover's colour or a
    /// colour of their own (`ListeningSpaceTintSettings`).
    @MainActor
    var tint: Color {
        guard let fixed = fixedTint else { return .accentColor }
        let settings = ListeningSpaceTintSettings.shared
        switch settings.choice(for: self) {
        case .standard:
            return Color(light: fixed.light, dark: fixed.dark)
        case .theme:
            return .accentColor
        case .artwork:
            return settings.themeService?.artworkLegibleAccent ?? .accentColor
        case .fixed(let hex):
            let picked = ListeningSpaceTint.legible(hex: hex) ?? fixed
            return Color(light: picked.light, dark: picked.dark)
        }
    }

    /// The deeper, light-appearance shade in both appearances: under a white
    /// glyph (the library's icon tiles) the dark-mode shade is too pale to
    /// read against.
    @MainActor
    var glyphTileTint: Color {
        guard let fixed = fixedTint else { return .accentColor }
        let settings = ListeningSpaceTintSettings.shared
        switch settings.choice(for: self) {
        case .standard:
            return Color(light: fixed.light, dark: fixed.light)
        case .theme:
            return settings.themeService.map { Self.lightShade(of: $0.uiAccentColor) } ?? .accentColor
        case .artwork:
            return settings.themeService.map { Self.lightShade(of: $0.artworkLegibleAccent) } ?? .accentColor
        case .fixed(let hex):
            let picked = ListeningSpaceTint.legible(hex: hex) ?? fixed
            return Color(light: picked.light, dark: picked.light)
        }
    }

    /// 随外观变的颜色在浅色外观下那一档,深色外观里也用它。
    private static func lightShade(of color: Color) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        return Color(color.resolve(in: environment))
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

/// The colour the user picked for radio, spoken word and podcasts
/// (`ListeningSpaceTintChoice`), kept on this device like the theme colour and
/// mirrored into the App Group for the widgets. `ListeningSpace.tint` reads it,
/// so every view naming a space follows a change at once.
@MainActor
@Observable
final class ListeningSpaceTintSettings {
    static let shared = ListeningSpaceTintSettings()

    private(set) var choices: [ListeningSpace: ListeningSpaceTintChoice]
    /// 「跟随主题色」「跟随封面」读它的颜色,App 启动时接上。
    @ObservationIgnored weak var themeService: ThemeService?

    private init() {
        var loaded: [ListeningSpace: ListeningSpaceTintChoice] = [:]
        for space in ListeningSpaceTintPreferences.customizableSpaces {
            loaded[space] = ListeningSpaceTintPreferences.choice(for: space, in: .standard)
        }
        choices = loaded
        publishToWidgets(reloading: false)
    }

    func choice(for space: ListeningSpace) -> ListeningSpaceTintChoice {
        choices[space] ?? .standard
    }

    /// 有一类选了「跟随封面」:主题色固定、播放背景也不取封面色时,封面照样要取色。
    var followsArtwork: Bool {
        choices.values.contains(.artwork)
    }

    /// 拖自定义颜色滑杆的途中不刷新小组件(`reloadingWidgets: false`),松手时再刷。
    func setChoice(
        _ choice: ListeningSpaceTintChoice,
        for space: ListeningSpace,
        reloadingWidgets: Bool = true
    ) {
        guard ListeningSpaceTintPreferences.customizableSpaces.contains(space) else { return }
        if self.choice(for: space) != choice {
            choices[space] = choice
            ListeningSpaceTintPreferences.store(choice, for: space, in: .standard)
        }
        publishToWidgets(reloading: reloadingWidgets)
    }

    private func publishToWidgets(reloading: Bool) {
        guard let shared = ListeningSpaceTintPreferences.sharedDefaults else { return }
        for space in ListeningSpaceTintPreferences.customizableSpaces {
            ListeningSpaceTintPreferences.store(choice(for: space), for: space, in: shared)
        }
        #if canImport(WidgetKit)
        if reloading { WidgetCenter.shared.reloadAllTimelines() }
        #endif
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
