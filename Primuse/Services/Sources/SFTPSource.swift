@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import PrimuseKit

actor SFTPSource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true

    private let host: String
    private let port: Int
    private let basePath: String?
    private let username: String
    private let secret: String
    private let authType: SourceAuthType

    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var connectTask: Task<Void, Error>?
    private var rootPath: String = "/"
    private let cacheDirectory: URL

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        basePath: String? = nil,
        username: String,
        secret: String,
        authType: SourceAuthType
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port ?? 22
        self.basePath = basePath
        self.username = username
        self.secret = secret
        self.authType = authType

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_sftp_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    func connect() async throws {
        if let sftp, sftp.isActive {
            return
        }
        if sftp != nil || client != nil {
            await closeCurrentConnection()
        }
        if let connectTask {
            try await connectTask.value
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

        // 提前算好 auth method 再传给 SSHClientSettings 闭包,避免之前
        // `try! Self.authenticationMethod(...)` 那种"非确定性场景下崩 app"
        // 的雷:闭包签名是非 throws,旧写法只能 try!,如果中途 keychain
        // 变了 / 密钥文件被改, 重算就会 fatal。一次构建一次复用更稳。
        let authMethod = try Self.authenticationMethod(
            username: username,
            secret: secret,
            authType: authType
        )

        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(SFTPHostKeyValidator(host: host, port: port))
        )

        // NIOSSH defaults to AES-GCM only. Dropbear and other NAS SSH servers
        // commonly offer AES-CTR instead; add only the required compatibility
        // cipher rather than Citadel's broader `.all` legacy algorithm set.
        if SFTPTransportCompatibilityPolicy.connectionProfile == .aes128CTR {
            // Citadel exposes AES128CTR through `.all`; clear its extra KEX and
            // host-key additions so the existing Curve25519/Ed25519 defaults
            // remain mandatory. This also avoids the dependency's incorrect
            // Swift 6 Sendable annotation on the raw transport metatype array.
            var algorithms = SSHAlgorithms.all
            algorithms.keyExchangeAlgorithms = nil
            algorithms.publicKeyAlgorihtms = nil
            settings.algorithms = algorithms
        }

        let newClient: SSHClient
        do {
            plog("[SFTP] stage=connect endpoint=\(host):\(port)")
            newClient = try await SSHClient.connect(to: settings)
        } catch {
            plog(Self.connectionFailureLog(stage: "connect", error: error))
            throw Self.connectionError(error)
        }

        var stage = "open-sftp"
        do {
            plog("[SFTP] stage=\(stage) endpoint=\(host):\(port)")
            let newSFTP = try await newClient.openSFTP()
            stage = "resolve-root"
            let resolvedRoot = try await resolveRootPath(using: newSFTP)
            stage = "list-root"
            _ = try await newSFTP.listDirectory(atPath: resolvedRoot)
            try Task.checkCancellation()
            client = newClient
            sftp = newSFTP
            rootPath = resolvedRoot
            plog("[SFTP] stage=ready endpoint=\(host):\(port)")
        } catch {
            plog(Self.connectionFailureLog(stage: stage, error: error))
            try? await newClient.close()
            throw Self.connectionError(error)
        }
    }

    private nonisolated static func connectionFailureLog(
        stage: String,
        error: Error
    ) -> String {
        "[SFTP] stage=\(stage) failed type=\(String(reflecting: type(of: error))) detail=\(String(describing: error))"
    }

    private nonisolated static func connectionError(_ error: Error) -> Error {
        if error is AuthenticationFailed {
            return SourceError.authenticationFailed
        }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication,
                 .allAuthenticationOptionsFailed:
                return SourceError.authenticationFailed
            case .channelCreationFailed:
                break
            }
        }
        if let sshError = error as? NIOSSHError {
            if sshError.type == .keyExchangeNegotiationFailure {
                return SourceError.connectionFailed(
                    "SSH key exchange failed because the server and client have no compatible algorithms"
                )
            }
            return SourceError.connectionFailed("SSH protocol error: \(sshError.type.description)")
        }
        if let mismatch = error as? SFTPHostKeyMismatch {
            return SourceError.connectionFailed(
                "SSH host key changed for \(mismatch.host):\(mismatch.port)"
            )
        }
        return error
    }

    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        await closeCurrentConnection()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        var completedRetryAttempts = 0
        var previousAttemptWasEmpty = false

        while true {
            do {
                try await connect()
                guard let sftp else {
                    throw SourceError.connectionFailed("Not connected")
                }
                let remotePath = try resolvedRemotePath(for: path)
                let listings = try await sftp.listDirectory(atPath: remotePath)
                let allComponents = listings.flatMap { $0.components }
                let items = allComponents.compactMap { item -> RemoteFileItem? in
                    guard item.filename != ".", item.filename != ".." else { return nil }

                    guard let childPath = RemotePathScopePolicy(rootPath: rootPath)
                        .resolvedPath(forStoredPath: joinedPath(parent: remotePath, child: item.filename)) else {
                        return nil
                    }
                    let isDir = item.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
                    let modifiedDate = item.attributes.accessModificationTime?.modificationTime
                    let size = Int64(item.attributes.size ?? 0)
                    return RemoteFileItem(
                        name: item.filename,
                        path: childPath,
                        isDirectory: isDir,
                        size: size,
                        modifiedDate: modifiedDate,
                        revision: Self.fileRevision(size: size, modifiedDate: modifiedDate)
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                let outcome: RemoteDirectoryListingOutcome = items.isEmpty ? .empty : .populated
                switch RemoteDirectoryRecoveryPolicy.decision(
                    outcome: outcome,
                    completedRetryAttempts: completedRetryAttempts,
                    // Citadel collapses every terminal READDIR status into an
                    // empty result. Confirm emptiness on a new SSH connection.
                    emptyNeedsFreshConfirmation: true,
                    previousAttemptWasEmpty: previousAttemptWasEmpty
                ) {
                case .accept:
                    return items
                case .retryFreshConnection:
                    completedRetryAttempts += 1
                    previousAttemptWasEmpty = true
                    await closeCurrentConnection()
                case .fail:
                    await closeCurrentConnection()
                    throw SourceError.connectionFailed(
                        "SFTP directory returned an unconfirmed empty response"
                    )
                }
            } catch {
                if OperationCancellationPolicy.isCancellation(error) {
                    await closeCurrentConnection()
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
                    previousAttemptWasEmpty = false
                    await closeCurrentConnection()
                case .accept:
                    assertionFailure("A directory error cannot be accepted")
                    throw Self.connectionError(error)
                case .fail:
                    if outcome == .retryableFailure {
                        await closeCurrentConnection()
                    }
                    throw Self.connectionError(error)
                }
            }
        }
    }

    private func closeCurrentConnection() async {
        let staleSFTP = sftp
        let staleClient = client
        sftp = nil
        client = nil
        rootPath = "/"
        if let staleSFTP {
            try? await staleSFTP.close()
        }
        if let staleClient {
            try? await staleClient.close()
        }
    }

    private nonisolated static func isPermanentDirectoryError(_ error: Error) -> Bool {
        if error is SFTPHostKeyMismatch {
            return true
        }
        if let status = error as? SFTPMessage.Status {
            return status.errorCode == .noSuchFile || status.errorCode == .permissionDenied
        }
        if let sshError = error as? NIOSSHError,
           sshError.type == .keyExchangeNegotiationFailure {
            return true
        }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable, .pathNotFound, .fileNotFound:
                return true
            case .connectionFailed, .timeout:
                return false
            }
        }
        if error is SourceConnectionTerminalError || error is AuthenticationFailed {
            return true
        }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication,
                 .allAuthenticationOptionsFailed:
                return true
            case .channelCreationFailed:
                return false
            }
        }
        return false
    }

    func localURL(for path: String) async throws -> URL {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }

        let remotePath = try resolvedRemotePath(for: path)
        let localURL = cacheDirectory.appendingPathComponent(safeCacheFileName(for: remotePath))

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // 下载到同目录临时文件 (.part-UUID), 全部写完并 close 成功后再原子
        // rename 到最终缓存路径。直写最终路径的话: actor 在 `file.read` 的
        // await 挂起期间可重入, 第二个对同一 path 的调用会命中 fileExists
        // 检查拿到只写了一半的文件; 进程在下载中途被杀也会留下半截文件被
        // 下次启动当成完整缓存。临时路径 + rename 同时规避这两种场景。
        let tempURL = cacheDirectory.appendingPathComponent(
            "\(safeCacheFileName(for: remotePath)).part-\(UUID().uuidString)"
        )

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)

        do {
            defer {
                try? handle.close()
            }

            var offset: UInt64 = 0
            while true {
                var buffer = try await file.read(from: offset, length: 256 * 1024)
                if buffer.readableBytes == 0 {
                    break
                }

                guard let data = buffer.readData(length: buffer.readableBytes) else {
                    break
                }

                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            }

            try await file.close()
            try handle.close()
            // 并发可重入: 另一路对同一 path 的下载可能已先完成并占用了
            // localURL。此时本路的临时文件同样是完整的, 直接复用已有缓存,
            // 丢弃本路临时文件即可 —— 避免 moveItem 因目标已存在而报错。
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            }
            return localURL
        } catch {
            try? await file.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    func writeFile(data: Data, to path: String) async throws {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }
        let destination = try resolvedRemotePath(for: path)
        let staging = Self.stagingPath(for: destination)
        do {
            try await upload(data: data, to: staging, using: sftp)
            try await sftp.rename(at: staging, to: destination, flags: 1)
        } catch {
            try? await sftp.remove(at: staging)
            throw error
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }
        let attributes = try await sftp.getAttributes(at: resolvedRemotePath(for: path))
        let size = Int64(attributes.size ?? 0)
        let modifiedDate = attributes.accessModificationTime?.modificationTime
        return EmbeddedMetadataRemoteFileState(
            fileSize: size,
            modifiedDate: modifiedDate,
            revision: Self.fileRevision(size: size, modifiedDate: modifiedDate)
        )
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }
        let destination = try resolvedRemotePath(for: path)
        let staging = Self.stagingPath(for: destination)
        do {
            try await upload(localURL: localURL, to: staging, using: sftp)
            let current = try await metadataWritebackState(for: path)
            guard expected.matches(current) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            // Citadel serializes the SFTP rename-overwrite flag when the
            // server supports it. Servers that reject replacement leave the
            // original untouched and surface a replace-stage error.
            try await sftp.rename(at: staging, to: destination, flags: 1)
        } catch {
            try? await sftp.remove(at: staging)
            throw error
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        guard let remotePath = try? resolvedRemotePath(for: path) else { return }
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(safeCacheFileName(for: remotePath))
        )
    }

    private func upload(data: Data, to remotePath: String, using sftp: SFTPClient) async throws {
        let file = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .forceCreate]
        )
        do {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    private func upload(localURL: URL, to remotePath: String, using sftp: SFTPClient) async throws {
        let remoteFile = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .forceCreate]
        )
        let localFile = try FileHandle(forReadingFrom: localURL)
        do {
            defer { try? localFile.close() }
            var offset: UInt64 = 0
            while true {
                let data = try localFile.read(upToCount: 256 * 1024) ?? Data()
                if data.isEmpty { break }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    private nonisolated static func stagingPath(for destination: String) -> String {
        let parent = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        return (parent as NSString).appendingPathComponent(
            ".\(name).primuse-writeback-\(UUID().uuidString)"
        )
    }

    private nonisolated static func fileRevision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "sftp:\(size):\(Int64(modifiedDate.timeIntervalSince1970))"
    }

    func deleteFile(at path: String) async throws {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }

        try await sftp.remove(at: resolvedRemotePath(for: path))
    }

    /// SFTP READ via Citadel's `SFTPFile.read(from:length:)`。SFTP 协议级支持
    /// 任意 offset 读, 让 CloudPlaybackSource 边下边播替代整文件下载。
    /// 每次开关 file handle 一次 (SSH 连接复用), 8 路并发 prefetch 时
     /// 同时开多个 file 也安全。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }
        let remotePath = try resolvedRemotePath(for: path)

        // offset < 0 表示从末尾倒数 (suffix range), 先 stat 拿 size 转正
        let actualOffset: UInt64
        let actualLength: UInt32
        if offset < 0 {
            let attrs = try await sftp.getAttributes(at: remotePath)
            let total = Int64(attrs.size ?? 0)
            let start = max(0, total + offset)
            let avail = max(0, total - start)
            actualOffset = UInt64(start)
            actualLength = UInt32(min(length, avail, Int64(UInt32.max)))
        } else {
            actualOffset = UInt64(offset)
            actualLength = UInt32(min(length, Int64(UInt32.max)))
        }
        guard actualLength > 0 else { return Data() }

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            var buffer = try await file.read(from: actualOffset, length: actualLength)
            try await file.close()
            return buffer.readData(length: buffer.readableBytes) ?? Data()
        } catch {
            try? await file.close()
            throw error
        }
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
            Task {
                do {
                    try await scanDirectory(at: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
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

    private func resolveRootPath(using sftp: SFTPClient) async throws -> String {
        let requestedRoot: String
        if let basePath, basePath.isEmpty == false {
            requestedRoot = normalizedBasePath(basePath)
        } else {
            requestedRoot = "."
        }

        let resolved = try await sftp.getRealPath(atPath: requestedRoot)
        return RemotePathScopePolicy(rootPath: resolved.isEmpty ? "/" : resolved).rootPath
    }

    private func resolvedRemotePath(for path: String) throws -> String {
        guard let resolved = RemotePathScopePolicy(rootPath: rootPath)
            .resolvedPath(forStoredPath: path) else {
            throw SourceError.pathNotFound(path)
        }
        return resolved
    }

    private func joinedPath(parent: String, child: String) -> String {
        let normalizedParent = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = [normalizedParent, normalizedChild]
            .filter { $0.isEmpty == false }
            .joined(separator: "/")
        return "/" + combined
    }

    private func normalizedBasePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/\(path)"
    }

    private func isDirectory(_ item: SFTPPathComponent) -> Bool {
        if item.longname.hasPrefix("d") {
            return true
        }

        guard let permissions = item.attributes.permissions else {
            return false
        }

        return (permissions & 0o170000) == 0o040000
    }

    private func safeCacheFileName(for path: String) -> String {
        CacheFileNamePolicy.make(path: path)
    }

    private nonisolated static func authenticationMethod(
        username: String,
        secret: String,
        authType: SourceAuthType
    ) throws -> SSHAuthenticationMethod {
        guard secret.isEmpty == false else {
            throw SourceError.authenticationFailed
        }

        switch authType {
        case .sshKey:
            return try keyAuthenticationMethod(username: username, key: secret)
        case .password, .none:
            guard username.isEmpty == false else {
                throw SourceError.authenticationFailed
            }
            return .passwordBased(username: username, password: secret)
        default:
            throw SourceError.authenticationFailed
        }
    }

    private nonisolated static func keyAuthenticationMethod(
        username: String,
        key: String
    ) throws -> SSHAuthenticationMethod {
        guard username.isEmpty == false else {
            throw SourceError.authenticationFailed
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // PEM 容器格式 (PKCS#1 "BEGIN RSA PRIVATE KEY" / PKCS#8 "BEGIN PRIVATE KEY")
        // 暂未接入解析,绝不能把私钥文本塞进 password 字段当 SSH 密码发出去
        // (认证必败 + 明文私钥泄露给远端)。直接报错引导用户转成 OpenSSH 格式。
        if trimmedKey.contains("BEGIN RSA PRIVATE KEY") || trimmedKey.contains("BEGIN PRIVATE KEY") {
            throw SourceConnectionTerminalError(
                message: "Unsupported SSH key format. Please convert to OpenSSH format: ssh-keygen -p -m RFC4716 -f <keyfile>"
            )
        }

        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: trimmedKey)
        switch keyType {
        case .rsa:
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: trimmedKey)
            return .rsa(username: username, privateKey: privateKey)
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: trimmedKey)
            return .ed25519(username: username, privateKey: privateKey)
        default:
            throw SourceConnectionTerminalError(message: "Unsupported SSH key type")
        }
    }
}

/// SSH 主机密钥校验器,采用 TOFU (Trust On First Use):
/// 首次连接某 host:port 时把服务器主机密钥指纹固定 (pin) 到 UserDefaults,
/// 之后每次连接都比对指纹,不一致即阻断 —— 防止 ARP/DNS 劫持等中间人冒充 NAS。
/// 取代之前 `.acceptAnything()` 无条件放行的不安全实现。
///
/// 校验回调是同步且非主线程的 (succeed/fail 一个 NIO promise),因此这里
/// 只做静默 pinning;首次连接弹窗征求用户确认属于 UI 层增强,见 SourceManager。
private struct SFTPHostKeyMismatch: Error {
    let host: String
    let port: Int
}

private struct SFTPHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int

    private static let defaultsKeyPrefix = "primuse_sftp_hostkey_v1."

    private var pinKey: String {
        "\(Self.defaultsKeyPrefix)\(host.lowercased()):\(port)"
    }

    /// 主机密钥的 SHA256 指纹 (基于 SSH wire 格式序列化),与 OpenSSH known_hosts 同源。
    private static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let current = Self.fingerprint(of: hostKey)
        let defaults = UserDefaults.standard

        if let pinned = defaults.string(forKey: pinKey) {
            if pinned == current {
                validationCompletePromise.succeed(())
            } else {
                // 指纹变化 = 可能的中间人攻击,阻断连接。用户需在源设置里
                // 手动重置该源以重新信任 (清空 pinKey)。
                validationCompletePromise.fail(SFTPHostKeyMismatch(host: host, port: port))
            }
        } else {
            // 首次连接:信任并固定指纹 (TOFU)。
            defaults.set(current, forKey: pinKey)
            validationCompletePromise.succeed(())
        }
    }
}
