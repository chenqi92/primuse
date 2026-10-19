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
    ///
    /// 「跟随封面」跟的是这一类自己最后在播时的封面,不是此刻在播的任何封面:
    /// 暂停听书去放歌,书的页面仍是书封的颜色(`effectiveChoice` 已经把它落成固定色或自带色)。
    @MainActor
    var tint: Color {
        guard let fixed = fixedTint else { return .accentColor }
        switch ListeningSpaceTintSettings.shared.effectiveChoice(for: self) {
        case .standard, .artwork:
            return Color(light: fixed.light, dark: fixed.dark)
        case .theme:
            return .accentColor
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
        switch settings.effectiveChoice(for: self) {
        case .standard, .artwork:
            return Color(light: fixed.light, dark: fixed.light)
        case .theme:
            return settings.themeService.map { Self.lightShade(of: $0.uiAccentColor) } ?? .accentColor
        case .fixed(let hex):
            let picked = ListeningSpaceTint.legible(hex: hex) ?? fixed
            return Color(light: picked.light, dark: picked.light)
        }
    }

    /// 白字底下那层深底(首页电台大卡)。自带色、自选色、记下的封面色都从原色压暗
    /// (`ListeningSpaceTint.deepened`);跟主题色时直接用主题算好的深色那档。
    @MainActor
    var backdropTint: Color {
        let settings = ListeningSpaceTintSettings.shared
        guard let fixed = fixedTint else {
            return settings.themeService?.uiDarkAccent ?? ThemeService.defaultDarkAccent
        }
        switch settings.effectiveChoice(for: self) {
        case .standard, .artwork:
            let deep = ListeningSpaceTint.deepened(fixed.light)
            return Color(light: deep, dark: deep)
        case .theme:
            return settings.themeService?.uiDarkAccent ?? ThemeService.defaultDarkAccent
        case .fixed(let hex):
            // 和主题色的深色档一样从挑的原色压暗,不是从压过对比度的那一档再压。
            let deep = ListeningSpaceTint.deepened(UInt32(hex, radix: 16) ?? fixed.light)
            return Color(light: deep, dark: deep)
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
    /// 每一类最后在播时的封面主色(`ListeningSpaceArtworkTintStore`),「跟随封面」按它画。
    private(set) var artworkHexes: [ListeningSpace: String]
    /// 「跟随主题色」读它的颜色,App 启动时接上。
    @ObservationIgnored weak var themeService: ThemeService?
    /// 正在播的这一条属于哪一类,App 启动时接上;取完封面色时按它记到那一类名下。
    @ObservationIgnored var currentSpace: (@MainActor () -> ListeningSpace?)?

    private init() {
        var loaded: [ListeningSpace: ListeningSpaceTintChoice] = [:]
        var artwork: [ListeningSpace: String] = [:]
        for space in ListeningSpaceTintPreferences.customizableSpaces {
            loaded[space] = ListeningSpaceTintPreferences.choice(for: space, in: .standard)
            artwork[space] = ListeningSpaceArtworkTintStore.hex(for: space, in: .standard)
        }
        choices = loaded
        artworkHexes = artwork
        publishToWidgets(reloading: false)
    }

    func choice(for space: ListeningSpace) -> ListeningSpaceTintChoice {
        choices[space] ?? .standard
    }

    /// 实际画的颜色:「跟随封面」换成这一类记下的封面色,没记过时是自带色。
    func effectiveChoice(for space: ListeningSpace) -> ListeningSpaceTintChoice {
        choice(for: space).resolvingArtwork(artworkHexes[space])
    }

    /// 取完正在播的那一条的封面色后调(`ThemeService`):记到它所属的那一类名下,音乐不记。
    /// `hex` 为 nil 表示这一条确实没有封面色,这一类回到自带色。小组件随后跟主题的封面色一起刷新。
    func recordArtwork(_ hex: String?, for space: ListeningSpace?) {
        guard let space, ListeningSpaceTintPreferences.customizableSpaces.contains(space) else { return }
        let normalized = ListeningSpaceTintChoice(storedValue: hex).fixedHex
        guard artworkHexes[space] != normalized else { return }
        artworkHexes[space] = normalized
        ListeningSpaceArtworkTintStore.store(normalized, for: space, in: .standard)
        if let shared = ListeningSpaceTintPreferences.sharedDefaults {
            ListeningSpaceArtworkTintStore.store(normalized, for: space, in: shared)
        }
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

    /// 别的设备经 iCloud 改过的选择(#320)。返回有没有变;变了照常抄给小组件。
    func reloadFromDefaults() -> Bool {
        var changed = false
        for space in ListeningSpaceTintPreferences.customizableSpaces {
            let stored = ListeningSpaceTintPreferences.choice(for: space, in: .standard)
            if choice(for: space) != stored {
                choices[space] = stored
                changed = true
            }
        }
        if changed { publishToWidgets(reloading: true) }
        return changed
    }

    private func publishToWidgets(reloading: Bool) {
        guard let shared = ListeningSpaceTintPreferences.sharedDefaults else { return }
        for space in ListeningSpaceTintPreferences.customizableSpaces {
            ListeningSpaceTintPreferences.store(choice(for: space), for: space, in: shared)
            ListeningSpaceArtworkTintStore.store(artworkHexes[space], for: space, in: shared)
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
