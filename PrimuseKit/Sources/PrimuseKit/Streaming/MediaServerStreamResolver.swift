import Foundation

/// 媒体服务器(Jellyfin / Emby / Plex)流式解析。播放地址鉴权全在 query,AVPlayer 直连。
///
/// - Jellyfin/Emby:用户名+密码登录(/Users/AuthenticateByName)拿 AccessToken,
///   或直接使用 API key；音频流地址为
///   `/Audio/{itemId}/stream?Static=true&api_key={token}`。
/// - Plex:token 即 secret(无需登录),需先取 /library/metadata/{ratingKey} 拿到
///   partKey,再拼 `{partKey}?X-Plex-Token={token}`。
///
/// 字段映射(同 iOS MediaServerSource):host/port/useSsl/basePath;Jellyfin/Emby 的
/// username+password、Plex 的 token 都来自同步凭据;song.filePath = `/items/{id}.{ext}`。
public actor MediaServerStreamResolver: StreamResolver {
    private struct CachedSession: Sendable {
        let account: SourceLoginSessionStore.Account
        let token: String
    }

    /// Jellyfin/Emby 的播放和扫描、收藏等共用同一个登录会话（见 `SourceLoginSessionStore`）：
    /// 交给播放器的地址里的 token 不会因为别处重新登录而失效。
    private let sessionStore: SourceLoginSessionStore
    private var sessions: [String: CachedSession] = [:]
    private var sessionHolders: [String: UUID] = [:]
    private var sessionGenerations: [String: UInt64] = [:]
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = StreamResolverSessionFactory.make(configuration: cfg)
        self.sessionStore = .shared
    }

    deinit { session.invalidateAndCancel() }

    /// Module-internal injection point for deterministic URLProtocol tests.
    init(session: URLSession, sessionStore: SourceLoginSessionStore = SourceLoginSessionStore()) {
        self.session = session
        self.sessionStore = sessionStore
    }

    /// 播放端作废会话多半是因为播放地址被拒：连同共用会话里的这个 token 一起作废，
    /// 下次取到的是重新登录的，而不是同一个已经失效的。别的实例已经换过就不动。
    public func invalidateSession(sourceID: String) async {
        sessionGenerations[sourceID, default: 0] &+= 1
        guard let cached = sessions.removeValue(forKey: sourceID) else { return }
        await sessionStore.invalidate(cached.account, ifCurrent: cached.token)
        if let holder = sessionHolders.removeValue(forKey: sourceID) {
            await sessionStore.release(cached.account, holder: holder, token: nil)
        }
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        guard let base = Self.baseURL(host: source.host ?? "", port: source.port, useSsl: source.useSsl,
                                      basePath: source.basePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        guard let itemID = Self.itemID(from: song.filePath) else { throw StreamResolveError.cannotBuildURL }
        let isLiveRadio = ServerRadioStationIdentity.isMediaServerPlaybackPath(song.filePath)

        switch source.type {
        case .plex:
            guard let token = cred.password ?? cred.token, !token.isEmpty else {
                throw StreamResolveError.missingCredential
            }
            let partKey = try await plexPartKey(base: base, ratingKey: itemID, token: token,
                                                deviceID: MediaServerDeviceIdentity.deviceID(sourceID: source.id))
            guard let url = Self.plexStreamURL(base: base, partKey: partKey, token: token) else {
                throw StreamResolveError.cannotBuildURL
            }
            return url
        case .jellyfin, .emby:
            if source.authType == .apiKey {
                guard let token = cred.password ?? cred.token, !token.isEmpty else {
                    throw StreamResolveError.missingCredential
                }
                let url = isLiveRadio
                    ? Self.jellyfinLiveRadioStreamURL(base: base, itemID: itemID, token: token)
                    : Self.jellyfinStreamURL(base: base, itemID: itemID, token: token)
                guard let url else {
                    throw StreamResolveError.cannotBuildURL
                }
                return url
            }

            let username = (cred.username ?? source.username ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else {
                throw StreamResolveError.missingCredential
            }
            // Passwordless Jellyfin/Emby users are valid. Preserve an absent
            // Keychain entry as an empty Pw instead of treating it as missing.
            let password = cred.password ?? ""
            let token = try await currentToken(source: source, base: base, username: username,
                                               password: password, emby: source.type == .emby)
            let url = isLiveRadio
                ? Self.jellyfinLiveRadioStreamURL(base: base, itemID: itemID, token: token)
                : Self.jellyfinStreamURL(base: base, itemID: itemID, token: token)
            guard let url else {
                throw StreamResolveError.cannotBuildURL
            }
            return url
        default:
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
    }

    // MARK: - Jellyfin / Emby 登录

    private func currentToken(source: MusicSource, base: URL, username: String,
                              password: String, emby: Bool) async throws -> String {
        let account = SourceLoginSessionStore.Account(
            sourceID: source.id, username: username, secret: password, qualifiers: [source.type.rawValue]
        )
        if let cached = sessions[source.id], cached.account == account { return cached.token }
        if let stale = sessions.removeValue(forKey: source.id), let holder = sessionHolders[source.id] {
            // 凭据换了：旧凭据的会话由它自己的持有者决定去留。
            await sessionStore.release(stale.account, holder: holder, token: nil)
        }
        let holder = sessionHolders[source.id] ?? UUID()
        sessionHolders[source.id] = holder
        let generation = sessionGenerations[source.id, default: 0]
        let deviceID = MediaServerDeviceIdentity.deviceID(sourceID: source.id)
        let session = try await sessionStore.session(
            for: account,
            route: SourceLoginSessionStore.Route(endpoint: base),
            holder: holder
        ) { [self] in
            try await login(base: base, username: username, password: password, deviceID: deviceID, emby: emby)
        }
        guard sessionGenerations[source.id, default: 0] == generation else { throw CancellationError() }
        sessions[source.id] = CachedSession(account: account, token: session.token)
        return session.token
    }

    private func login(
        base: URL,
        username: String,
        password: String,
        deviceID: String,
        emby: Bool
    ) async throws -> SourceLoginSessionStore.Session {
        var req = URLRequest(
            url: ProxyPrefixedBasePathPolicy.appending("Users/AuthenticateByName", to: base)
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authValue = Self.mediaBrowserAuth(deviceID: deviceID, token: nil)
        req.setValue(authValue, forHTTPHeaderField: emby ? "X-Emby-Authorization" : "Authorization")
        req.httpBody = try? SafeJSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: req,
            session: session
        )
        try Self.checkAuth(response)
        guard let token = Self.parseAccessToken(data) else { throw StreamResolveError.authFailed }
        return SourceLoginSessionStore.Session(token: token, userID: Self.parseUserID(data))
    }

    // MARK: - Plex 元数据 → partKey

    private func plexPartKey(base: URL, ratingKey: String, token: String, deviceID: String) async throws -> String {
        var req = URLRequest(
            url: ProxyPrefixedBasePathPolicy.appending("library/metadata/\(ratingKey)", to: base)
        )
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue("Primuse", forHTTPHeaderField: "X-Plex-Product")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: req,
            session: session
        )
        try Self.checkAuth(response)
        guard let key = Self.parsePlexPartKey(data) else { throw StreamResolveError.cannotBuildURL }
        return key
    }

    // MARK: - 纯函数(可单测)

    /// host 自带的那截路径以前在第一个 `/` 处被截掉,反代前缀写在地址栏里时
    /// 整段就丢了;basePath 里嵌套的完整 URL 也要逐字保留。
    static func baseURL(host: String, port: Int?, useSsl: Bool, basePath: String?) -> URL? {
        let address = ProxyPrefixedBasePathPolicy.splitAddress(host)
        // 裸 IPv6 字面量自带冒号,旧的 `!h.contains(":")` 判断会把端口整个丢掉,
        // 拼出来的还是个非法 URL。
        let split = NetworkHostAuthority.splitHostAndPort(address.authority)
        guard let hostPort = NetworkHostAuthority.authority(
            host: split.host,
            port: split.port ?? port
        ) else { return nil }
        return ProxyPrefixedBasePathPolicy.baseURL(
            scheme: address.scheme ?? (useSsl ? "https" : "http"),
            authority: hostPort,
            hostPath: address.pathPrefix,
            basePath: basePath
        )
    }

    static func itemID(from filePath: String) -> String? {
        let last = (filePath as NSString).lastPathComponent
        guard !last.isEmpty else { return nil }
        let id = (last as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    static func jellyfinStreamURL(base: URL, itemID: String, token: String) -> URL? {
        guard var comp = URLComponents(
            url: ProxyPrefixedBasePathPolicy.appending("Audio/\(itemID)/stream", to: base),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        comp.queryItems = [URLQueryItem(name: "Static", value: "true"),
                           URLQueryItem(name: "api_key", value: token)]
        return FormSafeQueryURLBuilder.url(from: comp)
    }

    static func jellyfinLiveRadioStreamURL(base: URL, itemID: String, token: String) -> URL? {
        guard var comp = URLComponents(
            url: ProxyPrefixedBasePathPolicy.appending("Audio/\(itemID)/stream.mp3", to: base),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "Container", value: "mp3"),
            URLQueryItem(name: "api_key", value: token)
        ]
        return FormSafeQueryURLBuilder.url(from: comp)
    }

    static func plexStreamURL(base: URL, partKey: String, token: String) -> URL? {
        // partKey 形如 /library/parts/123/file.mp3,直接拼到 base 上。
        guard var comp = URLComponents(
            url: ProxyPrefixedBasePathPolicy.appending(partKey, to: base),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        comp.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return FormSafeQueryURLBuilder.url(from: comp)
    }

    static func mediaBrowserAuth(deviceID: String, token: String?) -> String {
        var parts = [
            "Client=\"Primuse\"",
            "Device=\"\(MediaServerDeviceIdentity.deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"1.0.0\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser \(parts.joined(separator: ", "))"
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamResolveError.authFailed }
        guard (200...299).contains(http.statusCode) else { throw StreamResolveError.badServerResponse(http.statusCode) }
    }

    static func parseAccessToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["AccessToken"] as? String
    }

    /// 登录响应里的 `User.Id`：扫描端接手这个会话时要用它拼 `/Users/{id}/…`。
    static func parseUserID(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["User"] as? [String: Any],
              let id = user["Id"] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    /// 从 Plex /library/metadata 响应取第一个 part 的 key。
    static func parsePlexPartKey(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any],
              let metadata = container["Metadata"] as? [[String: Any]],
              let media = metadata.first?["Media"] as? [[String: Any]],
              let parts = media.first?["Part"] as? [[String: Any]],
              let key = parts.first?["key"] as? String else { return nil }
        return key
    }
}
