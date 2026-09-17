@preconcurrency import AVFoundation
import Foundation
import PrimuseKit

final class StreamingDownloadSessionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationHandler: (@Sendable () -> Void)?
    private var cancellationRequested = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = cancellationRequested || finished
        if !finished {
            self.task = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        let cancellationHandler = cancellationHandler
        lock.unlock()
        cancellationHandler?()
        task?.cancel()
    }

    func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldCancel = cancellationRequested || finished
        if !finished {
            cancellationHandler = handler
        }
        lock.unlock()
        if shouldCancel {
            handler()
        }
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        task = nil
        cancellationHandler = nil
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

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

    // MARK: - 整份物化(播放与预取共用)

    /// 把一条长度未知、不支持 Range 的远程流整份下载下来，校验它确实是音频，
    /// 再原子安装到 `destination`。服务端转码流的播放路径与预取路径共用这一份
    /// 实现 —— 传输配置、信任策略、字节上限、streamEpoch 语义和坏文件判据
    /// 都只有一处。
    ///
    /// `destination` 已存在时直接返回，不重复下载。
    ///
    /// **为什么必须校验**：转码产物没有原文件缓存那套按 `fileSize` 的完整性
    /// 兜底(它是「存在即完整」)，而 Subsonic 系服务端出错时经常回
    /// HTTP 200 + JSON/XML 错误体。把那种 body 装进去就等于永久缓存了一个
    /// 放不出声的文件。
    static func materializeCompleteFile(
        from url: URL,
        to destination: URL,
        maximumDownloadBytes: Int?,
        sourceID: String?,
        streamEpoch: UInt64?,
        control: StreamingDownloadSessionControl? = nil
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try Task.checkCancellation()
        try ensureCurrentStreamEpoch(sourceID: sourceID, streamEpoch: streamEpoch)

        let tempPath = NSTemporaryDirectory() + "primuse_tc_\(UUID().uuidString)"
        let tempURL = URL(fileURLWithPath: tempPath)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(),
            delegateQueue: nil
        )
        control?.installCancellationHandler {
            session.invalidateAndCancel()
        }
        defer { session.finishTasksAndInvalidate() }

        do {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let startTime = CFAbsoluteTimeGetCurrent()
            let (downloadedURL, response) = try await TrustedHTTPTransport.download(
                for: request,
                session: session,
                maximumRangedBodyBytes: maximumDownloadBytes,
                wholeResponsePrefixLimit: nil
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: downloadedURL)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw AudioDecoderError.decodingFailed("HTTP \(code)")
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tempURL)

            let byteCount = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.size] as? Int64) ?? 0
            var leadingBytes: [UInt8] = []
            if let handle = try? FileHandle(forReadingFrom: tempURL) {
                let head = try? handle.read(
                    upToCount: AdaptiveStreamQualityPolicy.payloadSniffPrefixLength
                )
                try? handle.close()
                leadingBytes = Array(head ?? Data())
            }
            let verdict = AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                byteCount: byteCount,
                leadingBytes: leadingBytes
            )
            guard verdict == .accepted else {
                try? FileManager.default.removeItem(at: tempURL)
                plog("⚠️ Transcode: rejected payload for \(destination.lastPathComponent) — \(verdict)")
                throw AudioDecoderError.decodingFailed("transcoded payload rejected: \(verdict)")
            }

            try Task.checkCancellation()
            try ensureCurrentStreamEpoch(sourceID: sourceID, streamEpoch: streamEpoch)
            try installCacheFile(
                from: tempURL,
                to: destination,
                sourceID: sourceID,
                streamEpoch: streamEpoch
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            plog("🎚 Transcode: materialized \(byteCount / 1024)KB in \(String(format: "%.1f", elapsed))s → \(destination.lastPathComponent)")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Download a remote URL completely, then decode it.
    /// - Parameters:
    ///   - url: Remote HTTP/HTTPS URL
    ///   - outputFormat: Target PCM format for the audio engine
    ///   - cacheFileURL: If provided, the downloaded file is moved here after decoding starts
    ///   - completedFileProvider: 非 nil 时由它给出一份**已经完整落盘**的文件,
    ///     Step 1 的下载与随后的 typed 临时路径 / installCacheFile 全部跳过 ——
    ///     文件已经在它该在的位置上。传 provider 而不是现成的 URL, 是为了让
    ///     「预取还在途时等它完成」这段等待留在本 Task 内: 既定的取消语义与
    ///     调用方的首块超时因此照常覆盖它。默认 nil 时本函数行为逐字节不变。
    ///   - removesDestinationOnDecodeFailure: 解码在**零输出**下失败时删掉
    ///     `completedFileProvider` 给出的那份文件。只给转码产物用 —— 它是
    ///     「存在即完整」, 留一个解不开的文件会被后续播放反复命中。原文件
    ///     缓存的既有保留语义不受影响。
    /// - Returns: AsyncThrowingStream of PCM buffers ready for AVAudioPlayerNode
    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        cacheFileURL: URL? = nil,
        fileExtension: String? = nil,
        maximumDownloadBytes: Int? = nil,
        sourceID: String? = nil,
        streamEpoch: UInt64? = nil,
        sessionControl: StreamingDownloadSessionControl? = nil,
        completedFileProvider: (@Sendable () async throws -> URL)? = nil,
        removesDestinationOnDecodeFailure: Bool = false,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) -> AudioBufferStream {
        let control = sessionControl ?? StreamingDownloadSessionControl()
        return AudioBufferStreamFactory.make { continuation in
            let task = Task {
                defer { control.finish() }
                let tempPath = NSTemporaryDirectory() + "primuse_dl_\(UUID().uuidString)"
                let tempURL = URL(fileURLWithPath: tempPath)

                do {
                    // 预取路径已经把这份完整文件准备好(或正在准备)时, 跳过
                    // Step 1 的整份下载。等待留在这个 Task 内, 所以取消与
                    // 调用方的首块超时照常覆盖它。
                    if let completedFileProvider {
                        let ready = try await completedFileProvider()
                        try Task.checkCancellation()
                        try Self.ensureCurrentStreamEpoch(
                            sourceID: sourceID,
                            streamEpoch: streamEpoch
                        )
                        try await Self.decodeCompleteFile(
                            at: ready,
                            outputFormat: outputFormat,
                            fileExtension: fileExtension,
                            removesFileOnZeroOutputFailure: removesDestinationOnDecodeFailure,
                            onResolveSourceLength: onResolveSourceLength,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }

                    // Step 1: Download the complete file
                    try Self.ensureCurrentStreamEpoch(
                        sourceID: sourceID,
                        streamEpoch: streamEpoch
                    )
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 600
                    let session = URLSession(
                        configuration: config,
                        delegate: SmartSSLDelegate(),
                        delegateQueue: nil
                    )
                    control.installCancellationHandler {
                        session.invalidateAndCancel()
                    }
                    defer { session.finishTasksAndInvalidate() }

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
                    let (downloadedURL, response) = try await TrustedHTTPTransport.download(
                        for: request,
                        session: session,
                        maximumRangedBodyBytes: maximumDownloadBytes,
                        wholeResponsePrefixLimit: nil
                    )

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

                    try Task.checkCancellation()
                    try Self.ensureCurrentStreamEpoch(
                        sourceID: sourceID,
                        streamEpoch: streamEpoch
                    )

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

                    let decoder = await FileFormatRouter.decoder(for: typedTempURL)
                    guard decoder is FFmpegAudioDecoder || decoder.canDecode(url: typedTempURL) else {
                        throw AudioDecoderError.unsupportedFormat(ext)
                    }

                    // The network download is already complete here. Persist it
                    // before paced PCM decoding starts so interruption recovery
                    // can reopen this exact file and seek with FFmpeg. Waiting
                    // until the decoder reaches EOF used to leave `cachedURL`
                    // unavailable for almost the entire track because bounded
                    // PCM backpressure intentionally runs near playback speed.
                    let decodingURL: URL
                    if let cacheURL = cacheFileURL {
                        do {
                            try Task.checkCancellation()
                            try Self.installCacheFile(
                                from: typedTempURL,
                                to: cacheURL,
                                sourceID: sourceID,
                                streamEpoch: streamEpoch
                            )
                            decodingURL = cacheURL
                            plog("🌊 DownloadDecoder: materialized cache before decode → \(cacheURL.lastPathComponent)")
                        } catch {
                            // Cache persistence is optional. Keep playback alive
                            // from the complete temp file and retry the move after
                            // decoding, matching the previous best-effort behavior.
                            decodingURL = typedTempURL
                            plog("⚠️ DownloadDecoder early cache move failed; using temp file: \(error.localizedDescription)")
                        }
                    } else {
                        decodingURL = typedTempURL
                    }

                    if let info = try? await decoder.fileInfo(for: decodingURL), info.duration > 0 {
                        onResolveSourceLength?(info.duration)
                    }
                    plog("🌊 DownloadDecoder: routed .\(ext) via \(String(describing: type(of: decoder)))")
                    var yieldedBuffers = 0
                    do {
                        for try await buffer in decoder.decode(from: decodingURL, outputFormat: outputFormat) {
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
                        let fallbackCanDecode: Bool
                        do {
                            fallbackCanDecode = try await fallback.canDecodeAsync(url: decodingURL)
                        } catch {
                            // The actual decode path is independently bounded
                            // and will preserve the original typed error.
                            fallbackCanDecode = true
                        }
                        guard yieldedBuffers == 0,
                              !(decoder is FFmpegAudioDecoder),
                              fallbackCanDecode else { throw error }
                        plog("↳ DownloadDecoder native open failed; retrying with FFmpeg")
                        if let info = try? await fallback.fileInfo(for: decodingURL), info.duration > 0 {
                            onResolveSourceLength?(info.duration)
                        }
                        for try await buffer in fallback.decode(from: decodingURL, outputFormat: outputFormat) {
                            try Task.checkCancellation()
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                buffer,
                                to: continuation
                            )
                        }
                    }

                    // Step 3: Clean up or retry a cache move that failed before
                    // decoding. A file already materialized at `cacheFileURL` is
                    // intentionally retained even if playback was interrupted.
                    if let cacheURL = cacheFileURL {
                        if decodingURL.standardizedFileURL != cacheURL.standardizedFileURL {
                            try Task.checkCancellation()
                            try Self.installCacheFile(
                                from: decodingURL,
                                to: cacheURL,
                                sourceID: sourceID,
                                streamEpoch: streamEpoch
                            )
                            if FileManager.default.fileExists(atPath: cacheURL.path) {
                                plog("🌊 DownloadDecoder: cached after decode → \(cacheURL.lastPathComponent)")
                            }
                        }
                    } else {
                        try? FileManager.default.removeItem(at: decodingURL)
                    }

                    continuation.finish()
                } catch {
                    // Clean up temp files
                    try? FileManager.default.removeItem(at: tempURL)
                    let cleanupExt = (fileExtension ?? url.pathExtension).lowercased()
                    if !cleanupExt.isEmpty {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempPath + ".\(cleanupExt)"))
                    }
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        plog("⚠️ DownloadDecoder failed: \(error.localizedDescription)")
                        await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                        continuation.finish(throwing: error)
                    }
                }
            }
            control.install(task)
            continuation.onTermination = { _ in
                control.cancel()
            }
        }
    }

    /// 解码一份已经完整落盘的文件, 直接把 PCM 推给调用方。
    ///
    /// 与 `decode` 内既有的解码段同构(同样的路由、同样的「零输出才回退
    /// FFmpeg」规则), 但不搬文件也不装缓存 —— 它已经在目标路径上。
    private static func decodeCompleteFile(
        at fileURL: URL,
        outputFormat: AVAudioFormat,
        fileExtension: String?,
        removesFileOnZeroOutputFailure: Bool,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?,
        continuation: AudioBufferStream.Continuation
    ) async throws {
        let ext = (fileExtension ?? fileURL.pathExtension).lowercased()
        var yieldedBuffers = 0
        do {
            let decoder = await FileFormatRouter.decoder(for: fileURL)
            guard decoder is FFmpegAudioDecoder || decoder.canDecode(url: fileURL) else {
                throw AudioDecoderError.unsupportedFormat(ext)
            }
            if let info = try? await decoder.fileInfo(for: fileURL), info.duration > 0 {
                onResolveSourceLength?(info.duration)
            }
            plog("🎚 Transcode: decoding prepared .\(ext) via \(String(describing: type(of: decoder)))")
            do {
                for try await buffer in decoder.decode(from: fileURL, outputFormat: outputFormat) {
                    try Task.checkCancellation()
                    yieldedBuffers += 1
                    try await AudioBufferStreamFactory.yieldWithBackpressure(buffer, to: continuation)
                }
            } catch {
                let fallback = FFmpegAudioDecoder()
                let fallbackCanDecode: Bool
                do {
                    fallbackCanDecode = try await fallback.canDecodeAsync(url: fileURL)
                } catch {
                    fallbackCanDecode = true
                }
                guard yieldedBuffers == 0,
                      !(decoder is FFmpegAudioDecoder),
                      fallbackCanDecode else { throw error }
                plog("↳ Transcode: native open failed; retrying with FFmpeg")
                if let info = try? await fallback.fileInfo(for: fileURL), info.duration > 0 {
                    onResolveSourceLength?(info.duration)
                }
                for try await buffer in fallback.decode(from: fileURL, outputFormat: outputFormat) {
                    try Task.checkCancellation()
                    yieldedBuffers += 1
                    try await AudioBufferStreamFactory.yieldWithBackpressure(buffer, to: continuation)
                }
            }
        } catch {
            // 一个字节都没解出来就失败 —— 这份文件是坏的(或格式对不上)。
            // 转码产物是「存在即完整」, 留着会被后续每次播放反复命中,
            // 所以就地删掉, 下次重新取。取消不算失败。
            if removesFileOnZeroOutputFailure,
               yieldedBuffers == 0,
               !(error is CancellationError),
               !Task.isCancelled {
                try? FileManager.default.removeItem(at: fileURL)
                plog("🗑 Transcode: removed undecodable file \(fileURL.lastPathComponent)")
            }
            throw error
        }
    }

    private static func ensureCurrentStreamEpoch(
        sourceID: String?,
        streamEpoch: UInt64?
    ) throws {
        guard let sourceID, let streamEpoch else { return }
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: sourceID,
            ticket: streamEpoch
        ) else { throw CancellationError() }
    }

    private static func installCacheFile(
        from source: URL,
        to target: URL,
        sourceID: String?,
        streamEpoch: UInt64?
    ) throws {
        if let sourceID, let streamEpoch {
            guard try CloudPlaybackSource.withCurrentStreamEpoch(
                sourceID: sourceID,
                epoch: streamEpoch,
                {
                    try OfflineCacheAtomicReplacement.install(
                        source: source,
                        target: target,
                        move: true
                    )
                    return ()
                }
            ) != nil else { throw CancellationError() }
            return
        }
        try OfflineCacheAtomicReplacement.install(
            source: source,
            target: target,
            move: true
        )
    }
}
