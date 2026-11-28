import AVFoundation
import Dispatch
import Foundation
import PrimuseKit
#if os(iOS)
import CoreHaptics
import UIKit
#endif

/// Layered real-time Core Haptics engine driven directly from `AudioEngine` PCM audio (#469).
///
/// - **Layer A**: Looped `CHHapticEvent.EventType.hapticContinuous` player modulated in real time via
///   `CHHapticDynamicParameter` (intensity & spectral sharpness).
/// - **Layer B**: Deduplicated `CHHapticEvent.EventType.hapticTransient` accents (kick, snare, bass
///   attack, hi-hat) synthesized by `MusicHapticsAnalyzer`.
/// - **Zero overhead when off**: No audio tap, no background analysis task, and no running
///   `CHHapticEngine` when disabled, paused, unsupported, or playing non-local audio.
@MainActor
@Observable
final class MusicHapticsEngine {
    private(set) var isActive: Bool = false

    @ObservationIgnored private var configuration = MusicHapticsConfiguration()
    @ObservationIgnored private var isPlaybackEligible = false
    @ObservationIgnored private weak var audioEngine: AudioEngine?
    #if os(iOS)
    @ObservationIgnored private var tappedNode: AVAudioNode?
    @ObservationIgnored private var sampleRing: SpectrumSampleRing?
    @ObservationIgnored private var tappedSampleRate: Double = 48_000
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var pipelineGeneration: UInt64 = 0
    @ObservationIgnored private let runtimeBox = MusicHapticsRuntimeBox()
    @ObservationIgnored private let driver = CoreHapticsOutputDriver()
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var isAppInBackground = false
    #endif

    init() {
        #if os(iOS)
        isAppInBackground = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAppInBackground = true
                self.tearDownPipeline()
            }
        }
        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAppInBackground = false
                self.reconcilePipeline()
            }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                switch type {
                case .began:
                    self.tearDownPipeline()
                case .ended:
                    self.reconcilePipeline()
                @unknown default:
                    break
                }
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleDiscontinuity()
                self.reconcilePipeline()
            }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        let center = NotificationCenter.default
        if let foregroundObserver { center.removeObserver(foregroundObserver) }
        if let backgroundObserver { center.removeObserver(backgroundObserver) }
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        if let routeChangeObserver { center.removeObserver(routeChangeObserver) }
        #endif
    }
}

extension MusicHapticsEngine {
    /// True when the current device hardware supports Core Haptics (iPhone with Taptic Engine).
    static var isHardwareSupported: Bool {
        #if os(iOS)
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        false
        #endif
    }

    func attach(to audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        audioEngine.onMusicHapticsLifecycleEvent = { [weak self] event in
            self?.handleAudioEngineEvent(event)
        }
        reconcilePipeline()
    }

    func updateConfiguration(_ newConfiguration: MusicHapticsConfiguration) {
        let changed = configuration != newConfiguration
        configuration = newConfiguration
        #if os(iOS)
        runtimeBox.setConfiguration(newConfiguration)
        #endif
        if changed {
            reconcilePipeline()
        }
    }

    func setPlaybackEligible(_ eligible: Bool) {
        guard isPlaybackEligible != eligible else { return }
        isPlaybackEligible = eligible
        reconcilePipeline()
    }

    /// Resets adaptive analysis history and silences continuous texture immediately
    /// on track changes, seeks, speed/varispeed changes, or audio route switches.
    func handleDiscontinuity() {
        #if os(iOS)
        sampleRing?.reset()
        runtimeBox.requestReset()
        driver.silenceImmediate()
        #endif
    }

    /// Plays a brief tactile preview pulse reflecting the selected style & intensity in Settings.
    func playPreviewPulse(style: MusicHapticsStyle, intensity: Double) {
        #if os(iOS)
        guard Self.isHardwareSupported, !isActive else { return }
        driver.playPreviewPulse(style: style, intensity: Float(MusicHapticsConfiguration.clampedIntensity(intensity)))
        #endif
    }

    func handleAudioEngineEvent(_ event: AudioEngineHapticsEvent) {
        #if os(iOS)
        switch event {
        case .graphTeardown:
            tearDownPipeline()
        case .graphReady, .started:
            reconcilePipeline()
        case .paused:
            tearDownPipeline()
        case .discontinuity, .rateChanged:
            handleDiscontinuity()
        }
        #endif
    }

    private func reconcilePipeline() {
        #if os(iOS)
        let shouldRun = Self.isHardwareSupported
            && configuration.isEnabled
            && configuration.intensity > 0.001
            && isPlaybackEligible
            && !isAppInBackground
            && (audioEngine?.isPlaying ?? false)
            && (audioEngine?.usesDSDCarrier == false)

        guard shouldRun,
              let engine = audioEngine?.engineForMusicHaptics,
              engine.isRunning,
              let node = audioEngine?.hapticsTapNode,
              node.engine === engine else {
            tearDownPipeline()
            return
        }

        // Reuse live pipeline if already tapping the same running node.
        if tappedNode === node, analysisTask != nil {
            if !isActive { isActive = true }
            return
        }

        tearDownPipeline()

        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            return
        }

        let ring = SpectrumSampleRing(capacityPowerOfTwo: 16)
        guard MusicHapticsTap.install(on: node, bufferSize: 1024, format: format, ring: ring) else {
            plog("⚠️ MusicHaptics: failed to install tap on \(type(of: node))")
            return
        }

        tappedNode = node
        sampleRing = ring
        tappedSampleRate = format.sampleRate
        runtimeBox.setConfiguration(configuration)
        runtimeBox.requestReset()

        pipelineGeneration &+= 1
        let generation = pipelineGeneration
        let sampleRate = format.sampleRate
        let runtimeBox = self.runtimeBox
        let driver = self.driver

        driver.start(generation: generation)
        isActive = true

        analysisTask = Task.detached(priority: .userInitiated) { [ring, runtimeBox, driver] in
            let fftSize = MusicHapticsAnalyzer.preferredFFTSize(forSampleRate: sampleRate)
            let analyzer = MusicHapticsAnalyzer(fftSize: fftSize)
            var scratch = Array(repeating: Float(0), count: fftSize)
            var cursor = SpectrumPlayoutCursor()
            let hopInterval: TimeInterval = 0.020 // 50 Hz tactile responsiveness
            let sleepDuration = Duration.milliseconds(20)
            var lastAnalyzedWritten: Int64 = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }

                let snapshot = runtimeBox.takeSnapshot()
                if snapshot.needsReset {
                    analyzer.reset()
                    cursor = SpectrumPlayoutCursor()
                    lastAnalyzedWritten = 0
                }
                guard snapshot.configuration.isEnabled, snapshot.configuration.intensity > 0.001 else {
                    driver.silenceImmediate()
                    continue
                }

                let state = ring.state()
                guard state.written > 0 else { continue }

                let windowEnd: Int64
                let dt: TimeInterval
                if let step = cursor.advance(
                    state: state,
                    nowUptime: DispatchTime.now().uptimeNanoseconds,
                    sampleRate: sampleRate
                ) {
                    windowEnd = step.end
                    dt = step.advancedFrames > 0
                        ? min(0.1, max(0.008, Double(step.advancedFrames) / sampleRate))
                        : hopInterval
                } else if state.written != lastAnalyzedWritten {
                    windowEnd = state.written
                    dt = hopInterval
                } else {
                    continue
                }
                lastAnalyzedWritten = state.written

                scratch.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    ring.copyWindow(endingAt: windowEnd, count: fftSize, into: base)
                }

                let frame = scratch.withUnsafeBufferPointer { buf in
                    analyzer.analyzeWindow(
                        buf,
                        sampleRate: sampleRate,
                        deltaTime: dt,
                        configuration: snapshot.configuration
                    )
                }
                driver.apply(frame: frame, generation: generation)
            }

            // Only this pipeline's own driver session: a cancelled task must not stop a newer one.
            driver.stop(generation: generation)
        }
        #else
        if isActive { isActive = false }
        #endif
    }

    private func tearDownPipeline() {
        #if os(iOS)
        pipelineGeneration &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        if let node = tappedNode {
            _ = PrimuseRemoveNodeTap(node, 0)
        }
        tappedNode = nil
        sampleRing = nil
        driver.stop()
        if isActive { isActive = false }
        #endif
    }
}

#if os(iOS)
/// Must stay outside `@MainActor` so Swift 6 does not inherit main-actor isolation
/// on Core Audio's real-time tap callback thread.
private enum MusicHapticsTap {
    static func install(
        on node: AVAudioNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        ring: SpectrumSampleRing
    ) -> Bool {
        var error: NSError?
        return PrimuseInstallNodeTap(node, 0, bufferSize, format, { audioBuffer, _ in
            guard let channels = audioBuffer.floatChannelData else { return }
            let frames = Int(audioBuffer.frameLength)
            guard frames > 0 else { return }
            ring.write(channels[0], frameCount: frames, stride: audioBuffer.stride)
        }, &error)
    }
}

/// Lock-protected configuration & reset handoff between `@MainActor` and the 50 Hz analysis task.
private final class MusicHapticsRuntimeBox: @unchecked Sendable {
    struct Snapshot: Sendable {
        let configuration: MusicHapticsConfiguration
        let needsReset: Bool
    }

    private let lock = NSLock()
    private var configuration = MusicHapticsConfiguration()
    private var resetRequested = false

    func setConfiguration(_ value: MusicHapticsConfiguration) {
        lock.lock()
        configuration = value
        lock.unlock()
    }

    func requestReset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    func takeSnapshot() -> Snapshot {
        lock.lock()
        let snap = Snapshot(configuration: configuration, needsReset: resetRequested)
        resetRequested = false
        lock.unlock()
        return snap
    }
}

/// Serial-queue-isolated Core Haptics hardware driver managing Layer A (looped continuous
/// player with real-time dynamic parameters) and Layer B (rhythmic transient bursts).
private final class CoreHapticsOutputDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.primuse.music-haptics.driver", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isEngineRunning = false
    private var isContinuousActive = false
    private var lastSentIntensity: Float = -1
    private var lastSentSharpness: Float = -1
    private var consecutiveSilentFrames = 0
    /// Pipeline that owns the hardware right now. Frames and stops from an analysis task that
    /// was already torn down arrive later on this queue and must not restart or stop the engine.
    private var activeGeneration: UInt64?
    private var previewToken: UInt64 = 0

    func start(generation: UInt64) {
        queue.async { [weak self] in
            self?.activeGeneration = generation
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.activeGeneration = nil
            self?.stopOnQueue()
        }
    }

    func stop(generation: UInt64) {
        queue.async { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.activeGeneration = nil
            self.stopOnQueue()
        }
    }

    func silenceImmediate() {
        queue.async { [weak self] in
            self?.silenceOnQueue()
        }
    }

    func apply(frame: MusicHapticsFrame, generation: UInt64) {
        queue.async { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.applyOnQueue(frame: frame)
        }
    }

    func playPreviewPulse(style: MusicHapticsStyle, intensity: Float) {
        queue.async { [weak self] in
            self?.playPreviewOnQueue(style: style, intensity: intensity)
        }
    }

    // MARK: - Queue-Isolated Implementation

    private func ensureEngineOnQueue() -> CHHapticEngine? {
        if let engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let created = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = false
            // Handlers of an engine that was already stopped and released must not touch the state
            // of the next one (a stale reset would mark a fresh, never-started engine as running).
            let engineID = ObjectIdentifier(created)
            created.stoppedHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.engine.map(ObjectIdentifier.init) == engineID else { return }
                    self.isEngineRunning = false
                    self.isContinuousActive = false
                }
            }
            created.resetHandler = { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.engine.map(ObjectIdentifier.init) == engineID else { return }
                    self.continuousPlayer = nil
                    self.isContinuousActive = false
                    self.lastSentIntensity = -1
                    self.lastSentSharpness = -1
                    do {
                        try self.engine?.start()
                        self.isEngineRunning = true
                        self.rebuildContinuousPlayerOnQueue()
                    } catch {
                        self.isEngineRunning = false
                    }
                }
            }
            self.engine = created
            return created
        } catch {
            plog("⚠️ MusicHaptics: CHHapticEngine init failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func startOnQueue() {
        guard let engine = ensureEngineOnQueue() else { return }
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                plog("⚠️ MusicHaptics: CHHapticEngine start failed: \(error.localizedDescription)")
                return
            }
        }
        rebuildContinuousPlayerOnQueue()
    }

    private func rebuildContinuousPlayerOnQueue() {
        guard let engine, isEngineRunning else { return }
        // Base intensity = 1.0 (multiplicative dynamic control), base sharpness = 0.0 (additive dynamic control).
        let baseEvent = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0),
            ],
            relativeTime: 0,
            duration: 30.0
        )
        do {
            let pattern = try CHHapticPattern(events: [baseEvent], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            player.loopEnd = 30.0
            continuousPlayer = player
            isContinuousActive = false
            lastSentIntensity = -1
            lastSentSharpness = -1
            consecutiveSilentFrames = 0
        } catch {
            plog("⚠️ MusicHaptics: continuous player creation failed: \(error.localizedDescription)")
        }
    }

    private func applyOnQueue(frame: MusicHapticsFrame) {
        guard let engine = ensureEngineOnQueue() else { return }
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
                rebuildContinuousPlayerOnQueue()
            } catch {
                return
            }
        }

        // Layer A: Continuous haptic texture
        if frame.isSilent || frame.continuousIntensity < 0.015 {
            consecutiveSilentFrames += 1
            if isContinuousActive {
                if lastSentIntensity > 0 {
                    sendContinuousParameters(intensity: 0, sharpness: frame.continuousSharpness)
                }
                // After ~300 ms of sustained silence, pause the continuous player so the actuator rests.
                if consecutiveSilentFrames >= 15 {
                    try? continuousPlayer?.pause(atTime: CHHapticTimeImmediate)
                    isContinuousActive = false
                }
            }
        } else {
            consecutiveSilentFrames = 0
            if continuousPlayer == nil {
                rebuildContinuousPlayerOnQueue()
            }
            if !isContinuousActive, let player = continuousPlayer {
                do {
                    try player.start(atTime: CHHapticTimeImmediate)
                    isContinuousActive = true
                    lastSentIntensity = -1
                    lastSentSharpness = -1
                } catch {
                    rebuildContinuousPlayerOnQueue()
                }
            }
            let intensityDelta = abs(frame.continuousIntensity - lastSentIntensity)
            let sharpnessDelta = abs(frame.continuousSharpness - lastSentSharpness)
            if intensityDelta >= 0.012 || sharpnessDelta >= 0.025 || lastSentIntensity < 0 {
                sendContinuousParameters(
                    intensity: frame.continuousIntensity,
                    sharpness: frame.continuousSharpness
                )
            }
        }

        // Layer B: Rhythmic transient accents
        for transient in frame.transients {
            fireTransientOnQueue(transient, engine: engine)
        }
    }

    private func sendContinuousParameters(intensity: Float, sharpness: Float) {
        guard let player = continuousPlayer else { return }
        let clampedIntensity = min(1, max(0, intensity))
        let clampedSharpness = min(1, max(0, sharpness))
        let params = [
            CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl,
                value: clampedIntensity,
                relativeTime: 0
            ),
            CHHapticDynamicParameter(
                parameterID: .hapticSharpnessControl,
                value: clampedSharpness,
                relativeTime: 0
            ),
        ]
        do {
            try player.sendParameters(params, atTime: CHHapticTimeImmediate)
            lastSentIntensity = clampedIntensity
            lastSentSharpness = clampedSharpness
        } catch {
            isContinuousActive = false
        }
    }

    private func fireTransientOnQueue(_ transient: MusicHapticsTransient, engine: CHHapticEngine) {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: transient.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: transient.sharpness),
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Transient failures are non-fatal; continuous recovery happens via resetHandler.
        }
    }

    private func silenceOnQueue() {
        if isContinuousActive {
            sendContinuousParameters(intensity: 0, sharpness: 0.15)
            try? continuousPlayer?.pause(atTime: CHHapticTimeImmediate)
            isContinuousActive = false
        }
        consecutiveSilentFrames = 0
        lastSentIntensity = 0
    }

    private func stopOnQueue() {
        if let player = continuousPlayer {
            try? player.stop(atTime: CHHapticTimeImmediate)
        }
        continuousPlayer = nil
        isContinuousActive = false
        lastSentIntensity = -1
        lastSentSharpness = -1
        consecutiveSilentFrames = 0
        if isEngineRunning {
            engine?.stop(completionHandler: nil)
            isEngineRunning = false
        }
        engine = nil
    }

    private func playPreviewOnQueue(style: MusicHapticsStyle, intensity: Float) {
        let clamped = min(1, max(0.15, intensity))
        guard let engine = ensureEngineOnQueue() else { return }
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                return
            }
        }
        // Auto-shutdown is off, so a preview outside playback would keep the engine running
        // indefinitely: stop it once the pulse has played unless a pipeline took it over.
        previewToken &+= 1
        let token = previewToken
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.activeGeneration == nil, self.previewToken == token else { return }
            self.stopOnQueue()
        }
        let p = style.parameters
        let swell = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, p.continuousGain * clamped)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: min(1, p.continuousSharpnessBase + 0.15)),
            ],
            relativeTime: 0,
            duration: 0.22
        )
        let kick = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, p.kickGain * clamped)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.20),
            ],
            relativeTime: 0.02
        )
        let snare = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, p.snareGain * clamped)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.65),
            ],
            relativeTime: 0.18
        )
        do {
            let pattern = try CHHapticPattern(events: [swell, kick, snare], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            return
        }
    }
}
#endif
