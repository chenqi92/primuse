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
        cacheURL: URL
    ) -> InputSource? {
        let partialURL = URL(fileURLWithPath: cacheURL.path + ".partial")
        // Wipe stale partial — we don't persist the byte-range set across
        // sessions, so we can't trust which bytes a previous run filled.
        try? FileManager.default.removeItem(at: partialURL)
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)

        let state = State(partialURL: partialURL, finalURL: cacheURL, totalLength: totalLength)
        let path = song.filePath

        let block: CloudInputFetchBlock = { offset, length, errorOut in
            return state.serve(
                offset: offset,
                length: length,
                connectorFetch: { off, len in
                    try await connector.fetchRange(path: path, offset: off, length: len)
                },
                errorOut: errorOut
            )
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
    private let partialURL: URL
    private let finalURL: URL
    /// File path currently used for read+write. Starts as `partialURL`,
    /// switches to `finalURL` after the atomic rename triggered when
    /// every byte has been fetched.
    private var activeURL: URL
    private let totalLength: Int64
    private let lock = NSLock()
    /// Disjoint sorted byte ranges already in the cache file. Coalesced
    /// after each write.
    private var cachedRanges: [Range<Int64>] = []

    init(partialURL: URL, finalURL: URL, totalLength: Int64) {
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.activeURL = partialURL
        self.totalLength = totalLength
    }

    /// Synchronously serve `length` bytes starting at `offset`. Reads from
    /// the cache where present, fetches the rest via `connectorFetch`.
    /// Returns at least `1` byte (or nil + error) — SFBAudioEngine treats
    /// short reads as "got some bytes, ask again", which is how we keep
    /// the chunk size bounded without over-fetching for header probes.
    func serve(
        offset: Int64,
        length: Int64,
        connectorFetch: @escaping @Sendable (Int64, Int64) async throws -> Data,
        errorOut: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Data? {
        if offset >= totalLength { return Data() }
        let endOffset = min(offset + length, totalLength)

        // Cache hit — read straight from disk.
        if let cached = readFromCacheIfAvailable(offset: offset, endOffset: endOffset) {
            return cached
        }

        // Decide how many bytes to fetch this round. Cap at chunkSize so a
        // header probe (often 4-32KB) doesn't pull megabytes the user
        // might never play through.
        let want = min(endOffset - offset, CloudPlaybackSource.chunkSize)

        // Bridge async → sync. SFBAudioEngine's decode thread isn't an
        // actor or main, so a semaphore wait is safe. The `Box` keeps
        // result/error storage Sendable across the Task boundary.
        let result = FetchResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { result.data = try await connectorFetch(offset, want) }
            catch { result.error = error }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = result.error {
            errorOut?.pointee = error as NSError
            return nil
        }
        guard let data = result.data, !data.isEmpty else {
            errorOut?.pointee = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            return nil
        }

        writeToCache(offset: offset, data: data)

        // Server may return more or fewer bytes than asked — return up
        // to `length` from what we got starting at `offset`.
        let copyCount = min(data.count, Int(length))
        return data.prefix(copyCount)
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
        // Once the entire file is covered, rename .partial → final so the
        // canonical cache path is only ever populated when truly complete.
        // Future plays of this song hit the SourceManager Priority-1
        // local-cache fast path and skip streaming altogether.
        if activeURL == partialURL,
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
