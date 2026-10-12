import AudioToolbox
import AVFoundation
import Foundation
import PrimuseKit

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

    /// 存储值是这里的 rawValue,不是 AVAudioUnitReverbPreset 的:系统的 6 是「中型室」,
    /// 教堂是 8,按 rawValue 直接换会把「教堂」放成中型室。
    var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .cathedral: .cathedral
        }
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

    var effectChainEnabled: Bool {
        didSet {
            scheduleNodeUpdate()
            settingsStore.effectChainEnabled = effectChainEnabled
        }
    }

    // MARK: - Compressor State

    var compressorEnabled: Bool {
        didSet {
            scheduleNodeUpdate()
            settingsStore.compressorEnabled = compressorEnabled
        }
    }
    var compressorThreshold: Float {
        didSet {
            scheduleNodeUpdate()
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorThreshold = compressorThreshold
        }
    }
    var compressorHeadRoom: Float {
        didSet {
            scheduleNodeUpdate()
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorHeadRoom = compressorHeadRoom
        }
    }
    var compressorAttackTime: Float {
        didSet {
            scheduleNodeUpdate()
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorAttackTime = compressorAttackTime
        }
    }
    var compressorReleaseTime: Float {
        didSet {
            scheduleNodeUpdate()
            if !isApplyingPreset { compressorPresetId = nil }
            settingsStore.compressorReleaseTime = compressorReleaseTime
        }
    }
    var compressorMasterGain: Float {
        didSet {
            scheduleNodeUpdate()
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
            scheduleNodeUpdate()
            settingsStore.reverbEnabled = reverbEnabled
        }
    }
    var reverbPreset: ReverbPreset {
        didSet {
            scheduleNodeUpdate()
            settingsStore.reverbPresetIndex = reverbPreset.rawValue
        }
    }
    var reverbWetDryMix: Float {
        didSet {
            scheduleNodeUpdate()
            settingsStore.reverbWetDryMix = reverbWetDryMix
        }
    }
    var reverbRoomSize: Float {
        didSet {
            settingsStore.reverbRoomSize = max(0, min(100, reverbRoomSize))
        }
    }

    // MARK: - Init

    init(audioEngine: AudioEngine, settingsStore: PlaybackSettingsStore) {
        self.audioEngine = audioEngine
        self.settingsStore = settingsStore

        // Load persisted settings
        let s = settingsStore.snapshot()
        self.effectChainEnabled = s.effectChainEnabled
        self.compressorEnabled = s.compressorEnabled
        self.compressorThreshold = s.compressorThreshold
        self.compressorHeadRoom = s.compressorHeadRoom
        self.compressorAttackTime = s.compressorAttackTime
        self.compressorReleaseTime = s.compressorReleaseTime
        self.compressorMasterGain = s.compressorMasterGain
        self.reverbEnabled = s.reverbEnabled
        self.reverbPreset = ReverbPreset(rawValue: s.reverbPresetIndex) ?? .mediumHall
        self.reverbWetDryMix = s.reverbWetDryMix
        self.reverbRoomSize = s.reverbRoomSize

        self.compressorPresetId = s.compressorPresetId
    }

    /// Apply persisted settings to the audio nodes (call after AudioEngine.setUp())
    /// 新建的图还没出声,整组直接写到位;同一张图上再调就照常走过渡。
    func applySettings() {
        guard let compressor = audioEngine.compressorNode else { return }
        guard compressor !== applied.compressor else {
            scheduleNodeUpdate()
            return
        }
        cancelTransition()
        applied = AppliedNodes(compressor: compressor)
        writeCompressor(compressorTarget, force: true)
        writeCompressorTiming()
        if let reverb = audioEngine.reverbNode {
            reverb.loadFactoryPreset(reverbPreset.avPreset)
            reverb.wetDryMix = 100
            reverb.bypass = !reverbIsActive
            applied.reverbPreset = reverbPreset
            applied.reverbBypassed = !reverbIsActive
            setReverbMix(reverbIsActive ? reverbWetDryMix : 0, at: .now)
            setReverbHeadroom(reverbTargetHeadroomDB, at: .now)
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
        reverbRoomSize = 55
    }

    // MARK: - Interface notes

    var compressorIsActive: Bool { effectChainEnabled && compressorEnabled }
    var reverbIsActive: Bool { effectChainEnabled && reverbEnabled }

    /// 开着混响时整体调低的量(dB),界面上说明用;没开或压得太少时为 nil。
    var reverbHeadroomNoteDB: Float? {
        let headroom = reverbTargetHeadroomDB
        return headroom >= 0.1 ? headroom : nil
    }

    /// 总增益被封顶时实际能加到多少(dB);没被封顶时为 nil。
    var compressorGainCapDB: Float? {
        guard compressorIsActive else { return nil }
        let cap = CompressorTransitionPolicy.maximumGainDB(
            threshold: compressorThreshold,
            headRoom: compressorHeadRoom
        )
        return compressorMasterGain > cap + 0.05 ? cap : nil
    }

    // MARK: - Node transitions
    //
    // 压缩器和混响的参数一写就是硬切(编译机实测:旁通开压缩器、混响干湿比一步跳、换房间都会
    // 咔哒),所以压缩器每 10 ms 挪一小步(CompressorTransitionPolicy),混响的干湿比和余量
    // 落在并联混音节点的音量上;升电平的改动都等降电平的改动生效之后才做。

    private struct AppliedNodes {
        weak var compressor: AVAudioUnitEffect?
        var compressorParameters = CompressorTransitionPolicy.Parameters(
            threshold: CompressorTransitionPolicy.neutralThreshold, headRoom: 5, gain: 0
        )
        var attackTime: Float?
        var releaseTime: Float?
        var reverbPreset: ReverbPreset?
        var reverbWetPercent: Float = 0
        var reverbBypassed = true
        var reverbHeadroomDB: Float = 0
        var reverbWetChangedAt: ContinuousClock.Instant?
        var reverbHeadroomLoweredAt: ContinuousClock.Instant?
        /// 等余量压下去之后再把湿声升到这里。
        var pendingWetRise: (wetPercent: Float, readyAt: ContinuousClock.Instant)?
    }

    @ObservationIgnored private var applied = AppliedNodes()
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var transitionID = 0

    private var compressorTarget: CompressorTransitionPolicy.Parameters {
        CompressorTransitionPolicy.target(
            enabled: compressorIsActive,
            threshold: compressorThreshold,
            headRoom: compressorHeadRoom,
            gain: compressorMasterGain
        )
    }

    private var reverbTargetHeadroomDB: Float {
        guard reverbIsActive else { return 0 }
        return ReverbTransitionPolicy.headroomDB(
            presetRawValue: reverbPreset.avPreset.rawValue,
            wetPercent: reverbWetDryMix
        )
    }

    private func scheduleNodeUpdate() {
        guard audioEngine.compressorNode != nil, transitionTask == nil else { return }
        transitionID &+= 1
        let id = transitionID
        transitionTask = Task { [weak self] in
            await self?.runTransition(id: id)
        }
    }

    private func cancelTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionID &+= 1
    }

    private func runTransition(id: Int) async {
        defer { if transitionID == id { transitionTask = nil } }
        while !Task.isCancelled, let compressor = audioEngine.compressorNode {
            if compressor !== applied.compressor {
                // 没经过 applySettings 的新图:压缩器是 AudioEngine 设的不压缩参数,混响旁通、
                // 湿声静音、余量为 0,还没装房间。
                applied = AppliedNodes(compressor: compressor)
            }
            let compressorDone = stepCompressor()
            let reverbDone = stepReverb(now: .now)
            if compressorDone, reverbDone { return }
            try? await Task.sleep(for: .seconds(CompressorTransitionPolicy.tickInterval))
        }
    }

    /// 压缩器走一步;到位了返回 true。
    private func stepCompressor() -> Bool {
        writeCompressorTiming()
        let target = compressorTarget
        let next = CompressorTransitionPolicy.step(from: applied.compressorParameters, toward: target)
        if next != applied.compressorParameters { writeCompressor(next) }
        return next == target
    }

    /// 混响走一步;没有要等的了返回 true。
    private func stepReverb(now: ContinuousClock.Instant) -> Bool {
        guard let reverb = audioEngine.reverbNode else { return true }
        let settle = Duration.seconds(EqualizerHeadroomPolicy.lowerSettleDelay(
            ioBufferDuration: audioEngine.outputIOBufferDuration
        ))
        func settled(_ instant: ContinuousClock.Instant?) -> Bool {
            instant.map { $0.duration(to: now) >= settle } ?? true
        }

        // 换房间:湿声那一路先渐渐静音,静下来再换,混响尾巴不会硬切。
        if applied.reverbPreset != reverbPreset {
            if applied.reverbWetPercent > 0 {
                applied.pendingWetRise = nil
                setReverbMix(stepWet(toward: 0), at: now)
                return false
            }
            guard settled(applied.reverbWetChangedAt) else { return false }
            reverb.loadFactoryPreset(reverbPreset.avPreset)
            reverb.wetDryMix = 100
            applied.reverbPreset = reverbPreset
        }

        let targetWet = reverbIsActive ? reverbWetDryMix : 0
        let targetHeadroom = reverbTargetHeadroomDB
        if targetWet < applied.reverbWetPercent {
            applied.pendingWetRise = nil
            setReverbMix(stepWet(toward: targetWet), at: now)
            return false
        } else if targetWet > applied.reverbWetPercent {
            if let rise = applied.pendingWetRise {
                guard now >= rise.readyAt else { return false }
                if applied.reverbBypassed {
                    // 湿声那一路还是静音的,这时取消旁通听不出来。
                    reverb.bypass = false
                    applied.reverbBypassed = false
                }
                let reach = min(rise.wetPercent, targetWet)
                setReverbMix(stepWet(toward: reach), at: now)
                if applied.reverbWetPercent >= reach { applied.pendingWetRise = nil }
                return false
            }
            // 余量先压到这次要升到的湿度,压下去之后再升湿声;拖动中又升了,下一轮接着来。
            if targetHeadroom > applied.reverbHeadroomDB {
                setReverbHeadroom(targetHeadroom, at: now)
            }
            let readyAt = applied.reverbHeadroomLoweredAt.map { max(now, $0 + settle) } ?? now
            applied.pendingWetRise = (targetWet, readyAt)
            return false
        }

        // 余量加大马上做;放回要等湿声降下来之后。
        if targetHeadroom > applied.reverbHeadroomDB {
            setReverbHeadroom(targetHeadroom, at: now)
        } else if targetHeadroom < applied.reverbHeadroomDB {
            guard settled(applied.reverbWetChangedAt) else { return false }
            setReverbHeadroom(targetHeadroom, at: now)
        }

        // 关着:湿声静下来后旁通,省掉混响的运算。
        if !reverbIsActive, !applied.reverbBypassed {
            guard settled(applied.reverbWetChangedAt) else { return false }
            reverb.bypass = true
            applied.reverbBypassed = true
        }
        return true
    }

    private func stepWet(toward target: Float) -> Float {
        let current = applied.reverbWetPercent
        let step = ReverbTransitionPolicy.wetStepPercent
        return target > current ? min(target, current + step) : max(target, current - step)
    }

    private func setReverbMix(_ wetPercent: Float, at now: ContinuousClock.Instant) {
        let gains = ReverbTransitionPolicy.mixGains(wetPercent: wetPercent)
        audioEngine.reverbDryGain = gains.dry
        audioEngine.reverbWetGain = gains.wet
        applied.reverbWetPercent = wetPercent
        applied.reverbWetChangedAt = now
    }

    private func setReverbHeadroom(_ decibels: Float, at now: ContinuousClock.Instant) {
        audioEngine.reverbHeadroomGain = Float(pow(10, Double(-decibels) / 20))
        if decibels > applied.reverbHeadroomDB { applied.reverbHeadroomLoweredAt = now }
        applied.reverbHeadroomDB = decibels
    }

    private func writeCompressor(_ parameters: CompressorTransitionPolicy.Parameters, force: Bool = false) {
        let current = applied.compressorParameters
        if force || parameters.threshold != current.threshold {
            setCompressorParam(kDynamicsProcessorParam_Threshold, value: parameters.threshold)
        }
        if force || parameters.headRoom != current.headRoom {
            setCompressorParam(kDynamicsProcessorParam_HeadRoom, value: parameters.headRoom)
        }
        if force || parameters.gain != current.gain {
            setCompressorParam(kDynamicsProcessorParam_OverallGain, value: parameters.gain)
        }
        applied.compressorParameters = parameters
    }

    /// 起音、释放时间不直接改电平,照设置写。
    private func writeCompressorTiming() {
        if applied.attackTime != compressorAttackTime {
            setCompressorParam(kDynamicsProcessorParam_AttackTime, value: compressorAttackTime)
            applied.attackTime = compressorAttackTime
        }
        if applied.releaseTime != compressorReleaseTime {
            setCompressorParam(kDynamicsProcessorParam_ReleaseTime, value: compressorReleaseTime)
            applied.releaseTime = compressorReleaseTime
        }
    }

    // MARK: - AudioUnit Parameter Helpers

    private func setCompressorParam(_ param: AudioUnitParameterID, value: Float) {
        guard let audioUnit = audioEngine.compressorNode?.audioUnit else { return }
        let status = AudioUnitSetParameter(audioUnit, param, kAudioUnitScope_Global, 0, value, 0)
        if status != noErr {
            plog("⚠️ AudioEffects: failed to set compressor param \(param) = \(value), OSStatus = \(status)")
        }
    }
}
