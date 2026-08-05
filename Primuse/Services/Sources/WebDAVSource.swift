import CryptoKit
import Foundation
import FilesProvider
import PrimuseKit

actor WebDAVSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let useSsl: Bool
    private let basePath: String?
    private let username: String
    private let password: String
    private var provider: WebDAVFileProvider?
    private var connectTask: Task<Void, Error>?
    private var didLogWholeResourceMetadataFallback = false
    private let cacheDirectory: URL

    /// 长生命周期 session, 让 fetchRange 复用 HTTP keep-alive 连接,
    /// 避免每次 chunk fetch 都重新 SSL handshake。
    /// 8 路并发: 配合 CloudPlaybackSource 小文件全 prefetch 时多 chunk 并发。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        useSsl: Bool,
        basePath: String? = nil,
        username: String,
        password: String
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.basePath = basePath
        self.username = username
        self.password = password

        // Per-source cache dir avoids file-name collisions when two WebDAV sources
        // happen to expose files with the same relative path.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_webdav_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if let connectTask {
            try await connectTask.value
            return
        }
        if provider != nil {
            return
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.establishConnection()
        }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func establishConnection() async throws {

        // 匿名 WebDAV 必须完全不带凭据；传一个 user/password 都为空的
        // URLCredential 仍可能让底层生成空的 Authorization challenge 响应。
        let credential: URLCredential? = if username.isEmpty && password.isEmpty {
            nil
        } else {
            URLCredential(user: username, password: password, persistence: .forSession)
        }

        guard let provider = WebDAVFileProvider(
            baseURL: try serverURL(),
            credential: credential
        ) else {
            throw SourceError.connectionFailed("Invalid WebDAV URL")
        }

        self.provider = provider

        do {
            _ = try await listFiles(at: "/")
            try Task.checkCancellation()
        } catch {
            self.provider = nil
            throw error
        }
    }

    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        provider = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let providerPath = providerRelativePath(path)

        return try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: providerPath) { contents, error in
                if let error {
                    // Re-throw the underlying NSError so SSLTrustStore can detect
                    // certificate errors and prompt the user. Wrapping it in
                    // SourceError.connectionFailed(_:) loses domain/code/userInfo.
                    continuation.resume(throwing: error)
                    return
                }

                let items = contents
                    .filter { !$0.name.hasPrefix(".") }
                    .map { file -> RemoteFileItem in
                        RemoteFileItem(
                            name: file.name,
                            path: file.path,
                            isDirectory: file.isDirectory,
                            size: file.size,
                            modifiedDate: file.modifiedDate
                        )
                    }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

                continuation.resume(returning: items)
            }
        }
    }

    private static func cacheFileName(for path: String) -> String {
        CacheFileNamePolicy.make(path: path)
    }

    func localURL(for path: String) async throws -> URL {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        // 缓存名用 SHA256 哈希: 朴素的 '/' → '_' 替换会让 "/A/B.mp3" 与 "/A_B.mp3"
        // 撞到同一缓存键、播到错误文件。
        let baseName = Self.cacheFileName(for: path)
        let localPath = cacheDirectory.appendingPathComponent(baseName)

        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath
        }

        let providerPath = providerRelativePath(path)

        // Download to a sibling temp path then atomically rename. FilesProvider's
        // copyItem moves a (possibly truncated) temp file to the destination even
        // on failure, so writing straight to localPath would leave a half-written
        // file that future calls treat as a complete cache hit (and never self-heal).
        let tempPath = cacheDirectory.appendingPathComponent(
            "\(baseName).part-\(UUID().uuidString)"
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                provider.copyItem(path: providerPath, toLocalURL: tempPath) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            if FileManager.default.fileExists(atPath: localPath.path) {
                try? FileManager.default.removeItem(at: tempPath)
            } else {
                try FileManager.default.moveItem(at: tempPath, to: localPath)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempPath)
            throw error
        }
        return localPath
    }

    func deleteFile(at path: String) async throws {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let providerPath = providerRelativePath(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            provider.removeItem(path: providerPath) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let request = try makeRangeRequest(path: path, rangeHeader: rangeHeader)
        let (data, response) = try await rangeSession.data(for: request)
        return try validateStrictRangeResponse(
            response,
            data: data,
            path: path,
            offset: offset,
            length: length
        )
    }

    func fetchMetadataRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let request = try makeRangeRequest(path: path, rangeHeader: rangeHeader)
        let (bytes, response) = try await rangeSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV metadata response")
        }
        switch http.statusCode {
        case 206:
            var data = Data()
            data.reserveCapacity(Int(clamping: length))
            for try await byte in bytes {
                data.append(byte)
                if data.count > Int(clamping: length) { break }
            }
            try rejectNonMediaResponseIfNeeded(http, data: data, path: path)
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid WebDAV Content-Range response")
            }
            return data
        case 200:
            let data = try await boundedMetadataSlice(
                bytes,
                offset: offset,
                length: length
            )
            try rejectNonMediaResponseIfNeeded(http, data: data, path: path)
            if !didLogWholeResourceMetadataFallback {
                didLogWholeResourceMetadataFallback = true
                plog("WebDAV metadata fallback: server ignored Range; streaming a bounded metadata slice without relaxing playback validation")
            }
            return data
        default:
            throw SourceError.connectionFailed("WebDAV metadata request failed: HTTP \(http.statusCode)")
        }
    }

    private func makeRangeRequest(path: String, rangeHeader: String) throws -> URLRequest {
        var request = URLRequest(url: try fileURL(for: path))
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !username.isEmpty || !password.isEmpty {
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    private func validateStrictRangeResponse(
        _ response: URLResponse,
        data: Data,
        path: String,
        offset: Int64,
        length: Int64
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV range response")
        }
        try rejectNonMediaResponseIfNeeded(http, data: data, path: path)
        switch http.statusCode {
        case 206:
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid WebDAV Content-Range response")
            }
            return data
        case 200:
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("WebDAV server ignored the byte Range request")
            }
            return data
        default:
            throw SourceError.connectionFailed("WebDAV range request failed: HTTP \(http.statusCode)")
        }
    }

    private func rejectNonMediaResponseIfNeeded(
        _ http: HTTPURLResponse,
        data: Data,
        path: String
    ) throws {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let expectsMediaResponse = PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
            || PrimuseConstants.supportedMusicVideoExtensions.contains(fileExtension)
        if expectsMediaResponse, httpMediaResponseLooksLikeErrorBody(http, data: data) {
            throw SourceError.connectionFailed("WebDAV returned a non-media response")
        }
    }

    private func boundedMetadataSlice(
        _ bytes: URLSession.AsyncBytes,
        offset: Int64,
        length: Int64
    ) async throws -> Data {
        guard length > 0 else { return Data() }
        if offset >= 0 {
            guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            var position: Int64 = 0
            var result = Data()
            result.reserveCapacity(Int(clamping: length))
            for try await byte in bytes {
                if position >= offset, position < end { result.append(byte) }
                position += 1
                if position >= end { break }
            }
            guard !result.isEmpty else {
                throw SourceError.connectionFailed("WebDAV metadata response was empty")
            }
            return result
        }

        guard offset != Int64.min else { return Data() }
        let windowLength = max(length, -offset)
        guard windowLength <= 64 * 1024 * 1024 else {
            throw SourceError.connectionFailed("WebDAV metadata suffix window is too large")
        }
        let capacity = Int(windowLength)
        var ring = [UInt8](repeating: 0, count: capacity)
        var total: Int64 = 0
        for try await byte in bytes {
            ring[Int(total % windowLength)] = byte
            total += 1
        }
        let retainedCount = Int(min(total, windowLength))
        let retainedStart = total > windowLength ? Int(total % windowLength) : 0
        var retained = Data()
        retained.reserveCapacity(retainedCount)
        for index in 0..<retainedCount {
            retained.append(ring[(retainedStart + index) % capacity])
        }
        let absoluteStart = max(0, total + offset)
        let retainedAbsoluteStart = total - Int64(retainedCount)
        let relativeStart = max(0, absoluteStart - retainedAbsoluteStart)
        let relativeEnd = min(Int64(retainedCount), relativeStart + length)
        guard relativeStart < relativeEnd else {
            throw SourceError.connectionFailed("WebDAV metadata response was empty")
        }
        return retained.subdata(in: Int(relativeStart)..<Int(relativeEnd))
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let items = try await listFiles(at: path)

        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else if let scannable = SidecarHintResolver.scannableItem(item, siblings: items) {
                continuation.yield(scannable)
            }
        }
    }

    /// Strips the leading "/" so the path is resolved relative to baseURL.
    /// WebDAVFileProvider does relative-URL resolution, and an absolute path
    /// (one that starts with "/") will replace baseURL's path component —
    /// dropping basePath entirely.
    private func providerRelativePath(_ path: String) -> String {
        if path == "/" { return "" }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func serverURL() throws -> URL {
        let scheme = useSsl ? "https" : "http"
        guard let baseURL = NetworkURLBuilder.makeURL(
            host: host,
            defaultScheme: scheme,
            port: port,
            path: basePath
        ) else {
            throw SourceError.connectionFailed("Invalid WebDAV URL")
        }

        // WebDAVFileProvider needs a directory-style baseURL (trailing "/")
        // so that relative path resolution preserves basePath.
        let absolute = baseURL.absoluteString
        if absolute.hasSuffix("/") {
            return baseURL
        }
        return URL(string: absolute + "/") ?? baseURL
    }

    /// OpenList can omit the scheme/host and write `/d/...` into the STRM.
    /// Resolve only that well-known route at this WebDAV server's origin;
    /// ordinary absolute source paths must continue to stay under `basePath`.
    func openListSTRMURL(for reference: String) throws -> URL? {
        OpenListSTRMTargetResolver.resolve(reference, wrapperURL: try serverURL())
    }

    private func fileURL(for path: String) throws -> URL {
        var url = try serverURL()
        let relative = providerRelativePath(path)
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }
}
