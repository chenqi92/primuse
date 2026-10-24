import Foundation
import PrimuseKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 封面视图要读的几项动态封面偏好, 整个 App 共用一份。
///
/// 每个 `@AppStorage` 都是一个独立的偏好观察者, 而这个 App 的键都带点号, SwiftUI 只能
/// 退回到监听整个 UserDefaults 的变更通知: 任何一处写偏好(扫描、补读标签写回时记的
/// 索引标记也算), 屏幕上每张封面的这几个属性都要各自醒来重读一遍, 一屏几十张封面就是
/// 上百次, 都压在写偏好的那一刻。这里只监听一次, 值真变了才通知读过它的视图。
@MainActor
@Observable
final class AnimatedArtworkPreferences {
    static let shared = AnimatedArtworkPreferences()

    private(set) var animatedArtworkEnabled: Bool
    private(set) var animatedArtworkUnmeteredOnly: Bool
    private(set) var motionArtworkServiceEnabled: Bool
    private(set) var motionArtworkServiceEndpoint: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        animatedArtworkEnabled = Self.bool(
            PlayerAppearancePreferences.animatedArtworkEnabledKey,
            default: PlayerAppearancePreferences.animatedArtworkEnabledByDefault,
            in: defaults
        )
        animatedArtworkUnmeteredOnly = Self.bool(
            PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyKey,
            default: PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyByDefault,
            in: defaults
        )
        motionArtworkServiceEnabled = Self.bool(
            PlayerAppearancePreferences.motionArtworkServiceEnabledKey,
            default: PlayerAppearancePreferences.motionArtworkServiceEnabledByDefault,
            in: defaults
        )
        motionArtworkServiceEndpoint = defaults.string(
            forKey: PlayerAppearancePreferences.motionArtworkServiceEndpointKey
        ) ?? PlayerAppearancePreferences.motionArtworkServiceEndpointByDefault
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // 变更通知在写偏好的那条线程上同步送达。
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func refresh() {
        let enabled = Self.bool(
            PlayerAppearancePreferences.animatedArtworkEnabledKey,
            default: PlayerAppearancePreferences.animatedArtworkEnabledByDefault,
            in: defaults
        )
        if animatedArtworkEnabled != enabled { animatedArtworkEnabled = enabled }
        let unmeteredOnly = Self.bool(
            PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyKey,
            default: PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyByDefault,
            in: defaults
        )
        if animatedArtworkUnmeteredOnly != unmeteredOnly { animatedArtworkUnmeteredOnly = unmeteredOnly }
        let serviceEnabled = Self.bool(
            PlayerAppearancePreferences.motionArtworkServiceEnabledKey,
            default: PlayerAppearancePreferences.motionArtworkServiceEnabledByDefault,
            in: defaults
        )
        if motionArtworkServiceEnabled != serviceEnabled { motionArtworkServiceEnabled = serviceEnabled }
        let endpoint = defaults.string(forKey: PlayerAppearancePreferences.motionArtworkServiceEndpointKey)
            ?? PlayerAppearancePreferences.motionArtworkServiceEndpointByDefault
        if motionArtworkServiceEndpoint != endpoint { motionArtworkServiceEndpoint = endpoint }
    }

    private static func bool(_ key: String, default value: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

enum PlayerAppearancePreferences {
    /// 手机播放页转成横屏时直接进入所选的全屏效果，转回竖屏时退出(#191)。默认关：
    /// 横屏另有自己的双栏播放页(封面与控件在左、歌词在右)。
    static let entersFullscreenInLandscapeKey = "primuse.player.entersFullscreenInLandscape"
    static let entersFullscreenInLandscapeByDefault = false
    /// 原生全屏(竖屏)那一面显示大封面而不是歌词(#311)。记住上次的选择，下次进全屏还是这一面。
    static let immersiveShowsArtworkKey = "primuse.player.immersiveShowsArtwork"
    static let immersiveShowsArtworkByDefault = false
    static let animatedArtworkEnabledKey = "primuse.player.animatedArtworkEnabled"
    static let animatedArtworkEnabledByDefault = true
    static let animatedArtworkUnmeteredOnlyKey = "primuse.player.animatedArtworkUnmeteredOnly"
    static let animatedArtworkUnmeteredOnlyByDefault = true
    static let motionArtworkServiceEnabledKey = "primuse.player.motionArtworkServiceEnabled"
    static let motionArtworkServiceEnabledByDefault = false
    static let motionArtworkServiceEndpointKey = "primuse.player.motionArtworkServiceEndpoint"
    static let motionArtworkServiceEndpointByDefault = ""
    static let showsVolumeBarKey = "primuse.player.showsVolumeBar"
    static let showsVolumeBarByDefault = true
    /// 竖屏播放页封面模式在进度条上面显示正在唱的那一句(#69、#318)。
    static let showsArtworkLyricsKey = "primuse.player.showsArtworkLyrics"
    static let showsArtworkLyricsByDefault = false
    /// 封面下的歌词放几行(`NowPlayingArtworkLyricsLines` 的原始值)与字号倍数(`.callout` 为 1)。
    static let artworkLyricsLinesKey = "primuse.player.artworkLyricsLines"
    static let artworkLyricsFontScaleKey = "primuse.player.artworkLyricsFontScale"
    static let artworkLyricsFontScaleByDefault = 1.0
    static let artworkLyricsFontScaleRange: ClosedRange<Double> = 0.8...1.8

    static func artworkLyricsLines(rawValue: String) -> NowPlayingArtworkLyricsLines {
        NowPlayingArtworkLyricsLines(rawValue: rawValue) ?? .one
    }

    static func artworkLyricsFontScale(_ value: Double) -> Double {
        guard value.isFinite else { return artworkLyricsFontScaleByDefault }
        return min(max(value, artworkLyricsFontScaleRange.lowerBound), artworkLyricsFontScaleRange.upperBound)
    }
    /// 播放页底部那行的音频信息档位(`NowPlayingAudioInfoMode` 的原始值)。
    static let audioInfoModeKey = "primuse.player.audioInfoMode"
    /// iPhone 沿用原来只给无损以上标音质的做法;Mac 播放页一直都显示规格,默认始终。
    static var audioInfoModeByDefault: NowPlayingAudioInfoMode {
        #if os(macOS)
        return .always
        #else
        return .nonStandardOnly
        #endif
    }

    static func audioInfoMode(rawValue: String) -> NowPlayingAudioInfoMode {
        .resolved(rawValue: rawValue, fallback: audioInfoModeByDefault)
    }
    static let lyricsAlignmentKey = "primuse.player.lyricsAlignment"
    /// 歌词的字体(`PlayerTextFont` 的原始值,#332):歌词页、封面下的歌词、全屏效果、Mac 桌面歌词与歌词岛
    /// 都用它,译文、注音行也跟着换。随 iCloud 同步,电视也跟着这一份。
    static let lyricsFontKey = "primuse.player.lyricsFont"
    static let lyricsColorModeKey = "primuse.player.lyricsColorMode"
    static let customLyricsColorHexKey = "primuse.player.customLyricsColorHex"
    static let gradientLyricsStartColorHexKey = "primuse.player.gradientLyricsStartColorHex"
    static let gradientLyricsEndColorHexKey = "primuse.player.gradientLyricsEndColorHex"
    static let blursInactiveLyricsKey = "primuse.player.blursInactiveLyrics"
    static let blursInactiveLyricsByDefault = false
    /// 歌词页换句时怎么滚(`PlayerLyricsMotion` 的原始值):整份歌词一起平滑滚动,或一行接一行像弹簧一样落位、
    /// 离当前句越远越淡越虚。随 iCloud 同步。
    static let lyricsMotionKey = "primuse.player.lyricsMotion"
    /// 播放器界面保持常亮。沿用早先「歌词界面常亮」的存储键，老用户开过的直接生效。
    static let keepsScreenAwakeInPlayerKey = "primuse.player.keepsScreenAwakeForLyrics"
    static let keepsScreenAwakeInPlayerByDefault = false
    static let playerScreenWakeRequiresChargingKey = "primuse.player.screenWakeRequiresCharging"
    static let playerScreenWakeRequiresChargingByDefault = false
    static let tapLyricsToSeekKey = "primuse.player.tapLyricsToSeek"
    static let tapLyricsToSeekByDefault = true
    /// 两句歌词之间有长间奏时,在上一句下面显示三个随间奏进度点亮的点(#198 可以关掉)。
    static let showsLyricsInterludeKey = "primuse.player.showsLyricsInterlude"
    static let showsLyricsInterludeByDefault = true
    /// 有声书、播客的文字稿带逐字时间(本机转写的都带)时一个字一个字地亮;关掉后整句高亮,和整句字幕一样(#336/#345)。
    /// 键名不带点号(见 #344 的教训)。
    static let spokenWordTranscriptHighlightsWordsKey = "spokenWordTranscriptHighlightsWords"
    static let spokenWordTranscriptHighlightsWordsByDefault = true
    /// 拖动歌词时显示定位标尺（时间与从该句播放）。
    static let showsLyricsBrowseTimelineKey = "primuse.player.showsLyricsBrowseTimeline"
    static let showsLyricsBrowseTimelineByDefault = false

    /// 播放页控件(进度条、开着的随机与循环、功能块里的强调色)跟主题色,还是单色(#189)。
    static let controlTintKey = "primuse.player.controlTint"

    static func controlTint(rawValue: String) -> NowPlayingControlTint {
        NowPlayingControlTint(rawValue: rawValue) ?? .theme
    }

    /// 播放页进度条的画法(#69):胶囊条、波浪、细线加圆点。
    static let progressStyleKey = "primuse.player.progressStyle"
    /// 进度条播放过的那段外面一圈同色的光晕(#319),三种画法都能叠。播放时亮,暂停时变淡。
    static let progressGlowKey = "primuse.player.progressGlow"
    static let progressGlowByDefault = false
    /// 有声书竖屏专版的进度条也照上面选的画法画(#320)。默认关:那套版式保留自己的细线加圆点,
    /// 只跟着换成波浪(#313)——默认画法是胶囊条,不能悄悄把所有人的书刊版式换掉。
    static let progressStyleAppliesToAudiobooksKey = "primuse.player.progressStyleAudiobooks"
    static let progressStyleAppliesToAudiobooksByDefault = false

    /// 系统是浅色时播放页也用深色(像 Apple Music、播客那样),有声书走墨黑版式(#313)。默认跟随系统。
    static let alwaysDarkKey = "primuse.player.alwaysDark"
    static let alwaysDarkByDefault = false

    static func progressStyle(rawValue: String) -> NowPlayingProgressStyle {
        NowPlayingProgressStyle(rawValue: rawValue) ?? .standard
    }

    /// iPhone 竖屏播放页的大封面:卡片(圆角方图)或铺满(从屏幕顶端铺满整宽、下沿渐隐进背景)。
    /// 音乐、播客、电台各选各的(「播放页样式与按钮」右上角切到那一页);有声书的书封照旧是卡片。
    static let artworkStyleKey = "primuse.player.artworkStyle"
    static let podcastArtworkStyleKey = "primuse.player.artworkStyle.podcast"
    static let radioArtworkStyleKey = "primuse.player.artworkStyle.radio"

    static func artworkStyle(rawValue: String) -> NowPlayingArtworkStyle {
        NowPlayingArtworkStyle(rawValue: rawValue) ?? .card
    }

    /// 播放页播放 / 暂停键与上一首 / 下一首的图标样式(「播放页样式与按钮」里挑)。这两个键是音乐的;
    /// 有声书、播客、电台的播放键各存一份,电台的上一台 / 下一台也单独一份,改一页不牵动别的页。
    /// 有声内容的快退、快进是秒数键,不换样子。
    static let playButtonStyleKey = "primuse.player.playButtonStyle"
    static let skipButtonStyleKey = "primuse.player.skipButtonStyle"
    static let audiobookPlayButtonStyleKey = "primuse.player.playButtonStyle.audiobook"
    static let podcastPlayButtonStyleKey = "primuse.player.playButtonStyle.podcast"
    static let radioPlayButtonStyleKey = "primuse.player.playButtonStyle.radio"
    static let radioSkipButtonStyleKey = "primuse.player.skipButtonStyle.radio"

    static func playButtonStyle(rawValue: String) -> NowPlayingPlayButtonStyle {
        NowPlayingPlayButtonStyle(rawValue: rawValue) ?? .filledCircle
    }

    static func skipButtonStyle(rawValue: String) -> NowPlayingSkipButtonStyle {
        NowPlayingSkipButtonStyle(rawValue: rawValue) ?? .standard
    }

    static let defaultCustomLyricsColorHex = "0A84FF"
    static let defaultGradientLyricsStartColorHex = "FF375F"
    static let defaultGradientLyricsEndColorHex = "AF52DE"

    static func normalizedLyricsColorHex(_ value: String, fallback: String) -> String {
        AppThemePreferences.normalizedHex(value, fallback: fallback)
    }

    static func tapLyricsToSeekIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tapLyricsToSeekKey) as? Bool
            ?? tapLyricsToSeekByDefault
    }
}

extension NowPlayingAudioInfoMode {
    /// 设置里这一档的名字(本地化键)。
    var titleKey: String {
        switch self {
        case .off: "player_audio_info_off"
        case .nonStandardOnly: "player_audio_info_lossless_only"
        case .always: "player_audio_info_always"
        }
    }
}

enum PlayerLyricsColorMode: String, CaseIterable, Identifiable {
    case defaultColor = "default"
    case custom
    case gradient

    static let defaultValue = PlayerLyricsColorMode.defaultColor

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .defaultColor:
            "player_lyrics_color_default"
        case .custom:
            "player_lyrics_color_custom"
        case .gradient:
            "player_lyrics_color_gradient"
        }
    }
}

/// 歌词页换句时的滚动方式。
enum PlayerLyricsMotion: String, CaseIterable, Identifiable {
    /// 整份歌词一起平滑滚到下一句(一直以来的做法)。
    case standard
    /// 一行接一行跟上来、像弹簧一样落位,离当前句越远越淡越虚(`LyricCascadeMotionPolicy`)。
    case cascade

    static let defaultValue = PlayerLyricsMotion.standard

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .standard: "player_lyrics_motion_standard"
        case .cascade: "player_lyrics_motion_cascade"
        }
    }
}

enum PlayerLyricsAlignment: String, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    static let defaultValue = PlayerLyricsAlignment.leading

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .leading:
            "player_lyrics_alignment_left"
        case .center:
            "player_lyrics_alignment_center"
        case .trailing:
            "player_lyrics_alignment_right"
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    func scaleAnchor(in layoutDirection: LayoutDirection) -> UnitPoint {
        let isRightToLeft = layoutDirection == .rightToLeft
        switch self {
        case .leading:
            return UnitPoint(x: isRightToLeft ? 1 : 0, y: 0.5)
        case .center:
            return .center
        case .trailing:
            return UnitPoint(x: isRightToLeft ? 0 : 1, y: 0.5)
        }
    }
}

/// 播放页控件的颜色。单色时深色外观下是白色、浅色外观下是黑色,配「流动色彩」这类花背景不抢色;
/// 只管 iPhone / iPad 播放页,有声书那两套版面保留自己的配色,全局的主题色不受影响。
enum NowPlayingControlTint: String, CaseIterable, Sendable {
    case theme
    case monochrome

    var titleKey: String {
        switch self {
        case .theme: "player_control_tint_theme"
        case .monochrome: "player_control_tint_monochrome"
        }
    }
}

/// 播放页进度条的画法。iPhone / iPad 与 Mac 的播放页用它;全屏效果、卡拉OK、有声书竖版各有自己的样子。
enum NowPlayingProgressStyle: String, CaseIterable, Sendable {
    /// 一直以来的胶囊条。
    case standard
    /// 播放过的那段是一条缓缓流动的波浪,暂停时抚平成直线。
    case wave
    /// 细线,播放头上一个圆点。
    case dot

    var titleKey: String {
        switch self {
        case .standard: "player_progress_style_standard"
        case .wave: "player_progress_style_wave"
        case .dot: "player_progress_style_dot"
        }
    }
}

enum NowPlayingArtworkStyle: String, CaseIterable, Sendable {
    /// 一直以来的圆角方图,带阴影,暂停时缩小一点。
    case card
    /// 从屏幕顶端铺满整宽,直角,下沿渐隐进播放页背景。
    case fullBleed

    var titleKey: String {
        switch self {
        case .card: "player_artwork_style_card"
        case .fullBleed: "player_artwork_style_full_bleed"
        }
    }
}

/// 封面下的歌词放几行。默认一行(#318:进度条上面只放正在唱的那一句);「自动」按歌名与进度条之间
/// 剩下的高度能放几行放几行,关掉音量条、调小字号都会多出几行。
enum NowPlayingArtworkLyricsLines: String, CaseIterable, Sendable {
    case one
    case two
    case three
    case fill

    var titleKey: String {
        switch self {
        case .one: "player_artwork_lyrics_lines_one"
        case .two: "player_artwork_lyrics_lines_two"
        case .three: "player_artwork_lyrics_lines_three"
        case .fill: "player_artwork_lyrics_lines_fill"
        }
    }

    /// 定好的行数;`fill` 由版面按分到的高度算。
    var fixedCount: Int? {
        switch self {
        case .one: 1
        case .two: 2
        case .three: 3
        case .fill: nil
        }
    }
}

/// 播放页播放 / 暂停键的样子。iPhone / iPad 的音乐、有声书、播客、电台播放页(竖屏、手机横屏、iPad 横屏、
/// 原生全屏底部那一排)共用这一个选择(#329);有声书墨黑 / 暖白里选实心圆时仍是设计稿那颗圆。
enum NowPlayingPlayButtonStyle: String, CaseIterable, Sendable {
    /// 一直以来的实心圆,三角在圆里挖空。
    case filledCircle
    /// 只有三角 / 两竖,不带框。
    case plain
    /// 细圆圈里一个三角。
    case outlinedCircle
    /// 实心圆角方块,三角挖空。
    case filledSquare
    /// 不带框,三角 / 两竖撑满整颗键,比「无框」大一圈,上一首 / 下一首跟着放大(#338)。
    case largePlain

    var titleKey: String {
        switch self {
        case .filledCircle: "player_play_style_filled_circle"
        case .plain: "player_play_style_plain"
        case .outlinedCircle: "player_play_style_outlined_circle"
        case .filledSquare: "player_play_style_filled_square"
        case .largePlain: "player_play_style_large_plain"
        }
    }
}

/// 播放页上一首 / 下一首的样子。音乐的这两颗和电台的上一台 / 下一台跟着换;有声内容那两颗是快退 / 快进秒数,不跟着换。
enum NowPlayingSkipButtonStyle: String, CaseIterable, Sendable {
    /// 一直以来的双三角。
    case standard
    /// 双三角放大加粗。
    case bold
    /// 双三角带一道竖线(跳到上一首 / 下一首的老写法)。
    case track
    /// 实心圆里的双三角。
    case filledCircle
    /// 细圆圈里的双三角。
    case outlinedCircle

    var titleKey: String {
        switch self {
        case .standard: "player_skip_style_standard"
        case .bold: "player_skip_style_bold"
        case .track: "player_skip_style_track"
        case .filledCircle: "player_skip_style_filled_circle"
        case .outlinedCircle: "player_skip_style_outlined_circle"
        }
    }

    func symbol(forward: Bool) -> String {
        switch self {
        case .standard, .bold: forward ? "forward.fill" : "backward.fill"
        case .track: forward ? "forward.end.fill" : "backward.end.fill"
        case .filledCircle: forward ? "forward.circle.fill" : "backward.circle.fill"
        case .outlinedCircle: forward ? "forward.circle" : "backward.circle"
        }
    }

    /// 压在自己的玻璃胶囊里时(浮起来的原生全屏底排)用的字形:胶囊已经是框,圆底、圆圈两种换成不带圆的。
    func glyphSymbol(forward: Bool) -> String {
        switch self {
        case .standard, .bold, .filledCircle, .outlinedCircle: forward ? "forward.fill" : "backward.fill"
        case .track: forward ? "forward.end.fill" : "backward.end.fill"
        }
    }
}

enum AppThemeColorMode: String, CaseIterable, Sendable {
    case automatic = "auto"
    case fixed
}

/// 三端共用的主题偏好键与色板。主题色来源与播放背景的封面氛围分别保存：
/// 自动主题色负责控件强调色，封面氛围开关负责播放背景，两者可以独立使用。
enum AppThemePreferences {
    struct Swatch: Identifiable, Equatable, Sendable {
        /// 大写、无 `#` 的 RRGGBB，同时作为稳定存储值。
        let id: String
        let localizationKey: String
    }

    static let accentHexKey = "primuse.theme.fixedColorHex"
    static let colorModeKey = "primuse.theme.colorMode"
    static let coverDrivenAmbientKey = "primuse.theme.coverDrivenAmbient"
    static let ambientStrengthKey = "primuse.theme.ambientStrength"
    static let iOSAppearanceKey = "primuse.appearance"

    /// 「品红」:Primuse 图标的颜色,也是新装默认色。浅色外观用压深一档的 D6176F(白底上
    /// 5:1),深色外观用图标上的 EF1A7F(黑底上 5.1:1,压白字也还有 4.1:1)。存储值是浅色那档。
    static let brandHex = "D6176F"
    static let brandDarkHex = "EF1A7F"

    static let defaultAccentHex = brandHex
    static let defaultColorMode = AppThemeColorMode.automatic
    static let defaultCoverDrivenAmbient = true
    static let defaultAmbientStrength = 0.70

    static let swatches: [Swatch] = [
        Swatch(id: brandHex, localizationKey: "theme_color_magenta"),
        Swatch(id: "147D8A", localizationKey: "theme_color_teal"),
        Swatch(id: "2AAA8A", localizationKey: "theme_color_turquoise"),
        Swatch(id: "1F8A5B", localizationKey: "theme_color_forest"),
        Swatch(id: "0A84FF", localizationKey: "theme_color_blue"),
        Swatch(id: "5E5CE6", localizationKey: "theme_color_indigo"),
        Swatch(id: "AF52DE", localizationKey: "theme_color_purple"),
        Swatch(id: "FF2D55", localizationKey: "theme_color_rose"),
        Swatch(id: "E8453C", localizationKey: "theme_color_red"),
        Swatch(id: "C96442", localizationKey: "theme_color_terracotta"),
        Swatch(id: "FF9500", localizationKey: "theme_color_orange"),
        Swatch(id: "D4A017", localizationKey: "theme_color_amber"),
        Swatch(id: "5E6B87", localizationKey: "theme_color_slate"),
        Swatch(id: monochromeHex, localizationKey: "theme_color_white"),
    ]

    /// 「白色」(#189):深色外观下是纯白,浅色外观下换成近黑,不然按钮、勾选在白底上看不见。
    /// 目前只在 iPhone / iPad 的色板里出现:Mac 与 Apple TV 的品牌色另有一套推导(电视会把
    /// 饱和度抬到 0.28 以上,白色会变成偏红),没验证之前不放。主题色不跨设备同步。
    static let monochromeHex = "FFFFFF"

    static func isMonochrome(_ hex: String) -> Bool {
        normalizedHex(hex) == monochromeHex
    }

    /// Mac 与 Apple TV 色板里列哪些。
    static var swatchesWithoutMonochrome: [Swatch] {
        swatches.filter { !isMonochrome($0.id) }
    }

    /// 存下来的固定主题色变成颜色;「白色」与「品红」随深浅外观换。
    static func themeColor(hex: String) -> Color {
        let normalized = normalizedHex(hex)
        if normalized == brandHex {
            return adaptiveColor(light: Color(hex: brandHex), dark: Color(hex: brandDarkHex))
        }
        guard isMonochrome(normalized) else { return Color(hex: normalized) }
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : UIColor(white: 0.11, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .white
                : NSColor(white: 0.11, alpha: 1)
        })
        #endif
    }

    /// 浅色、深色外观各用一档的颜色。闭包在 SwiftUI 的后台渲染线程上解析,不能带主线程隔离。
    static func adaptiveColor(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        return Color(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
        #else
        let lightColor = NSColor(light)
        let darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #endif
    }

    static func normalizedHex(_ value: String, fallback: String = defaultAccentHex) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        return isValidHex(normalized) ? normalized : fallback
    }

    static func isValidHex(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy(\.isHexDigit)
    }

    static func normalizedAmbientStrength(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func colorMode(in defaults: UserDefaults = .standard) -> AppThemeColorMode {
        if let rawValue = defaults.string(forKey: colorModeKey),
           let mode = AppThemeColorMode(rawValue: rawValue) {
            return mode
        }

        // 兼容短暂使用“固定主题色 + 封面氛围”模型的版本：没有旧模式值时，
        // 用封面氛围偏好推断一次，避免升级后无故改变用户看到的颜色来源。
        if let coverDriven = defaults.object(forKey: coverDrivenAmbientKey) as? Bool {
            return coverDriven ? .automatic : .fixed
        }
        return defaultColorMode
    }
}

struct AmbientLightOverlay: Equatable, Sendable {
    let topOpacity: Double
    let bottomOpacity: Double
}

enum AmbientLightOverlayPolicy {
    static func resolve(
        hasArtworkTheme: Bool,
        usesIncreasedContrast: Bool,
        strength: Double
    ) -> AmbientLightOverlay {
        guard hasArtworkTheme else {
            return usesIncreasedContrast
                ? AmbientLightOverlay(topOpacity: 0.52, bottomOpacity: 0.38)
                : AmbientLightOverlay(topOpacity: 0.38, bottomOpacity: 0.22)
        }

        let value = AppThemePreferences.normalizedAmbientStrength(strength)
        let neutral = usesIncreasedContrast
            ? AmbientLightOverlay(topOpacity: 0.52, bottomOpacity: 0.38)
            : AmbientLightOverlay(topOpacity: 0.38, bottomOpacity: 0.22)
        let defaultAppearance = usesIncreasedContrast
            ? AmbientLightOverlay(topOpacity: 0.34, bottomOpacity: 0.20)
            : AmbientLightOverlay(topOpacity: 0.24, bottomOpacity: 0.10)
        let vivid = usesIncreasedContrast
            ? AmbientLightOverlay(topOpacity: 0.22, bottomOpacity: 0.10)
            : AmbientLightOverlay(topOpacity: 0.10, bottomOpacity: 0.02)
        let defaultStrength = AppThemePreferences.defaultAmbientStrength

        if value <= defaultStrength {
            return interpolate(
                from: neutral,
                to: defaultAppearance,
                progress: value / defaultStrength
            )
        }
        return interpolate(
            from: defaultAppearance,
            to: vivid,
            progress: (value - defaultStrength) / (1 - defaultStrength)
        )
    }

    private static func interpolate(
        from start: AmbientLightOverlay,
        to end: AmbientLightOverlay,
        progress: Double
    ) -> AmbientLightOverlay {
        let value = min(max(progress, 0), 1)
        return AmbientLightOverlay(
            topOpacity: start.topOpacity + (end.topOpacity - start.topOpacity) * value,
            bottomOpacity: start.bottomOpacity + (end.bottomOpacity - start.bottomOpacity) * value
        )
    }
}

/// 用户可选择的沉浸画面。名称描述效果机制，不再暴露设计稿编号。
enum ImmersiveEffectScene: Sendable {
    case coverGallery
    case vinylDeck
    case flowingLines
    case auroraVeil
    case radialPulse
    case spectrumHorizon
    case particleBloom
    case albumFlow
    case chladniPlate
    case fireflySync
    case flyBrain
    case kineticLyrics
}

/// 保留控制层语义，便于三端共用同一套容器。
enum ImmersiveEffectChromeFamily: Sendable {
    case standard
    case deck
    case lyrics
    case spectrum
    case showcase
}

enum ImmersiveLyricsOverlayKind: Sendable {
    case none
    case singleLine
    case stage
}

enum FullscreenEffectCollection: Int, CaseIterable, Identifiable, Sendable {
    case native
    case coverReactive
    case sceneMotion
    case audioReactive

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .native:
            PMString("fullscreen_effect_collection_native")
        case .coverReactive:
            PMString("fullscreen_effect_collection_cover_reactive")
        case .sceneMotion:
            PMString("fullscreen_effect_collection_scene_motion")
        case .audioReactive:
            PMString("fullscreen_effect_collection_audio_reactive")
        }
    }

    var effects: [FullscreenPlayerEffect] {
        FullscreenPlayerEffect.allCases.filter { $0.collection == self }
    }
}

/// 三端共享的全屏效果目录。原生播放器保持默认，其余每项对应一种实际渲染机制。
/// 新增效果追加在末尾，保证 macOS 数字快捷键与既有顺序一致。
enum FullscreenPlayerEffect: CaseIterable, Identifiable, Sendable {
    case native
    case coverGallery
    case flowingLines
    case radialPulse
    case vinylDeck
    case auroraVeil
    case spectrumHorizon
    case particleBloom
    /// 封面流(#191): 正在播的这首居中, 播放队列里前后的歌斜着排在两边, 下面是倒影;
    /// 电视上和中间同一张专辑的那几张换成曲库里别的专辑封面。
    /// 存储值不用 "coverFlow" —— 那是旧版封面墙留下的别名, 升级用户存的就是它。
    case albumFlow
    /// 克拉尼沙画：振动金属板上的细沙随频谱重心与响度排出不同的节线花纹。
    case chladniPlate
    /// 萤火同步：草地上的萤火虫各闪各的，节拍越稳越会慢慢对上，最后整片一齐闪。
    case fireflySync
    /// 神经共鸣：真实果蝇大脑听觉通路的全息投影，声音沿真实接线一级级点亮。
    case flyBrain
    /// 动态歌词：一次一句压在画面正中，字一个个弹上来、唱到就亮起，上一句往上飘走。只用专辑色，不读频谱。
    case kineticLyrics

    static let storageKey = "primuse.fullscreenPlayerEffect"
    static let defaultValue = FullscreenPlayerEffect.native
    static let immersiveCases = allCases.filter { !$0.isNative }

    var id: String { rawValue }
    var isNative: Bool { self == .native }

    var rawValue: String {
        switch self {
        case .native: "native"
        case .coverGallery: "coverGallery"
        case .flowingLines: "flowingLines"
        case .radialPulse: "radialPulse"
        case .vinylDeck: "vinylDeck"
        case .auroraVeil: "auroraVeil"
        case .spectrumHorizon: "spectrumHorizon"
        case .particleBloom: "particleBloom"
        case .albumFlow: "albumFlow"
        case .chladniPlate: "chladniPlate"
        case .fireflySync: "fireflySync"
        case .flyBrain: "flyBrain"
        case .kineticLyrics: "kineticLyrics"
        }
    }

    /// 把旧实现的存储值迁移到最接近的新效果类型，避免升级后选项失效。
    init?(rawValue: String) {
        switch rawValue {
        case "native":
            self = .native
        case "coverGallery", "coverWall",
             "coverFlow", "cover", "deepField", "ambientBloom", "amberDust", "jadeMoss",
             "sectionIndigo", "duotone", "daylight", "ambientRefined", "editorial", "coverDriven":
            self = .coverGallery
        case "flowingLines", "contour",
             "kineticTitle", "typography", "typeWall", "lyricStage", "lyrics":
            self = .flowingLines
        case "lightRhythm", "lightField", "liquidChrome", "starryNight", "starField":
            self = .auroraVeil
        case "radialPulse", "radialSpectrum":
            self = .radialPulse
        case "liveWaveform", "spectrum", "visualizer", "mirrorStage":
            self = .spectrumHorizon
        case "vinylDeck", "vinyl":
            self = .vinylDeck
        case "auroraVeil", "auroraDrift":
            self = .auroraVeil
        case "spectrumHorizon":
            self = .spectrumHorizon
        case "particleBloom":
            self = .particleBloom
        case "albumFlow":
            self = .albumFlow
        case "chladniPlate":
            self = .chladniPlate
        case "fireflySync":
            self = .fireflySync
        case "flyBrain":
            self = .flyBrain
        case "kineticLyrics":
            self = .kineticLyrics
        default:
            return nil
        }
    }

    var collection: FullscreenEffectCollection {
        switch self {
        case .native: .native
        case .coverGallery, .vinylDeck, .albumFlow: .coverReactive
        case .flowingLines, .auroraVeil, .kineticLyrics: .sceneMotion
        case .radialPulse, .spectrumHorizon, .particleBloom, .chladniPlate, .fireflySync, .flyBrain: .audioReactive
        }
    }

    var scene: ImmersiveEffectScene {
        switch self {
        case .native, .coverGallery: .coverGallery
        case .flowingLines: .flowingLines
        case .radialPulse: .radialPulse
        case .vinylDeck: .vinylDeck
        case .auroraVeil: .auroraVeil
        case .spectrumHorizon: .spectrumHorizon
        case .particleBloom: .particleBloom
        case .albumFlow: .albumFlow
        case .chladniPlate: .chladniPlate
        case .fireflySync: .fireflySync
        case .flyBrain: .flyBrain
        case .kineticLyrics: .kineticLyrics
        }
    }

    /// 所有沉浸画面共用同一套浮动按钮外观，避免同级操作有无底色不一致。
    var chromeFamily: ImmersiveEffectChromeFamily { .showcase }
    var lyricsOverlay: ImmersiveLyricsOverlayKind { .none }
    var displaysLyrics: Bool { !isNative }
    var prefersLightContent: Bool { false }
    var usesRealtimeSpectrum: Bool {
        switch self {
        case .radialPulse, .spectrumHorizon, .particleBloom, .chladniPlate, .fireflySync, .flyBrain: true
        default: false
        }
    }
    var usesShowcaseChrome: Bool { !isNative }

    func advanced(by offset: Int) -> FullscreenPlayerEffect {
        let values = Self.immersiveCases
        guard !values.isEmpty else { return self }
        let index = values.firstIndex(of: self) ?? 0
        let wrapped = (index + offset % values.count + values.count) % values.count
        return values[wrapped]
    }

    private var localizationStem: String {
        switch self {
        case .native: "native"
        case .coverGallery: "cover_gallery"
        case .flowingLines: "flowing_lines"
        case .radialPulse: "radial_pulse"
        case .vinylDeck: "vinyl_deck"
        case .auroraVeil: "aurora_veil"
        case .spectrumHorizon: "spectrum_horizon"
        case .particleBloom: "particle_bloom"
        case .albumFlow: "cover_flow"
        case .chladniPlate: "chladni_plate"
        case .fireflySync: "firefly_sync"
        case .flyBrain: "fly_brain"
        case .kineticLyrics: "kinetic_lyrics"
        }
    }

    private var titleLocalizationKey: String { "fullscreen_effect_\(localizationStem)" }
    private var subtitleLocalizationKey: String { "\(titleLocalizationKey)_subtitle" }
    private var motionLocalizationKey: String { "\(titleLocalizationKey)_motion" }

    var localizedTitle: String {
        PMString(titleLocalizationKey)
    }

    var localizedSubtitle: String {
        PMString(subtitleLocalizationKey)
    }

    var motionDescription: String {
        PMString(motionLocalizationKey)
    }

    var symbolName: String {
        switch self {
        case .native: "rectangle.inset.filled"
        case .coverGallery: "square.grid.3x3.fill"
        case .flowingLines: "scribble.variable"
        case .radialPulse: "waveform.circle.fill"
        case .vinylDeck: "opticaldisc.fill"
        case .auroraVeil: "moon.stars.fill"
        case .spectrumHorizon: "chart.bar.xaxis"
        case .particleBloom: "aqi.medium"
        case .albumFlow: "rectangle.stack.fill"
        case .chladniPlate: "squareshape.split.3x3"
        case .fireflySync: "sparkles"
        case .flyBrain: "brain"
        case .kineticLyrics: "textformat.size"
        }
    }
}

extension FullscreenPlayerEffect {
    /// 自动轮换(#312)在哪几种里挑:原生播放页不算;只换声音响应的时候就是那一类。
    static func rotationPool(_ scope: ImmersiveEffectRotationScope) -> [FullscreenPlayerEffect] {
        switch scope {
        case .all: immersiveCases
        case .audioReactive: immersiveCases.filter { $0.collection == .audioReactive }
        }
    }
}

extension ImmersiveEffectRotationMode {
    var localizedTitle: String {
        switch self {
        case .off: String(localized: "immersive_effect_rotation_off")
        case .perSong: String(localized: "immersive_effect_rotation_per_song")
        case .minutes1: String(localized: "immersive_effect_rotation_minutes_1")
        case .minutes2: String(localized: "immersive_effect_rotation_minutes_2")
        case .minutes5: String(localized: "immersive_effect_rotation_minutes_5")
        case .minutes10: String(localized: "immersive_effect_rotation_minutes_10")
        }
    }
}

extension ImmersiveEffectRotationScope {
    var localizedTitle: String {
        switch self {
        case .audioReactive: FullscreenEffectCollection.audioReactive.title
        case .all: String(localized: "immersive_effect_rotation_scope_all")
        }
    }
}

/// 全屏页什么时候数着时间准备换下一种:定时档、正在播、页面在前台、没在省电休憩、效果抽屉没开着。
/// 眼前的效果也算在里面,换上一种就从头再数。
struct ImmersiveEffectRotationSchedule: Hashable {
    let mode: ImmersiveEffectRotationMode
    let displayedEffect: String
    let isRunning: Bool

    var interval: TimeInterval? { isRunning ? mode.interval : nil }
}

/// 全屏效果眼前换上的那一种,和换场时那一下柔焦;iPhone / iPad、Mac、Apple TV 的全屏页共用,自动轮换(#312)的
/// 计时由各页按 `ImmersiveEffectRotationSchedule` 自己做。轮换换上来的只在这一次全屏里有效:不写回所选效果(那是
/// 三端同步的设置),手动换了效果、或者别的设备改了所选效果,就回到所选的那一种。
///
/// 换场(轮换和手动换都一样):旧画面略微放大、虚化、压暗着退下,换成新的一种以后再从虚化里落定。舞台里有实时模糊和
/// Canvas,两套场景叠着交叉淡化太重,所以同一时刻只画一种。换歌时整幅从轻微虚化里落定一下(封面流、动态歌词
/// 自己有换歌的动画,不做)。
@MainActor
@Observable
final class ImmersiveEffectRotator {
    /// 轮换换上来的效果;nil 时显示用户选定的那一种。
    private(set) var rotatedEffect: FullscreenPlayerEffect?
    /// 手动换场时,虚化到底之前先留着的旧效果。
    private(set) var heldEffect: FullscreenPlayerEffect?
    /// 柔焦的深浅:0 清楚,1 虚化、压暗到底。
    private(set) var softFocus: Double = 0
    /// 柔焦时整幅的缩放:退下时放大一点,新的一种从略大落回原样。不缩到 1 以下,画面边上不会露出底色。
    private(set) var focusScale: Double = 1
    @ObservationIgnored private var queue = ImmersiveEffectRotationQueue()
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    private static let outDuration: TimeInterval = 0.42
    private static let inDuration: TimeInterval = 0.58
    private static let outScale = 1.06
    private static let inScale = 1.035
    /// 换歌时从多深的虚化里落定、用多久。
    private static let songSettleFocus = 0.5
    private static let songSettleDuration: TimeInterval = 0.65

    /// 舞台上正画着的那一种:手动换场虚化到底之前还是旧的。
    func displayedEffect(selected: FullscreenPlayerEffect) -> FullscreenPlayerEffect {
        heldEffect ?? rotatedEffect ?? selected
    }

    /// 选择器里该高亮的那一种:轮换换上来的,或者刚选的(哪怕舞台还在换场)。
    func highlightedEffect(selected: FullscreenPlayerEffect) -> FullscreenPlayerEffect {
        rotatedEffect ?? selected
    }

    /// 回到所选的那一种。手动换场做到一半时只丢掉轮换结果,换场照常做完;否则换场停下、画面变清楚。
    func reset() {
        rotatedEffect = nil
        guard heldEffect == nil else { return }
        transitionTask?.cancel()
        transitionTask = nil
        settleImmediately(animated: true)
    }

    /// 手动换效果(抽屉、捏合、选择器、快捷键)时调用,紧接着再写入所选效果:旧画面先柔焦着退下,换成新选的再
    /// 从虚化里落定。换场途中又选了一次,就接着退下、最后换到最新选的那一种。减弱动态效果时直接换。
    func beginManualChange(from current: FullscreenPlayerEffect, reduceMotion: Bool) {
        rotatedEffect = nil
        guard !reduceMotion else {
            transitionTask?.cancel()
            transitionTask = nil
            heldEffect = nil
            settleImmediately(animated: false)
            return
        }
        if heldEffect == nil { heldEffect = current }
        runTransition { [weak self] in
            self?.heldEffect = nil
        }
    }

    /// 换到候选里的下一种。减弱动态效果时直接换,不做柔焦。
    func advance(selected: FullscreenPlayerEffect, scope: ImmersiveEffectRotationScope, reduceMotion: Bool) {
        let current = displayedEffect(selected: selected)
        let pool = FullscreenPlayerEffect.rotationPool(scope).map(\.rawValue)
        guard let raw = queue.next(after: current.rawValue, pool: pool),
              let next = FullscreenPlayerEffect(rawValue: raw) else { return }
        let target: FullscreenPlayerEffect? = next == selected ? nil : next
        guard !reduceMotion else {
            transitionTask?.cancel()
            transitionTask = nil
            heldEffect = nil
            settleImmediately(animated: false)
            rotatedEffect = target
            return
        }
        runTransition { [weak self] in
            self?.heldEffect = nil
            self?.rotatedEffect = target
        }
    }

    /// 换歌了:整幅从轻微虚化里落定一下。正在换场、减弱动态效果、省电休憩时不做;封面流、动态歌词自己有换歌的动画。
    func settleAfterSongChange(on effect: FullscreenPlayerEffect, isEnabled: Bool) {
        guard isEnabled, transitionTask == nil, effect != .albumFlow, effect != .kineticLyrics else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            softFocus = Self.songSettleFocus
            focusScale = 1 + (Self.inScale - 1) * Self.songSettleFocus
        }
        withAnimation(.easeOut(duration: Self.songSettleDuration)) {
            softFocus = 0
            focusScale = 1
        }
    }

    /// 退下 → 换上 → 落定。`swap` 在虚化到底、画面最暗的那一刻无动画地换场景。
    private func runTransition(swap: @escaping @MainActor @Sendable () -> Void) {
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: Self.outDuration)) {
                self.softFocus = 1
                self.focusScale = Self.outScale
            }
            try? await Task.sleep(for: .seconds(Self.outDuration))
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                swap()
                self.focusScale = Self.inScale
            }
            // 留一帧给新场景建好再落定,不让上一种的最后一帧闪回来。
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.inDuration)) {
                self.softFocus = 0
                self.focusScale = 1
            }
            self.transitionTask = nil
        }
    }

    private func settleImmediately(animated: Bool) {
        guard softFocus > 0 || focusScale != 1 else { return }
        if animated {
            withAnimation(.easeOut(duration: Self.inDuration)) {
                softFocus = 0
                focusScale = 1
            }
        } else {
            softFocus = 0
            focusScale = 1
        }
    }
}

/// 换场柔焦落在舞台上的样子:缩放、虚化、压暗。三端全屏页都挂在舞台外面,控件不受影响。
/// 清楚的时候三样都是原样,舞台不会多走一遍模糊。
struct ImmersiveSoftFocusEffect: ViewModifier {
    let softFocus: Double
    let scale: Double
    /// 虚化到底时的模糊半径(点)。
    let maximumBlur: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .blur(radius: maximumBlur * CGFloat(softFocus))
            .overlay {
                Color.black
                    .opacity(0.55 * softFocus)
                    .allowsHitTesting(false)
            }
    }
}

enum ImmersiveLyricsMotionSettings {
    static let storageKey = "primuse.immersiveLyricsMotionEnabled"
    static let defaultValue = true
}

extension ImmersiveFrameRateMode {
    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    /// 换到 60 帧或跟随屏幕之前那段说明：各端耗的东西不一样，电视没有电池。
    static var highRefreshExplanation: String {
        #if os(tvOS)
        String(localized: "immersive_high_refresh_message_tv")
        #elseif os(macOS)
        String(localized: "immersive_high_refresh_message_mac")
        #else
        String(localized: "immersive_high_refresh_message_ios")
        #endif
    }
}

extension ImmersiveMotionIntensity {
    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey))
    }
}

/// 低电量模式与发热状态，全屏页和设置页共用一份。两个通知都可能在后台线程上发出：
/// 观察者挂 `queue: nil` 再回主线程改，不让发通知的线程去等主线程。
@MainActor
@Observable
final class ImmersiveDeviceConditions {
    static let shared = ImmersiveDeviceConditions()

    private(set) var constraint: ImmersiveDeviceConstraint?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in ImmersiveDeviceConditions.shared.refresh() }
            })
        }
    }

    func refresh() {
        let info = ProcessInfo.processInfo
        let thermalIsSerious = info.thermalState == .serious || info.thermalState == .critical
        #if os(tvOS)
        // Apple TV 没有低电量模式。
        let lowPowerModeEnabled = false
        #else
        let lowPowerModeEnabled = info.isLowPowerModeEnabled
        #endif
        let next = ImmersiveDeviceConstraint.current(
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalStateIsSerious: thermalIsSerious
        )
        if next != constraint { constraint = next }
    }

    /// 选的档位经当前设备状态封顶之后，全屏页实际用的那一组。
    func budget(
        frameRate: ImmersiveFrameRateMode,
        intensity: ImmersiveMotionIntensity
    ) -> ImmersiveRenderBudget {
        ImmersiveRenderBudget(selectedFrameRate: frameRate, selectedIntensity: intensity, constraint: constraint)
    }
}

extension ImmersiveRenderBudget {
    /// 临时降档的说明：第一行写原因，第二行写降到了哪一档；没降档时为 nil。
    var noticeItem: ImmersiveStageNoticeItem? {
        guard let constraint else { return nil }
        let title: String
        let symbol: String
        switch constraint {
        case .lowPowerMode:
            title = String(localized: "immersive_power_reason_low_power")
            symbol = "battery.25percent"
        case .thermal:
            title = String(localized: "immersive_power_reason_thermal")
            symbol = "thermometer.high"
        }
        let detail: String
        switch (lowersFrameRate, lowersIntensity) {
        case (true, true): detail = String(localized: "immersive_power_lowered_both")
        case (true, false): detail = String(localized: "immersive_power_lowered_frame_rate")
        default: detail = String(localized: "immersive_power_lowered_intensity")
        }
        return ImmersiveStageNoticeItem(
            id: "power.\(constraint.rawValue).\(lowersFrameRate).\(lowersIntensity)",
            symbol: symbol,
            title: title,
            detail: detail
        )
    }
}

extension ImmersiveStageNoticeItem {
    /// 这首歌拿不到声音数据，跟着声音动的效果停在原地。
    static var spectrumUnavailable: ImmersiveStageNoticeItem {
        ImmersiveStageNoticeItem(
            id: "spectrum.unavailable",
            symbol: "waveform.slash",
            title: String(localized: "immersive_spectrum_unavailable_title"),
            detail: String(localized: "immersive_spectrum_unavailable_detail")
        )
    }
}

/// 「跟随屏幕」档按屏幕最高刷新率发布频谱，免得在 60 Hz 屏上空算一倍。
@MainActor
enum ImmersiveDisplayRefresh {
    static var maximumFramesPerSecond: Int {
        #if os(macOS)
        return NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        #else
        let maximum = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }
            .max() ?? 60
        #if os(iOS)
        // iPhone 没在 Info.plist 声明 CADisableMinimumFrameDurationOnPhone 时，
        // 应用里的动画最高只到 60 帧，ProMotion 屏报 120 也画不到。
        if UIDevice.current.userInterfaceIdiom == .phone,
           Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool != true {
            return min(maximum, 60)
        }
        #endif
        return maximum
        #endif
    }
}

/// 只同步所选全屏呈现方式，不同步各端的动画强度、控件显隐或版式状态。
/// (音乐播放页上几个位置放哪些按钮是另一件事，由 `InterfaceLayoutSync` 同步。)
/// 走 `CloudKVSSync` 那套带修订号的键: 同步开关、初次下载、换账号都由它统一
/// 处理。以前这里自带一份同步逻辑, 绕过了总开关, 新装设备还会把默认值推上云端。
@MainActor
final class FullscreenPlayerEffectSync {
    static let shared = FullscreenPlayerEffectSync()
    static let didChangeNotification = Notification.Name("primuse.fullscreenEffect.didChange")

    private let defaults = UserDefaults.standard
    private var isInstalled = false

    private init() {}

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        normalizeLocalValue()
        CloudKVSSync.shared.register(key: FullscreenPlayerEffect.storageKey) { [weak self] in
            guard let self else { return }
            self.normalizeLocalValue()
            let raw = self.defaults.string(forKey: FullscreenPlayerEffect.storageKey)
                ?? FullscreenPlayerEffect.defaultValue.rawValue
            NotificationCenter.default.post(name: Self.didChangeNotification, object: raw)
        }
    }

    func select(_ effect: FullscreenPlayerEffect) {
        install()
        defaults.set(effect.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        CloudKVSSync.shared.markChanged(key: FullscreenPlayerEffect.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: effect.rawValue)
    }

    private func normalizeLocalValue() {
        let stored = defaults.string(forKey: FullscreenPlayerEffect.storageKey) ?? ""
        guard let effect = FullscreenPlayerEffect(rawValue: stored) else {
            defaults.set(FullscreenPlayerEffect.defaultValue.rawValue, forKey: FullscreenPlayerEffect.storageKey)
            return
        }
        if stored != effect.rawValue {
            defaults.set(effect.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        }
    }
}

extension FullscreenPlayerEffect {
    /// 外接屏选「全屏效果」时用哪一种:单独选过就用选的;没选过跟着播放页的全屏效果,
    /// 那边是「原生」时(外接屏上没有原生全屏那一页)用流动封面墙。
    static func externalDisplayEffect(
        storedValue: String,
        playerEffectValue: String
    ) -> FullscreenPlayerEffect {
        if let chosen = FullscreenPlayerEffect(rawValue: storedValue), !chosen.isNative {
            return chosen
        }
        if let following = FullscreenPlayerEffect(rawValue: playerEffectValue), !following.isNative {
            return following
        }
        return .coverGallery
    }
}
