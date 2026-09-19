import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 可注入的请求传输:App 层可以换上自己的证书信任与明文确认策略,而不必复制协议实现。
public struct SynologyAudioStationRequestTransport: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadLoader = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    let data: DataLoader
    let download: DownloadLoader

    public init(data: @escaping DataLoader, download: @escaping DownloadLoader) {
        self.data = data
        self.download = download
    }
}

public struct SynologyAudioStationLogin: Equatable, Sendable {
    public let sid: String
    /// 勾选「记住此设备」后 DSM 发的受信设备令牌;调用方持久化到 `MusicSource.deviceId`,
    /// 之后登录即可跳过两步验证。
    public let deviceID: String?
}

/// 群晖 Audio Station 的有状态客户端:接口发现、登录与会话续期、翻页、取流。
/// iOS 连接器与 tvOS 解析器共用。协议细节都在 `SynologyAudioStationAPI`。
public actor SynologyAudioStationClient {
    public typealias QuickConnectResolver = @Sendable (String) async throws -> URL

    private struct Context: Sendable {
        let baseURL: URL
        let catalog: SynologyAudioStationAPICatalog
    }
    private struct Session: Sendable {
        let context: Context
        let sid: String
    }

    private let host: String
    private let port: Int?
    private let useSSL: Bool
    private let basePath: String?
    private let usesQuickConnect: Bool
    private let username: String
    private let password: String?
    private let deviceName: String?
    private var deviceID: String?
    private let transport: SynologyAudioStationRequestTransport
    private let quickConnectResolver: QuickConnectResolver
    private let ownedSessions: [URLSession]
    private var context: Context?
    private var session: Session?
    private var authTask: (id: UUID, task: Task<Session, Error>)?
    private var sessionGeneration = UUID()

    /// - Parameters:
    ///   - source: 已经投影到某条路由的音乐源;QuickConnect 模式下 `host` 是 QuickConnect ID。
    ///   - deviceName: 非空时随登录申请受信设备令牌(与群晖直连「记住此设备」同一做法)。
    public init(
        source: MusicSource,
        credential: SourceCredential?,
        deviceName: String? = nil,
        transport: SynologyAudioStationRequestTransport? = nil,
        quickConnectResolver: QuickConnectResolver? = nil
    ) {
        let usesQuickConnect = source.effectiveSynologyConnectionMode == .quickConnect
        host = source.host ?? ""
        port = source.port
        useSSL = source.useSsl
        basePath = source.basePath
        self.usesQuickConnect = usesQuickConnect
        username = credential?.username ?? source.username ?? ""
        password = credential?.password
        self.deviceName = deviceName
        deviceID = source.deviceId?.isEmpty == false ? source.deviceId : nil
        var ownedSessions: [URLSession] = []
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            configuration.httpMaximumConnectionsPerHost = 4
            // 只靠 `_sid` 认证:播放器拿到的链接不带 Cookie,客户端这边也不能依赖它。
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = StreamResolverSessionFactory.make(configuration: configuration)
            self.transport = SynologyAudioStationRequestTransport(
                data: { try await StreamResolverHTTPTransport.data(for: $0, session: session) },
                download: { try await StreamResolverHTTPTransport.download(for: $0, session: session) }
            )
            ownedSessions.append(session)
        }
        if let quickConnectResolver {
            self.quickConnectResolver = quickConnectResolver
        } else if usesQuickConnect {
            // 与群晖直连一致:QuickConnect 发现只用系统证书校验;证书有问题的候选作为
            // 最后兜底返回,由正式请求的信任代理去问用户。
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            self.quickConnectResolver = { try await SynologyQuickConnectResolver(session: session).resolve($0).baseURL }
            ownedSessions.append(session)
        } else {
            self.quickConnectResolver = { _ in throw SynologyAudioStationError.invalidURL }
        }
        self.ownedSessions = ownedSessions
    }

    deinit { ownedSessions.forEach { $0.invalidateAndCancel() } }

    // MARK: - 会话

    /// 丢掉会话、已发现的接口与 QuickConnect 路线。不发登出请求:它可能和新会话赛跑,
    /// 把刚登上的会话踢掉。
    public func invalidateSession() {
        sessionGeneration = UUID()
        authTask?.task.cancel()
        authTask = nil
        session = nil
        context = nil
    }

    /// 显式登录,用于两步验证:带上验证码,成功后返回新的受信设备令牌。
    public func login(otp: String? = nil) async throws -> SynologyAudioStationLogin {
        let generation = sessionGeneration
        authTask?.task.cancel()
        authTask = nil
        session = nil
        let (established, login) = try await establishSession(otp: otp)
        guard generation == sessionGeneration else { throw CancellationError() }
        session = established
        return login
    }

    public func logout() async {
        guard let current = session else { return }
        session = nil
        guard let endpoint = try? current.context.catalog.endpoint(for: .auth),
              let request = SynologyAudioStationAPI.request(
                for: SynologyAudioStationAPI.logoutCall(), baseURL: current.context.baseURL,
                endpoint: endpoint, sid: current.sid
              ) else { return }
        _ = try? await transport.data(request)
    }

    private func currentSession() async throws -> Session {
        try Task.checkCancellation()
        if let session { return session }
        let generation = sessionGeneration
        let pending: (id: UUID, task: Task<Session, Error>)
        if let authTask {
            pending = authTask
        } else {
            pending = (UUID(), Task { try await self.establishSession(otp: nil).0 })
            authTask = pending
        }
        do {
            let value = try await pending.task.value
            // 登录途中音乐源被失效时,不能让这次登录复活旧会话。
            guard generation == sessionGeneration else { throw CancellationError() }
            if authTask?.id == pending.id {
                session = value
                authTask = nil
            }
            try Task.checkCancellation()
            // 别的请求可能已经把这次登录换来的 `_sid` 判为失效并清掉了;这时仍交回
            // 等到的这份,由调用方按失效码走一次重登,而不是凭空报取消。
            return session ?? value
        } catch {
            if authTask?.id == pending.id { authTask = nil }
            throw error
        }
    }

    /// 迟到的失效响应只能作废发出它的那个 `_sid`,不能踢掉别的请求刚换来的新会话。
    private func expireSession(ifMatches sid: String) {
        if session?.sid == sid { session = nil }
    }

    private func establishSession(otp: String?) async throws -> (Session, SynologyAudioStationLogin) {
        guard !username.isEmpty, let password, !password.isEmpty else {
            throw SynologyAudioStationError.missingCredential
        }
        let context = try await apiContext()
        let call = SynologyAudioStationAPI.loginCall(
            account: username, password: password, otp: otp, deviceName: deviceName, deviceID: deviceID
        )
        guard let request = SynologyAudioStationAPI.request(
            for: call, baseURL: context.baseURL,
            endpoint: try context.catalog.endpoint(for: .auth), sid: nil
        ) else { throw SynologyAudioStationError.invalidURL }
        let (body, response) = try await transport.data(request)
        try Task.checkCancellation()
        try Self.validateStatus(response)
        switch try SynologyAudioStationAPI.decode(SynologyAudioStationLoginData.self, from: body) {
        case .success(let data):
            guard let sid = data.sid, !sid.isEmpty else { throw SynologyAudioStationError.invalidResponse }
            if let did = data.deviceID { deviceID = did }
            return (Session(context: context, sid: sid), SynologyAudioStationLogin(sid: sid, deviceID: data.deviceID))
        case .failure(let failure):
            throw SynologyAudioStationAPI.error(for: failure, call: call)
        }
    }

    /// 基址与接口表在重登之间复用;只有 `invalidateSession` 才会让它们重新发现。
    private func apiContext() async throws -> Context {
        if let context { return context }
        let generation = sessionGeneration
        let baseURL = try await resolvedBaseURL()
        guard let url = SynologyAudioStationAPI.discoveryURL(baseURL: baseURL) else {
            throw SynologyAudioStationError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await transport.data(request)
        try Task.checkCancellation()
        try Self.validateStatus(response)
        let descriptors: [String: SynologyAudioStationAPIDescriptor]
        switch try SynologyAudioStationAPI.decode(SynologyAudioStationAPIDescriptor.Table.self, from: body) {
        case .success(let table): descriptors = table.descriptors
        case .failure(let failure):
            throw SynologyAudioStationAPI.error(
                for: failure,
                call: SynologyAudioStationCall(interface: nil, apiName: "SYNO.API.Info", method: "query")
            )
        }
        let value = Context(baseURL: baseURL, catalog: try SynologyAudioStationAPI.negotiate(descriptors))
        if generation == sessionGeneration { context = value }
        return value
    }

    private func resolvedBaseURL() async throws -> URL {
        guard usesQuickConnect else {
            guard let url = SynologyAudioStationAPI.baseURL(host: host, port: port, useSSL: useSSL, basePath: basePath) else {
                throw SynologyAudioStationError.invalidURL
            }
            return url
        }
        // QuickConnect 解析出的就是 DSM 根地址,不再叠加反代前缀。
        return try await quickConnectResolver(host)
    }

    // MARK: - 请求执行

    private func perform<Value: Decodable & Sendable>(
        _ call: SynologyAudioStationCall,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        for attempt in 0...1 {
            let session = try await currentSession()
            let endpoint = try session.context.catalog.endpoint(for: try Self.interface(of: call))
            guard let request = SynologyAudioStationAPI.request(
                for: call, baseURL: session.context.baseURL, endpoint: endpoint, sid: session.sid
            ) else { throw SynologyAudioStationError.invalidURL }
            let (body, response) = try await transport.data(request)
            try Task.checkCancellation()
            try Self.validateStatus(response)
            switch try SynologyAudioStationAPI.decode(Value.self, from: body) {
            case .success(let value):
                return value
            case .failure(let failure):
                if attempt == 0, SynologyAudioStationAPI.renewsSession(after: failure.code) {
                    expireSession(ifMatches: session.sid)
                    continue
                }
                throw SynologyAudioStationAPI.error(for: failure, call: call)
            }
        }
        throw SynologyAudioStationError.invalidResponse
    }

    /// 二进制端点:返回响应本身,以及(重登一次之后仍然存在的)DSM 错误体。
    private func raw(
        _ call: SynologyAudioStationCall,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse, SynologyAudioStationFailure?) {
        for attempt in 0...1 {
            let session = try await currentSession()
            var request = try Self.getRequest(call, session: session)
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            let (body, response) = try await transport.data(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SynologyAudioStationError.invalidResponse }
            let failure = SynologyAudioStationAPI.failureEnvelope(in: body, response: http)
            if let failure, attempt == 0, SynologyAudioStationAPI.renewsSession(after: failure.code) {
                expireSession(ifMatches: session.sid)
                continue
            }
            return (body, http, failure)
        }
        throw SynologyAudioStationError.invalidResponse
    }

    private static func getRequest(_ call: SynologyAudioStationCall, session: Session) throws -> URLRequest {
        let endpoint = try session.context.catalog.endpoint(for: try interface(of: call))
        guard let url = SynologyAudioStationAPI.url(
            for: call, baseURL: session.context.baseURL, endpoint: endpoint, sid: session.sid
        ) else { throw SynologyAudioStationError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func interface(of call: SynologyAudioStationCall) throws -> SynologyAudioStationInterface {
        guard let interface = call.interface else { throw SynologyAudioStationError.invalidURL }
        return interface
    }

    private static func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SynologyAudioStationError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SynologyAudioStationError.badServerResponse(http.statusCode)
        }
    }

    // MARK: - 曲库

    public func info() async throws -> SynologyAudioStationInfo {
        try await perform(SynologyAudioStationAPI.infoCall())
    }

    public func songPage(offset: Int, limit: Int = SynologyAudioStationAPI.pageSize) async throws -> SynologyAudioStationSongPage {
        guard offset >= 0, (1...5_000).contains(limit) else { throw SynologyAudioStationError.invalidResponse }
        return try await perform(SynologyAudioStationAPI.songListCall(offset: offset, limit: limit))
    }

    /// 整库逐页拉取。任何一页对不上(总数变化、重复 id、中途短页),或走完后总数
    /// 已经变了,都以 `invalidResponse` 结束,调用方不能据此删歌。
    public func songs(pageSize: Int = SynologyAudioStationAPI.pageSize) -> AsyncThrowingStream<SynologyAudioStationSong, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var pagination = SynologyAudioStationCatalogPagination()
                    var total = 0
                    while true {
                        try Task.checkCancellation()
                        let page = try await self.songPage(offset: pagination.offset, limit: pageSize)
                        let finished = try pagination.accept(page, requestedLimit: pageSize)
                        for song in page.songs {
                            try Task.checkCancellation()
                            continuation.yield(song)
                        }
                        if finished {
                            total = page.total
                            break
                        }
                    }
                    guard try await self.songPage(offset: 0, limit: 1).total == total else {
                        throw SynologyAudioStationError.invalidResponse
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - 歌单

    /// 全部歌单(个人 + 共享),已去掉系统内部歌单。智能歌单保留但标为只读。
    public func playlists() async throws -> [SynologyAudioStationPlaylist] {
        var values: [SynologyAudioStationPlaylist] = []
        var expectedTotal: Int?
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            let page: SynologyAudioStationPlaylistPage = try await perform(
                SynologyAudioStationAPI.playlistListCall(offset: values.count, limit: SynologyAudioStationAPI.pageSize)
            )
            guard page.total >= 0, page.offset == nil || page.offset == values.count,
                  expectedTotal == nil || expectedTotal == page.total,
                  page.playlists.count <= SynologyAudioStationAPI.pageSize,
                  page.playlists.count <= page.total - values.count else {
                throw SynologyAudioStationError.invalidResponse
            }
            expectedTotal = page.total
            for playlist in page.playlists {
                guard seen.insert(playlist.id).inserted else { throw SynologyAudioStationError.invalidResponse }
            }
            values.append(contentsOf: page.playlists)
            if values.count == page.total { return values.filter { !$0.isSystem } }
            guard page.playlists.count == SynologyAudioStationAPI.pageSize else {
                throw SynologyAudioStationError.invalidResponse
            }
        }
    }

    /// 歌单曲目按服务端顺序排列,长度等于 `songs_total`。尚未入库的条目也在其中
    /// (`isCatalogSongID` 为 false):`updatesongs` 按下标剪接,位置必须与服务端一致。
    public func playlistTrackIDs(id: String, pageSize: Int = SynologyAudioStationAPI.pageSize) async throws -> [String] {
        guard SynologyAudioStationAPI.isPlaylistID(id), pageSize > 0 else { throw SynologyAudioStationError.invalidResponse }
        var pagination = SynologyAudioStationPlaylistPagination()
        var ids: [String] = []
        while true {
            try Task.checkCancellation()
            let page: SynologyAudioStationPlaylistSongsPage = try await perform(
                SynologyAudioStationAPI.playlistInfoCall(id: id, songsOffset: pagination.offset, songsLimit: pageSize)
            )
            guard page.playlist.id == id else { throw SynologyAudioStationError.invalidResponse }
            let finished = try pagination.accept(page, requestedLimit: pageSize)
            ids.append(contentsOf: page.songs.map(\.id))
            if finished { return ids }
        }
    }

    public func createPlaylist(name: String, shared: Bool = false) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SynologyAudioStationError.invalidResponse }
        let created: SynologyAudioStationCreatedPlaylist = try await perform(
            SynologyAudioStationAPI.createPlaylistCall(name: trimmed, shared: shared)
        )
        guard let id = created.id, SynologyAudioStationAPI.isPlaylistID(id) else {
            throw SynologyAudioStationError.invalidResponse
        }
        return id
    }

    public func renamePlaylist(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateWritablePlaylist(id)
        guard !trimmed.isEmpty else { throw SynologyAudioStationError.invalidResponse }
        let _: SynologyAudioStationEmpty = try await perform(
            SynologyAudioStationAPI.renamePlaylistCall(id: id, newName: trimmed)
        )
    }

    public func deletePlaylist(id: String) async throws {
        guard SynologyAudioStationAPI.isPlaylistID(id) else { throw SynologyAudioStationError.invalidResponse }
        let _: SynologyAudioStationEmpty = try await perform(SynologyAudioStationAPI.deletePlaylistCall(id: id))
    }

    /// 从 `offset` 起删掉 `limit` 首,再在 `offset` 处插入 `songIDs`(服务端的剪接语义)。
    public func updatePlaylistSongs(id: String, offset: Int, limit: Int, songIDs: [String]) async throws {
        try Self.validateWritablePlaylist(id)
        guard offset >= 0, limit >= 0, songIDs.allSatisfy(SynologyAudioStationAPI.isCatalogSongID) else {
            throw SynologyAudioStationError.invalidResponse
        }
        let _: SynologyAudioStationEmpty = try await perform(SynologyAudioStationAPI.updatePlaylistSongsCall(
            id: id, offset: offset, limit: limit, songIDs: songIDs, skipDuplicates: false
        ))
    }

    /// 追加到末尾;已在歌单里的歌由服务端跳过,不会让整次调用失败。
    public func appendToPlaylist(id: String, songIDs: [String]) async throws {
        try Self.validateWritablePlaylist(id)
        guard !songIDs.isEmpty, songIDs.allSatisfy(SynologyAudioStationAPI.isCatalogSongID) else {
            throw SynologyAudioStationError.invalidResponse
        }
        let _: SynologyAudioStationEmpty = try await perform(SynologyAudioStationAPI.updatePlaylistSongsCall(
            id: id, offset: -1, limit: 0, songIDs: songIDs, skipDuplicates: true
        ))
    }

    private static func validateWritablePlaylist(_ id: String) throws {
        guard SynologyAudioStationAPI.isPlaylistID(id) else { throw SynologyAudioStationError.invalidResponse }
        guard !SynologyAudioStationAPI.isSmartPlaylistID(id) else { throw SynologyAudioStationError.operationNotPermitted }
    }

    // MARK: - 电台

    public func radios(
        in container: SynologyAudioStationRadioContainer,
        pageSize: Int = SynologyAudioStationAPI.pageSize
    ) async throws -> [SynologyAudioStationRadio] {
        try await radios(inContainer: container.rawValue, pageSize: pageSize)
    }

    /// 一个电台容器(或 SHOUTcast 流派)里的全部条目,按服务端顺序。总数对不上就整体失败,
    /// 调用方不能据此删镜像。
    public func radios(
        inContainer container: String,
        pageSize: Int = SynologyAudioStationAPI.pageSize
    ) async throws -> [SynologyAudioStationRadio] {
        guard pageSize > 0 else { throw SynologyAudioStationError.invalidResponse }
        var values: [SynologyAudioStationRadio] = []
        var expectedTotal: Int?
        while true {
            try Task.checkCancellation()
            let page: SynologyAudioStationRadioPage = try await perform(
                SynologyAudioStationAPI.radioListCall(container: container, offset: values.count, limit: pageSize)
            )
            guard page.total >= 0, page.offset == nil || page.offset == values.count,
                  expectedTotal == nil || expectedTotal == page.total,
                  page.radios.count <= page.total - values.count else {
                throw SynologyAudioStationError.invalidResponse
            }
            expectedTotal = page.total
            values.append(contentsOf: page.radios)
            if values.count == page.total { return values }
            guard page.radios.count == pageSize else { throw SynologyAudioStationError.invalidResponse }
        }
    }

    // MARK: - 评分与歌词

    /// nil 表示没评分(服务端的 0)。
    public func rating(id: String) async throws -> Int? {
        guard SynologyAudioStationAPI.isCatalogSongID(id) else { throw SynologyAudioStationError.invalidResponse }
        let info: SynologyAudioStationSongInfo = try await perform(SynologyAudioStationAPI.songInfoCall(id: id))
        guard let song = info.songs.first(where: { $0.id == id }),
              (0...5).contains(song.rawRating ?? 0) else { throw SynologyAudioStationError.invalidResponse }
        return song.userRating
    }

    /// 写入 1–5,nil 清除(发 0)。写完读回确认,返回服务端确认后的值。
    public func setRating(id: String, rating: Int?) async throws -> Int? {
        guard SynologyAudioStationAPI.isCatalogSongID(id),
              rating.map({ (1...5).contains($0) }) ?? true else { throw SynologyAudioStationError.invalidResponse }
        // `setrating` 从 Song v2 才有。
        guard try await currentSession().context.catalog.endpoint(for: .song).version >= 2 else {
            throw SynologyAudioStationError.unsupportedVersion(api: SynologyAudioStationInterface.song.rawValue)
        }
        let _: SynologyAudioStationEmpty = try await perform(
            SynologyAudioStationAPI.setRatingCall(id: id, rating: rating ?? 0)
        )
        let confirmed = try await self.rating(id: id)
        guard confirmed == rating else { throw SynologyAudioStationError.invalidResponse }
        return confirmed
    }

    /// 服务端存的歌词原文(通常是 LRC);空串视为没有。
    public func lyrics(id: String) async throws -> String? {
        guard SynologyAudioStationAPI.isCatalogSongID(id) else { throw SynologyAudioStationError.invalidResponse }
        let data: SynologyAudioStationLyricsData = try await perform(SynologyAudioStationAPI.lyricsCall(id: id))
        guard let text = data.lyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - 封面与音频

    /// 响应不是图片(没有封面时的 JSON 错误体、404)一律返回 nil,调用方接着走自己的刮削。
    public func artwork(reference: String, maxBytes: Int) async throws -> Data? {
        guard maxBytes > 0, let parsed = SynologyAudioStationCoverReference(rawValue: reference) else {
            throw SynologyAudioStationError.invalidResponse
        }
        let (body, http, failure) = try await raw(SynologyAudioStationAPI.coverCall(for: parsed))
        if let failure {
            // 重登之后仍然失效就是真的登不上,不能伪装成「没有封面」。
            if SynologyAudioStationAPI.renewsSession(after: failure.code), failure.code != 105 {
                throw SynologyAudioStationAPI.error(for: failure, call: SynologyAudioStationAPI.coverCall(for: parsed))
            }
            return nil
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SynologyAudioStationError.badServerResponse(http.statusCode)
        }
        guard body.count <= maxBytes else { throw SynologyAudioStationError.invalidResponse }
        return SynologyAudioStationAPI.isImageData(body) ? body : nil
    }

    /// 交给播放层的链接,带当前 `_sid`。虚拟音轨不传 `transcode` 也会转成 mp3。
    /// `extraQueryItems` 供连接器挂播放层标记,排在 `_sid` 之前。
    public func streamURL(
        id: String,
        transcode: SynologyAudioStationTranscodeFormat? = nil,
        extraQueryItems: [URLQueryItem] = []
    ) async throws -> URL {
        guard SynologyAudioStationAPI.isCatalogSongID(id) else { throw SynologyAudioStationError.invalidResponse }
        let session = try await currentSession()
        guard let url = SynologyAudioStationAPI.streamURL(
            baseURL: session.context.baseURL,
            endpoint: try session.context.catalog.endpoint(for: .stream),
            id: id, transcode: transcode, extraQueryItems: extraQueryItems, sid: session.sid
        ) else { throw SynologyAudioStationError.invalidURL }
        return url
    }

    /// 原始流的一段。只接受与请求窗口完全一致的 206;服务端忽略 Range 回 200 时报
    /// `rangeNotSupported`,让调用方改走整曲下载,而不是把整份文件当成这一段塞进稀疏缓存。
    public func fetchRange(id: String, offset: Int64, length: Int64) async throws -> Data {
        guard SynologyAudioStationAPI.isCatalogSongID(id) else { throw SynologyAudioStationError.invalidResponse }
        guard !SynologyAudioStationAPI.isVirtualTrackID(id) else { throw SynologyAudioStationError.transcodeRequired }
        guard length > 0, length <= Int64(Int.max),
              let range = SafeByteRange.httpHeader(offset: offset, length: length) else {
            throw SynologyAudioStationError.invalidResponse
        }
        let call = SynologyAudioStationAPI.streamCall(id: id, transcode: nil)
        let (body, http, failure) = try await raw(call, headers: ["Range": range, "Accept-Encoding": "identity"])
        if let failure { throw SynologyAudioStationAPI.error(for: failure, call: call) }
        if http.statusCode == 200 { throw SynologyAudioStationError.rangeNotSupported }
        guard http.statusCode == 206 else {
            throw (200...299).contains(http.statusCode)
                ? SynologyAudioStationError.invalidResponse
                : SynologyAudioStationError.badServerResponse(http.statusCode)
        }
        guard HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
            bodyLength: body.count, requestedOffset: offset, requestedLength: length
        ) != nil else { throw SynologyAudioStationError.invalidResponse }
        return body
    }

    /// 整份原文件,走与 `fetchRange` 同一个 `method=stream` 端点:字节与目录里的
    /// `filesize` 一致,缓存校验才对得上。`SYNO.AudioStation.Download` 的参数没有可靠资料,
    /// 且受 `settings.enable_download` 开关限制,不用它。
    public func downloadOriginal(id: String) async throws -> URL {
        guard SynologyAudioStationAPI.isCatalogSongID(id) else { throw SynologyAudioStationError.invalidResponse }
        guard !SynologyAudioStationAPI.isVirtualTrackID(id) else { throw SynologyAudioStationError.transcodeRequired }
        let call = SynologyAudioStationAPI.streamCall(id: id, transcode: nil)
        for attempt in 0...1 {
            let session = try await currentSession()
            var request = try Self.getRequest(call, session: session)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (file, response) = try await transport.download(request)
            do {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw SynologyAudioStationError.invalidResponse }
                let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                if size <= 64 * 1_024,
                   let failure = SynologyAudioStationAPI.failureEnvelope(in: try Data(contentsOf: file), response: http) {
                    if attempt == 0, SynologyAudioStationAPI.renewsSession(after: failure.code) {
                        expireSession(ifMatches: session.sid)
                        try? FileManager.default.removeItem(at: file)
                        continue
                    }
                    throw SynologyAudioStationAPI.error(for: failure, call: call)
                }
                let mime = http.mimeType?.lowercased() ?? ""
                guard http.statusCode == 200, size > 0,
                      http.expectedContentLength < 0 || http.expectedContentLength == Int64(size),
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
}

// MARK: - 曲目映射

extension SynologyAudioStationSong {
    /// 映射成 Primuse 的曲目。id 不是目录曲目(歌单里尚未入库的条目)或格式认不出时返回 nil。
    ///
    /// `Song.id` 只由音乐源与服务端曲目 id 决定,不含扩展名:容器识别口径以后变了
    /// (比如 m4a 的归类),歌单、收藏与播放记录也不会跟着断。
    public func makeSong(sourceID: String) -> Song? {
        guard let format = audioFormat, let filePath = trackPath else { return nil }
        let artist = MediaMetadataTextRepair.repaired(artist)
        return Song(
            id: Self.digest("\(sourceID):synology-audiostation:\(id)"),
            title: displayTitle,
            albumTitle: MediaMetadataTextRepair.repaired(album),
            artistName: artist,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: MediaMetadataTextRepair.repaired(albumArtist),
                trackArtistName: artist
            ),
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: max(0, duration ?? 0),
            fileFormat: format,
            filePath: filePath,
            sourceID: sourceID,
            // 虚拟音轨播的是现转的 mp3,目录里的大小不是响应的大小。
            fileSize: isVirtualTrack ? 0 : max(0, fileSize ?? 0),
            bitRate: bitRateKbps,
            sampleRate: isVirtualTrack ? nil : sampleRate.flatMap { $0 > 0 ? $0 : nil },
            genre: genre,
            year: year,
            coverArtFileName: coverReference?.rawValue,
            replayGainTrackGain: replayGainTrackGain,
            replayGainTrackPeak: replayGainTrackPeak,
            replayGainAlbumGain: replayGainAlbumGain,
            replayGainAlbumPeak: replayGainAlbumPeak,
            revision: "audiostation:\(fileSize ?? 0):\(Int((duration ?? 0).rounded())):\(container ?? "")"
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 歌单镜像

/// 一份服务端歌单在本地只读镜像里的样子。iPhone、Mac 的连接器与电视端共用这一份
/// 规则,同一份服务端歌单在三端得出同样的镜像 id 与曲目。
public struct SynologyAudioStationPlaylistMirror: Equatable, Sendable {
    public let id: String
    public let name: String
    /// 服务端顺序;尚未入库的条目(id 是 NAS 路径)匹配不到任何一首歌,已经去掉。
    public let trackIDs: [String]
}

public struct SynologyAudioStationPlaylistMirrorSnapshot: Equatable, Sendable {
    public let playlists: [SynologyAudioStationPlaylistMirror]
    /// 出现在歌单列表里、但这次没能取全曲目的歌单(镜像 id)。调用方要保留它们
    /// 已有的镜像,不能当成服务端已删除。
    public let failedPlaylistIDs: Set<String>

    /// Audio Station 的歌单 id 里带着名字与斜杠(`playlist_personal_normal/开车`)。
    /// 镜像身份只用它的摘要,本地歌单 id 里不出现任意文字。
    public static func mirrorID(for serverPlaylistID: String) -> String {
        let digest = SHA256.hash(data: Data(serverPlaylistID.utf8))
        return "as-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 歌单列表取不到就整体失败;某一份歌单的曲目取不到只记进 `failedPlaylistIDs`,
    /// 不影响其他歌单。取数由调用方传入:iPhone 端的每次请求要经过自己的
    /// QuickConnect 路线失效处理。
    public static func collect(
        playlists: @Sendable () async throws -> [SynologyAudioStationPlaylist],
        trackIDs: @Sendable (String) async throws -> [String]
    ) async throws -> SynologyAudioStationPlaylistMirrorSnapshot {
        var mirrors: [SynologyAudioStationPlaylistMirror] = []
        var failed: Set<String> = []
        for playlist in try await playlists() {
            try Task.checkCancellation()
            let mirrorID = mirrorID(for: playlist.id)
            do {
                let ids = try await trackIDs(playlist.id).filter(SynologyAudioStationAPI.isCatalogSongID)
                mirrors.append(SynologyAudioStationPlaylistMirror(id: mirrorID, name: playlist.name, trackIDs: ids))
            } catch let error where OperationCancellationPolicy.isCancellation(error) {
                throw CancellationError()
            } catch {
                failed.insert(mirrorID)
            }
        }
        return SynologyAudioStationPlaylistMirrorSnapshot(playlists: mirrors, failedPlaylistIDs: failed)
    }
}

extension SynologyAudioStationClient {
    /// 直接用这个客户端取数的镜像快照(电视端)。
    public func playlistMirrorSnapshot() async throws -> SynologyAudioStationPlaylistMirrorSnapshot {
        try await SynologyAudioStationPlaylistMirrorSnapshot.collect(
            playlists: { try await self.playlists() },
            trackIDs: { try await self.playlistTrackIDs(id: $0) }
        )
    }

    public func radioMirrors() async throws -> [SynologyAudioStationRadioMirror] {
        try await SynologyAudioStationRadioMirror.collect(radios: { try await self.radios(inContainer: $0) })
    }
}

// MARK: - 电台镜像

/// Audio Station「INTERNET 广播」里的一个台:收藏的、自己添加的,或 SHOUTcast 某个流派里的。
public struct SynologyAudioStationRadioMirror: Equatable, Sendable {
    /// 由 NAS 上存的地址派生:服务端 id 里带着名字,改名就会变。
    public let id: String
    public let name: String
    /// NAS 上存的地址,SHOUTcast 的台是 `.pls` 包装,播放时再拆。
    public let url: String
    public let folder: SynologyAudioStationRadioFolder

    /// 流派并发读取的上限:DSM 每读一个流派都要现去问 SHOUTcast,逐个读要几十秒。
    static let genreConcurrency = 4

    public static func mirrorID(forStationURL url: String) -> String? {
        guard let key = RadioImportParser.streamIdentityKey(url) else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return "as-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 依次收集「我收藏的广播」「用户定义的广播」与 SHOUTcast 各流派(服务端顺序);
    /// 同一个地址出现多次时只留第一次。没有可用地址的条目、流派里再套的目录跳过。
    /// 任何一个容器或流派取不到就整体失败 —— 残缺的列表会让缺掉的那部分被当成服务端已删。
    public static func collect(
        radios: @escaping @Sendable (String) async throws -> [SynologyAudioStationRadio]
    ) async throws -> [SynologyAudioStationRadioMirror] {
        var groups: [(folder: SynologyAudioStationRadioFolder, radios: [SynologyAudioStationRadio])] = [
            (.favorite, try await radios(SynologyAudioStationRadioContainer.favorite.rawValue)),
            (.userDefined, try await radios(SynologyAudioStationRadioContainer.userDefined.rawValue)),
        ]
        let genres = try await radios(SynologyAudioStationRadioContainer.shoutcast.rawValue).compactMap { entry
            -> (id: String, name: String)? in
            guard entry.isContainer, let id = entry.id, !id.isEmpty else { return nil }
            let name = RadioStationValidation.normalizedName(entry.title ?? "")
            return (id, name.isEmpty ? id : name)
        }
        let genreRadios = try await withThrowingTaskGroup(
            of: (index: Int, radios: [SynologyAudioStationRadio]).self
        ) { group -> [[SynologyAudioStationRadio]] in
            var results = Array(repeating: [SynologyAudioStationRadio](), count: genres.count)
            var next = 0
            while next < min(genreConcurrency, genres.count) {
                let index = next
                group.addTask { (index, try await radios(genres[index].id)) }
                next += 1
            }
            while let finished = try await group.next() {
                results[finished.index] = finished.radios
                if next < genres.count {
                    let index = next
                    group.addTask { (index, try await radios(genres[index].id)) }
                    next += 1
                }
            }
            return results
        }
        for (genre, entries) in zip(genres, genreRadios) {
            groups.append((.genre(genre.name), entries))
        }

        var mirrors: [SynologyAudioStationRadioMirror] = []
        var seen: Set<String> = []
        for group in groups {
            for radio in group.radios {
                try Task.checkCancellation()
                guard !radio.isContainer,
                      let url = radio.url.flatMap(RadioStationValidation.normalizedURLString),
                      let id = mirrorID(forStationURL: url),
                      seen.insert(id).inserted else { continue }
                let title = RadioStationValidation.normalizedName(radio.title ?? "")
                mirrors.append(SynologyAudioStationRadioMirror(
                    id: id,
                    name: title.isEmpty ? RadioImportParser.suggestedName(for: url) : title,
                    url: url,
                    folder: group.folder
                ))
            }
        }
        return mirrors
    }
}
