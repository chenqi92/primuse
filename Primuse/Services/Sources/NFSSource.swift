import CryptoKit
import Foundation
import PrimuseKit

enum NFSSelectionPathCodec {
    struct SelectionPath: Sendable {
        let exportPath: String
        let relativePath: String
    }

    static func makeSelectionPath(exportPath: String, relativePath: String) -> String {
        "nfs::\(encodeToken(normalizedExportPath(exportPath)))::\(encodeToken(normalizedRelativePath(relativePath)))"
    }

    static func parse(
        _ path: String,
        constrainedToExport configuredExportPath: String? = nil
    ) throws -> SelectionPath {
        guard path.hasPrefix("nfs::") else {
            throw SourceError.pathNotFound(path)
        }

        let payload = String(path.dropFirst("nfs::".count))
        guard let separator = payload.range(of: "::") else {
            throw SourceError.pathNotFound(path)
        }

        let exportToken = String(payload[..<separator.lowerBound])
        let relativeToken = String(payload[separator.upperBound...])

        guard let exportPath = decodeToken(exportToken),
              let relativePath = decodeToken(relativeToken) else {
            throw SourceError.pathNotFound(path)
        }

        guard let scoped = NFSSelectionScopePolicy.resolve(
            exportPath: exportPath,
            relativePath: relativePath,
            configuredExportPath: configuredExportPath
        ) else {
            throw SourceError.pathNotFound(path)
        }

        return SelectionPath(
            exportPath: scoped.exportPath,
            relativePath: scoped.relativePath
        )
    }

    static func displayComponents(for path: String) -> [String] {
        guard let selection = try? parse(path) else {
            return []
        }

        let exportName = displayName(forExportPath: selection.exportPath)
        let children = selection.relativePath
            .split(separator: "/")
            .map(String.init)

        return [exportName] + children
    }

    static func cacheFileName(for path: String) -> String? {
        guard let selection = try? parse(path) else { return nil }
        return cacheFileName(for: selection)
    }

    static func cacheFileName(for selection: SelectionPath) -> String {
        CacheFileNamePolicy.make(
            path: "\(selection.exportPath):\(selection.relativePath)",
            preferredExtension: (selection.relativePath as NSString).pathExtension
        )
    }

    static func displayName(forExportPath exportPath: String) -> String {
        let trimmed = exportPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? exportPath : name
    }

    static func normalizedRelativePath(_ path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/"
        }

        return path.hasPrefix("/") ? path : "/\(path)"
    }

    static func normalizedExportPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemotePathScopePolicy(rootPath: trimmed).rootPath
    }

    private static func encodeToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeToken(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding != 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

private struct NFSFallbackCandidate {
    let version: NFSVersion
    let client: any NFSClientBackend
}

actor NFSSource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter,
    LyricsSidecarTargetResolving {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true

    private let host: String
    private let port: Int?
    private let configuredExportPath: String?
    private let nfsVersion: NFSVersion
    private var client: (any NFSClientBackend)?
    private var activeVersion: NFSVersion?
    private var connectedExportPath: String?
    private var cachedExports: [String]?
    private let cacheDirectory: URL
    private var localFileTasks: [String: Task<URL, Error>] = [:]

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        exportPath: String? = nil,
        nfsVersion: NFSVersion = .auto
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.nfsVersion = nfsVersion
        let normalizedExport = exportPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredExportPath = normalizedExport?.isEmpty == false
            ? NFSSelectionPathCodec.normalizedExportPath(normalizedExport!)
            : nil

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_nfs_cache")
            .appendingPathComponent(sourceID)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID))
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory

    }

    func connect() async throws {
        _ = try resolveClient()
        if let configuredExportPath {
            // A cached export path is not a liveness signal after sleep or a
            // network handoff. Probe the mounted root through the same bounded
            // fresh-client recovery used by scans.
            _ = try await listDirectory(
                exportPath: configuredExportPath,
                relativePath: "/"
            )
        } else {
            // Cached export names are likewise not proof that rpcbind/NFS is
            // still reachable. A connection preflight must perform real I/O.
            _ = try await loadExports(forceRefresh: true)
        }
    }

    func disconnect() async {
        await invalidateActiveClient()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if path == "/", let configuredExportPath {
            return try await listDirectory(
                exportPath: configuredExportPath,
                relativePath: "/"
            )
        }

        if path == "/" {
            let exports = try await loadExports()
            return exports
                .map { exportPath in
                    RemoteFileItem(
                        name: NFSSelectionPathCodec.displayName(forExportPath: exportPath),
                        path: NFSSelectionPathCodec.makeSelectionPath(
                            exportPath: exportPath,
                            relativePath: "/"
                        ),
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        let selection = try await resolveSelectionPath(for: path)
        return try await listDirectory(
            exportPath: selection.exportPath,
            relativePath: selection.relativePath
        )
    }

    func localURL(for path: String) async throws -> URL {
        let selection = try await resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        let cacheName = NFSSelectionPathCodec.cacheFileName(for: selection)
        let localURL = cacheDirectory.appendingPathComponent(cacheName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        if let inFlight = localFileTasks[cacheName] {
            return try await inFlight.value
        }

        let task = Task<URL, Error> {
            let tempURL = self.cacheDirectory.appendingPathComponent(
                "\(cacheName).part-\(UUID().uuidString)"
            )
            do {
                try await client.download(path: selection.relativePath, to: tempURL)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try? FileManager.default.removeItem(at: tempURL)
                    return localURL
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)
                return localURL
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw SourceError.connectionFailed(error.localizedDescription)
            }
        }
        localFileTasks[cacheName] = task
        defer { localFileTasks[cacheName] = nil }
        return try await task.value
    }

    func deleteFile(at path: String) async throws {
        let selection = try await resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        try await client.remove(path: selection.relativePath)
    }

    func writeFile(data: Data, to path: String) async throws {
        let selection = try await sidecarAwareWriteSelection(for: path)
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-nfs-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try data.write(to: localURL, options: .atomic)

        let activeClient = try await ensureConnected(to: selection.exportPath)
        let stagingPath = Self.stagingPath(for: selection.relativePath)
        do {
            try await activeClient.upload(localURL: localURL, to: stagingPath)
            try await activeClient.rename(path: stagingPath, to: selection.relativePath)
        } catch {
            try? await activeClient.remove(path: stagingPath)
            throw error
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        let selection = try await sidecarAwareWriteSelection(for: path)
        let resolvedPath = NFSSelectionPathCodec.makeSelectionPath(
            exportPath: selection.exportPath,
            relativePath: selection.relativePath
        )
        await invalidateMetadataWritebackCache(for: resolvedPath)
        let readback = try await fetchRange(
            path: resolvedPath,
            offset: 0,
            length: Int64(data.count) + 1
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
    }

    func lyricsSidecarTarget(for song: Song) async throws -> LyricsSidecarTarget {
        let source = try await resolveSelectionPath(for: song.filePath)
        let directory = (source.relativePath as NSString).deletingLastPathComponent
        let baseName = ((source.relativePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let existingItems = try await listDirectory(
            exportPath: source.exportPath,
            relativePath: directory.isEmpty ? "/" : directory
        )

        let existing = try LyricsSidecarTargetPolicy.uniqueExistingItem(
            baseName: baseName,
            in: existingItems
        )
        let fileName = existing?.name ?? "\(baseName).lrc"
        let relativePath = ((directory.isEmpty ? "/" : directory) as NSString)
            .appendingPathComponent(fileName)
        let targetPath = NFSSelectionPathCodec.makeSelectionPath(
            exportPath: source.exportPath,
            relativePath: relativePath
        )
        let containerPath = NFSSelectionPathCodec.makeSelectionPath(
            exportPath: source.exportPath,
            relativePath: directory.isEmpty ? "/" : directory
        )
        return LyricsSidecarTarget(
            targetPath: targetPath,
            fileName: fileName,
            containerPath: containerPath,
            exists: existing != nil,
            existingPath: existing?.path,
            existingSize: existing?.size
        )
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let selection = try await resolveSelectionPath(for: path)
        let activeClient = try await ensureConnected(to: selection.exportPath)
        return try await remoteState(for: selection, using: activeClient)
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        let selection = try await resolveSelectionPath(for: path)
        let activeClient = try await ensureConnected(to: selection.exportPath)
        let stagingPath = Self.stagingPath(for: selection.relativePath)
        do {
            try await activeClient.upload(localURL: localURL, to: stagingPath)
            let current = try await remoteState(for: selection, using: activeClient)
            guard expected.matches(current) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            // NFS RENAME replaces an existing non-directory destination in one
            // server operation, so readers never observe a partially uploaded
            // audio object.
            try await activeClient.rename(path: stagingPath, to: selection.relativePath)
        } catch {
            try? await activeClient.remove(path: stagingPath)
            throw error
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        guard let cacheName = NFSSelectionPathCodec.cacheFileName(for: path) else { return }
        localFileTasks[cacheName]?.cancel()
        localFileTasks[cacheName] = nil
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(cacheName)
        )
    }

    /// NFSv3/v4 都通过 libnfs 执行 NFS_READ (offset + count)，协议级支持
    /// 任意 offset 读取，让 CloudPlaybackSource 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        let selection = try await resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        // offset < 0 表示从末尾倒数，先 stat 拿 size 转正。
        let actualRange: Range<Int64>
        if offset < 0 {
            // 区分"大小拿不到"与"0 字节文件": 前者无法换算 suffix range,
            // 返回空会被回填误判为"无尾部标签"而静默丢标签, 应抛错。
            let total = try await client.fileSize(path: selection.relativePath)
            let start = max(0, total + offset)
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: start, length: length) else {
                return Data()
            }
            let end = min(total, requestedEnd)
            guard start < end else { return Data() }
            actualRange = start..<end
        } else {
            guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            actualRange = offset..<end
        }

        return try await client.read(
            path: selection.relativePath,
            offset: actualRange.lowerBound,
            length: actualRange.upperBound - actualRange.lowerBound
        )
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { try? handle.close() }

                    while true {
                        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if data.isEmpty {
                            break
                        }
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
                    try await scanDirectory(at: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func scanDirectory(
        at path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let items = try await listFiles(at: path)
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)

        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try await scanDirectory(at: item.path, continuation: continuation)
                continue
            }

            if let scannable = SidecarHintResolver.scannableItem(
                item,
                index: sidecarIndex
            ) {
                continuation.yield(scannable)
            }
        }
    }

    private func resolveClient() throws -> any NFSClientBackend {
        if let client {
            return client
        }

        let version = nfsVersion.connectionAttemptOrder[0]
        let client = try makeClient(version: version)
        self.client = client
        self.activeVersion = version
        return client
    }

    private func makeClient(version: NFSVersion) throws -> any NFSClientBackend {
        if version == .v4 {
            return NFSv4ClientBackend(host: host, port: port, sourceID: sourceID)
        }

        // IPv6 addresses must be wrapped in brackets for URL construction
        let urlHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = urlHost

        // NFSKit appends URL ports to the hostname before rpcbind lookup,
        // producing an unresolvable `host:port` address. NFSv3 discovers its
        // MOUNT and NFS service ports through rpcbind; only the v4 backend
        // above applies the explicitly configured NFS port directly.

        guard let url = components.url else {
            throw SourceError.connectionFailed("Invalid NFS host")
        }

        return try NFSKitClientBackend(url: url)
    }

    private func loadExports(forceRefresh: Bool = false) async throws -> [String] {
        if forceRefresh == false, let cachedExports, cachedExports.isEmpty == false {
            return cachedExports
        }

        let activeClient = try resolveClient()
        let exports: [String]
        do {
            let loaded = try await listExportsWithRecovery(startingWith: activeClient)
            guard loaded.isEmpty == false else {
                throw SourceError.connectionFailed("No NFS exports found")
            }
            exports = loaded
        } catch {
            let originalError = error
            let candidate: NFSFallbackCandidate
            do {
                candidate = try makeFallbackCandidateForAuto(after: originalError)
            } catch {
                await invalidateActiveClient()
                throw originalError
            }
            do {
                let loaded = try await discoverExports(
                    using: candidate.client,
                    version: candidate.version
                )
                guard loaded.isEmpty == false else {
                    throw SourceError.connectionFailed("No NFS exports found")
                }
                await commitFallback(
                    candidate,
                    connectedTo: candidate.version == .v4 ? "/" : nil
                )
                exports = loaded
            } catch {
                await candidate.client.disconnect()
                await invalidateActiveClient()
                throw error
            }
        }

        let normalizedExports = exports
            .compactMap { exportPath -> String? in
                let scope = RemotePathScopePolicy(rootPath: exportPath)
                return scope.matchesRoot(exportPath) ? scope.rootPath : nil
            }
            .sorted { $0.localizedCompare($1) == .orderedAscending }

        if normalizedExports.isEmpty {
            throw SourceError.connectionFailed("No NFS exports found")
        }

        cachedExports = normalizedExports
        return normalizedExports
    }

    private func ensureConnected(to exportPath: String) async throws -> any NFSClientBackend {
        var activeClient = try resolveClient()
        let normalizedExportPath = NFSSelectionPathCodec.normalizedExportPath(exportPath)

        if connectedExportPath == normalizedExportPath {
            return activeClient
        }

        if connectedExportPath != nil {
            await activeClient.disconnect()
            self.connectedExportPath = nil
        }

        do {
            try await activeClient.connect(exportPath: normalizedExportPath)
        } catch {
            let candidate = try makeFallbackCandidateForAuto(after: error)
            do {
                try await candidate.client.connect(exportPath: normalizedExportPath)
                await commitFallback(candidate, connectedTo: normalizedExportPath)
                activeClient = candidate.client
            } catch {
                await candidate.client.disconnect()
                throw error
            }
        }

        connectedExportPath = normalizedExportPath
        return activeClient
    }

    private func makeFallbackCandidateForAuto(after originalError: any Error) throws -> NFSFallbackCandidate {
        guard let activeVersion,
              let fallbackVersion = nfsVersion.fallbackVersion(after: activeVersion) else {
            throw originalError
        }

        return NFSFallbackCandidate(
            version: fallbackVersion,
            client: try makeClient(version: fallbackVersion)
        )
    }

    private func commitFallback(
        _ candidate: NFSFallbackCandidate,
        connectedTo exportPath: String? = nil
    ) async {
        let previousClient = client
        let previousVersion = activeVersion

        client = candidate.client
        activeVersion = previousVersion?.versionAfterFallback(
            to: candidate.version,
            succeeded: true
        ) ?? candidate.version
        connectedExportPath = exportPath
        cachedExports = nil

        await previousClient?.disconnect()
    }

    private func resolveSelectionPath(
        for path: String
    ) async throws -> NFSSelectionPathCodec.SelectionPath {
        if path.hasPrefix("nfs::") {
            let selection = try NFSSelectionPathCodec.parse(
                path,
                constrainedToExport: configuredExportPath
            )
            if configuredExportPath == nil {
                let allowedExports = try await loadExports()
                guard allowedExports.contains(where: {
                    RemotePathScopePolicy(rootPath: $0).matchesRoot(selection.exportPath)
                }) else {
                    throw SourceError.pathNotFound(path)
                }
            }
            return selection
        }

        if let configuredExportPath {
            guard let relativePath = RemotePathScopePolicy(rootPath: "/")
                .resolvedPath(forStoredPath: path) else {
                throw SourceError.pathNotFound(path)
            }
            return .init(
                exportPath: configuredExportPath,
                relativePath: relativePath
            )
        }

        throw SourceError.pathNotFound(path)
    }

    /// Generic sidecar naming operates on Song.filePath. NFS stores that path
    /// as an opaque selection token, so translate the synthetic suffix back to
    /// a real sibling path before uploading the file.
    private func sidecarAwareWriteSelection(
        for path: String
    ) async throws -> NFSSelectionPathCodec.SelectionPath {
        let suffixes = ["-cover.jpg", ".lrc"]
        if let suffix = suffixes.first(where: { path.hasSuffix($0) }) {
            let sourcePath = String(path.dropLast(suffix.count))
            let source = try await resolveSelectionPath(for: sourcePath)
            let directory = (source.relativePath as NSString).deletingLastPathComponent
            let baseName = ((source.relativePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            return .init(
                exportPath: source.exportPath,
                relativePath: ((directory.isEmpty ? "/" : directory) as NSString)
                    .appendingPathComponent(baseName + suffix)
            )
        }
        return try await resolveSelectionPath(for: path)
    }

    private func listDirectory(
        exportPath: String,
        relativePath: String
    ) async throws -> [RemoteFileItem] {
        var completedRetryAttempts = 0

        while true {
            do {
                let activeClient = try await ensureConnected(to: exportPath)
                try Task.checkCancellation()
                let entries = try await activeClient.listDirectory(path: relativePath)
                try Task.checkCancellation()
                return entries
                    .compactMap { entry in
                        guard let normalizedPath = RemotePathScopePolicy(rootPath: "/")
                            .resolvedPath(forStoredPath: entry.path) else {
                            return nil
                        }
                        return RemoteFileItem(
                            name: entry.name,
                            path: NFSSelectionPathCodec.makeSelectionPath(
                                exportPath: exportPath,
                                relativePath: normalizedPath
                            ),
                            isDirectory: entry.isDirectory,
                            size: entry.size,
                            modifiedDate: entry.modifiedDate,
                            revision: Self.fileRevision(
                                size: entry.size,
                                modifiedDate: entry.modifiedDate
                            )
                        )
                    }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            } catch {
                if OperationCancellationPolicy.isCancellation(error) {
                    await invalidateActiveClient()
                    throw CancellationError()
                }

                let outcome: RemoteDirectoryListingOutcome = Self.isPermanentDirectoryError(error)
                    ? .permanentFailure
                    : .retryableFailure
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    emptyNeedsFreshConfirmation: false
                ) {
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    try await replaceActiveClientPreservingVersion()
                case .accept:
                    assertionFailure("A directory error cannot be accepted")
                    throw error
                case .fail:
                    if outcome == .retryableFailure {
                        await invalidateActiveClient()
                        throw SourceError.connectionFailed(error.localizedDescription)
                    }
                    throw error
                }
            }
        }
    }

    private func remoteState(
        for selection: NFSSelectionPathCodec.SelectionPath,
        using client: any NFSClientBackend
    ) async throws -> EmbeddedMetadataRemoteFileState {
        let relativePath = NFSSelectionPathCodec.normalizedRelativePath(selection.relativePath)
        let parent = (relativePath as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "/" : parent
        guard let entry = try await client.listDirectory(path: directory).first(where: {
            NFSSelectionPathCodec.normalizedRelativePath($0.path) == relativePath
        }), !entry.isDirectory else {
            throw SourceError.fileNotFound(selection.relativePath)
        }
        return EmbeddedMetadataRemoteFileState(
            fileSize: entry.size,
            modifiedDate: entry.modifiedDate,
            revision: Self.fileRevision(size: entry.size, modifiedDate: entry.modifiedDate)
        )
    }

    private nonisolated static func stagingPath(for path: String) -> String {
        let normalized = NFSSelectionPathCodec.normalizedRelativePath(path)
        let directory = (normalized as NSString).deletingLastPathComponent
        let fileName = (normalized as NSString).lastPathComponent
        let stagingName = ".\(fileName).primuse-writeback-\(UUID().uuidString)"
        return ((directory.isEmpty ? "/" : directory) as NSString)
            .appendingPathComponent(stagingName)
    }

    private nonisolated static func fileRevision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "nfs:\(size):\(Int64(modifiedDate.timeIntervalSince1970 * 1_000_000))"
    }

    private func listExportsWithRecovery(
        startingWith initialClient: any NFSClientBackend
    ) async throws -> [String] {
        var activeClient = initialClient
        var completedRetryAttempts = 0

        while true {
            do {
                try Task.checkCancellation()
                let version = activeVersion ?? nfsVersion.connectionAttemptOrder[0]
                let exports = try await discoverExports(
                    using: activeClient,
                    version: version
                )
                if version == .v4 {
                    connectedExportPath = "/"
                }
                try Task.checkCancellation()
                return exports
            } catch {
                if OperationCancellationPolicy.isCancellation(error) {
                    await invalidateActiveClient()
                    throw CancellationError()
                }
                let outcome: RemoteDirectoryListingOutcome = Self.isPermanentDirectoryError(error)
                    ? .permanentFailure
                    : .retryableFailure
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    emptyNeedsFreshConfirmation: false
                ) {
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    activeClient = try await replaceActiveClientPreservingVersion()
                case .accept:
                    assertionFailure("An export-list error cannot be accepted")
                    throw error
                case .fail:
                    // Keep the attempted version long enough for loadExports
                    // to choose the configured automatic protocol fallback.
                    throw error
                }
            }
        }
    }

    private func discoverExports(
        using client: any NFSClientBackend,
        version: NFSVersion
    ) async throws -> [String] {
        let exports = try await client.listExports()
        if version == .v4 {
            // NFSv4 has no MOUNT export enumeration; its backend's ["/"] is
            // synthetic. Mount and enumerate the pseudo-root so it cannot be
            // mistaken for a successful network preflight while offline.
            try await client.connect(exportPath: "/")
            _ = try await client.listDirectory(path: "/")
        }
        return exports
    }

    @discardableResult
    private func replaceActiveClientPreservingVersion() async throws -> any NFSClientBackend {
        let version = activeVersion ?? nfsVersion.connectionAttemptOrder[0]
        let staleClient = client
        client = nil
        activeVersion = nil
        connectedExportPath = nil
        cachedExports = nil
        await staleClient?.disconnect()

        let replacement = try makeClient(version: version)
        client = replacement
        activeVersion = version
        return replacement
    }

    private func invalidateActiveClient() async {
        let staleClient = client
        client = nil
        activeVersion = nil
        connectedExportPath = nil
        cachedExports = nil
        await staleClient?.disconnect()
    }

    private nonisolated static func isPermanentDirectoryError(_ error: Error) -> Bool {
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable, .pathNotFound, .fileNotFound:
                return true
            case .connectionFailed, .timeout:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && [Int(EACCES), Int(EPERM), Int(ENOENT)].contains(nsError.code)
    }

}
