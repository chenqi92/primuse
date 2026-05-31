import Foundation

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

struct PlaybackSettings: Codable, Sendable {
    static let defaultsKey = "primuse_playback_settings_v1"

    var gaplessEnabled: Bool = false
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 3.0
    var replayGainEnabled: Bool = false
    var replayGainMode: ReplayGainMode = .track
    var spatialAudioEnabled: Bool = false
    var spatialHeadTrackingEnabled: Bool = false
    var audioCacheEnabled: Bool = true
    var audioCacheLimitBytes: Int64 = AudioCacheManager.defaultMaxCacheSize
    var skipLeadingSilenceEnabled: Bool = true
    var skipTrailingSilenceEnabled: Bool = false
    var prewarmQueueCount: Int = 3
    /// 播放速度倍率, 0.5x ~ 2.0x。1.0 = 正常。走 AVAudioUnitTimePitch
    /// 节点，自动保持音调不变。
    var playbackRate: Float = 1.0
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
        gaplessEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessEnabled) ?? false
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 3.0
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        replayGainMode = try c.decodeIfPresent(ReplayGainMode.self, forKey: .replayGainMode) ?? .track
        spatialAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .spatialAudioEnabled) ?? false
        spatialHeadTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .spatialHeadTrackingEnabled) ?? false
        audioCacheEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioCacheEnabled) ?? true
        audioCacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .audioCacheLimitBytes) ?? AudioCacheManager.defaultMaxCacheSize
        skipLeadingSilenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipLeadingSilenceEnabled) ?? true
        skipTrailingSilenceEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipTrailingSilenceEnabled) ?? false
        prewarmQueueCount = try c.decodeIfPresent(Int.self, forKey: .prewarmQueueCount) ?? 3
        playbackRate = try c.decodeIfPresent(Float.self, forKey: .playbackRate) ?? 1.0
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
        gaplessEnabled: Bool = false,
        crossfadeEnabled: Bool = false,
        crossfadeDuration: Double = 3.0,
        replayGainEnabled: Bool = false,
        replayGainMode: ReplayGainMode = .track,
        spatialAudioEnabled: Bool = false,
        spatialHeadTrackingEnabled: Bool = false,
        audioCacheEnabled: Bool = true,
        audioCacheLimitBytes: Int64 = AudioCacheManager.defaultMaxCacheSize,
        skipLeadingSilenceEnabled: Bool = true,
        skipTrailingSilenceEnabled: Bool = false,
        prewarmQueueCount: Int = 3,
        playbackRate: Float = 1.0,
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
        self.gaplessEnabled = gaplessEnabled
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.replayGainEnabled = replayGainEnabled
        self.replayGainMode = replayGainMode
        self.spatialAudioEnabled = spatialAudioEnabled
        self.spatialHeadTrackingEnabled = spatialHeadTrackingEnabled
        self.audioCacheEnabled = audioCacheEnabled
        self.audioCacheLimitBytes = audioCacheLimitBytes
        self.skipLeadingSilenceEnabled = skipLeadingSilenceEnabled
        self.skipTrailingSilenceEnabled = skipTrailingSilenceEnabled
        self.prewarmQueueCount = prewarmQueueCount
        self.playbackRate = playbackRate
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
}

@MainActor
@Observable
final class PlaybackSettingsStore {
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
    var audioCacheEnabled: Bool { didSet { persist() } }
    var audioCacheLimitBytes: Int64 { didSet { persist() } }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = PlaybackSettings.load(defaults: defaults)
        self.gaplessEnabled = s.gaplessEnabled
        self.crossfadeEnabled = s.crossfadeEnabled
        self.crossfadeDuration = s.crossfadeDuration
        self.replayGainEnabled = s.replayGainEnabled
        self.replayGainMode = s.replayGainMode
        self.spatialAudioEnabled = s.spatialAudioEnabled
        self.spatialHeadTrackingEnabled = s.spatialAudioEnabled && s.spatialHeadTrackingEnabled
        self.audioCacheEnabled = s.audioCacheEnabled
        self.audioCacheLimitBytes = s.audioCacheLimitBytes
        self.skipLeadingSilenceEnabled = s.skipLeadingSilenceEnabled
        self.skipTrailingSilenceEnabled = s.skipTrailingSilenceEnabled
        self.prewarmQueueCount = max(0, min(8, s.prewarmQueueCount))
        self.playbackRate = max(0.5, min(2.0, s.playbackRate))
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

        CloudKVSSync.shared.register(key: PlaybackSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
    }

    /// Re-apply values from UserDefaults (used after KVS pushes a remote update).
    private func reloadFromDefaults() {
        let s = PlaybackSettings.load(defaults: defaults)
        suppressPersist = true
        defer { suppressPersist = false }

        gaplessEnabled = s.gaplessEnabled
        crossfadeEnabled = s.crossfadeEnabled
        crossfadeDuration = s.crossfadeDuration
        replayGainEnabled = s.replayGainEnabled
        replayGainMode = s.replayGainMode
        spatialAudioEnabled = s.spatialAudioEnabled
        spatialHeadTrackingEnabled = s.spatialAudioEnabled && s.spatialHeadTrackingEnabled
        audioCacheEnabled = s.audioCacheEnabled
        audioCacheLimitBytes = s.audioCacheLimitBytes
        skipLeadingSilenceEnabled = s.skipLeadingSilenceEnabled
        skipTrailingSilenceEnabled = s.skipTrailingSilenceEnabled
        prewarmQueueCount = max(0, min(8, s.prewarmQueueCount))
        playbackRate = max(0.5, min(2.0, s.playbackRate))
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
    }

    func snapshot() -> PlaybackSettings {
        PlaybackSettings(
            gaplessEnabled: gaplessEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDuration: crossfadeDuration,
            replayGainEnabled: replayGainEnabled,
            replayGainMode: replayGainMode,
            spatialAudioEnabled: spatialAudioEnabled,
            spatialHeadTrackingEnabled: spatialHeadTrackingEnabled,
            audioCacheEnabled: audioCacheEnabled,
            audioCacheLimitBytes: audioCacheLimitBytes,
            skipLeadingSilenceEnabled: skipLeadingSilenceEnabled,
            skipTrailingSilenceEnabled: skipTrailingSilenceEnabled,
            prewarmQueueCount: prewarmQueueCount,
            playbackRate: playbackRate,
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
