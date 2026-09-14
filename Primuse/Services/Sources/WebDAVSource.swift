import CryptoKit
import Foundation
import FilesProvider
import PrimuseKit

enum WebDAVDirectoryListingConfirmationPolicy {
    static func missingPaths(
        previouslyObserved: Set<String>,
        listed: Set<String>
    ) -> Set<String> {
        let listed = Set(listed.map(normalizedPath))
        return Set(previouslyObserved.map(normalizedPath)).subtracting(listed)
    }

    static func acceptsIndependentConfirmation(
        firstMissing: Set<String>,
        secondMissing: Set<String>
    ) -> Bool {
        secondMissing.isEmpty || secondMissing == firstMissing
    }

    private static func normalizedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

actor WebDAVSource: MusicSourceConnector, OpenListSTRMResolvingConnector,
    DestructiveDirectoryListingConfirmingConnector,
    EmbeddedMetadataWritebackAdapter {
    nonisolated let supportsSidecarWriting = true
    let sourceID: String
    private let host: String
    private let port: Int?
    private let useSsl: Bool
    private let basePath: String?
    private let username: String
    private let password: String
    private let alternateTLSValidationHostname: String?
    private let mutationSession: URLSession?
    private var provider: WebDAVFileProvider?
    private var usesTrustedURLSession = false
    private var connectTask: Task<Void, Error>?
    private var didLogWholeResourceMetadataFallback = false
    private var didLogFirstRangeRequest = false
    /// 给整库读取的日志限幅 —— 细节见 DiagnosticLogSampler。
    private var metadataStatusLogSampler = DiagnosticLogSampler(detailLimit: 20)
    private var metadataRedirectLogSampler = DiagnosticLogSampler(detailLimit: 10)
    private var metadataSuccessLogSampler = DiagnosticLogSampler(detailLimit: 3)
    private static let diagnosticBodyByteLimit = 4096
    private var metadataSuffixRangeCapabilityCache = MetadataSuffixRangeCapabilityCache()
    private var completeMetadataFallbackTasks: [String: Task<URL, Error>] = [:]
    private let cacheDirectory: URL

    /// 长生命周期 session, 让 fetchRange 复用 HTTP keep-alive 连接,
    /// 避免每次 chunk fetch 都重新 SSL handshake。
    /// 8 路并发: 配合 CloudPlaybackSource 小文件全 prefetch 时多 chunk 并发。
    private var directorySession: URLSession?
    private var rangeSession: URLSession?
    private var redirectedMediaSession: URLSession?

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        useSsl: Bool,
        basePath: String? = nil,
        username: String,
        password: String,
        alternateTLSValidationHostname: String? = nil,
        mutationSession: URLSession? = nil
    ) {
        self.sourceID = sourceID
        self.mutationSession = mutationSession
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.basePath = basePath
        self.username = username
        self.password = password
        self.alternateTLSValidationHostname = alternateTLSValidationHostname

        // Per-source cache dir avoids file-name collisions when two WebDAV sources
        // happen to expose files with the same relative path.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_webdav_cache")
            .appendingPathComponent(sourceID)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID))
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
        self.directorySession = Self.makeRangeSession(
            host: host,
            port: port,
            useSsl: useSsl,
            username: username,
            password: password,
            alternateTLSValidationHostname: alternateTLSValidationHostname
        )
        self.rangeSession = Self.makeRangeSession(
            host: host,
            port: port,
            useSsl: useSsl,
            username: username,
            password: password,
            alternateTLSValidationHostname: alternateTLSValidationHostname
        )
        self.redirectedMediaSession = Self.makeRedirectedMediaSession()
    }

    private static func makeRangeSession(
        host: String,
        port: Int?,
        useSsl: Bool,
        username: String,
        password: String,
        alternateTLSValidationHostname: String?
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
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: NetworkEndpointIdentity(
                    scheme: useSsl ? "https" : "http",
                    host: host,
                    port: port
                )
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
        ensureTransportSessions()
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
            provider.session.invalidateAndCancel()
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
                resetDirectorySession()
            }
            throw error
        }
    }


    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        completeMetadataFallbackTasks.values.forEach { $0.cancel() }
        completeMetadataFallbackTasks.removeAll()
        provider?.session.invalidateAndCancel()
        provider = nil
        usesTrustedURLSession = false
        directorySession?.invalidateAndCancel()
        directorySession = nil
        rangeSession?.invalidateAndCancel()
        rangeSession = nil
        redirectedMediaSession?.invalidateAndCancel()
        redirectedMediaSession = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard provider != nil || usesTrustedURLSession else {
            throw SourceError.connectionFailed("Not connected")
        }

        var completedRetryAttempts = 0
        while true {
            do {
                return try await listFilesUsingTrustedTransport(at: path)
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
                    assertionFailure("A directory error cannot be accepted")
                    throw error
                case .fail:
                    if outcome == .retryableFailure {
                        resetDirectorySession()
                    }
                    if let status = error as? RemoteDirectoryHTTPStatusError {
                        throw SourceError.connectionFailed(status.localizedDescription)
                    }
                    throw error
                }
            }
        }
    }

    func listFiles(
        at path: String,
        confirmingPreviouslyObservedPaths paths: Set<String>
    ) async throws -> [RemoteFileItem] {
        let first = try await listFiles(at: path)
        let firstMissing = WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: paths,
            listed: Set(first.map(\.path))
        )
        guard !firstMissing.isEmpty else { return first }

        // A fresh transport prevents one truncated keep-alive response from
        // becoming an authoritative deletion. Real removals are accepted when
        // both independent directory snapshots omit the same paths.
        resetDirectorySession()
        let second = try await listFilesUsingTrustedTransport(at: path)
        try Task.checkCancellation()
        let secondMissing = WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: paths,
            listed: Set(second.map(\.path))
        )
        guard WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: secondMissing
        ) else {
            throw SourceError.connectionFailed(
                "WebDAV directory changed while confirming removed files"
            )
        }
        return second
    }

    private func requireTransportSession(_ session: URLSession?) throws -> URLSession {
        try Task.checkCancellation()
        // Disconnect can run while a read awaits a redirect or retry. Late
        // requests must stop instead of unwrapping a cleared session.
        guard let session else { throw CancellationError() }
        return session
    }

    private func ensureTransportSessions() {
        if directorySession == nil {
            directorySession = Self.makeRangeSession(
                host: host,
                port: port,
                useSsl: useSsl,
                username: username,
                password: password,
                alternateTLSValidationHostname: alternateTLSValidationHostname
            )
        }
        if rangeSession == nil {
            rangeSession = Self.makeRangeSession(
                host: host,
                port: port,
                useSsl: useSsl,
                username: username,
                password: password,
                alternateTLSValidationHostname: alternateTLSValidationHostname
            )
        }
        if redirectedMediaSession == nil {
            redirectedMediaSession = Self.makeRedirectedMediaSession()
        }
    }

    private func resetDirectorySession() {
        guard directorySession != nil else { return }
        directorySession?.invalidateAndCancel()
        directorySession = Self.makeRangeSession(
            host: host,
            port: port,
            useSsl: useSsl,
            username: username,
            password: password,
            alternateTLSValidationHostname: alternateTLSValidationHostname
        )
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
        let session = try requireTransportSession(rangeSession)
        let request = try makeWebDAVRequest(url: fileURL(for: path), method: "DELETE")
        // Use one response contract for HTTP and HTTPS. The provider callback
        // otherwise treats accepted/incomplete 202 and 207 replies as success.
        let (_, response) = try await TrustedHTTPTransport.data(for: request, session: mutationSession ?? session)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV delete response")
        }
        switch http.statusCode {
        case 200, 204: break
        case 401: throw SourceError.authenticationFailed
        case 403: throw SourceFileMutationError.permissionDenied
        case 404, 410: throw SourceError.fileNotFound(path)
        case 405: throw SourceFileMutationError.readOnly
        default:
            throw RemoteMediaHTTPError(service: "WebDAV", statusCode: http.statusCode)
        }
        invalidateLocalCache(for: path)
    }

    func writeFile(data: Data, to path: String) async throws {
        let current = try await resourceMetadata(at: path)
        var request = try makeWebDAVRequest(url: fileURL(for: path), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let current {
            guard let etag = WebDAVWritebackPolicy.strongETag(current.etag) else {
                throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
            }
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        let response = try await send(data: data, for: request)
        try validateMutationResponse(response, operation: "PUT")

        guard let written = try await resourceMetadata(at: path),
              let writtenETag = WebDAVWritebackPolicy.strongETag(written.etag) else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let fetched = try await fetchWholeResource(
            at: path,
            expectedETag: writtenETag,
            maximumBytes: max(PlainHTTPClient.defaultMaxBytes, data.count + 64 * 1024)
        )
        guard Self.sha256(fetched) == Self.sha256(data) else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        invalidateLocalCache(for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        guard let metadata = try await resourceMetadata(at: path),
              let eTag = WebDAVWritebackPolicy.strongETag(metadata.etag),
              let size = metadata.contentLength,
              size >= 0 else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        return EmbeddedMetadataRemoteFileState(
            fileSize: size,
            modifiedDate: Self.webDAVDate(metadata.lastModified),
            revision: eTag
        )
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard let originalETag = WebDAVWritebackPolicy.strongETag(expected.revision) else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let temporaryPath = Self.temporaryWritebackPath(for: path)
        do {
            var put = try makeWebDAVRequest(url: fileURL(for: temporaryPath), method: "PUT")
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            put.setValue("*", forHTTPHeaderField: "If-None-Match")
            let putResponse = try await send(fileAt: localURL, for: put)
            try validateMutationResponse(putResponse, operation: "PUT")

            let destinationURL = try fileURL(for: path)
            var move = try makeWebDAVRequest(url: fileURL(for: temporaryPath), method: "MOVE")
            move.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
            move.setValue("T", forHTTPHeaderField: "Overwrite")
            guard let destinationCondition = WebDAVWritebackPolicy.taggedDestinationCondition(
                destinationURL: destinationURL,
                strongETag: originalETag
            ) else {
                throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
            }
            move.setValue(destinationCondition, forHTTPHeaderField: "If")
            let (_, moveResponse) = try await TrustedHTTPTransport.data(
                for: move,
                session: try requireTransportSession(rangeSession),
                maxBytes: 1024 * 1024
            )
            try validateMutationResponse(moveResponse, operation: "MOVE")
        } catch {
            try? await deleteFile(at: temporaryPath)
            throw error
        }
        invalidateLocalCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        invalidateLocalCache(for: path)
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

    func fetchMetadataRange(
        path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let request = try makeRangeRequest(path: path, rangeHeader: rangeHeader)
        let startedAt = Date()
        let data = try await fetchMetadataRange(
            request: request,
            mediaPath: path,
            offset: offset,
            length: length,
            intent: intent
        )
        logMetadataReadSuccess(
            url: request.url,
            rangeHeader: rangeHeader,
            byteCount: data.count,
            path: path,
            startedAt: startedAt
        )
        return data
    }

    /// 只记前几条成功的读取。整批失败的日志里最难回答的问题是"这个源到底
    /// 有没有成功过一次" —— 有这几行才有对照, 没有就说明一首都没读下来。
    private func logMetadataReadSuccess(
        url: URL?,
        rangeHeader: String,
        byteCount: Int,
        path: String,
        startedAt: Date
    ) {
        let endpoint = metadataEndpointKey(for: url) ?? "?"
        let decision = metadataSuccessLogSampler.record(key: "ok#\(endpoint)")
        guard decision.detailed else { return }
        plog(String(
            format: "🌐 WebDAV metadata ok endpoint=%@ elapsed=%.2fs range=%@ bytes=%d path=%@",
            endpoint,
            Date().timeIntervalSince(startedAt),
            rangeHeader,
            byteCount,
            path
        ))
    }

    private func fetchMetadataRange(
        request: URLRequest,
        mediaPath path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        let requestStartedAt = Date()
        if offset < 0 {
            return try await fetchMetadataSuffix(
                request: request,
                mediaPath: path,
                offset: offset,
                length: length,
                intent: intent
            )
        }
        if let url = request.url, TrustedHTTPTransport.requiresPlainSocket(for: url) {
            let requestedBodyBytes = Int(clamping: max(length, 0))
            let maximumRangedBodyBytes = requestedBodyBytes > Int.max - 64 * 1024
                ? Int.max
                : requestedBodyBytes + 64 * 1024
            let wholeResponsePrefixLimit = WholeResourceMetadataRangePolicy
                .wholeResponsePrefixLimit(
                    requestedOffset: offset,
                    requestedLength: length
                )
            let (temporaryURL, response) = try await TrustedHTTPTransport.download(
                for: request,
                session: try requireTransportSession(rangeSession),
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
                    throw MetadataRangeReadError.invalidRangeResponse
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
                throw metadataStatusError(
                    http,
                    path: path,
                    request: request,
                    bodyPrefix: responsePrefix,
                    startedAt: requestStartedAt
                )
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
                throw MetadataRangeReadError.invalidRangeResponse
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
            throw metadataStatusError(
                http,
                path: path,
                request: request,
                bodyPrefix: await errorBodyPrefix(bytes),
                startedAt: requestStartedAt
            )
        }
    }

    private func fetchMetadataSuffix(
        request: URLRequest,
        mediaPath path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        let requestStartedAt = Date()
        if let cachedURL = cachedCompleteMetadataFallbackURL(for: path),
           intent == .explicitSingleFileCompleteFallback {
            return try boundedMetadataSlice(cachedURL, offset: offset, length: length)
        }

        if metadataSuffixRangeIsKnownUnsupported(for: request.url) {
            switch intent {
            case .bulkBounded:
                throw MetadataRangeReadError.suffixRangeUnsupported
            case .explicitSingleFileCompleteFallback:
                let completeURL = try await completeMetadataFallbackURL(
                    request: request,
                    mediaPath: path
                )
                return try boundedMetadataSlice(completeURL, offset: offset, length: length)
            }
        }

        let requestedBodyBytes = Int(clamping: max(length, 0))
        let maximumRangedBodyBytes = requestedBodyBytes > Int.max - 64 * 1024
            ? Int.max
            : requestedBodyBytes + 64 * 1024
        let (temporaryURL, response) = try await downloadFollowingMediaRedirects(
            for: request,
            maximumBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: 0
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV metadata response")
        }
        switch http.statusCode {
        case 206:
            let bodyLength = try temporaryResponseBodyLength(at: temporaryURL)
            let responsePrefix = try boundedMetadataSlice(
                temporaryURL,
                offset: 0,
                length: min(bodyLength, 4 * 1024)
            )
            try rejectNonMediaResponseIfNeeded(http, data: responsePrefix, path: path)
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: Int(clamping: bodyLength),
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw MetadataRangeReadError.invalidRangeResponse
            }
            return try boundedMetadataSlice(temporaryURL, offset: 0, length: length)
        case 200:
            rememberUnsupportedMetadataSuffixRange(
                requestedURL: request.url,
                responseURL: response.url
            )
            switch WholeResourceMetadataRangePolicy.responseDisposition(
                requestedOffset: offset,
                intent: intent
            ) {
            case .consumeBoundedPrefix:
                assertionFailure("A suffix request cannot consume a response prefix")
                throw MetadataRangeReadError.suffixRangeUnsupported
            case .rejectSuffixWithoutConsuming:
                throw MetadataRangeReadError.suffixRangeUnsupported
            case .useCompleteFileFallback:
                let completeURL = try await completeMetadataFallbackURL(
                    request: request,
                    mediaPath: path
                )
                return try boundedMetadataSlice(completeURL, offset: offset, length: length)
            }
        default:
            throw metadataStatusError(
                http,
                path: path,
                request: request,
                bodyPrefix: try? boundedMetadataSlice(
                    temporaryURL,
                    offset: 0,
                    length: Int64(Self.diagnosticBodyByteLimit)
                ),
                startedAt: requestStartedAt
            )
        }
    }

    private func metadataSuffixRangeIsKnownUnsupported(for url: URL?) -> Bool {
        metadataSuffixRangeCapabilityCache.isUnsupported(
            endpointKey: metadataEndpointKey(for: url)
        )
    }

    private func rememberUnsupportedMetadataSuffixRange(
        requestedURL: URL?,
        responseURL: URL?
    ) {
        metadataSuffixRangeCapabilityCache.recordUnsupported(
            requestedEndpointKey: metadataEndpointKey(for: requestedURL),
            finalEndpointKey: metadataEndpointKey(for: responseURL)
        )
        if !didLogWholeResourceMetadataFallback {
            didLogWholeResourceMetadataFallback = true
            plog("WebDAV metadata fallback: endpoint ignored a suffix Range; bulk reads will stop before consuming the response body")
        }
    }

    private func metadataEndpointKey(for url: URL?) -> String? {
        guard let url, let endpoint = NetworkEndpointIdentity(url: url) else { return nil }
        return endpoint.key
    }

    /// 带上真正回这个状态的主机。挂载代理(alist/OpenList 之类)自己报的 5xx 和
    /// 跟随 302 之后由对象存储报的 5xx, 原本在界面上分不出来 —— 而这两端要查的
    /// 东西完全不同。
    private func metadataStatusError(
        _ response: HTTPURLResponse,
        path: String,
        request: URLRequest?,
        bodyPrefix: Data?,
        startedAt: Date? = nil
    ) -> RemoteMetadataHTTPStatusError {
        let responseEndpoint = response.url.flatMap { NetworkEndpointIdentity(url: $0) }
        let sourceEndpoint = (try? serverURL()).flatMap { NetworkEndpointIdentity(url: $0) }
        let error = RemoteMetadataHTTPStatusError(
            service: "WebDAV",
            statusCode: response.statusCode,
            origin: Self.originDescription(for: response.url),
            followedRedirect: responseEndpoint != nil
                && sourceEndpoint != nil
                && responseEndpoint != sourceEndpoint
        )
        logMetadataStatusFailure(
            response,
            error: error,
            path: path,
            request: request,
            bodyPrefix: bodyPrefix,
            startedAt: startedAt
        )
        return error
    }

    /// 导出的日志要能直接回答"这个状态码是谁回的、它说了什么"。挂载代理会把
    /// 后端的真实原因写在响应体里(alist 之类回的是一小段 JSON), 而那段 body
    /// 原本是被直接丢掉的 —— 界面上只剩一个光秃秃的状态码。
    private func logMetadataStatusFailure(
        _ response: HTTPURLResponse,
        error: RemoteMetadataHTTPStatusError,
        path: String,
        request: URLRequest?,
        bodyPrefix: Data?,
        startedAt: Date?
    ) {
        let origin = error.origin ?? "?"
        let decision = metadataStatusLogSampler.record(
            key: "status#\(origin)#\(response.statusCode)"
        )
        guard decision.detailed else {
            if decision.summarize {
                plog("🌐 WebDAV metadata HTTP \(response.statusCode) origin=\(origin) x\(decision.count) (details suppressed)")
            }
            return
        }
        var fields = [
            "🌐 WebDAV metadata HTTP \(response.statusCode)",
            "origin=\(origin)",
            "redirected=\(error.followedRedirect ? "yes" : "no")",
        ]
        if let startedAt {
            fields.append(String(format: "elapsed=%.2fs", Date().timeIntervalSince(startedAt)))
        }
        if let range = request?.value(forHTTPHeaderField: "Range") {
            fields.append("range=\(range)")
        }
        fields.append("path=\(path)")
        for header in ["Content-Type", "Content-Length", "Content-Range", "Server", "Retry-After"] {
            guard let value = response.value(forHTTPHeaderField: header) else { continue }
            fields.append("\(header.lowercased())=\(value)")
        }
        if let location = response.value(forHTTPHeaderField: "Location") {
            let destination = URL(string: location, relativeTo: response.url)?.absoluteURL
            fields.append("location=\(Self.redactedURLDescription(destination))")
        }
        if let bodyPrefix, !bodyPrefix.isEmpty {
            fields.append("body=\(Self.printableBodyPrefix(bodyPrefix))")
        }
        plog(fields.joined(separator: " "))
    }

    /// 302 到对象存储/CDN 是这条链路最容易出问题的一跳: 之后的失败由另一台
    /// 机器给出, 而原先的日志里连"跳过这一跳"这件事都看不到。
    private func logMediaRedirect(
        from request: URLRequest,
        response: HTTPURLResponse,
        redirected: URLRequest?
    ) {
        guard (300...399).contains(response.statusCode) else { return }
        let destination = response.value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: response.url ?? request.url)?.absoluteURL }
        let destinationKey = destination.flatMap { NetworkEndpointIdentity(url: $0)?.key } ?? "?"
        let decision = metadataRedirectLogSampler.record(key: "redirect#\(destinationKey)")
        guard decision.detailed else {
            if decision.summarize {
                plog("🌐 WebDAV redirect \(response.statusCode) → \(destinationKey) x\(decision.count) (details suppressed)")
            }
            return
        }
        var line = "🌐 WebDAV redirect \(response.statusCode)"
        line += " from=\(Self.originDescription(for: request.url) ?? "?")"
        line += " to=\(Self.redactedURLDescription(destination))"
        if let followed = redirected?.url {
            line += " followed=yes"
            let requestedScheme = destination?.scheme?.lowercased()
            let followedScheme = followed.scheme?.lowercased()
            if let requestedScheme, let followedScheme, requestedScheme != followedScheme {
                line += " scheme=\(requestedScheme)→\(followedScheme)"
            }
        } else {
            line += " followed=no (redirect policy rejected it)"
        }
        plog(line)
    }

    /// 错误响应体一般只有几百字节。读一小段留给日志, 读失败就算了 —— 诊断
    /// 信息不值得盖过真正的错误。
    private func errorBodyPrefix(_ bytes: URLSession.AsyncBytes) async -> Data {
        var prefix = Data()
        prefix.reserveCapacity(Self.diagnosticBodyByteLimit)
        do {
            for try await byte in bytes {
                prefix.append(byte)
                if prefix.count >= Self.diagnosticBodyByteLimit { break }
            }
        } catch {
            // 读不到就少一条线索, 不改变结论。
        }
        return prefix
    }

    /// 错误响应体往往是一小段 JSON 或一整页 HTML。折成一行、截断, 并且不让
    /// 二进制内容进日志。
    private static func printableBodyPrefix(_ data: Data, limit: Int = 400) -> String {
        guard !data.prefix(64).contains(0) else { return "<binary \(data.count) bytes>" }
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "<empty>" }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// 重定向目标常常是一条带签名的临时直链。日志要的是"去了哪台机器、哪条
    /// 路径", 签名和令牌不必跟着进日志。
    private static func redactedURLDescription(_ url: URL?) -> String {
        guard let url else { return "?" }
        var description = ""
        if let scheme = url.scheme { description += "\(scheme)://" }
        description += originDescription(for: url) ?? "?"
        description += url.path
        if let query = url.query, !query.isEmpty {
            description += "?<\(query.split(separator: "&").count) params redacted>"
        }
        return description
    }

    /// host[:端口], 默认端口省掉 —— 这行是给人看的, 不参与任何判断。
    private static func originDescription(for url: URL?) -> String? {
        guard let url, let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? "http"
        guard let port = url.port,
              port != NetworkEndpointIdentity.defaultPort(for: scheme) else {
            return host
        }
        return "\(host):\(port)"
    }

    private func cachedCompleteMetadataFallbackURL(for path: String) -> URL? {
        let url = completeMetadataFallbackCacheURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func completeMetadataFallbackCacheURL(for path: String) -> URL {
        // Reuse the connector's canonical complete-file cache. An explicit
        // reread may follow a suffix probe with `localURL(for:)`; sharing the
        // destination guarantees that path does not download the same file a
        // second time during the complete metadata parse.
        cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
    }

    private func completeMetadataFallbackURL(
        request: URLRequest,
        mediaPath path: String
    ) async throws -> URL {
        if let cachedURL = cachedCompleteMetadataFallbackURL(for: path) {
            return cachedURL
        }
        if let task = completeMetadataFallbackTasks[path] {
            return try await awaitCompleteMetadataFallbackTask(task)
        }

        var completeRequest = request
        completeRequest.setValue(nil, forHTTPHeaderField: "Range")
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.downloadCompleteMetadataFallback(
                request: completeRequest,
                mediaPath: path
            )
        }
        completeMetadataFallbackTasks[path] = task
        do {
            let url = try await awaitCompleteMetadataFallbackTask(task)
            completeMetadataFallbackTasks.removeValue(forKey: path)
            return url
        } catch {
            completeMetadataFallbackTasks.removeValue(forKey: path)
            throw error
        }
    }

    private func awaitCompleteMetadataFallbackTask(
        _ task: Task<URL, Error>
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func downloadCompleteMetadataFallback(
        request: URLRequest,
        mediaPath path: String
    ) async throws -> URL {
        let (downloadedURL, response) = try await downloadFollowingMediaRedirects(for: request)
        var shouldRemoveDownload = true
        defer {
            if shouldRemoveDownload {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
        }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            if let status = (response as? HTTPURLResponse)?.statusCode,
               status == 401 || status == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed(
                "WebDAV complete metadata fallback failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        let bodyLength = try temporaryResponseBodyLength(at: downloadedURL)
        let responsePrefix = try boundedMetadataSlice(
            downloadedURL,
            offset: 0,
            length: min(bodyLength, 4 * 1024)
        )
        try rejectNonMediaResponseIfNeeded(http, data: responsePrefix, path: path)

        let cacheURL = completeMetadataFallbackCacheURL(for: path)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: cacheURL)
            shouldRemoveDownload = false
            return cacheURL
        } catch {
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                return cacheURL
            }
            throw error
        }
    }

    private func dataFollowingMediaRedirects(
        for request: URLRequest,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            let initial = try await TrustedHTTPTransport.data(
                for: request,
                session: try requireTransportSession(rangeSession),
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
                    session: try requireTransportSession(redirectedMediaSession),
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
        for request: URLRequest,
        maximumBytes: Int? = nil,
        wholeResponsePrefixLimit: Int? = nil
    ) async throws -> (URL, URLResponse) {
        for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            let initial = try await TrustedHTTPTransport.download(
                for: request,
                session: try requireTransportSession(rangeSession),
                maximumRangedBodyBytes: maximumBytes,
                wholeResponsePrefixLimit: wholeResponsePrefixLimit
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
                    session: try requireTransportSession(redirectedMediaSession),
                    maximumRangedBodyBytes: maximumBytes,
                    wholeResponsePrefixLimit: wholeResponsePrefixLimit
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
            let initial = try await requireTransportSession(rangeSession).bytes(for: request)
            guard let redirected = redirectedMediaRequest(
                from: request,
                response: initial.1
            ) else {
                return initial
            }
            do {
                let result = try await requireTransportSession(redirectedMediaSession).bytes(for: redirected)
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
        let redirected = HTTPMediaRedirectRequestPolicy.redirectedRequest(
            from: request,
            response: http
        )
        logMediaRedirect(from: request, response: http, redirected: redirected)
        return redirected
    }

    private func makeRangeRequest(path: String, rangeHeader: String) throws -> URLRequest {
        try makeRangeRequest(url: fileURL(for: path), rangeHeader: rangeHeader)
    }

    private func makeRangeRequest(url: URL, rangeHeader: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !username.isEmpty || !password.isEmpty {
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        logFirstRangeRequestIfNeeded(url: url, rangeHeader: rangeHeader)
        return request
    }

    /// 排查这条链路第一步是"客户端到底发了什么"。每个连接实例记一次就够 ——
    /// 后面每一首歌的请求只有路径和 Range 在变。
    private func logFirstRangeRequestIfNeeded(url: URL, rangeHeader: String) {
        guard !didLogFirstRangeRequest else { return }
        didLogFirstRangeRequest = true
        let credentials = username.isEmpty && password.isEmpty ? "none" : "basic"
        plog("🌐 WebDAV range request endpoint=\(metadataEndpointKey(for: url) ?? "?") range=\(rangeHeader) accept-encoding=identity auth=\(credentials)")
    }

    func validateStrictRangeResponse(
        _ response: URLResponse,
        data: Data,
        path: String,
        offset: Int64,
        length: Int64
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV range response")
        }
        switch http.statusCode {
        case 206:
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
            try rejectNonMediaResponseIfNeeded(http, data: data, path: path)
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("WebDAV server ignored the byte Range request")
            }
            return data
        default:
            throw RemoteMediaHTTPError(
                service: "WebDAV",
                statusCode: http.statusCode,
                retryAfter: RemoteMediaHTTPError.retryDelay(from: http)
            )
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
            let decision = metadataStatusLogSampler.record(
                key: "non-media#\(metadataEndpointKey(for: http.url) ?? "?")"
            )
            if decision.detailed {
                plog("🌐 WebDAV non-media body HTTP \(http.statusCode) origin=\(Self.originDescription(for: http.url) ?? "?") type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?") path=\(path) body=\(Self.printableBodyPrefix(data))")
            } else if decision.summarize {
                plog("🌐 WebDAV non-media body HTTP \(http.statusCode) x\(decision.count) (details suppressed)")
            }
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
                <D:getetag/>
              </D:prop>
            </D:propfind>
            """.utf8
        )
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: try requireTransportSession(directorySession),
            maxBytes: 16 * 1024 * 1024
        )
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV directory response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.authenticationFailed
        }
        if http.statusCode == 404 {
            throw SourceError.pathNotFound(path)
        }
        guard http.statusCode == 207 || (200...299).contains(http.statusCode) else {
            throw RemoteDirectoryHTTPStatusError(
                service: "WebDAV",
                statusCode: http.statusCode
            )
        }

        let entries = try WebDAVMultistatusParser.parse(data)
        guard let currentSourcePath = RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: path) else {
            throw SourceError.connectionFailed("Invalid WebDAV directory path")
        }

        let resolvedEntries = entries.compactMap { entry -> (WebDAVMultistatusEntry, String)? in
            guard let sourcePath = sourcePath(forWebDAVHref: entry.href, baseURL: baseURL) else {
                return nil
            }
            return (entry, sourcePath)
        }
        guard resolvedEntries.contains(where: { $0.1 == currentSourcePath }) else {
            throw SourceError.connectionFailed(
                "WebDAV directory response did not describe the requested resource"
            )
        }

        let items = resolvedEntries.compactMap { resolved -> RemoteFileItem? in
            let (entry, sourcePath) = resolved
            guard sourcePath != currentSourcePath else { return nil }
            let fallbackName = (sourcePath as NSString).lastPathComponent
            let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (name?.isEmpty == false ? name : nil) ?? fallbackName
            guard !resolvedName.isEmpty, !resolvedName.hasPrefix(".") else { return nil }
            return RemoteFileItem(
                name: resolvedName,
                path: sourcePath,
                isDirectory: entry.isDirectory,
                size: entry.contentLength ?? -1,
                modifiedDate: Self.webDAVDate(entry.lastModified),
                revision: entry.etag
            )
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

    private func resourceMetadata(at path: String) async throws -> WebDAVMultistatusEntry? {
        let requestStartedAt = Date()
        let baseURL = try serverURL()
        var request = try makeWebDAVRequest(url: fileURL(for: path), method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
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
                <D:getetag/>
              </D:prop>
            </D:propfind>
            """.utf8
        )
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: try requireTransportSession(rangeSession),
            maxBytes: 1024 * 1024
        )
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddedMetadataWritebackSourceError.invalidResponse
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.authenticationFailed
        }
        guard http.statusCode == 207 || (200...299).contains(http.statusCode) else {
            throw metadataStatusError(
                http,
                path: path,
                request: request,
                bodyPrefix: data,
                startedAt: requestStartedAt
            )
        }
        guard let target = RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: path) else {
            throw EmbeddedMetadataWritebackSourceError.invalidResponse
        }
        return try WebDAVMultistatusParser.parse(data).first { entry in
            guard let sourcePath = sourcePath(forWebDAVHref: entry.href, baseURL: baseURL) else {
                return false
            }
            return sourcePath == target
        }
    }

    private func materializeCurrentResource(
        at path: String,
        expectedETag: String
    ) async throws -> URL {
        var request = try makeWebDAVRequest(url: fileURL(for: path), method: "GET")
        request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        let (downloadURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: try requireTransportSession(rangeSession)
        )
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw EmbeddedMetadataWritebackSourceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: downloadURL)
            if http.statusCode == 412 { throw EmbeddedMetadataWritebackSourceError.conflict }
            if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authenticationFailed }
            throw SourceError.connectionFailed("WebDAV download failed: HTTP \(http.statusCode)")
        }

        let fileExtension = (path as NSString).pathExtension
        let localURL = cacheDirectory.appendingPathComponent(
            "writeback-\(UUID().uuidString)\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
        )
        do {
            try FileManager.default.moveItem(at: downloadURL, to: localURL)
            return localURL
        } catch {
            try? FileManager.default.removeItem(at: downloadURL)
            throw error
        }
    }

    private func fetchWholeResource(
        at path: String,
        expectedETag: String?,
        maximumBytes: Int
    ) async throws -> Data {
        var request = try makeWebDAVRequest(url: fileURL(for: path), method: "GET")
        if let expectedETag {
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        }
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: try requireTransportSession(rangeSession),
            maxBytes: maximumBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddedMetadataWritebackSourceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 412 { throw EmbeddedMetadataWritebackSourceError.conflict }
            if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authenticationFailed }
            throw SourceError.connectionFailed("WebDAV readback failed: HTTP \(http.statusCode)")
        }
        return data
    }

    private func send(data: Data, for request: URLRequest) async throws -> URLResponse {
        if let url = request.url, TrustedHTTPTransport.requiresPlainSocket(for: url) {
            var request = request
            request.httpBody = data
            return try await TrustedHTTPTransport.data(
                for: request,
                session: try requireTransportSession(rangeSession),
                maxBytes: 1024 * 1024
            ).1
        }
        return try await requireTransportSession(rangeSession).upload(for: request, from: data).1
    }

    private func send(fileAt localURL: URL, for request: URLRequest) async throws -> URLResponse {
        if let url = request.url, TrustedHTTPTransport.requiresPlainSocket(for: url) {
            return try await send(data: Data(contentsOf: localURL), for: request)
        }
        return try await requireTransportSession(rangeSession).upload(for: request, fromFile: localURL).1
    }

    private func validateMutationResponse(_ response: URLResponse, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddedMetadataWritebackSourceError.invalidResponse
        }
        if http.statusCode == 412 || http.statusCode == 409 || http.statusCode == 423 {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("WebDAV \(operation) failed: HTTP \(http.statusCode)")
        }
    }

    private static func temporaryWritebackPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let temporaryName = ".\(fileName).primuse-writeback-\(UUID().uuidString)"
        return (directory as NSString).appendingPathComponent(temporaryName)
    }

    private func invalidateLocalCache(for path: String) {
        completeMetadataFallbackTasks.removeValue(forKey: path)?.cancel()
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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

    func localOpenListSTRMURL(for reference: String) async throws -> URL {
        guard let remoteURL = try openListSTRMURL(for: reference) else {
            throw SourceError.fileNotFound(reference)
        }

        let baseName = CacheFileNamePolicy.make(
            path: remoteURL.absoluteString,
            preferredExtension: remoteURL.pathExtension
        )
        let localURL = cacheDirectory.appendingPathComponent(baseName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        let temporaryTarget = cacheDirectory.appendingPathComponent(
            "\(baseName).part-\(UUID().uuidString)"
        )
        let request = try makeWebDAVRequest(url: remoteURL, method: "GET")
        let (downloadedURL, response) = try await downloadFollowingMediaRedirects(
            for: request
        )
        do {
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                if let status = (response as? HTTPURLResponse)?.statusCode,
                   status == 401 || status == 403 {
                    throw SourceError.authenticationFailed
                }
                throw SourceError.connectionFailed(
                    "OpenList STRM download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
            }
            try FileManager.default.moveItem(at: downloadedURL, to: temporaryTarget)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: temporaryTarget)
            } else {
                try FileManager.default.moveItem(at: temporaryTarget, to: localURL)
            }
            return localURL
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            try? FileManager.default.removeItem(at: temporaryTarget)
            throw error
        }
    }

    func downloadBoundedOpenListSTRM(
        for reference: String,
        maximumBytes: Int64
    ) async throws -> URL {
        guard maximumBytes > 0,
              let remoteURL = try openListSTRMURL(for: reference) else {
            throw SourceError.fileNotFound(reference)
        }
        let request = try makeWebDAVRequest(url: remoteURL, method: "GET")
        let (downloadedURL, response) = try await downloadFollowingMediaRedirects(
            for: request,
            maximumBytes: Int(clamping: maximumBytes)
        )
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            if let status = (response as? HTTPURLResponse)?.statusCode,
               status == 401 || status == 403 {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed(
                "OpenList STRM download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        return downloadedURL
    }

    func fetchOpenListSTRMMetadataRange(
        for reference: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        guard let remoteURL = try openListSTRMURL(for: reference) else {
            throw SourceError.fileNotFound(reference)
        }
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let request = try makeRangeRequest(url: remoteURL, rangeHeader: rangeHeader)
        return try await fetchMetadataRange(
            request: request,
            mediaPath: reference,
            offset: offset,
            length: length,
            intent: intent
        )
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
    let etag: String?
    let isDirectory: Bool
}

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct Properties {
        var displayName: String?
        var contentLength: Int64?
        var lastModified: String?
        var etag: String?
        var isDirectory = false

        mutating func merge(_ other: Self) {
            displayName = other.displayName ?? displayName
            contentLength = other.contentLength ?? contentLength
            lastModified = other.lastModified ?? lastModified
            etag = other.etag ?? etag
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
    private var depth = 0
    private var sawMultistatusRoot = false
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
        guard delegate.sawMultistatusRoot else {
            throw SourceError.connectionFailed("Invalid WebDAV multistatus response")
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
        if depth == 0, element == "multistatus" {
            sawMultistatusRoot = true
        }
        depth += 1
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
        defer { depth = max(0, depth - 1) }
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
        case "getetag":
            propstat?.properties.etag = value.isEmpty ? nil : value
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
                        etag: response.properties.etag,
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
