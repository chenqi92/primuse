import Foundation

/// 群晖 Audio Station 的播放解析(tvOS):从 `/songs/<目录曲目 id>.<扩展名>` 取回
/// 曲目 id,交出带 `_sid` 的 `method=stream` 链接。整轨(CUE)切出来的虚拟音轨
/// (`music_v_`)由客户端自动改成服务端现转的 mp3。
///
/// 每个音乐源缓存一个 `SynologyAudioStationClient`:接口发现、QuickConnect 解析与
/// 登录会话都跟着它复用;地址、账号、受信设备令牌或凭据一变就换一个新的。注册表
/// 传进来的是已经投影到某条路由的音乐源,`synologyConnectionMode` 与这条路由一致,
/// QuickConnect 由客户端自己解析。
public actor SynologyAudioStationStreamResolver: StreamResolver {
    private struct Configuration: Equatable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let connectionMode: SynologyConnectionMode
        let sourceUsername: String?
        let deviceID: String?
        let credential: SourceCredential?
    }

    private struct Entry {
        let configuration: Configuration
        let client: SynologyAudioStationClient
    }

    /// 两步验证时随登录申请受信设备令牌用的设备名,与群晖直连在电视上的写法一致。
    public static let trustedDeviceName = "Apple TV"

    private var clients: [String: Entry] = [:]
    private let transport: SynologyAudioStationRequestTransport?
    private let quickConnectResolver: SynologyAudioStationClient.QuickConnectResolver?

    /// 两个参数只给测试注入;不传时客户端用电视端的证书信任与明文确认流程。
    public init(
        transport: SynologyAudioStationRequestTransport? = nil,
        quickConnectResolver: SynologyAudioStationClient.QuickConnectResolver? = nil
    ) {
        self.transport = transport
        self.quickConnectResolver = quickConnectResolver
    }

    public func streamURL(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> URL {
        guard source.type == .synologyAudioStation else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        guard let id = SynologyAudioStationAPI.songID(fromTrackPath: song.filePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        let client = client(source: source, credential: credential)
        do {
            // 先用一次轻量请求确认会话还有效(过期时客户端自己重登一次),免得交出
            // 一个播放器那边才发现已失效的链接。与 iPhone 端连接器同一做法。
            _ = try await client.info()
            return try await client.streamURL(id: id)
        } catch {
            throw Self.streamError(from: error)
        }
    }

    public func invalidateSession(sourceID: String) async {
        guard let entry = clients.removeValue(forKey: sourceID) else { return }
        await entry.client.invalidateSession()
    }

    /// 两步验证:带验证码登录并申请受信设备令牌。与 iPhone 端一致,验证码通过之后
    /// 还要确认这个账号确实能用 Audio Station,才把令牌交回去保存。
    ///
    /// 这里用一次性的客户端:调用方保存令牌后会让这个源的会话失效,之后按新的
    /// `deviceId` 另建客户端,登录时带上它就不再要验证码。
    public func loginForDeviceToken(
        source: MusicSource,
        credential: SourceCredential?,
        otp: String
    ) async throws -> String? {
        guard source.type == .synologyAudioStation else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let client = SynologyAudioStationClient(
            source: source,
            credential: credential,
            deviceName: Self.trustedDeviceName,
            transport: transport,
            quickConnectResolver: quickConnectResolver
        )
        do {
            let login = try await client.login(otp: otp)
            _ = try await client.info()
            return login.deviceID
        } catch {
            throw Self.streamError(from: error)
        }
    }

    /// 电视端的界面与重试只认 `StreamResolveError`:缺凭据、账号密码错、要验证码
    /// 这几类必须落到它上面,才会引导去输凭据或验证码。其余(账号没有 Audio Station
    /// 权限、套件没装、服务端繁忙……)保留原样,由它自己的错误描述说清原因。
    /// 电视端的目录校验与整库扫描也用这一份映射。
    public nonisolated static func streamError(from error: Error) -> Error {
        guard let failure = error as? SynologyAudioStationError else { return error }
        switch failure {
        case .missingCredential:
            return StreamResolveError.missingCredential
        case .invalidCredentials:
            return StreamResolveError.authFailed
        case .twoFactorRequired, .invalidOneTimePassword:
            return StreamResolveError.needs2FA
        case .invalidURL:
            return StreamResolveError.cannotBuildURL
        case .badServerResponse(let status):
            return StreamResolveError.badServerResponse(status)
        default:
            return failure
        }
    }

    private func client(
        source: MusicSource,
        credential: SourceCredential?
    ) -> SynologyAudioStationClient {
        let configuration = Configuration(
            host: source.host,
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath,
            connectionMode: source.effectiveSynologyConnectionMode,
            sourceUsername: source.username,
            deviceID: source.deviceId,
            credential: credential
        )
        if let entry = clients[source.id], entry.configuration == configuration {
            return entry.client
        }
        if let stale = clients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = SynologyAudioStationClient(
            source: source,
            credential: credential,
            transport: transport,
            quickConnectResolver: quickConnectResolver
        )
        clients[source.id] = Entry(configuration: configuration, client: client)
        return client
    }
}
