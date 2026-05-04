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

    /// 默认一次性后台并发预取这么多个 chunk (大文件场景)。
    /// 实际值会按 file size 自适应: 小文件 (<= prefetchSmallFileThreshold)
    /// 直接拉整个文件, SFB 任意 seek 都 cache hit。
    /// 4 而不是 8: 8 路并发 + 1 user fetch 给 NAS 太多压力, 实测每个 chunk
    /// fetch 从 0.5s 变 1.5s, 反而拖慢 firstBuffer。配合 user fetch 等待
    /// in-flight prefetch 复用结果, 4 路 + 复用 = 实际有效 5+ 个 chunk
    /// 同时 cover, 性能更稳。
    static let prefetchAhead: Int = 4

    /// 小于这个 size 的文件, prefetch 一次性覆盖整个文件 (减去 head + tail)。
    /// mp3 SFB.open() 阶段会跳读到中段做 frame index seek (实测跳到 1MB / 6MB
    /// / 9MB 等位置), 顺序 prefetch ahead=N 完全覆盖不到。直接全文件 prefetch
    /// 让 SFB 任意 seek 都 hit。20MB = 典型 mp3 (4-15MB) 全覆盖, 长 flac
    /// (50MB+) 不全拉避免冷启动流量爆炸。
    static let prefetchSmallFileThreshold: Int64 = 20 * 1024 * 1024

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

        let path = song.filePath
        let connectorFetch: @Sendable (Int64, Int64) async throws -> Data = { off, len in
            try await connector.fetchRange(path: path, offset: off, length: len)
        }

        plog("☁️ makeInputSource '\(song.title)' totalLength=\(totalLength) initialRanges=\(initialRanges.map { "[\($0.lowerBound)..\($0.upperBound))" }.joined(separator: ","))")

        let state = State(
            label: song.title,
            partialURL: partialURL,
            finalURL: cacheURL,
            totalLength: totalLength,
            initialRanges: initialRanges,
            persistOnComplete: persistOnComplete,
            cacheRelativePath: cacheRelativePath,
            connectorFetch: connectorFetch
        )

        let block: CloudInputFetchBlock = { offset, length, errorOut in
            return state.serve(offset: offset, length: length, errorOut: errorOut)
        }

        return CloudInputSourceObjC(
            url: URL(string: "primuse-cloud://\(song.sourceID)\(song.filePath)"),
            totalLength: totalLength,
            fetch: block
        )
    }
}

/// Carries fetch result across the async Task → sync semaphore wait.
/// Sendable-by-fiat: the Task fills it before signaling, the wait side
/// reads after — no concurrent access ever.
private final class FetchResultBox: @unchecked Sendable {
    var data: Data?
    var error: Error?
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

        // 入口立即触发 prefetch (后续 N 个 chunk), 让 prefetch 与 user-facing
        // fetch 真正并发跑。之前 prefetch 在 serve 末尾触发, cache miss 时
        // 主 fetch 1s 阻塞 + prefetch 串行启动 → SFB 接下来读下一个 chunk
        // 还是 cache miss + 等下一次 fetch。改到入口后, SFB 读 chunk N 的
        // user fetch 与 chunk N+1..N+4 prefetch 并行, 整体 firstBuffer
        // 时间从 3s 降到 ~1s (单次 RTT)。
        prefetchIfNeeded(startOffset: offset)

        let served: Data?

        // Cache hit — read straight from disk.
        if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
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

            // 关键优化: 如果这个 chunk 已经被 prefetch task 在拉, 等它完成读
            // cache, 而不是并发自己再发一个 fetch (SFB 顺序读时 user fetch
            // 紧跟 prefetch, 双 fetch 同 chunk 浪费 NAS 带宽且让两边都变慢)。
            lock.lock()
            let prefetchActive = prefetchInFlight.contains(chunkStart)
            lock.unlock()
            if prefetchActive {
                // Poll cache (background thread, sleep OK). Prefetch 完成
                // (成功写 cache 或失败移除 in-flight) 时退出 wait。
                let waitDeadline = Date().addingTimeInterval(8)
                while Date() < waitDeadline {
                    Thread.sleep(forTimeInterval: 0.03)
                    if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
                        return cached
                    }
                    lock.lock()
                    let stillInFlight = prefetchInFlight.contains(chunkStart)
                    lock.unlock()
                    if !stillInFlight {
                        // Prefetch 退出了 — 再读 cache, 命中就返回; 否则
                        // (prefetch 失败) fall through 到 user fetch 路径。
                        if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
                            return cached
                        }
                        break
                    }
                }
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
        // 小文件直接拉到结尾, mp3 SFB.open() 跳读全文件做 frame index seek 时
        // 任意位置都 cache hit。大文件用固定 ahead 数量避免一次性流量爆炸。
        let aheadCount: Int = {
            if totalLength <= CloudPlaybackSource.prefetchSmallFileThreshold {
                let remaining = max(0, totalLength - baseChunkStart)
                return Int((remaining + chunkSize - 1) / chunkSize)
            }
            return CloudPlaybackSource.prefetchAhead
        }()
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
        }
        lock.unlock()

        // 完整下完 + rename 成功后给 LRU 打访问时间戳, 这样后续的
        // evictIfNeeded 才知道这个文件最近被访问过, 不会优先把它淘汰。
        // 之前 Range streaming 路径完全不通知 AudioCacheManager, 所以
        // 2GB 上限对 NAS 全失效。
        if let path = renamedRelativePath {
            Task { await AudioCacheManager.shared.recordAccess(path: path) }
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
