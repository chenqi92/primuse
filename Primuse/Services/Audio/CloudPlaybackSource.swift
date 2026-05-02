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
    static let chunkSize: Int64 = 256 * 1024

    /// Size of the head chunk that `SourceManager.prewarmCloudSong` fetches
    /// for the next-up song. The `.prewarmed` sentinel sidecar is what
    /// proves the partial came from a prewarm — without it we'd risk
    /// trusting a sparse partial left by a prior session whose decoder
    /// happened to seek mid-file (sparse-file zeros would be decoded as
    /// silence/garbage and corrupt the cache state).
    static let prewarmHeadBytes: Int64 = 256 * 1024

    /// Sidecar marker filename suffix written next to the `.partial` by
    /// `SourceManager.prewarmCloudSong`. Consumed (deleted) by the first
    /// playback session that adopts the seed bytes — so a later session
    /// that finds a `.partial` without the marker treats it as untrusted.
    static let prewarmMarkerSuffix = ".prewarmed"

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
        persistOnComplete: Bool = true
    ) -> InputSource? {
        let partialURL = URL(fileURLWithPath: cacheURL.path + ".partial")
        let markerURL = URL(fileURLWithPath: partialURL.path + prewarmMarkerSuffix)

        // Only trust .partial bytes when the prewarm sidecar marker is
        // present — that's the unforgeable signal that the file is the
        // single contiguous head chunk produced by `prewarmCloudSong` and
        // not a sparse leftover from a prior decode session that seeked
        // around. Consume the marker so a future session can't pick up
        // bytes another session may have appended past the head.
        var initialRange: Range<Int64>? = nil
        let hasMarker = FileManager.default.fileExists(atPath: markerURL.path)
        if hasMarker,
           let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let size = attrs[.size] as? Int64,
           size > 0,
           size <= prewarmHeadBytes,
           size <= totalLength {
            initialRange = 0..<size
            try? FileManager.default.removeItem(at: markerURL)
        } else {
            // No marker, or shape doesn't match — start clean.
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: partialURL)
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }

        let path = song.filePath
        let connectorFetch: @Sendable (Int64, Int64) async throws -> Data = { off, len in
            try await connector.fetchRange(path: path, offset: off, length: len)
        }

        let state = State(
            label: song.title,
            partialURL: partialURL,
            finalURL: cacheURL,
            totalLength: totalLength,
            initialRange: initialRange,
            persistOnComplete: persistOnComplete,
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

    init(
        label: String,
        partialURL: URL,
        finalURL: URL,
        totalLength: Int64,
        initialRange: Range<Int64>? = nil,
        persistOnComplete: Bool = true,
        connectorFetch: @escaping @Sendable (Int64, Int64) async throws -> Data
    ) {
        self.label = label
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.activeURL = partialURL
        self.totalLength = totalLength
        self.persistOnComplete = persistOnComplete
        self.connectorFetch = connectorFetch
        if let initialRange { self.cachedRanges = [initialRange] }
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
            served = cached
        } else {
            // Always fetch a full chunk-aligned window. SFB MP3 parsing
            // probes headers in 4-byte and 623-byte reads — fetching only
            // those amounts left the cache full of unusable splinters and
            // turned every frame read into a fresh 2-second Baidu round
            // trip. Aligning to the `chunkSize` grid means one fetch
            // populates ~5 seconds of audio at typical bitrates and every
            // subsequent in-chunk read is a memory hit.
            let chunkSize = CloudPlaybackSource.chunkSize
            let chunkStart = (offset / chunkSize) * chunkSize
            let chunkEnd = min(chunkStart + chunkSize, totalLength)
            let want = chunkEnd - chunkStart

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
            if elapsed > 1.5 {
                plog(String(format: "☁️ Cloud stream '%@' fetch chunkStart=%lld len=%lld got=%d in %.2fs",
                            label, chunkStart, want, data.count, elapsed))
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

    /// Best-effort: kick off a background fetch for the NEXT chunk after
    /// `startOffset`, aligned to the `chunkSize` grid. Without alignment,
    /// every per-frame `serve` (SFB asks for ~1KB at a time) fired its own
    /// prefetch at a slightly-different offset — `prefetchInFlight` only
    /// dedupes by exact offset, so 30 nearly-identical 256KB fetches
    /// stampeded Baidu in <1s, drowning out the user-facing fetch and
    /// causing the first-buffer 35s timeout. Aligning collapses every
    /// serve within the same chunk to one prefetch.
    private func prefetchIfNeeded(startOffset: Int64) {
        let chunkSize = CloudPlaybackSource.chunkSize
        // Round UP to the next chunk boundary — the chunk *containing*
        // startOffset was just fetched (or hit cache). Prefetch the one
        // after it so SFB doesn't stall when it crosses the boundary.
        let nextChunkStart = ((startOffset / chunkSize) + 1) * chunkSize
        guard nextChunkStart < totalLength else { return }
        let want = min(chunkSize, totalLength - nextChunkStart)
        let endOffset = nextChunkStart + want

        guard tryClaimPrefetch(offset: nextChunkStart, endOffset: endOffset) else { return }

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
        if persistOnComplete,
           activeURL == partialURL,
           cachedRanges.count == 1,
           cachedRanges[0].lowerBound == 0,
           cachedRanges[0].upperBound == totalLength {
            try? FileManager.default.removeItem(at: finalURL)
            do {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
                activeURL = finalURL
            } catch {
                // Stay on partialURL — next play will re-stream from scratch.
            }
        }
        lock.unlock()
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
