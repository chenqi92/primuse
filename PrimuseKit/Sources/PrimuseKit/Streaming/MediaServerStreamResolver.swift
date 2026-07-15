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
    private var tokens: [String: String] = [:]   // sourceID → AccessToken(Jellyfin/Emby)
    private var tokenTasks: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = StreamResolverSessionFactory.make(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    /// Module-internal injection point for deterministic URLProtocol tests.
    init(session: URLSession) {
        self.session = session
    }

    public func invalidateSession(sourceID: String) {
        tokens[sourceID] = nil
        tokenTasks.removeValue(forKey: sourceID)?.task.cancel()
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

        switch source.type {
        case .plex:
            guard let token = cred.password ?? cred.token, !token.isEmpty else {
                throw StreamResolveError.missingCredential
            }
            let partKey = try await plexPartKey(base: base, ratingKey: itemID, token: token,
                                                deviceID: "primuse-\(source.id)")
            guard let url = Self.plexStreamURL(base: base, partKey: partKey, token: token) else {
                throw StreamResolveError.cannotBuildURL
            }
            return url
        case .jellyfin, .emby:
            if source.authType == .apiKey {
                guard let token = cred.password ?? cred.token, !token.isEmpty else {
                    throw StreamResolveError.missingCredential
                }
                guard let url = Self.jellyfinStreamURL(base: base, itemID: itemID, token: token) else {
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
            guard let url = Self.jellyfinStreamURL(base: base, itemID: itemID, token: token) else {
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
        if let cached = tokens[source.id] { return cached }
        if let inFlight = tokenTasks[source.id] { return try await inFlight.task.value }
        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            try await login(base: base, username: username, password: password,
                            deviceID: "primuse-\(source.id)", emby: emby)
        }
        tokenTasks[source.id] = (taskID, task)
        let token: String
        do {
            token = try await task.value
        } catch {
            if tokenTasks[source.id]?.id == taskID { tokenTasks[source.id] = nil }
            throw error
        }
        if tokenTasks[source.id]?.id == taskID {
            tokens[source.id] = token
            tokenTasks[source.id] = nil
        }
        return token
    }

    private func login(base: URL, username: String, password: String, deviceID: String, emby: Bool) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authValue = Self.mediaBrowserAuth(deviceID: deviceID, token: nil)
        req.setValue(authValue, forHTTPHeaderField: emby ? "X-Emby-Authorization" : "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let token = Self.parseAccessToken(data) else { throw StreamResolveError.authFailed }
        return token
    }

    // MARK: - Plex 元数据 → partKey

    private func plexPartKey(base: URL, ratingKey: String, token: String, deviceID: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("library/metadata/\(ratingKey)"))
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue("Primuse", forHTTPHeaderField: "X-Plex-Product")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let key = Self.parsePlexPartKey(data) else { throw StreamResolveError.cannotBuildURL }
        return key
    }

    // MARK: - 纯函数(可单测)

    static func baseURL(host: String, port: Int?, useSsl: Bool, basePath: String?) -> URL? {
        var h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let r = h.range(of: "://") { scheme = String(h[..<r.lowerBound]).lowercased(); h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var hostPort = h
        if let port, port > 0, !h.contains(":") { hostPort = "\(h):\(port)" }
        guard var url = URL(string: "\(scheme)://\(hostPort)") else { return nil }
        if let bp = basePath?.trimmingCharacters(in: .whitespaces), !bp.isEmpty {
            for c in bp.split(separator: "/") { url.appendPathComponent(String(c)) }
        }
        return url
    }

    static func itemID(from filePath: String) -> String? {
        let last = (filePath as NSString).lastPathComponent
        guard !last.isEmpty else { return nil }
        let id = (last as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    static func jellyfinStreamURL(base: URL, itemID: String, token: String) -> URL? {
        guard var comp = URLComponents(url: base.appendingPathComponent("Audio/\(itemID)/stream"),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [URLQueryItem(name: "Static", value: "true"),
                           URLQueryItem(name: "api_key", value: token)]
        return comp.url
    }

    static func plexStreamURL(base: URL, partKey: String, token: String) -> URL? {
        // partKey 形如 /library/parts/123/file.mp3,直接拼到 base 上。
        guard var comp = URLComponents(url: base.appendingPathComponent(partKey),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comp.url
    }

    static func mediaBrowserAuth(deviceID: String, token: String?) -> String {
        var parts = ["Client=\"Primuse\"", "Device=\"Apple TV\"", "DeviceId=\"\(deviceID)\"", "Version=\"1.0.0\""]
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
