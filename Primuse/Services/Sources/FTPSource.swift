import CryptoKit
import Foundation
import PrimuseKit

/// 数据连接没能建立:多半是数据连接方式不对(被动模式下服务器报了连不上的地址、主动模式下
/// 服务器连不进来)。换数据连接方式才能好,所以不当成网络抖动自动重试,直接告诉用户该改哪里。
private struct FTPDataConnectionError: LocalizedError {
    var errorDescription: String? { String(localized: "ftp_data_connection_timeout") }
}

private func ftpLocalFileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.int64Value
}

private func ftpTransferFailure(expectedSize: Int64, actualSize: Int64?) -> SourceError {
    let actual = actualSize.map(String.init) ?? "missing"
    return .connectionFailed("Incomplete FTP transfer: expected \(expectedSize) bytes, received \(actual)")
}

actor FTPSource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    private let host: String
    private let port: Int?
    private let pathPolicy: FTPPathPolicy
    private let username: String
    private let password: String
    private let encryption: FTPEncryption
    private let dataConnectionMode: FTPDataConnectionMode
    private var pool: FTPSessionPool?
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
        encryption: FTPEncryption,
        dataConnectionMode: FTPDataConnectionMode = .automatic
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.pathPolicy = FTPPathPolicy(basePath: basePath)
        self.username = username
        self.password = password
        self.encryption = encryption
        self.dataConnectionMode = dataConnectionMode

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_ftp_cache")
            .appendingPathComponent(sourceID)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID))
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if pool != nil {
            return
        }

        let pool = FTPSessionPool(configuration: try sessionConfiguration())
        let generation = activeRequests.open()
        connectionGeneration = generation
        self.pool = pool

        do {
            _ = try await listFiles(at: "/")
            try ensureConnected(generation)
        } catch {
            if connectionGeneration == generation {
                connectionGeneration = nil
                if self.pool === pool {
                    self.pool = nil
                }
                _ = activeRequests.close(generation)
            }
            await pool.shutdown()
            throw error
        }
    }

    func disconnect() async {
        invalidateConnectionState()
    }

    private func sessionConfiguration() throws -> FTPSessionConfiguration {
        let url = try serverURL()
        guard let resolvedHost = url.host, !resolvedHost.isEmpty else {
            throw SourceError.connectionFailed("Invalid FTP URL")
        }
        return FTPSessionConfiguration(
            host: resolvedHost,
            port: url.port ?? defaultPort,
            username: username,
            password: password,
            encryption: encryption,
            dataConnectionMode: dataConnectionMode,
            log: { plog($0) }
        )
    }

    // MARK: - Directory listing

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        var completedRetryAttempts = 0
        var previousAttemptWasEmpty = false

        while true {
            let generation = try connectedGeneration()
            do {
                let items = try await rawListFiles(at: path, generation: generation)
                let outcome: RemoteDirectoryListingOutcome = items.isEmpty ? .empty : .populated
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    // 空目录要再从一条新连接确认一次:扫描会把「列出来是空的」当成歌都删了。
                    emptyNeedsFreshConfirmation: true,
                    previousAttemptWasEmpty: previousAttemptWasEmpty
                ) {
                case .accept:
                    for item in items where !item.isDirectory && item.size >= 0 {
                        fileSizeCache[fileSizeCacheKey(for: item.path)] = item.size
                    }
                    return items
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    previousAttemptWasEmpty = true
                case .fail:
                    invalidateConnectionState()
                    throw SourceError.connectionFailed("FTP directory listing failed")
                }
            } catch {
                let mapped = Self.sourceError(for: error, path: path, isDirectory: true)
                if mapped is CancellationError || OperationCancellationPolicy.isCancellation(error) {
                    throw CancellationError()
                }
                let outcome: RemoteDirectoryListingOutcome = Self.isPermanentDirectoryError(mapped)
                    ? .permanentFailure
                    : .retryableFailure
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    emptyNeedsFreshConfirmation: true
                ) {
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    previousAttemptWasEmpty = false
                case .accept:
                    assertionFailure("A directory error cannot be accepted")
                    invalidateConnectionState()
                    throw mapped
                case .fail:
                    if !(mapped is FTPDataConnectionError) {
                        invalidateConnectionState()
                    }
                    throw mapped
                }
            }
        }
    }

    private func rawListFiles(
        at path: String,
        generation: ConnectionScopedOperationRegistry.Generation
    ) async throws -> [RemoteFileItem] {
        let pathPolicy = self.pathPolicy
        let directory = pathPolicy.providerPath(forSourcePath: path)
        let entries = try await withPool(generation: generation) { session in
            try await session.list(directory)
        }
        return entries
            .filter { !$0.name.hasPrefix(".") }
            .compactMap { entry -> RemoteFileItem? in
                let providerPath = (directory as NSString).appendingPathComponent(entry.name)
                guard let sourcePath = pathPolicy.sourcePath(forProviderPath: providerPath) else {
                    return nil
                }
                return RemoteFileItem(
                    name: entry.name,
                    path: sourcePath,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modifiedDate: entry.modifiedDate,
                    revision: Self.fileRevision(size: entry.size, modifiedDate: entry.modifiedDate)
                )
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func invalidateConnectionState() {
        let disconnectedPool = pool
        let disconnectedGeneration = connectionGeneration
        pool = nil
        connectionGeneration = nil
        if let disconnectedGeneration {
            _ = activeRequests.close(disconnectedGeneration)
        }
        if let disconnectedPool {
            Task { await disconnectedPool.shutdown() }
        }
        fileSizeCache.removeAll(keepingCapacity: true)
    }

    private nonisolated static func isPermanentDirectoryError(_ error: Error) -> Bool {
        if error is FTPDataConnectionError { return true }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable, .pathNotFound, .fileNotFound:
                return true
            case .connectionFailed, .timeout:
                return false
            }
        }
        return false
    }

    /// 客户端错误换成音乐源统一的错误。数据连接建不起来的给出带提示的那条。
    private nonisolated static func sourceError(for error: Error, path: String, isDirectory: Bool) -> Error {
        guard let ftpError = error as? FTPClientError else { return error }
        if ftpError.isAuthenticationFailure { return SourceError.authenticationFailed }
        if ftpError.isPathFailure {
            return isDirectory ? SourceError.pathNotFound(path) : SourceError.fileNotFound(path)
        }
        if ftpError.isDataConnectionFailure { return FTPDataConnectionError() }
        if case .timedOut = ftpError { return SourceError.timeout }
        if case .cancelled = ftpError { return CancellationError() }
        return SourceError.connectionFailed(String(describing: ftpError))
    }

    /// 缓存文件名用 path 的 SHA256 哈希: 朴素地把 '/' 换 '_' 会让 "/A/B.mp3" 与
    /// "/A_B.mp3" 撞到同一缓存键、播到错误文件(NFS 已用哈希规避, 这里对齐)。
    private static func cacheFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    // MARK: - Downloads

    func localURL(for path: String) async throws -> URL {
        let generation = try connectedGeneration()

        let localURL = cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
        let expectedSize = try await ftpFileSize(path: path, generation: generation)
        try ensureConnected(generation)

        if ftpLocalFileSize(at: localURL) == expectedSize {
            return localURL
        }

        // 先下到旁边的临时文件, 大小核对无误再改名, 中途失败不会留下被当成完整缓存的半截文件。
        let tempURL = cacheDirectory.appendingPathComponent(
            "\(localURL.lastPathComponent).part-\(UUID().uuidString)"
        )
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)

        do {
            var attempt = 0
            while true {
                let received = try await withPool(generation: generation) { session in
                    try await session.retrieve(providerFilePath, to: tempURL)
                }
                let payloadIsValid = FTPTransferPolicy.downloadPayloadIsValid(
                    expectedSize: expectedSize,
                    actualSize: ftpLocalFileSize(at: tempURL) ?? received,
                    errorOccurred: false
                )
                switch FTPTransferPolicy.callbackDecision(
                    attempt: attempt,
                    payloadIsValid: payloadIsValid,
                    retryAlreadyStarted: false
                ) {
                case .accept:
                    break
                case .retry, .awaitRetry:
                    attempt += 1
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                case .fail:
                    throw ftpTransferFailure(expectedSize: expectedSize, actualSize: ftpLocalFileSize(at: tempURL))
                }
                break
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
                throw ftpTransferFailure(expectedSize: expectedSize, actualSize: ftpLocalFileSize(at: tempURL))
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
                    // 别的调用方可能在最后一次核对与改名之间装好了同一个缓存键。
                    if ftpLocalFileSize(at: localURL) == expectedSize {
                        try? FileManager.default.removeItem(at: tempURL)
                        return localURL
                    }
                    throw error
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw Self.sourceError(for: error, path: path, isDirectory: false)
        }
        return localURL
    }

    /// REST + RETR 读一段, 让 CloudPlaybackSource 边下边播。读够就断开数据连接,
    /// 控制连接留在池里给下一段用, 不用每段都重新登录。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let generation = try connectedGeneration()

        let totalSize = try await ftpFileSize(path: path, generation: generation)
        try ensureConnected(generation)
        let rangePlan = FTPTransferPolicy.rangePlan(
            fileSize: totalSize,
            requestedOffset: offset,
            requestedLength: length
        )
        guard rangePlan.expectedLength > 0 else { return Data() }

        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)
        var attempt = 0
        while true {
            let data: Data
            do {
                data = try await withPool(generation: generation) { session in
                    try await session.retrieve(
                        providerFilePath,
                        offset: rangePlan.offset,
                        length: rangePlan.expectedLength
                    )
                }
            } catch {
                throw Self.sourceError(for: error, path: path, isDirectory: false)
            }
            try ensureConnected(generation)
            switch FTPTransferPolicy.callbackDecision(
                attempt: attempt,
                payloadIsValid: FTPTransferPolicy.rangePayloadIsValid(
                    expectedLength: rangePlan.expectedLength,
                    actualLength: data.count,
                    errorOccurred: false
                ),
                retryAlreadyStarted: false
            ) {
            case .accept:
                return data
            case .retry, .awaitRetry:
                attempt += 1
            case .fail:
                throw ftpTransferFailure(
                    expectedSize: Int64(rangePlan.expectedLength),
                    actualSize: Int64(data.count)
                )
            }
        }
    }

    // MARK: - Writes

    func writeFile(data: Data, to path: String) async throws {
        let generation = try connectedGeneration()
        let providerPath = pathPolicy.providerPath(forSourcePath: path)
        do {
            try await withPool(generation: generation, retriesOnStaleConnection: false) { session in
                try await session.store(providerPath, data: data)
            }
        } catch {
            throw Self.sourceError(for: error, path: path, isDirectory: false)
        }
        fileSizeCache[fileSizeCacheKey(for: path)] = Int64(data.count)
        await invalidateMetadataWritebackCache(for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        try await listedMetadataWritebackState(for: path)
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        let generation = try connectedGeneration()
        let destinationPath = pathPolicy.providerPath(forSourcePath: path)
        let parent = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let stagingSourcePath = (parent as NSString).appendingPathComponent(
            ".\(fileName).primuse-writeback-\(UUID().uuidString)"
        )
        let stagingPath = pathPolicy.providerPath(forSourcePath: stagingSourcePath)

        do {
            try await withPool(generation: generation, retriesOnStaleConnection: false) { session in
                try await session.store(stagingPath, fileURL: localURL)
            }

            let current = try await metadataWritebackState(for: path)
            guard expected.matches(current) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }

            try await withPool(generation: generation, retriesOnStaleConnection: false) { session in
                try await session.rename(stagingPath, to: destinationPath)
            }
        } catch {
            await removeStagingFileIfPresent(providerPath: stagingPath, generation: generation)
            throw Self.sourceError(for: error, path: path, isDirectory: false)
        }

        fileSizeCache[fileSizeCacheKey(for: path)] = nil
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
        )
        fileSizeCache[fileSizeCacheKey(for: path)] = nil
    }

    private func removeStagingFileIfPresent(
        providerPath: String,
        generation: ConnectionScopedOperationRegistry.Generation
    ) async {
        try? await withPool(generation: generation, retriesOnStaleConnection: false) { session in
            try await session.delete(providerPath)
        }
    }

    private nonisolated static func fileRevision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "ftp:\(size):\(Int64(modifiedDate.timeIntervalSince1970))"
    }

    func deleteFile(at path: String) async throws {
        let generation = try connectedGeneration()
        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)
        do {
            try await withPool(generation: generation, retriesOnStaleConnection: false) { session in
                try await session.delete(providerFilePath)
            }
        } catch {
            throw Self.sourceError(for: error, path: path, isDirectory: false)
        }
        fileSizeCache[fileSizeCacheKey(for: path)] = nil
    }

    // MARK: - Sizes

    /// 先用缓存;没有就问 `SIZE`,服务器不支持再列一次所在目录。
    private func ftpFileSize(
        path: String,
        generation: ConnectionScopedOperationRegistry.Generation
    ) async throws -> Int64 {
        try ensureConnected(generation)
        let cacheKey = fileSizeCacheKey(for: path)
        if let cachedSize = fileSizeCache[cacheKey] {
            return cachedSize
        }

        let providerFilePath = pathPolicy.providerPath(forSourcePath: path)
        let fileName = (providerFilePath as NSString).lastPathComponent
        let providerDirectory = (providerFilePath as NSString).deletingLastPathComponent
        let size: Int64
        do {
            size = try await withPool(generation: generation) { session -> Int64 in
                if let reported = try await session.size(providerFilePath), reported >= 0 {
                    return reported
                }
                let entries = try await session.list(providerDirectory.isEmpty ? "/" : providerDirectory)
                guard let entry = entries.first(where: { !$0.isDirectory && $0.name == fileName }) else {
                    throw SourceError.fileNotFound(path)
                }
                guard entry.size >= 0 else {
                    throw SourceError.connectionFailed("FTP server did not report a valid size for \(path)")
                }
                return entry.size
            }
        } catch {
            throw Self.sourceError(for: error, path: path, isDirectory: false)
        }
        try ensureConnected(generation)
        fileSizeCache[cacheKey] = size
        return size
    }

    private func fileSizeCacheKey(for sourcePath: String) -> String {
        pathPolicy.providerPath(forSourcePath: sourcePath)
    }

    // MARK: - Connection scope

    /// 在池里借一个会话跑 `body`。断开(或换了一代连接)时正在跑的操作一并取消。
    private func withPool<T: Sendable>(
        generation: ConnectionScopedOperationRegistry.Generation,
        retriesOnStaleConnection: Bool = true,
        _ body: @escaping @Sendable (FTPSession) async throws -> T
    ) async throws -> T {
        guard let pool else { throw SourceError.connectionFailed("Not connected") }
        let operation = Task {
            try await pool.withSession(retriesOnStaleConnection: retriesOnStaleConnection, body)
        }
        guard let registrationID = activeRequests.register(for: generation, { operation.cancel() }) else {
            throw SourceError.connectionFailed("Not connected")
        }
        defer { activeRequests.unregister(registrationID) }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func connectedGeneration() throws -> ConnectionScopedOperationRegistry.Generation {
        guard pool != nil, let connectionGeneration else {
            throw SourceError.connectionFailed("Not connected")
        }
        try ensureConnected(connectionGeneration)
        return connectionGeneration
    }

    private func ensureConnected(
        _ generation: ConnectionScopedOperationRegistry.Generation
    ) throws {
        guard pool != nil,
              connectionGeneration == generation,
              activeRequests.isActive(generation) else {
            throw SourceError.connectionFailed("Not connected")
        }
    }

    // MARK: - Streaming and scanning

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { try? handle.close() }
                    while true {
                        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
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
