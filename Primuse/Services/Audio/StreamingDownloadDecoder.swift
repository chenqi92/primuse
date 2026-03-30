@preconcurrency import AVFoundation
import Foundation
import SFBAudioEngine

/// Downloads audio from a remote URL via URLSession (handles self-signed HTTPS),
/// then decodes using SFBAudioEngine's AudioDecoder which supports:
/// FLAC, MP3, AAC, ALAC, WAV, AIFF, Ogg Vorbis, Ogg Opus, WavPack, APE, TTA,
/// Musepack, Shorten, DSD, and all Core Audio / libsndfile formats.
///
/// Architecture:
/// 1. Download complete file via URLSession with InsecureURLSessionDelegate
/// 2. Decode using SFBAudioEngine AudioDecoder (universal format support)
/// 3. Convert to engine output format if needed (via AVAudioConverter)
/// 4. Move downloaded file to cache directory for future instant playback
final class StreamingDownloadDecoder: Sendable {
    private let bufferFrameCount: AVAudioFrameCount = 8192

    func canDecode(url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// Download and decode audio from a remote URL.
    /// - Parameters:
    ///   - url: Remote HTTP/HTTPS URL
    ///   - outputFormat: Target PCM format for the audio engine
    ///   - cacheFileURL: If provided, the downloaded file is moved here after decoding starts
    /// - Returns: AsyncThrowingStream of PCM buffers ready for AVAudioPlayerNode
    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        cacheFileURL: URL? = nil,
        fileExtension: String? = nil
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let tempPath = NSTemporaryDirectory() + "primuse_dl_\(UUID().uuidString)"
                let tempURL = URL(fileURLWithPath: tempPath)

                do {
                    // Step 1: Download the complete file
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 600
                    let session = URLSession(
                        configuration: config,
                        delegate: SmartSSLDelegate(),
                        delegateQueue: nil
                    )

                    plog("🌊 StreamingDecoder: downloading from \(url.host ?? "?")")
                    let startTime = CFAbsoluteTimeGetCurrent()

                    let (downloadedURL, response) = try await session.download(from: url)

                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw AudioDecoderError.decodingFailed("HTTP \(code)")
                    }

                    // Move to our temp path (system temp files get cleaned up)
                    try FileManager.default.moveItem(at: downloadedURL, to: tempURL)

                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.size] as? Int64) ?? 0
                    plog("🌊 StreamingDecoder: downloaded \(fileSize / 1024)KB in \(String(format: "%.1f", elapsed))s")

                    if Task.isCancelled { throw CancellationError() }

                    // Step 2: Decode using SFBAudioEngine (supports FLAC, APE, WV, TTA, DSD, etc.)
                    // Use explicit file extension (from Song.fileFormat) or fall back to URL extension
                    let ext = (fileExtension ?? url.pathExtension).lowercased()
                    let typedTempURL: URL
                    if !ext.isEmpty {
                        let typedPath = tempPath + ".\(ext)"
                        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: typedPath))
                        typedTempURL = URL(fileURLWithPath: typedPath)
                    } else {
                        typedTempURL = tempURL
                    }

                    let decoder = try SFBAudioEngine.AudioDecoder(url: typedTempURL)
                    try decoder.open()

                    let srcFmt = decoder.processingFormat
                    let totalFrames = decoder.length

                    plog("🌊 SFBDecoder: format=sr\(srcFmt.sampleRate)/ch\(srcFmt.channelCount) length=\(totalFrames)")

                    let directRead = srcFmt.sampleRate == outputFormat.sampleRate
                        && srcFmt.channelCount == outputFormat.channelCount

                    if directRead {
                        // Direct read — formats match
                        while decoder.position < totalFrames {
                            if Task.isCancelled { break }
                            let remaining = AVAudioFrameCount(totalFrames - decoder.position)
                            let toRead = min(bufferFrameCount, remaining)
                            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: toRead) else { break }
                            try decoder.decode(into: buf, length: toRead)
                            if buf.frameLength > 0 {
                                nonisolated(unsafe) let sendBuf = buf
                                continuation.yield(sendBuf)
                            }
                        }
                    } else {
                        // Need format conversion (e.g., 48kHz FLAC → 44.1kHz engine)
                        guard let converter = AVAudioConverter(from: srcFmt, to: outputFormat) else {
                            throw AudioDecoderError.converterCreationFailed
                        }
                        plog("🌊 SFBDecoder: converting sr\(srcFmt.sampleRate)→\(outputFormat.sampleRate)")

                        while decoder.position < totalFrames {
                            if Task.isCancelled { break }
                            let remaining = AVAudioFrameCount(totalFrames - decoder.position)
                            let toRead = min(bufferFrameCount, remaining)
                            guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: toRead) else { break }
                            try decoder.decode(into: inBuf, length: toRead)
                            guard inBuf.frameLength > 0 else { break }

                            let outCap = AVAudioFrameCount(
                                Double(inBuf.frameLength) * outputFormat.sampleRate / srcFmt.sampleRate
                            ) + 1
                            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { break }

                            var convError: NSError?
                            let inputBuffer = inBuf
                            converter.convert(to: outBuf, error: &convError) { _, outStatus in
                                outStatus.pointee = .haveData
                                return inputBuffer
                            }
                            if let e = convError { throw e }
                            if outBuf.frameLength > 0 {
                                continuation.yield(outBuf)
                            }
                        }
                    }

                    try? decoder.close()

                    // Step 3: Cache the downloaded file
                    if let cacheURL = cacheFileURL {
                        try? FileManager.default.createDirectory(
                            at: cacheURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? FileManager.default.removeItem(at: cacheURL)
                        try? FileManager.default.moveItem(at: typedTempURL, to: cacheURL)
                        plog("🌊 SFBDecoder: cached → \(cacheURL.lastPathComponent)")
                    } else {
                        try? FileManager.default.removeItem(at: typedTempURL)
                    }

                    continuation.finish()
                } catch {
                    // Clean up temp files
                    try? FileManager.default.removeItem(at: tempURL)
                    let cleanupExt = (fileExtension ?? url.pathExtension).lowercased()
                    if !cleanupExt.isEmpty {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempPath + ".\(cleanupExt)"))
                    }
                    if !Task.isCancelled {
                        plog("⚠️ SFBDecoder failed: \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}
