import Foundation
import PrimuseKit

/// pCloud Source —— pcloud.com 的 HTTP JSON 接口(`PCloudAPIProtocol`)。
///
/// 授权有两条路,拿到的 token 完全一样:
///   · iPhone / iPad / Mac:浏览器隐式授权(`response_type=token`),和 pCloud 官方
///     Swift SDK 一样不需要 client_secret,回调 fragment 里直接带 token 与账号所在区;
///   · Apple TV:poll_token —— 电视画二维码,用户在任意浏览器里同意,电视挂在 token
///     端点上的长连接直接拿到 token(见 `CloudDeviceAuthService`)。
/// token 不过期、没有 refresh_token,被用户撤销后只能重新授权。
///
/// 美国 / 欧洲两个数据中心是同一套接口。每个源的 API 主机在授权时就定了,记在 token
/// 的 extra 里(`PCloudAPIProtocol.apiHostKey`),之后所有请求都打那台。
///
/// 文件与文件夹用带前缀的 ID(`f…` / `d…`)标识:`RemoteFileItem.path` /
/// `Song.filePath` 存的就是它,文件夹层级靠 `parentPath` 重建 —— 那里填调用方用来
/// 定位本目录的标识,与光鸭、123 等 ID 寻址网盘一致。
///
/// 标签和伴随文件通过 uploadfile 同名覆盖，pCloud 保留旧内容为文件修订。
actor PCloudSource: MusicSourceConnector, OAuthCloudSource, EmbeddedMetadataWritebackAdapter, LyricsSidecarTargetResolving {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    private let helper: CloudDriveHelper
    private let session: URLSession?
    private let tokenProvider: (@Sendable () async throws -> CloudTokenManager.Tokens)?

    static let redirectURI = "\(CloudOAuthConfig.callbackScheme)://oauth/pcloud/callback"

    /// fileID → (直链, 本地过期时间)。直链自带有效期,这里按服务端给的时长打折缓存。
    private var fileLinkCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let maximumFileLinkTTL: TimeInterval = 30 * 60
    /// 直链到期前这么久就当它已经过期,避免正在播的一段 Range 打到刚失效的链接。
    private static let fileLinkSafetyMargin: TimeInterval = 60

    init(
        sourceID: String,
        session: URLSession? = nil,
        tokenProvider: (@Sendable () async throws -> CloudTokenManager.Tokens)? = nil,
        requests: CloudRequestScheduler = .shared
    ) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID, requests: requests, session: session ?? .shared)
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func connect() async throws { _ = try await currentTokens() }
    func disconnect() async {}

    /// `userinfo` 的 `userid` —— 跨设备稳定,用来把同一个 pCloud 账号下的多个挂载
    /// 归并到一个 CloudAccount。
    func accountIdentifier() async throws -> String {
        let data = try await authorizedCall { host in PCloudAPIProtocol.userInfoURL(host: host) }
        guard let info = PCloudAPIProtocol.parseUserInfo(data) else {
            throw CloudDriveError.invalidResponse
        }
        return info.userID
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let folderID = PCloudAPIProtocol.folderID(from: path) else {
            throw CloudDriveError.fileNotFound(path)
        }
        let data = try await authorizedCall(notFoundPath: path) { host in
            PCloudAPIProtocol.listFolderURL(host: host, folderID: folderID)
        }
        guard let entries = PCloudAPIProtocol.parseFolderListing(data) else {
            throw CloudDriveError.invalidResponse
        }
        return entries.map { entry in
            RemoteFileItem(
                name: entry.name,
                path: entry.id,
                isDirectory: entry.isFolder,
                size: entry.size,
                modifiedDate: entry.modifiedAt,
                // 内容哈希随内容变,同尺寸覆盖也认得出来。
                revision: entry.contentHash,
                providerID: entry.id,
                // 文件夹层级只能靠这个字段重建,填的必须是调用方用来定位本目录的
                // 那个标识(浏览器根是 "/",子目录是 d…),不是 pCloud 的 parentfolderid。
                parentPath: path
            )
        }
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await fileLink(for: path)
        return try await helper.downloadToCache(request: URLRequest(url: url), for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] directory in
            try await listFiles(at: directory)
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await fileLink(for: path)
        do {
            return try await helper.rangeRequest(url: url, offset: offset, length: length,
                                                 session: session ?? CloudDriveHelper.rangeSession)
        } catch CloudDriveError.apiError(let status, _) where [401, 403, 410].contains(status) {
            // 直链在有效期内也可能失效(比如换了网络出口)。换一条再试一次,
            // 而不是把这次播放判死。
            fileLinkCache.removeValue(forKey: path)
            let refreshed = try await fileLink(for: path)
            return try await helper.rangeRequest(url: refreshed, offset: offset, length: length,
                                                 session: session ?? CloudDriveHelper.rangeSession)
        }
    }

    /// 删除源文件。pCloud 的 deletefile 把文件移进回收站,应答带 `isdeleted: true`
    /// 才算删成,否则不让 Primuse 先把这首歌从曲库里拿掉。
    func deleteFile(at path: String) async throws {
        guard let fileID = PCloudAPIProtocol.fileID(from: path) else {
            throw CloudDriveError.fileNotFound(path)
        }
        let data = try await authorizedCall(method: "POST", notFoundPath: path) { host in
            PCloudAPIProtocol.deleteFileURL(host: host, fileID: fileID)
        }
        guard PCloudAPIProtocol.confirmsDeletion(data) else {
            throw CloudDriveError.apiError(200, "pCloud did not confirm deletion")
        }
        fileLinkCache.removeValue(forKey: path)
        plog("🗑️ pCloud file moved to trash: \(path)")
    }

    // MARK: - 直链

    private func fileLink(for path: String) async throws -> URL {
        if let cached = fileLinkCache[path], cached.expiresAt > Date() { return cached.url }
        guard let fileID = PCloudAPIProtocol.fileID(from: path) else {
            throw CloudDriveError.fileNotFound(path)
        }
        let data = try await authorizedCall(notFoundPath: path) { host in
            PCloudAPIProtocol.fileLinkURL(host: host, fileID: fileID)
        }
        guard let link = PCloudAPIProtocol.parseFileLink(data) else {
            throw CloudDriveError.fileNotFound(path)
        }
        let serverTTL = (link.expiresAt?.timeIntervalSinceNow ?? 0) - Self.fileLinkSafetyMargin
        let ttl = serverTTL > 0 ? min(serverTTL, Self.maximumFileLinkTTL) : Self.maximumFileLinkTTL
        fileLinkCache[path] = (link.url, Date().addingTimeInterval(ttl))
        return link.url
    }

    // MARK: - 文件写回

    private func metadata(for path: String) async throws -> PCloudAPIProtocol.FileMetadata {
        guard let id = PCloudAPIProtocol.fileID(from: path) else { throw CloudDriveError.fileNotFound(path) }
        let data = try await authorizedCall(notFoundPath: path) { PCloudAPIProtocol.statURL(host: $0, fileID: id) }
        guard let file = PCloudAPIProtocol.parseFileMetadata(data), file.entry.id == "f\(id)" else {
            throw CloudDriveError.invalidResponse
        }
        return file
    }

    private func state(_ file: PCloudAPIProtocol.FileMetadata) -> EmbeddedMetadataRemoteFileState {
        .init(fileSize: file.entry.size, modifiedDate: file.entry.modifiedAt,
              revision: file.entry.contentHash, replacementToken: "\(file.parentID)/\(file.entry.name)")
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        state(try await metadata(for: path))
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        fileLinkCache.removeValue(forKey: path)
        helper.invalidateCachedFile(path: path)
    }

    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws {
        _ = try await replaceMetadataFileReturningPath(at: path, with: localURL, expected: expected)
    }

    func replaceMetadataFileReturningPath(at path: String, with localURL: URL,
                                          expected: EmbeddedMetadataRemoteFileState) async throws -> String {
        let current = try await metadata(for: path)
        guard state(current).matches(expected) else { throw EmbeddedMetadataWritebackSourceError.conflict }
        let siblings = try await listFiles(at: "d\(current.parentID)").filter {
            $0.name.caseInsensitiveCompare(current.entry.name) == .orderedSame
        }
        guard siblings.count == 1, siblings.first?.path == current.entry.id else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        guard try await metadataWritebackState(for: path).matches(expected) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        defer { fileLinkCache.removeValue(forKey: path); helper.invalidateCachedFile(path: path) }
        let uploaded = try await upload(localURL, name: current.entry.name, parentID: current.parentID)
        await invalidateMetadataWritebackCache(for: uploaded.entry.id)
        do {
            let confirmed = try await metadata(for: uploaded.entry.id)
            guard confirmed == uploaded else { throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed }
        } catch {
            throw EmbeddedMetadataReplacementReadbackError(filePath: uploaded.entry.id,
                fileSize: uploaded.entry.size, detail: error.localizedDescription)
        }
        return uploaded.entry.id
    }

    private func upload(_ file: URL, name: String, parentID: Int64) async throws -> PCloudAPIProtocol.FileMetadata {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw CloudDriveError.invalidResponse }
        let tokens = try await currentTokens()
        guard let url = PCloudAPIProtocol.uploadURL(host: PCloudAPIProtocol.apiHost(from: tokens.extra),
                                                  folderID: parentID, filename: name) else { throw CloudDriveError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 3_600
        let (data, response) = try await helper.sendOnce(request) { session, request in
            try await session.upload(for: request, fromFile: file)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 403 { throw SourceFileMutationError.permissionDenied }
        guard (200...299).contains(http.statusCode), let envelope = PCloudAPIProtocol.parseEnvelope(data) else {
            throw CloudDriveError.invalidResponse
        }
        guard envelope.isSuccess else {
            if envelope.result == PCloudAPIProtocol.ResultCode.accessDenied { throw SourceFileMutationError.permissionDenied }
            throw Self.connectorError(for: envelope, notFoundPath: nil)
        }
        guard let uploaded = PCloudAPIProtocol.parseFileMetadata(data, uploaded: true),
              uploaded.parentID == parentID, uploaded.entry.name == name, uploaded.entry.size == Int64(size) else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        return uploaded
    }

    func lyricsSidecarTarget(for song: Song, request: LyricsDocumentRequest) async throws -> LyricsSidecarTarget {
        let file = try await metadata(for: song.filePath)
        let base = (file.entry.name as NSString).deletingPathExtension
        let directory = "d\(file.parentID)"
        let siblings = try await listFiles(at: directory)
        let existing = try LyricsSidecarTargetPolicy.uniqueExistingItem(baseName: base, in: siblings, request: request)
        let companion = LyricsSidecarTargetPolicy.translationTrackItem(forPrimary: existing, baseName: base, in: siblings)
        let name = existing?.name ?? "\(base).lrc"
        return LyricsSidecarTarget(targetPath: song.filePath + "." + (name as NSString).pathExtension.lowercased(),
            fileName: name, containerPath: directory, exists: existing != nil, existingPath: existing?.path,
            existingSize: existing?.size, songBaseName: base, translationPath: companion?.path,
            translationFileName: companion?.name, translationSize: companion?.size,
            documents: LyricsSidecarTargetPolicy.documents(baseName: base, in: siblings))
    }

    func writeLyricsSidecar(data: Data, target: LyricsSidecarTarget, priority: RangeFetchPriority) async throws -> LyricsSidecarWriteReceipt {
        let suffix = "." + (target.fileName as NSString).pathExtension.lowercased()
        guard PrimuseConstants.supportedLyricsExtensions.contains(String(suffix.dropFirst())),
              target.targetPath.hasSuffix(suffix) else { throw CloudDriveError.invalidResponse }
        let source = try await metadata(for: String(target.targetPath.dropLast(suffix.count)))
        guard target.containerPath == "d\(source.parentID)",
              (source.entry.name as NSString).deletingPathExtension.caseInsensitiveCompare(
                (target.fileName as NSString).deletingPathExtension) == .orderedSame else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let existing = try await listFiles(at: target.containerPath).filter {
            $0.name.caseInsensitiveCompare(target.fileName) == .orderedSame
        }
        guard existing.count <= 1,
              existing.allSatisfy({ !$0.isDirectory && $0.name == target.fileName }),
              target.exists ? existing.first?.path == target.existingPath && target.existingPath != nil
                && (target.existingSize == nil || existing.first?.size == target.existingSize) : existing.isEmpty else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let uploaded = try await uploadSidecar(data, name: target.fileName, parentID: source.parentID)
        return LyricsSidecarWriteReceipt(requestedTargetPath: target.targetPath, writtenPath: uploaded.entry.id,
            fileName: target.fileName, containerPath: target.containerPath, remoteSize: uploaded.entry.size, readback: data)
    }

    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if let ext = PrimuseConstants.supportedLyricsExtensions.first(where: { path.hasSuffix(".\($0)") }) { suffix = "." + ext }
        else { throw CloudDriveError.invalidResponse }
        let source = try await metadata(for: String(path.dropLast(suffix.count)))
        let name = (source.entry.name as NSString).deletingPathExtension + suffix
        let matches = try await listFiles(at: "d\(source.parentID)").filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1, matches.allSatisfy({ !$0.isDirectory && $0.name == name }) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        _ = try await uploadSidecar(data, name: name, parentID: source.parentID)
    }

    private func uploadSidecar(_ data: Data, name: String, parentID: Int64) async throws -> PCloudAPIProtocol.FileMetadata {
        guard !data.isEmpty else { throw CloudDriveError.invalidResponse }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-pcloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let uploaded = try await upload(temporary, name: name, parentID: parentID)
        await invalidateMetadataWritebackCache(for: uploaded.entry.id)
        let readback = try await fetchRange(path: uploaded.entry.id, offset: 0, length: Int64(data.count))
        guard readback == data else { throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed }
        return uploaded
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        // writeFile verifies the uploaded provider ID before returning.
    }

    // MARK: - 鉴权请求

    /// 发一个带 Bearer 头的业务请求,校验 `result == 0`,把业务码翻成 `CloudDriveError`。
    /// token 被拒(2094 等)时先看钥匙串里是不是已经换了新 token(比如在另一台设备上
    /// 重新授权后同步过来),换了就用新的再试一次;没换说明这份授权确实失效了。
    private func authorizedCall(
        method: String = "GET",
        notFoundPath: String? = nil,
        url makeURL: (String) -> URL?
    ) async throws -> Data {
        let tokens = try await currentTokens()
        let host = PCloudAPIProtocol.apiHost(from: tokens.extra)
        guard let url = makeURL(host) else { throw CloudDriveError.invalidResponse }
        let replay: RequestExecutor.Replay = method == "GET" ? .idempotent : .never
        return try await helper.withTokenRetry(
            initialToken: tokens.accessToken,
            refresh: Self.cannotRefresh
        ) { @Sendable accessToken in
            try await self.perform(
                url: url, method: method, replay: replay,
                accessToken: accessToken, notFoundPath: notFoundPath
            )
        }
    }

    private func perform(
        url: URL,
        method: String,
        replay: RequestExecutor.Replay,
        accessToken: String,
        notFoundPath: String?
    ) async throws -> Data {
        let (data, http) = try await helper.dataRequest(
            url: url, replay: replay, session: session,
            validate: { data, http in
                guard (200...299).contains(http.statusCode) else { return }
                guard let envelope = PCloudAPIProtocol.parseEnvelope(data) else {
                    throw CloudDriveError.invalidResponse
                }
                guard !envelope.isSuccess else { return }
                if PCloudAPIProtocol.isTransient(envelope.result) {
                    // 4xxx 限频、5xxx 临时故障:交给执行器按退避重试(只对能重发的请求)。
                    throw HTTPResponseFailure(
                        statusCode: http.statusCode, body: data,
                        retryAfter: HTTPResponseFailure.retryDelay(from: http),
                        isRateLimited: envelope.result / 1000 == 4, isRetryable: true
                    )
                }
                throw Self.connectorError(for: envelope, notFoundPath: notFoundPath)
            },
            request: { refreshed in
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer \(refreshed ?? accessToken)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 60
                return request
            }
        )
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
            throw CloudDriveError.apiError(http.statusCode, String(data: data.prefix(512), encoding: .utf8) ?? "")
        }
        return data
    }

    private static func connectorError(
        for envelope: PCloudAPIProtocol.Envelope,
        notFoundPath: String?
    ) -> CloudDriveError {
        if PCloudAPIProtocol.indicatesInvalidToken(envelope.result) { return .tokenExpired }
        if PCloudAPIProtocol.indicatesMissingItem(envelope.result) { return .fileNotFound(notFoundPath ?? "") }
        if envelope.result == PCloudAPIProtocol.ResultCode.accessDenied { return .permissionDenied(.fileRead) }
        return .apiError(envelope.result, envelope.message)
    }

    // MARK: - Token

    private func currentTokens() async throws -> CloudTokenManager.Tokens {
        let tokens: CloudTokenManager.Tokens
        if let tokenProvider {
            tokens = try await tokenProvider()
        } else {
            // 走去重刷新入口:它会先补写上次没落盘的 token。pCloud 的 token 不带
            // 过期时间,这里不会真的发起刷新。
            tokens = try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: Self.cannotRefresh)
        }
        guard !tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudDriveError.notAuthenticated
        }
        return tokens
    }

    /// pCloud 没有 refresh_token。钥匙串里还是被拒的那一份时只能请用户重新授权。
    private static let cannotRefresh: @Sendable (CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens = { _ in
        throw CloudDriveError.tokenRefreshFailed(String(localized: "pcloud_err_authorization_revoked"))
    }

    /// 浏览器隐式授权:回调 fragment 直接带 token、`locationid` 与 `hostname`,
    /// 不需要 client_secret,也没有 PKCE 这一步(没有授权码可换)。
    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .pcloud,
            authURL: PCloudAPIProtocol.authorizeURL.absoluteString,
            tokenURL: "",
            clientId: clientId,
            clientSecret: nil,
            scopes: [],
            redirectURI: redirectURI,
            usesPKCE: false,
            grant: .implicit
        )
    }
}
