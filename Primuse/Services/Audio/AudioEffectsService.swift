import AudioToolbox
import AVFoundation
import Foundation

// MARK: - Reverb Preset Wrapper

enum ReverbPreset: Int, CaseIterable, Codable, Sendable, Identifiable {
    case smallRoom = 0
    case mediumRoom = 1
    case largeRoom = 2
    case mediumHall = 3
    case largeHall = 4
    case plate = 5
    case cathedral = 6

    var id: Int { rawValue }

    var avPreset: AVAudioUnitReverbPreset {
        AVAudioUnitReverbPreset(rawValue: rawValue) ?? .mediumHall
    }

    var localizedName: String {
        switch self {
        case .smallRoom: String(localized: "reverb_small_room")
        case .mediumRoom: String(localized: "reverb_medium_room")
        case .largeRoom: String(localized: "reverb_large_room")
        case .mediumHall: String(localized: "reverb_medium_hall")
        case .largeHall: String(localized: "reverb_large_hall")
        case .cathedral: String(localized: "reverb_cathedral")
        case .plate: String(localized: "reverb_plate")
        }
    }
}

// MARK: - Compressor Preset

struct CompressorPreset: Identifiable, Sendable {
    let id: String
    let localizedName: String
    let threshold: Float
    let headRoom: Float
    let attackTime: Float
    let releaseTime: Float
    let masterGain: Float

    static let light = CompressorPreset(
        id: "light",
        localizedName: String(localized: "compressor_light"),
        threshold: -15, headRoom: 10, attackTime: 0.01, releaseTime: 0.15, masterGain: 2
    )

    static let medium = CompressorPreset(
        id: "medium",
        localizedName: String(localized: "compressor_medium"),
        threshold: -20, headRoom: 5, attackTime: 0.005, releaseTime: 0.1, masterGain: 5
    )

    static let heavy = CompressorPreset(
        id: "heavy",
        localizedName: String(localized: "compressor_heavy"),
        threshold: -30, headRoom: 2, attackTime: 0.001, releaseTime: 0.05, masterGain: 10
    )

    static let allPresets: [CompressorPreset] = [.light, .medium, .heavy]
}

// MARK: - Audio Effects Service

@MainActor
@Observable
final class AudioEffectsService {
    private let audioEngine: AudioEngine
    private let settingsStore: PlaybackSettingsStore
    private var isApplyingPreset = false

    // MARK: - Compressor State

    var compressorEnabled: Bool {
        didSet {
            audioEngine.compressorNode?.bypass = !compressorEnabled
            settingsStore.compressorEnabled = compressorEnabled
        }
    }
    var compressorThreshold: Float {
        didSet {
            setCompressorParam(kDynamicsProcessorParam_Threshold, value: compressorThreshold)
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorThreshold = compressorThreshold
        }
    }
    var compressorHeadRoom: Float {
        didSet {
            setCompressorParam(kDynamicsProcessorParam_HeadRoom, value: compressorHeadRoom)
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorHeadRoom = compressorHeadRoom
        }
    }
    var compressorAttackTime: Float {
        didSet {
            setCompressorParam(kDynamicsProcessorParam_AttackTime, value: compressorAttackTime)
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorAttackTime = compressorAttackTime
        }
    }
    var compressorReleaseTime: Float {
        didSet {
            setCompressorParam(kDynamicsProcessorParam_ReleaseTime, value: compressorReleaseTime)
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorReleaseTime = compressorReleaseTime
        }
    }
    var compressorMasterGain: Float {
        didSet {
            setCompressorParam(kDynamicsProcessorParam_OverallGain, value: compressorMasterGain)
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorMasterGain = compressorMasterGain
        }
    }
    var compressorPresetId: String? {
        didSet { settingsStore.compressorPresetId = compressorPresetId }
    }

    // MARK: - Reverb State

    var reverbEnabled: Bool {
        didSet {
            audioEngine.reverbNode?.bypass = !reverbEnabled
            settingsStore.reverbEnabled = reverbEnabled
        }
    }
    var reverbPreset: ReverbPreset {
        didSet {
            audioEngine.reverbNode?.loadFactoryPreset(reverbPreset.avPreset)
            settingsStore.reverbPresetIndex = reverbPreset.rawValue
        }
    }
    var reverbWetDryMix: Float {
        didSet {
            audioEngine.reverbNode?.wetDryMix = reverbWetDryMix
            settingsStore.reverbWetDryMix = reverbWetDryMix
        }
    }

    // MARK: - Init

    init(audioEngine: AudioEngine, settingsStore: PlaybackSettingsStore) {
        self.audioEngine = audioEngine
        self.settingsStore = settingsStore

        // Load persisted settings
        let s = settingsStore.snapshot()
        self.compressorEnabled = s.compressorEnabled
        self.compressorThreshold = s.compressorThreshold
        self.compressorHeadRoom = s.compressorHeadRoom
        self.compressorAttackTime = s.compressorAttackTime
        self.compressorReleaseTime = s.compressorReleaseTime
        self.compressorMasterGain = s.compressorMasterGain
        self.reverbEnabled = s.reverbEnabled
        self.reverbPreset = ReverbPreset(rawValue: s.reverbPresetIndex) ?? .mediumHall
        self.reverbWetDryMix = s.reverbWetDryMix

        self.compressorPresetId = s.compressorPresetId
    }

    /// Apply persisted settings to the audio nodes (call after AudioEngine.setUp())
    func applySettings() {
        // Compressor
        if let comp = audioEngine.compressorNode {
            comp.bypass = !compressorEnabled
            setCompressorParam(kDynamicsProcessorParam_Threshold, value: compressorThreshold)
            setCompressorParam(kDynamicsProcessorParam_HeadRoom, value: compressorHeadRoom)
            setCompressorParam(kDynamicsProcessorParam_AttackTime, value: compressorAttackTime)
            setCompressorParam(kDynamicsProcessorParam_ReleaseTime, value: compressorReleaseTime)
            setCompressorParam(kDynamicsProcessorParam_OverallGain, value: compressorMasterGain)
        }

        // Reverb
        if let reverb = audioEngine.reverbNode {
            reverb.bypass = !reverbEnabled
            reverb.loadFactoryPreset(reverbPreset.avPreset)
            reverb.wetDryMix = reverbWetDryMix
        }
    }

    // MARK: - Compressor Presets

    func applyCompressorPreset(_ preset: CompressorPreset) {
        isApplyingPreset = true
        defer { isApplyingPreset = false }

        compressorPresetId = preset.id
        compressorThreshold = preset.threshold
        compressorHeadRoom = preset.headRoom
        compressorAttackTime = preset.attackTime
        compressorReleaseTime = preset.releaseTime
        compressorMasterGain = preset.masterGain
    }

    func resetCompressor() {
        applyCompressorPreset(.medium)
    }

    func resetReverb() {
        reverbPreset = .mediumHall
        reverbWetDryMix = 20
    }

    // MARK: - AudioUnit Parameter Helpers

    private func setCompressorParam(_ param: AudioUnitParameterID, value: Float) {
        guard let audioUnit = audioEngine.compressorNode?.audioUnit else { return }
        let status = AudioUnitSetParameter(audioUnit, param, kAudioUnitScope_Global, 0, value, 0)
        if status != noErr {
            NSLog("⚠️ AudioEffects: failed to set compressor param \(param) = \(value), OSStatus = \(status)")
        }
    }
}
