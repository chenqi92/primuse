import AVFoundation
import Foundation
import PrimuseKit

@MainActor
@Observable
final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private(set) var eqNode: AVAudioUnitEQ?

    private(set) var isPlaying = false
    private(set) var outputFormat: AVAudioFormat?

    private var isSetUp = false

    init() {
        // Defer engine setup until first use to avoid crashes
        // when audio session isn't ready
    }

    /// Lazily sets up the audio engine graph.
    /// Must be called before any playback operation.
    func setUp() throws {
        guard !isSetUp else { return }

        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: PrimuseConstants.eqBandCount)

        // Configure EQ bands with standard frequencies
        for (index, frequency) in PrimuseConstants.eqBandFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = PrimuseConstants.eqDefaultBandwidth
            band.gain = 0
            band.bypass = false
        }

        // Attach nodes
        eng.attach(player)
        eng.attach(eq)

        // Get output format - use a safe default if system returns invalid format
        let mainMixer = eng.mainMixerNode
        var format = mainMixer.outputFormat(forBus: 0)

        if format.sampleRate == 0 || format.channelCount == 0 {
            // Fallback to standard format
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        }

        // Connect: playerNode -> eqNode -> mainMixer -> output
        eng.connect(player, to: eq, format: format)
        eng.connect(eq, to: mainMixer, format: format)

        self.engine = eng
        self.playerNode = player
        self.eqNode = eq
        self.outputFormat = format
        self.isSetUp = true
    }

    func start() throws {
        try setUp()
        guard let engine, !engine.isRunning else { return }
        try engine.start()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        isPlaying = false
    }

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime? = nil) {
        playerNode?.scheduleBuffer(buffer, at: when)
    }

    func scheduleBufferStream(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws {
        guard let playerNode else { return }
        for try await buffer in stream {
            await playerNode.scheduleBuffer(buffer)
        }
    }

    func play() {
        if engine == nil || !isSetUp {
            do {
                try setUp()
            } catch {
                print("Failed to set up engine: \(error)")
                return
            }
        }
        guard let engine else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Failed to start engine: \(error)")
                return
            }
        }
        playerNode?.play()
        isPlaying = true
    }

    func pause() {
        playerNode?.pause()
        isPlaying = false
    }

    func resume() {
        playerNode?.play()
        isPlaying = true
    }

    func stopPlayback() {
        playerNode?.stop()
        isPlaying = false
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

    var currentTime: TimeInterval? {
        guard let playerNode,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    var volume: Float {
        get { engine?.mainMixerNode.outputVolume ?? 1.0 }
        set { engine?.mainMixerNode.outputVolume = newValue }
    }
}
