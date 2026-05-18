import Foundation
import PrimuseKit
import SFBAudioEngine

/// Builds an `SFBInputSource` for a cloud-source song that streams bytes
/// on demand via the connector's `fetchRange`, while persisting fetched
/// chunks to a sparse cache file. Sequel of:
/// - Decoder asks for bytes at offset N
/// - We check the cache file's covered ranges
/// - Cached → read from disk
/// - Not cached → HTTP Range fetch, write to disk, return data
/// When all ranges fill in, the cache file becomes a complete copy and
/// future plays bypass this entire path (`SourceManager.cachedURL` hit).
///
/// Synchronization model: SFBAudioEngine's audio decoder calls
/// `readBytes:` synchronously on a background thread. We bridge to the
/// connector's `async` API by spawning a Task and waiting on a
/// DispatchSemaphore — safe because the read happens on a non-main
/// non-actor thread.
enum CloudPlaybackSource {
    /// Bytes per single Range fetch when serving a missing chunk. Smaller
    /// = faster first-byte latency / wasted bytes if seeking; larger =
    /// fewer round-trips for sequential playback.
    ///
    /// 1MB 的取舍: SFB 对 mp3 (没 LAME/Xing header) 必须扫全部帧算 length,
    /// 这是个 sequential read。chunkSize 太小 (256KB) 时 round-trip 累加成
    /// 主要瓶颈 —— 10MB mp3 / 256KB = 40 chunks * 300ms = 12s 卡顿。
    /// 1MB 减少 4 倍 round-trip,加上 prefetchAhead=4 并发,实测 first-buffer
    /// 从 5.3s 降到 ~1s。代价: cloud drive 下"听 1 秒就跳"会浪费带宽,
    /// 但比 cold-start 卡顿 5s 重要得多。
    static let chunkSize: Int64 = 1024 * 1024

    /// 默认一次性后台并发预取这么多个 chunk。
    /// 4 而不是 8: 8 路并发 + 1 user fetch 给 NAS 太多压力, 实测每个 chunk
    /// fetch 从 0.5s 变 1.5s, 反而拖慢 firstBuffer。配合 user fetch 等待
    /// in-flight prefetch 复用结果, 4 路 + 复用 = 实际有效 5+ 个 chunk
    /// 同时 cover, 性能更稳。
    static let prefetchAhead: Int = 4

    /// Size of the head chunk that `SourceManager.prewarmCloudSong` fetches
    /// for the next-up song. Marker JSON 描述 partial 里哪些 ranges 已 prewarm。
    ///
    /// 1MB 对齐 chunkSize: SFB.open() 顺序 read mp3 header + 头几十帧时,
    /// 如果 prewarm head 只 256KB, SFB 读到 256KB+ 时 cache miss → fetch
    /// chunk align 拉整个 0-1MB (即使有 cache prefix skip 也仍然要拉 768KB)。
    /// 1MB head 让"prewarm 过的歌"SFB.open() 阶段 0 fetch — 实测 firstBuffer
    /// 从 3.1s 降到 < 200ms (只剩 SFB CPU 时间)。
    /// 代价: library 全量 prewarm 流量从 82MB → 330MB, 但是 background
    /// 优先级跑, user 不会感知; 可接受。
    static let prewarmHeadBytes: Int64 = 1024 * 1024

    /// Sidecar marker filename suffix written next to the `.partial` by
    /// `SourceManager.prewarmCloudSong`. Consumed (deleted) by the first
    /// playback session that adopts the seed bytes — so a later session
    /// that finds a `.partial` without the marker treats it as untrusted.
    /// 内容是 PrewarmMarker JSON, 描述哪些 byte ranges 已经 prewarm。
    static let prewarmMarkerSuffix = ".prewarmed"

    /// mp3 ID3v1 tag 在文件最后 128 字节, SFB.open() 必须读 tail。
    /// 如果只 prewarm head, SFB 读 tail 时触发 user-facing fetch 卡顿 1-2s。
    /// 同时拉 head + tail (并发, 不增加 wallclock) 让 SFB.open() 全部命中
    /// cache, 实测 first-buffer 从 3.2s 降到 < 800ms。
    static let prewarmTailBytes: Int64 = 256 * 1024

    /// `.prewarmed` marker 内容: 描述 partial 文件里哪些 byte ranges 是
    /// 可信的 prewarm 数据。让 prewarm 同时支持 head + tail (sparse file)。
    /// 旧版 (空 sentinel) marker 解析失败 → 当作未 prewarm, 自然迁移。
    struct PrewarmMarker: Codable {
        let v: Int
        let ranges: [[Int64]]  // [[start, end), ...]

        static let currentVersion = 1

        static func read(from url: URL) -> PrewarmMarker? {
            guard let data = try? Data(contentsOf: url),
                  let m = try? JSONDecoder().decode(PrewarmMarker.self, from: data),
                  m.v == currentVersion else { return nil }
            return m
        }

        func write(to url: URL) throws {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        }

        var swiftRanges: [Range<Int64>] {
            ranges.compactMap { pair in
                guard pair.count == 2, pair[0] < pair[1] else { return nil }
                return pair[0]..<pair[1]
            }
        }
    }

    /// Build an `InputSource` for `song` whose reads are backed by
    /// `connector.fetchRange` + a sparse on-disk cache at `cacheURL`.
    /// `totalLength` should be the song's known fileSize (cloud sources
    /// fill this from the listing response).
    ///
    /// Streaming writes go to `cacheURL.partial`. Only when every byte
    /// has been fetched do we atomically rename to `cacheURL` so the
    /// canonical path always represents a complete, decodable file.
    /// (`SourceManager.cachedURL` treats existence as "fully cached" —
    /// without this we'd serve corrupt zero-padded files on next play.)
    static func makeInputSource(
        song: Song,
        totalLength: Int64,
        connector: any MusicSourceConnector,
        cacheURL: URL,
        persistOnComplete: Bool = true,
        cacheRelativePath: String? = nil
    ) -> InputSource? {
        let path = song.filePath
        let connectorFetch: @Sendable (Int64, Int64) async throws -> Data = { off, len in
            try await connector.fetchRange(path: path, offset: off, length: len)
        }

        return makeInputSource(
            label: song.title,
            sourceURL: makeSourceURL(scheme: "primuse-cloud", song: song),
            totalLength: totalLength,
            cacheURL: cacheURL,
            persistOnComplete: persistOnComplete,
            cacheRelativePath: cacheRelativePath,
            connectorFetch: connectorFetch
        )
    }

    /// Build an `InputSource` for a direct HTTP(S) playback URL. This is
    /// used for media servers, UPnP, and NAS plain streaming URLs so
    /// playback can start from byte ranges instead of waiting for
    /// `URLSession.download` to finish the whole file.
    static func makeHTTPInputSource(
        song: Song,
        url: URL,
        totalLength: Int64,
        cacheURL: URL,
        persistOnComplete: Bool = true,
        cacheRelativePath: String? = nil
    ) -> InputSource? {
        guard totalLength > 0,
              url.scheme == "http" || url.scheme == "https" else { return nil }

        let fetcher = HTTPRangeFetcher(url: url, totalLength: totalLength)
        let fetch: @Sendable (Int64, Int64) async throws -> Data = { off, len in
            try await fetcher.fetch(offset: off, length: len)
        }

        return makeInputSource(
            label: song.title,
            sourceURL: makeSourceURL(scheme: "primuse-http", song: song),
            totalLength: totalLength,
            cacheURL: cacheURL,
            persistOnComplete: persistOnComplete,
            cacheRelativePath: cacheRelativePath,
            connectorFetch: fetch
        )
    }

    private static func makeInputSource(
        label: String,
        sourceURL: URL?,
        totalLength: Int64,
        cacheURL: URL,
        persistOnComplete: Bool,
        cacheRelativePath: String?,
        connectorFetch: @escaping @Sendable (Int64, Int64) async throws -> Data
    ) -> InputSource? {
        let partialURL = URL(fileURLWithPath: cacheURL.path + ".partial")
        let markerURL = URL(fileURLWithPath: partialURL.path + prewarmMarkerSuffix)

        // Only trust .partial bytes when the prewarm marker JSON is valid
        // and the partial file size is large enough to contain all listed
        // ranges. Consume the marker so a future session can't pick up
        // bytes another session may have appended past the prewarm windows.
        var initialRanges: [Range<Int64>] = []
        if let marker = PrewarmMarker.read(from: markerURL),
           FileManager.default.fileExists(atPath: partialURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let size = attrs[.size] as? Int64,
           let maxEnd = marker.swiftRanges.map(\.upperBound).max(),
           size >= maxEnd,
           maxEnd <= totalLength {
            initialRanges = marker.swiftRanges
            try? FileManager.default.removeItem(at: markerURL)
        } else {
            // No marker, invalid JSON, or shape mismatch — start clean.
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: partialURL)
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }

        plog("☁️ makeInputSource '\(label)' totalLength=\(totalLength) initialRanges=\(initialRanges.map { "[\($0.lowerBound)..\($0.upperBound))" }.joined(separator: ","))")

        let state = State(
            label: label,
            partialURL: partialURL,
            finalURL: cacheURL,
            totalLength: totalLength,
            initialRanges: initialRanges,
            persistOnComplete: persistOnComplete,
            cacheRelativePath: cacheRelativePath,
            connectorFetch: connectorFetch
        )
        registerActiveState(state, key: partialURL.path)

        let block: CloudInputFetchBlock = { offset, length, errorOut in
            return state.serve(offset: offset, length: length, errorOut: errorOut)
        }

        return CloudInputSourceObjC(
            url: sourceURL,
            totalLength: totalLength,
            fetch: block
        )
    }

    private static func makeSourceURL(scheme: String, song: Song) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = song.sourceID
        components.path = song.filePath.hasPrefix("/") ? song.filePath : "/" + song.filePath
        return components.url
    }

    // MARK: - Active session registry

    /// 当前活跃的 streaming session 列表 (key = partialURL.path)。
    /// 用 NSLock 保护, 不用 @MainActor —— 注册和访问都可能从 SFB
    /// decode thread / main thread 同时进入。
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var activeStates: [String: State] = [:]

    private static func registerActiveState(_ state: State, key: String) {
        registryLock.lock()
        activeStates[key] = state
        registryLock.unlock()
    }

    private static func lookupActiveState(key: String) -> State? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return activeStates[key]
    }

    private static func unregisterActiveState(key: String) {
        registryLock.lock()
        activeStates[key] = nil
        registryLock.unlock()
    }

    /// AudioPlayerService 在切歌 / 停止时调, 主动结束对应的 streaming session:
    /// - 如果 cachedRanges 已经合得拢 (单段从 0 到 totalLength), 走 rename
    /// - 如果就差小段缺口, 后台拉补完后 rename
    /// - 如果差太多 (用户跳过没听完), 不动 .partial 让 LRU / pruneStalePartialFiles
    ///   后续清理
    /// 核心目的: 不再依赖 writeToCache 被反复触发, 让会话结束后 .partial
    /// 能确定性地走完该走的路径。
    static func finalizeSession(partialPath: String) {
        guard let state = lookupActiveState(key: partialPath) else { return }
        unregisterActiveState(key: partialPath)
        state.finalizeSession()
    }

    /// 当前所有活跃 streaming session 的 .partial 绝对路径集合。
    /// 给「存储管理」用 —— 把这些 .partial 标成「正在播放/缓存中」, 跟
    /// 真正中断废弃的 .partial 区分, 用户就不会以为正在听的歌算 bug。
    static func activeSessionPaths() -> Set<String> {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Set(activeStates.keys)
    }
}

/// Carries fetch result across the async Task → sync semaphore wait.
/// Sendable-by-fiat: the Task fills it before signaling, the wait side
/// reads after — no concurrent access ever.
private final class FetchResultBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
}

private final class HTTPRangeFetcher: @unchecked Sendable {
    private let url: URL
    private let totalLength: Int64
    private let session: URLSession

    init(url: URL, totalLength: Int64) {
        self.url = url
        self.totalLength = totalLength

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }

    func fetch(offset: Int64, length: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let rangeHeader = offset < 0
            ? "bytes=\(offset)"
            : "bytes=\(offset)-\(offset + length - 1)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudioDecoderError.decodingFailed("Invalid HTTP range response")
        }

        switch http.statusCode {
        case 206:
            return data
        case 200 where offset == 0:
            // Server ignored Range. Returning the full body lets the cache
            // complete in one pass, matching the old full-download behavior
            // without corrupting non-zero offsets.
            return data
        case 200:
            throw AudioDecoderError.decodingFailed("HTTP server ignored Range")
        case 416 where offset >= totalLength:
            return Data()
        default:
            throw AudioDecoderError.decodingFailed("HTTP \(http.statusCode)")
        }
    }
}

/// Per-source mutable state. Held by the fetch block via the closure
/// capture; lives as long as the InputSource itself.
private final class State: @unchecked Sendable {
    private let label: String
    private let partialURL: URL
    private let finalURL: URL
    /// File path currently used for read+write. Starts as `partialURL`,
    /// switches to `finalURL` after the atomic rename triggered when
    /// every byte has been fetched (only when `persistOnComplete` is on).
    private var activeURL: URL
    private let totalLength: Int64
    /// When false, fully-fetched files are kept at `partialURL` (in
    /// NSTemporaryDirectory) and never promoted to the canonical cache
    /// path — used when the user has Audio Cache disabled.
    private let persistOnComplete: Bool
    /// LRU 里这个文件的相对路径 (`<sourceID>/<sanitized>`)。rename 完成
    /// 后用它去 AudioCacheManager.recordAccess 给本曲打访问时间戳, 让
    /// 后续 evict 能正确按 LRU 淘汰。nil 表示不持久化 (cache 关掉了)。
    private let cacheRelativePath: String?
    private let lock = NSLock()
    /// Disjoint sorted byte ranges already in the cache file. Coalesced
    /// after each write.
    private var cachedRanges: [Range<Int64>] = []
    /// Stored so background prefetch can run without an active SFB call.
    private let connectorFetch: @Sendable (Int64, Int64) async throws -> Data
    /// Chunk start offsets currently being fetched in background. Stops
    /// us from racing two prefetches against the same range when SFB
    /// asks repeatedly while a prefetch is still in flight.
    private var prefetchInFlight: Set<Int64> = []
    /// Set after a fetch failure (auth-revoked dlink, network down) to
    /// stop the prefetch path from hammering the connector. Without
    /// this, a single 403 spawns dozens of parallel retries in seconds
    /// — Baidu's anti-abuse then rate-limits the account globally.
    /// Cleared on the next successful serve.
    private var fetchDisabled: Bool = false

    /// 调试用: 记录从首次 serve 到现在的累积 fetch 次数和耗时。
    /// 方便诊断"卡顿 N 秒"是几次 fetch 累加的。
    private var firstServeAt: Date?
    private var fetchCount: Int = 0
    private var fetchTotalElapsed: TimeInterval = 0
    private var fetchTotalBytes: Int = 0
    /// SFB read 命中已 cache 部分的次数 / 字节。跟 fetchCount 一起在切歌时
    /// 输出 summary, 看 cache 复用率, 帮诊断"为什么这首歌仍然卡 ── 是 SFB
    /// 反复跨 chunk 边界 cache miss, 还是云盘真的拉不动"。
    private var cacheHitCount: Int = 0
    private var cacheHitBytes: Int = 0
    /// 每个 chunkStart 累计被 fetch 的次数。第 2 次 + 时打 retry 日志,
    /// 不正常应用情况下 SFB 不应该让同一个 chunk 被 fetch 多次 (fetch
    /// 完会写 cache, 下次 read 应该 cache hit)。出现 retry > 1 通常是
    /// 上次 fetch 写 cache 失败 / 或解码器的 short-read 触发了 chunk
    /// 重新对齐。
    private var fetchAttemptByChunk: [Int64: Int] = [:]
    /// 本 session 最慢 / 最快的单次 fetch, 帮诊断网络抖动是均匀慢还是
    /// 单次 spike。
    private var maxFetchElapsed: TimeInterval = 0
    private var slowestChunkStart: Int64 = -1
    private var minFetchElapsed: TimeInterval = .greatestFiniteMagnitude
    /// 等待并行 prefetch 完成的次数和总等待时间。这两个值高 = SFB 读到一个
    /// 已经在 prefetch 的 chunk, prefetch 没赶上 SFB 节奏 (chunk size 太大
    /// 或 prefetchAhead 不够)。
    private var prefetchWaitCount: Int = 0
    private var prefetchWaitTotalElapsed: TimeInterval = 0
    /// session 创建到 finalize 之间是否输出过摘要, 防止重复输出 (例如
    /// 同一 session 被 finalize 两次)。
    private var summaryEmitted: Bool = false

    /// 「补全 trailing 缺口」任务是否已经派出去过。每个 session 只跑一次,
    /// 防止 writeToCache 反复触发 + 多个 in-flight fill 互相打架。
    private var trailingFillScheduled: Bool = false

    /// 自动补齐缺口的阈值 — 缺口比这个小才主动拉。50MB 覆盖大部分
    /// 「播完但 trailing 没读到」的真实场景, 同时避免给那些 user 实际
    /// 只听了开头的歌强行下完整首。
    fileprivate static let autoFillThreshold: Int64 = 50 * 1024 * 1024

    init(
        label: String,
        partialURL: URL,
        finalURL: URL,
        totalLength: Int64,
        initialRanges: [Range<Int64>] = [],
        persistOnComplete: Bool = true,
        cacheRelativePath: String? = nil,
        connectorFetch: @escaping @Sendable (Int64, Int64) async throws -> Data
    ) {
        self.label = label
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.activeURL = partialURL
        self.totalLength = totalLength
        self.persistOnComplete = persistOnComplete
        self.cacheRelativePath = cacheRelativePath
        self.connectorFetch = connectorFetch
        // 排序 + 简单 dedupe (调用方应保证 disjoint, 这里不强行 coalesce)
        self.cachedRanges = initialRanges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Synchronously serve `length` bytes starting at `offset`. Reads from
    /// the cache where present, fetches the rest via `connectorFetch`.
    /// Returns at least `1` byte (or nil + error) — SFBAudioEngine treats
    /// short reads as "got some bytes, ask again", which is how we keep
    /// the chunk size bounded without over-fetching for header probes.
    func serve(
        offset: Int64,
        length: Int64,
        errorOut: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Data? {
        if offset >= totalLength { return Data() }
        let endOffset = min(offset + length, totalLength)

        let served: Data?

        // Cache hit — read straight from disk.
        if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
            // 不每次 plog, 累计在 finalize summary 输出 (read 一首歌可能几百
            // 次, 每次打日志会淹没真正重要的 fetch / 失败信息)。
            lock.lock()
            cacheHitCount += 1
            cacheHitBytes += cached.count
            lock.unlock()
            served = cached
        } else {
            // Chunk-align fetch, but skip already-cached prefix within
            // [chunkAlign, offset). 之前 prewarm head 256KB + chunk size 1MB
            // 时, SFB read 跨 256KB 边界后 cache miss → chunk align 回到 0
            // → 重新拉整个 1MB (重复拉前 256KB), 浪费带宽和时间。
            // 推 fetchStart 到 cache 末尾后, 只拉缺失的 [256KB..1MB]。
            let chunkSize = CloudPlaybackSource.chunkSize
            let chunkAlign = (offset / chunkSize) * chunkSize
            let chunkEnd = min(chunkAlign + chunkSize, totalLength)
            let chunkStart: Int64 = {
                lock.lock()
                var s = chunkAlign
                for r in cachedRanges where r.lowerBound < offset && r.upperBound > s {
                    let effectiveUpper = min(r.upperBound, offset)
                    if effectiveUpper > s { s = effectiveUpper }
                }
                lock.unlock()
                // 边界保护: 若 cache 已完全覆盖 chunk, 退回 chunkAlign 让 fetch
                // 至少拉一些 (理论上不该发生 — readFromCacheIfAvailable 应已 hit)
                return s >= chunkEnd ? chunkAlign : s
            }()
            let want = chunkEnd - chunkStart

            // Foreground decode must never wait long behind background
            // prefetch. Give an already-running prefetch a tiny chance to
            // finish, then issue the user-facing fetch anyway. On slow WAN
            // links this avoids "next track spins while prefetch owns the
            // connection pool" behavior.
            lock.lock()
            let prefetchActive = prefetchInFlight.contains(chunkStart)
            lock.unlock()
            if prefetchActive {
                let waitStart = Date()
                let waitDeadline = waitStart.addingTimeInterval(0.15)
                while Date() < waitDeadline {
                    Thread.sleep(forTimeInterval: 0.03)
                    if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
                        let elapsed = Date().timeIntervalSince(waitStart)
                        lock.lock()
                        prefetchWaitCount += 1
                        prefetchWaitTotalElapsed += elapsed
                        lock.unlock()
                        cacheHitCountIncrement(by: cached.count)
                        if elapsed > 0.1 {
                            plog(String(format: "⏳ Cloud stream '%@' waited %.0fms for prefetch chunkStart=%lld (then served from cache)",
                                        label, elapsed * 1000, chunkStart))
                        }
                        return cached
                    }
                    lock.lock()
                    let stillInFlight = prefetchInFlight.contains(chunkStart)
                    lock.unlock()
                    if !stillInFlight {
                        if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
                            let elapsed = Date().timeIntervalSince(waitStart)
                            lock.lock()
                            prefetchWaitCount += 1
                            prefetchWaitTotalElapsed += elapsed
                            lock.unlock()
                            cacheHitCountIncrement(by: cached.count)
                            return cached
                        }
                        let elapsed = Date().timeIntervalSince(waitStart)
                        plog(String(format: "⚠️ Cloud stream '%@' prefetch chunkStart=%lld dropped (waited %.0fms, falling back to user fetch)",
                                    label, chunkStart, elapsed * 1000))
                        break
                    }
                }
                if Date() >= waitDeadline {
                    let elapsed = Date().timeIntervalSince(waitStart)
                    plog(String(format: "⏩ Cloud stream '%@' foreground fetch bypassing slow prefetch chunkStart=%lld after %.0fms",
                                label, chunkStart, elapsed * 1000))
                }
            }

            // 记录这次 fetch 的 attempt 次数。SFB 正常顺序读时每个 chunk 应该
            // 只 fetch 一次, attempt > 1 说明上次 fetch 完成但 cache 没写到
            // SFB 期望的位置 (e.g. partial fetch, short read), 或者解码器
            // 跳读后又回来。
            lock.lock()
            let attempt = (fetchAttemptByChunk[chunkStart] ?? 0) + 1
            fetchAttemptByChunk[chunkStart] = attempt
            lock.unlock()
            if attempt > 1 {
                plog(String(format: "🔁 Cloud stream '%@' fetch RETRY chunkStart=%lld attempt=%d (offsetReq=%lld)",
                            label, chunkStart, attempt, offset))
            }

            // Bridge async → sync. SFBAudioEngine's decode thread isn't
            // an actor or main, so a semaphore wait is safe. The `Box`
            // keeps result/error storage Sendable across the Task
            // boundary. Hard timeout because the fetch Task can hang
            // indefinitely (revoked dlink mid-handshake, network
            // never settling) and SFB has no way to surface that —
            // the user sees a forever-spinning play button. 30s is
            // longer than any legitimate single-chunk fetch.
            let result = FetchResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let startedAt = Date()
            Task { [connectorFetch] in
                do { result.data = try await connectorFetch(chunkStart, want) }
                catch { result.error = error }
                semaphore.signal()
            }
            let timeoutResult = semaphore.wait(timeout: .now() + .seconds(30))
            let elapsed = Date().timeIntervalSince(startedAt)
            if timeoutResult == .timedOut {
                lock.lock(); fetchDisabled = true; lock.unlock()
                plog(String(format: "⚠️ Cloud stream '%@' fetch timeout chunkStart=%lld len=%lld after %.1fs",
                            label, chunkStart, want, elapsed))
                errorOut?.pointee = NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "Cloud fetch timed out after 30s"]
                )
                return nil
            }

            if let error = result.error {
                // Disable further prefetches — see fetchDisabled doc.
                lock.lock(); fetchDisabled = true; lock.unlock()
                plog(String(format: "⚠️ Cloud stream '%@' fetch failed chunkStart=%lld len=%lld after %.2fs: %@",
                            label, chunkStart, want, elapsed, error.localizedDescription))
                errorOut?.pointee = error as NSError
                return nil
            }
            guard let data = result.data, !data.isEmpty else {
                lock.lock(); fetchDisabled = true; lock.unlock()
                plog(String(format: "⚠️ Cloud stream '%@' fetch returned empty chunkStart=%lld len=%lld after %.2fs",
                            label, chunkStart, want, elapsed))
                errorOut?.pointee = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                return nil
            }
            // 调试: 所有 fetch 都打印 chunkStart, 方便看 SFB read 模式
            plog(String(format: "☁️ Cloud stream '%@' fetch chunkStart=%lld want=%lld got=%d in %.2fs (offsetReq=%lld)",
                        label, chunkStart, want, data.count, elapsed, offset))
            // 累积统计 + 每 5 次或 elapsed > 总和 3s 时打一次摘要,方便调试 cold-start 卡顿
            lock.lock()
            if firstServeAt == nil { firstServeAt = startedAt }
            fetchCount += 1
            fetchTotalElapsed += elapsed
            fetchTotalBytes += data.count
            if elapsed > maxFetchElapsed {
                maxFetchElapsed = elapsed
                slowestChunkStart = chunkStart
            }
            if elapsed < minFetchElapsed {
                minFetchElapsed = elapsed
            }
            let count = fetchCount
            let totalElapsed = fetchTotalElapsed
            let totalBytes = fetchTotalBytes
            let sinceFirstServe = Date().timeIntervalSince(firstServeAt!)
            lock.unlock()
            if count == 1 || count % 5 == 0 {
                plog(String(format: "☁️ Cloud stream '%@' STATS: %d fetches, total=%.2fs, %dKB, wallclock=%.2fs",
                            label, count, totalElapsed, totalBytes / 1024, sinceFirstServe))
            }

            // Successful fetch — re-enable prefetching (may have been
            // disabled by a transient earlier failure).
            lock.lock(); fetchDisabled = false; lock.unlock()
            writeToCache(offset: chunkStart, data: data)

            // Slice out the part SFB actually asked for. The chunk may
            // start before `offset` (we floored to chunk boundary) and
            // extend past `endOffset`, so we have to translate back.
            let inChunkStart = Int(offset - chunkStart)
            let inChunkEnd = min(data.count, Int(endOffset - chunkStart))
            guard inChunkStart < inChunkEnd else { return Data() }
            served = data.subdata(in: inChunkStart..<inChunkEnd)
        }

        // Always try to keep one chunk ahead. Cheap when already cached
        // / in-flight (early bail), expensive only when we need a real
        // background fetch — and by then SFB hasn't asked for it yet, so
        // its decode thread doesn't block on the next chunk's network
        // round-trip. Without this, every cache miss every ~6s of audio
        // (256KB at typical mp3 bitrate) sat synchronously waiting on a
        // Baidu Range request while the audio queue drained.
        if let served, !served.isEmpty {
            let nextStart = offset + Int64(served.count)
            prefetchIfNeeded(startOffset: nextStart)
        }
        return served
    }

    /// Best-effort: kick off background fetches for the NEXT N chunks after
    /// `startOffset`, aligned to the `chunkSize` grid. Without alignment,
    /// every per-frame `serve` (SFB asks for ~1KB at a time) fired its own
    /// prefetch at a slightly-different offset — `prefetchInFlight` only
    /// dedupes by exact offset, so 30 nearly-identical 256KB fetches
    /// stampeded Baidu in <1s, drowning out the user-facing fetch and
    /// causing the first-buffer 35s timeout. Aligning collapses every
    /// serve within the same chunk to one prefetch.
    ///
    /// N 个并发 chunk(`prefetchAhead`)的关键: SFB 顺序读时不止快一个 chunk,
    /// 否则 mp3 全帧扫描场景下每个 chunk fetch 串行累加变成"整下时间"。
    private func prefetchIfNeeded(startOffset: Int64) {
        let chunkSize = CloudPlaybackSource.chunkSize
        // Round UP to the next chunk boundary — the chunk *containing*
        // startOffset was just fetched (or hit cache). Prefetch the ones
        // after it so SFB doesn't stall when it crosses boundaries.
        let baseChunkStart = ((startOffset / chunkSize) + 1) * chunkSize
        // 始终固定少量前瞻。不要按“小文件”切换成整首预取:
        // 真实音乐库里大部分 mp3 都小于 20MB, 那会让普通播放退化成
        // 整首后台下载, 在蜂窝 / 外网 NAS 上既抢前台带宽也浪费流量。
        let aheadCount = CloudPlaybackSource.prefetchAhead
        for i in 0..<aheadCount {
            let nextChunkStart = baseChunkStart + Int64(i) * chunkSize
            guard nextChunkStart < totalLength else { return }
            let want = min(chunkSize, totalLength - nextChunkStart)
            let endOffset = nextChunkStart + want

            guard tryClaimPrefetch(offset: nextChunkStart, endOffset: endOffset) else { continue }

            Task { [weak self, connectorFetch] in
                guard let self else { return }
                defer { self.releasePrefetch(offset: nextChunkStart) }
                do {
                    let data = try await connectorFetch(nextChunkStart, want)
                    guard !data.isEmpty else { return }
                    self.writeToCache(offset: nextChunkStart, data: data)
                } catch {
                    // Disable the prefetch path until a user-facing serve
                    // succeeds. Retries from a background-Task storm are
                    // exactly what triggers Baidu's anti-abuse rate-limit.
                    self.markFetchDisabled()
                }
            }
        }
    }

    /// Lock manipulation is wrapped in sync helpers because `NSLock`
    /// is annotated `noasync` under Swift 6 strict concurrency — calling
    /// `lock.lock()` directly inside the prefetch `Task` body fails to
    /// build. The helpers themselves aren't `noasync`, so async callers
    /// can use them freely.
    private func tryClaimPrefetch(offset: Int64, endOffset: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Don't prefetch when the last serve failed — letting prefetch
        // continue would re-trigger the same failure dozens of times
        // while the user-facing serve waits on its own retry path.
        if fetchDisabled { return false }
        if prefetchInFlight.contains(offset) { return false }
        if isRangeCovered(offset: offset, endOffset: endOffset) { return false }
        prefetchInFlight.insert(offset)
        return true
    }

    private func releasePrefetch(offset: Int64) {
        lock.lock()
        prefetchInFlight.remove(offset)
        lock.unlock()
    }

    private func markFetchDisabled() {
        lock.lock()
        fetchDisabled = true
        lock.unlock()
    }

    /// 把 cacheHit 累计字段加锁更新成原子动作。serve 多入口都要计数, 抽出
    /// 来比每处 lock/unlock 易读。
    private func cacheHitCountIncrement(by bytes: Int) {
        lock.lock()
        cacheHitCount += 1
        cacheHitBytes += bytes
        lock.unlock()
    }

    /// 在 finalizeSession / disconnect 之前打一次本 session 的统计摘要。
    /// 用来回头看一首歌为什么卡 ── 是 fetch 慢还是 SFB 反复 short-read 重读
    /// 还是 prefetch 跟不上, 一行能定位。
    fileprivate func emitSessionSummary() {
        lock.lock()
        if summaryEmitted { lock.unlock(); return }
        summaryEmitted = true
        let count = fetchCount
        let totalElapsed = fetchTotalElapsed
        let maxE = maxFetchElapsed
        let slow = slowestChunkStart
        let minE = minFetchElapsed == .greatestFiniteMagnitude ? 0 : minFetchElapsed
        let hit = cacheHitCount
        let hitKB = cacheHitBytes / 1024
        let pwCount = prefetchWaitCount
        let pwElapsed = prefetchWaitTotalElapsed
        let retries = fetchAttemptByChunk.values.filter { $0 > 1 }.count
        let cachedKB = cachedRanges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) } / 1024
        let totalKB = Int(totalLength) / 1024
        let sinceFirst = firstServeAt.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()

        plog(String(format:
            "📊 Cloud SUMMARY '%@' %dKB/%dKB cached, fetch=%d (%.2fs avg=%.2fs min=%.2fs max=%.2fs@%lld) retry=%d hit=%d/%dKB prefetchWait=%d/%.2fs lifetime=%.1fs",
            label,
            cachedKB, totalKB,
            count, totalElapsed,
            count > 0 ? totalElapsed / Double(count) : 0,
            minE, maxE, slow,
            retries,
            hit, hitKB,
            pwCount, pwElapsed,
            sinceFirst))
    }

    /// Caller MUST hold `lock`. Returns true when `cachedRanges`
    /// completely covers `[offset, endOffset)`.
    private func isRangeCovered(offset: Int64, endOffset: Int64) -> Bool {
        cachedRanges.contains { $0.lowerBound <= offset && $0.upperBound >= endOffset }
    }

    private func readFromCacheIfAvailable(offset: Int64, endOffset: Int64) -> Data? {
        lock.lock()
        let coveringRange = cachedRanges.first { $0.contains(offset) }
        let url = activeURL
        lock.unlock()
        guard let coveringRange else { return nil }
        let upper = min(endOffset, coveringRange.upperBound)
        guard upper > offset else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return handle.readData(ofLength: Int(upper - offset))
        } catch {
            return nil
        }
    }

    private func writeToCache(offset: Int64, data: Data) {
        lock.lock()
        let url = activeURL
        lock.unlock()

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            handle.write(data)
            try? handle.close()
        } catch {
            try? handle.close()
            return
        }

        lock.lock()
        mergeRange(offset..<offset + Int64(data.count))
        // Once the entire file is covered AND we're allowed to persist,
        // rename .partial → final so the canonical cache path is only
        // ever populated when truly complete. Future plays of this song
        // hit the SourceManager Priority-1 local-cache fast path.
        // When `persistOnComplete` is off (Audio Cache disabled), we skip
        // the rename — the temp file lives in NSTemporaryDirectory and
        // iOS purges it on its own schedule.
        var renamedRelativePath: String?
        var fillRequest: (offset: Int64, length: Int64)?
        if persistOnComplete,
           activeURL == partialURL,
           cachedRanges.count == 1,
           cachedRanges[0].lowerBound == 0,
           cachedRanges[0].upperBound == totalLength {
            try? FileManager.default.removeItem(at: finalURL)
            do {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
                activeURL = finalURL
                renamedRelativePath = cacheRelativePath
            } catch {
                // Stay on partialURL — next play will re-stream from scratch.
            }
        } else if persistOnComplete,
                  activeURL == partialURL,
                  !trailingFillScheduled,
                  cachedRanges.first?.lowerBound == 0 {
            // 「就差一小段就能 rename」的常见模式:
            // 1) 单段 [0, X), X 接近 totalLength — 用户播完歌但 SFB 没读
            //    最末尾几 KB (e.g., mp3 ID3v1 trailing); 缺 [X, totalLength)
            // 2) 双段 [0, X) + [Y, totalLength), Y - X 较小 — 顺序播没追上
            //    prewarm tail; 缺 [X, Y)
            //
            // 只在缺口 < autoFillThreshold 时主动补, 避免对真正大段没下完
            // 的歌 (用户跳过) 还浪费带宽硬下完。补完 writeToCache 会再回来
            // 走 rename 分支。
            let firstUpper = cachedRanges[0].upperBound
            if cachedRanges.count == 1,
               firstUpper < totalLength,
               (totalLength - firstUpper) < Self.autoFillThreshold {
                fillRequest = (firstUpper, totalLength - firstUpper)
                trailingFillScheduled = true
            } else if cachedRanges.count == 2,
                      cachedRanges[1].upperBound == totalLength,
                      (cachedRanges[1].lowerBound - firstUpper) < Self.autoFillThreshold {
                fillRequest = (firstUpper, cachedRanges[1].lowerBound - firstUpper)
                trailingFillScheduled = true
            }
        }
        lock.unlock()

        if let req = fillRequest {
            // background 跑, 不阻塞当前 serve / SFB read。失败也不要紧 ——
            // 下次播这首歌走 stream 再尝试, 或者被 pruneStalePartialFiles 清掉。
            Task { [weak self, connectorFetch, label] in
                guard let self else { return }
                do {
                    let data = try await connectorFetch(req.offset, req.length)
                    if !data.isEmpty {
                        self.writeToCache(offset: req.offset, data: data)
                    }
                } catch {
                    plog("⚠️ Cloud stream '\(label)' trailing fill failed: \(error.localizedDescription)")
                }
            }
        }

        // 完整下完 + rename 成功后给 LRU 打访问时间戳, 这样后续的
        // evictIfNeeded 才知道这个文件最近被访问过, 不会优先把它淘汰。
        // 之前 Range streaming 路径完全不通知 AudioCacheManager, 所以
        // 2GB 上限对 NAS 全失效。
        if let path = renamedRelativePath {
            Task { await AudioCacheManager.shared.recordAccess(path: path) }
        }
    }

    /// 由 AudioPlayerService 切歌 / 停止时通过 finalizeSession(partialPath:)
    /// 触发, 主动结束这个 session 的 .partial 状态。三种结果:
    /// - 已经是 final: 啥也不做
    /// - 缺口在 autoFillThreshold 内: 后台拉缺失字节, 拉完 writeToCache
    ///   会自动 rename。这里只触发, 不等待。
    /// - 缺口太大 (用户跳过没听到那段): 不动, .partial 留着 LRU / pruneStale
    ///   后续清理。
    fileprivate func finalizeSession() {
        // 不论结果如何, finalize 时机一律输出一次 session summary, 用来对照
        // 本首歌的 fetch / cache / prefetch 表现。emitSessionSummary 内部
        // dedupe, 多次调用只输出一次。
        emitSessionSummary()
        // Audio Cache 关闭时 streaming 文件只放在 NSTemporaryDirectory 供
        // 本次 SFB 解码读取。不要在用户切歌/停止后继续补齐临时文件, 否则
        // 会把"边播边取"退化成后台整首下载。
        guard persistOnComplete else { return }
        lock.lock()
        // 已经 rename 过了, 啥也不做。
        if activeURL == finalURL {
            lock.unlock()
            return
        }
        // 已经派发过 trailing fill task, 不重复触发。
        if trailingFillScheduled {
            lock.unlock()
            return
        }
        guard !cachedRanges.isEmpty,
              cachedRanges[0].lowerBound == 0 else {
            lock.unlock()
            return
        }
        var fillRequest: (offset: Int64, length: Int64)?
        let firstUpper = cachedRanges[0].upperBound
        if cachedRanges.count == 1,
           firstUpper < totalLength,
           (totalLength - firstUpper) < Self.autoFillThreshold {
            fillRequest = (firstUpper, totalLength - firstUpper)
            trailingFillScheduled = true
        } else if cachedRanges.count == 2,
                  cachedRanges[1].upperBound == totalLength,
                  (cachedRanges[1].lowerBound - firstUpper) < Self.autoFillThreshold {
            fillRequest = (firstUpper, cachedRanges[1].lowerBound - firstUpper)
            trailingFillScheduled = true
        }
        lock.unlock()

        guard let req = fillRequest else { return }
        plog("☁️ finalizeSession '\(label)' fill missing range [\(req.offset)..\(req.offset + req.length)) (\(req.length / 1024)KB)")
        Task { [weak self, connectorFetch, label] in
            guard let self else { return }
            do {
                let data = try await connectorFetch(req.offset, req.length)
                if !data.isEmpty {
                    self.writeToCache(offset: req.offset, data: data)
                }
            } catch {
                plog("⚠️ Cloud stream '\(label)' finalize fill failed: \(error.localizedDescription)")
            }
        }
    }

    private func mergeRange(_ newRange: Range<Int64>) {
        var combined = newRange
        var rest: [Range<Int64>] = []
        for r in cachedRanges {
            if r.upperBound < combined.lowerBound || r.lowerBound > combined.upperBound {
                rest.append(r)
            } else {
                combined = Swift.min(r.lowerBound, combined.lowerBound)..<Swift.max(r.upperBound, combined.upperBound)
            }
        }
        rest.append(combined)
        rest.sort { $0.lowerBound < $1.lowerBound }
        cachedRanges = rest
    }
}
