import Foundation
import AMSMB2
import PrimuseKit

/// AMSMB2 wraps one mutable libsmb2 context. Swift actor isolation alone is
/// not sufficient here because every AMSMB2 call suspends: while one call is
/// awaiting I/O, another actor entry can disconnect or replace that same C
/// context. Keep the complete request/retry lifecycle mutually exclusive.
private actor SMBOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor SMBSource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter, PathFileRenameConnector {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    private let host: String
    private let port: Int
    private let sharePath: String
    private let username: String
    private let password: String
    private var client: SMB2Manager?
    private var connectedShareName: String?
    private let operationGate = SMBOperationGate()
    /// Playback prefetch uses a separate libsmb2 context/TCP session. AMSMB2
    /// serializes each context, so sharing the foreground context made a slow
    /// 1 MB prefetch block decoder reads long enough to underrun.
    private var backgroundClient: SMB2Manager?
    private var backgroundConnectedShareName: String?
    private let backgroundOperationGate = SMBOperationGate()
    private let cacheDirectory: URL

    private enum ResolvedPath {
        case serverRoot
        case share(name: String, relativePath: String)
    }

    init(sourceID: String, host: String, port: Int = 445, sharePath: String, username: String, password: String) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.sharePath = Self.normalizeShareName(sharePath)
        self.username = username
        self.password = password

        // Per-source cache dir avoids file-name collisions when two SMB sources
        // happen to expose files with the same path.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_smb_cache")
            .appendingPathComponent(sourceID)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: sourceID))
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    deinit {
        // Releasing a still connected session makes AMSMB2 log off
        // synchronously on whichever thread lets go of it. Nothing is in
        // flight on the sessions held here (busy ones are retired), so give
        // that goodbye AMSMB2's old bounded wait instead of `libraryTimeout`.
        client?.timeout = RemoteRequestDeadline.standardStallTimeout
        backgroundClient?.timeout = RemoteRequestDeadline.standardStallTimeout
    }

    func connect() async throws {
        try await runWithRetry {
            if self.sharePath.isEmpty == false {
                _ = try await self.ensureConnectedShare(named: self.sharePath)
            } else {
                _ = try await self.rawListShares()
            }
        }
    }

    func disconnect() async {
        await operationGate.acquire()
        await backgroundOperationGate.acquire()
        if let client, connectedShareName != nil {
            await Self.closeShare(on: client, lane: "foreground")
        }
        if let backgroundClient, backgroundConnectedShareName != nil {
            await Self.closeShare(on: backgroundClient, lane: "background")
        }
        connectedShareName = nil
        client = nil
        backgroundConnectedShareName = nil
        backgroundClient = nil
        await backgroundOperationGate.release()
        await operationGate.release()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let normalizedPath = Self.normalizeRemotePath(path)

        switch try resolve(path: normalizedPath) {
        case .serverRoot:
            let shares = try await runWithRetry { try await self.rawListShares() }
            return shares
                .filter { Self.isUserVisibleShare($0.name) }
                .map { share in
                    RemoteFileItem(
                        name: share.name,
                        path: Self.appendPathComponent(share.name, to: normalizedPath),
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        case .share(let shareName, let relativePath):
            // Convert raw entries to Sendable RemoteFileItem inside the retry block —
            // the AMSMB2 dictionaries contain `Any` values that can't cross the closure boundary.
            return try await runWithRetry {
                let client = try await self.ensureConnectedShare(named: shareName)
                return try await Self.awaitRequest(stallTimeout: RemoteRequestDeadline.listingStallTimeout) { _ in
                    let items = try await client.contentsOfDirectory(atPath: relativePath)
                    return items
                        .filter { Self.isUserVisibleEntry(($0[.nameKey] as? String) ?? "") }
                        .map { item -> RemoteFileItem in
                            let name = item[.nameKey] as? String ?? ""
                            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                            let size = item[.fileSizeKey] as? Int64 ?? 0
                            let modified = item[.contentModificationDateKey] as? Date
                            return RemoteFileItem(
                                name: name,
                                path: Self.appendPathComponent(name, to: normalizedPath),
                                isDirectory: isDir,
                                size: size,
                                modifiedDate: modified,
                                revision: Self.fileRevision(size: size, modifiedDate: modified)
                            )
                        }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    func localURL(for path: String) async throws -> URL {
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)

        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        let localURL = cacheDirectory.appendingPathComponent(
            Self.cacheFileName(for: normalizedPath)
        )

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Download to a sibling temp path then atomically rename. If the download
        // is cancelled or the connection drops mid-stream we don't want a half-written
        // file lingering at `localURL` that future calls will think is complete.
        let tempURL = cacheDirectory.appendingPathComponent(
            "\(Self.cacheFileName(for: normalizedPath)).part-\(UUID().uuidString)"
        )

        do {
            try await runWithRetry {
                let client = try await self.ensureConnectedShare(named: shareName)
                try await Self.awaitRequest { activity in
                    try await client.downloadItem(atPath: relativePath, to: tempURL) { _, _ in
                        activity.noteProgress()
                    }
                }
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return localURL
    }

    /// SMB2 READ command via AMSMB2's `contents(atPath:range:)`。底层是 libsmb2
     /// 的 SMB2 READ (8-byte offset), 协议级支持 byte range, 让 CloudPlaybackSource
     /// 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await fetchRange(
            path: path,
            offset: offset,
            length: length,
            priority: .userInitiated
        )
    }

    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority: RangeFetchPriority
    ) async throws -> Data {
        guard length > 0 else { return Data() }
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)
        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        switch priority {
        case .userInitiated:
            return try await runWithRetry {
                let client = try await self.ensureConnectedShare(named: shareName)
                return try await self.readRange(
                    client: client,
                    relativePath: relativePath,
                    offset: offset,
                    length: length
                )
            }
        case .background:
            return try await runBackgroundWithRetry {
                let client = try await self.ensureBackgroundConnectedShare(
                    named: shareName
                )
                return try await self.readRange(
                    client: client,
                    relativePath: relativePath,
                    offset: offset,
                    length: length
                )
            }
        }
    }

    private func readRange(
        client: SMB2Manager,
        relativePath: String,
        offset: Int64,
        length: Int64
    ) async throws -> Data {
        // offset < 0 表示从文件末尾倒数 (suffix range), AMSMB2 的
        // RangeExpression 接受 UInt64 所以负 offset 需要先拿 fileSize 转换。
        if offset < 0 {
            let attrs = try await Self.awaitRequest { _ in
                try await client.attributesOfItem(atPath: relativePath)
            }
            guard let total = (attrs[.fileSizeKey] as? Int64)
                    ?? (attrs[.fileSizeKey] as? Int).map({ Int64($0) }) else {
                throw SourceError.fileNotFound(relativePath)
            }
            let start = max(0, total + offset)
            guard let requestedEnd = SafeByteRange.exclusiveEnd(
                offset: start,
                length: length
            ) else {
                return Data()
            }
            let end = min(total, requestedEnd)
            guard start < end else { return Data() }
            return try await Self.readContents(
                client: client,
                relativePath: relativePath,
                range: UInt64(start)..<UInt64(end)
            )
        }
        guard let end = SafeByteRange.exclusiveEnd(
            offset: offset,
            length: length
        ) else {
            return Data()
        }
        return try await Self.readContents(
            client: client,
            relativePath: relativePath,
            range: UInt64(offset)..<UInt64(end)
        )
    }

    /// The read closes its file handle inside the same AMSMB2 call, which is
    /// where a reply to an abandoned read used to land (see
    /// `RemoteRequestDeadline`). Every completed chunk counts as progress.
    private static func readContents(
        client: SMB2Manager,
        relativePath: String,
        range: Range<UInt64>
    ) async throws -> Data {
        try await awaitRequest { activity in
            try await client.contents(
                atPath: relativePath,
                range: range,
                progress: { _, _ in activity.noteProgress() }
            )
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { try? handle.close() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = try handle.read(upToCount: chunkSize) ?? Data()
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
        return AsyncThrowingStream { continuation in
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

    func writeFile(data: Data, to path: String) async throws {
        try await writeFile(data: data, to: path, priority: .userInitiated)
    }

    func writeFile(
        data: Data,
        to path: String,
        priority: RangeFetchPriority
    ) async throws {
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)

        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb_upload_\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        switch priority {
        case .userInitiated:
            try await runWithRetry {
                let client = try await self.ensureConnectedShare(named: shareName)
                try await self.uploadOrOverwrite(
                    client: client,
                    localURL: tempURL,
                    data: data,
                    relativePath: relativePath
                )
            }
        case .background:
            try await runBackgroundWithRetry {
                let client = try await self.ensureBackgroundConnectedShare(named: shareName)
                try await self.uploadOrOverwrite(
                    client: client,
                    localURL: tempURL,
                    data: data,
                    relativePath: relativePath
                )
            }
        }
    }

    func moveFileWithoutReplacing(from: String, to: String, expected: EmbeddedMetadataRemoteFileState) async throws {
        guard (from as NSString).deletingLastPathComponent == (to as NSString).deletingLastPathComponent,
              case let .share(share, sourcePath) = try resolve(path: Self.normalizeRemotePath(from)),
              case let .share(destinationShare, destinationPath) = try resolve(path: Self.normalizeRemotePath(to)),
              share == destinationShare else { throw SongFileRenameError.unsupported }
        try await withSerializedOperation {
            let client = try await self.ensureConnectedShare(named: share)
            let attributes = try await Self.awaitRequest { _ in
                try await client.attributesOfItem(atPath: sourcePath)
            }
            let size = (attributes[.fileSizeKey] as? Int64) ?? (attributes[.fileSizeKey] as? Int).map(Int64.init) ?? 0
            let modified = attributes[.contentModificationDateKey] as? Date
            let current = EmbeddedMetadataRemoteFileState(fileSize: size, modifiedDate: modified,
                revision: Self.fileRevision(size: size, modifiedDate: modified))
            guard expected.matches(current) else { throw EmbeddedMetadataWritebackSourceError.conflict }
            try await Self.awaitRequest { _ in
                try await client.moveItem(atPath: sourcePath, toPath: destinationPath)
            }
        }
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let normalizedPath = Self.normalizeRemotePath(path)
        guard case let .share(shareName, relativePath) = try resolve(path: normalizedPath) else {
            throw SourceError.connectionFailed("SMB share not selected")
        }
        return try await runWithRetry {
            let client = try await self.ensureConnectedShare(named: shareName)
            let attributes = try await Self.awaitRequest { _ in
                try await client.attributesOfItem(atPath: relativePath)
            }
            let size = (attributes[.fileSizeKey] as? Int64)
                ?? (attributes[.fileSizeKey] as? Int).map(Int64.init)
                ?? 0
            let modifiedDate = attributes[.contentModificationDateKey] as? Date
            return EmbeddedMetadataRemoteFileState(
                fileSize: size,
                modifiedDate: modifiedDate,
                revision: Self.fileRevision(size: size, modifiedDate: modifiedDate)
            )
        }
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        let normalizedPath = Self.normalizeRemotePath(path)
        guard case let .share(shareName, relativePath) = try resolve(path: normalizedPath) else {
            throw SourceError.connectionFailed("SMB share not selected")
        }
        try await withSerializedOperation {
            let client = try await self.ensureConnectedShare(named: shareName)
            let directory = (relativePath as NSString).deletingLastPathComponent
            let fileName = (relativePath as NSString).lastPathComponent
            let nonce = UUID().uuidString
            let stagingName = ".\(fileName).primuse-writeback-\(nonce)"
            let backupName = ".\(fileName).primuse-backup-\(nonce)"
            let stagingPath = ((directory.isEmpty ? "/" : directory) as NSString)
                .appendingPathComponent(stagingName)
            let backupPath = ((directory.isEmpty ? "/" : directory) as NSString)
                .appendingPathComponent(backupName)

            var originalMoved = false
            do {
                try await Self.awaitRequest { activity in
                    try await client.uploadItem(at: localURL, toPath: stagingPath) { _ in
                        activity.noteProgress()
                    }
                }
                let attributes = try await Self.awaitRequest { _ in
                    try await client.attributesOfItem(atPath: relativePath)
                }
                let size = (attributes[.fileSizeKey] as? Int64)
                    ?? (attributes[.fileSizeKey] as? Int).map(Int64.init)
                    ?? 0
                let modifiedDate = attributes[.contentModificationDateKey] as? Date
                let current = EmbeddedMetadataRemoteFileState(
                    fileSize: size,
                    modifiedDate: modifiedDate,
                    revision: Self.fileRevision(size: size, modifiedDate: modifiedDate)
                )
                guard expected.matches(current) else {
                    throw EmbeddedMetadataWritebackSourceError.conflict
                }

                // libsmb2's public rename intentionally refuses to replace an
                // existing target. Move the original to a recoverable
                // same-folder backup, publish the fully uploaded staging file,
                // then remove the backup.
                try await Self.awaitRequest { _ in
                    try await client.moveItem(atPath: relativePath, toPath: backupPath)
                }
                originalMoved = true
                do {
                    try await Self.awaitRequest { _ in
                        try await client.moveItem(atPath: stagingPath, toPath: relativePath)
                    }
                    originalMoved = false
                } catch {
                    // A publish that ran out of time may still be carried out,
                    // and its session is still busy with it, so no restore can
                    // be sent on that session.
                    if Self.isAbandonedRequest(error) {
                        self.retireClientIfRequestAbandoned(error)
                        throw SourceError.connectionFailed(
                            "SMB publish did not finish and the original remains at \(backupPath): \(error.localizedDescription)"
                        )
                    }
                    do {
                        try await Self.awaitRequest { _ in
                            try await client.moveItem(atPath: backupPath, toPath: relativePath)
                        }
                        originalMoved = false
                    } catch let restoreError {
                        self.retireClientIfRequestAbandoned(restoreError)
                        throw SourceError.connectionFailed(
                            "SMB publish failed and the original remains at \(backupPath): \(restoreError.localizedDescription)"
                        )
                    }
                    throw error
                }
                do {
                    try await Self.awaitRequest { _ in
                        try await client.removeFile(atPath: backupPath)
                    }
                } catch {
                    self.retireClientIfRequestAbandoned(error)
                    // Publication is already complete; a hidden recovery copy
                    // is preferable to reporting a failed write and retrying it.
                    plog("⚠️ SMB metadata writeback left recovery backup at \(backupPath): \(error.localizedDescription)")
                }
            } catch {
                // This path never went through the retrying wrapper, so it has
                // to retire a session left mid-request itself, before any
                // clean-up could send another request on it.
                self.retireClientIfRequestAbandoned(error)
                if !originalMoved, self.client === client {
                    do {
                        try await Self.awaitRequest { _ in
                            try await client.removeFile(atPath: stagingPath)
                        }
                    } catch {
                        self.retireClientIfRequestAbandoned(error)
                    }
                }
                throw error
            }
        }
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        let normalizedPath = Self.normalizeRemotePath(path)
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(Self.cacheFileName(for: normalizedPath))
        )
    }

    /// AMSMB2's `uploadItem` intentionally uses create-exclusive semantics,
    /// so writing a scraped sidecar for a second time fails with EEXIST /
    /// STATUS_OBJECT_NAME_COLLISION. Create first to keep the normal path
    /// efficient, then use the library's offset-zero write API to truncate and
    /// replace an existing file on that same serialized SMB connection.
    private func uploadOrOverwrite(
        client: SMB2Manager,
        localURL: URL,
        data: Data,
        relativePath: String
    ) async throws {
        do {
            try await Self.awaitRequest { activity in
                try await client.uploadItem(at: localURL, toPath: relativePath) { _ in
                    activity.noteProgress()
                }
            }
        } catch {
            if let denial = MetadataWriteFailurePolicy.denial(error) { throw denial }
            let nsError = error as NSError
            guard nsError.domain == NSPOSIXErrorDomain,
                  nsError.code == Int(EEXIST) else {
                throw error
            }
            do {
                try await Self.awaitRequest { activity in
                    try await client.append(data: data, toPath: relativePath, offset: 0, progress: { _ in
                        activity.noteProgress()
                    })
                }
            } catch {
                throw MetadataWriteFailurePolicy.denial(error) ?? error
            }
        }
    }

    private nonisolated static func fileRevision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "smb:\(size):\(Int64(modifiedDate.timeIntervalSince1970 * 1_000))"
    }

    func deleteFile(at path: String) async throws {
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)

        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        try await runWithRetry {
            let client = try await self.ensureConnectedShare(named: shareName)
            do {
                try await Self.awaitRequest { _ in
                    try await client.removeItem(atPath: relativePath)
                }
            } catch {
                let ns = error as NSError
                if ns.domain == NSPOSIXErrorDomain {
                    switch ns.code {
                    case Int(ENOENT): throw SourceError.fileNotFound(normalizedPath)
                    case Int(EACCES), Int(EPERM): throw SourceFileMutationError.permissionDenied
                    case Int(EROFS): throw SourceFileMutationError.readOnly
                    default: break
                    }
                }
                throw error
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

    private func ensureServerConnection() async throws -> SMB2Manager {
        if let client {
            return client
        }

        let client = try makeClient(lane: "foreground")
        self.client = client
        return client
    }

    private func ensureBackgroundServerConnection() async throws -> SMB2Manager {
        if let backgroundClient {
            return backgroundClient
        }

        let client = try makeClient(lane: "background")
        self.backgroundClient = client
        return client
    }

    private func makeClient(lane: String) throws -> SMB2Manager {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL = try Self.buildSMBUrl(host: trimmedHost, port: port)
        plog("ℹ️ SMB \(lane) connecting to \(serverURL.absoluteString) (original host: \(trimmedHost))")

        let cleanUser = NetworkCredentialPolicy.username(username)
        let cleanPassword = NetworkCredentialPolicy.password(password)
        if cleanUser.count != username.count {
            plog("⚠️ SMB username trimmed surrounding whitespace: \(username.count)→\(cleanUser.count)")
        }

        // AMSMB2/libsmb2 的访客登录约定是 guest + 空密码。直接传空用户名在部分
        // Samba / NAS 上会被当成缺失凭据而拒绝，而不是映射到 guest account。
        let isGuest = cleanUser.isEmpty && cleanPassword.isEmpty
        let credential = URLCredential(
            user: isGuest ? "guest" : cleanUser,
            password: cleanPassword,
            persistence: .forSession
        )

        guard let client = SMB2Manager(url: serverURL, credential: credential) else {
            throw SourceError.connectionFailed("Invalid SMB server configuration")
        }
        // AMSMB2 must never be the one that gives up on a request; every call
        // goes through `awaitRequest`, which applies the real deadline.
        client.timeout = RemoteRequestDeadline.libraryTimeout
        return client
    }

    private func ensureConnectedShare(named shareName: String) async throws -> SMB2Manager {
        let normalizedShareName = Self.normalizeShareName(shareName)
        guard normalizedShareName.isEmpty == false else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        try Task.checkCancellation()
        let client = try await ensureServerConnection()
        if connectedShareName == normalizedShareName {
            return client
        }

        // libsmb2 keeps a single tree-connect per session, so switching shares
        // requires explicitly disconnecting the previous one first.
        if connectedShareName != nil {
            connectedShareName = nil
            do {
                try await Self.awaitRequest { _ in try await client.disconnectShare() }
            } catch {
                // A failed disconnect is otherwise harmless, but a session
                // left mid-request must not carry the next connect.
                if Self.isAbandonedRequest(error) {
                    retireClientIfRequestAbandoned(error)
                    throw error
                }
            }
        }

        do {
            try await Self.awaitRequest { _ in
                try await client.connectShare(name: normalizedShareName)
            }
            try Task.checkCancellation()
        } catch {
            retireClientIfRequestAbandoned(error)
            await invalidateConnection()
            throw error
        }
        connectedShareName = normalizedShareName
        return client
    }

    private func ensureBackgroundConnectedShare(
        named shareName: String
    ) async throws -> SMB2Manager {
        let normalizedShareName = Self.normalizeShareName(shareName)
        guard normalizedShareName.isEmpty == false else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        try Task.checkCancellation()
        let client = try await ensureBackgroundServerConnection()
        if backgroundConnectedShareName == normalizedShareName {
            return client
        }
        if backgroundConnectedShareName != nil {
            backgroundConnectedShareName = nil
            do {
                try await Self.awaitRequest { _ in try await client.disconnectShare() }
            } catch {
                if Self.isAbandonedRequest(error) {
                    retireBackgroundClientIfRequestAbandoned(error)
                    throw error
                }
            }
        }
        do {
            try await Self.awaitRequest { _ in
                try await client.connectShare(name: normalizedShareName)
            }
            try Task.checkCancellation()
        } catch {
            retireBackgroundClientIfRequestAbandoned(error)
            await invalidateBackgroundConnection()
            throw error
        }
        backgroundConnectedShareName = normalizedShareName
        return client
    }

    private func rawListShares() async throws -> [(name: String, comment: String)] {
        try Task.checkCancellation()
        let client = try await ensureServerConnection()
        do {
            let shares = try await Self.awaitRequest { _ in try await client.listShares() }
            try Task.checkCancellation()
            return shares
        } catch {
            retireClientIfRequestAbandoned(error)
            await invalidateConnection()
            throw error
        }
    }

    /// Drop the cached client and tree-connect so the next call re-handshakes
    /// from scratch. Called when a request fails with a transient error.
    private func invalidateConnection() async {
        if let client, connectedShareName != nil {
            await Self.closeShare(on: client, lane: "foreground")
        }
        connectedShareName = nil
        client = nil
    }

    private func invalidateBackgroundConnection() async {
        if let backgroundClient, backgroundConnectedShareName != nil {
            await Self.closeShare(on: backgroundClient, lane: "background")
        }
        backgroundConnectedShareName = nil
        backgroundClient = nil
    }

    /// Ends the share on a session that is being dropped. A disconnect that
    /// does not finish in time leaves the session mid-request, so it is
    /// retired instead of released (see `SMBSessionDisposalPolicy`).
    private static func closeShare(on session: SMB2Manager, lane: String) async {
        do {
            try await awaitRequest { _ in try await session.disconnectShare() }
        } catch {
            if isAbandonedRequest(error) {
                retire(session, lane: lane)
            }
        }
    }

    /// Every AMSMB2 call goes through here. The session itself never gives up
    /// on a request (`RemoteRequestDeadline.libraryTimeout`); this stops waiting
    /// after AMSMB2's former 60 s of silence and reports `ETIMEDOUT`, and the
    /// callers' existing handling retires the still busy session.
    private static func awaitRequest<T: Sendable>(
        stallTimeout: TimeInterval = RemoteRequestDeadline.standardStallTimeout,
        _ operation: @escaping @Sendable (RemoteRequestDeadline.Activity) async throws -> T
    ) async throws -> T {
        try await RemoteRequestDeadline.run(stallTimeout: stallTimeout, operation: operation)
    }

    /// Stops using — without closing — a session whose request may still be
    /// queued inside libsmb2. Closing or releasing such a session is what turns
    /// the queued callback into a jump through a freed directory handle.
    private func retireClientIfRequestAbandoned(_ error: Error) {
        guard let client, Self.isAbandonedRequest(error) else { return }
        Self.retire(client, lane: "foreground")
        self.client = nil
        connectedShareName = nil
    }

    private func retireBackgroundClientIfRequestAbandoned(_ error: Error) {
        guard let backgroundClient, Self.isAbandonedRequest(error) else { return }
        Self.retire(backgroundClient, lane: "background")
        self.backgroundClient = nil
        backgroundConnectedShareName = nil
    }

    private static func retire(_ session: SMB2Manager, lane: String) {
        let held = RemoteRetiredSessions.shared.retire(session)
        plog("⚠️ SMB \(lane) session retired after an abandoned request (held: \(held))")
    }

    private static func isAbandonedRequest(_ error: Error) -> Bool {
        let nsError = error as NSError
        return SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }

    /// Run an SMB request, retrying once if the first attempt leaves the
    /// session unusable. Besides ordinary transport failures, AMSMB2 can emit
    /// ENODATA when a directory callback has no payload; a fresh session must
    /// be established before repeating that request.
    private func runWithRetry<T: Sendable>(
        _ block: () async throws -> T
    ) async throws -> T {
        try await withSerializedOperation {
            try await self.runWithRetryWhileLocked(block)
        }
    }

    private func runBackgroundWithRetry<T: Sendable>(
        _ block: () async throws -> T
    ) async throws -> T {
        try await withSerializedBackgroundOperation {
            var completedReconnectAttempts = 0
            while true {
                do {
                    try Task.checkCancellation()
                    return try await block()
                } catch is CancellationError {
                    await invalidateBackgroundConnection()
                    throw CancellationError()
                } catch {
                    retireBackgroundClientIfRequestAbandoned(error)
                    let nsError = error as NSError
                    guard SMBConnectionRecoveryPolicy.shouldReconnect(
                        errorDomain: nsError.domain,
                        errorCode: nsError.code,
                        completedReconnectAttempts: completedReconnectAttempts
                    ) else {
                        if completedReconnectAttempts > 0 {
                            await invalidateBackgroundConnection()
                        }
                        throw mapSMBError(error)
                    }
                    completedReconnectAttempts += 1
                    plog(
                        "⚠️ SMB background recoverable error "
                            + "\(nsError.domain)(\(nsError.code)), reconnecting: "
                            + nsError.localizedDescription
                    )
                    await invalidateBackgroundConnection()
                }
            }
        }
    }

    private func runWithRetryWhileLocked<T: Sendable>(
        _ block: () async throws -> T
    ) async throws -> T {
        var completedReconnectAttempts = 0
        while true {
            do {
                try Task.checkCancellation()
                return try await block()
            } catch is CancellationError {
                await invalidateConnection()
                throw CancellationError()
            } catch {
                retireClientIfRequestAbandoned(error)
                let nsError = error as NSError
                guard SMBConnectionRecoveryPolicy.shouldReconnect(
                    errorDomain: nsError.domain,
                    errorCode: nsError.code,
                    completedReconnectAttempts: completedReconnectAttempts
                ) else {
                    if completedReconnectAttempts > 0 {
                        await invalidateConnection()
                    }
                    throw mapSMBError(error)
                }
                completedReconnectAttempts += 1
                plog(
                    "⚠️ SMB foreground recoverable error "
                        + "\(nsError.domain)(\(nsError.code)), reconnecting: "
                        + nsError.localizedDescription
                )
                await invalidateConnection()
            }
        }
    }

    private func withSerializedOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await operationGate.acquire()
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func withSerializedBackgroundOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await backgroundOperationGate.acquire()
        do {
            let result = try await operation()
            await backgroundOperationGate.release()
            return result
        } catch {
            await backgroundOperationGate.release()
            throw error
        }
    }

    private nonisolated func mapSMBError(_ error: Error) -> Error {
        if error is CancellationError || SourceNetworkFailurePolicy.isNetworkFailure(error) {
            return error
        }
        if error is SourceError { return error }
        if error is SourceFileMutationError { return error }
        if error is EmbeddedMetadataWritebackSourceError { return error }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM):
                return SourceError.authenticationFailed
            case Int(ENOENT):
                return SourceError.connectionFailed(String(localized: "smb_error_not_found"))
            case Int(ENODATA):
                return SourceError.connectionFailed(
                    "SMB: \(String(localized: "source_diag_advice_invalid_response"))"
                )
            default: break
            }
        }
        return SourceError.connectionFailed("SMB: \(ns.localizedDescription)")
    }

    /// Hide system / administrative shares from the source picker. Hidden shares
    /// end with `$` (C$, ADMIN$, IPC$, print$ ...) — none of which contain
    /// user-browsable music files.
    private static func isUserVisibleShare(_ name: String) -> Bool {
        !name.hasSuffix("$")
    }

    private static func isUserVisibleEntry(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.hasPrefix(".") { return false }
        let lower = name.lowercased()
        if lower == "thumbs.db" { return false }
        if lower == "desktop.ini" { return false }
        return true
    }

    private func resolve(path: String) throws -> ResolvedPath {
        let normalizedPath = Self.normalizeRemotePath(path)

        if sharePath.isEmpty == false {
            let prefixedShareRoot = "/\(sharePath)"
            if normalizedPath == prefixedShareRoot {
                return .share(name: sharePath, relativePath: "/")
            }
            if normalizedPath.hasPrefix(prefixedShareRoot + "/") {
                let relativePath = String(normalizedPath.dropFirst(prefixedShareRoot.count))
                return .share(name: sharePath, relativePath: relativePath.isEmpty ? "/" : relativePath)
            }
            return .share(name: sharePath, relativePath: normalizedPath)
        }

        guard normalizedPath != "/" else {
            return .serverRoot
        }

        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard let shareName = components.first else {
            return .serverRoot
        }

        let relativeComponents = components.dropFirst()
        let relativePath = relativeComponents.isEmpty ? "/" : "/" + relativeComponents.joined(separator: "/")
        return .share(name: shareName, relativePath: relativePath)
    }

    private static func normalizeShareName(_ shareName: String) -> String {
        shareName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizeRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "/"
        }

        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.isEmpty == false else {
            return "/"
        }

        return "/" + components.joined(separator: "/")
    }

    private static func appendPathComponent(_ component: String, to path: String) -> String {
        let normalizedBase = normalizeRemotePath(path)
        let sanitizedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard sanitizedComponent.isEmpty == false else {
            return normalizedBase
        }

        if normalizedBase == "/" {
            return "/" + sanitizedComponent
        }

        return normalizedBase + "/" + sanitizedComponent
    }

    private static func cacheFileName(for path: String) -> String {
        CacheFileNamePolicy.make(path: normalizeRemotePath(path))
    }

    // MARK: - SMB URL Construction
    //
    // Supports hostname, IPv4, and IPv6. AMSMB2/libsmb2 has a bug where it
    // concatenates host:port as a flat string, breaking IPv6 (e.g. "::1:445").
    // Workaround: when the input is an IPv6 literal, resolve to IPv4 via
    // reverse-DNS → forward-DNS. If the host only has IPv6 (no IPv4 record),
    // pass the hostname (from reverse-DNS) so libsmb2 can resolve it natively.

    private static func buildSMBUrl(host: String, port: Int) throws -> URL {
        let isIPv4 = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        let isIPv6 = host.contains(":") && !isIPv4

        var connectHost = host

        if isIPv6 {
            if let hostname = reverseResolve(ipv6: host) {
                plog("ℹ️ SMB: Reverse DNS '\(host)' → '\(hostname)'")
                if let ipv4 = forwardResolveIPv4(hostname) {
                    plog("ℹ️ SMB: Resolved '\(hostname)' → '\(ipv4)'")
                    connectHost = ipv4
                } else {
                    plog("ℹ️ SMB: No IPv4 for '\(hostname)', using hostname directly")
                    connectHost = hostname
                }
            } else {
                plog("⚠️ SMB: Reverse DNS failed for '\(host)', using bracketed IPv6")
            }
        }

        let hostPart: String
        if connectHost.contains(":") {
            hostPart = "[\(connectHost)]"
        } else {
            hostPart = connectHost
        }

        let urlString = "smb://\(hostPart):\(port)"
        guard let url = URL(string: urlString) else {
            throw SourceError.connectionFailed("Invalid SMB URL: \(urlString)")
        }
        return url
    }

    private static func forwardResolveIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }

        guard status == 0, let addrInfo = result else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            addrInfo.pointee.ai_addr,
            socklen_t(addrInfo.pointee.ai_addrlen),
            &buf,
            socklen_t(buf.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else {
            return nil
        }

        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func reverseResolve(ipv6 address: String) -> String? {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getnameinfo(
                    sockPtr,
                    socklen_t(MemoryLayout<sockaddr_in6>.size),
                    &buf,
                    socklen_t(buf.count),
                    nil,
                    0,
                    0
                )
            }
        }
        guard rc == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.contains(":") ? nil : name
    }
}
