import Foundation
import PrimuseKit
import SwiftUI

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
