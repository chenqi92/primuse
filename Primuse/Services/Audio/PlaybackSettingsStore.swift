import Foundation
import PrimuseKit

enum AudioOutputMode: String, Codable, Sendable, CaseIterable {
    case highFidelity
    case effects

    var displayName: String {
        switch self {
        case .highFidelity: String(localized: "output_mode_high_fidelity")
        case .effects: String(localized: "output_mode_effects")
        }
    }

    /// What high-fidelity direct bypasses, then the hardware it takes to hear
    /// the difference at all. Shown before the mode is switched on and under
    /// the picker while it is on.
    static var highFidelityExplanation: String {
        String(localized: "output_mode_high_fidelity_desc")
            + "\n\n"
            + String(localized: "output_mode_high_fidelity_hardware_note")
    }
}

enum DSDPlaybackMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case pcm
    case dop

    var displayName: String {
        switch self {
        case .automatic: String(localized: "dsd_mode_auto")
        case .pcm: String(localized: "dsd_mode_pcm")
        case .dop: String(localized: "dsd_mode_dop")
        }
    }
}

enum ReplayGainMode: String, Codable, Sendable, CaseIterable {
    case track
    case album

    var displayName: String {
        switch self {
        case .track: String(localized: "rg_mode_track")
        case .album: String(localized: "rg_mode_album")
        }
    }
}

enum CrossfadeMode: String, Codable, Sendable, CaseIterable {
    case fixed
    case smart

    var displayName: String {
        switch self {
        case .fixed: String(localized: "crossfade_mode_fixed")
        case .smart: String(localized: "crossfade_mode_smart")
        }
    }
}

/// 传输音质选项的本地化标题。枚举本身住在 PrimuseKit(判定逻辑要能在没有
/// Xcode 的环境里跑测试)，文案留在 app 侧的 Localizable.strings 里。
extension StreamQualityPreference {
    var displayName: String {
        switch self {
        case .original: String(localized: "streaming_quality_original")
        case .kbps320: String(localized: "streaming_quality_320")
        case .kbps192: String(localized: "streaming_quality_192")
        case .kbps128: String(localized: "streaming_quality_128")
        }
    }
}

struct PlaybackSettings: Codable, Sendable {
    static let defaultsKey = "primuse_playback_settings_v1"
    static let lockScreenLyricsRolloutKey = "primuse_lock_screen_lyrics_default_enabled_v1"
    static let crossfadeDurationRolloutKey = "primuse_crossfade_default_duration_v2"

    /// Three seconds mostly overlapped the recorded fade-out at the end of a
    /// file, so an enabled crossfade was hard to hear at all. Five seconds is
    /// long enough to be audible without stepping on the next song's intro.
    static let defaultCrossfadeDuration: Double = 5.0
    static let legacyDefaultCrossfadeDuration: Double = 3.0

    /// New installs start on the full processing graph. High-fidelity direct
    /// bypasses EQ, playback speed, crossfade, spatial audio and ReplayGain —
    /// out of the box that reads as "those features are broken" rather than as
    /// a deliberate choice, so it is opt-in (with an explanation) instead of
    /// the default. Existing persisted settings keep whatever they have.
    var outputMode: AudioOutputMode = .effects
    var dsdPlaybackMode: DSDPlaybackMode = .automatic
    var gaplessEnabled: Bool = false
    var crossfadeEnabled: Bool = false
    /// New installs use energy-aware boundaries. Persisted payloads from
    /// earlier builds decode as `.fixed` below to preserve their exact sound.
    var crossfadeMode: CrossfadeMode = .smart
    var crossfadeDuration: Double = PlaybackSettings.defaultCrossfadeDuration
    var replayGainEnabled: Bool = false
    var replayGainMode: ReplayGainMode = .track
    var spatialAudioEnabled: Bool = false
    var spatialHeadTrackingEnabled: Bool = false
    var audioCacheEnabled: Bool = true
    var audioCacheLimitBytes: Int64 = AudioCacheManager.defaultMaxCacheSize
    /// 支持转码的服务端(Subsonic / Navidrome 等)上按网络类型选用的传输音质。
    /// 默认两项都是 `.original` —— 那时整条取流链路与未引入本功能时一致。
    var wifiStreamQuality: StreamQualityPreference = .original
    var cellularStreamQuality: StreamQualityPreference = .original
    var skipLeadingSilenceEnabled: Bool = true
    var skipTrailingSilenceEnabled: Bool = false
    var prewarmQueueCount: Int = 3
    /// 播放速度倍率, 0.5x ~ 2.0x。1.0 = 正常。走 AVAudioUnitTimePitch
    /// 节点，自动保持音调不变。
    var playbackRate: Float = 1.0
    /// 有声内容单独一档速度: 听书常用 1.25×–1.5×, 不能带到下一首歌上。
    var spokenWordPlaybackRate: Float = 1.0
    /// 有声内容的后退 / 前进秒数, 取值见 `SpokenWordSkipPolicy.allowedIntervals`。
    var spokenWordSkipBackwardSeconds: Int = 15
    var spokenWordSkipForwardSeconds: Int = 30
    /// 串烧每首截取的秒数。
    var medleySegmentSeconds: Int = 45
    /// Uses the current synchronized lyric as the system Now Playing title.
    /// Users can still opt out because the remapped metadata is also visible
    /// to Control Center, Bluetooth receivers and in-car Now Playing surfaces.
    var lockScreenLyricsEnabled: Bool = true
    /// 是否让 AVAudioSession 把硬件输出 SR 切到当前歌曲采样率, 避免
    /// CoreAudio 自动重采样。仅 iOS 真机有效, 部分老款硬件无视该 hint。
    var matchOutputSampleRate: Bool = false

    // Compressor / Limiter
    var effectChainEnabled: Bool = true
    var compressorEnabled: Bool = false
    var compressorThreshold: Float = -20
    var compressorHeadRoom: Float = 5
    var compressorAttackTime: Float = 0.005
    var compressorReleaseTime: Float = 0.1
    var compressorMasterGain: Float = 5

    var compressorPresetId: String?

    // Reverb
    var reverbEnabled: Bool = false
    var reverbPresetIndex: Int = 3  // mediumHall
    var reverbWetDryMix: Float = 20
    var reverbRoomSize: Float = 55

    // Custom decoding: use decodeIfPresent for new fields so that older
    // persisted JSON (without compressor/reverb keys) does not fail to
    // decode — existing user settings are preserved on update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try c.decodeIfPresent(AudioOutputMode.self, forKey: .outputMode) ?? .effects
        dsdPlaybackMode = try c.decodeIfPresent(DSDPlaybackMode.self, forKey: .dsdPlaybackMode) ?? .automatic
        gaplessEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessEnabled) ?? false
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeMode = try c.decodeIfPresent(CrossfadeMode.self, forKey: .crossfadeMode) ?? .fixed
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration)
            ?? Self.defaultCrossfadeDuration
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        replayGainMode = try c.decodeIfPresent(ReplayGainMode.self, forKey: .replayGainMode) ?? .track
        spatialAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .spatialAudioEnabled) ?? false
        spatialHeadTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .spatialHeadTrackingEnabled) ?? false
        audioCacheEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioCacheEnabled) ?? true
        audioCacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .audioCacheLimitBytes) ?? AudioCacheManager.defaultMaxCacheSize
        // 旧的持久化 JSON 里没有这两个键，必须解出 .original —— 升级上来的
        // 用户不能因为装了新版本就被改成转码。
        wifiStreamQuality = try c.decodeIfPresent(StreamQualityPreference.self, forKey: .wifiStreamQuality) ?? .original
        cellularStreamQuality = try c.decodeIfPresent(StreamQualityPreference.self, forKey: .cellularStreamQuality) ?? .original
        skipLeadingSilenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipLeadingSilenceEnabled) ?? true
        skipTrailingSilenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipTrailingSilenceEnabled) ?? false
        prewarmQueueCount = try c.decodeIfPresent(Int.self, forKey: .prewarmQueueCount) ?? 3
        playbackRate = try c.decodeIfPresent(Float.self, forKey: .playbackRate) ?? 1.0
        spokenWordPlaybackRate = try c.decodeIfPresent(Float.self, forKey: .spokenWordPlaybackRate) ?? 1.0
        spokenWordSkipBackwardSeconds = try c.decodeIfPresent(Int.self, forKey: .spokenWordSkipBackwardSeconds) ?? 15
        spokenWordSkipForwardSeconds = try c.decodeIfPresent(Int.self, forKey: .spokenWordSkipForwardSeconds) ?? 30
        medleySegmentSeconds = try c.decodeIfPresent(Int.self, forKey: .medleySegmentSeconds) ?? 45
        lockScreenLyricsEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockScreenLyricsEnabled) ?? true
        matchOutputSampleRate = try c.decodeIfPresent(Bool.self, forKey: .matchOutputSampleRate) ?? false
        effectChainEnabled = try c.decodeIfPresent(Bool.self, forKey: .effectChainEnabled) ?? true
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? false
        compressorThreshold = try c.decodeIfPresent(Float.self, forKey: .compressorThreshold) ?? -20
        compressorHeadRoom = try c.decodeIfPresent(Float.self, forKey: .compressorHeadRoom) ?? 5
        compressorAttackTime = try c.decodeIfPresent(Float.self, forKey: .compressorAttackTime) ?? 0.005
        compressorReleaseTime = try c.decodeIfPresent(Float.self, forKey: .compressorReleaseTime) ?? 0.1
        compressorMasterGain = try c.decodeIfPresent(Float.self, forKey: .compressorMasterGain) ?? 5
        compressorPresetId = try c.decodeIfPresent(String.self, forKey: .compressorPresetId)
        reverbEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverbEnabled) ?? false
        reverbPresetIndex = try c.decodeIfPresent(Int.self, forKey: .reverbPresetIndex) ?? 3
        reverbWetDryMix = try c.decodeIfPresent(Float.self, forKey: .reverbWetDryMix) ?? 20
        reverbRoomSize = try c.decodeIfPresent(Float.self, forKey: .reverbRoomSize) ?? 55
    }

    init(
        outputMode: AudioOutputMode = .effects,
        dsdPlaybackMode: DSDPlaybackMode = .automatic,
        gaplessEnabled: Bool = false,
        crossfadeEnabled: Bool = false,
        crossfadeMode: CrossfadeMode = .smart,
        crossfadeDuration: Double = PlaybackSettings.defaultCrossfadeDuration,
        replayGainEnabled: Bool = false,
        replayGainMode: ReplayGainMode = .track,
        spatialAudioEnabled: Bool = false,
        spatialHeadTrackingEnabled: Bool = false,
        audioCacheEnabled: Bool = true,
        audioCacheLimitBytes: Int64 = AudioCacheManager.defaultMaxCacheSize,
        wifiStreamQuality: StreamQualityPreference = .original,
        cellularStreamQuality: StreamQualityPreference = .original,
        skipLeadingSilenceEnabled: Bool = true,
        skipTrailingSilenceEnabled: Bool = false,
        prewarmQueueCount: Int = 3,
        playbackRate: Float = 1.0,
        spokenWordPlaybackRate: Float = 1.0,
        spokenWordSkipBackwardSeconds: Int = 15,
        spokenWordSkipForwardSeconds: Int = 30,
        medleySegmentSeconds: Int = 45,
        lockScreenLyricsEnabled: Bool = true,
        matchOutputSampleRate: Bool = false,
        effectChainEnabled: Bool = true,
        compressorEnabled: Bool = false,
        compressorThreshold: Float = -20,
        compressorHeadRoom: Float = 5,
        compressorAttackTime: Float = 0.005,
        compressorReleaseTime: Float = 0.1,
        compressorMasterGain: Float = 5,
        compressorPresetId: String? = nil,
        reverbEnabled: Bool = false,
        reverbPresetIndex: Int = 3,
        reverbWetDryMix: Float = 20,
        reverbRoomSize: Float = 55
    ) {
        self.outputMode = outputMode
        self.dsdPlaybackMode = dsdPlaybackMode
        self.gaplessEnabled = gaplessEnabled
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeMode = crossfadeMode
        self.crossfadeDuration = crossfadeDuration
        self.replayGainEnabled = replayGainEnabled
        self.replayGainMode = replayGainMode
        self.spatialAudioEnabled = spatialAudioEnabled
        self.spatialHeadTrackingEnabled = spatialHeadTrackingEnabled
        self.audioCacheEnabled = audioCacheEnabled
        self.audioCacheLimitBytes = audioCacheLimitBytes
        self.wifiStreamQuality = wifiStreamQuality
        self.cellularStreamQuality = cellularStreamQuality
        self.skipLeadingSilenceEnabled = skipLeadingSilenceEnabled
        self.skipTrailingSilenceEnabled = skipTrailingSilenceEnabled
        self.prewarmQueueCount = prewarmQueueCount
        self.playbackRate = playbackRate
        self.spokenWordPlaybackRate = spokenWordPlaybackRate
        self.spokenWordSkipBackwardSeconds = spokenWordSkipBackwardSeconds
        self.spokenWordSkipForwardSeconds = spokenWordSkipForwardSeconds
        self.medleySegmentSeconds = medleySegmentSeconds
        self.lockScreenLyricsEnabled = lockScreenLyricsEnabled
        self.matchOutputSampleRate = matchOutputSampleRate
        self.effectChainEnabled = effectChainEnabled
        self.compressorEnabled = compressorEnabled
        self.compressorThreshold = compressorThreshold
        self.compressorHeadRoom = compressorHeadRoom
        self.compressorAttackTime = compressorAttackTime
        self.compressorReleaseTime = compressorReleaseTime
        self.compressorMasterGain = compressorMasterGain
        self.compressorPresetId = compressorPresetId
        self.reverbEnabled = reverbEnabled
        self.reverbPresetIndex = reverbPresetIndex
        self.reverbWetDryMix = reverbWetDryMix
        self.reverbRoomSize = reverbRoomSize
    }

    /// 整包经 iCloud 键值存储同步到用户的每台设备, 但下面这些字段是按这台设备的
    /// 硬件与存储做的决定, 别的设备推来的整包不能替本机做主: Mac 上给缓存划 50 GB、
    /// 为外置 DAC 开高保真直通, 同步到 iPhone 上就是一台存储被占满、耳机里没了
    /// 均衡器的手机。远端整包到达时(`PlaybackSettingsStore.reloadFromDefaults`)这些
    /// 字段保留本机原值。整包格式不变, 旧版本照样解得开; 推上云端的整包里带的仍是
    /// 本机值, 收到的一方拿这张表把它们忽略掉。
    ///
    /// 新增字段时先问一句: 换一台设备, 用户还会想要同一个值吗? 不会的才放进来。
    static let deviceLocalFields = CloudKVSDeviceLocalFields<PlaybackSettings>([
        // 缓存开关与容量是本机存储的决定: 手机的 64 GB 和 Mac 的 2 TB 没法共用一个数。
        .init("audioCacheEnabled", \.audioCacheEnabled),
        .init("audioCacheLimitBytes", \.audioCacheLimitBytes),
        // 输出模式与 DSD 走哪条路取决于接在这台设备上的 DAC / 输出链路。
        .init("outputMode", \.outputMode),
        .init("dsdPlaybackMode", \.dsdPlaybackMode),
        // 让硬件输出采样率跟随歌曲只对 iOS 真机有意义, 而且部分硬件无视。
        .init("matchOutputSampleRate", \.matchOutputSampleRate),
        // 提前准备几首是本机内存与网络预算的取舍。
        .init("prewarmQueueCount", \.prewarmQueueCount),
        // 头部追踪要这台设备连着带传感器的耳机; 空间音频本身是听感偏好, 照常同步。
        .init("spatialHeadTrackingEnabled", \.spatialHeadTrackingEnabled),
        // 传输音质按这台设备的网络来: Mac 没有蜂窝, 手机的流量套餐也不是 Mac 的。
        .init("wifiStreamQuality", \.wifiStreamQuality),
        .init("cellularStreamQuality", \.cellularStreamQuality),
    ])

    static func load(defaults: UserDefaults = .standard) -> PlaybackSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return PlaybackSettings()
        }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The initial lock-screen lyrics implementation shipped disabled, which
    /// made the feature appear absent after an update. Enable it once while
    /// retaining the user's later opt-out as an ordinary persisted setting.
    @discardableResult
    static func applyLockScreenLyricsRolloutIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: lockScreenLyricsRolloutKey) == nil else {
            return false
        }
        var settings = load(defaults: defaults)
        settings.lockScreenLyricsEnabled = true
        settings.save(defaults: defaults)
        defaults.set(true, forKey: lockScreenLyricsRolloutKey)
        return true
    }

    /// The whole payload is persisted on first launch, so the old three-second
    /// value is frozen into existing installs even when crossfade was never used.
    /// Move those to the current default once; a duration picked while
    /// crossfade is on, or any value other than the old default, is a choice
    /// and stays as it is.
    @discardableResult
    static func applyCrossfadeDurationRolloutIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: crossfadeDurationRolloutKey) == nil else {
            return false
        }
        defaults.set(true, forKey: crossfadeDurationRolloutKey)
        var settings = load(defaults: defaults)
        guard !settings.crossfadeEnabled,
              settings.crossfadeDuration == legacyDefaultCrossfadeDuration else {
            return false
        }
        settings.crossfadeDuration = defaultCrossfadeDuration
        settings.save(defaults: defaults)
        return true
    }
}

@MainActor
@Observable
final class PlaybackSettingsStore {
    var outputMode: AudioOutputMode { didSet { persist() } }
    var dsdPlaybackMode: DSDPlaybackMode { didSet { persist() } }
    var gaplessEnabled: Bool {
        didSet {
            if gaplessEnabled, crossfadeEnabled {
                crossfadeEnabled = false
            }
            persist()
        }
    }
    var crossfadeEnabled: Bool {
        didSet {
            if crossfadeEnabled, gaplessEnabled {
                gaplessEnabled = false
            }
            persist()
        }
    }
    var crossfadeMode: CrossfadeMode { didSet { persist() } }
    var crossfadeDuration: Double { didSet { persist() } }
    var replayGainEnabled: Bool { didSet { persist() } }
    var replayGainMode: ReplayGainMode { didSet { persist() } }
    var spatialAudioEnabled: Bool {
        didSet {
            if !spatialAudioEnabled, spatialHeadTrackingEnabled {
                spatialHeadTrackingEnabled = false
            }
            persist()
        }
    }
    var spatialHeadTrackingEnabled: Bool {
        didSet {
            if spatialHeadTrackingEnabled, !spatialAudioEnabled {
                spatialAudioEnabled = true
            }
            persist()
        }
    }
    var audioCacheEnabled: Bool {
        didSet {
            persist()
            guard audioCacheEnabled != oldValue else { return }
            audioCacheEnabledDidChange?(audioCacheEnabled)
        }
    }
    var audioCacheLimitBytes: Int64 { didSet { persist() } }
    var wifiStreamQuality: StreamQualityPreference { didSet { persist() } }
    var cellularStreamQuality: StreamQualityPreference { didSet { persist() } }
    var skipLeadingSilenceEnabled: Bool { didSet { persist() } }
    var skipTrailingSilenceEnabled: Bool { didSet { persist() } }
    var prewarmQueueCount: Int {
        didSet {
            let clamped = max(0, min(8, prewarmQueueCount))
            if clamped != prewarmQueueCount {
                prewarmQueueCount = clamped
                return
            }
            persist()
        }
    }
    var playbackRate: Float {
        didSet {
            // 限定 0.5x - 2.0x, AVAudioUnitTimePitch 单元在此区间外音质会明显劣化
            let clamped = max(0.5, min(2.0, playbackRate))
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            persist()
        }
    }
    var spokenWordPlaybackRate: Float {
        didSet {
            let clamped = SpokenWordPlaybackRatePolicy.clamped(spokenWordPlaybackRate)
            if clamped != spokenWordPlaybackRate {
                spokenWordPlaybackRate = clamped
                return
            }
            persist()
        }
    }
    var spokenWordSkipBackwardSeconds: Int {
        didSet {
            let clamped = SpokenWordSkipPolicy.clampedInterval(spokenWordSkipBackwardSeconds)
            if clamped != spokenWordSkipBackwardSeconds {
                spokenWordSkipBackwardSeconds = clamped
                return
            }
            persist()
        }
    }
    var spokenWordSkipForwardSeconds: Int {
        didSet {
            let clamped = SpokenWordSkipPolicy.clampedInterval(spokenWordSkipForwardSeconds)
            if clamped != spokenWordSkipForwardSeconds {
                spokenWordSkipForwardSeconds = clamped
                return
            }
            persist()
        }
    }
    var medleySegmentSeconds: Int {
        didSet {
            let clamped = MedleySegmentPolicy.clampedSegmentLength(medleySegmentSeconds)
            if clamped != medleySegmentSeconds {
                medleySegmentSeconds = clamped
                return
            }
            persist()
        }
    }
    var lockScreenLyricsEnabled: Bool { didSet { persist() } }
    var matchOutputSampleRate: Bool { didSet { persist() } }

    // Compressor / Limiter
    var effectChainEnabled: Bool { didSet { persist() } }
    var compressorEnabled: Bool { didSet { persist() } }
    var compressorThreshold: Float { didSet { persist() } }
    var compressorHeadRoom: Float { didSet { persist() } }
    var compressorAttackTime: Float { didSet { persist() } }
    var compressorReleaseTime: Float { didSet { persist() } }
    var compressorMasterGain: Float { didSet { persist() } }
    var compressorPresetId: String? { didSet { persist() } }

    // Reverb
    var reverbEnabled: Bool { didSet { persist() } }
    var reverbPresetIndex: Int { didSet { persist() } }
    var reverbWetDryMix: Float { didSet { persist() } }
    var reverbRoomSize: Float { didSet { persist() } }

    private let defaults: UserDefaults
    private var suppressPersist = false
    @ObservationIgnored var audioCacheEnabledDidChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = PlaybackSettings.load(defaults: defaults)
        self.outputMode = s.outputMode
        self.dsdPlaybackMode = s.dsdPlaybackMode
        self.gaplessEnabled = s.gaplessEnabled
        self.crossfadeEnabled = s.crossfadeEnabled
        self.crossfadeMode = s.crossfadeMode
        self.crossfadeDuration = s.crossfadeDuration
        self.replayGainEnabled = s.replayGainEnabled
        self.replayGainMode = s.replayGainMode
        self.spatialAudioEnabled = s.spatialAudioEnabled
        self.spatialHeadTrackingEnabled = s.spatialAudioEnabled && s.spatialHeadTrackingEnabled
        self.audioCacheEnabled = s.audioCacheEnabled
        self.audioCacheLimitBytes = s.audioCacheLimitBytes
        self.wifiStreamQuality = s.wifiStreamQuality
        self.cellularStreamQuality = s.cellularStreamQuality
        self.skipLeadingSilenceEnabled = s.skipLeadingSilenceEnabled
        self.skipTrailingSilenceEnabled = s.skipTrailingSilenceEnabled
        self.prewarmQueueCount = max(0, min(8, s.prewarmQueueCount))
        self.playbackRate = max(0.5, min(2.0, s.playbackRate))
        self.spokenWordPlaybackRate = SpokenWordPlaybackRatePolicy.clamped(s.spokenWordPlaybackRate)
        self.spokenWordSkipBackwardSeconds = SpokenWordSkipPolicy.clampedInterval(s.spokenWordSkipBackwardSeconds)
        self.spokenWordSkipForwardSeconds = SpokenWordSkipPolicy.clampedInterval(s.spokenWordSkipForwardSeconds)
        self.medleySegmentSeconds = MedleySegmentPolicy.clampedSegmentLength(s.medleySegmentSeconds)
        self.lockScreenLyricsEnabled = s.lockScreenLyricsEnabled
        self.matchOutputSampleRate = s.matchOutputSampleRate
        self.effectChainEnabled = s.effectChainEnabled
        self.compressorEnabled = s.compressorEnabled
        self.compressorThreshold = s.compressorThreshold
        self.compressorHeadRoom = s.compressorHeadRoom
        self.compressorAttackTime = s.compressorAttackTime
        self.compressorReleaseTime = s.compressorReleaseTime
        self.compressorMasterGain = s.compressorMasterGain
        self.compressorPresetId = s.compressorPresetId
        self.reverbEnabled = s.reverbEnabled
        self.reverbPresetIndex = s.reverbPresetIndex
        self.reverbWetDryMix = s.reverbWetDryMix
        self.reverbRoomSize = s.reverbRoomSize

        // 新装的设备还没有自己的设置: 灰度迁移只写本机默认值, 不能当成用户编辑
        // 推上 iCloud —— 那会把别的设备上的播放设置整份换成默认值。
        let hadPersistedSettings = defaults.data(forKey: PlaybackSettings.defaultsKey) != nil
        CloudKVSSync.shared.register(key: PlaybackSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
        let lyricsRolledOut = PlaybackSettings.applyLockScreenLyricsRolloutIfNeeded(defaults: defaults)
        let crossfadeRolledOut = PlaybackSettings.applyCrossfadeDurationRolloutIfNeeded(defaults: defaults)
        if lyricsRolledOut || crossfadeRolledOut {
            reloadFromDefaults()
            if hadPersistedSettings {
                CloudKVSSync.shared.markChanged(key: PlaybackSettings.defaultsKey)
            }
        }
    }

    /// Re-apply values from UserDefaults (used after KVS pushes a remote update,
    /// and after a one-time rollout rewrote the local payload).
    ///
    /// 到这里时 UserDefaults 里已经是远端整包(`CloudKVSSync` 先写 defaults 再回调)。
    /// 套用到内存前, 把只属于本机的字段(`PlaybackSettings.deviceLocalFields`)换回
    /// 内存里的当前值: 那就是本机套用远端之前的值 —— 新装设备上则是默认值, 两种都
    /// 不能被远端顶掉。合并结果还要写回 UserDefaults, `AudioCacheManager` 这类直接
    /// 读 defaults 的地方才看得到本机值, 下次启动也才装得回来。但这不是一次编辑,
    /// 绝不能经 `persist()` 走 `markChanged`: 推回去会让两台设备拿各自的本机值来回
    /// 互推。灰度迁移那条路上 defaults 里的本机字段与内存一致, 合并是恒等, 不写回。
    private func reloadFromDefaults() {
        let merge = PlaybackSettings.deviceLocalFields.merge(
            remote: PlaybackSettings.load(defaults: defaults),
            local: snapshot()
        )
        let s = merge.settings
        suppressPersist = true
        defer { suppressPersist = false }

        outputMode = s.outputMode
        dsdPlaybackMode = s.dsdPlaybackMode
        gaplessEnabled = s.gaplessEnabled
        crossfadeEnabled = s.crossfadeEnabled
        crossfadeMode = s.crossfadeMode
        crossfadeDuration = s.crossfadeDuration
        replayGainEnabled = s.replayGainEnabled
        replayGainMode = s.replayGainMode
        spatialAudioEnabled = s.spatialAudioEnabled
        spatialHeadTrackingEnabled = s.spatialAudioEnabled && s.spatialHeadTrackingEnabled
        audioCacheEnabled = s.audioCacheEnabled
        audioCacheLimitBytes = s.audioCacheLimitBytes
        wifiStreamQuality = s.wifiStreamQuality
        cellularStreamQuality = s.cellularStreamQuality
        skipLeadingSilenceEnabled = s.skipLeadingSilenceEnabled
        skipTrailingSilenceEnabled = s.skipTrailingSilenceEnabled
        prewarmQueueCount = max(0, min(8, s.prewarmQueueCount))
        playbackRate = max(0.5, min(2.0, s.playbackRate))
        spokenWordPlaybackRate = SpokenWordPlaybackRatePolicy.clamped(s.spokenWordPlaybackRate)
        spokenWordSkipBackwardSeconds = SpokenWordSkipPolicy.clampedInterval(s.spokenWordSkipBackwardSeconds)
        spokenWordSkipForwardSeconds = SpokenWordSkipPolicy.clampedInterval(s.spokenWordSkipForwardSeconds)
        medleySegmentSeconds = MedleySegmentPolicy.clampedSegmentLength(s.medleySegmentSeconds)
        lockScreenLyricsEnabled = s.lockScreenLyricsEnabled
        matchOutputSampleRate = s.matchOutputSampleRate
        effectChainEnabled = s.effectChainEnabled
        compressorEnabled = s.compressorEnabled
        compressorThreshold = s.compressorThreshold
        compressorHeadRoom = s.compressorHeadRoom
        compressorAttackTime = s.compressorAttackTime
        compressorReleaseTime = s.compressorReleaseTime
        compressorMasterGain = s.compressorMasterGain
        compressorPresetId = s.compressorPresetId
        reverbEnabled = s.reverbEnabled
        reverbPresetIndex = s.reverbPresetIndex
        reverbWetDryMix = s.reverbWetDryMix
        reverbRoomSize = s.reverbRoomSize

        guard !merge.keptFields.isEmpty else { return }
        // 写回的是套用后的内存快照(已做范围与联动归一), 与 `persist()` 落盘的
        // 内容一致, 只是不推云端。
        snapshot().save(defaults: defaults)
        plog("☁️ PlaybackSettings remote payload applied, kept device-local: \(merge.keptFields.joined(separator: ", "))")
    }

    func snapshot() -> PlaybackSettings {
        PlaybackSettings(
            outputMode: outputMode,
            dsdPlaybackMode: dsdPlaybackMode,
            gaplessEnabled: gaplessEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeMode: crossfadeMode,
            crossfadeDuration: crossfadeDuration,
            replayGainEnabled: replayGainEnabled,
            replayGainMode: replayGainMode,
            spatialAudioEnabled: spatialAudioEnabled,
            spatialHeadTrackingEnabled: spatialHeadTrackingEnabled,
            audioCacheEnabled: audioCacheEnabled,
            audioCacheLimitBytes: audioCacheLimitBytes,
            wifiStreamQuality: wifiStreamQuality,
            cellularStreamQuality: cellularStreamQuality,
            skipLeadingSilenceEnabled: skipLeadingSilenceEnabled,
            skipTrailingSilenceEnabled: skipTrailingSilenceEnabled,
            prewarmQueueCount: prewarmQueueCount,
            playbackRate: playbackRate,
            spokenWordPlaybackRate: spokenWordPlaybackRate,
            spokenWordSkipBackwardSeconds: spokenWordSkipBackwardSeconds,
            spokenWordSkipForwardSeconds: spokenWordSkipForwardSeconds,
            medleySegmentSeconds: medleySegmentSeconds,
            lockScreenLyricsEnabled: lockScreenLyricsEnabled,
            matchOutputSampleRate: matchOutputSampleRate,
            effectChainEnabled: effectChainEnabled,
            compressorEnabled: compressorEnabled,
            compressorThreshold: compressorThreshold,
            compressorHeadRoom: compressorHeadRoom,
            compressorAttackTime: compressorAttackTime,
            compressorReleaseTime: compressorReleaseTime,
            compressorMasterGain: compressorMasterGain,
            compressorPresetId: compressorPresetId,
            reverbEnabled: reverbEnabled,
            reverbPresetIndex: reverbPresetIndex,
            reverbWetDryMix: reverbWetDryMix,
            reverbRoomSize: reverbRoomSize
        )
    }

    private func persist() {
        guard !suppressPersist else { return }
        snapshot().save(defaults: defaults)
        CloudKVSSync.shared.markChanged(key: PlaybackSettings.defaultsKey)
    }
}
