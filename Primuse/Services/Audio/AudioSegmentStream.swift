@preconcurrency import AVFoundation
import Foundation

private final class AudioSegmentIteratorBox: @unchecked Sendable {
    private var iterator: AudioBufferStream.AsyncIterator

    init(_ iterator: AudioBufferStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

/// Trims decoded PCM to a CUE track's INDEX 01 boundaries. The decoder still
/// reads the physical image while the audio engine sees a zero-based track.
enum AudioSegmentStream {
    static func trim(
        _ source: AudioBufferStream,
        startTime: TimeInterval?,
        endTime: TimeInterval?
    ) -> AudioBufferStream {
        let start = max(0, startTime ?? 0)
        let end = endTime.flatMap { $0 > start ? $0 : nil }
        guard start > 0 || end != nil else { return source }
        let iteratorBox = AudioSegmentIteratorBox(source.makeAsyncIterator())

        return AudioBufferStreamFactory.make { continuation in
            let task = Task {
                do {
                    var sourceFramePosition: Int64 = 0
                    while let buffer = try await iteratorBox.next() {
                        try Task.checkCancellation()
                        let sampleRate = buffer.format.sampleRate
                        guard sampleRate > 0 else { continue }

                        let segmentStartFrame = Int64((start * sampleRate).rounded(.down))
                        let segmentEndFrame = end.map { Int64(($0 * sampleRate).rounded(.down)) }
                        let bufferStart = sourceFramePosition
                        let bufferEnd = bufferStart + Int64(buffer.frameLength)
                        sourceFramePosition = bufferEnd

                        if bufferEnd <= segmentStartFrame { continue }
                        if let segmentEndFrame, bufferStart >= segmentEndFrame { break }

                        let keepStart = max(bufferStart, segmentStartFrame)
                        let keepEnd = min(bufferEnd, segmentEndFrame ?? bufferEnd)
                        guard keepEnd > keepStart else { continue }
                        let skip = AVAudioFrameCount(keepStart - bufferStart)
                        let count = AVAudioFrameCount(keepEnd - keepStart)

                        if skip == 0, count == buffer.frameLength {
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                buffer,
                                to: continuation
                            )
                        } else {
                            let sliced = try slice(buffer, skipping: skip, count: count)
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                sliced,
                                to: continuation
                            )
                        }
                        if let segmentEndFrame, keepEnd >= segmentEndFrame { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        skipping: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        destination.frameLength = count

        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { throw AudioDecoderError.bufferAllocationFailed }
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
                  sourceOffset + byteCount <= Int(sourceBuffers[index].mDataByteSize) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            memcpy(destinationData, sourceData.advanced(by: sourceOffset), byteCount)
        }
        return destination
    }
}
