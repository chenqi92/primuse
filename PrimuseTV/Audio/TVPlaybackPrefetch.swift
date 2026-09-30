#if os(tvOS)
import Foundation
import PrimuseKit
import UniformTypeIdentifiers

/// The first bytes (and the last few) of a song queued after the current one,
/// fetched while the current song plays, so an automatic advance opens the
/// file and starts sound without waiting on the network. Kept in memory: the
/// TV has no sparse audio cache.
struct TVPlaybackSeed: Sendable {
    let head: Data
    let tail: Data
    let totalLength: Int64
    /// UTType identifier from the server response, for streams whose file
    /// extension alone does not name a playable type.
    let contentTypeIdentifier: String?

    init(head: Data, tail: Data, totalLength: Int64, contentTypeIdentifier: String?) {
        // Slices keep their parent's indices; `bytes` indexes from zero.
        self.head = Data(head)
        self.tail = Data(tail)
        self.totalLength = totalLength
        self.contentTypeIdentifier = contentTypeIdentifier
    }

    var headEnd: Int64 { Int64(head.count) }
    var tailStart: Int64 { totalLength - Int64(tail.count) }

    /// Seeded bytes starting at `offset`, at most `maximumLength` of them; nil
    /// when the seed does not cover `offset`.
    func bytes(offset: Int64, maximumLength: Int64) -> Data? {
        guard offset >= 0, maximumLength > 0, offset < totalLength else { return nil }
        if offset < headEnd {
            let end = min(headEnd, offset + maximumLength)
            return head.subdata(in: Int(offset)..<Int(end))
        }
        if !tail.isEmpty, offset >= tailStart {
            let start = offset - tailStart
            let end = min(Int64(tail.count), start + maximumLength)
            return tail.subdata(in: Int(start)..<Int(end))
        }
        return nil
    }
}

/// Seeds for the songs about to play, plus at most one complete file for a
/// next song whose format the TV can only decode from a local copy.
final class TVPlaybackPrefetchStore: @unchecked Sendable {
    static let shared = TVPlaybackPrefetchStore()

    /// Next song ~8 MB at most, later songs ~1.25 MB each.
    private let seedByteLimit = 24 * 1024 * 1024
    private let lock = NSLock()
    private var seeds: [String: (seed: TVPlaybackSeed, stamp: UInt64)] = [:]
    private var stamp: UInt64 = 0
    private var completeFile: (key: String, url: URL)?

    /// Library identity of the bytes: a changed file (size or revision) never
    /// reuses an old seed.
    static func key(for song: Song) -> String {
        [
            song.sourceID,
            song.filePath,
            String(song.fileSize),
            song.revision ?? "",
            song.lastModified.map { String($0.timeIntervalSince1970) } ?? "",
        ].joined(separator: "\u{1F}")
    }

    func seed(for key: String) -> TVPlaybackSeed? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = seeds[key] else { return nil }
        stamp &+= 1
        entry.stamp = stamp
        seeds[key] = entry
        return entry.seed
    }

    func store(_ seed: TVPlaybackSeed, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        stamp &+= 1
        seeds[key] = (seed, stamp)
        var total = seeds.values.reduce(0) { $0 + $1.seed.head.count + $1.seed.tail.count }
        while total > seedByteLimit,
              let oldest = seeds.filter({ $0.key != key }).min(by: { $0.value.stamp < $1.value.stamp }) {
            total -= oldest.value.seed.head.count + oldest.value.seed.tail.count
            seeds[oldest.key] = nil
        }
    }

    /// The complete-file download for the next song. It is owned here, not
    /// by the prefetch loop, so a track change that restarts the loop does not
    /// throw away a download the song now starting is about to use.
    private var completeFileJob: (key: String, task: Task<URL?, Never>)?

    func hasCompleteFile(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completeFile?.key == key || completeFileJob?.key == key
    }

    /// Starts downloading the complete file for `key` unless it is already
    /// there or on its way. Any other song's file or download is dropped:
    /// only the next song keeps one.
    func startCompleteFileDownload(
        for key: String,
        download: @escaping @MainActor @Sendable () async -> URL?
    ) {
        discardCompleteFile(keeping: key)
        lock.lock()
        guard completeFile?.key != key, completeFileJob?.key != key else {
            lock.unlock()
            return
        }
        let task = Task { @MainActor in await download() }
        completeFileJob = (key, task)
        lock.unlock()
        Task { [weak self] in
            let url = await task.value
            self?.finishCompleteFileDownload(key: key, task: task, url: url)
        }
    }

    private func finishCompleteFileDownload(key: String, task: Task<URL?, Never>, url: URL?) {
        lock.lock()
        guard let job = completeFileJob, job.key == key, job.task == task else {
            lock.unlock()
            if let url { Self.removeManagedFile(url) }
            return
        }
        completeFileJob = nil
        let previous = completeFile
        if let url { completeFile = (key, url) }
        lock.unlock()
        if url != nil, let previous, previous.key != key {
            Self.removeManagedFile(previous.url)
        }
    }

    /// Hands the prefetched complete file for `key` to playback, waiting for
    /// a download that is still running. Playback moves the file into its
    /// own temporary path.
    func completeFileForPlayback(key: String) async -> URL? {
        while !Task.isCancelled {
            switch takeCompleteFile(for: key) {
            case .ready(let url):
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            case .downloading:
                try? await Task.sleep(for: .milliseconds(100))
            case .none:
                return nil
            }
        }
        return nil
    }

    private enum CompleteFileState {
        case ready(URL)
        case downloading
        case none
    }

    private func takeCompleteFile(for key: String) -> CompleteFileState {
        lock.lock()
        defer { lock.unlock() }
        if let completeFile, completeFile.key == key {
            self.completeFile = nil
            return .ready(completeFile.url)
        }
        return completeFileJob?.key == key ? .downloading : .none
    }

    /// Drops the complete file and any download for songs other than `key`
    /// (the song that is still next).
    func discardCompleteFile(keeping key: String?) {
        lock.lock()
        var removed: URL?
        if let completeFile, completeFile.key != key {
            removed = completeFile.url
            self.completeFile = nil
        }
        var cancelled: Task<URL?, Never>?
        if let job = completeFileJob, job.key != key {
            cancelled = job.task
            completeFileJob = nil
        }
        lock.unlock()
        cancelled?.cancel()
        if let removed { Self.removeManagedFile(removed) }
    }

    private static func removeManagedFile(_ url: URL) {
        _ = try? TVDecodedTemporaryFilePolicy.removeIfManaged(
            url,
            in: FileManager.default.temporaryDirectory
        )
    }
}

/// Serves the seeded head and tail from memory and everything else from the
/// protocol reader, so the first reads of a prefetched song never touch the
/// network. Short reads at the seed boundary let `TVProtocolResourceLoader`
/// continue from the inner reader.
struct TVSeededByteRangeReader: ByteRangeReader {
    let inner: any ByteRangeReader
    let seed: TVPlaybackSeed

    func contentLength() async throws -> Int64 { seed.totalLength }

    func read(offset: Int64, length: Int64) async throws -> Data {
        if let bytes = seed.bytes(offset: offset, maximumLength: length) { return bytes }
        return try await inner.read(offset: offset, length: length)
    }

    func close() async { await inner.close() }
}

/// Bounded Range reads for queue seeds against a resolved stream URL. A
/// server that ignores `Range` costs at most the requested window plus slack
/// and ends the seed instead of downloading the whole file.
enum TVPrefetchHTTPRangeReader {
    struct Response: Sendable {
        let data: Data
        let totalLength: Int64
        let contentTypeIdentifier: String?
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: TVInsecureTLSDelegate(), delegateQueue: nil)
    }()

    static func fetch(
        _ resolved: ResolvedStream,
        offset: Int64,
        length: Int64
    ) async throws -> Response {
        guard let range = SafeByteRange.httpHeader(offset: offset, length: length) else {
            throw SpeculativeRangeReadError.rangeUnsupported
        }
        var request = URLRequest(url: resolved.url)
        for (key, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let signsEachRequest = resolved.headers[FnMusicAPIProtocol.authxHeaderField] != nil
            && FnMusicAPIProtocol.authxPath(for: resolved.url) == "\(FnMusicAPIProtocol.apiPath)/track/stream"
        if signsEachRequest {
            FnMusicAPIProtocol.applyAuthx(to: &request)
        }
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            maximumBytes: SpeculativeRangeRead.responseLimit(forRequestedLength: length),
            redirectMode: signsEachRequest ? .fnMusic : .safe
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { UTType(mimeType: $0)?.identifier }
        switch http.statusCode {
        case 206:
            guard let total = HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw URLError(.badServerResponse)
            }
            return Response(data: data, totalLength: total, contentTypeIdentifier: contentType)
        case 200:
            // Only a file no longer than the request is acceptable whole;
            // anything else means the server ignored `Range`.
            guard offset == 0, Int64(data.count) <= length else {
                throw SpeculativeRangeReadError.rangeUnsupported
            }
            return Response(data: data, totalLength: Int64(data.count), contentTypeIdentifier: contentType)
        default:
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
    }
}
#endif
