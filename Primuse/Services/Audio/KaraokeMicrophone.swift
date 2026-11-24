import AVFoundation
import Foundation
import PrimuseKit
import Synchronization

/// Single producer on the input render thread, sampled by the network queue.
final class KaraokeInputCadence: Sendable {
    private let blocks = Atomic<Int>(0)
    private let largest = Atomic<Int>(0)

    var blockCount: Int { blocks.load(ordering: .relaxed) }
    var maximumFrames: Int { largest.load(ordering: .relaxed) }

    func observe(_ frames: Int) {
        blocks.store(blockCount + 1, ordering: .relaxed)
        if frames > maximumFrames { largest.store(frames, ordering: .relaxed) }
    }
}

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
    static func makeLiveInput(ring: KaraokeSampleRing, cadence: KaraokeInputCadence) -> AVAudioSinkNode {
        ring.prepareStorage()
        return AVAudioSinkNode { _, frames, input in
            let buffer = input.pointee.mBuffers
            if let data = buffer.mData, buffer.mNumberChannels == 1 {
                ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frames))
                cadence.observe(Int(frames))
            }
            return noErr
        }
    }

    static func installRing(
        on node: AVAudioNode,
        format: AVAudioFormat,
        ring: KaraokeSampleRing
    ) throws {
        ring.prepareStorage()
        var error: NSError?
        guard PrimuseInstallNodeTap(node, 0, 1_024, format, { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            ring.write(channel, count: Int(buffer.frameLength))
        }, &error) else {
            throw error ?? NSError(domain: "PrimuseAudioEngine", code: 2)
        }
    }

    static func installWriter(
        on node: AVAudioNode,
        format: AVAudioFormat,
        writer: KaraokeTakeWriter
    ) throws {
        var error: NSError?
        guard PrimuseInstallNodeTap(node, 0, 4_096, format, { buffer, time in
            writer.append(buffer, at: time)
        }, &error) else {
            throw error ?? NSError(domain: "PrimuseAudioEngine", code: 2)
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
    private(set) var usesLiveInput = false
    private(set) var inputCadence = KaraokeInputCadence()

    private var engine: AVAudioEngine?
    private var reverb: AVAudioUnitReverb?
    private var monitorMixer: AVAudioMixerNode?
    private var takeWriter: KaraokeTakeWriter?
    #if os(iOS)
    private var previousBufferDuration: TimeInterval?
    #endif

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

    #if os(iOS)
    func remoteInputNeedsRestart(changedEngine: AVAudioEngine?) -> Bool {
        guard usesLiveInput, let engine, changedEngine == nil || changedEngine === engine else { return false }
        return !engine.isRunning || AVAudioSession.sharedInstance().sampleRate != sampleRate
            || engine.inputNode.outputFormat(forBus: 0).sampleRate != sampleRate
    }
    #endif

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(forRemoteStage: Bool = false) async throws {
        guard !isRunning else { return }
        guard await Self.requestPermission() else { throw StartError.permissionDenied }
        try Task.checkCancellation()
        try AudioSessionManager.shared.setMicrophoneCaptureActive(true)

        #if os(iOS)
        if forRemoteStage {
            let session = AVAudioSession.sharedInstance()
            let previous = session.preferredIOBufferDuration
            do {
                try session.setPreferredIOBufferDuration(0.005)
                previousBufferDuration = previous
            } catch {
                plog("Karaoke remote mic: using the current I/O buffer duration")
            }
        }
        defer {
            if !usesLiveInput { restoreBufferDuration() }
        }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? AudioSessionManager.shared.setMicrophoneCaptureActive(false)
            throw StartError.noInput
        }

        // A sink gets each hardware I/O cycle. A recording tap can batch
        // many cycles together, which is audible when singing through a TV.
        if forRemoteStage, inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved {
            inputCadence = KaraokeInputCadence()
            let sink = KaraokeTap.makeLiveInput(ring: ring, cadence: inputCadence)
            engine.attach(sink)
            do {
                try AudioEngine.connect(input, to: sink, format: inputFormat, in: engine)
                engine.prepare()
                try engine.start()
                self.engine = engine
                sampleRate = inputFormat.sampleRate
                usesLiveInput = true
                isRunning = true
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                plog("Karaoke remote mic: input=\(Int(sampleRate))Hz hardwareInput=\(session.inputLatency * 1_000)ms ioBuffer=\(session.ioBufferDuration * 1_000)ms")
                #endif
                return
            } catch {
                engine.stop()
                engine.detach(sink)
                plog("Karaoke remote mic: low-latency input unavailable, using scoring tap: \(error.localizedDescription)")
            }
        }

        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = reverbMix
        let monitor = AVAudioMixerNode()
        engine.attach(reverb)
        engine.attach(monitor)
        do {
            // The input node only connects in its hardware format.
            try AudioEngine.connect(input, to: reverb, format: inputFormat, in: engine)
            try AudioEngine.connect(reverb, to: monitor, format: inputFormat, in: engine)
            // Keeps the graph pulling the input even with the monitor muted.
            try AudioEngine.connect(monitor, to: engine.mainMixerNode, format: nil, in: engine)
        } catch {
            try? AudioSessionManager.shared.setMicrophoneCaptureActive(false)
            throw error
        }
        monitor.outputVolume = monitorVolume

        do {
            try KaraokeTap.installRing(on: input, format: inputFormat, ring: ring)
        } catch {
            try? AudioSessionManager.shared.setMicrophoneCaptureActive(false)
            throw error
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            _ = PrimuseRemoveNodeTap(input, 0)
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
        if !usesLiveInput { _ = PrimuseRemoveNodeTap(engine.inputNode, 0) }
        engine.stop()
        self.engine = nil
        reverb = nil
        monitorMixer = nil
        isRunning = false
        usesLiveInput = false
        ring.reset()
        #if os(iOS)
        restoreBufferDuration()
        #endif
        do {
            try AudioSessionManager.shared.setMicrophoneCaptureActive(false)
        } catch {
            plog("⚠️ Karaoke: restoring playback session failed: \(error.localizedDescription)")
        }
    }

    #if os(iOS)
    private func restoreBufferDuration() {
        if let duration = previousBufferDuration {
            try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(duration)
            previousBufferDuration = nil
        }
    }
    #endif

    /// Starts writing the wet voice to `url`.
    func startTake(url: URL) throws {
        guard let reverb, takeWriter == nil else { return }
        let format = reverb.outputFormat(forBus: 0)
        let writer = try KaraokeTakeWriter(url: url, format: format)
        try KaraokeTap.installWriter(on: reverb, format: format, writer: writer)
        takeWriter = writer
    }

    /// Stops the take; returns the file and the host time of its first frame.
    func finishTake() -> (url: URL, firstHostSeconds: Double)? {
        guard let writer = takeWriter else { return nil }
        if let reverb { _ = PrimuseRemoveNodeTap(reverb, 0) }
        takeWriter = nil
        guard let first = writer.finish() else { return nil }
        return (writer.url, first)
    }
}

/// Mixes the accompaniment take and the voice take into one shareable file.
enum KaraokeMixdown {
    private final class FileInput: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        private(set) var failure: Error?

        init(file: AVAudioFile) throws {
            self.file = file
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
                throw MixError.unreadable
            }
            self.buffer = buffer
        }

        func next(_ requested: AVAudioPacketCount) -> AVAudioPCMBuffer? {
            let remaining = file.length - file.framePosition
            guard failure == nil, remaining > 0 else { return nil }
            let count = min(buffer.frameCapacity, requested, AVAudioFrameCount(min(remaining, 8_192)))
            do {
                try file.read(into: buffer, frameCount: count)
                return buffer.frameLength > 0 ? buffer : nil
            } catch {
                failure = error
                return nil
            }
        }
    }

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
        let sourceFormat = accompanimentFile.processingFormat
        // AAC output must not inherit a DAC's high sample rate or channel layout.
        guard accompanimentFile.length > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sourceFormat.sampleRate == 44_100 ? 44_100 : 48_000,
                channels: min(2, sourceFormat.channelCount)
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: format),
              let voiceBuffer = try readConverted(voiceFile, to: format) else {
            throw MixError.unreadable
        }
        converter.downmix = sourceFormat.channelCount > format.channelCount
        let input = try FileInput(file: accompanimentFile)

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
        defer { output.close() }

        let chunk: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let voiceSamples = voiceBuffer.floatChannelData else {
            throw MixError.unreadable
        }
        let voiceLength = Int(voiceBuffer.frameLength)
        var frame = 0
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { requested, inputStatus in
                let next = input.next(requested)
                inputStatus.pointee = next == nil ? .endOfStream : .haveData
                return next
            }
            if let failure = input.failure { throw failure }
            if status == .error { throw conversionError ?? MixError.unreadable }
            let count = Int(buffer.frameLength)
            if count == 0, status == .endOfStream { break }
            guard count > 0, let channels = buffer.floatChannelData else { throw MixError.unreadable }
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
            if status == .endOfStream { break }
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
