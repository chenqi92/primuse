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
    var isActuallyPlaying: Bool {
        engine?.isRunning == true && playerNode?.isPlaying == true
    }
    private(set) var outputFormat: AVAudioFormat?
    private(set) var spatialAudioEnabled = false
    private(set) var spatialHeadTrackingEnabled = false
    private(set) var outputMode: AudioOutputMode = .effects

    private var isSetUp = false
    private var directSourceFormat: AVAudioFormat?
    private var headphoneMotionManager: CMHeadphoneMotionManager?

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

    init() {}

    // MARK: - Setup

    /// Selects the render graph used for the next playback session.
    ///
    /// High-fidelity mode connects the primary player straight to the output
    /// node and keeps volume at unity. The effects graph retains the spatial,
    /// EQ, dynamics, reverb, rate, crossfade and visualizer chain.
    func configure(outputMode: AudioOutputMode, directSourceFormat: AVAudioFormat? = nil) throws {
        let normalizedDirectFormat = outputMode == .highFidelity ? directSourceFormat : nil
        let formatChanged: Bool = {
            switch (self.directSourceFormat, normalizedDirectFormat) {
            case (nil, nil): false
            case let (lhs?, rhs?): lhs != rhs
            default: true
            }
        }()
        guard self.outputMode != outputMode || formatChanged || !isSetUp else { return }

        #if os(macOS)
        let previousDevice = currentOutputDeviceID
        let wasFollowingSystem = followsSystemOutput
        #endif

        tearDownGraph()
        self.outputMode = outputMode
        self.directSourceFormat = normalizedDirectFormat
        try setUp()

        #if os(macOS)
        if !wasFollowingSystem, let previousDevice {
            try? setOutputDevice(deviceID: previousDevice)
        }
        #endif
    }

    private func tearDownGraph() {
        stopSilenceKeepAlive()
        playerNode?.stop()
        crossfadePlayerNode?.stop()
        engine?.stop()
        stopSpatialHeadTracking()
        engine = nil
        playerNode = nil
        crossfadePlayerNode = nil
        playerMixer = nil
        environmentNode = nil
        eqNode = nil
        compressorNode = nil
        reverbNode = nil
        timePitchNode = nil
        outputFormat = nil
        isSetUp = false
        isPlaying = false
        sampleTimeOffset = 0
    }

    func setUp() throws {
        guard !isSetUp else { return }

        let eng = AVAudioEngine()
        let playerA = AVAudioPlayerNode()
        let playerB = AVAudioPlayerNode()

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
            self.outputFormat = format
            self.isSetUp = true
            spatialAudioEnabled = false
            spatialHeadTrackingEnabled = false
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
        // 注意: 不要在这里把 output unit 钉到任何设备。新建的 AVAudioEngine
        // 默认就跟随系统默认输出设备(并随系统切换而切换), 这正是「跟随系统」
        // 想要的行为。之前在此调用 restoreOutputRouting() 把 CurrentDevice 设成
        // kAudioObjectUnknown(0), 反而让 AUHAL 失去有效设备, engine 启动直接报
        // -10875, 所有播放(本地/NAS/云盘)全部失败。
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

    // MARK: - Hardware format negotiation

    /// Requests a hardware sample rate and returns the rate actually reported
    /// by the active output. Core Audio and AVAudioSession are allowed to
    /// reject the request, so callers must compare the return value before
    /// enabling DoP or claiming a sample-rate-matched path.
    @discardableResult
    func prepareHardwareSampleRate(_ targetHz: Double) -> Double {
        guard targetHz >= 8_000, targetHz <= 384_000 else {
            return currentHardwareSampleRate
        }
        #if os(iOS)
        _ = AudioSessionManager.shared.setPreferredSampleRate(targetHz)
        return AVAudioSession.sharedInstance().sampleRate
        #elseif os(macOS)
        guard let deviceID = currentOutputDeviceID ?? Self.systemDefaultOutputDeviceID() else {
            return 0
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue {
            var rate = targetHz
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil,
                UInt32(MemoryLayout<Double>.size), &rate
            )
            if status != noErr {
                plog("⚠️ Core Audio rejected sample rate \(targetHz) (status=\(status))")
            }
        }
        return Self.nominalSampleRate(deviceID: deviceID)
        #else
        return currentHardwareSampleRate
        #endif
    }

    var currentHardwareSampleRate: Double {
        #if os(iOS)
        return AVAudioSession.sharedInstance().sampleRate
        #elseif os(macOS)
        guard let deviceID = currentOutputDeviceID ?? Self.systemDefaultOutputDeviceID() else { return 0 }
        return Self.nominalSampleRate(deviceID: deviceID)
        #else
        return outputFormat?.sampleRate ?? 0
        #endif
    }

    /// Builds the PCM format used by the DSP-free graph for a source sample
    /// rate. The channel count follows the active output route; unlike the
    /// sample rate it is not persisted on `Song`.
    func directPCMFormat(sampleRate: Double) -> AVAudioFormat? {
        guard sampleRate >= 8_000, sampleRate <= 384_000 else { return nil }
        let routeChannels = engine?.outputNode.inputFormat(forBus: 0).channelCount
            ?? outputFormat?.channelCount
            ?? 2
        return AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: max(1, routeChannels)
        )
    }

    func hardwareSupportsDirectFormat(_ format: AVAudioFormat) -> Bool {
        let actual = currentHardwareSampleRate
        return actual > 0 && abs(actual - format.sampleRate) < 1
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

    /// 把这个 app 的音频输出切到指定的 Core Audio 设备。系统默认输出
    /// 不变 —— 这只影响 Primuse 自己。设备 ID 来自 AudioOutputDeviceManager,
    /// 通常对应内置扬声器、AirPlay 接收器(HomePod / Apple TV)、蓝牙
    /// 耳机等。设备拔掉后会自动回退到系统默认。
    func setOutputDevice(deviceID: AudioDeviceID) throws {
        try setUp()
        guard let engine else { return }
        let outputUnit = engine.outputNode.audioUnit
        guard let outputUnit else { return }

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
                NSLocalizedDescriptionKey: "Failed to set output device (status=\(status))"
            ])
        }
        // 显式钉到了某设备, 退出跟随系统状态并持久化。
        UserDefaults.standard.set(false, forKey: Self.followsSystemKey)
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
                NSLocalizedDescriptionKey: "Failed to follow system output (status=\(status))"
            ])
        }
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
        node.play()
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

    func scheduleCrossfadeBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) {
        crossfadePlayerNode?.scheduleBuffer(
            buffer,
            completionCallbackType: completionCallbackType,
            completionHandler: completionHandler
        )
    }

    func playCrossfadeNode() {
        crossfadePlayerNode?.play()
    }

    func stopCrossfadeNode() {
        crossfadePlayerNode?.stop()
        crossfadePlayerNode?.reset()
    }

    // MARK: - Playback Control

    @discardableResult
    func play() -> Bool {
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
            do { try engine.start() } catch {
                plog("Failed to start engine: \(error)")
                isPlaying = false
                return false
            }
        }
        playerNode?.play()
        isPlaying = engine.isRunning && (playerNode?.isPlaying ?? false)
        return isPlaying
    }

    func pause() {
        playerNode?.pause()
        crossfadePlayerNode?.pause()
        // Pausing every player node leaves AVAudioEngine and the audio hardware
        // running. Stop that render activity without releasing the prepared
        // graph so system Now Playing can observe a real paused transport and
        // resume() can restart the same scheduled buffers.
        engine?.pause()
        isPlaying = false
    }

    @discardableResult
    func resume() -> Bool {
        // After audio interruption (e.g. phone call, other app), the engine stops.
        // Restart it before resuming playback.
        applySpatialAudioConfiguration()
        if let engine, !engine.isRunning {
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
        playerNode?.play()
        if (crossfadePlayerNode?.volume ?? 0) > 0 {
            crossfadePlayerNode?.play()
        }
        isPlaying = playerNode?.isPlaying ?? false
        return isPlaying
    }

    func stopPlayback() {
        playerNode?.stop()
        playerNode?.reset()
        isPlaying = false
    }

    /// Restart the engine and player node if they were stopped (e.g. by a configuration change).
    @discardableResult
    func restartIfNeeded() -> Bool {
        guard let engine else {
            isPlaying = false
            return false
        }
        if !engine.isRunning {
            do {
                applySpatialAudioConfiguration()
                try engine.start()
            } catch {
                plog("Failed to restart engine: \(error)")
                isPlaying = false
                return false
            }
        }
        playerNode?.play()
        isPlaying = engine.isRunning && (playerNode?.isPlaying ?? false)
        return isPlaying
    }

    // MARK: - Playback Rate

    /// 设定播放速度倍率, 0.5x ~ 2.0x。AVAudioUnitTimePitch.rate 直接生效,
    /// 不用重启 engine。1.0 是 passthrough。pitch 保持 0 (不变调)。
    func applyPlaybackRate(_ rate: Float) {
        guard outputMode == .effects else { return }
        let clamped = max(0.5, min(2.0, rate))
        timePitchNode?.rate = clamped
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

    /// Set volumes for crossfade transition.
    /// primaryVolume: volume of current playerNode (1→0 during fade out)
    /// crossfadeVolume: volume of crossfade node (0→1 during fade in)
    func setCrossfadeVolumes(primary: Float, crossfade: Float) {
        guard outputMode == .effects else { return }
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
        guard outputMode == .effects else {
            playerNode?.volume = 1
            return
        }
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
        guard outputMode == .effects else { return }
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
        get { outputMode == .highFidelity ? 1 : (engine?.mainMixerNode.outputVolume ?? 1.0) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.volumeKey)
            guard outputMode == .effects else { return }
            engine?.mainMixerNode.outputVolume = newValue
        }
    }

    /// Restore saved volume on setup
    func restoreVolume() {
        #if os(iOS)
        // The Now Playing control is the system `MPVolumeView`. Keeping a
        // second persisted mixer gain would make the visible system value and
        // actual loudness diverge, and it cannot affect MusicKit playback at
        // all. Migrate legacy app-volume values back to unity gain.
        UserDefaults.standard.removeObject(forKey: Self.volumeKey)
        playerNode?.volume = 1
        // The high-fidelity graph deliberately connects the player directly
        // to the output node. Asking AVAudioEngine for mainMixerNode in that
        // mode makes it try to attach a second output path and can trip an
        // internal Core Audio assertion. Never materialize the mixer there.
        if outputMode == .effects {
            engine?.mainMixerNode.outputVolume = 1
        }
        #else
        guard outputMode == .effects else {
            playerNode?.volume = 1
            return
        }
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float {
            engine?.mainMixerNode.outputVolume = saved
        }
        #endif
    }

    /// 给 visualizer 用的 ── mainMixerNode 是输出前最后一站,挂 tap 拿到的
    /// buffer 已经过 EQ / compressor / reverb / volume,跟 user 实际听到的一致。
    /// nil 表示 engine 还没 setup,visualizer 直接 stop。
    var mainMixerForVisualizer: AVAudioMixerNode? {
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
            : 1
        let hasTime = (playerNode?.lastRenderTime) != nil
        return "mode=\(outputMode.rawValue) eng=\(engRunning) player=\(playerPlaying) pVol=\(playerVol) cVol=\(crossVol) mainVol=\(mainVol) hasRenderTime=\(hasTime)"
    }

    func scheduleBufferStream(_ stream: AudioBufferStream) async throws {
        guard let playerNode else { return }
        for try await buffer in stream {
            await playerNode.scheduleBuffer(buffer)
        }
    }

}
