@preconcurrency import AVFoundation
import AudioToolbox
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

    // MARK: - 整份下载

    /// Downloads the whole response, noting each arriving chunk as a transfer
    /// from `sourceID`. The player waits for the first buffer only until the
    /// source stops sending, so a server that transcodes slower than a minute
    /// per file still starts instead of being skipped as a timeout.
    private static func downloadReportingTransfer(
        from url: URL,
        session: URLSession,
        maximumDownloadBytes: Int?,
        sourceID: String?
    ) async throws -> (URL, URLResponse) {
        // OneDrive 个人版 CDN(microsoftpersonalcontent.com)对非浏览器
        // User-Agent 的整文件下载会限速到 ~1-2MB/s,大文件因此拖到几十秒
        // 才下完(首缓冲超时)。带上浏览器 UA 后下载速度对齐网页端。
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if TrustedHTTPTransport.requiresPlainSocket(for: url) {
            // The plain socket client treats the request timeout as the limit
            // for the whole transfer; match the session's resource limit.
            // A stalled transfer is still cut short by the first-buffer wait.
            request.timeoutInterval = 600
        }
        let observer: (@Sendable (Int) -> Void)? = sourceID.map { id in
            { @Sendable (_: Int) in CloudPlaybackSource.noteTransferSucceeded(sourceID: id) }
        }
        return try await TrustedHTTPTransport.DownloadProgress.$observer.withValue(observer) {
            try await TrustedHTTPTransport.mediaDownload(
                for: request,
                session: session,
                maximumRangedBodyBytes: maximumDownloadBytes,
                wholeResponsePrefixLimit: nil
            )
        }
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
        let session = TrustedHTTPTransport.makeMediaSession(configuration: config)
        control?.installCancellationHandler {
            session.invalidateAndCancel()
        }
        defer { session.finishTasksAndInvalidate() }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            let (downloadedURL, response) = try await downloadReportingTransfer(
                from: url,
                session: session,
                maximumDownloadBytes: maximumDownloadBytes,
                sourceID: sourceID
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            let http = try Self.validatedDownloadResponse(response)
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
    ///   - allowsProgressiveDecoding: MP3 边下边解, 不等整份下完才出第一块
    ///     (`decodesProgressively`)。服务端现转的流没有长度、不认 Range, 整份
    ///     下完常常要几十秒。
    ///   - expectedDuration: 歌曲时长, 边下边解时用来判断下载跟不跟得上播放。
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
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil,
        allowsProgressiveDecoding: Bool = false,
        expectedDuration: TimeInterval? = nil
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

                    if allowsProgressiveDecoding,
                       Self.decodesProgressively(fileExtension: fileExtension ?? url.pathExtension, url: url) {
                        do {
                            try await Self.decodeProgressively(
                                from: url,
                                outputFormat: outputFormat,
                                cacheFileURL: cacheFileURL,
                                maximumDownloadBytes: maximumDownloadBytes,
                                sourceID: sourceID,
                                streamEpoch: streamEpoch,
                                expectedDuration: expectedDuration,
                                control: control,
                                onResolveSourceLength: onResolveSourceLength,
                                continuation: continuation
                            )
                            continuation.finish()
                            return
                        } catch ProgressiveDownloadFallback.completeDownloadRequired {
                            plog("↳ StreamingDecoder: progressive start unavailable; downloading the whole file")
                        }
                    }

                    // Step 1: Download the complete file
                    try Self.ensureCurrentStreamEpoch(
                        sourceID: sourceID,
                        streamEpoch: streamEpoch
                    )
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 600
                    let session = TrustedHTTPTransport.makeMediaSession(configuration: config)
                    control.installCancellationHandler {
                        session.invalidateAndCancel()
                    }
                    defer { session.finishTasksAndInvalidate() }

                    plog("🌊 StreamingDecoder: downloading from \(url.host ?? "?")")
                    let startTime = CFAbsoluteTimeGetCurrent()

                    let (downloadedURL, response) = try await Self.downloadReportingTransfer(
                        from: url,
                        session: session,
                        maximumDownloadBytes: maximumDownloadBytes,
                        sourceID: sourceID
                    )
                    defer { try? FileManager.default.removeItem(at: downloadedURL) }
                    let http = try Self.validatedDownloadResponse(response)

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

    private static func validatedDownloadResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteMediaHTTPError(
                service: "HTTP media", statusCode: http.statusCode,
                retryAfter: RemoteMediaHTTPError.retryDelay(from: http)
            )
        }
        return http
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

    // MARK: - 边下边解(长度未知的 MP3)

    private static let progressiveChunkBytes = 64 * 1_024
    private static let progressiveFlushBytes = 4 * 1_024

    /// 只有 MP3 边下边解: 帧自带同步头, 拿到一段就能接着解, 用不着先知道总长度。
    /// 公网明文 HTTP 走自己的套接字客户端, 没有逐段交付, 仍然整份下载。
    static func decodesProgressively(fileExtension: String, url: URL) -> Bool {
        fileExtension.lowercased() == "mp3"
            && (url.scheme == "http" || url.scheme == "https")
            && !TrustedHTTPTransport.requiresPlainSocket(for: url)
    }

    /// 一边把响应写进临时文件, 一边按到达顺序从文件里解码。下载比播放快时攒够
    /// 两秒就出声, 慢时多攒一些, 攒到按目前的速度能一直放到结尾
    /// (`ProgressiveDownloadStartPolicy`)。整份到齐、确认是解得开的音频才装进
    /// 缓存 —— 缓存「存在即完整」, 之后拖动与重播都用它。
    ///
    /// 抛 `ProgressiveDownloadFallback.completeDownloadRequired` 时还什么都没交出去,
    /// 调用方改走整份下载。
    private static func decodeProgressively(
        from url: URL,
        outputFormat: AVAudioFormat,
        cacheFileURL: URL?,
        maximumDownloadBytes: Int?,
        sourceID: String?,
        streamEpoch: UInt64?,
        expectedDuration: TimeInterval?,
        control: StreamingDownloadSessionControl,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?,
        continuation: AudioBufferStream.Continuation
    ) async throws {
        try ensureCurrentStreamEpoch(sourceID: sourceID, streamEpoch: streamEpoch)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // 边下边放: 总时长按歌曲长度放宽; 停住不动的传输仍由 30 秒的空闲上限截断。
        config.timeoutIntervalForResource = min(6 * 60 * 60, max(600, (expectedDuration ?? 0) * 4))
        let session = TrustedHTTPTransport.makeMediaSession(configuration: config)
        control.installCancellationHandler {
            session.invalidateAndCancel()
        }
        defer { session.finishTasksAndInvalidate() }

        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory() + "primuse_pdl_\(UUID().uuidString).mp3")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        // 装进缓存时是挪过去的, 这里删的就只剩没装的那份。
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transfer = ProgressiveDownloadState()
        let (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        plog("🌊 StreamingDecoder: progressive download from \(url.host ?? "?")")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.runProgressiveDownload(
                    url: url,
                    session: session,
                    fileURL: fileURL,
                    maximumBytes: maximumDownloadBytes,
                    sourceID: sourceID,
                    transfer: transfer,
                    signal: signal
                )
            }
            try await Self.decodeGrowingFile(
                fileURL: fileURL,
                transfer: transfer,
                signals: signals,
                outputFormat: outputFormat,
                cacheFileURL: cacheFileURL,
                sourceID: sourceID,
                streamEpoch: streamEpoch,
                expectedDuration: expectedDuration,
                onResolveSourceLength: onResolveSourceLength,
                continuation: continuation
            )
        }
    }

    /// 下载端: 把响应按到达顺序追加进文件, 不受解码节奏牵制。失败记进 `transfer`,
    /// 由解码端决定是放完已到的部分再报错, 还是改走整份下载。
    private static func runProgressiveDownload(
        url: URL,
        session: URLSession,
        fileURL: URL,
        maximumBytes: Int?,
        sourceID: String?,
        transfer: ProgressiveDownloadState,
        signal: AsyncStream<Void>.Continuation
    ) async {
        // 算作播放在用的网络读取: 队列预取先等它的空档, 不和服务端正在转的这首抢。
        CloudPlaybackSource.beginProgressivePlaybackDownload()
        defer {
            CloudPlaybackSource.endProgressivePlaybackDownload()
            signal.yield()
            signal.finish()
        }
        do {
            let writer = try FileHandle(forWritingTo: fileURL)
            defer { try? writer.close() }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let startedAt = ProcessInfo.processInfo.systemUptime
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // 媒体会话不自动跟随跳转; 整份下载那条路径按规则跟过去。
            if (300...399).contains(http.statusCode) {
                throw ProgressiveDownloadFallback.completeDownloadRequired
            }
            _ = try validatedDownloadResponse(http)
            if let maximumBytes, http.expectedContentLength > Int64(maximumBytes) {
                throw URLError(.dataLengthExceedsMaximum)
            }
            transfer.responseArrived(contentType: http.value(forHTTPHeaderField: "Content-Type"))
            if let sourceID { CloudPlaybackSource.noteTransferSucceeded(sourceID: sourceID) }
            plog(String(
                format: "🌊 StreamingDecoder: progressive response after %.2fs status=%ld type=%@ length=%@ ranges=%@ encoding=%@",
                ProcessInfo.processInfo.systemUptime - startedAt,
                http.statusCode,
                http.value(forHTTPHeaderField: "Content-Type") ?? "-",
                http.value(forHTTPHeaderField: "Content-Length") ?? "-",
                http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-",
                http.value(forHTTPHeaderField: "Transfer-Encoding") ?? "-"
            ))

            // 每 4 KB 落一次盘: 传输停住时压在内存里没让解码端看到的不超过 4 KB
            // (128 kbps 下约 0.25 秒)。
            var pending: [UInt8] = []
            pending.reserveCapacity(progressiveFlushBytes)
            var written = 0
            func flush() throws {
                guard !pending.isEmpty else { return }
                written += pending.count
                if let maximumBytes, written > maximumBytes {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                try writer.write(contentsOf: pending)
                transfer.appended(pending.count)
                if let sourceID { CloudPlaybackSource.noteTransferSucceeded(sourceID: sourceID) }
                signal.yield()
                pending.removeAll(keepingCapacity: true)
            }
            for try await byte in bytes {
                pending.append(byte)
                if pending.count >= progressiveFlushBytes { try flush() }
            }
            try flush()
            try Task.checkCancellation()
            plog(String(
                format: "🌊 StreamingDecoder: progressive download finished %ldKB in %.1fs",
                written / 1_024,
                ProcessInfo.processInfo.systemUptime - startedAt
            ))
            transfer.finish(failure: nil)
        } catch {
            transfer.finish(failure: error)
        }
    }

    /// 解码端: 按到达顺序从临时文件读, 读到尽头就等下一段。认不出 MP3 帧时
    /// 等整份到齐, 交给通用解码路由, 与整份下载的结果一样。
    private static func decodeGrowingFile(
        fileURL: URL,
        transfer: ProgressiveDownloadState,
        signals: AsyncStream<Void>,
        outputFormat: AVAudioFormat,
        cacheFileURL: URL?,
        sourceID: String?,
        streamEpoch: UInt64?,
        expectedDuration: TimeInterval?,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?,
        continuation: AudioBufferStream.Continuation
    ) async throws {
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        let frames = try ProgressiveMP3FrameDecoder(outputFormat: outputFormat)
        var arrivals = signals.makeAsyncIterator()
        var readOffset: Int64 = 0
        var held: [AVAudioPCMBuffer] = []
        var started = false
        var parserGaveUp = false
        var completionHandled = false
        let decodeStartedAt = ProcessInfo.processInfo.systemUptime

        func emit(_ buffers: [AVAudioPCMBuffer]) async throws {
            for buffer in buffers {
                try await AudioBufferStreamFactory.yieldWithBackpressure(buffer, to: continuation)
            }
        }

        while true {
            try Task.checkCancellation()
            let state = transfer.snapshot()
            // 断在半路: 已经开放的先把到了的部分放完再报错; 还没开放就直接报错。
            if let failure = state.failure, !started || readOffset >= state.bytes {
                throw failure
            }
            if !completionHandled, state.finished, frames.hasProducedAudio {
                completionHandled = true
                let completeURL = installCompletedDownload(
                    fileURL,
                    state: state,
                    cacheFileURL: cacheFileURL,
                    sourceID: sourceID,
                    streamEpoch: streamEpoch
                )
                if let onResolveSourceLength {
                    let decoder = await FileFormatRouter.decoder(for: completeURL)
                    if let info = try? await decoder.fileInfo(for: completeURL), info.duration > 0 {
                        onResolveSourceLength(info.duration)
                    }
                }
            }
            if !started, !held.isEmpty {
                let elapsed = state.responseUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                guard ProgressiveDownloadStartPolicy.canStart(
                    bufferedAudioBytes: state.bytes - frames.audioDataOffset,
                    downloadedBytes: state.bytes,
                    elapsedSeconds: elapsed,
                    downloadFinished: state.finished,
                    audioBytesPerSecond: frames.audioBytesPerSecond,
                    expectedDuration: expectedDuration
                ) else {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                started = true
                plog(String(
                    format: "🌊 StreamingDecoder: progressive start after %.1fs with %lldKB on disk",
                    ProcessInfo.processInfo.systemUptime - decodeStartedAt,
                    state.bytes / 1_024
                ))
                let ready = held
                held.removeAll()
                try await emit(ready)
            }
            if readOffset < state.bytes {
                guard !parserGaveUp else {
                    readOffset = state.bytes
                    continue
                }
                try reader.seek(toOffset: UInt64(readOffset))
                let chunk = try reader.read(
                    upToCount: Int(min(Int64(progressiveChunkBytes), state.bytes - readOffset))
                ) ?? Data()
                guard !chunk.isEmpty else {
                    throw AudioDecoderError.decodingFailed("progressive download file is shorter than reported")
                }
                readOffset += Int64(chunk.count)
                let buffers: [AVAudioPCMBuffer]
                do {
                    buffers = try frames.decode(chunk)
                } catch {
                    guard !frames.hasProducedAudio else { throw error }
                    parserGaveUp = true
                    plog("↳ StreamingDecoder: no MP3 frames in progressive download (\(error.localizedDescription)); waiting for the whole file")
                    continue
                }
                if started {
                    try await emit(buffers)
                } else {
                    held.append(contentsOf: buffers)
                }
                continue
            }
            if state.finished, readOffset >= state.bytes { break }
            _ = await arrivals.next()
        }

        guard !parserGaveUp, frames.hasProducedAudio else {
            // 不是解得开的 MP3: 整份已经到齐, 按整份下载那样交给通用解码路由。
            let state = transfer.snapshot()
            let completeURL = installCompletedDownload(
                fileURL,
                state: state,
                cacheFileURL: cacheFileURL,
                sourceID: sourceID,
                streamEpoch: streamEpoch
            )
            try await decodeCompleteFile(
                at: completeURL,
                outputFormat: outputFormat,
                fileExtension: "mp3",
                removesFileOnZeroOutputFailure: false,
                onResolveSourceLength: onResolveSourceLength,
                continuation: continuation
            )
            return
        }
        held.append(contentsOf: try frames.finish())
        if !started {
            plog(String(
                format: "🌊 StreamingDecoder: progressive start after %.1fs (download complete)",
                ProcessInfo.processInfo.systemUptime - decodeStartedAt
            ))
        }
        try await emit(held)
    }

    /// 整份到齐的下载装进缓存, 返回它现在的位置。没有缓存位置、看起来不是音频
    /// (服务端回 200 加 JSON/HTML 错误体)或装不进去时留在临时文件里。
    private static func installCompletedDownload(
        _ fileURL: URL,
        state: ProgressiveDownloadState.Snapshot,
        cacheFileURL: URL?,
        sourceID: String?,
        streamEpoch: UInt64?
    ) -> URL {
        guard let cacheFileURL else { return fileURL }
        var leadingBytes: [UInt8] = []
        if let handle = try? FileHandle(forReadingFrom: fileURL) {
            leadingBytes = Array(
                (try? handle.read(upToCount: AdaptiveStreamQualityPolicy.payloadSniffPrefixLength)) ?? Data()
            )
            try? handle.close()
        }
        let verdict = AdaptiveStreamQualityPolicy.verifyTranscodedPayload(
            contentType: state.contentType,
            byteCount: state.bytes,
            leadingBytes: leadingBytes
        )
        guard verdict == .accepted else {
            plog("⚠️ StreamingDecoder: progressive download not cached — \(verdict)")
            return fileURL
        }
        do {
            try installCacheFile(from: fileURL, to: cacheFileURL, sourceID: sourceID, streamEpoch: streamEpoch)
            plog("🌊 StreamingDecoder: progressive download cached → \(cacheFileURL.lastPathComponent)")
            return cacheFileURL
        } catch {
            plog("⚠️ StreamingDecoder: progressive cache install failed; decoding from temp file: \(error.localizedDescription)")
            return fileURL
        }
    }
}

/// 边下边解时不能接着走、要改成整份下载的情况(目前只有服务端回跳转)。
private enum ProgressiveDownloadFallback: Error {
    case completeDownloadRequired
}

/// 边下边解时下载端与解码端共享的进度。
private final class ProgressiveDownloadState: @unchecked Sendable {
    struct Snapshot {
        let bytes: Int64
        let finished: Bool
        let failure: (any Error)?
        let responseUptime: TimeInterval?
        let contentType: String?
    }

    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var finished = false
    private var failure: (any Error)?
    private var responseUptime: TimeInterval?
    private var contentType: String?

    func responseArrived(contentType: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            responseUptime = now
            self.contentType = contentType
        }
    }

    func appended(_ count: Int) {
        lock.withLock { bytes += Int64(count) }
    }

    func finish(failure: (any Error)?) {
        lock.withLock {
            finished = failure == nil
            self.failure = failure
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                bytes: bytes,
                finished: finished,
                failure: failure,
                responseUptime: responseUptime,
                contentType: contentType
            )
        }
    }
}

/// 喂给 AVAudioConverter 的一份输入: 交出一次, 之后回 `.noDataNow`(流的结尾回 `.endOfStream`)。
private final class ProgressiveConverterFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioBuffer?
    private let endOfStream: Bool

    init(_ buffer: AVAudioBuffer?, endOfStream: Bool) {
        self.buffer = buffer
        self.endOfStream = endOfStream
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if let buffer {
                self.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
    }
}

/// 按到达顺序喂进来的 MP3 字节 → 播放图要的 PCM。AudioFileStream 把字节切成帧
/// (跳过 ID3 标签、遇到杂字节重新找同步头), AVAudioConverter 解码, 采样率或
/// 声道数不同时再换一次。只在一个解码任务里顺序使用。
private final class ProgressiveMP3FrameDecoder {
    private static let outputFrameCapacity: AVAudioFrameCount = 8_192

    private let outputFormat: AVAudioFormat
    private var streamID: AudioFileStreamID?
    private var sourceDescription = AudioStreamBasicDescription()
    private var compressedFormat: AVAudioFormat?
    private var decodedFormat: AVAudioFormat?
    private var codec: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var configurationError: (any Error)?
    private var pendingBytes = Data()
    private var pendingDescriptions: [AudioStreamPacketDescription] = []
    /// 第一帧之前的字节数(ID3 标签等)。
    private(set) var audioDataOffset: Int64 = 0
    private var decodedPacketBytes: Int64 = 0
    private var decodedPacketCount: Int64 = 0
    private var decodedSourceFrames: Int64 = 0

    var hasProducedAudio: Bool { decodedSourceFrames > 0 }

    /// 播放每秒用掉多少字节, 按已经解出的帧算。
    var audioBytesPerSecond: Double? {
        let seconds = Double(decodedPacketCount) * Double(framesPerPacket) / sourceDescription.mSampleRate
        guard decodedPacketCount > 0, seconds.isFinite, seconds > 0 else { return nil }
        return Double(decodedPacketBytes) / seconds
    }

    private var framesPerPacket: UInt32 {
        sourceDescription.mFramesPerPacket > 0 ? sourceDescription.mFramesPerPacket : 1_152
    }

    init(outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        var opened: AudioFileStreamID?
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            { clientData, _, propertyID, _ in
                Unmanaged<ProgressiveMP3FrameDecoder>.fromOpaque(clientData)
                    .takeUnretainedValue()
                    .streamReported(propertyID)
            },
            { clientData, byteCount, packetCount, data, descriptions in
                let packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>? = descriptions
                Unmanaged<ProgressiveMP3FrameDecoder>.fromOpaque(clientData)
                    .takeUnretainedValue()
                    .streamDelivered(
                        byteCount: byteCount,
                        packetCount: packetCount,
                        data: data,
                        descriptions: packetDescriptions
                    )
            },
            kAudioFileMP3Type,
            &opened
        )
        guard status == noErr, let opened else {
            throw AudioDecoderError.decodingFailed("AudioFileStreamOpen failed: \(status)")
        }
        streamID = opened
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    func decode(_ chunk: Data) throws -> [AVAudioPCMBuffer] {
        guard let streamID, !chunk.isEmpty else { return [] }
        let status = chunk.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(raw.count), base, [])
        }
        if let configurationError { throw configurationError }
        guard status == noErr else {
            throw AudioDecoderError.decodingFailed("AudioFileStreamParseBytes failed: \(status)")
        }
        return try decodePendingPackets()
    }

    /// 流结束: 把解码器和重采样里压着的尾巴都倒出来。
    func finish() throws -> [AVAudioPCMBuffer] {
        guard let codec, let decodedFormat else { return [] }
        var outputs = try resampled(Self.run(codec, input: nil, endOfStream: true, outputFormat: decodedFormat))
        if let resampler {
            outputs += try Self.run(resampler, input: nil, endOfStream: true, outputFormat: outputFormat)
        }
        return outputs
    }

    fileprivate func streamReported(_ propertyID: AudioFileStreamPropertyID) {
        guard let streamID else { return }
        switch propertyID {
        case kAudioFileStreamProperty_DataOffset:
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &offset) == noErr {
                audioDataOffset = max(0, offset)
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            configureDecoder(streamID)
        default:
            break
        }
    }

    fileprivate func streamDelivered(
        byteCount: UInt32,
        packetCount: UInt32,
        data: UnsafeRawPointer,
        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard packetCount > 0 else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        if let descriptions {
            for index in 0..<Int(packetCount) {
                var description = descriptions[index]
                let start = Int(description.mStartOffset)
                let size = Int(description.mDataByteSize)
                guard size > 0, start >= 0, start <= Int(byteCount) - size else { continue }
                description.mStartOffset = Int64(pendingBytes.count)
                pendingBytes.append(bytes + start, count: size)
                pendingDescriptions.append(description)
            }
        } else {
            let packetSize = Int(sourceDescription.mBytesPerPacket)
            guard packetSize > 0 else { return }
            for index in 0..<Int(packetCount) where (index + 1) * packetSize <= Int(byteCount) {
                pendingDescriptions.append(AudioStreamPacketDescription(
                    mStartOffset: Int64(pendingBytes.count),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(packetSize)
                ))
                pendingBytes.append(bytes + index * packetSize, count: packetSize)
            }
        }
    }

    private func configureDecoder(_ streamID: AudioFileStreamID) {
        guard codec == nil, configurationError == nil else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              description.mSampleRate > 0, description.mChannelsPerFrame > 0,
              let compressed = AVAudioFormat(streamDescription: &description) else {
            configurationError = AudioDecoderError.unsupportedFormat("mp3")
            return
        }
        // 采样率与声道数和播放图一样时直接解成它要的格式, 不再多换一次。
        let matchesOutput = description.mSampleRate == outputFormat.sampleRate
            && description.mChannelsPerFrame == outputFormat.channelCount
            && outputFormat.commonFormat == .pcmFormatFloat32
            && !outputFormat.isInterleaved
        let decoded = matchesOutput ? outputFormat : AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: description.mSampleRate,
            channels: description.mChannelsPerFrame,
            interleaved: false
        )
        guard let decoded, let codec = AVAudioConverter(from: compressed, to: decoded) else {
            configurationError = AudioDecoderError.converterCreationFailed
            return
        }
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, base)
            }
            if status == noErr { codec.magicCookie = cookie }
        }
        if !matchesOutput {
            guard let converter = AVAudioConverter(from: decoded, to: outputFormat) else {
                configurationError = AudioDecoderError.converterCreationFailed
                return
            }
            converter.usePlaybackResampling()
            if AudioChannelConversionPolicy.requiresDownmix(
                sourceChannelCount: Int(decoded.channelCount),
                outputChannelCount: Int(outputFormat.channelCount)
            ) {
                converter.downmix = true
            }
            resampler = converter
        }
        sourceDescription = description
        compressedFormat = compressed
        decodedFormat = decoded
        self.codec = codec
    }

    /// 每批帧数控制在输出缓冲装得下的范围内, 解码器每次都把这一批吃完。
    private func decodePendingPackets() throws -> [AVAudioPCMBuffer] {
        guard !pendingDescriptions.isEmpty else { return [] }
        defer {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingDescriptions.removeAll(keepingCapacity: true)
        }
        guard let codec, let compressedFormat, let decodedFormat else {
            throw configurationError ?? AudioDecoderError.unsupportedFormat("mp3")
        }
        let packetsPerBatch = max(1, Int(Self.outputFrameCapacity / framesPerPacket))
        var outputs: [AVAudioPCMBuffer] = []
        var first = 0
        while first < pendingDescriptions.count {
            let last = min(first + packetsPerBatch, pendingDescriptions.count)
            let batch = Array(pendingDescriptions[first..<last])
            let byteStart = Int(batch[0].mStartOffset)
            let byteEnd = batch.reduce(byteStart) { max($0, Int($1.mStartOffset) + Int($1.mDataByteSize)) }
            let largestPacket = batch.reduce(0) { max($0, Int($1.mDataByteSize)) }
            let input = AVAudioCompressedBuffer(
                format: compressedFormat,
                packetCapacity: AVAudioPacketCount(batch.count),
                maximumPacketSize: largestPacket
            )
            pendingBytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                input.data.copyMemory(from: base + byteStart, byteCount: byteEnd - byteStart)
            }
            if let target = input.packetDescriptions {
                for (index, description) in batch.enumerated() {
                    var rebased = description
                    rebased.mStartOffset = description.mStartOffset - Int64(byteStart)
                    target[index] = rebased
                }
            }
            input.packetCount = AVAudioPacketCount(batch.count)
            input.byteLength = UInt32(byteEnd - byteStart)
            let decoded = try Self.run(codec, input: input, endOfStream: false, outputFormat: decodedFormat)
            decodedPacketCount += Int64(batch.count)
            decodedPacketBytes += Int64(batch.reduce(0) { $0 + Int($1.mDataByteSize) })
            outputs += try resampled(decoded)
            first = last
        }
        return outputs
    }

    private func resampled(_ decoded: [AVAudioPCMBuffer]) throws -> [AVAudioPCMBuffer] {
        decodedSourceFrames += decoded.reduce(Int64(0)) { $0 + Int64($1.frameLength) }
        guard let resampler else { return decoded }
        var outputs: [AVAudioPCMBuffer] = []
        for buffer in decoded {
            outputs += try Self.run(resampler, input: buffer, endOfStream: false, outputFormat: outputFormat)
        }
        return outputs
    }

    /// 把一份输入(nil 表示流的结尾)交给转换器, 收下它这次产出的全部缓冲。
    private static func run(
        _ converter: AVAudioConverter,
        input: AVAudioBuffer?,
        endOfStream: Bool,
        outputFormat: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        let feed = ProgressiveConverterFeed(input, endOfStream: endOfStream)
        let ratio = outputFormat.sampleRate / max(1, converter.inputFormat.sampleRate)
        // 输出要装得下这一份输入换出来的全部帧, 转换器每次都把输入吃完。
        let inputFrames = max(outputFrameCapacity, (input as? AVAudioPCMBuffer)?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(Double(inputFrames) * max(1, ratio)) + 4_096
        var outputs: [AVAudioPCMBuffer] = []
        for _ in 0..<256 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                feed.next(inputStatus)
            }
            if let error { throw error }
            if status == .error {
                throw AudioDecoderError.decodingFailed("MP3 stream conversion failed")
            }
            if output.frameLength > 0 { outputs.append(output) }
            guard status == .haveData, output.frameLength > 0 else { break }
        }
        return outputs
    }
}
