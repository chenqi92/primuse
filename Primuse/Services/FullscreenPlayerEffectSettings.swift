import Foundation
import PrimuseKit
import SwiftUI

enum PlayerAppearancePreferences {
    static let animatedArtworkEnabledKey = "primuse.player.animatedArtworkEnabled"
    static let animatedArtworkEnabledByDefault = true
    static let animatedArtworkUnmeteredOnlyKey = "primuse.player.animatedArtworkUnmeteredOnly"
    static let animatedArtworkUnmeteredOnlyByDefault = true
    static let showsVolumeBarKey = "primuse.player.showsVolumeBar"
    static let showsVolumeBarByDefault = true
    static let lyricsAlignmentKey = "primuse.player.lyricsAlignment"
    static let lyricsColorModeKey = "primuse.player.lyricsColorMode"
    static let customLyricsColorHexKey = "primuse.player.customLyricsColorHex"
    static let gradientLyricsStartColorHexKey = "primuse.player.gradientLyricsStartColorHex"
    static let gradientLyricsEndColorHexKey = "primuse.player.gradientLyricsEndColorHex"
    static let blursInactiveLyricsKey = "primuse.player.blursInactiveLyrics"
    static let blursInactiveLyricsByDefault = false

    static let defaultCustomLyricsColorHex = "0A84FF"
    static let defaultGradientLyricsStartColorHex = "FF375F"
    static let defaultGradientLyricsEndColorHex = "AF52DE"

    static func normalizedLyricsColorHex(_ value: String, fallback: String) -> String {
        AppThemePreferences.normalizedHex(value, fallback: fallback)
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

/// 用户可选择的八类沉浸画面。名称描述效果机制，不再暴露设计稿编号。
enum ImmersiveEffectScene: Sendable {
    case coverFlow
    case coverGallery
    case starryNight
    case flowingLines
    case lightRhythm
    case kineticTitle
    case radialPulse
    case liveWaveform
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
enum FullscreenPlayerEffect: CaseIterable, Identifiable, Sendable {
    case native
    case coverFlow
    case coverGallery
    case starryNight
    case flowingLines
    case lightRhythm
    case kineticTitle
    case radialPulse
    case liveWaveform

    static let storageKey = "primuse.fullscreenPlayerEffect"
    static let defaultValue = FullscreenPlayerEffect.native
    static let immersiveCases = allCases.filter { !$0.isNative }

    var id: String { rawValue }
    var isNative: Bool { self == .native }

    var rawValue: String {
        switch self {
        case .native: "native"
        case .coverFlow: "coverFlow"
        case .coverGallery: "coverGallery"
        case .starryNight: "starryNight"
        case .flowingLines: "flowingLines"
        case .lightRhythm: "lightRhythm"
        case .kineticTitle: "kineticTitle"
        case .radialPulse: "radialPulse"
        case .liveWaveform: "liveWaveform"
        }
    }

    /// 把旧实现的存储值迁移到最接近的新效果类型，避免升级后选项失效。
    init?(rawValue: String) {
        switch rawValue {
        case "native":
            self = .native
        case "coverFlow", "cover", "deepField", "ambientBloom", "amberDust", "jadeMoss",
             "sectionIndigo", "duotone", "daylight", "ambientRefined", "editorial", "coverDriven":
            self = .coverFlow
        case "coverGallery", "coverWall":
            self = .coverGallery
        case "starryNight", "starField":
            self = .starryNight
        case "flowingLines", "contour":
            self = .flowingLines
        case "lightRhythm", "lightField", "auroraDrift", "liquidChrome":
            self = .lightRhythm
        case "kineticTitle", "typography", "typeWall", "lyricStage", "lyrics":
            self = .kineticTitle
        case "radialPulse", "radialSpectrum", "vinyl":
            self = .radialPulse
        case "liveWaveform", "spectrum", "visualizer":
            self = .liveWaveform
        default:
            return nil
        }
    }

    var collection: FullscreenEffectCollection {
        switch self {
        case .native: .native
        case .coverFlow, .coverGallery: .coverReactive
        case .starryNight, .flowingLines, .lightRhythm, .kineticTitle: .sceneMotion
        case .radialPulse, .liveWaveform: .audioReactive
        }
    }

    var scene: ImmersiveEffectScene {
        switch self {
        case .native, .coverFlow: .coverFlow
        case .coverGallery: .coverGallery
        case .starryNight: .starryNight
        case .flowingLines: .flowingLines
        case .lightRhythm: .lightRhythm
        case .kineticTitle: .kineticTitle
        case .radialPulse: .radialPulse
        case .liveWaveform: .liveWaveform
        }
    }

    /// 新的八类画面共用同一套浮动按钮外观，避免同级操作有无底色不一致。
    var chromeFamily: ImmersiveEffectChromeFamily { .showcase }
    var lyricsOverlay: ImmersiveLyricsOverlayKind { .none }
    var prefersLightContent: Bool { false }
    var usesRealtimeSpectrum: Bool { self == .radialPulse || self == .liveWaveform }
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
        case .coverFlow: "cover_flow"
        case .coverGallery: "cover_gallery"
        case .starryNight: "starry_night"
        case .flowingLines: "flowing_lines"
        case .lightRhythm: "light_rhythm"
        case .kineticTitle: "kinetic_title"
        case .radialPulse: "radial_pulse"
        case .liveWaveform: "live_waveform"
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
        case .coverFlow: "paintpalette.fill"
        case .coverGallery: "square.grid.3x3.fill"
        case .starryNight: "sparkles"
        case .flowingLines: "scribble.variable"
        case .lightRhythm: "lightspectrum.horizontal"
        case .kineticTitle: "textformat.size"
        case .radialPulse: "waveform.circle.fill"
        case .liveWaveform: "waveform"
        }
    }
}

enum ImmersiveLyricsMotionSettings {
    static let storageKey = "primuse.immersiveLyricsMotionEnabled"
    static let defaultValue = true
}

/// 只同步所选全屏呈现方式，不同步各端的动画强度、控件显隐或版式状态。
/// 使用带版本号的 KVS 项解决多设备同时修改时的覆盖顺序。
@MainActor
final class FullscreenPlayerEffectSync {
    static let shared = FullscreenPlayerEffectSync()
    static let didChangeNotification = Notification.Name("primuse.fullscreenEffect.didChange")

    private let defaults = UserDefaults.standard
    private let timestampKey = "\(FullscreenPlayerEffect.storageKey).__updatedAt"
    private let writerKey = "\(FullscreenPlayerEffect.storageKey).__writerID"
    private let localWriterKey = "primuse.fullscreenEffect.writerID"
    private var kvs: NSUbiquitousKeyValueStore?
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?
    private var isInstalled = false

    private init() {}

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        normalizeLocalValue()
        guard CloudKitRuntime.canCreateContainer else { return }

        let store = NSUbiquitousKeyValueStore.default
        kvs = store
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            Task { @MainActor in
                self?.applyRemoteChange(changedKeys: changed)
            }
        }
        store.synchronize()

        if store.string(forKey: FullscreenPlayerEffect.storageKey) == nil {
            pushCurrentValue()
        } else {
            pullRemoteIfNewer()
        }
    }

    func select(_ effect: FullscreenPlayerEffect) {
        install()
        defaults.set(effect.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        pushCurrentValue()
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

    private var localWriterID: String {
        if let existing = defaults.string(forKey: localWriterKey), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: localWriterKey)
        return value
    }

    private func pushCurrentValue() {
        guard let kvs else { return }
        let revision = max(
            Date().timeIntervalSince1970,
            max(defaults.double(forKey: timestampKey), kvs.double(forKey: timestampKey))
        ) + 1
        let writer = localWriterID
        let raw = defaults.string(forKey: FullscreenPlayerEffect.storageKey)
            ?? FullscreenPlayerEffect.defaultValue.rawValue

        defaults.set(revision, forKey: timestampKey)
        defaults.set(writer, forKey: writerKey)
        kvs.set(raw, forKey: FullscreenPlayerEffect.storageKey)
        kvs.set(revision, forKey: timestampKey)
        kvs.set(writer, forKey: writerKey)
        kvs.synchronize()
    }

    private func applyRemoteChange(changedKeys: [String]) {
        guard changedKeys.isEmpty
                || changedKeys.contains(FullscreenPlayerEffect.storageKey)
                || changedKeys.contains(timestampKey)
                || changedKeys.contains(writerKey) else { return }
        pullRemoteIfNewer()
    }

    private func pullRemoteIfNewer() {
        guard let kvs,
              let raw = kvs.string(forKey: FullscreenPlayerEffect.storageKey),
              let effect = FullscreenPlayerEffect(rawValue: raw) else { return }

        let remote = (kvs.double(forKey: timestampKey), kvs.string(forKey: writerKey) ?? "")
        let local = (defaults.double(forKey: timestampKey), defaults.string(forKey: writerKey) ?? "")
        let remoteWins = remote.0 > local.0 || (remote.0 == local.0 && remote.1 > local.1)
        guard remoteWins || defaults.string(forKey: FullscreenPlayerEffect.storageKey) == nil else { return }

        defaults.set(effect.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        defaults.set(remote.0, forKey: timestampKey)
        defaults.set(remote.1, forKey: writerKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: effect.rawValue)
    }
}
