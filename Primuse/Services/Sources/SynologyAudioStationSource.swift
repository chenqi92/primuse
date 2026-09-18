import CryptoKit
import Foundation
import PrimuseKit

/// 群晖 Audio Station 音乐源:整库曲目、歌单(只读镜像)、评分、歌词、封面与播放。
///
/// 与群晖直连(`SynologySource`,经 File Station 浏览文件夹)是两种源 —— 这里连的
/// 是 DSM 上的音乐套件本身。协议、会话续期与翻页都在 PrimuseKit 的
/// `SynologyAudioStationClient` 里,这里只负责接进连接器体系:证书信任走
/// `SmartSSLDelegate`、公网明文走 `TrustedHTTPTransport`,与其他 HTTP 源一致。
///
/// 播放:原文件用 `method=stream` 的 Range 读进稀疏缓存。服务端若不认 Range
/// (回 200),改成整曲下载一次再切片,之后同一个连接器都走本地文件。整轨切出来的
/// 虚拟音轨(`music_v_`)没有独立文件,只能拿服务端现转的 mp3。
actor SynologyAudioStationSource: RefreshingMetadataSongConnector, ServerLyricsConnector,
    ServerPlaylistConnector, ServerRatingConnector {
    /// 诊断里「连接」这一步的上限。QuickConnect 要先解析中转,比直连地址慢。
    static let connectionTimeout: TimeInterval = 30

    let sourceID: String
    private let client: SynologyAudioStationClient
    private let session: URLSession
    private let audioCacheDirectory: URL
    private let usesQuickConnect: Bool
    private var connected = false
    /// 这台服务器的 `method=stream` 不认 Range。连接器存活期间不再逐段试探。
    private var rangeRequestsUnsupported = false
    /// 整曲下载按路径单飞:并发的分段读取与离线下载共用同一次传输。任务不随
    /// 某一个等待方取消,播放层 30 秒的分段超时之后重试还能接着等它。
    private var completeFileDownloads: [String: (token: UUID, task: Task<URL, Error>)] = [:]

    /// - Parameters:
    ///   - source: 已经投影到某条路由的音乐源;QuickConnect 模式下 `host` 是 QuickConnect ID。
    ///   - deviceName: 非空时随登录申请受信设备令牌(与群晖直连「记住此设备」同一做法)。
    init(
        source: MusicSource,
        password: String,
        deviceName: String?,
        transport: SynologyAudioStationRequestTransport? = nil
    ) {
        sourceID = source.id
        usesQuickConnect = source.effectiveSynologyConnectionMode == .quickConnect
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        // 只靠 `_sid` 认证,不让 Cookie 或系统凭据掺进来。
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: SmartSSLDelegate(
            redirectPolicy: .sameEndpoint,
            alternateServerTrustHostname: source.alternateTLSValidationHostname,
            alternateServerTrustEndpoint: NetworkEndpointIdentity(
                scheme: source.useSsl ? "https" : "http",
                host: source.host ?? "",
                port: source.port
            )
        ), delegateQueue: nil)
        self.session = session
        var loginSource = source
        // 没勾「记住此设备」时不带旧令牌,与群晖直连的登录参数一致。
        if deviceName == nil { loginSource.deviceId = nil }
        client = SynologyAudioStationClient(
            source: loginSource,
            credential: SourceCredential(username: source.username ?? "", password: password),
            deviceName: deviceName,
            transport: transport ?? SynologyAudioStationRequestTransport(
                data: { try await TrustedHTTPTransport.data(for: $0, session: session) },
                download: { try await TrustedHTTPTransport.download(for: $0, session: session) }
            )
        )
        audioCacheDirectory = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(source.id, isDirectory: true)
            .appendingPathComponent(MusicSourceSecurityRevision.cacheNamespace(for: source.id), isDirectory: true)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - 连接

    /// 登录并确认这个账号能用 Audio Station。`info()` 会在需要时自动登录;
    /// 没有权限时 DSM 在登录(402)或这一步(105)就会说出来。
    func connect() async throws {
        guard !connected else { return }
        do {
            _ = try await perform { try await $0.info() }
            connected = true
            #if !os(tvOS)
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
            #endif
        } catch {
            #if !os(tvOS)
            // 只有账号密码能靠重新输入解决;两步验证要走「重新登录」,不在这里弹。
            if let failure = error as? SynologyAudioStationError,
               failure.requiresCredentialPrompt || failure == .missingCredential {
                let message = failure.localizedDescription
                await MainActor.run { SourceAuthAlert.report(sourceID: sourceID, message: message) }
            }
            #endif
            throw error
        }
    }

    /// 两步验证入口:带验证码显式登录,确认 Audio Station 权限后返回 DSM 发的受信设备令牌。
    func signIn(otp: String?) async throws -> String? {
        let login = try await client.login(otp: otp)
        _ = try await perform { try await $0.info() }
        connected = true
        return login.deviceID
    }

    func disconnect() async {
        connected = false
        for download in completeFileDownloads.values { download.task.cancel() }
        completeFileDownloads.removeAll()
        await client.invalidateSession()
    }

    /// QuickConnect 解析出的路线会随网络变化失效。连接层面的失败后丢掉会话与
    /// 已解析的路线,下一次请求重新解析,而不是一直打向旧地址。
    private func perform<Value: Sendable>(
        _ operation: @Sendable (SynologyAudioStationClient) async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation(client)
        } catch let error as URLError where usesQuickConnect && Self.routeLossCodes.contains(error.code) {
            connected = false
            await client.invalidateSession()
            throw error
        }
    }

    private static let routeLossCodes: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
        .notConnectedToInternet, .timedOut, .secureConnectionFailed,
    ]

    // MARK: - 曲库

    /// 整库源没有目录可选,给诊断一个代表整库的合成根。
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return [RemoteFileItem(name: "Audio Station", path: "/", isDirectory: true, size: 0, modifiedDate: nil)]
    }

    /// 客户端逐页校验总数与重复 id,任何一页对不上就以错误结束 —— 扫描管线见到
    /// 错误不会提交快照,已有的歌不会因为一次残缺的遍历被删掉。
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        let catalog = await client.songs()
        let sourceID = sourceID
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await track in catalog {
                        try Task.checkCancellation()
                        // 认不出格式的条目没法播放,跳过而不是让整轮扫描失败。
                        guard let song = track.makeSong(sourceID: sourceID) else { continue }
                        continuation.yield(ConnectorScannedSong(
                            song: song,
                            displayName: song.title,
                            titleMetadataInspected: track.hasUsableTitle,
                            folderLocation: Self.folderLocation(for: track.folderPlacement)
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private static func folderLocation(
        for placement: SynologyAudioStationFolderPlacement
    ) -> ConnectorLibraryFolderLocation {
        let fallback = [("artist", placement.artistName), ("album", placement.albumName)]
            .compactMap { kind, name -> ConnectorLibraryFolderComponent? in
                guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ConnectorLibraryFolderComponent(
                    stableID: "\(kind):\(ConnectorLibraryFolderHierarchy.stableNameIdentity(name))",
                    displayName: name
                )
            }
        return ConnectorLibraryFolderHierarchy.location(
            rootStableID: "synology-audiostation:catalog",
            rootDisplayName: "Audio Station",
            providerFilePath: placement.providerFilePath,
            declaredLibraryRoots: placement.libraryRoot.map { [$0] } ?? [],
            fallbackComponents: fallback
        )
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let songs = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await item in songs {
                        try Task.checkCancellation()
                        continuation.yield(RemoteFileItem(
                            name: item.displayName,
                            path: item.song.filePath,
                            isDirectory: false,
                            size: item.song.fileSize,
                            modifiedDate: item.song.lastModified,
                            revision: item.song.revision
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - 播放

    /// 交给播放层的链接带当前 `_sid`。先用一次轻量请求确认会话还有效(过期时
    /// 客户端会自动重登),免得交出一个播放器那边才发现已失效的链接。虚拟音轨
    /// 由客户端自动转成 mp3;它在曲库里没有文件大小,播放层本来就不会按大小 Range。
    func streamingURL(for path: String) async throws -> URL? {
        let id = try Self.songID(from: path)
        if connected {
            _ = try await perform { try await $0.info() }
        } else {
            try await connect()
        }
        return try await perform { try await $0.streamURL(id: id) }
    }

    func imageURL(for path: String) async throws -> URL? { nil }

    func localURL(for path: String) async throws -> URL {
        let id = try Self.songID(from: path)
        let target = audioCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(path: path, preferredExtension: (path as NSString).pathExtension)
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let download: Task<URL, Error>
        if let pending = completeFileDownloads[path] {
            download = pending.task
        } else {
            let token = UUID()
            download = Task {
                try await self.materializeCompleteFile(path: path, id: id, target: target, token: token)
            }
            completeFileDownloads[path] = (token, download)
        }
        return try await Self.awaitCompleteFile(download)
    }

    private func materializeCompleteFile(path: String, id: String, target: URL, token: UUID) async throws -> URL {
        defer {
            if completeFileDownloads[path]?.token == token { completeFileDownloads[path] = nil }
        }
        let temporary = SynologyAudioStationAPI.isVirtualTrackID(id)
            ? try await Self.downloadTranscodedTrack(id: id, client: client, session: session)
            : try await client.downloadOriginal(id: id)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: audioCacheDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        return target
    }

    /// 等整曲下载,但调用方被取消时立刻返回:下载本身不停,下一次读取接着等它。
    /// 直接 `await task.value` 不响应取消,会把播放层的跳歌卡到下载结束。
    private static func awaitCompleteFile(_ task: Task<URL, Error>) async throws -> URL {
        let race = CancellableResultRace<URL>()
        let observer = Task {
            do {
                let file = try await task.value
                race.resolve(.success(file))
            } catch {
                race.resolve(.failure(error))
            }
        }
        defer { observer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// 虚拟音轨只能拿服务端现转的 mp3。会话失效时 DSM 回的是 HTTP 200 + JSON
    /// 错误体,认出来就重登一次再取。
    private static func downloadTranscodedTrack(
        id: String,
        client: SynologyAudioStationClient,
        session: URLSession
    ) async throws -> URL {
        for attempt in 0...1 {
            let url = try await client.streamURL(id: id)
            var request = URLRequest(url: url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (file, response) = try await TrustedHTTPTransport.download(for: request, session: session)
            do {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw SynologyAudioStationError.invalidResponse
                }
                let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                if size <= 64 * 1_024,
                   let failure = SynologyAudioStationAPI.failureEnvelope(
                    in: try Data(contentsOf: file),
                    response: http
                   ) {
                    if attempt == 0, SynologyAudioStationAPI.renewsSession(after: failure.code) {
                        try? FileManager.default.removeItem(at: file)
                        await client.invalidateSession()
                        continue
                    }
                    throw SynologyAudioStationAPI.error(
                        for: failure,
                        call: SynologyAudioStationAPI.streamCall(id: id, transcode: nil)
                    )
                }
                let mime = http.mimeType?.lowercased() ?? ""
                guard http.statusCode == 200, size > 0,
                      !mime.contains("json"), !mime.contains("html"), !mime.hasPrefix("text/") else {
                    throw (200...299).contains(http.statusCode)
                        ? SynologyAudioStationError.invalidResponse
                        : SynologyAudioStationError.badServerResponse(http.statusCode)
                }
                return file
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        throw SynologyAudioStationError.invalidResponse
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let file = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// 原始流的一段。服务端不认 Range 时(回 200,或者整份文件超过了传输上限)
    /// 降级为整曲下载一次再从本地切片,而不是让播放或离线失败。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let id = try Self.songID(from: path)
        guard length > 0 else { return Data() }
        if rangeRequestsUnsupported || SynologyAudioStationAPI.isVirtualTrackID(id) {
            return try await rangeFromCompleteFile(path: path, offset: offset, length: length)
        }
        do {
            return try await perform { try await $0.fetchRange(id: id, offset: offset, length: length) }
        } catch let error where Self.indicatesRangeUnsupported(error, requestedLength: length) {
            if !rangeRequestsUnsupported {
                rangeRequestsUnsupported = true
                plog("⚠️ Audio Station stream ignored Range source=\(sourceID.prefix(8)); falling back to complete downloads")
            }
            return try await rangeFromCompleteFile(path: path, offset: offset, length: length)
        }
    }

    private static func indicatesRangeUnsupported(_ error: Error, requestedLength: Int64) -> Bool {
        if let failure = error as? SynologyAudioStationError {
            return failure == .rangeNotSupported || failure == .transcodeRequired
        }
        // 忽略 Range 的服务端回的是整份文件,超过传输上限(20 MB)时在这里被截住。
        // 只有请求的窗口远小于上限时,超限才说明对方没按 Range 回。
        return (error as? URLError)?.code == .dataLengthExceedsMaximum
            && requestedLength <= 8 * 1_024 * 1_024
    }

    private func rangeFromCompleteFile(path: String, offset: Int64, length: Int64) async throws -> Data {
        let file = try await localURL(for: path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let start: Int64
        if offset < 0 {
            start = max(0, fileSize + offset)
        } else {
            guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else { return Data() }
            start = offset
        }
        guard start < fileSize else { return Data() }
        try handle.seek(toOffset: UInt64(start))
        return try handle.read(upToCount: Int(clamping: min(length, fileSize - start))) ?? Data()
    }

    // MARK: - 封面

    /// 只认扫描时写进 `coverArtFileName` 的引用;没有封面时返回 nil,由刮削接手。
    func fetchArtworkData(
        for reference: String,
        maximumBytes: Int,
        purpose: ArtworkFetchPurpose
    ) async throws -> Data? {
        guard maximumBytes > 0, SynologyAudioStationCoverReference(rawValue: reference) != nil else {
            return nil
        }
        return try await perform { try await $0.artwork(reference: reference, maxBytes: maximumBytes) }
    }

    // MARK: - 歌词

    func fetchServerLyrics(for path: String) async -> String? {
        guard case .content(let text) = await readServerLyrics(for: path) else { return nil }
        return text
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        guard let id = try? Self.songID(from: path) else { return .unavailable }
        do {
            return try await perform { try await $0.lyrics(id: id) }
                .map(ServerLyricsReadResult.content) ?? .absent
        } catch let error as SynologyAudioStationError {
            // 套件没有歌词接口时服务端永远给不出歌词,如实说「没有」。
            switch error {
            case .apiNotFound, .unsupportedVersion: return .absent
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    // MARK: - 歌单

    /// 只读镜像:个人与共享歌单(客户端已滤掉系统内部歌单),智能歌单也照样镜像。
    /// 尚未入库的条目(id 是 NAS 路径)匹配不到任何一首歌,在这里就去掉,
    /// 自报数量随之按目录曲目计,不会让镜像被当成「被截断」而一直不更新。
    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await connect()
        let listed = try await perform { try await $0.playlists() }
        var playlists: [ServerPlaylist] = []
        var failed: Set<String> = []
        for playlist in listed {
            try Task.checkCancellation()
            let mirrorID = Self.mirrorPlaylistID(for: playlist.id)
            do {
                let trackIDs = try await perform { try await $0.playlistTrackIDs(id: playlist.id) }
                    .filter(SynologyAudioStationAPI.isCatalogSongID)
                playlists.append(ServerPlaylist(
                    id: mirrorID,
                    name: playlist.name,
                    trackIDs: trackIDs,
                    reportedTrackCount: trackIDs.count
                ))
            } catch let error where OperationCancellationPolicy.isCancellation(error) {
                throw CancellationError()
            } catch {
                failed.insert(mirrorID)
            }
        }
        return ServerPlaylistSnapshot(playlists: playlists, failedPlaylistIDs: failed)
    }

    /// Audio Station 的歌单 id 里带着名字与斜杠(`playlist_personal_normal/开车`)。
    /// 镜像身份只用它的摘要,本地歌单 id 里不出现任意文字。
    static func mirrorPlaylistID(for serverPlaylistID: String) -> String {
        let digest = SHA256.hash(data: Data(serverPlaylistID.utf8))
        return "as-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 评分

    /// nil 表示没评分(服务端的 0)。
    func fetchServerRating(itemID: String) async throws -> Int? {
        guard SynologyAudioStationAPI.isCatalogSongID(itemID) else { throw SourceError.fileNotFound(itemID) }
        return try await perform { try await $0.rating(id: itemID) }
    }

    /// 写 1–5,nil 清除;客户端写完读回,返回服务端确认的值。
    func setServerRating(itemID: String, rating: Int?) async throws -> Int? {
        guard SynologyAudioStationAPI.isCatalogSongID(itemID) else { throw SourceError.fileNotFound(itemID) }
        return try await perform { try await $0.setRating(id: itemID, rating: rating) }
    }

    // MARK: - 工具

    private static func songID(from path: String) throws -> String {
        guard let id = SynologyAudioStationAPI.songID(fromTrackPath: path) else {
            throw SourceError.fileNotFound(path)
        }
        return id
    }
}
