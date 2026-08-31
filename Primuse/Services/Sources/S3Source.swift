import Foundation
import PrimuseKit
import CryptoKit

/// S3-compatible storage source (AWS S3 / MinIO / Cloudflare R2 / Backblaze B2)
/// Uses AWS Signature V4 for authentication — pure Swift, no SDK dependency.
actor S3Source: MusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    private let endpoint: String  // e.g. "s3.amazonaws.com" or "minio.example.com:9000"
    private let port: Int?
    private let region: String
    private let bucket: String
    private let accessKey: String
    private let secretKey: String
    private let useSsl: Bool
    private let alternateTLSValidationHostname: String?
    private let cacheDirectory: URL
    private var clockOffset: TimeInterval

    /// 长生命周期 session, fetchRange / localURL 复用 HTTP keep-alive。
    /// S3 协议天然支持 Range header (GetObject with Range), 不需要签名。
    /// disconnect() 中 finishTasksAndInvalidate(), 避免 session/线程/fd 泄漏。
    private var _directorySession: URLSession?
    private var directorySession: URLSession {
        if let session = _directorySession { return session }
        let session = Self.makeSession(
            alternateTLSValidationHostname: alternateTLSValidationHostname,
            alternateTLSValidationEndpoint: NetworkEndpointIdentity(
                scheme: useSsl ? "https" : "http",
                host: endpoint,
                port: port
            )
        )
        _directorySession = session
        return session
    }
    private var _rangeSession: URLSession?
    private var rangeSession: URLSession {
        if let session = _rangeSession { return session }
        let session = Self.makeSession(
            alternateTLSValidationHostname: alternateTLSValidationHostname,
            alternateTLSValidationEndpoint: NetworkEndpointIdentity(
                scheme: useSsl ? "https" : "http",
                host: endpoint,
                port: port
            )
        )
        _rangeSession = session
        return session
    }

    private static func makeSession(
        alternateTLSValidationHostname: String?,
        alternateTLSValidationEndpoint: NetworkEndpointIdentity?
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: alternateTLSValidationEndpoint
            ),
            delegateQueue: nil
        )
        return session
    }

    init(
        sourceID: String, endpoint: String, port: Int?, region: String,
        bucket: String, accessKey: String, secretKey: String, useSsl: Bool,
        alternateTLSValidationHostname: String? = nil
    ) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.port = port
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.useSsl = useSsl
        self.alternateTLSValidationHostname = alternateTLSValidationHostname
        self.clockOffset = S3ClockSkewPolicy.storedOffset(for: sourceID)

        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_s3_cache/\(sourceID)")
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID))
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        // Test connection by listing root
        _ = try await listFiles(at: "")
    }

    func disconnect() async {
        // 自建 session 必须显式 invalidate, 否则其内部工作队列/连接缓存
        // 在进程退出前不会释放 (connector 反复重建时累积线程/fd)。
        _directorySession?.finishTasksAndInvalidate()
        _directorySession = nil
        _rangeSession?.finishTasksAndInvalidate()
        _rangeSession = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let prefix = path.isEmpty ? "" : (path.hasSuffix("/") ? path : "\(path)/")
        var items: [RemoteFileItem] = []
        // ListObjectsV2 caps a single response at max-keys (≤1000) and signals
        // more pages via IsTruncated / NextContinuationToken. A flat directory
        // with >1000 entries would otherwise return only the first page, and
        // ConnectorScanner treats the missing songs as deleted. Follow the
        // continuation token until the listing is complete.
        var continuationToken: String? = nil
        var seenContinuationTokens: Set<String> = []
        repeat {
            guard var components = URLComponents(url: try bucketURL(), resolvingAgainstBaseURL: false) else {
                throw SourceError.connectionFailed("Invalid S3 URL")
            }
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "max-keys", value: "1000"),
            ]
            if let token = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw SourceError.connectionFailed("Invalid URL") }

            let page = try await loadListPage(url: url, prefix: prefix)
            items.append(contentsOf: page.items)
            if page.isTruncated, let nextToken = page.nextContinuationToken {
                guard seenContinuationTokens.insert(nextToken).inserted else {
                    throw SourceError.connectionFailed(
                        "S3 list response repeated its continuation token"
                    )
                }
                continuationToken = nextToken
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil

        return items
    }

    private func loadListPage(url: URL, prefix: String) async throws -> S3ListPage {
        var completedRetryAttempts = 0

        while true {
            do {
                try Task.checkCancellation()
                let (data, http) = try await performDataRequest(
                    url: url,
                    method: "GET",
                    session: directorySession
                )
                switch http.statusCode {
                case 200:
                    return try parseListResponse(data: data, prefix: prefix)
                case 401, 403:
                    throw SourceError.authenticationFailed
                case 404:
                    throw SourceError.pathNotFound(bucket)
                default:
                    throw RemoteDirectoryHTTPStatusError(
                        service: "S3",
                        statusCode: http.statusCode
                    )
                }
            } catch {
                if OperationCancellationPolicy.isCancellation(error) {
                    resetDirectorySession()
                    throw CancellationError()
                }

                let outcome: RemoteDirectoryListingOutcome = RemoteDirectoryTransportErrorPolicy
                    .isRetryable(error) ? .retryableFailure : .permanentFailure
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    emptyNeedsFreshConfirmation: false
                ) {
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    resetDirectorySession()
                case .accept:
                    assertionFailure("An S3 list error cannot be accepted")
                    throw error
                case .fail:
                    if outcome == .retryableFailure {
                        resetDirectorySession()
                    }
                    throw error
                }
            }
        }
    }

    func localURL(for path: String) async throws -> URL {
        let cacheName = CacheFileNamePolicy.make(path: path)
        let cachedURL = cacheDirectory.appendingPathComponent(cacheName)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let url = try objectURL(for: path)
        let (tempURL, http) = try await performDownloadRequest(url: url, method: "GET", timeout: 300)
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SourceError.fileNotFound(path)
        }
        let handle = try FileHandle(forReadingFrom: tempURL)
        let prefix = try handle.read(upToCount: 64) ?? Data()
        try? handle.close()
        guard !httpMediaResponseLooksLikeErrorBody(http, data: prefix) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SourceError.connectionFailed("S3 download returned a non-audio response")
        }

        try? FileManager.default.removeItem(at: cachedURL)
        try FileManager.default.moveItem(at: tempURL, to: cachedURL)
        return cachedURL
    }

    func writeFile(data: Data, to path: String) async throws {
        guard !path.isEmpty else { throw SourceError.fileNotFound(path) }
        try await uploadData(data, to: path, expectedETag: nil)
        await invalidateMetadataWritebackCache(for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        guard !path.isEmpty else { throw SourceError.fileNotFound(path) }
        let (_, http) = try await performDataRequest(
            url: objectURL(for: path),
            method: "HEAD"
        )
        switch http.statusCode {
        case 200...299:
            guard let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                  let etag = Self.normalizedETag(
                    http.value(forHTTPHeaderField: "ETag")
                  ) else {
                throw EmbeddedMetadataCoordinatedWritebackError.invalidRemoteState
            }
            return EmbeddedMetadataRemoteFileState(
                fileSize: size,
                modifiedDate: Self.httpDate(
                    http.value(forHTTPHeaderField: "Last-Modified")
                ),
                revision: etag
            )
        case 401, 403:
            throw SourceError.authenticationFailed
        case 404:
            throw SourceError.fileNotFound(path)
        default:
            throw SourceError.connectionFailed(
                "S3 object inspection failed: HTTP \(http.statusCode)"
            )
        }
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard let etag = Self.normalizedETag(expected.revision) else {
            throw EmbeddedMetadataCoordinatedWritebackError.invalidRemoteState
        }
        try await uploadFile(localURL, to: path, expectedETag: etag)
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(CacheFileNamePolicy.make(path: path))
        )
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(CacheFileNamePolicy.legacySanitized(path: path))
        )
    }

    /// HTTP Range GET on S3 GetObject。S3 协议规范支持 Range header
    /// (RFC 7233), 不算 signed header 不影响签名。让 CloudPlaybackSource
    /// 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try objectURL(for: path)
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let (data, http) = try await performDataRequest(
            url: url,
            method: "GET",
            rangeHeader: rangeHeader,
            timeout: 60,
            maxBytes: Self.rangeResponseLimit(for: length)
        )
        switch http.statusCode {
        case 206:
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid S3 Content-Range response")
            }
            return data
        case 200:
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("S3 server ignored the byte Range request")
            }
            return data
        default:
            throw SourceError.connectionFailed("S3 range request failed: HTTP \(http.statusCode)")
        }
    }

    /// S3 DeleteObject. Versioned buckets create a delete marker; unversioned
    /// buckets remove the object. In both cases the live key is really gone.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty else { throw SourceError.fileNotFound(path) }
        let (data, http) = try await performDataRequest(url: objectURL(for: path), method: "DELETE")
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw SourceError.connectionFailed("S3 delete failed: HTTP \(http.statusCode) \(detail)")
        }
        let cacheName = CacheFileNamePolicy.make(path: path)
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(cacheName))
        let legacyName = CacheFileNamePolicy.legacySanitized(path: path)
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(legacyName))
        plog("🗑️ S3 object deleted: \(path)")
    }

    private func bucketURL() throws -> URL {
        let scheme = useSsl ? "https" : "http"
        guard var url = NetworkURLBuilder.baseURL(host: endpoint, scheme: scheme, port: port) else {
            throw SourceError.connectionFailed("Invalid S3 endpoint")
        }
        for component in bucket.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    private func objectURL(for path: String) throws -> URL {
        var url = try bucketURL()
        for component in path.split(separator: "/") where component.isEmpty == false {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    while true {
                        let data = handle.readData(ofLength: 64 * 1024)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - S3 Signature V4

    private func performDataRequest(
        url: URL,
        method: String,
        rangeHeader: String? = nil,
        timeout: TimeInterval = 30,
        maxBytes: Int = PlainHTTPClient.defaultMaxBytes,
        session explicitSession: URLSession? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            var request = try signedRequest(url: url, method: method)
            request.timeoutInterval = timeout
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            }

            let (data, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: explicitSession ?? rangeSession,
                maxBytes: maxBytes
            )
            guard let http = response as? HTTPURLResponse else {
                throw SourceError.connectionFailed("Invalid S3 response")
            }
            if attempt == 0, updateClockOffsetIfNeeded(from: http, body: data) {
                continue
            }
            synchronizeClockOffset(from: http)
            return (data, http)
        }
        throw SourceError.connectionFailed("S3 clock correction retry failed")
    }

    private func uploadData(
        _ data: Data,
        to path: String,
        expectedETag: String?
    ) async throws {
        let payloadHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try await performUpload(
            path: path,
            payloadHash: payloadHash,
            expectedETag: expectedETag
        ) { request in
            var request = request
            request.httpBody = data
            return try await TrustedHTTPTransport.data(
                for: request,
                session: self.rangeSession,
                maxBytes: 1024 * 1024
            )
        }
    }

    private func uploadFile(
        _ localURL: URL,
        to path: String,
        expectedETag: String?
    ) async throws {
        let payloadHash = try SHA256FileDigest.hexDigest(at: localURL)
        try await performUpload(
            path: path,
            payloadHash: payloadHash,
            expectedETag: expectedETag
        ) { request in
            if TrustedHTTPTransport.requiresPlainSocket(for: request.url!) {
                var request = request
                request.httpBody = try Data(contentsOf: localURL, options: .mappedIfSafe)
                return try await TrustedHTTPTransport.data(
                    for: request,
                    session: self.rangeSession,
                    maxBytes: 1024 * 1024
                )
            }
            return try await self.rangeSession.upload(for: request, fromFile: localURL)
        }
    }

    private func performUpload(
        path: String,
        payloadHash: String,
        expectedETag: String?,
        operation: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws {
        let url = try objectURL(for: path)
        for attempt in 0..<2 {
            var headers: [String: String] = [:]
            if let expectedETag { headers["If-Match"] = expectedETag }
            var request = try signedRequest(
                url: url,
                method: "PUT",
                payloadHash: payloadHash,
                signedHeaders: headers
            )
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3_600
            let (data, response) = try await operation(request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceError.connectionFailed("Invalid S3 upload response")
            }
            if attempt == 0, updateClockOffsetIfNeeded(from: http, body: data) {
                continue
            }
            synchronizeClockOffset(from: http)
            switch http.statusCode {
            case 200...299:
                return
            case 409, 412:
                throw EmbeddedMetadataWritebackSourceError.conflict
            case 401, 403:
                throw SourceError.authenticationFailed
            default:
                let detail = String(data: data.prefix(4_096), encoding: .utf8) ?? ""
                throw SourceError.connectionFailed(
                    "S3 upload failed: HTTP \(http.statusCode) \(detail)"
                )
            }
        }
        throw SourceError.connectionFailed("S3 clock correction retry failed")
    }

    private func resetDirectorySession() {
        _directorySession?.invalidateAndCancel()
        _directorySession = nil
    }

    private static func rangeResponseLimit(for length: Int64) -> Int {
        let requested = Int(clamping: max(length, 0))
        return requested > Int.max - 64 * 1_024
            ? Int.max
            : max(PlainHTTPClient.defaultMaxBytes, requested + 64 * 1_024)
    }

    private func performDownloadRequest(
        url: URL,
        method: String,
        timeout: TimeInterval
    ) async throws -> (URL, HTTPURLResponse) {
        for attempt in 0..<2 {
            var request = try signedRequest(url: url, method: method)
            request.timeoutInterval = timeout
            let (temporaryURL, response) = try await TrustedHTTPTransport.download(
                for: request,
                session: rangeSession
            )
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw SourceError.connectionFailed("Invalid S3 download response")
            }
            if attempt == 0, updateClockOffsetIfNeeded(from: http, body: nil) {
                try? FileManager.default.removeItem(at: temporaryURL)
                continue
            }
            synchronizeClockOffset(from: http)
            return (temporaryURL, http)
        }
        throw SourceError.connectionFailed("S3 clock correction retry failed")
    }

    private func updateClockOffsetIfNeeded(from response: HTTPURLResponse, body: Data?) -> Bool {
        guard response.statusCode == 400 || response.statusCode == 403,
              let serverDate = response.value(forHTTPHeaderField: "Date") else { return false }

        if let body, !body.isEmpty {
            let text = String(data: body, encoding: .utf8)?.lowercased() ?? ""
            let isClockRelated = text.contains("requesttimetoo")
                || text.contains("requestexpired")
                || text.contains("signaturedoesnotmatch")
            guard isClockRelated else { return false }
        }

        guard let offset = S3ClockSkewPolicy.adjustment(serverDateHeader: serverDate) else {
            return false
        }
        clockOffset = offset
        S3ClockSkewPolicy.store(offset: offset, for: sourceID)
        plog("🕒 S3 clock adjusted by \(offset.finiteInt())s for source \(sourceID)")
        return true
    }

    private func synchronizeClockOffset(from response: HTTPURLResponse) {
        guard (200...299).contains(response.statusCode),
              let serverDate = response.value(forHTTPHeaderField: "Date"),
              let offset = S3ClockSkewPolicy.adjustment(serverDateHeader: serverDate),
              abs(offset - clockOffset) >= 1 else { return }
        clockOffset = offset
        S3ClockSkewPolicy.store(offset: offset, for: sourceID)
    }

    private func signedRequest(
        url: URL,
        method: String,
        payloadHash explicitPayloadHash: String? = nil,
        signedHeaders additionalSignedHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        let now = Date().addingTimeInterval(clockOffset)
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        let hostHeader = Self.hostHeader(for: url, fallback: endpoint)
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        let payloadHash = explicitPayloadHash
            ?? SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        for (name, value) in additionalSignedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // Canonical request — must follow SigV4 byte-for-byte, otherwise the
        // server recomputes a different signature → SignatureDoesNotMatch (403).
        let path = canonicalURI(for: url)
        let query = canonicalQueryString(for: url)
        var canonicalHeaderValues = [
            "host": hostHeader,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
        ]
        for (name, value) in additionalSignedHeaders {
            canonicalHeaderValues[name.lowercased()] = Self.normalizedHeaderValue(value)
        }
        let signedHeaderNames = canonicalHeaderValues.keys.sorted()
        let signedHeaders = signedHeaderNames.joined(separator: ";")
        let canonicalHeaders = signedHeaderNames
            .map { "\($0):\(Self.normalizedHeaderValue(canonicalHeaderValues[$0] ?? ""))\n" }
            .joined()
        let canonicalRequest = "\(method)\n\(path)\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).compactMap { String(format: "%02x", $0) }.joined()

        // String to sign
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(canonicalHash)"

        // Signing key
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        return request
    }

    private nonisolated static func normalizedHeaderValue(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .joined(separator: " ")
    }

    private nonisolated static func normalizedETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func httpDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// SigV4 的 canonical host 必须包含非默认端口，否则 MinIO 等自建端点会
    /// 按实际 Host 头（host:port）重算出不同签名并返回 SignatureDoesNotMatch。
    private static func hostHeader(for url: URL, fallback: String) -> String {
        guard let host = url.host, !host.isEmpty else { return fallback }
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = url.port else { return hostPart }
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        return port == defaultPort ? hostPart : "\(hostPart):\(port)"
    }

    /// SigV4 canonical URI: percent-encode each path segment with the AWS
    /// unreserved set (A-Za-z0-9-._~), keeping `/` as the separator. Uses the
    /// raw (already percent-encoded) path so non-ASCII / space keys match the
    /// bytes actually sent on the wire; `url.path` would decode them and break
    /// the signature.
    private func canonicalURI(for url: URL) -> String {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard rawPath.isEmpty == false else { return "/" }
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            // Decode then re-encode each segment so the result is exactly one
            // layer of AWS-style encoding regardless of how the URL was built.
            let decoded = segment.removingPercentEncoding ?? String(segment)
            return Self.awsURIEncode(decoded)
        }
        let joined = segments.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    /// SigV4 canonical query string: sort params by name (byte order),
    /// AWS-encode both name and value (so `/` → %2F), join `name=value` with `&`.
    private func canonicalQueryString(for url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded = items.map { item -> (String, String) in
            (Self.awsURIEncode(item.name), Self.awsURIEncode(item.value ?? ""))
        }
        return encoded
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// AWS SigV4 percent-encoding: everything except the unreserved set
    /// (A-Za-z0-9, `-`, `.`, `_`, `~`) is %XX-encoded with uppercase hex.
    private static func awsURIEncode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    // MARK: - XML Parsing

    private struct S3ListPage {
        let items: [RemoteFileItem]
        let isTruncated: Bool
        let nextContinuationToken: String?
    }

    private func parseListResponse(data: Data, prefix: String) throws -> S3ListPage {
        let parser = S3ListParser(prefix: prefix)
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldProcessNamespaces = true
        xmlParser.delegate = parser
        let parsed = xmlParser.parse()
        guard parser.isStructurallyValid,
              S3ListResponseValidationPolicy.isValid(
                xmlParsed: parsed,
                sawListBucketResult: parser.sawListBucketResult,
                hasValidIsTruncatedMarker: parser.sawValidIsTruncatedMarker,
                isTruncated: parser.isTruncated,
                hasContinuationToken: parser.nextContinuationToken != nil
              ) else {
            let detail = xmlParser.parserError?.localizedDescription
                ?? "incomplete ListBucketResult"
            throw SourceError.connectionFailed("Invalid S3 list response: \(detail)")
        }
        return S3ListPage(
            items: parser.items,
            isTruncated: parser.isTruncated,
            nextContinuationToken: parser.nextContinuationToken
        )
    }

    // MARK: - Private scan

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let items = try await listFiles(at: path)
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else if let scannable = SidecarHintResolver.scannableItem(
                item,
                index: sidecarIndex
            ) {
                continuation.yield(scannable)
            }
        }
    }
}

// MARK: - S3 XML Response Parser

private class S3ListParser: NSObject, XMLParserDelegate {
    let prefix: String
    var items: [RemoteFileItem] = []
    var isTruncated = false
    var nextContinuationToken: String?
    var sawListBucketResult = false
    var sawValidIsTruncatedMarker = false
    var isStructurallyValid = true

    private var currentElement = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentETag = ""
    private var currentLastModified = ""
    private var currentPrefix = ""
    private var currentScalar = ""
    private var inContents = false
    private var inCommonPrefix = false
    private var depth = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if depth == 0, element == "ListBucketResult" {
            sawListBucketResult = true
        }
        depth += 1
        currentElement = element
        currentScalar = ""
        if element == "Contents" {
            if inContents { isStructurallyValid = false }
            inContents = true
            currentKey = ""
            currentSize = 0
            currentETag = ""
            currentLastModified = ""
        }
        if element == "CommonPrefixes" {
            if inCommonPrefix { isStructurallyValid = false }
            inCommonPrefix = true
            currentPrefix = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inContents {
            if currentElement == "Key" { currentKey += string }
            if currentElement == "Size" { currentScalar += string }
            if currentElement == "ETag" { currentETag += string }
            if currentElement == "LastModified" { currentLastModified += string }
        }
        if inCommonPrefix && currentElement == "Prefix" {
            currentPrefix += string
        }
        // Top-level pagination markers (children of ListBucketResult, not inside
        // Contents/CommonPrefixes) — drive continuation-token paging.
        if !inContents && !inCommonPrefix {
            if currentElement == "IsTruncated" || currentElement == "NextContinuationToken" {
                currentScalar += string
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth = max(0, depth - 1) }
        let scalar = currentScalar.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "Size" { currentSize = Int64(scalar) ?? 0 }
        if element == "IsTruncated" {
            switch scalar.lowercased() {
            case "true":
                isTruncated = true
                sawValidIsTruncatedMarker = true
            case "false":
                isTruncated = false
                sawValidIsTruncatedMarker = true
            default:
                isStructurallyValid = false
            }
        }
        if element == "NextContinuationToken" { nextContinuationToken = scalar.isEmpty ? nil : scalar }
        if element == "Contents" {
            if currentKey.isEmpty {
                isStructurallyValid = false
            } else {
                let name = (currentKey as NSString).lastPathComponent
                let modifiedDate = ISO8601DateFormatter().date(
                    from: currentLastModified.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let etag = currentETag.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(RemoteFileItem(
                    name: name,
                    path: currentKey,
                    isDirectory: false,
                    size: currentSize,
                    modifiedDate: modifiedDate,
                    revision: etag.isEmpty ? nil : etag
                ))
            }
            inContents = false
        }
        if element == "CommonPrefixes" {
            if currentPrefix.isEmpty {
                isStructurallyValid = false
            } else {
                let trimmedPrefix = currentPrefix.hasSuffix("/") ? String(currentPrefix.dropLast()) : currentPrefix
                let name = (trimmedPrefix as NSString).lastPathComponent
                items.append(RemoteFileItem(name: name, path: currentPrefix, isDirectory: true, size: 0, modifiedDate: nil))
            }
            inCommonPrefix = false
        }
    }
}
