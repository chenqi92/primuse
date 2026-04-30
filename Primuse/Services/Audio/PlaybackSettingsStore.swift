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

    var gaplessEnabled: Bool = true
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 3.0
    var replayGainEnabled: Bool = false
    var replayGainMode: ReplayGainMode = .track
    var audioCacheEnabled: Bool = true

    // Compressor / Limiter
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

    // Custom decoding: use decodeIfPresent for new fields so that older
    // persisted JSON (without compressor/reverb keys) does not fail to
    // decode — existing user settings are preserved on update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gaplessEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessEnabled) ?? true
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 3.0
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        replayGainMode = try c.decodeIfPresent(ReplayGainMode.self, forKey: .replayGainMode) ?? .track
        audioCacheEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioCacheEnabled) ?? true
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
    }

    init(
        gaplessEnabled: Bool = true,
        crossfadeEnabled: Bool = false,
        crossfadeDuration: Double = 3.0,
        replayGainEnabled: Bool = false,
        replayGainMode: ReplayGainMode = .track,
        audioCacheEnabled: Bool = true,
        compressorEnabled: Bool = false,
        compressorThreshold: Float = -20,
        compressorHeadRoom: Float = 5,
        compressorAttackTime: Float = 0.005,
        compressorReleaseTime: Float = 0.1,
        compressorMasterGain: Float = 5,
        compressorPresetId: String? = nil,
        reverbEnabled: Bool = false,
        reverbPresetIndex: Int = 3,
        reverbWetDryMix: Float = 20
    ) {
        self.gaplessEnabled = gaplessEnabled
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.replayGainEnabled = replayGainEnabled
        self.replayGainMode = replayGainMode
        self.audioCacheEnabled = audioCacheEnabled
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
    var gaplessEnabled: Bool { didSet { persist() } }
    var crossfadeEnabled: Bool { didSet { persist() } }
    var crossfadeDuration: Double { didSet { persist() } }
    var replayGainEnabled: Bool { didSet { persist() } }
    var replayGainMode: ReplayGainMode { didSet { persist() } }
    var audioCacheEnabled: Bool { didSet { persist() } }

    // Compressor / Limiter
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
        self.audioCacheEnabled = s.audioCacheEnabled
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
        audioCacheEnabled = s.audioCacheEnabled
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
    }

    func snapshot() -> PlaybackSettings {
        PlaybackSettings(
            gaplessEnabled: gaplessEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDuration: crossfadeDuration,
            replayGainEnabled: replayGainEnabled,
            replayGainMode: replayGainMode,
            audioCacheEnabled: audioCacheEnabled,
            compressorEnabled: compressorEnabled,
            compressorThreshold: compressorThreshold,
            compressorHeadRoom: compressorHeadRoom,
            compressorAttackTime: compressorAttackTime,
            compressorReleaseTime: compressorReleaseTime,
            compressorMasterGain: compressorMasterGain,
            compressorPresetId: compressorPresetId,
            reverbEnabled: reverbEnabled,
            reverbPresetIndex: reverbPresetIndex,
            reverbWetDryMix: reverbWetDryMix
        )
    }

    private func persist() {
        guard !suppressPersist else { return }
        snapshot().save(defaults: defaults)
        CloudKVSSync.shared.markChanged(key: PlaybackSettings.defaultsKey)
    }
}
