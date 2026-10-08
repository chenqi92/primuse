import Foundation
import PrimuseKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PlayerAppearancePreferences {
    /// 手机播放页转成横屏时直接进入所选的全屏效果，转回竖屏时退出(#191)。默认关：
    /// 横屏另有自己的双栏播放页(封面与控件在左、歌词在右)。
    static let entersFullscreenInLandscapeKey = "primuse.player.entersFullscreenInLandscape"
    static let entersFullscreenInLandscapeByDefault = false
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
    static let lyricsColorModeKey = "primuse.player.lyricsColorMode"
    static let customLyricsColorHexKey = "primuse.player.customLyricsColorHex"
    static let gradientLyricsStartColorHexKey = "primuse.player.gradientLyricsStartColorHex"
    static let gradientLyricsEndColorHexKey = "primuse.player.gradientLyricsEndColorHex"
    static let blursInactiveLyricsKey = "primuse.player.blursInactiveLyrics"
    static let blursInactiveLyricsByDefault = false
    /// 播放器界面保持常亮。沿用早先「歌词界面常亮」的存储键，老用户开过的直接生效。
    static let keepsScreenAwakeInPlayerKey = "primuse.player.keepsScreenAwakeForLyrics"
    static let keepsScreenAwakeInPlayerByDefault = false
    static let playerScreenWakeRequiresChargingKey = "primuse.player.screenWakeRequiresCharging"
    static let playerScreenWakeRequiresChargingByDefault = false
    static let tapLyricsToSeekKey = "primuse.player.tapLyricsToSeek"
    static let tapLyricsToSeekByDefault = true
    /// 拖动歌词时显示定位标尺（时间与从该句播放）。
    static let showsLyricsBrowseTimelineKey = "primuse.player.showsLyricsBrowseTimeline"
    static let showsLyricsBrowseTimelineByDefault = false

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

    static let defaultAccentHex = "C96442"
    static let defaultColorMode = AppThemeColorMode.automatic
    static let defaultCoverDrivenAmbient = true
    static let defaultAmbientStrength = 0.70

    static let swatches: [Swatch] = [
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
    ]

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

/// 用户可选择的八类沉浸画面。名称描述效果机制，不再暴露设计稿编号。
enum ImmersiveEffectScene: Sendable {
    case coverGallery
    case vinylDeck
    case flowingLines
    case auroraVeil
    case radialPulse
    case spectrumHorizon
    case particleBloom
    case albumFlow
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

/// 三端共享的全屏效果目录。原生播放器保持默认，其余八项对应八种实际渲染机制。
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
    /// 封面流(#191): 当前专辑居中, 资料库里前后的专辑斜着排在两边, 下面是倒影。
    /// 存储值不用 "coverFlow" —— 那是旧版封面墙留下的别名, 升级用户存的就是它。
    case albumFlow

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
        default:
            return nil
        }
    }

    var collection: FullscreenEffectCollection {
        switch self {
        case .native: .native
        case .coverGallery, .vinylDeck, .albumFlow: .coverReactive
        case .flowingLines, .auroraVeil: .sceneMotion
        case .radialPulse, .spectrumHorizon, .particleBloom: .audioReactive
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
        }
    }

    /// 所有沉浸画面共用同一套浮动按钮外观，避免同级操作有无底色不一致。
    var chromeFamily: ImmersiveEffectChromeFamily { .showcase }
    var lyricsOverlay: ImmersiveLyricsOverlayKind { .none }
    var displaysLyrics: Bool { !isNative }
    var prefersLightContent: Bool { false }
    var usesRealtimeSpectrum: Bool {
        switch self {
        case .radialPulse, .spectrumHorizon, .particleBloom: true
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
