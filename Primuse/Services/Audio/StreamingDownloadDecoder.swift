@preconcurrency import AVFoundation
import Foundation

/// Full-download fallback for remote URLs (handles self-signed HTTPS),
/// then decodes using the central format router (SFBAudioEngine or FFmpeg):
/// FLAC, MP3, AAC, ALAC, WAV, AIFF, Ogg Vorbis, Ogg Opus, WavPack, APE, TTA,
/// Musepack, Shorten, DSD, and all Core Audio / libsndfile formats.
///
/// Architecture:
/// 1. Download complete file via URLSession with InsecureURLSessionDelegate
/// 2. Decode using the routed local decoder
/// 3. Convert to engine output format if needed (via AVAudioConverter)
/// 4. Move downloaded file to cache directory for future instant playback
///
/// Normal HTTP(S) playback should prefer `CloudPlaybackSource.makeHTTPInputSource`
/// so audio can start from byte ranges. This class remains for URLs whose
/// length is unknown or servers that do not cooperate with Range reads.
final class StreamingDownloadDecoder: Sendable {

    func canDecode(url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// Download a remote URL completely, then decode it.
    /// - Parameters:
    ///   - url: Remote HTTP/HTTPS URL
    ///   - outputFormat: Target PCM format for the audio engine
    ///   - cacheFileURL: If provided, the downloaded file is moved here after decoding starts
    /// - Returns: AsyncThrowingStream of PCM buffers ready for AVAudioPlayerNode
    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        cacheFileURL: URL? = nil,
        fileExtension: String? = nil,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) -> AudioBufferStream {
        AudioBufferStreamFactory.make { continuation in
            let task = Task {
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

                    // OneDrive 个人版 CDN(microsoftpersonalcontent.com)对非浏览器
                    // User-Agent 的整文件下载会限速到 ~1-2MB/s,大文件因此拖到几十秒
                    // 才下完(首缓冲超时)。带上浏览器 UA 后下载速度对齐网页端。
                    var request = URLRequest(url: url)
                    request.setValue(
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                        forHTTPHeaderField: "User-Agent"
                    )
                    let (downloadedURL, response) = try await session.download(for: request)

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

                    // 调试用: 如果 SFBDecoder 抱怨格式不对,多半是 DSM 返回了
                    // JSON/HTML 错误体而不是音频(SID 过期 / 路径错 / 权限不足
                    // 等)。打头 80 字节,看到 "{" / "<!DOCTYPE" 一眼就知道。
                    // 仅在文件可疑过小(多半是错误 JSON/HTML 而非音频)时打印 head。
                    // 原条件 `fileSize < 4096 || fileSize > 0` 对任意非负值恒真。
                    if fileSize < 4096, let handle = try? FileHandle(forReadingFrom: tempURL) {
                        let head = try? handle.read(upToCount: 80)
                        try? handle.close()
                        if let head {
                            let preview = String(data: head, encoding: .utf8)?
                                .replacingOccurrences(of: "\n", with: "\\n")
                                ?? head.map { String(format: "%02x", $0) }.joined()
                            plog("🌊 StreamingDecoder: head80=\(preview.prefix(120))")
                        }
                    }

                    if Task.isCancelled { throw CancellationError() }

                    // Step 2: Decode through the central router. It selects
                    // FFmpeg for broad fallback/DTS-CD and SFBAudioEngine otherwise.
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

                    let decoder = FileFormatRouter.decoder(for: typedTempURL)
                    guard decoder.canDecode(url: typedTempURL) else {
                        throw AudioDecoderError.unsupportedFormat(ext)
                    }
                    if let info = try? await decoder.fileInfo(for: typedTempURL), info.duration > 0 {
                        onResolveSourceLength?(info.duration)
                    }
                    plog("🌊 DownloadDecoder: routed .\(ext) via \(String(describing: type(of: decoder)))")
                    var yieldedBuffers = 0
                    do {
                        for try await buffer in decoder.decode(from: typedTempURL, outputFormat: outputFormat) {
                            try Task.checkCancellation()
                            yieldedBuffers += 1
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                buffer,
                                to: continuation
                            )
                        }
                    } catch {
                        // A native decoder may recognize a container but reject
                        // a particular profile (for example DSD128 while SFB's
                        // DSD-to-PCM converter supports DSD64). Only retry when
                        // nothing was emitted, otherwise restarting at frame 0
                        // would duplicate already-played audio.
                        let fallback = FFmpegAudioDecoder()
                        guard yieldedBuffers == 0,
                              !(decoder is FFmpegAudioDecoder),
                              fallback.canDecode(url: typedTempURL) else { throw error }
                        plog("↳ DownloadDecoder native open failed; retrying with FFmpeg")
                        if let info = try? await fallback.fileInfo(for: typedTempURL), info.duration > 0 {
                            onResolveSourceLength?(info.duration)
                        }
                        for try await buffer in fallback.decode(from: typedTempURL, outputFormat: outputFormat) {
                            try Task.checkCancellation()
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                buffer,
                                to: continuation
                            )
                        }
                    }

                    // Step 3: Cache the downloaded file
                    if let cacheURL = cacheFileURL {
                        try? FileManager.default.createDirectory(
                            at: cacheURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? FileManager.default.removeItem(at: cacheURL)
                        try? FileManager.default.moveItem(at: typedTempURL, to: cacheURL)
                        plog("🌊 DownloadDecoder: cached → \(cacheURL.lastPathComponent)")
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
                        plog("⚠️ DownloadDecoder failed: \(error.localizedDescription)")
                        await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
