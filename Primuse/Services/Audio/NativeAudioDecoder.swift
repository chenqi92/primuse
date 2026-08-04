@preconcurrency import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

private final class ConverterInputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}

private final class InputSourceBox: @unchecked Sendable {
    let value: InputSource
    init(_ value: InputSource) { self.value = value }
}

final class NativeAudioDecoder: PrimuseAudioDecoder {
    private let bufferFrameCount: AVAudioFrameCount = 8192

    /// 解码循环里碰到「0 帧且无进度」时的退避节奏与放弃阈值。退避避免截断文件
    /// 100% CPU 空转; 阈值给 HTTP 流式源足够的缓冲等待时间(网络抖动), 只有持续
    /// 无进度才判死流退出。
    fileprivate static let decodeStallBackoffNanos: UInt64 = 15_000_000   // 15ms
    fileprivate static let maxDecodeStallNanos: UInt64 = 8_000_000_000    // 8s 无进度→放弃

    func canDecode(url: URL) -> Bool {
        // SFBAudioEngine supports a huge range of formats
        let ext = url.pathExtension.lowercased()
        return SFBAudioEngine.AudioDecoder.handlesPaths(withExtension: ext)
            || SFBAudioEngine.DSDDecoder.handlesPaths(withExtension: ext)
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        if isDSD(url) {
            let decoder = try SFBAudioEngine.DSDDecoder(url: url)
            try decoder.open()
            let format = decoder.processingFormat
            let packetCount = decoder.count
            // One SFBAudioEngine DSD packet carries eight 1-bit samples.
            let duration = packetCount > 0 && format.sampleRate > 0
                ? Double(packetCount) * 8 / format.sampleRate : 0
            try? decoder.close()
            return AudioFileInfo(
                duration: duration,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                bitDepth: 1,
                bitRate: nil,
                format: url.pathExtension.uppercased()
            )
        }

        // Try SFBAudioEngine first for broader format support
        let decoder = try SFBAudioEngine.AudioDecoder(url: url)
        try decoder.open()
        let format = decoder.processingFormat
        let totalFrames = decoder.length
        let duration = totalFrames > 0 ? Double(totalFrames) / format.sampleRate : 0
        try? decoder.close()

        return AudioFileInfo(
            duration: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            bitDepth: Int(format.settings[AVLinearPCMBitDepthKey] as? Int ?? 0),
            format: url.pathExtension.uppercased()
        )
    }

    /// Decode by streaming from a custom `InputSource`. Used by cloud
    /// playback where bytes are fetched via HTTP Range and cached lazily —
    /// see `CloudPlaybackSource`. Same decoding pipeline as URL-based, just
    /// constructed differently.
    /// `onResolveSourceLength` fires once per decode session as soon as
    /// SFB reports the source's PCM frame count. For cloud-streamed
    /// MP3s without an XING/LAME header, SFB's value is the only
    /// trustworthy duration we'll ever get (backfill saw a truncated
    /// 256KB head and had to guess). The caller writes it back to the
    /// library so the next render shows the real time.
    func decode(
        from inputSource: InputSource,
        outputFormat: AVAudioFormat,
        startingAt startTime: TimeInterval? = nil,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) -> AudioBufferStream {
        // SFBAudioEngine's InputSource isn't formally Sendable but it's
        // safe to hand off across one Task boundary — the decoder owns
        // it from then on. Box it to silence the strict-concurrency check.
        let inputBox = InputSourceBox(inputSource)
        return AudioBufferStreamFactory.make { continuation in
            let task = Task {
                do {
                    let prepared = try self.prepareDecoder(
                        startingAt: startTime,
                        reopenAfterFailedSeek: false,
                        allowDecodeAndDiscardFallback: false
                    ) {
                        try SFBAudioEngine.AudioDecoder(inputSource: inputBox.value)
                    }
                    try await self.runDecode(
                        decoder: prepared.decoder,
                        outputFormat: outputFormat,
                        framesToDiscard: prepared.framesToDiscard,
                        continuation: continuation,
                        onResolveSourceLength: onResolveSourceLength
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Protocol-witness signature for `PrimuseAudioDecoder.decode`. The
    /// extended overload below adds the optional length callback used by
    /// `AudioPlayerService` to write back real durations — kept as a
    /// separate method (not just a default arg) so the protocol witness
    /// matches exactly and no other decoder implementation has to be
    /// modified.
    func decode(from url: URL, outputFormat: AVAudioFormat) -> AudioBufferStream {
        decode(from: url, outputFormat: outputFormat, dsdMode: .pcm, onResolveSourceLength: nil)
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AudioBufferStream {
        decode(from: url, outputFormat: outputFormat, dsdMode: .pcm, onResolveSourceLength: onResolveSourceLength)
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        startingAt startTime: TimeInterval?,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AudioBufferStream {
        decode(
            from: url,
            outputFormat: outputFormat,
            dsdMode: .pcm,
            startingAt: startTime,
            onResolveSourceLength: onResolveSourceLength
        )
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        dsdMode: DSDPlaybackMode,
        startingAt startTime: TimeInterval? = nil,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AudioBufferStream {
        AudioBufferStreamFactory.make { continuation in
            let task = Task {
                do {
                    let prepared = try self.prepareDecoder(
                        startingAt: startTime,
                        reopenAfterFailedSeek: true,
                        allowDecodeAndDiscardFallback: true
                    ) {
                        if self.isDSD(url) {
                            switch dsdMode {
                            case .dop:
                                return try SFBAudioEngine.DoPDecoder(url: url)
                            case .automatic, .pcm:
                                // SFBAudioEngine's native converter deliberately
                                // supports DSD64. Higher-rate DSD falls back to the
                                // FFmpeg PCM path in AudioPlayerService.
                                return try SFBAudioEngine.DSDPCMDecoder(url: url)
                            }
                        }
                        return try SFBAudioEngine.AudioDecoder(url: url)
                    }
                    plog("🎵 SFBDecoder: file=\(url.lastPathComponent)")
                    try await self.runDecode(
                        decoder: prepared.decoder,
                        outputFormat: outputFormat,
                        framesToDiscard: prepared.framesToDiscard,
                        continuation: continuation,
                        onResolveSourceLength: onResolveSourceLength
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared decode loop. Reads PCM from the open `decoder`, converts to
    /// `outputFormat` if needed, yields buffers via the continuation.
    private func runDecode(
        decoder: any SFBAudioEngine.PCMDecoding,
        outputFormat: AVAudioFormat,
        framesToDiscard initialFramesToDiscard: AVAudioFramePosition = 0,
        continuation: AudioBufferStream.Continuation,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) async throws {
        let sourceFormat = decoder.processingFormat
        let totalFrames = decoder.length
        var framesToDiscard = max(0, initialFramesToDiscard)

        plog("🎵 SFBDecoder: sourceFormat=sr\(sourceFormat.sampleRate)/ch\(sourceFormat.channelCount) length=\(totalFrames) outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount)")

        // Surface the resolved duration so the caller (AudioPlayerService)
        // can write it back to the library, replacing whatever placeholder
        // backfill stuffed in there from its 256KB-head estimate. Guarded
        // against zero sample rate (some malformed files) — caller's
        // closure ignores zero anyway.
        if let onResolveSourceLength, sourceFormat.sampleRate > 0, totalFrames > 0 {
            let durationSeconds = Double(totalFrames) / sourceFormat.sampleRate
            onResolveSourceLength(durationSeconds)
        }

        if sourceFormat == outputFormat {
            plog("🎵 SFBDecoder: direct read (formats match)")
            var stallNanos: UInt64 = 0
            while !Task.isCancelled,
                  totalFrames < 0 || decoder.position < totalFrames {
                let framesToRead: AVAudioFrameCount
                if totalFrames >= 0 {
                    let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                    framesToRead = min(bufferFrameCount, remainingFrames)
                } else {
                    framesToRead = bufferFrameCount
                }
                guard var buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                let positionBefore = decoder.position
                try decoder.decode(into: buffer, length: framesToRead)
                if buffer.frameLength > 0 {
                    stallNanos = 0
                    if framesToDiscard > 0 {
                        let discarded = min(
                            framesToDiscard,
                            AVAudioFramePosition(buffer.frameLength)
                        )
                        framesToDiscard -= discarded
                        if discarded == AVAudioFramePosition(buffer.frameLength) {
                            continue
                        }
                        buffer = try Self.slice(
                            buffer,
                            skipping: AVAudioFrameCount(discarded)
                        )
                    }
                    try await AudioBufferStreamFactory.yieldWithBackpressure(
                        buffer,
                        to: continuation
                    )
                } else if decoder.position <= positionBefore {
                    // 0 帧且 position 没前进: 要么是 HTTP 流式源在等下一段 Range
                    // 数据(瞬时, 数据到了就恢复), 要么是截断/损坏文件卡死(永不前进)。
                    // 退避 sleep 既消除原来的 100% CPU 空转, 又不会把还在缓冲的流过早
                    // 掐断; 长时间(Self.maxDecodeStallNanos)无任何进度才判定为死流并退出。
                    stallNanos += Self.decodeStallBackoffNanos
                    if stallNanos >= Self.maxDecodeStallNanos { break }
                    try await Task.sleep(nanoseconds: Self.decodeStallBackoffNanos)
                }
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                continuation.finish(throwing: AudioDecoderError.converterCreationFailed)
                return
            }
            if AudioChannelConversionPolicy.requiresDownmix(
                sourceChannelCount: Int(sourceFormat.channelCount),
                outputChannelCount: Int(outputFormat.channelCount)
            ) {
                converter.downmix = true
                plog("🔊 Native decoder downmix enabled: ch\(sourceFormat.channelCount) → ch\(outputFormat.channelCount)")
            }
            var stallNanos: UInt64 = 0
            while !Task.isCancelled,
                  totalFrames < 0 || decoder.position < totalFrames {
                let framesToRead: AVAudioFrameCount
                if totalFrames >= 0 {
                    let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                    framesToRead = min(bufferFrameCount, remainingFrames)
                } else {
                    framesToRead = bufferFrameCount
                }
                guard var inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                let positionBefore = decoder.position
                try decoder.decode(into: inputBuffer, length: framesToRead)
                if inputBuffer.frameLength == 0 {
                    if decoder.position > positionBefore {
                        stallNanos = 0
                        continue
                    }
                    stallNanos += Self.decodeStallBackoffNanos
                    if stallNanos >= Self.maxDecodeStallNanos { break }
                    try await Task.sleep(nanoseconds: Self.decodeStallBackoffNanos)
                    continue
                }
                stallNanos = 0
                if framesToDiscard > 0 {
                    let discarded = min(
                        framesToDiscard,
                        AVAudioFramePosition(inputBuffer.frameLength)
                    )
                    framesToDiscard -= discarded
                    if discarded == AVAudioFramePosition(inputBuffer.frameLength) {
                        continue
                    }
                    inputBuffer = try Self.slice(
                        inputBuffer,
                        skipping: AVAudioFrameCount(discarded)
                    )
                }
                let converterInput = ConverterInputBuffer(inputBuffer)

                let outputFrameCapacity = AVAudioFrameCount(
                    Double(inputBuffer.frameLength) * outputFormat.sampleRate / sourceFormat.sampleRate
                ) + 64
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if let input = converterInput.take() {
                        outStatus.pointee = .haveData
                        return input
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                if outputBuffer.frameLength > 0 {
                    try await AudioBufferStreamFactory.yieldWithBackpressure(
                        outputBuffer,
                        to: continuation
                    )
                }
            }
            try await drain(
                converter: converter,
                outputFormat: outputFormat,
                continuation: continuation
            )
        }

        try? decoder.close()
        continuation.finish()
    }

    private struct PreparedDecoder {
        let decoder: any SFBAudioEngine.PCMDecoding
        let framesToDiscard: AVAudioFramePosition
    }

    /// Prefer the decoder's native seek, but preserve the old always-works
    /// behaviour for formats or custom InputSources that cannot seek. A failed
    /// URL-backed seek is reopened from frame zero before falling back. Custom
    /// InputSources are kept open because closing `CloudInputSourceObjC`
    /// intentionally releases its fetch closure; SFB seek failures leave their
    /// frame position unchanged in the unsupported-seek case.
    private func prepareDecoder(
        startingAt startTime: TimeInterval?,
        reopenAfterFailedSeek: Bool,
        allowDecodeAndDiscardFallback: Bool,
        makeDecoder: () throws -> any SFBAudioEngine.PCMDecoding
    ) throws -> PreparedDecoder {
        var decoder = try makeDecoder()
        try decoder.open()
        guard let target = seekTarget(decoder: decoder, startTime: startTime) else {
            return PreparedDecoder(decoder: decoder, framesToDiscard: 0)
        }

        guard decoder.supportsSeeking else {
            guard allowDecodeAndDiscardFallback else {
                throw AudioDecoderError.seekUnavailable
            }
            plog("⚠️ SFBDecoder: decoder is not seekable; falling back to decode-and-discard through frame \(target)")
            return PreparedDecoder(
                decoder: decoder,
                framesToDiscard: max(0, target - max(0, decoder.position))
            )
        }

        do {
            try decoder.seek(to: target)
            return PreparedDecoder(decoder: decoder, framesToDiscard: 0)
        } catch {
            let seekError = error
            if reopenAfterFailedSeek {
                try? decoder.close()
                decoder = try makeDecoder()
                try decoder.open()
            }

            let currentPosition = max(0, decoder.position)
            guard currentPosition <= target else { throw seekError }
            guard allowDecodeAndDiscardFallback else {
                plog("⚠️ SFBDecoder: remote native seek failed; refusing unbounded decode-and-discard through frame \(target)")
                throw AudioDecoderError.seekUnavailable
            }
            plog("⚠️ SFBDecoder: native seek failed (\(seekError.localizedDescription)); falling back to decode-and-discard through frame \(target)")
            return PreparedDecoder(
                decoder: decoder,
                framesToDiscard: target - currentPosition
            )
        }
    }

    private func seekTarget(
        decoder: any SFBAudioEngine.PCMDecoding,
        startTime: TimeInterval?
    ) -> AVAudioFramePosition? {
        guard let startTime,
              startTime.isFinite,
              startTime > 0,
              decoder.processingFormat.sampleRate > 0 else { return nil }
        let requested = AVAudioFramePosition(
            (startTime * decoder.processingFormat.sampleRate).rounded(.down)
        )
        return decoder.length > 0
            ? min(max(0, requested), decoder.length - 1)
            : max(0, requested)
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        skipping: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard skipping < source.frameLength else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let frameCount = source.frameLength - skipping
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: frameCount
        ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        destination.frameLength = frameCount

        let bytesPerFrame = Int(
            source.format.streamDescription.pointee.mBytesPerFrame
        )
        guard bytesPerFrame > 0 else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        let sourceOffset = Int(skipping) * bytesPerFrame
        let byteCount = Int(frameCount) * bytesPerFrame
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceOffset + byteCount <= Int(sourceBuffers[index].mDataByteSize),
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            memcpy(destinationData, sourceData.advanced(by: sourceOffset), byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }

    private func drain(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        continuation: AudioBufferStream.Continuation
    ) async throws {
        while !Task.isCancelled {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: bufferFrameCount
            ) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0 {
                try await AudioBufferStreamFactory.yieldWithBackpressure(
                    output,
                    to: continuation
                )
            }
            if status == .endOfStream || output.frameLength == 0 { return }
            if status == .error {
                throw AudioDecoderError.decodingFailed("Native PCM converter drain failed")
            }
        }
    }

    func dsdOutputFormat(for url: URL, mode: DSDPlaybackMode) throws -> AVAudioFormat? {
        guard isDSD(url) else { return nil }
        let decoder: any SFBAudioEngine.PCMDecoding
        switch mode {
        case .dop:
            decoder = try SFBAudioEngine.DoPDecoder(url: url)
        case .automatic, .pcm:
            decoder = try SFBAudioEngine.DSDPCMDecoder(url: url)
        }
        try decoder.open()
        let format = decoder.processingFormat
        try? decoder.close()
        return format
    }

    func isDSD(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "dsf" || ext == "dff"
    }
}

enum AudioDecoderError: Error, LocalizedError {
    case bufferAllocationFailed
    case converterCreationFailed
    case unsupportedFormat(String)
    case decodingFailed(String)
    case seekUnavailable

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Failed to allocate audio buffer"
        case .converterCreationFailed: return "Failed to create audio converter"
        case .unsupportedFormat(let fmt): return "Unsupported audio format: \(fmt)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .seekUnavailable: return "Random access requires a complete local audio file"
        }
    }
}
