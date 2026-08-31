@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import PrimuseKit
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

private final class AudioSilenceIteratorBox: @unchecked Sendable {
    private var iterator: AudioBufferStream.AsyncIterator

    init(_ iterator: AudioBufferStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

struct AudioSilenceProfile: Sendable {
    let leadingTrimmedDuration: TimeInterval
    let trailingTrimmedDuration: TimeInterval
    let playableDuration: TimeInterval
}

private final class StreamingPCMSmartMixAnalyzer: @unchecked Sendable {
    private static let envelopeSampleRate = 50.0
    private static let maximumEnvelopeDuration: TimeInterval = 120
    private static let firstPublicationDuration: TimeInterval = 12
    private static let publicationInterval: TimeInterval = 8

    private var sourceSampleRate: Double?
    private var envelope: [Float] = []
    private var pendingWindowEnergy = 0.0
    private var pendingWindowSampleCount = 0
    private var pendingWindowFrameCoverage = 0
    private var totalFrameCount: Int64 = 0
    private var nextPublicationDuration = firstPublicationDuration

    func append(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0,
              channelCount > 0,
              sampleRate.isFinite,
              sampleRate > 0 else { return }

        if let sourceSampleRate, abs(sourceSampleRate - sampleRate) > 0.5 {
            reset(for: sampleRate)
        } else if sourceSampleRate == nil {
            sourceSampleRate = sampleRate
        }
        totalFrameCount += Int64(frameCount)

        let maximumEnvelopeCount = Int(
            Self.envelopeSampleRate * Self.maximumEnvelopeDuration
        )
        guard envelope.count < maximumEnvelopeCount else { return }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let isInterleaved = buffer.format.isInterleaved
        let samplingStride = max(1, Int((sampleRate / 12_000).rounded(.down)))
        let windowFrames = max(1, Int((sampleRate / Self.envelopeSampleRate).rounded()))

        func consume<T>(
            _: T.Type,
            normalize: (T) -> Double
        ) {
            var frame = 0
            while frame < frameCount, envelope.count < maximumEnvelopeCount {
                var frameEnergy = 0.0
                var validChannels = 0
                for channel in 0..<channelCount {
                    let sample: T
                    if isInterleaved {
                        guard let data = audioBuffers.first?.mData else { continue }
                        sample = data.assumingMemoryBound(to: T.self)[
                            frame * channelCount + channel
                        ]
                    } else {
                        guard channel < audioBuffers.count,
                              let data = audioBuffers[channel].mData else { continue }
                        sample = data.assumingMemoryBound(to: T.self)[frame]
                    }
                    let normalized = normalize(sample)
                    guard normalized.isFinite else { continue }
                    frameEnergy += normalized * normalized
                    validChannels += 1
                }
                if validChannels > 0 {
                    pendingWindowEnergy += frameEnergy / Double(validChannels)
                    pendingWindowSampleCount += 1
                }
                pendingWindowFrameCoverage += samplingStride
                if pendingWindowFrameCoverage >= windowFrames {
                    let rms = pendingWindowSampleCount > 0
                        ? sqrt(pendingWindowEnergy / Double(pendingWindowSampleCount))
                        : 0
                    envelope.append(Float(rms))
                    pendingWindowEnergy = 0
                    pendingWindowSampleCount = 0
                    pendingWindowFrameCoverage -= windowFrames
                }
                frame += samplingStride
            }
        }

        func consumeInteger<T: FixedWidthInteger & SignedInteger>(
            _: T.Type,
            divisor: Double
        ) {
            consume(T.self) { Double($0) / divisor }
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            consume(Float.self, normalize: Double.init)
        case .pcmFormatFloat64:
            consume(Double.self, normalize: { $0 })
        case .pcmFormatInt16:
            consumeInteger(Int16.self, divisor: Double(Int16.max))
        case .pcmFormatInt32:
            consumeInteger(Int32.self, divisor: Double(Int32.max))
        case .otherFormat:
            break
        @unknown default:
            break
        }
    }

    func snapshotIfNeeded(force: Bool = false) -> SmartMixTrackAnalysis? {
        guard let sourceSampleRate, sourceSampleRate > 0 else { return nil }
        let duration = Double(totalFrameCount) / sourceSampleRate
        guard force || duration >= nextPublicationDuration else { return nil }
        if !force {
            while nextPublicationDuration <= duration {
                nextPublicationDuration += Self.publicationInterval
            }
        }
        guard let tempo = SmartMixRhythmDetector.estimateTempo(
            rmsEnvelope: envelope,
            envelopeSampleRate: Self.envelopeSampleRate
        ) else { return nil }
        return SmartMixTrackAnalysis(
            backend: .streamingPCM,
            analyzedDuration: duration,
            tempo: tempo
        )
    }

    private func reset(for sampleRate: Double) {
        sourceSampleRate = sampleRate
        envelope.removeAll(keepingCapacity: true)
        pendingWindowEnergy = 0
        pendingWindowSampleCount = 0
        pendingWindowFrameCoverage = 0
        totalFrameCount = 0
        nextPublicationDuration = Self.firstPublicationDuration
    }
}

enum AudioSilenceStream {
    private static let silenceThresholdDB = -50.0
    private static let analysisWindowDuration: TimeInterval = 0.01

    static func trim(
        _ source: AudioBufferStream,
        leading: Bool,
        trailing: Bool,
        maximumLeadingDuration: TimeInterval = 12,
        maximumTrailingDuration: TimeInterval = 12,
        onProfile: (@Sendable (AudioSilenceProfile) -> Void)? = nil
    ) -> AudioBufferStream {
        trimAnalyzingSmartMix(
            source,
            leading: leading,
            trailing: trailing,
            maximumLeadingDuration: maximumLeadingDuration,
            maximumTrailingDuration: maximumTrailingDuration,
            onSmartMixAnalysis: nil,
            onProfile: onProfile
        )
    }

    static func trimAnalyzingSmartMix(
        _ source: AudioBufferStream,
        leading: Bool,
        trailing: Bool,
        maximumLeadingDuration: TimeInterval = 12,
        maximumTrailingDuration: TimeInterval = 12,
        onSmartMixAnalysis: (@Sendable (SmartMixTrackAnalysis) -> Void)? = nil,
        onProfile: (@Sendable (AudioSilenceProfile) -> Void)? = nil
    ) -> AudioBufferStream {
        guard leading || trailing || onSmartMixAnalysis != nil else { return source }

        let iteratorBox = AudioSilenceIteratorBox(source.makeAsyncIterator())
        return AudioBufferStreamFactory.make { continuation in
            let task = Task {
                var isFindingLeadingBoundary = leading
                var leadingTrimmedDuration: TimeInterval = 0
                var trailingTrimmedDuration: TimeInterval = 0
                var playableDuration: TimeInterval = 0
                var pendingTail: [AVAudioPCMBuffer] = []
                var pendingTailDuration: TimeInterval = 0
                let smartMixAnalyzer = onSmartMixAnalysis == nil
                    ? nil
                    : StreamingPCMSmartMixAnalyzer()

                func yield(_ buffer: AVAudioPCMBuffer) async throws {
                    guard buffer.frameLength > 0 else { return }
                    try await AudioBufferStreamFactory.yieldWithBackpressure(
                        buffer,
                        to: continuation
                    )
                    playableDuration += duration(of: buffer)
                }

                func flushPendingTail() async throws {
                    for buffer in pendingTail {
                        try await yield(buffer)
                    }
                    pendingTail.removeAll(keepingCapacity: true)
                    pendingTailDuration = 0
                }

                func boundPendingTail() async throws {
                    let limit = max(0, maximumTrailingDuration)
                    while pendingTailDuration > limit, !pendingTail.isEmpty {
                        let excess = pendingTailDuration - limit
                        let first = pendingTail.removeFirst()
                        let firstDuration = duration(of: first)
                        if firstDuration <= excess + 0.000_001 {
                            pendingTailDuration -= firstDuration
                            try await yield(first)
                            continue
                        }

                        let sampleRate = first.format.sampleRate
                        let framesToFlush = min(
                            first.frameLength,
                            AVAudioFrameCount(max(1, Int((excess * sampleRate).rounded(.up))))
                        )
                        if framesToFlush >= first.frameLength {
                            pendingTailDuration -= firstDuration
                            try await yield(first)
                        } else {
                            let prefix = try slice(
                                first,
                                skipping: 0,
                                count: framesToFlush
                            )
                            let suffix = try slice(
                                first,
                                skipping: framesToFlush,
                                count: first.frameLength - framesToFlush
                            )
                            pendingTail.insert(suffix, at: 0)
                            let flushedDuration = duration(of: prefix)
                            pendingTailDuration -= flushedDuration
                            try await yield(prefix)
                        }
                    }
                }

                do {
                    while var buffer = try await iteratorBox.next() {
                        try Task.checkCancellation()
                        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
                            continue
                        }

                        if isFindingLeadingBoundary {
                            let remainingBudget = max(
                                0,
                                maximumLeadingDuration - leadingTrimmedDuration
                            )
                            let range = audibleRange(in: buffer)
                            let budgetFrames = AVAudioFrameCount(min(
                                Double(buffer.frameLength),
                                (remainingBudget * buffer.format.sampleRate).rounded(.down)
                            ))

                            if let range {
                                let framesToTrim = min(range.lowerBound, budgetFrames)
                                leadingTrimmedDuration += Double(framesToTrim)
                                    / buffer.format.sampleRate
                                isFindingLeadingBoundary = false
                                if framesToTrim >= buffer.frameLength { continue }
                                if framesToTrim > 0 {
                                    buffer = try slice(
                                        buffer,
                                        skipping: framesToTrim,
                                        count: buffer.frameLength - framesToTrim
                                    )
                                }
                            } else if budgetFrames >= buffer.frameLength {
                                leadingTrimmedDuration += duration(of: buffer)
                                continue
                            } else {
                                isFindingLeadingBoundary = false
                                leadingTrimmedDuration += Double(budgetFrames)
                                    / buffer.format.sampleRate
                                if budgetFrames >= buffer.frameLength { continue }
                                if budgetFrames > 0 {
                                    buffer = try slice(
                                        buffer,
                                        skipping: budgetFrames,
                                        count: buffer.frameLength - budgetFrames
                                    )
                                }
                            }
                        }

                        smartMixAnalyzer?.append(buffer)
                        if let analysis = smartMixAnalyzer?.snapshotIfNeeded() {
                            onSmartMixAnalysis?(analysis)
                        }

                        guard trailing else {
                            try await yield(buffer)
                            continue
                        }

                        if let range = audibleRange(in: buffer) {
                            try await flushPendingTail()
                            if range.upperBound < buffer.frameLength {
                                let audible = try slice(
                                    buffer,
                                    skipping: 0,
                                    count: range.upperBound
                                )
                                let quietTail = try slice(
                                    buffer,
                                    skipping: range.upperBound,
                                    count: buffer.frameLength - range.upperBound
                                )
                                try await yield(audible)
                                pendingTail.append(quietTail)
                                pendingTailDuration += duration(of: quietTail)
                            } else {
                                try await yield(buffer)
                            }
                        } else {
                            pendingTail.append(buffer)
                            pendingTailDuration += duration(of: buffer)
                        }
                        try await boundPendingTail()
                    }

                    trailingTrimmedDuration = pendingTailDuration
                    pendingTail.removeAll()
                    pendingTailDuration = 0
                    onProfile?(AudioSilenceProfile(
                        leadingTrimmedDuration: leadingTrimmedDuration,
                        trailingTrimmedDuration: trailingTrimmedDuration,
                        playableDuration: playableDuration
                    ))
                    if let analysis = smartMixAnalyzer?.snapshotIfNeeded(force: true) {
                        onSmartMixAnalysis?(analysis)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private static func audibleRange(
        in buffer: AVAudioPCMBuffer
    ) -> Range<AVAudioFrameCount>? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let isInterleaved = buffer.format.isInterleaved

        func detect<T: BinaryFloatingPoint>(
            _: T.Type,
            normalize: @escaping (T) -> Float
        ) -> Range<AVAudioFrameCount>? {
            let result = AudioSignalBoundaryDetector.audibleFrameRange(
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: buffer.format.sampleRate,
                silenceThresholdDB: silenceThresholdDB,
                windowDuration: analysisWindowDuration
            ) { frame, channel in
                if isInterleaved {
                    guard let data = audioBuffers.first?.mData else { return 0 }
                    let samples = data.assumingMemoryBound(to: T.self)
                    return normalize(samples[frame * channelCount + channel])
                }
                guard channel < audioBuffers.count,
                      let data = audioBuffers[channel].mData else { return 0 }
                let samples = data.assumingMemoryBound(to: T.self)
                return normalize(samples[frame])
            }
            return result.map {
                AVAudioFrameCount($0.lowerBound)..<AVAudioFrameCount($0.upperBound)
            }
        }

        func detectInteger<T: FixedWidthInteger & SignedInteger>(
            _: T.Type,
            divisor: Float
        ) -> Range<AVAudioFrameCount>? {
            let result = AudioSignalBoundaryDetector.audibleFrameRange(
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: buffer.format.sampleRate,
                silenceThresholdDB: silenceThresholdDB,
                windowDuration: analysisWindowDuration
            ) { frame, channel in
                if isInterleaved {
                    guard let data = audioBuffers.first?.mData else { return 0 }
                    let samples = data.assumingMemoryBound(to: T.self)
                    return Float(samples[frame * channelCount + channel]) / divisor
                }
                guard channel < audioBuffers.count,
                      let data = audioBuffers[channel].mData else { return 0 }
                let samples = data.assumingMemoryBound(to: T.self)
                return Float(samples[frame]) / divisor
            }
            return result.map {
                AVAudioFrameCount($0.lowerBound)..<AVAudioFrameCount($0.upperBound)
            }
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return detect(Float.self, normalize: { $0 })
        case .pcmFormatFloat64:
            return detect(Double.self, normalize: { Float($0) })
        case .pcmFormatInt16:
            return detectInteger(Int16.self, divisor: Float(Int16.max))
        case .pcmFormatInt32:
            return detectInteger(Int32.self, divisor: Float(Int32.max))
        case .otherFormat:
            // An unknown packed PCM representation must never be discarded as
            // silence. Treat the complete buffer as audible and preserve it.
            return 0..<buffer.frameLength
        @unknown default:
            return 0..<buffer.frameLength
        }
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        skipping: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard count > 0,
              skipping <= source.frameLength,
              skipping + count <= source.frameLength,
              let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: count
              ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        destination.frameLength = count

        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        let sourceOffset = Int(skipping) * bytesPerFrame
        let byteCount = Int(count) * bytesPerFrame
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceOffset + byteCount <= Int(sourceBuffers[index].mDataByteSize),
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            memcpy(destinationData, sourceData.advanced(by: sourceOffset), byteCount)
        }
        return destination
    }
}

#if canImport(MusicUnderstanding)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
enum MusicUnderstandingSmartMixAnalyzer {
    static func analyze(fileURL: URL) async throws -> SmartMixTrackAnalysis {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let duration = try await asset.load(.duration).seconds
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await session.analyze(for: [
            .rhythm,
            .structure,
            .loudness,
        ])

        let beats = result.rhythm?.beats.compactMap(finiteSeconds) ?? []
        let bpm = result.rhythm?.beatsPerMinute.map(Double.init)
        let tempo = bpm.flatMap { value -> SmartMixTempoEstimate? in
            guard value.isFinite, value > 0 else { return nil }
            return SmartMixTempoEstimate(
                beatsPerMinute: value,
                confidence: beats.count >= 4 ? 1 : 0.6,
                firstBeatTime: beats.first ?? 0
            )
        }
        let barStartTimes = result.rhythm?.bars.compactMap(finiteSeconds) ?? []
        let sectionStartTimes = result.structure?.sections.compactMap {
            finiteSeconds($0.start)
        } ?? []
        let loudness = result.loudness?.integrated.value

        return SmartMixTrackAnalysis(
            backend: .musicUnderstanding,
            analyzedDuration: duration.isFinite ? max(0, duration) : 0,
            tempo: tempo,
            barStartTimes: barStartTimes,
            sectionStartTimes: sectionStartTimes,
            integratedLoudnessDB: loudness.map(Double.init)
        )
    }

    private static func finiteSeconds(_ time: CMTime) -> TimeInterval? {
        let seconds = time.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
#endif
