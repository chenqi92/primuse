import AudioToolbox
import AVFoundation
import CoreMotion
import Foundation
import PrimuseKit

/// Which of the two player nodes a scheduling call addresses.
enum PlayerNodeRole: Sendable {
    case primary
    case crossfade
}

/// Lock-protected owner of the two player nodes and their scheduled-frame
/// timelines.
///
/// The decode pumps are moving off the main actor, so they can no longer reach
/// `AudioEngine`'s isolated storage for every decoded buffer. The registry keeps
/// the node reference and its timeline together behind one lock, which is the
/// pair that has to stay consistent: a boundary token is only meaningful if the
/// timeline recorded the buffer in the same order the node enqueued it.
///
/// `AVAudioPlayerNode.scheduleBuffer` is itself thread-safe. The lock is held
/// across the enqueue purely to keep node order and timeline order identical
/// when the main actor and a pump schedule onto the same role.
final class PlayerNodeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var primaryNode: AVAudioPlayerNode?
    private var crossfadeNode: AVAudioPlayerNode?
    private var primaryTimeline = PlaybackTimelineTracker()
    private var crossfadeTimeline = PlaybackTimelineTracker()

    func attach(_ node: AVAudioPlayerNode?, to role: PlayerNodeRole) {
        lock.lock()
        switch role {
        case .primary: primaryNode = node
        case .crossfade: crossfadeNode = node
        }
        lock.unlock()
    }

    func node(for role: PlayerNodeRole) -> AVAudioPlayerNode? {
        lock.lock()
        defer { lock.unlock() }
        return role == .primary ? primaryNode : crossfadeNode
    }

    /// Rotates both nodes and both timelines together after a crossfade, so the
    /// incoming node keeps the frame cursor it accumulated while fading in.
    func swapRoles() {
        lock.lock()
        swap(&primaryNode, &crossfadeNode)
        swap(&primaryTimeline, &crossfadeTimeline)
        lock.unlock()
    }

    func resetTimeline(for role: PlayerNodeRole) {
        lock.lock()
        switch role {
        case .primary: primaryTimeline.reset()
        case .crossfade: crossfadeTimeline.reset()
        }
        lock.unlock()
    }

    @discardableResult
    func schedule(
        _ buffer: AVAudioPCMBuffer,
        on role: PlayerNodeRole
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = role == .primary ? primaryNode : crossfadeNode else { return nil }
        node.scheduleBuffer(buffer)
        return record(frames: Int64(buffer.frameLength), on: role)
    }

    @discardableResult
    func schedule(
        _ buffer: AVAudioPCMBuffer,
        on role: PlayerNodeRole,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = role == .primary ? primaryNode : crossfadeNode else { return nil }
        node.scheduleBuffer(
            buffer,
            completionCallbackType: completionCallbackType,
            completionHandler: completionHandler
        )
        return record(frames: Int64(buffer.frameLength), on: role)
    }

    @discardableResult
    func commitBoundary(
        _ token: PlaybackTimelineTracker.BoundaryToken,
        on role: PlayerNodeRole
    ) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        switch role {
        case .primary: return primaryTimeline.commitBoundary(token)
        case .crossfade: return crossfadeTimeline.commitBoundary(token)
        }
    }

    /// Caller must already hold `lock`.
    private func record(
        frames: Int64,
        on role: PlayerNodeRole
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        switch role {
        case .primary: return primaryTimeline.recordScheduledFrames(frames)
        case .crossfade: return crossfadeTimeline.recordScheduledFrames(frames)
        }
    }
}

@MainActor
@Observable
final class AudioEngine {
    private let volumeDefaults: UserDefaults
    private var requestedVolume: Float = 1
    /// 直通图这一刻搬的是不是 DoP/DSD 码流。DSD 的样本里装的是 1bit 码流，
    /// 乘任何系数都会变成噪声，所以这种图不能加增益。
    private(set) var usesDSDCarrier = false
    #if os(macOS)
    /// 直通图上一次写应用级输出音量是否成功。
    private(set) var directOutputVolumeIsSupported = false
    private let hardwareSampleRateNegotiator = HardwareSampleRateNegotiator()
    #endif
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var crossfadePlayerNode: AVAudioPlayerNode?
    private var playerMixer: AVAudioMixerNode?  // Mixes the spatial output before EQ
    private var environmentNode: AVAudioEnvironmentNode?
    private(set) var eqNode: AVAudioUnitEQ?
    private(set) var compressorNode: AVAudioUnitEffect?
    private(set) var reverbNode: AVAudioUnitReverb?
    /// 用于变速 (rate) + 保持音调 (overlap)。1.0 时基本无开销, 用户改速度
    /// 时调它的 .rate 即可, engine graph 不需要 reconfigure。
    private(set) var timePitchNode: AVAudioUnitTimePitch?
    /// 卡拉OK人声消除, 夹在播放混音器和 EQ 之间, 淡入淡出/无缝衔接的两路
    /// 已经混成一路再处理。关闭时渲染里直接透传, 没有延迟。
    private var karaokeVocalNode: AVAudioUnitEffect?
    /// 跨图重建保留的卡拉OK开关与回读状态, 渲染线程只读它。
    nonisolated let karaokeControl = KaraokeRenderControl()
    /// 卡拉OK升降调(音分)。只在卡拉OK开着时非零, 图重建后要重新套上。
    private var karaokePitchCents: Float = 0

    private(set) var isPlaying = false
    var isActuallyPlaying: Bool {
        engine?.isRunning == true && playerNode?.isPlaying == true
    }
    private(set) var outputFormat: AVAudioFormat?
    private(set) var spatialAudioEnabled = false
    private(set) var spatialHeadTrackingEnabled = false
    private(set) var outputMode: AudioOutputMode = .effects

    private var isSetUp = false
    private var playbackClockReadsSuspended = true
    /// Owns both player nodes and their scheduled-frame timelines so decode
    /// pumps can schedule without hopping back to the main actor.
    nonisolated let nodeRegistry = PlayerNodeRegistry()
    private var directSourceFormat: AVAudioFormat?
    private var hardwareConfigurationRecoveryState = AudioHardwareConfigurationRecoveryState()
    #if os(macOS)
    /// A pinned route must be applied to AUHAL before graph formats are read.
    private var pendingGraphOutputDeviceID: AudioDeviceID?
    #endif
    private var headphoneMotionManager: CMHeadphoneMotionManager?
    private var transportFadeTask: Task<Void, Never>?
    private var transportFadeRestoreVolume: Float?
    /// The primary node's steady-state volume: unity, or the ReplayGain volume
    /// of the song it started playing. Transport fades and crossfade ramps move
    /// the node away from it and come back to it. Gapless successors keep it
    /// and carry their own gain in their samples instead.
    private(set) var primaryProgramVolume: Float = 1

    private static let transportFadeStepCount = 6
    private static let transportFadeStepDuration: Duration = .milliseconds(8)

    private var engineIdleShutdownTask: Task<Void, Never>?
    /// How long the render graph stays live after a transport pause: long
    /// enough for the effect chain to drain its tail, and for a quick
    /// Play/Pause reversal to reuse the live graph. It must stay short —
    /// iOS derives the Control Center / lock screen play-pause glyph from
    /// whether the app's audio IO is still running, not from the published
    /// playback rate, so a running engine keeps showing Pause after a pause.
    private static let engineIdleShutdownDelay: Duration = .milliseconds(300)

    /// DLNA 后台保活用 ── 喂一段 -90 dB 的极小振幅 buffer 让 iOS audio
    /// background mode 不挂起进程, NWListener 才能持续接 SSDP / control 请求。
    /// 真歌在播时主路径已经撑住 session, 这两个 nil; 真歌停 + DLNA 后台保活
    /// 开启时挂上去。开关由 DLNARendererService 调度。
    private var keepAlivePlayerNode: AVAudioPlayerNode?
    private var keepAliveBuffer: AVAudioPCMBuffer?
    /// A separate minimal graph keeps DLNA control sockets alive while the
    /// selected playback graph is DSP-free. It never changes or connects a
    /// mixer into the high-fidelity playback engine.
    private var standaloneKeepAliveEngine: AVAudioEngine?

    /// Sample time offset for gapless track transitions.
    /// When gapless transitions happen without stopping the playerNode,
    /// this tracks the cumulative sample offset so currentTime resets to 0.
    var sampleTimeOffset: Int64 = 0

    init(volumeDefaults: UserDefaults = .standard) {
        self.volumeDefaults = volumeDefaults
        #if !os(iOS)
        let saved = volumeDefaults.object(forKey: Self.volumeKey) as? Float ?? 1
        requestedVolume = saved.isFinite ? min(max(saved, 0), 1) : 1
        #endif
    }

    // MARK: - Setup

    /// Selects the render graph used for the next playback session.
    ///
    /// High-fidelity mode connects the primary player straight to the output
    /// node; volume rides on the output unit's own application gain instead of
    /// a mixer, so the signal stays untouched at full volume. The effects graph
    /// retains the spatial, EQ, dynamics, reverb, rate, crossfade and
    /// visualizer chain.
    func configure(
        outputMode: AudioOutputMode,
        directSourceFormat: AVAudioFormat? = nil,
        isDSDCarrier: Bool = false
    ) throws {
        let normalizedDirectFormat = outputMode == .highFidelity ? directSourceFormat : nil
        let normalizedDSDCarrier = outputMode == .highFidelity && isDSDCarrier
        let formatChanged: Bool = {
            switch (self.directSourceFormat, normalizedDirectFormat) {
            case (nil, nil): false
            case let (lhs?, rhs?): lhs != rhs
            default: true
            }
        }()
        guard self.outputMode != outputMode
                || formatChanged
                || self.usesDSDCarrier != normalizedDSDCarrier
                || !isSetUp
                || hardwareConfigurationRecoveryState.requiresGraphRebuild else { return }

        #if os(macOS)
        let wasFollowingSystem = followsSystemOutput
        let previousDevice = wasFollowingSystem ? nil : currentOutputDeviceID
        #endif

        tearDownGraph()
        self.outputMode = outputMode
        self.directSourceFormat = normalizedDirectFormat
        self.usesDSDCarrier = normalizedDSDCarrier
        #if os(macOS)
        pendingGraphOutputDeviceID = previousDevice
        defer { pendingGraphOutputDeviceID = nil }
        #endif
        try setUp()
        hardwareConfigurationRecoveryState.graphRebuiltSuccessfully()
    }

    /// Called from the player after AVAudioEngine reports a hardware change.
    /// The actual teardown happens later in `configure`, never on the engine's
    /// internal notification queue.
    func markHardwareConfigurationChanged() {
        hardwareConfigurationRecoveryState.configurationChanged()
        // 换设备 / 换采样率会重建输出单元，应用音量得重新写一遍，
        // 否则换完输出音量悄悄回到满格。
        applyRequestedVolumeToGraph()
    }

    private func tearDownGraph() {
        cancelTransportFade(restoreVolume: false)
        cancelEngineIdleShutdown()
        stopSilenceKeepAlive()
        nodeRegistry.resetTimeline(for: .primary)
        nodeRegistry.resetTimeline(for: .crossfade)
        playerNode?.stop()
        crossfadePlayerNode?.stop()
        engine?.stop()
        stopSpatialHeadTracking()
        engine = nil
        playerNode = nil
        nodeRegistry.attach(nil, to: .primary)
        crossfadePlayerNode = nil
        nodeRegistry.attach(nil, to: .crossfade)
        playerMixer = nil
        environmentNode = nil
        eqNode = nil
        compressorNode = nil
        reverbNode = nil
        timePitchNode = nil
        karaokeVocalNode = nil
        outputFormat = nil
        #if os(macOS)
        directOutputVolumeIsSupported = false
        #endif
        isSetUp = false
        isPlaying = false
        playbackClockReadsSuspended = true
        sampleTimeOffset = 0
    }

    func setUp() throws {
        guard !isSetUp else { return }

        nodeRegistry.resetTimeline(for: .primary)
        nodeRegistry.resetTimeline(for: .crossfade)

        let eng = AVAudioEngine()
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()

        #if os(macOS)
        if let pendingGraphOutputDeviceID {
            try Self.applyOutputDevice(pendingGraphOutputDeviceID, to: eng)
        }
        #endif

        if outputMode == .highFidelity {
            eng.attach(playerA)
            eng.attach(playerB)

            var format = directSourceFormat ?? eng.outputNode.inputFormat(forBus: 0)
            if format.sampleRate == 0 || format.channelCount == 0 {
                format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            }

            // No mixer and no audio unit in this graph. Integer DoP buffers can
            // also use this path when the hardware sample rate is compatible.
            eng.connect(playerA, to: eng.outputNode, format: format)
            playerA.volume = 1
            playerB.volume = 0

            self.engine = eng
            self.playerNode = playerA
            self.crossfadePlayerNode = playerB
            nodeRegistry.attach(playerA, to: .primary)
            nodeRegistry.attach(playerB, to: .crossfade)
            self.outputFormat = format
            self.isSetUp = true
            spatialAudioEnabled = false
            spatialHeadTrackingEnabled = false
            applyRequestedVolumeToGraph()
            return
        }

        let mixer = AVAudioMixerNode()
        let environment = AVAudioEnvironmentNode()
        let eq = AVAudioUnitEQ(numberOfBands: PrimuseConstants.eqBandCount)
        let compressorDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let compressor = AVAudioUnitEffect(audioComponentDescription: compressorDesc)
        let reverb = AVAudioUnitReverb()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = 1.0
        timePitch.pitch = karaokePitchCents
        // overlap 默认 8.0, 提高到 16 让 0.5x / 2.0x 极端速度声音更稳;
        // 1.0x 时该节点几乎是 passthrough, 不会有副作用。
        timePitch.overlap = 16.0

        for (index, frequency) in PrimuseConstants.eqBandFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = PrimuseConstants.eqDefaultBandwidth
            band.gain = 0
            band.bypass = false
        }

        // Compressor — bypassed until user enables; parameters set by AudioEffectsService
        compressor.bypass = true

        // Reverb — bypassed until user enables; parameters set by AudioEffectsService
        reverb.bypass = true

        eng.attach(playerA)
        eng.attach(playerB)
        eng.attach(environment)
        eng.attach(mixer)
        eng.attach(eq)
        eng.attach(compressor)
        eng.attach(reverb)
        eng.attach(timePitch)
        let karaokeVocal = KaraokeVocalReducerUnit.makeNode(control: karaokeControl)
        if let karaokeVocal {
            eng.attach(karaokeVocal)
        }

        let mainMixer = eng.mainMixerNode
        var format = mainMixer.outputFormat(forBus: 0)

        if format.sampleRate == 0 || format.channelCount == 0 {
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        }

        // Signal chain: playerA/B → Spatial Environment → mixer → (Karaoke) → EQ → Compressor → Reverb → TimePitch → mainMixer → output
        // TimePitch 放最后一站, 让 EQ / 压缩 / 混响 都在原速下处理,
        // visualizer 仍挂 mainMixer 拿到变速后的最终输出。
        eng.connect(playerA, to: environment, format: format)
        eng.connect(playerB, to: environment, format: format)
        eng.connect(environment, to: mixer, format: format)
        if let karaokeVocal {
            eng.connect(mixer, to: karaokeVocal, format: format)
            eng.connect(karaokeVocal, to: eq, format: format)
        } else {
            eng.connect(mixer, to: eq, format: format)
        }
        eng.connect(eq, to: compressor, format: format)
        eng.connect(compressor, to: reverb, format: format)
        eng.connect(reverb, to: timePitch, format: format)
        eng.connect(timePitch, to: mainMixer, format: format)

        playerB.volume = 0 // crossfade node starts silent

        self.engine = eng
        self.playerNode = playerA
        self.crossfadePlayerNode = playerB
        // Fresh nodes play at unity; the caller re-applies ReplayGain.
        primaryProgramVolume = 1
        nodeRegistry.attach(playerA, to: .primary)
        nodeRegistry.attach(playerB, to: .crossfade)
        self.playerMixer = mixer
        self.environmentNode = environment
        self.eqNode = eq
        self.compressorNode = compressor
        self.reverbNode = reverb
        self.timePitchNode = timePitch
        self.karaokeVocalNode = karaokeVocal
        self.outputFormat = format
        self.isSetUp = true
        applySpatialAudioConfiguration()
        restoreVolume()
        // 注意: 不要在这里把 output unit 钉到任何设备。新建的 AVAudioEngine
        // 默认就跟随系统默认输出设备(并随系统切换而切换), 这正是「跟随系统」
        // 想要的行为。之前在此调用 restoreOutputRouting() 把 CurrentDevice 设成
        // kAudioObjectUnknown(0), 反而让 AUHAL 失去有效设备, engine 启动直接报
        // -10875, 所有播放(本地/NAS/云盘)全部失败。
    }

    // MARK: - Engine Control

    func start() throws {
        cancelEngineIdleShutdown()
        try setUp()
        applySpatialAudioConfiguration()
        guard let engine, !engine.isRunning else { return }
        flushEffectChain()
        try engine.start()
        applyRequestedVolumeToGraph()
    }

    func stop() {
        cancelEngineIdleShutdown()
        playbackClockReadsSuspended = true
        nodeRegistry.resetTimeline(for: .primary)
        nodeRegistry.resetTimeline(for: .crossfade)
        sampleTimeOffset = 0
        playerNode?.stop()
        crossfadePlayerNode?.stop()
        engine?.stop()
        stopSpatialHeadTracking()
        isPlaying = false
    }

    // MARK: - Hardware format negotiation

    /// Requests a hardware sample rate and returns the rate actually reported
    /// by the active output. Core Audio and AVAudioSession are allowed to
    /// reject the request, so callers must compare the return value before
    /// enabling DoP or claiming a sample-rate-matched path. On macOS a
    /// successful write is asynchronous: wait for HAL confirmation first.
    @discardableResult
    func prepareHardwareSampleRate(_ targetHz: Double) async throws -> Double {
        try Task.checkCancellation()
        guard targetHz >= 8_000, targetHz <= 384_000 else {
            return currentHardwareSampleRate
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let currentRate = session.sampleRate
        if DirectPCMOutputSampleRatePolicy.shouldRequestNominalSampleRateChange(
            requestedSampleRate: targetHz,
            currentHardwareSampleRate: currentRate,
            propertyIsSettable: true,
            requestedRateIsSupported: nil,
            isSystemManagedWirelessOutput: AudioSessionManager.shared
                .outputRouteIsSystemManagedWireless
        ) {
            _ = AudioSessionManager.shared.setPreferredSampleRate(targetHz)
        }
        return session.sampleRate
        #elseif os(macOS)
        guard let deviceID = hardwareOutputDeviceID else {
            return 0
        }
        let currentRate = Self.nominalSampleRate(deviceID: deviceID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        let propertyIsSettable = AudioObjectIsPropertySettable(
            deviceID, &address, &settable
        ) == noErr && settable.boolValue
        let shouldRequestChange = DirectPCMOutputSampleRatePolicy
            .shouldRequestNominalSampleRateChange(
                requestedSampleRate: targetHz,
                currentHardwareSampleRate: currentRate,
                propertyIsSettable: propertyIsSettable,
                requestedRateIsSupported: Self.availableNominalSampleRates(deviceID: deviceID)?
                    .contains { range in
                        targetHz >= range.mMinimum && targetHz <= range.mMaximum
                    },
                isSystemManagedWirelessOutput: Self.isSystemManagedWirelessOutput(
                    deviceID: deviceID
                )
            )
        guard shouldRequestChange else { return currentRate }
        let startedAt = ContinuousClock.now
        plog("🎧 Hardware rate request device=\(deviceID) current=\(currentRate) target=\(targetHz)")
        let result = try await hardwareSampleRateNegotiator.prepare(
            targetSampleRate: targetHz,
            deviceID: deviceID,
            readSnapshot: { [self] in
                guard let activeDevice = hardwareOutputDeviceID,
                      Self.deviceIsAlive(activeDevice) else { return nil }
                let rate = Self.nominalSampleRate(deviceID: activeDevice)
                guard rate.isFinite, rate > 0 else { return nil }
                return .init(deviceID: activeDevice, sampleRate: rate)
            },
            observe: { [self] callback in
                try Self.observeHardwareSampleRate(
                    deviceID: deviceID,
                    followsSystem: followsSystemOutput,
                    callback: callback
                )
            },
            requestChange: {
                var rate = targetHz
                let status = AudioObjectSetPropertyData(
                    deviceID, &address, 0, nil,
                    UInt32(MemoryLayout<Double>.size), &rate
                )
                if status != noErr {
                    plog("⚠️ Core Audio rejected sample rate \(targetHz) (status=\(status))")
                }
                return status == noErr
            }
        )
        try Task.checkCancellation()
        let actual = result.snapshot?.sampleRate ?? 0
        plog("🎧 Hardware rate settled device=\(result.snapshot?.deviceID ?? 0) target=\(targetHz) actual=\(actual) result=\(result.reason.rawValue) elapsed=\(startedAt.duration(to: .now))")
        return actual
        #else
        return currentHardwareSampleRate
        #endif
    }

    func cancelHardwareSampleRatePreparation() {
        #if os(macOS)
        hardwareSampleRateNegotiator.cancel()
        #endif
    }

    #if os(macOS)
    /// Notifications queued by a graph that has already been replaced must
    /// not stop its successor or seek the newly selected song.
    func ownsConfigurationChange(from engineID: ObjectIdentifier?) -> Bool {
        guard let engine, let engineID else { return false }
        return ObjectIdentifier(engine) == engineID
    }

    private var hardwareOutputDeviceID: AudioDeviceID? {
        if followsSystemOutput { return Self.systemDefaultOutputDeviceID() }
        return currentOutputDeviceID ?? Self.systemDefaultOutputDeviceID()
    }
    #endif

    var currentHardwareSampleRate: Double {
        #if os(iOS)
        return AVAudioSession.sharedInstance().sampleRate
        #elseif os(macOS)
        guard let deviceID = hardwareOutputDeviceID else { return 0 }
        return Self.nominalSampleRate(deviceID: deviceID)
        #else
        return outputFormat?.sampleRate ?? 0
        #endif
    }

    /// Builds the PCM format used by the DSP-free graph for a source sample
    /// rate. The channel count follows the active output route; unlike the
    /// sample rate it is not persisted on `Song`.
    func directPCMFormat(sampleRate: Double) -> AVAudioFormat? {
        guard sampleRate >= DirectPCMOutputSampleRatePolicy.minimumSampleRate,
              sampleRate <= DirectPCMOutputSampleRatePolicy.maximumSampleRate else {
            return nil
        }
        let routeChannels = engine?.outputNode.inputFormat(forBus: 0).channelCount
            ?? outputFormat?.channelCount
            ?? 2
        return AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: max(1, routeChannels)
        )
    }

    func hardwareSupportsDirectFormat(_ format: AVAudioFormat) -> Bool {
        DirectPCMOutputSampleRatePolicy.hardwareMatches(
            requestedSampleRate: format.sampleRate,
            actualHardwareSampleRate: currentHardwareSampleRate
        )
    }

    // MARK: - Output device routing (macOS only)

    #if os(macOS)
    private static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != AudioDeviceID(kAudioObjectUnknown) ? id : nil
    }

    private static func nominalSampleRate(deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }

    private static func availableNominalSampleRates(
        deviceID: AudioDeviceID
    ) -> [AudioValueRange]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &dataSize
        ) == noErr, dataSize >= MemoryLayout<AudioValueRange>.size else {
            return nil
        }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: Int(dataSize) / MemoryLayout<AudioValueRange>.size
        )
        let status = ranges.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, bytes.baseAddress!
            )
        }
        return status == noErr ? ranges : nil
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr
            && alive != 0
    }

    private static func isSystemManagedWirelessOutput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport
        ) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeAirPlay
            || transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func observeHardwareSampleRate(
        deviceID: AudioDeviceID,
        followsSystem: Bool,
        callback: @escaping @Sendable (HardwareSampleRateNegotiator.Event) -> Void
    ) throws -> @MainActor () -> Void {
        let queue = DispatchQueue(label: "com.primuse.hardware-sample-rate")
        var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        func removeListeners() {
            for (object, address, listener) in registrations {
                var address = address
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            }
        }
        var properties: [(AudioObjectID, AudioObjectPropertySelector, HardwareSampleRateNegotiator.Event)] = [
            (deviceID, kAudioDevicePropertyNominalSampleRate, .sampleRateChanged),
            (deviceID, kAudioDevicePropertyDeviceIsAlive, .deviceChanged),
        ]
        if followsSystem {
            properties.append((
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyDefaultOutputDevice,
                .deviceChanged
            ))
        }
        do {
            for (object, selector, event) in properties {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let listener: AudioObjectPropertyListenerBlock = { _, _ in callback(event) }
                let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
                guard status == noErr else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
                registrations.append((object, address, listener))
            }
        } catch {
            removeListeners()
            plog("⚠️ Cannot observe hardware rate changes; keeping the current format: \(error)")
            throw error
        }
        return { removeListeners() }
    }

    private static func applyOutputDevice(
        _ deviceID: AudioDeviceID,
        to engine: AVAudioEngine
    ) throws {
        guard let outputUnit = engine.outputNode.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: String(localized: "audio_output_error_set_device %d"),
                    status
                )
            ])
        }
    }

    /// 把这个 app 的音频输出切到指定的 Core Audio 设备。系统默认输出
    /// 不变 —— 这只影响 Primuse 自己。设备 ID 来自 AudioOutputDeviceManager,
    /// 通常对应内置扬声器、AirPlay 接收器(HomePod / Apple TV)、蓝牙
    /// 耳机等。设备拔掉后会自动回退到系统默认。
    func setOutputDevice(deviceID: AudioDeviceID) throws {
        try setUp()
        guard let engine else { return }
        try Self.applyOutputDevice(deviceID, to: engine)
        // 显式钉到了某设备, 退出跟随系统状态并持久化。
        UserDefaults.standard.set(false, forKey: Self.followsSystemKey)
        markHardwareConfigurationChanged()
    }

    /// 让 Primuse 回到「跟随系统默认输出」—— 用户之前用 picker 钉死过某台设备
    /// (applyDevice 把 CurrentDevice 设成了具体 id)后, 点「跟随系统」把 output
    /// unit 重新指向**当前系统默认输出设备的真实 id**。
    ///
    /// ⚠️ 不能把 CurrentDevice 设成 kAudioObjectUnknown(0): 那不是「跟随默认」,
    /// 而是让 AUHAL 失去有效设备, engine 启动直接报 -10875、所有播放失败。
    func followSystemOutput() throws {
        try setUp()
        UserDefaults.standard.set(true, forKey: Self.followsSystemKey)
        guard let engine, let outputUnit = engine.outputNode.audioUnit else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID
        )
        // 取不到真实默认设备就别动 output unit, 维持 AUHAL 既有(默认)路由。
        guard getStatus == noErr, defaultID != AudioDeviceID(kAudioObjectUnknown) else { return }

        var id = defaultID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: String(localized: "audio_output_error_follow_system %d"),
                    status
                )
            ])
        }
        markHardwareConfigurationChanged()
    }

    /// 用户上次是否选了「跟随系统」。默认 true(从未显式钉过设备就是跟随)。
    var followsSystemOutput: Bool {
        UserDefaults.standard.object(forKey: Self.followsSystemKey) as? Bool ?? true
    }

    private static let followsSystemKey = "primuse_output_follows_system"

    /// 取当前 audio unit 在用的设备 ID,用于在 picker 里高亮当前选中项。
    var currentOutputDeviceID: AudioDeviceID? {
        guard let engine, let outputUnit = engine.outputNode.audioUnit else { return nil }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            &size
        )
        return status == noErr ? id : nil
    }
    #endif

    // MARK: - DLNA Background Keep-Alive (主要 iOS 用; macOS 没 background
    // suspend 问题, 但 API 保留跨平台一致, 调用方一律可用)

    /// 启动一个静音 AVAudioPlayerNode 喂极小振幅 buffer ── 让 iOS 的
    /// audio background mode 把 app 标记为 "正在播音频", 进程不被 suspend,
    /// NWListener / POSIX socket 才能在后台继续接 SSDP / control 请求。
    ///
    /// 振幅用 1/32768 (-90 dB FS, 已经在 16-bit 量化噪声以下), 用户听不到。
    /// 用交替正负避免全 0 buffer 被 iOS 静音检测当成"没在播"。
    func startSilenceKeepAlive() {
        guard keepAlivePlayerNode == nil else { return }
        let keepAliveEngine: AVAudioEngine
        let mainMixer: AVAudioMixerNode
        if outputMode == .effects {
            do { try setUp() } catch {
                plog("⚠️ AudioEngine keepAlive setUp failed: \(error.localizedDescription)")
                return
            }
            guard let engine else { return }
            keepAliveEngine = engine
            mainMixer = engine.mainMixerNode
        } else {
            // Do not materialize mainMixerNode in the direct playback graph.
            // A tiny independent engine owns the silent loop instead.
            let engine = AVAudioEngine()
            keepAliveEngine = engine
            mainMixer = engine.mainMixerNode
            standaloneKeepAliveEngine = engine
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
            ?? mainMixer.outputFormat(forBus: 0)
        let frames: AVAudioFrameCount = 4_800   // 0.1s @ 48k
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        let amplitude: Float = 1.0 / 32_768
        if let channelData = buffer.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                for i in 0..<Int(frames) {
                    channelData[ch][i] = (i % 2 == 0) ? amplitude : -amplitude
                }
            }
        }

        let node = AVAudioPlayerNode()
        keepAliveEngine.attach(node)
        keepAliveEngine.connect(node, to: mainMixer, format: format)
        node.volume = 0.001

        if !keepAliveEngine.isRunning {
            do { try keepAliveEngine.start() } catch {
                plog("⚠️ AudioEngine keepAlive engine.start failed: \(error.localizedDescription)")
                keepAliveEngine.detach(node)
                standaloneKeepAliveEngine = nil
                return
            }
        }

        node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        guard startPlayerNode(node) else {
            plog("⚠️ AudioEngine keepAlive node start rejected")
            keepAliveEngine.detach(node)
            standaloneKeepAliveEngine = nil
            return
        }
        keepAlivePlayerNode = node
        keepAliveBuffer = buffer
        plog("🛡 AudioEngine silence keepAlive ON")
    }

    func stopSilenceKeepAlive() {
        guard let node = keepAlivePlayerNode else { return }
        node.stop()
        if let standaloneKeepAliveEngine {
            standaloneKeepAliveEngine.stop()
            standaloneKeepAliveEngine.detach(node)
            self.standaloneKeepAliveEngine = nil
        } else {
            engine?.detach(node)
        }
        keepAlivePlayerNode = nil
        keepAliveBuffer = nil
        plog("🛡 AudioEngine silence keepAlive OFF")
    }

    // MARK: - Buffer Scheduling (Primary Node)

    @discardableResult
    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(buffer, on: .primary)
    }

    /// Schedule buffer with completion callback — use `.dataPlayedBack` for precise track-end detection.
    @discardableResult
    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(
            buffer,
            on: .primary,
            completionCallbackType: completionCallbackType,
            completionHandler: completionHandler
        )
    }

    // MARK: - Buffer Scheduling (Crossfade Node)

    @discardableResult
    func scheduleCrossfadeBuffer(
        _ buffer: AVAudioPCMBuffer
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(buffer, on: .crossfade)
    }

    @discardableResult
    func scheduleCrossfadeBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(
            buffer,
            on: .crossfade,
            completionCallbackType: completionCallbackType,
            completionHandler: completionHandler
        )
    }

    // MARK: - Buffer Scheduling (off the main actor)

    /// Entry point for decode pumps that no longer run on the main actor.
    /// Same accounting as `scheduleBuffer`, without the isolation hop per buffer.
    @discardableResult
    nonisolated func scheduleDecodedBuffer(
        _ buffer: AVAudioPCMBuffer,
        on role: PlayerNodeRole,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(
            buffer,
            on: role,
            completionCallbackType: completionCallbackType,
            completionHandler: completionHandler
        )
    }

    @discardableResult
    nonisolated func scheduleDecodedBuffer(
        _ buffer: AVAudioPCMBuffer,
        on role: PlayerNodeRole
    ) -> PlaybackTimelineTracker.BoundaryToken? {
        nodeRegistry.schedule(buffer, on: role)
    }

    func playCrossfadeNode() {
        startPlayerNode(crossfadePlayerNode)
    }

    func stopCrossfadeNode() {
        nodeRegistry.resetTimeline(for: .crossfade)
        crossfadePlayerNode?.stop()
        crossfadePlayerNode?.reset()
    }

    // MARK: - Playback Control

    /// Starts a player node without letting AVFAudio terminate the app.
    ///
    /// `AVAudioPlayerNode.play()` raises an Objective-C exception when the
    /// graph is no longer running by the time the node starts, and an audio
    /// interruption or route change landing between the engine check and this
    /// call is enough to hit that window. Swift cannot catch it, so the start
    /// goes through the Objective-C shim and a rejected start comes back as
    /// `false` for the transport to report.
    @discardableResult
    private func startPlayerNode(_ node: AVAudioPlayerNode?) -> Bool {
        guard let node else { return false }
        return PrimuseStartPlayerNode(node)
    }

    @discardableResult
    func play() -> Bool {
        cancelTransportFade(restoreVolume: true)
        cancelEngineIdleShutdown()
        if engine == nil || !isSetUp {
            do { try setUp() } catch {
                plog("Failed to set up engine: \(error)")
                isPlaying = false
                return false
            }
        }
        guard let engine else {
            isPlaying = false
            return false
        }
        applySpatialAudioConfiguration()
        if !engine.isRunning {
            flushEffectChain()
            do { try engine.start() } catch {
                plog("Failed to start engine: \(error)")
                isPlaying = false
                return false
            }
        }
        if !startPlayerNode(playerNode), !engine.isRunning {
            // The graph stopped between the start above and the node start.
            // The audio is still scheduled on the node, so bring the engine
            // back once before giving up on this song.
            flushEffectChain()
            do { try engine.start() } catch {
                plog("Failed to restart engine after a rejected node start: \(error)")
                isPlaying = false
                playbackClockReadsSuspended = true
                return false
            }
            startPlayerNode(playerNode)
        }
        isPlaying = engine.isRunning && (playerNode?.isPlaying ?? false)
        playbackClockReadsSuspended = !isPlaying
        return isPlaying
    }

    func pause() {
        cancelTransportFade(restoreVolume: true)
        pauseImmediately()
    }

    /// Manual transport pauses use a short, cancellable envelope so a quick
    /// Play/Pause reversal never leaves a stale task muting or pausing the new
    /// command. The node's program volume (including ReplayGain) is restored
    /// while paused and reused as the target of the next fade-in.
    func pauseWithFade() {
        guard isActuallyPlaying, let playerNode else {
            pause()
            return
        }

        let targetVolume = transportFadeRestoreVolume ?? playerNode.volume
        let startVolume = playerNode.volume
        cancelTransportFade(restoreVolume: false)
        transportFadeRestoreVolume = targetVolume
        transportFadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...Self.transportFadeStepCount {
                do {
                    try await Task.sleep(for: Self.transportFadeStepDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(Self.transportFadeStepCount)
                self.playerNode?.volume = startVolume * Self.fadeOutGain(at: progress)
            }
            guard !Task.isCancelled else { return }
            self.pauseImmediately()
            // ReplayGain may have landed mid-fade and moved the target.
            self.playerNode?.volume = self.transportFadeRestoreVolume ?? targetVolume
            self.transportFadeRestoreVolume = nil
            self.transportFadeTask = nil
        }
    }

    private func pauseImmediately() {
        playbackClockReadsSuspended = true
        playerNode?.pause()
        crossfadePlayerNode?.pause()
        // Pausing every player node already silences the transport: the graph
        // keeps rendering, so the effect chain drains its own tail instead of
        // freezing it. The idle timer releases the hardware once the pause
        // turns out not to be a quick one.
        scheduleEngineIdleShutdown()
        isPlaying = false
    }

    @discardableResult
    func resume() -> Bool {
        cancelTransportFade(restoreVolume: true)
        return resumeImmediately()
    }

    /// Starts prepared local audio at the current transport volume and eases
    /// back to the program volume. Reversing a fade-out continues from its
    /// current level instead of producing a gain jump.
    @discardableResult
    func resumeWithFade() -> Bool {
        let wasPlaying = isActuallyPlaying
        let currentVolume = playerNode?.volume ?? 1
        let targetVolume = transportFadeRestoreVolume ?? currentVolume
        cancelTransportFade(restoreVolume: false)
        let startVolume: Float = wasPlaying ? currentVolume : 0
        playerNode?.volume = startVolume

        guard resumeImmediately() else {
            playerNode?.volume = targetVolume
            return false
        }

        transportFadeRestoreVolume = targetVolume
        transportFadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...Self.transportFadeStepCount {
                do {
                    try await Task.sleep(for: Self.transportFadeStepDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(Self.transportFadeStepCount)
                let liveTarget = self.transportFadeRestoreVolume ?? targetVolume
                self.playerNode?.volume = startVolume
                    + (liveTarget - startVolume) * Self.fadeInGain(at: progress)
            }
            guard !Task.isCancelled else { return }
            self.playerNode?.volume = self.transportFadeRestoreVolume ?? targetVolume
            self.transportFadeRestoreVolume = nil
            self.transportFadeTask = nil
        }
        return true
    }

    @discardableResult
    private func resumeImmediately() -> Bool {
        // After audio interruption (e.g. phone call, other app), the engine stops.
        // Restart it before resuming playback.
        cancelEngineIdleShutdown()
        applySpatialAudioConfiguration()
        if let engine, !engine.isRunning {
            flushEffectChain()
            do { try engine.start() } catch {
                plog("Failed to restart engine after interruption: \(error)")
                isPlaying = false
                return false
            }
        }
        guard let engine, engine.isRunning else {
            isPlaying = false
            return false
        }
        startPlayerNode(playerNode)
        if (crossfadePlayerNode?.volume ?? 0) > 0 {
            startPlayerNode(crossfadePlayerNode)
        }
        isPlaying = playerNode?.isPlaying ?? false
        playbackClockReadsSuspended = !isPlaying
        return isPlaying
    }

    func stopPlayback() {
        // A seek or song change: the karaoke stem lock and the vocal
        // remover's delay line both belong to the old position.
        karaokeControl.markDiscontinuity()
        cancelTransportFade(restoreVolume: true)
        playbackClockReadsSuspended = true
        nodeRegistry.resetTimeline(for: .primary)
        sampleTimeOffset = 0
        playerNode?.stop()
        playerNode?.reset()
        isPlaying = false
    }

    /// Restart the engine and player node if they were stopped (e.g. by a configuration change).
    @discardableResult
    func restartIfNeeded() -> Bool {
        cancelEngineIdleShutdown()
        guard let engine else {
            isPlaying = false
            return false
        }
        if !engine.isRunning {
            do {
                applySpatialAudioConfiguration()
                flushEffectChain()
                try engine.start()
            } catch {
                plog("Failed to restart engine: \(error)")
                isPlaying = false
                return false
            }
        }
        startPlayerNode(playerNode)
        isPlaying = engine.isRunning && (playerNode?.isPlaying ?? false)
        playbackClockReadsSuspended = !isPlaying
        return isPlaying
    }

    /// Prevents lifecycle callbacks from sampling a render clock whose engine
    /// may already have been stopped by AVFAudio. A successful play/resume
    /// re-enables reads after the node is running again.
    func suspendPlaybackClockReads() {
        playbackClockReadsSuspended = true
    }

    // MARK: - Playback Rate

    /// 设定播放速度倍率, 0.5x ~ 2.0x。AVAudioUnitTimePitch.rate 直接生效,
    /// 不用重启 engine。1.0 是 passthrough。pitch 保持 0 (不变调)。
    func applyPlaybackRate(_ rate: Float) {
        guard outputMode == .effects else { return }
        let clamped = max(0.5, min(2.0, rate))
        timePitchNode?.rate = clamped
    }

    // MARK: - Karaoke

    /// 效果图里有没有挂上人声消除单元(高保真直通图没有)。
    var supportsKaraokeVocalReduction: Bool {
        outputMode == .effects && karaokeVocalNode != nil
    }

    /// 升降调只作用在播放图上; 麦克风走自己的引擎, 不会被一起变调。
    func applyKaraokePitch(cents: Float) {
        karaokePitchCents = cents
        guard outputMode == .effects, let timePitchNode, timePitchNode.pitch != cents else { return }
        timePitchNode.pitch = cents
    }

    /// 渲染 → 扬声器的延迟, 录音对齐人声时要补上。
    var outputPresentationLatency: TimeInterval {
        engine?.outputNode.presentationLatency ?? 0
    }

    /// 录音时抓伴奏: 变调之后、主音量之前, 所以录下来的电平不跟音量滑块走。
    /// 可视化已经占了 mainMixer 的 tap, 同一个总线只能挂一个。
    var karaokeRecordingTapNode: AVAudioNode? {
        outputMode == .effects ? timePitchNode : nil
    }

    // MARK: - Spatial Audio

    func configureSpatialAudio(enabled: Bool, headTrackingEnabled: Bool) {
        let allowEffects = outputMode == .effects
        spatialAudioEnabled = allowEffects && enabled
        spatialHeadTrackingEnabled = allowEffects && enabled && headTrackingEnabled
        applySpatialAudioConfiguration()
    }

    private func applySpatialAudioConfiguration() {
        guard let environmentNode else { return }

        environmentNode.outputType = spatialAudioEnabled ? .headphones : .auto
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environmentNode.distanceAttenuationParameters.referenceDistance = 1
        environmentNode.distanceAttenuationParameters.maximumDistance = 4
        environmentNode.distanceAttenuationParameters.rolloffFactor = 0
        environmentNode.reverbParameters.enable = false

        configureSpatialSource(playerNode)
        configureSpatialSource(crossfadePlayerNode)

        if spatialAudioEnabled, spatialHeadTrackingEnabled {
            startSpatialHeadTracking()
        } else {
            stopSpatialHeadTracking()
            resetSpatialListenerOrientation()
        }
    }

    private func configureSpatialSource(_ node: AVAudioPlayerNode?) {
        guard let node else { return }

        node.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        node.sourceMode = spatialAudioEnabled ? .pointSource : .bypass
        node.renderingAlgorithm = spatialAudioEnabled ? .HRTFHQ : .stereoPassThrough
    }

    private func startSpatialHeadTracking() {
        let manager = headphoneMotionManager ?? CMHeadphoneMotionManager()
        guard manager.isDeviceMotionAvailable else {
            spatialHeadTrackingEnabled = false
            resetSpatialListenerOrientation()
            return
        }

        headphoneMotionManager = manager
        guard !manager.isDeviceMotionActive else { return }

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            Task { @MainActor [weak self] in
                self?.applyHeadphoneMotion(motion)
            }
        }
    }

    private func stopSpatialHeadTracking() {
        headphoneMotionManager?.stopDeviceMotionUpdates()
    }

    private func resetSpatialListenerOrientation() {
        environmentNode?.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
    }

    private func applyHeadphoneMotion(_ motion: CMDeviceMotion) {
        guard spatialAudioEnabled, spatialHeadTrackingEnabled else { return }

        let attitude = motion.attitude
        let radiansToDegrees = 180.0 / Double.pi
        environmentNode?.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: Float(attitude.yaw * radiansToDegrees),
            pitch: Float(attitude.pitch * radiansToDegrees),
            roll: Float(attitude.roll * radiansToDegrees)
        )
    }

    // MARK: - Crossfade Volume

    /// Set volumes for crossfade transition. The caller passes volumes that
    /// are already scaled by each song's program volume, see
    /// `ReplayGainPolicy.crossfadeVolumes`.
    /// primary: volume of the current playerNode (program volume → 0 while fading out)
    /// crossfade: volume of the crossfade node (0 → program volume while fading in)
    func setCrossfadeVolumes(primary: Float, crossfade: Float) {
        guard outputMode == .effects else { return }
        cancelTransportFade(restoreVolume: true)
        playerNode?.volume = primary
        crossfadePlayerNode?.volume = crossfade
    }

    /// Swap primary and crossfade player nodes after a crossfade completes.
    /// `programVolume` is the incoming song's steady-state volume. The ramp has
    /// already landed there, so the swap itself changes nothing audible.
    func swapPlayerNodes(programVolume: Float) {
        let temp = playerNode
        playerNode = crossfadePlayerNode
        crossfadePlayerNode = temp
        nodeRegistry.swapRoles()
        sampleTimeOffset = 0

        // Reset the now-inactive crossfade node
        nodeRegistry.resetTimeline(for: .crossfade)
        crossfadePlayerNode?.stop()
        crossfadePlayerNode?.reset()
        crossfadePlayerNode?.volume = 0

        // The incoming song keeps the volume the ramp faded it in to.
        primaryProgramVolume = programVolume
        playerNode?.volume = programVolume
    }

    // MARK: - ReplayGain

    /// Sets the primary node's steady-state volume, normally a song's
    /// ReplayGain volume from `ReplayGainPolicy.linearGain`. While a pause or
    /// resume fade is running it only moves that fade's target, so the fade
    /// cannot finish by restoring the volume it started from.
    func applyProgramVolume(_ volume: Float) {
        let linear = outputMode == .effects && volume.isFinite ? max(0, volume) : 1
        primaryProgramVolume = linear
        if transportFadeTask != nil {
            transportFadeRestoreVolume = linear
        } else {
            playerNode?.volume = linear
        }
    }

    func resetPlayerVolume() {
        cancelTransportFade(restoreVolume: false)
        primaryProgramVolume = 1
        playerNode?.volume = 1.0
    }

    /// Puts the primary node back on its program volume after a crossfade
    /// ramp was abandoned before the swap.
    func restorePrimaryProgramVolume() {
        cancelTransportFade(restoreVolume: false)
        playerNode?.volume = primaryProgramVolume
    }

    /// A paused AVAudioEngine freezes its whole render graph. The spatial
    /// environment, the EQ / compressor / reverb chain and the time-pitch node
    /// each hold the tail of whatever was playing, and restarting the engine
    /// pushes that stale tail to the output before any new audio — heard as a
    /// glitch when Play resumes, and as a fragment of the previous song when a
    /// new one starts from a paused transport. Clearing those buffers while the
    /// graph is silent is what keeps the next start clean.
    ///
    /// The high-fidelity graph connects the player straight to the output node
    /// with no unit in between, so it has nothing to flush — and materialising
    /// `mainMixerNode` there would splice a mixer into that direct path.
    private func flushEffectChain() {
        guard outputMode == .effects, let engine else { return }
        environmentNode?.reset()
        playerMixer?.reset()
        eqNode?.reset()
        compressorNode?.reset()
        reverbNode?.reset()
        timePitchNode?.reset()
        karaokeVocalNode?.reset()
        engine.mainMixerNode.reset()
    }

    /// Keeps the graph running briefly across a transport pause, then releases
    /// the hardware. Within the window a resume reuses the live graph; after
    /// it every start flushes the effect chain first, so the stale tail never
    /// reaches the output either way.
    private func scheduleEngineIdleShutdown() {
        cancelEngineIdleShutdown()
        engineIdleShutdownTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.engineIdleShutdownDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.engineIdleShutdownTask = nil
            // A transport that came back to life owns the graph again.
            guard !self.isPlaying, self.playerNode?.isPlaying != true else { return }
            self.engine?.pause()
            self.flushEffectChain()
        }
    }

    private func cancelEngineIdleShutdown() {
        engineIdleShutdownTask?.cancel()
        engineIdleShutdownTask = nil
    }

    private func cancelTransportFade(restoreVolume: Bool) {
        transportFadeTask?.cancel()
        transportFadeTask = nil
        if restoreVolume, let targetVolume = transportFadeRestoreVolume {
            playerNode?.volume = targetVolume
        }
        transportFadeRestoreVolume = nil
    }

    private static func fadeInGain(at progress: Float) -> Float {
        let clamped = max(0, min(progress, 1))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func fadeOutGain(at progress: Float) -> Float {
        1 - fadeInGain(at: progress)
    }

    // MARK: - Time Tracking

    var currentTime: TimeInterval? {
        playbackTime(for: playerNode, sampleTimeOffset: sampleTimeOffset)
    }

    /// The incoming node owns the visible song as soon as a crossfade commits,
    /// even though it does not become the primary node until the ramp ends.
    var crossfadeCurrentTime: TimeInterval? {
        playbackTime(for: crossfadePlayerNode, sampleTimeOffset: 0)
    }

    private func playbackTime(
        for node: AVAudioPlayerNode?,
        sampleTimeOffset: Int64
    ) -> TimeInterval? {
        guard let playerTime = playbackClockSample(for: node) else {
            return nil
        }
        let (adjustedSampleTime, overflow) = playerTime.sampleTime
            .subtractingReportingOverflow(sampleTimeOffset)
        guard !overflow else { return nil }
        let time = Double(adjustedSampleTime) / playerTime.sampleRate
        return time.isFinite ? time : nil
    }

    private func playbackClockSample(for node: AVAudioPlayerNode?) -> AVAudioTime? {
        guard !playbackClockReadsSuspended,
              let engine,
              let node,
              node.engine === engine,
              engine.isRunning,
              node.isPlaying,
              let playerTime = PrimusePlayerTimeForNode(node),
              playerTime.sampleRate.isFinite,
              playerTime.sampleRate > 0,
              node.engine === engine,
              engine.isRunning,
              node.isPlaying else {
            return nil
        }
        return playerTime
    }

    /// Moves the gapless zero point to a previously scheduled final buffer.
    /// This never queries AVFAudio from a completion callback, where the
    /// render graph may already be transitioning to another lifecycle state.
    @discardableResult
    func markTrackBoundary(
        _ boundary: PlaybackTimelineTracker.BoundaryToken?
    ) -> Bool {
        guard let boundary,
              let frameCursor = nodeRegistry.commitBoundary(boundary, on: .primary) else {
            return false
        }
        sampleTimeOffset = frameCursor
        return true
    }

    private static let volumeKey = "primuse_volume"

    var volume: Float {
        // The control must retain its value before playback prepares a graph
        // and while an output-device change replaces that graph.
        get { applicationGainIsAvailable ? requestedVolume : 1 }
        set { setVolume(newValue) }
    }

    /// 这一刻应用能不能自己给声音加增益 —— 也就是音量条能不能用。
    ///
    /// - 音效模式：走 mainMixer，一直可以。
    /// - 高保真直通（PCM）：图里没有混音器，改走输出单元的应用级音量。它只缩放
    ///   本 app 送出去的数据流，不碰设备硬件音量，所以系统音量和别的 app 都不受
    ///   影响；音量拉满时仍是单位增益，直通依旧逐位精确。
    /// - DoP / DSD 直通：样本里是 1bit 码流，动不得。
    var applicationGainIsAvailable: Bool {
        if outputMode == .effects { return true }
        #if os(macOS)
        guard !usesDSDCarrier else { return false }
        // 图还没建起来时先当可用 —— 起播之前也该能拖音量。真的写不进去时,
        // 建图那一次写入会把它置回 false, 控件再退回禁用并说明。
        return !isSetUp || directOutputVolumeIsSupported
        #else
        return false
        #endif
    }

    /// 用户设定的音量，不受当前播放图是否施加增益影响。
    ///
    /// `volume` 表达的是「当前播放图这一刻的实际增益」，加不了增益的图（DoP /
    /// DSD 直通）下恒为 1。那个语义只对本地链路成立，而电台、MV、系统回退播放
    /// 各自走独立的 AVPlayer，DLNA 上报的也是用户音量 —— 这些路径读 `volume`
    /// 会在切过一次这种图之后统统跳到满音量。它们要的是这个值。
    var userVolume: Float { requestedVolume }

    func setVolume(_ value: Float, persist: Bool = true) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0), 1)
        // 值没变就不重新赋值 —— 拖动时每个鼠标事件都赋一次会让所有观察它的
        // 视图白重绘一遍。但图里那一级增益每次都要写：图重建之后它是满格的，
        // 用户把滑块推回原值时同样得写一次，否则那一次拖动像没反应。
        if requestedVolume != clamped { requestedVolume = clamped }
        applyRequestedVolumeToGraph()
        if persist { persistVolume() }
    }

    /// 把用户音量写到这一刻真正在出声的那一级增益上。
    private func applyRequestedVolumeToGraph() {
        guard isSetUp else { return }
        if outputMode == .effects {
            engine?.mainMixerNode.outputVolume = requestedVolume
            return
        }
        #if os(macOS)
        guard !usesDSDCarrier else { return }
        applyDirectOutputVolume(requestedVolume)
        #endif
    }

    #if os(macOS)
    /// 输出单元（AUHAL）的应用级音量参数 `kHALOutputParam_Volume`。
    ///
    /// 它缩放的是本 app 送往设备的数据流，不是设备的硬件音量 —— 系统音量、
    /// 其它 app 的音量都不会跟着动。高保真直通图里没有混音器，这是唯一能给它
    /// 加增益的地方。
    private static let halOutputVolumeParameterID = AudioUnitParameterID(14)

    @discardableResult
    private func applyDirectOutputVolume(_ value: Float) -> Bool {
        guard let outputUnit = engine?.outputNode.audioUnit else {
            directOutputVolumeIsSupported = false
            return false
        }
        let status = AudioUnitSetParameter(
            outputUnit,
            Self.halOutputVolumeParameterID,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
        if status != noErr, engine?.isRunning == true {
            plog("⚠️ 直通输出音量写不进去, 音量条会退回禁用 status=\(status)")
        }
        directOutputVolumeIsSupported = status == noErr
        return status == noErr
    }
    #endif

    /// Continuous slider tracking must not broadcast preference changes on
    /// every pointer event. Commit the latest audible value when tracking ends.
    func persistVolume() {
        guard volumeDefaults.object(forKey: Self.volumeKey) as? Float != requestedVolume else { return }
        volumeDefaults.set(requestedVolume, forKey: Self.volumeKey)
    }

    /// Restore saved volume on setup
    func restoreVolume() {
        #if os(iOS)
        // The Now Playing control is the system `MPVolumeView`. Keeping a
        // second persisted mixer gain would make the visible system value and
        // actual loudness diverge, and it cannot affect MusicKit playback at
        // all. Migrate legacy app-volume values back to unity gain.
        volumeDefaults.removeObject(forKey: Self.volumeKey)
        requestedVolume = 1
        playerNode?.volume = 1
        // The high-fidelity graph deliberately connects the player directly
        // to the output node. Asking AVAudioEngine for mainMixerNode in that
        // mode makes it try to attach a second output path and can trip an
        // internal Core Audio assertion. Never materialize the mixer there.
        if outputMode == .effects {
            engine?.mainMixerNode.outputVolume = 1
        }
        #else
        if outputMode != .effects { playerNode?.volume = 1 }
        applyRequestedVolumeToGraph()
        #endif
    }

    /// 给 visualizer 挂 tap 的节点。效果图取 mainMixerNode ── 输出前最后一站,
    /// 挂 tap 拿到的 buffer 已经过 EQ / compressor / reverb / volume,跟 user 实际
    /// 听到的一致。高保真直通图没有混音器(访问 mainMixerNode 会让 AVAudioEngine
    /// 凭空创建并接线),改取主播放节点的输出:直通时那就是送去硬件的原样信号。
    /// nil 表示 engine 还没 setup,visualizer 直接 stop。
    var visualizerTapNode: AVAudioNode? {
        if outputMode == .effects {
            return effectsMainMixer
        }
        return playerNode
    }

    /// 效果图的主混音器;高保真直通图没有混音器,返回 nil。
    var effectsMainMixer: AVAudioMixerNode? {
        outputMode == .effects ? engine?.mainMixerNode : nil
    }

    /// 让 visualizer 拿到底层 engine 自己 install/remove tap。
    var engineForVisualizer: AVAudioEngine? {
        engine
    }

    /// Returns diagnostic info about the engine state for debugging playback issues.
    func diagnosticInfo() -> String {
        let engRunning = engine?.isRunning ?? false
        let playerPlaying = playerNode?.isPlaying ?? false
        let playerVol = playerNode?.volume ?? -1
        let crossVol = crossfadePlayerNode?.volume ?? -1
        // mainMixerNode does not exist in the direct high-fidelity graph.
        // Merely accessing the property asks AVAudioEngine to create/connect
        // it, which conflicts with the player's existing output connection.
        let mainVol: Float = outputMode == .effects
            ? (engine?.mainMixerNode.outputVolume ?? -1)
            : (applicationGainIsAvailable ? requestedVolume : 1)
        let hasTime = playerNode.map { PrimusePlayerNodeHasRenderTime($0) } ?? false
        return "mode=\(outputMode.rawValue) eng=\(engRunning) player=\(playerPlaying) pVol=\(playerVol) cVol=\(crossVol) mainVol=\(mainVol) hasRenderTime=\(hasTime)"
    }

    func scheduleBufferStream(_ stream: AudioBufferStream) async throws {
        for try await buffer in stream {
            scheduleBuffer(buffer)
        }
    }

}
