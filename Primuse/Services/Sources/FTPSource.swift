import CryptoKit
import FilesProvider
import Foundation
import PrimuseKit

/// FilesProvider 0.26's RFC 3659 fallback invokes `attributesOfItem` twice:
/// once for the failed MLST request and again for its LIST fallback. Its RETR
/// implementation ignores the attribute error and starts a transfer for each
/// callback, so one logical read can otherwise create parallel RETR requests.
/// Force the dependency's single-callback LIST implementation for every
/// metadata lookup performed internally by `copyItem` and `contents`.
private final class PrimuseFTPFileProvider: FTPFileProvider {
    override func attributesOfItem(
        path: String,
        completionHandler: @escaping (FileObject?, (any Error)?) -> Void
    ) {
        super.attributesOfItem(
            path: path,
            rfc3659enabled: FTPTransferPolicy.usesRFC3659ForAttributes,
            completionHandler: completionHandler
        )
    }
}

/// Coordinates the one explicit retry after an invalid transfer callback.
/// Multiple callbacks from the original request may race here.
private final class FTPRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var retryStarted = false

    var hasStartedRetry: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retryStarted
    }

    func claimRetry() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retryStarted else { return false }
        retryStarted = true
        return true
    }
}

/// Owns one isolated FTP session and resolves callback/cancellation races once.
/// FilesProvider's Progress cancellation handler may only point at its latest
/// stream task. Keep every returned Progress and also invalidate any
/// URLSession-backed work owned by the isolated provider.
private final class FTPRequestBox<Value: Sendable>: @unchecked Sendable {
    let provider: FTPFileProvider
    private let race = CancellableResultRace<Value>()
    private let progressCancellations = OneShotCancellationRegistry()

    init(provider: FTPFileProvider) {
        self.provider = provider
        // Materialize FilesProvider's lazy session before cancellation can
        // race request startup on another callback queue.
        _ = provider.session
    }

    var isResolved: Bool {
        race.isResolved
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        race.install(continuation)
    }

    func updateProgress(_ progress: Progress?) {
        guard let progress else { return }
        _ = progressCancellations.register {
            progress.cancel()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        // Begin transport cleanup before waking the actor. Otherwise the
        // resumed localURL path could rename its validated temp file while a
        // late transport callback is still able to observe that path.
        terminateTransport()
        return race.resolve(result)
    }

    func cancel() {
        terminateTransport()
        _ = race.cancel()
    }

    private func terminateTransport() {
        _ = progressCancellations.cancelAll()
        provider.session.invalidateAndCancel()
    }
}

private func ftpLocalFileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.int64Value
}

private func ftpTransferFailure(
    error: (any Error)?,
    expectedSize: Int64? = nil,
    actualSize: Int64? = nil
) -> SourceError {
    if let error {
        return .connectionFailed(error.localizedDescription)
    }
    if let expectedSize {
        let actual = actualSize.map(String.init) ?? "missing"
        return .connectionFailed(
            "Incomplete FTP transfer: expected \(expectedSize) bytes, received \(actual)"
        )
    }
    return .connectionFailed("FTP request completed without data")
}

private func startFTPDownloadAttempt(
    request: FTPRequestBox<Void>,
    path: String,
    temporaryURL: URL,
    expectedSize: Int64,
    attempt: Int,
    retryGate: FTPRetryGate
) {
    guard !request.isResolved else { return }

    let progress = request.provider.copyItem(path: path, toLocalURL: temporaryURL) { error in
        guard !request.isResolved else { return }
        let actualSize = ftpLocalFileSize(at: temporaryURL)
        let decision = FTPTransferPolicy.callbackDecision(
            attempt: attempt,
            payloadIsValid: FTPTransferPolicy.downloadPayloadIsValid(
                expectedSize: expectedSize,
                actualSize: actualSize,
                errorOccurred: error != nil
            ),
            retryAlreadyStarted: retryGate.hasStartedRetry
        )

        switch decision {
        case .accept:
            request.resolve(.success(()))
        case .retry:
            guard retryGate.claimRetry() else { return }
            try? FileManager.default.removeItem(at: temporaryURL)
            startFTPDownloadAttempt(
                request: request,
                path: path,
                temporaryURL: temporaryURL,
                expectedSize: expectedSize,
                attempt: 1,
                retryGate: retryGate
            )
        case .awaitRetry:
            return
        case .fail:
            request.resolve(.failure(ftpTransferFailure(
                error: error,
                expectedSize: expectedSize,
                actualSize: actualSize
            )))
        }
    }
    request.updateProgress(progress)
}

private func startFTPRangeAttempt(
    request: FTPRequestBox<Data>,
    path: String,
    offset: Int64,
    expectedLength: Int,
    attempt: Int,
    retryGate: FTPRetryGate
) {
    guard !request.isResolved else { return }

    let progress = request.provider.contents(
        path: path,
        offset: offset,
        length: expectedLength
    ) { data, error in
        guard !request.isResolved else { return }
        let decision = FTPTransferPolicy.callbackDecision(
            attempt: attempt,
            payloadIsValid: FTPTransferPolicy.rangePayloadIsValid(
                expectedLength: expectedLength,
                actualLength: data?.count,
                errorOccurred: error != nil
            ),
            retryAlreadyStarted: retryGate.hasStartedRetry
        )

        switch decision {
        case .accept:
            request.resolve(.success(data ?? Data()))
        case .retry:
            guard retryGate.claimRetry() else { return }
            startFTPRangeAttempt(
                request: request,
                path: path,
                offset: offset,
                expectedLength: expectedLength,
                attempt: 1,
                retryGate: retryGate
            )
        case .awaitRetry:
            return
        case .fail:
            request.resolve(.failure(ftpTransferFailure(
                error: error,
                expectedSize: Int64(expectedLength),
                actualSize: data.map { Int64($0.count) }
            )))
        }
    }
    request.updateProgress(progress)
}

actor FTPSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let pathPolicy: FTPPathPolicy
    private let username: String
    private let password: String
    private let encryption: FTPEncryption
    private var provider: FTPFileProvider?
    private let cacheDirectory: URL
    private let activeRequests = ConnectionScopedOperationRegistry()
    private var connectionGeneration: ConnectionScopedOperationRegistry.Generation?
    private var fileSizeCache: [String: Int64] = [:]

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        basePath: String? = nil,
        username: String,
        password: String,
        encryption: FTPEncryption
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.pathPolicy = FTPPathPolicy(basePath: basePath)
        self.username = username
        self.password = password
        self.encryption = encryption

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_ftp_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if provider != nil {
            return
        }

        let provider = try makeProvider()
        let generation = activeRequests.open()
        connectionGeneration = generation
        self.provider = provider

        do {
            _ = try await listFiles(at: "/")
            try ensureConnected(generation)
        } catch {
            if connectionGeneration == generation {
                connectionGeneration = nil
                if self.provider === provider {
                    self.provider = nil
                }
                _ = activeRequests.close(generation)
            }
            provider.session.invalidateAndCancel()
            throw error
        }
    }

    func disconnect() async {
        let disconnectedProvider = provider
        let disconnectedGeneration = connectionGeneration
        provider = nil
        connectionGeneration = nil
        if let disconnectedGeneration {
            _ = activeRequests.close(disconnectedGeneration)
        }
        disconnectedProvider?.session.invalidateAndCancel()
        // A reconnect may observe files changed by another FTP client.
        fileSizeCache.removeAll(keepingCapacity: true)
    }

    private func makeProvider() throws -> FTPFileProvider {
        // FTP anonymous login convention: username "anonymous" with any password
        // (commonly an email). Empty username is rejected by most servers.
        let effectiveUser = username.isEmpty ? "anonymous" : username
        let effectivePassword: String = {
            if username.isEmpty && password.isEmpty {
                return "anonymous@primuse"
            }
            return password
        }()

        let credential = URLCredential(
            user: effectiveUser,
            password: effectivePassword,
            persistence: .forSession
        )

        guard let provider = PrimuseFTPFileProvider(
            baseURL: try serverURL(),
            credential: credential
        ) else {
            throw SourceError.connectionFailed("Invalid FTP URL")
        }

        // FilesProvider may report the completed data callback and then a
        // trailing FTP control-channel error (for example 426 after the
        // requested byte count has already been received). Its default
        // concurrent callback queue can reorder those deliveries, allowing
        // the trailing error to beat the valid data into our once-only gate.
        // Preserve the dependency's production order for every provider.
        provider.dispatch_queue = DispatchQueue(
            label: "com.welape.yuanyin.ftp.callbacks.\(UUID().uuidString)"
        )
        provider.securedDataConnection = encryption != .none
        return provider
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }
        let pathPolicy = self.pathPolicy
        let providerDirectoryPath = pathPolicy.providerPath(forSourcePath: path)

        let items: [RemoteFileItem] = try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: providerDirectoryPath) { contents, error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                    return
                }

                let items = contents
                    .filter { !$0.name.hasPrefix(".") }
                    .compactMap { file -> RemoteFileItem? in
                        guard let sourcePath = pathPolicy.sourcePath(
                            forProviderPath: file.path
                        ) else {
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
        // The FilesProvider callback is outside this actor. Populate the cache
        // only after the continuation resumes on the actor executor.
        for item in items where !item.isDirectory && item.size >= 0 {
            fileSizeCache[fileSizeCacheKey(for: item.path)] = item.size
        }
        return items
    }

    /// 缓存文件名用 path 的 SHA256 哈希: 朴素地把 '/' 换 '_' 会让 "/A/B.mp3" 与
    /// "/A_B.mp3" 撞到同一缓存键、播到错误文件(NFS 已用哈希规避, 这里对齐)。
    private static func cacheFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    func localURL(for path: String) async throws -> URL {
        let generation = try connectedGeneration()

        let localURL = cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
        let expectedSize = try await ftpFileSize(path: path, generation: generation)
        try ensureConnected(generation)

        if ftpLocalFileSize(at: localURL) == expectedSize {
            return localURL
        }

        // Download to a sibling temp path then atomically rename. FilesProvider's
        // `copyItem` moves the in-progress temp file to its destination *before*
        // reporting an error, so downloading straight to `localURL` would leave a
        // truncated file there that future calls treat as a complete cache.
        let tempURL = cacheDirectory.appendingPathComponent(
            "\(localURL.lastPathComponent).part-\(UUID().uuidString)"
        )
        let transferProvider = try makeProvider()
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)

        do {
            try await performIsolatedRequest(
                provider: transferProvider,
                generation: generation
            ) { request in
                startFTPDownloadAttempt(
                    request: request,
                    path: providerFilePath,
                    temporaryURL: tempURL,
                    expectedSize: expectedSize,
                    attempt: 0,
                    retryGate: FTPRetryGate()
                )
            }
            try ensureConnected(generation)

            let targetExists = FileManager.default.fileExists(atPath: localURL.path)
            let targetSize = targetExists ? (ftpLocalFileSize(at: localURL) ?? -1) : nil
            switch FTPTransferPolicy.promotionDecision(
                expectedSize: expectedSize,
                temporarySize: ftpLocalFileSize(at: tempURL),
                existingTargetSize: targetSize
            ) {
            case .rejectTemporary:
                throw ftpTransferFailure(
                    error: nil,
                    expectedSize: expectedSize,
                    actualSize: ftpLocalFileSize(at: tempURL)
                )
            case .useExistingTarget:
                try? FileManager.default.removeItem(at: tempURL)
                return localURL
            case .replaceIncompleteTarget:
                try FileManager.default.removeItem(at: localURL)
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            case .promoteTemporary:
                do {
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                } catch {
                    // A non-actor participant may have installed the same cache
                    // key between the final size check and rename.
                    if ftpLocalFileSize(at: localURL) == expectedSize {
                        try? FileManager.default.removeItem(at: tempURL)
                        return localURL
                    }
                    throw error
                }
            }
        } catch {
            transferProvider.session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return localURL
    }

    func deleteFile(at path: String) async throws {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            provider.removeItem(path: providerFilePath) { error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        fileSizeCache[fileSizeCacheKey(for: path)] = nil
    }

    /// FTP REST + RETR via FilesProvider's `contents(path:offset:length:)`。
    /// FTP 协议支持 REST 命令断点续传, FilesProvider 内部用 REST + RETR
    /// 实现 byte range, 让 CloudPlaybackSource 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let generation = try connectedGeneration()

        // Resolve the size through the actor cache so both regular and suffix
        // requests have an EOF-clipped byte count. Successful directory scans
        // populate it up front; otherwise only the first range performs the
        // explicit metadata LIST. FilesProvider can deliver a nonnil short
        // buffer before its trailing control-channel error, so callback validity
        // must still be checked against this exact count.
        let totalSize = try await ftpFileSize(path: path, generation: generation)
        try ensureConnected(generation)
        let rangePlan = FTPTransferPolicy.rangePlan(
            fileSize: totalSize,
            requestedOffset: offset,
            requestedLength: length
        )
        guard rangePlan.expectedLength > 0 else { return Data() }

        // FilesProvider's range API opens a fresh FTP control task but never
        // sends QUIT after RETR completes. Reusing the browsing provider leaves
        // every range task alive until the server's idle timeout, eventually
        // exhausting connections during scans and concurrent playback reads.
        // Isolate each range request so cleanup remains scoped to that request:
        // cancel its returned Progress and invalidate URLSession-backed work as
        // soon as the callback resolves. FilesProvider's custom stream task may
        // still acknowledge Progress cancellation only after its read loop exits.
        let rangeProvider = try makeProvider()
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)
        let data = try await performIsolatedRequest(
            provider: rangeProvider,
            generation: generation
        ) { request in
            startFTPRangeAttempt(
                request: request,
                path: providerFilePath,
                offset: rangePlan.offset,
                expectedLength: rangePlan.expectedLength,
                attempt: 0,
                retryGate: FTPRetryGate()
            )
        }
        try ensureConnected(generation)
        return data
    }

    /// Uses a cached size when available. A miss performs a parent-directory
    /// listing instead of `attributesOfItem`: the dependency's MLST 500 fallback
    /// in `attributesOfItem` lacks a return and can call its completion twice.
    private func ftpFileSize(
        path: String,
        generation: ConnectionScopedOperationRegistry.Generation
    ) async throws -> Int64 {
        try ensureConnected(generation)
        let cacheKey = fileSizeCacheKey(for: path)
        if let cachedSize = fileSizeCache[cacheKey] {
            return cachedSize
        }

        let metadataProvider = try makeProvider()
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)
        let fileName = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "/" : parent
        let providerDirectoryPath = pathPolicy.providerPath(forSourcePath: directory)

        let size: Int64 = try await performIsolatedRequest(
            provider: metadataProvider,
            generation: generation
        ) { request in
            request.provider.contentsOfDirectory(path: providerDirectoryPath) { contents, error in
                guard !request.isResolved else { return }
                if let error {
                    request.resolve(.failure(
                        SourceError.connectionFailed(error.localizedDescription)
                    ))
                    return
                }

                guard let file = contents.first(where: {
                    !$0.isDirectory && ($0.path == providerFilePath || $0.name == fileName)
                }) else {
                    request.resolve(.failure(SourceError.fileNotFound(path)))
                    return
                }
                guard file.size >= 0 else {
                    request.resolve(.failure(SourceError.connectionFailed(
                        "FTP server did not report a valid size for \(path)"
                    )))
                    return
                }
                request.resolve(.success(file.size))
            }
        }
        try ensureConnected(generation)
        fileSizeCache[cacheKey] = size
        return size
    }

    private func fileSizeCacheKey(for sourcePath: String) -> String {
        pathPolicy.providerPath(forSourcePath: sourcePath)
    }

    private func performIsolatedRequest<Value: Sendable>(
        provider: FTPFileProvider,
        generation: ConnectionScopedOperationRegistry.Generation,
        start: @Sendable (FTPRequestBox<Value>) -> Void
    ) async throws -> Value {
        let request = FTPRequestBox<Value>(provider: provider)
        guard let registrationID = activeRequests.register(for: generation, {
            request.cancel()
        }) else {
            throw SourceError.connectionFailed("Not connected")
        }
        defer { activeRequests.unregister(registrationID) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !request.isResolved else { return }
                start(request)
            }
        } onCancel: {
            request.cancel()
        }
    }

    private func connectedGeneration() throws -> ConnectionScopedOperationRegistry.Generation {
        guard provider != nil, let connectionGeneration else {
            throw SourceError.connectionFailed("Not connected")
        }
        try ensureConnected(connectionGeneration)
        return connectionGeneration
    }

    private func ensureConnected(
        _ generation: ConnectionScopedOperationRegistry.Generation
    ) throws {
        guard provider != nil,
              connectionGeneration == generation,
              activeRequests.isActive(generation) else {
            throw SourceError.connectionFailed("Not connected")
        }
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
            Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
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
        let items = try await listFiles(at: path)
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)

        for item in items {
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

    private func serverURL() throws -> URL {
        let scheme = switch encryption {
        case .none: "ftp"
        case .implicitTLS: "ftps"
        case .explicitTLS: "ftpes"
        }
        guard let url = NetworkURLBuilder.makeURL(
            host: host,
            defaultScheme: scheme,
            port: port ?? defaultPort,
            path: FTPPathPolicy.providerBaseURLPath,
            forceScheme: true
        ) else {
            throw SourceError.connectionFailed("Invalid FTP URL")
        }
        return url
    }

    private var defaultPort: Int {
        switch encryption {
        case .implicitTLS:
            return 990
        case .none, .explicitTLS:
            return 21
        }
    }

}
