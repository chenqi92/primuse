@preconcurrency import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

actor ReplayGainAnalysisService {
    static let shared = ReplayGainAnalysisService()
    private var pending: [String: (UUID, Task<ReplayGainLoudnessMeasurement, Error>)] = [:]
    private var preparations: [UUID: Set<String>] = [:]

    typealias Status = ReplayGainAnalysisStatus

    func status(for song: Song) async -> Status {
        if await ReplayGainAnalysisCache.shared.measurement(for: song) != nil { return .cached }
        let key = ReplayGainAnalysisCache.key(for: song)
        if pending[key] != nil { return .analyzing }
        return preparations.values.contains { $0.contains(key) } ? .queued : .unavailable
    }

    /// Produces cache entries only. Playback takes a snapshot before starting
    /// and must never be changed by an analysis finishing later.
    func prepare(
        _ songs: [Song],
        knownFiles: [String: URL] = [:],
        audioFile: @MainActor @Sendable (Song) async throws -> KaraokeAudioFile?
    ) async throws {
        let preparationID = UUID()
        preparations[preparationID] = Set(songs.map { ReplayGainAnalysisCache.key(for: $0) })
        defer { preparations[preparationID] = nil }
        for song in songs {
            try Task.checkCancellation()
            let key = ReplayGainAnalysisCache.key(for: song)
            defer { preparations[preparationID]?.remove(key) }
            let local = knownFiles[key]
            if await ReplayGainAnalysisCache.shared.measurement(for: song, fileURL: local) != nil { continue }
            do {
                guard let file = try await audioFile(song) else { continue }
                defer { if file.removeAfterDecoding { try? FileManager.default.removeItem(at: file.url) } }
                try Task.checkCancellation()
                _ = try await analyze(song, url: file.url)
                plog("ReplayGain analysis cached for '\(song.title)'")
            } catch {
                try Task.checkCancellation()
                plog("ReplayGain analysis unavailable: \(type(of: error))")
            }
        }
    }

    func analyze(_ song: Song, url: URL) async throws -> ReplayGainLoudnessMeasurement {
        if let cached = await ReplayGainAnalysisCache.shared.measurement(for: song, fileURL: url) { return cached }
        let key = ReplayGainAnalysisCache.key(for: song)
        if let job = pending[key] { return try await job.1.value }
        let id = UUID()
        let job = Task {
            let value = try await ReplayGainFileAnalyzer.analyze(url: url, song: song)
            try Task.checkCancellation()
            await ReplayGainAnalysisCache.shared.store(value, for: song, fileURL: url)
            return value
        }
        pending[key] = (id, job)
        defer { if pending[key]?.0 == id { pending[key] = nil } }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    static func cachedAdjustment(for song: Song, mode: ReplayGainMode, album: [Song], url: URL? = nil) async -> ReplayGainAdjustment {
        await cachedSnapshot(for: song, mode: mode, album: album, url: url)?.values ?? .init()
    }

    static func cachedSnapshot(for song: Song, mode: ReplayGainMode, album: [Song], url: URL? = nil) async -> ReplayGainPlaybackSnapshot? {
        guard let track = await ReplayGainAnalysisCache.shared.measurement(for: song, fileURL: url) else { return nil }
        if mode == .album, !album.isEmpty,
           let measurement = await ReplayGainAnalysisCache.shared.albumMeasurement(for: album) {
            return .init(mode: .album, values: measurement.adjustment, origin: .analysis)
        }
        return .init(mode: .track, values: track.adjustment, origin: .analysis)
    }
}

private final class ReplayGainAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var bridge: FFmpegDecoderBridge?

    func cancel() {
        lock.lock()
        cancelled = true
        bridge?.cancel()
        lock.unlock()
    }

    func install(_ value: FFmpegDecoderBridge?) {
        lock.lock()
        bridge = value
        if cancelled { bridge?.cancel() }
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum ReplayGainFileAnalyzer {
    // Synchronous file decoders never run on the main actor or the
    // cooperative pool. A single utility lane bounds the CPU / disk load.
    private static let lane = DispatchQueue(label: "com.welape.primuse.replaygain", qos: .utility)
    enum Failure: Error { case unreadable, unsupportedChannels, incomplete }

    static func analyze(url: URL, song: Song) async throws -> ReplayGainLoudnessMeasurement {
        guard url.isFileURL else { throw Failure.unreadable }
        let cancellation = ReplayGainAnalysisCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lane.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        var accumulator = Accumulator(song: song)
                        do {
                            let bridge = try FFmpegDecoderBridge(url: url, ioTimeout: 10)
                            cancellation.install(bridge)
                            defer { cancellation.install(nil) }
                            while true {
                                try cancellation.check()
                                guard let buffer = try bridge.readNextBuffer().buffer, buffer.frameLength > 0 else { break }
                                if try accumulator.append(buffer) { break }
                            }
                        } catch {
                            try cancellation.check()
                            // SFB also handles tracker modules and formats
                            // unavailable in a particular FFmpeg build.
                            accumulator = Accumulator(song: song)
                            let decoder: AudioDecoder
                            if AudioFormat.from(fileExtension: url.pathExtension)?.isTrackerModule == true {
                                decoder = try AudioDecoder(url: url, decoderName: .module)
                            } else {
                                decoder = try AudioDecoder(url: url)
                            }
                            try decoder.open()
                            defer { try? decoder.close() }
                            guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192) else {
                                throw Failure.unreadable
                            }
                            while true {
                                try cancellation.check()
                                try decoder.decode(into: buffer, length: 8192)
                                if buffer.frameLength == 0 { break }
                                if try accumulator.append(buffer) { break }
                            }
                        }
                        try cancellation.check()
                        guard let value = accumulator.analyzer?.measurement else { throw Failure.incomplete }
                        return value
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private struct Accumulator {
        let song: Song
        var analyzer: ReplayGainLoudnessAnalyzer?
        private var elapsed = 0.0
        private var sampleRate: Double?

        init(song: Song) { self.song = song }

        mutating func append(_ buffer: AVAudioPCMBuffer) throws -> Bool {
            let format = buffer.format
            let rate = format.sampleRate
            guard rate.isFinite, (8000...768000).contains(rate) else { throw Failure.unreadable }
            let channels = Int(format.channelCount)
            if let sampleRate, sampleRate != rate { throw Failure.unreadable }
            sampleRate = rate
            if analyzer == nil {
                analyzer = ReplayGainLoudnessAnalyzer(sampleRate: rate, channelWeights: try weights(format))
            }
            let frames = Int(buffer.frameLength)
            let start = max(0, song.cueStartTime.flatMap { $0.isFinite ? $0 : nil } ?? 0)
            let end = song.cueEndTime.flatMap { $0.isFinite && $0 > start ? $0 : nil } ?? .infinity
            let lower = Int(min(Double(frames), max(0, ((start - elapsed) * rate).rounded(.up))))
            let upper = Int(min(Double(frames), max(0, ((end - elapsed) * rate).rounded(.up))))
            defer { elapsed += Double(frames) / rate }
            guard upper > lower else { return elapsed >= end }
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            var planar = Array(repeating: [Float](), count: channels)
            for channel in 0..<channels {
                let data = buffers[format.isInterleaved ? 0 : channel].mData
                guard let data else { throw Failure.unreadable }
                planar[channel].reserveCapacity(upper - lower)
                for frame in lower..<upper {
                    let offset = format.isInterleaved ? frame * channels + channel : frame
                    let sample: Float
                    switch format.commonFormat {
                    case .pcmFormatFloat32: sample = data.assumingMemoryBound(to: Float.self)[offset]
                    case .pcmFormatFloat64: sample = Float(data.assumingMemoryBound(to: Double.self)[offset])
                    case .pcmFormatInt16: sample = Float(data.assumingMemoryBound(to: Int16.self)[offset]) / 32768
                    case .pcmFormatInt32: sample = Float(Double(data.assumingMemoryBound(to: Int32.self)[offset]) / 2147483648)
                    default: throw Failure.unreadable
                    }
                    planar[channel].append(sample)
                }
            }
            analyzer?.append(planarSamples: planar)
            return elapsed + Double(frames) / rate >= end
        }

        private func weights(_ format: AVAudioFormat) throws -> [Double] {
            let count = Int(format.channelCount)
            if count <= 2 { return Array(repeating: 1, count: count) }
            // Expand Core Audio's named layouts so LFE is excluded and rear /
            // side channels receive the BS.1770 surround weighting.
            guard let layout = format.channelLayout else { throw Failure.unsupportedChannels }
            var tag = layout.layoutTag
            if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
                guard layout.layout.pointee.mNumberChannelDescriptions == count else { throw Failure.unsupportedChannels }
                return weights(descriptions: UnsafeRawPointer(layout.layout), count: count)
            }
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size) == noErr else {
                throw Failure.unsupportedChannels
            }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { storage.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size, storage) == noErr else {
                throw Failure.unsupportedChannels
            }
            let expanded = storage.assumingMemoryBound(to: AudioChannelLayout.self)
            guard expanded.pointee.mNumberChannelDescriptions == count else { throw Failure.unsupportedChannels }
            return weights(descriptions: UnsafeRawPointer(storage), count: count)
        }

        private func weights(descriptions storage: UnsafeRawPointer, count: Int) -> [Double] {
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descriptions = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<count).map { channel in
                switch descriptions[channel].mChannelLabel {
                case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return 0
                case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                     kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                     kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                     kAudioChannelLabel_CenterSurround: return 1.41
                default: return 1
                }
            }
        }
    }
}
