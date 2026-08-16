import CryptoKit
import Foundation
import FilesProvider
import PrimuseKit

actor WebDAVSource: MusicSourceConnector, OpenListSTRMResolvingConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let useSsl: Bool
    private let basePath: String?
    private let username: String
    private let password: String
    private var provider: WebDAVFileProvider?
    private var usesTrustedURLSession = false
    private var connectTask: Task<Void, Error>?
    private var didLogWholeResourceMetadataFallback = false
    private let cacheDirectory: URL

    /// 长生命周期 session, 让 fetchRange 复用 HTTP keep-alive 连接,
    /// 避免每次 chunk fetch 都重新 SSL handshake。
    /// 8 路并发: 配合 CloudPlaybackSource 小文件全 prefetch 时多 chunk 并发。
    private var rangeSession: URLSession!
    private var redirectedMediaSession: URLSession!

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
        self.rangeSession = Self.makeRangeSession(
            host: host,
            port: port,
            useSsl: useSsl,
            username: username,
            password: password
        )
        self.redirectedMediaSession = Self.makeRedirectedMediaSession()
    }

    private static func makeRangeSession(
        host: String,
        port: Int?,
        useSsl: Bool,
        username: String,
        password: String
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                httpUsername: username,
                httpPassword: password,
                httpCredentialEndpoint: NetworkEndpointIdentity(
                    scheme: useSsl ? "https" : "http",
                    host: host,
                    port: port
                ),
                redirectPolicy: .sameEndpoint,
                defersUntrustedServerTrustToCaller: true
            ),
            delegateQueue: nil
        )
    }

    private static func makeRedirectedMediaSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(redirectPolicy: .media),
            delegateQueue: nil
        )
    }

    func connect() async throws {
        if let connectTask {
            try await connectTask.value
            return
        }
        if provider != nil || usesTrustedURLSession {
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

        let baseURL = try serverURL()
        let requiresPlainSocket = TrustedHTTPTransport.requiresPlainSocket(for: baseURL)
        let usesAppManagedTransport = useSsl || requiresPlainSocket
        if usesAppManagedTransport {
            try await establishTrustedConnection()
            return
        }

        // 匿名 WebDAV 必须完全不带凭据；传一个 user/password 都为空的
        // URLCredential 仍可能让底层生成空的 Authorization challenge 响应。
        let credential: URLCredential? = if username.isEmpty && password.isEmpty {
            nil
        } else {
            URLCredential(user: username, password: password, persistence: .forSession)
        }

        guard let provider = WebDAVFileProvider(
            baseURL: baseURL,
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
            guard useSsl, SSLTrustStore.sslErrorDomain(from: error) != nil else {
                throw error
            }
            // FilesProvider owns a final URLSession delegate and cannot apply
            // Primuse's endpoint-scoped TOFU policy. Retry this connector with
            // our shared trusted transport so the normal certificate prompt,
            // pinning, and rotation checks remain in force.
            try await establishTrustedConnection()
        }
    }
    private func establishTrustedConnection() async throws {
        usesTrustedURLSession = true
        do {
            _ = try await listFilesUsingTrustedTransport(at: "/")
            try Task.checkCancellation()
        } catch {
            usesTrustedURLSession = false
            if useSsl, SSLTrustStore.sslErrorDomain(from: error) != nil {
                rangeSession.invalidateAndCancel()
                rangeSession = Self.makeRangeSession(
                    host: host,
                    port: port,
                    useSsl: useSsl,
                    username: username,
                    password: password
                )
            }
            throw error
        }
    }


    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        provider = nil
        usesTrustedURLSession = false
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if usesTrustedURLSession {
            return try await listFilesUsingTrustedTransport(at: path)
        }
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let pathPolicy = WebDAVPathPolicy(basePath: try serverURL().path)
        guard let currentSourcePath = RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: path) else {
            throw SourceError.connectionFailed("Invalid WebDAV directory path")
        }

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
                    .compactMap { file -> RemoteFileItem? in
                        guard !file.name.hasPrefix("."),
                              let sourcePath = pathPolicy.sourcePath(forProviderPath: file.path),
                              sourcePath != currentSourcePath else {
                            return nil
                        }
                        return RemoteFileItem(
                            name: file.name,
                            path: sourcePath,
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
        guard provider != nil || usesTrustedURLSession else {
            throw SourceError.connectionFailed("Not connected")
        }

        // 缓存名用 SHA256 哈希: 朴素的 '/' → '_' 替换会让 "/A/B.mp3" 与 "/A_B.mp3"
        // 撞到同一缓存键、播到错误文件。
        let baseName = Self.cacheFileName(for: path)
        let localPath = cacheDirectory.appendingPathComponent(baseName)

        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath
        }

        // Download to a sibling temp path then atomically rename. FilesProvider's
        // copyItem moves a (possibly truncated) temp file to the destination even
        // on failure, so writing straight to localPath would leave a half-written
        // file that future calls treat as a complete cache hit (and never self-heal).
        let tempPath = cacheDirectory.appendingPathComponent(
            "\(baseName).part-\(UUID().uuidString)"
        )

        do {
            if usesTrustedURLSession {
                let request = try makeWebDAVRequest(
                    url: fileURL(for: path),
                    method: "GET"
                )
                let (downloadedURL, response) = try await downloadFollowingMediaRedirects(
                    for: request
                )
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    if let status = (response as? HTTPURLResponse)?.statusCode,
                       status == 401 || status == 403 {
                        throw SourceError.authenticationFailed
                    }
                    throw SourceError.connectionFailed(
                        "WebDAV download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    )
                }
                try FileManager.default.moveItem(at: downloadedURL, to: tempPath)
            } else if let provider {
                let providerPath = providerRelativePath(path)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    provider.copyItem(path: providerPath, toLocalURL: tempPath) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                }
            } else {
                throw SourceError.connectionFailed("Not connected")
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
        if usesTrustedURLSession {
            let request = try makeWebDAVRequest(
                url: fileURL(for: path),
                method: "DELETE"
            )
            let (_, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: rangeSession
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                if let status = (response as? HTTPURLResponse)?.statusCode,
                   status == 401 || status == 403 {
                    throw SourceError.authenticationFailed
                }
                throw SourceError.connectionFailed(
                    "WebDAV delete failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
            }
            return
        }
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
        let maxBytes = Int(clamping: max(length, 0))
        let responseLimit = maxBytes > Int.max - 64 * 1024 ? Int.max : maxBytes + 64 * 1024
        let (data, response) = try await dataFollowingMediaRedirects(
            for: request,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
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
        if let url = request.url, TrustedHTTPTransport.requiresPlainSocket(for: url) {
            let requestedBodyBytes = Int(clamping: max(length, 0))
            let maximumRangedBodyBytes = requestedBodyBytes > Int.max - 64 * 1024
                ? Int.max
                : requestedBodyBytes + 64 * 1024
            let wholeResponsePrefixLimit: Int? = {
                guard offset >= 0,
                      let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                    return nil
                }
                return Int(clamping: end)
            }()
            let (temporaryURL, response) = try await TrustedHTTPTransport.download(
                for: request,
                session: rangeSession,
                maximumRangedBodyBytes: maximumRangedBodyBytes,
                wholeResponsePrefixLimit: wholeResponsePrefixLimit
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse else {
                throw SourceError.connectionFailed("Invalid WebDAV metadata response")
            }
            let bodyLength = try temporaryResponseBodyLength(at: temporaryURL)
            let responsePrefix = try boundedMetadataSlice(
                temporaryURL,
                offset: 0,
                length: min(bodyLength, 4 * 1024)
            )
            switch http.statusCode {
            case 206:
                try rejectNonMediaResponseIfNeeded(http, data: responsePrefix, path: path)
                guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                    bodyLength: Int(clamping: bodyLength),
                    requestedOffset: offset,
                    requestedLength: length
                ) != nil else {
                    throw SourceError.connectionFailed("Invalid WebDAV Content-Range response")
                }
                return try boundedMetadataSlice(temporaryURL, offset: 0, length: length)
            case 200:
                try rejectNonMediaResponseIfNeeded(http, data: responsePrefix, path: path)
                let slice = try boundedMetadataSlice(temporaryURL, offset: offset, length: length)
                if !didLogWholeResourceMetadataFallback {
                    didLogWholeResourceMetadataFallback = true
                    plog("WebDAV metadata fallback: public HTTP server ignored Range; using a disk-backed metadata slice")
                }
                return slice
            default:
                throw SourceError.connectionFailed("WebDAV metadata request failed: HTTP \(http.statusCode)")
            }
        }
        let (bytes, response) = try await bytesFollowingMediaRedirects(for: request)
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

    private func dataFollowingMediaRedirects(
        for request: URLRequest,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            let initial = try await TrustedHTTPTransport.data(
                for: request,
                session: rangeSession,
                maxBytes: maxBytes
            )
            guard let redirected = redirectedMediaRequest(
                from: request,
                response: initial.1
            ) else {
                return initial
            }
            do {
                let result = try await TrustedHTTPTransport.data(
                    for: redirected,
                    session: redirectedMediaSession,
                    maxBytes: maxBytes
                )
                if attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                   let http = result.1 as? HTTPURLResponse,
                   HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: http.statusCode) {
                    continue
                }
                return result
            } catch {
                guard attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                      HTTPMediaRedirectRetryPolicy.isRetryable(error: error) else {
                    throw error
                }
            }
        }
        throw URLError(.unknown)
    }

    private func downloadFollowingMediaRedirects(
        for request: URLRequest
    ) async throws -> (URL, URLResponse) {
        for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            let initial = try await TrustedHTTPTransport.download(
                for: request,
                session: rangeSession
            )
            guard let redirected = redirectedMediaRequest(
                from: request,
                response: initial.1
            ) else {
                return initial
            }
            try? FileManager.default.removeItem(at: initial.0)
            do {
                let result = try await TrustedHTTPTransport.download(
                    for: redirected,
                    session: redirectedMediaSession
                )
                if attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                   let http = result.1 as? HTTPURLResponse,
                   HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: http.statusCode) {
                    try? FileManager.default.removeItem(at: result.0)
                    continue
                }
                return result
            } catch {
                guard attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                      HTTPMediaRedirectRetryPolicy.isRetryable(error: error) else {
                    throw error
                }
            }
        }
        throw URLError(.unknown)
    }

    private func bytesFollowingMediaRedirects(
        for request: URLRequest
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            let initial = try await rangeSession.bytes(for: request)
            guard let redirected = redirectedMediaRequest(
                from: request,
                response: initial.1
            ) else {
                return initial
            }
            do {
                let result = try await redirectedMediaSession.bytes(for: redirected)
                if attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                   let http = result.1 as? HTTPURLResponse,
                   HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: http.statusCode) {
                    continue
                }
                return result
            } catch {
                guard attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                      HTTPMediaRedirectRetryPolicy.isRetryable(error: error) else {
                    throw error
                }
            }
        }
        throw URLError(.unknown)
    }

    private func redirectedMediaRequest(
        from request: URLRequest,
        response: URLResponse
    ) -> URLRequest? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return HTTPMediaRedirectRequestPolicy.redirectedRequest(
            from: request,
            response: http
        )
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

    private func temporaryResponseBodyLength(at fileURL: URL) throws -> Int64 {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw SourceError.connectionFailed("WebDAV metadata response size was unavailable")
        }
        return Int64(fileSize)
    }

    private func boundedMetadataSlice(
        _ fileURL: URL,
        offset: Int64,
        length: Int64
    ) throws -> Data {
        guard length > 0 else { return Data() }
        let total = try temporaryResponseBodyLength(at: fileURL)
        guard offset != Int64.min else {
            throw SourceError.connectionFailed("WebDAV metadata response was empty")
        }
        let start = offset < 0 ? max(0, total + offset) : offset
        guard start < total,
              let requestedEnd = SafeByteRange.exclusiveEnd(offset: start, length: length) else {
            throw SourceError.connectionFailed("WebDAV metadata response was empty")
        }
        let end = min(total, requestedEnd)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: Int(clamping: end - start)) ?? Data()
        guard !data.isEmpty else {
            throw SourceError.connectionFailed("WebDAV metadata response was empty")
        }
        return data
    }

    private func listFilesUsingTrustedTransport(at path: String) async throws -> [RemoteFileItem] {
        let baseURL = try serverURL()
        var directoryURL = try fileURL(for: path)
        if !directoryURL.absoluteString.hasSuffix("/") {
            directoryURL = URL(string: directoryURL.absoluteString + "/") ?? directoryURL
        }
        var request = try makeWebDAVRequest(
            url: directoryURL,
            method: "PROPFIND"
        )
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:">
              <D:prop>
                <D:displayname/>
                <D:resourcetype/>
                <D:getcontentlength/>
                <D:getlastmodified/>
              </D:prop>
            </D:propfind>
            """.utf8
        )
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: rangeSession,
            maxBytes: 16 * 1024 * 1024
        )
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV directory response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.authenticationFailed
        }
        guard http.statusCode == 207 || (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("WebDAV directory request failed: HTTP \(http.statusCode)")
        }

        let entries = try WebDAVMultistatusParser.parse(data)
        guard let currentSourcePath = RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: path) else {
            throw SourceError.connectionFailed("Invalid WebDAV directory path")
        }

        let items = entries.compactMap { entry -> RemoteFileItem? in
            guard let sourcePath = sourcePath(forWebDAVHref: entry.href, baseURL: baseURL),
                  sourcePath != currentSourcePath else {
                return nil
            }
            let fallbackName = (sourcePath as NSString).lastPathComponent
            let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (name?.isEmpty == false ? name : nil) ?? fallbackName
            guard !resolvedName.isEmpty, !resolvedName.hasPrefix(".") else { return nil }
            return RemoteFileItem(
                name: resolvedName,
                path: sourcePath,
                isDirectory: entry.isDirectory,
                size: entry.contentLength ?? -1,
                modifiedDate: Self.webDAVDate(entry.lastModified)
            )
        }
        guard !entries.isEmpty else {
            throw SourceError.connectionFailed("WebDAV directory response contained no resources")
        }
        return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func makeWebDAVRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if !username.isEmpty || !password.isEmpty {
            let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sourcePath(forWebDAVHref href: String, baseURL: URL) -> String? {
        let escapedHref = href.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: " ").inverted
        ) ?? href
        guard let absoluteURL = URL(string: escapedHref, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        if let responseHost = absoluteURL.host,
           let baseHost = baseURL.host,
           InsecureHTTPHostPolicy.normalizedHost(responseHost)
            != InsecureHTTPHostPolicy.normalizedHost(baseHost) {
            return nil
        }

        return WebDAVPathPolicy(basePath: baseURL.path)
            .sourcePath(forServerPath: absoluteURL.standardized.path)
    }

    private static func webDAVDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return http.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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

private struct WebDAVMultistatusEntry: Sendable {
    let href: String
    let displayName: String?
    let contentLength: Int64?
    let lastModified: String?
    let isDirectory: Bool
}

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct Properties {
        var displayName: String?
        var contentLength: Int64?
        var lastModified: String?
        var isDirectory = false

        mutating func merge(_ other: Self) {
            displayName = other.displayName ?? displayName
            contentLength = other.contentLength ?? contentLength
            lastModified = other.lastModified ?? lastModified
            isDirectory = isDirectory || other.isDirectory
        }
    }

    private struct ResponseBuilder {
        var href: String?
        var statusCode: Int?
        var properties = Properties()
    }

    private struct PropstatBuilder {
        var statusCode: Int?
        var properties = Properties()
    }

    private var response: ResponseBuilder?
    private var propstat: PropstatBuilder?
    private var textBuffer = ""
    private(set) var entries: [WebDAVMultistatusEntry] = []

    static func parse(_ data: Data) throws -> [WebDAVMultistatusEntry] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceError.connectionFailed(
                parser.parserError?.localizedDescription ?? "Invalid WebDAV XML response"
            )
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Self.localName(qName ?? elementName)
        textBuffer = ""
        switch element {
        case "response":
            response = ResponseBuilder()
        case "propstat":
            propstat = PropstatBuilder()
        case "collection":
            propstat?.properties.isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = Self.localName(qName ?? elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href":
            response?.href = value
        case "displayname":
            propstat?.properties.displayName = value.isEmpty ? nil : value
        case "getcontentlength":
            propstat?.properties.contentLength = Int64(value)
        case "getlastmodified":
            propstat?.properties.lastModified = value.isEmpty ? nil : value
        case "status":
            let status = Self.statusCode(value)
            if propstat != nil {
                propstat?.statusCode = status
            } else {
                response?.statusCode = status
            }
        case "propstat":
            if let propstat,
               propstat.statusCode.map({ (200...299).contains($0) }) != false {
                response?.properties.merge(propstat.properties)
            }
            propstat = nil
        case "response":
            if let response,
               let href = response.href,
               !href.isEmpty,
               response.statusCode.map({ (200...299).contains($0) }) != false {
                entries.append(
                    WebDAVMultistatusEntry(
                        href: href,
                        displayName: response.properties.displayName,
                        contentLength: response.properties.contentLength,
                        lastModified: response.properties.lastModified,
                        isDirectory: response.properties.isDirectory
                    )
                )
            }
            response = nil
        default:
            break
        }
        textBuffer = ""
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map { String($0).lowercased() }
            ?? name.lowercased()
    }

    private static func statusCode(_ value: String) -> Int? {
        value.split(separator: " ").compactMap { Int($0) }.first
    }
}
