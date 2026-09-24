import AVFoundation
import Foundation
import PrimuseKit

/// Writes tapped buffers to a file off the main actor and remembers when the
/// first buffer arrived, which the mixdown needs to line the two takes up.
final class KaraokeTakeWriter: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var firstHostSeconds: Double?
    private var failed = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed else { return }
        if firstHostSeconds == nil, time.isHostTimeValid {
            firstHostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        }
        do {
            try file.write(from: buffer)
        } catch {
            failed = true
            plog("⚠️ Karaoke: take write failed: \(error.localizedDescription)")
        }
    }

    /// Closes the file; returns the host time of its first frame.
    func finish() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return failed ? nil : firstHostSeconds
    }
}

/// Tap closures must not be formed inside a `@MainActor` type: Core Audio
/// calls them on its own queue (see `AudioVisualizerTap`).
enum KaraokeTap {
    static func installRing(
        on node: AVAudioNode,
        format: AVAudioFormat,
        ring: KaraokeSampleRing
    ) {
        node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            ring.write(channel, count: Int(buffer.frameLength))
        }
    }

    static func installWriter(
        on node: AVAudioNode,
        format: AVAudioFormat,
        writer: KaraokeTakeWriter
    ) {
        node.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            writer.append(buffer, at: time)
        }
    }
}

/// The microphone side of karaoke: its own engine so the playback graph is
/// never rebuilt around an input. Input feeds a pitch ring (dry) and, through
/// a reverb, the optional headphone monitor and the recording take (wet).
@MainActor
final class KaraokeMicrophone {
    enum StartError: Error {
        case permissionDenied
        case noInput
    }

    /// Dry microphone samples for pitch analysis.
    let ring = KaraokeSampleRing(capacity: 1 << 16)
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var reverb: AVAudioUnitReverb?
    private var monitorMixer: AVAudioMixerNode?
    private var takeWriter: KaraokeTakeWriter?

    var monitorVolume: Float = 0 {
        didSet { monitorMixer?.outputVolume = monitorVolume }
    }

    var reverbMix: Float = 25 {
        didSet { reverb?.wetDryMix = reverbMix }
    }

    /// Microphone → delivery delay plus this engine's output delay.
    var inputLatency: TimeInterval {
        engine?.inputNode.presentationLatency ?? 0
    }

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await Self.requestPermission() else { throw StartError.permissionDenied }
        try AudioSessionManager.shared.setMicrophoneCaptureActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? AudioSessionManager.shared.setMicrophoneCaptureActive(false)
            throw StartError.noInput
        }

        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = reverbMix
        let monitor = AVAudioMixerNode()
        engine.attach(reverb)
        engine.attach(monitor)
        // The input node only connects in its hardware format.
        engine.connect(input, to: reverb, format: inputFormat)
        engine.connect(reverb, to: monitor, format: inputFormat)
        // Keeps the graph pulling the input even with the monitor muted.
        engine.connect(monitor, to: engine.mainMixerNode, format: nil)
        monitor.outputVolume = monitorVolume

        KaraokeTap.installRing(on: input, format: inputFormat, ring: ring)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? AudioSessionManager.shared.setMicrophoneCaptureActive(false)
            throw error
        }
        self.engine = engine
        self.reverb = reverb
        monitorMixer = monitor
        sampleRate = inputFormat.sampleRate
        isRunning = true
    }

    func stop() {
        guard let engine else { return }
        _ = finishTake()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        reverb = nil
        monitorMixer = nil
        isRunning = false
        ring.reset()
        do {
            try AudioSessionManager.shared.setMicrophoneCaptureActive(false)
        } catch {
            plog("⚠️ Karaoke: restoring playback session failed: \(error.localizedDescription)")
        }
    }

    /// Starts writing the wet voice to `url`.
    func startTake(url: URL) throws {
        guard let reverb, takeWriter == nil else { return }
        let format = reverb.outputFormat(forBus: 0)
        let writer = try KaraokeTakeWriter(url: url, format: format)
        KaraokeTap.installWriter(on: reverb, format: format, writer: writer)
        takeWriter = writer
    }

    /// Stops the take; returns the file and the host time of its first frame.
    func finishTake() -> (url: URL, firstHostSeconds: Double)? {
        guard let writer = takeWriter else { return nil }
        reverb?.removeTap(onBus: 0)
        takeWriter = nil
        guard let first = writer.finish() else { return nil }
        return (writer.url, first)
    }
}

/// Mixes the accompaniment take and the voice take into one shareable file.
enum KaraokeMixdown {
    private final class PendingBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    struct Take: Sendable {
        var url: URL
        var firstHostSeconds: Double
    }

    enum MixError: Error {
        case unreadable
    }

    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Karaoke", isDirectory: true)
    }

    /// Runs off the main actor; files can be minutes long.
    nonisolated static func mix(
        accompaniment: Take,
        voice: Take,
        outputLatency: Double,
        inputLatency: Double,
        voiceGain: Float,
        destination: URL
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try mixSynchronously(
                accompaniment: accompaniment,
                voice: voice,
                outputLatency: outputLatency,
                inputLatency: inputLatency,
                voiceGain: voiceGain,
                destination: destination
            )
        }.value
    }

    private nonisolated static func mixSynchronously(
        accompaniment: Take,
        voice: Take,
        outputLatency: Double,
        inputLatency: Double,
        voiceGain: Float,
        destination: URL
    ) throws -> URL {
        let accompanimentFile = try AVAudioFile(forReading: accompaniment.url)
        let voiceFile = try AVAudioFile(forReading: voice.url)
        let format = accompanimentFile.processingFormat
        guard format.channelCount >= 1,
              let voiceBuffer = try readConverted(voiceFile, to: format) else {
            throw MixError.unreadable
        }

        let lead = KaraokeRecordingAlignment.microphoneLeadFrames(
            accompanimentFirstHostSeconds: accompaniment.firstHostSeconds,
            microphoneFirstHostSeconds: voice.firstHostSeconds,
            outputLatency: outputLatency,
            inputLatency: inputLatency,
            sampleRate: format.sampleRate
        )

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(2, Int(format.channelCount)),
            AVEncoderBitRateKey: 192_000,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunk: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let voiceSamples = voiceBuffer.floatChannelData else {
            throw MixError.unreadable
        }
        let voiceLength = Int(voiceBuffer.frameLength)
        var frame = 0
        while true {
            try accompanimentFile.read(into: buffer, frameCount: chunk)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                let voiceChannel = min(channel, Int(voiceBuffer.format.channelCount) - 1)
                let samples = channels[channel]
                for index in 0..<count {
                    let voiceIndex = frame + index + lead
                    var value = samples[index]
                    if voiceIndex >= 0, voiceIndex < voiceLength {
                        value += voiceGain * voiceSamples[voiceChannel][voiceIndex]
                    }
                    // Soft clip instead of wrapping when the two sum hot.
                    samples[index] = value / (1 + abs(value) * 0.25)
                }
            }
            try output.write(from: buffer)
            frame += count
        }
        return destination
    }

    /// Reads a whole file converted to `format` (rate and channel count).
    private nonisolated static func readConverted(
        _ file: AVAudioFile,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let sourceFormat = file.processingFormat
        let sourceLength = AVAudioFrameCount(file.length)
        guard sourceLength > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceLength) else {
            return nil
        }
        try file.read(into: source)
        if sourceFormat.sampleRate == format.sampleRate,
           sourceFormat.channelCount == format.channelCount {
            return source
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceLength) * ratio) + 1_024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // Handed over once, then end of stream. Boxed because the input
        // block may be treated as @Sendable.
        let pending = PendingBuffer(source)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? MixError.unreadable
        }
        return converted
    }
}
