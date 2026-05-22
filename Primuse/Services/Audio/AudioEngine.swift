import AudioToolbox
import AVFoundation
import CoreMotion
import Foundation
import PrimuseKit

@MainActor
@Observable
final class AudioEngine {
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

    private(set) var isPlaying = false
    private(set) var outputFormat: AVAudioFormat?
    private(set) var spatialAudioEnabled = false
    private(set) var spatialHeadTrackingEnabled = false

    private var isSetUp = false
    private var headphoneMotionManager: CMHeadphoneMotionManager?

    /// Sample time offset for gapless track transitions.
    /// When gapless transitions happen without stopping the playerNode,
    /// this tracks the cumulative sample offset so currentTime resets to 0.
    var sampleTimeOffset: Int64 = 0

    init() {}

    // MARK: - Setup

    func setUp() throws {
        guard !isSetUp else { return }

        let eng = AVAudioEngine()
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()
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
        timePitch.pitch = 0
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

        let mainMixer = eng.mainMixerNode
        var format = mainMixer.outputFormat(forBus: 0)

        if format.sampleRate == 0 || format.channelCount == 0 {
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        }

        // Signal chain: playerA/B → Spatial Environment → mixer → EQ → Compressor → Reverb → TimePitch → mainMixer → output
        // TimePitch 放最后一站, 让 EQ / 压缩 / 混响 都在原速下处理,
        // visualizer 仍挂 mainMixer 拿到变速后的最终输出。
        eng.connect(playerA, to: environment, format: format)
        eng.connect(playerB, to: environment, format: format)
        eng.connect(environment, to: mixer, format: format)
        eng.connect(mixer, to: eq, format: format)
        eng.connect(eq, to: compressor, format: format)
        eng.connect(compressor, to: reverb, format: format)
        eng.connect(reverb, to: timePitch, format: format)
        eng.connect(timePitch, to: mainMixer, format: format)

        playerB.volume = 0 // crossfade node starts silent

        self.engine = eng
        self.playerNode = playerA
        self.crossfadePlayerNode = playerB
        self.playerMixer = mixer
        self.environmentNode = environment
        self.eqNode = eq
        self.compressorNode = compressor
        self.reverbNode = reverb
        self.timePitchNode = timePitch
        self.outputFormat = format
        self.isSetUp = true
        applySpatialAudioConfiguration()
        restoreVolume()
    }

    // MARK: - Engine Control

    func start() throws {
        try setUp()
        applySpatialAudioConfiguration()
        guard let engine, !engine.isRunning else { return }
        try engine.start()
    }

    func stop() {
        playerNode?.stop()
        crossfadePlayerNode?.stop()
        engine?.stop()
        stopSpatialHeadTracking()
        isPlaying = false
    }

    // MARK: - Buffer Scheduling (Primary Node)

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode?.scheduleBuffer(buffer)
    }

    /// Schedule buffer with completion callback — use `.dataPlayedBack` for precise track-end detection.
    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) {
        playerNode?.scheduleBuffer(buffer, completionCallbackType: completionCallbackType, completionHandler: completionHandler)
    }

    // MARK: - Buffer Scheduling (Crossfade Node)

    func scheduleCrossfadeBuffer(_ buffer: AVAudioPCMBuffer) {
        crossfadePlayerNode?.scheduleBuffer(buffer)
    }

    func playCrossfadeNode() {
        crossfadePlayerNode?.play()
    }

    func stopCrossfadeNode() {
        crossfadePlayerNode?.stop()
        crossfadePlayerNode?.reset()
    }

    // MARK: - Playback Control

    func play() {
        if engine == nil || !isSetUp {
            do { try setUp() } catch {
                print("Failed to set up engine: \(error)")
                return
            }
        }
        guard let engine else { return }
        applySpatialAudioConfiguration()
        if !engine.isRunning {
            do { try engine.start() } catch {
                print("Failed to start engine: \(error)")
                return
            }
        }
        playerNode?.play()
        isPlaying = true
    }

    func pause() {
        playerNode?.pause()
        crossfadePlayerNode?.pause()
        isPlaying = false
    }

    func resume() {
        // After audio interruption (e.g. phone call, other app), the engine stops.
        // Restart it before resuming playback.
        applySpatialAudioConfiguration()
        if let engine, !engine.isRunning {
            do { try engine.start() } catch {
                print("Failed to restart engine after interruption: \(error)")
                return
            }
        }
        playerNode?.play()
        if (crossfadePlayerNode?.volume ?? 0) > 0 {
            crossfadePlayerNode?.play()
        }
        isPlaying = true
    }

    func stopPlayback() {
        playerNode?.stop()
        playerNode?.reset()
        isPlaying = false
    }

    /// Restart the engine and player node if they were stopped (e.g. by a configuration change).
    func restartIfNeeded() {
        guard let engine, !engine.isRunning else { return }
        do {
            applySpatialAudioConfiguration()
            try engine.start()
            playerNode?.play()
        } catch {
            print("Failed to restart engine: \(error)")
        }
    }

    // MARK: - Playback Rate

    /// 设定播放速度倍率, 0.5x ~ 2.0x。AVAudioUnitTimePitch.rate 直接生效,
    /// 不用重启 engine。1.0 是 passthrough。pitch 保持 0 (不变调)。
    func applyPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(2.0, rate))
        timePitchNode?.rate = clamped
    }

    // MARK: - Spatial Audio

    func configureSpatialAudio(enabled: Bool, headTrackingEnabled: Bool) {
        spatialAudioEnabled = enabled
        spatialHeadTrackingEnabled = enabled && headTrackingEnabled
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

    /// Set volumes for crossfade transition.
    /// primaryVolume: volume of current playerNode (1→0 during fade out)
    /// crossfadeVolume: volume of crossfade node (0→1 during fade in)
    func setCrossfadeVolumes(primary: Float, crossfade: Float) {
        playerNode?.volume = primary
        crossfadePlayerNode?.volume = crossfade
    }

    /// Swap primary and crossfade player nodes after a crossfade completes.
    func swapPlayerNodes() {
        let temp = playerNode
        playerNode = crossfadePlayerNode
        crossfadePlayerNode = temp

        // Reset the now-inactive crossfade node
        crossfadePlayerNode?.stop()
        crossfadePlayerNode?.reset()
        crossfadePlayerNode?.volume = 0

        // Ensure primary is at full volume
        playerNode?.volume = 1.0
    }

    // MARK: - ReplayGain

    /// Apply ReplayGain adjustment to the primary player node.
    /// gain: dB value from ReplayGain tag
    /// peak: peak sample value (0-1 range), used to prevent clipping
    func applyReplayGain(gain: Double?, peak: Double?) {
        guard let gain else {
            playerNode?.volume = 1.0
            return
        }

        var linearGain = Float(pow(10.0, gain / 20.0))

        // Prevent clipping using peak value
        if let peak, peak > 0 {
            let maxGain = Float(1.0 / peak)
            linearGain = min(linearGain, maxGain)
        }

        // Clamp to reasonable range
        linearGain = max(0.0, min(linearGain, 4.0))
        playerNode?.volume = linearGain
    }

    func resetPlayerVolume() {
        playerNode?.volume = 1.0
    }

    /// Apply ReplayGain to the crossfade node (before crossfade starts).
    /// The crossfade volume ramp is applied on top of this base volume.
    func applyCrossfadeReplayGain(gain: Double?, peak: Double?) {
        guard let gain else {
            // Store base volume as 1.0; crossfade ramp will modulate from 0→1
            crossfadePlayerNode?.volume = 0 // will be ramped by crossfade
            return
        }

        var linearGain = Float(pow(10.0, gain / 20.0))
        if let peak, peak > 0 {
            let maxGain = Float(1.0 / peak)
            linearGain = min(linearGain, maxGain)
        }
        linearGain = max(0.0, min(linearGain, 4.0))

        // Store in a tag property — the crossfade ramp will multiply by this
        // For now, we'll apply after swap since crossfade ramp controls volume 0→1
        // The RG volume is applied after the swap completes
        crossfadePlayerNode?.volume = 0 // crossfade starts silent, ramp handles it
    }

    // MARK: - Time Tracking

    var currentTime: TimeInterval? {
        guard let playerNode,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        let adjustedSampleTime = playerTime.sampleTime - sampleTimeOffset
        return Double(adjustedSampleTime) / playerTime.sampleRate
    }

    /// Record current sample time as the new zero point (for gapless transitions).
    func markTrackBoundary() {
        guard let playerNode,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        sampleTimeOffset = playerTime.sampleTime
    }

    private static let volumeKey = "primuse_volume"

    var volume: Float {
        get { engine?.mainMixerNode.outputVolume ?? 1.0 }
        set {
            engine?.mainMixerNode.outputVolume = newValue
            UserDefaults.standard.set(newValue, forKey: Self.volumeKey)
        }
    }

    /// Restore saved volume on setup
    func restoreVolume() {
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float {
            engine?.mainMixerNode.outputVolume = saved
        }
    }

    /// 给 visualizer 用的 ── mainMixerNode 是输出前最后一站,挂 tap 拿到的
    /// buffer 已经过 EQ / compressor / reverb / volume,跟 user 实际听到的一致。
    /// nil 表示 engine 还没 setup,visualizer 直接 stop。
    var mainMixerForVisualizer: AVAudioMixerNode? {
        engine?.mainMixerNode
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
        let mainVol = engine?.mainMixerNode.outputVolume ?? -1
        let hasTime = (playerNode?.lastRenderTime) != nil
        return "eng=\(engRunning) player=\(playerPlaying) pVol=\(playerVol) cVol=\(crossVol) mainVol=\(mainVol) hasRenderTime=\(hasTime)"
    }

    func scheduleBufferStream(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws {
        guard let playerNode else { return }
        for try await buffer in stream {
            await playerNode.scheduleBuffer(buffer)
        }
    }

    func seek(to time: TimeInterval, in file: AVAudioFile) throws {
        playerNode?.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let remainingFrames = AVAudioFrameCount(file.length - startFrame)
        guard remainingFrames > 0 else { return }
        file.framePosition = startFrame
        playerNode?.play()
        isPlaying = true
    }
}
