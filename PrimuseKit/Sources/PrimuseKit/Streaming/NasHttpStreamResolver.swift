import Foundation

/// QNAP 与 fnOS(飞牛)NAS 的流式解析。两者都登录拿会话 token/sid → 下载地址把
/// token/sid 放 query,AVPlayer 直连。song.filePath = 服务端完整文件路径。
///
/// (绿联 Ugreen 登录需 RSA 加密密码,单列;此处只接 QNAP/fnOS。)
public actor NasHttpStreamResolver: StreamResolver {
    private var sessions: [String: String] = [:]   // sourceID → token/sid
    private var sessionTasks: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = StreamResolverSessionFactory.make(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    public func invalidateSession(sourceID: String) {
        sessions[sourceID] = nil
        sessionTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        let username = cred.username ?? source.username ?? ""
        guard let password = cred.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.baseURL(host: source.host ?? "", port: source.port, useSsl: source.useSsl) else {
            throw StreamResolveError.cannotBuildURL
        }
        let token = try await currentSession(source: source, base: base, username: username,
                                             password: password, type: source.type)
        let url: URL?
        switch source.type {
        case .qnap: url = Self.qnapDownloadURL(base: base, path: song.filePath, sid: token)
        case .fnos: url = Self.fnosDownloadURL(base: base, path: song.filePath, token: token)
        default: throw StreamResolveError.unsupportedSourceType(source.type)
        }
        guard let url else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    private func currentSession(source: MusicSource, base: URL, username: String,
                                password: String, type: MusicSourceType) async throws -> String {
        if let cached = sessions[source.id] { return cached }
        if let inFlight = sessionTasks[source.id] { return try await inFlight.task.value }
        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            switch type {
            case .qnap: return try await qnapLogin(base: base, username: username, password: password)
            case .fnos: return try await fnosLogin(base: base, username: username, password: password)
            default: throw StreamResolveError.unsupportedSourceType(type)
            }
        }
        sessionTasks[source.id] = (taskID, task)
        let token: String
        do {
            token = try await task.value
        } catch {
            if sessionTasks[source.id]?.id == taskID { sessionTasks[source.id] = nil }
            throw error
        }
        if sessionTasks[source.id]?.id == taskID {
            sessions[source.id] = token
            sessionTasks[source.id] = nil
        }
        return token
    }

    // MARK: - QNAP

    private func qnapLogin(base: URL, username: String, password: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("cgi-bin/authLogin.cgi"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "user=\(Self.formEncode(username))&pwd=\(Self.formEncode(password))&remme=1".data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let sid = Self.parseQnapSID(data) else { throw StreamResolveError.authFailed }
        return sid
    }

    // MARK: - fnOS(多种登录端点格式兜底)

    private func fnosLogin(base: URL, username: String, password: String) async throws -> String {
        let attempts: [(String, [String: Any])] = [
            ("api/v1/auth/login", ["username": username, "password": password]),
            ("api/auth/login", ["username": username, "password": password]),
            ("user/login", ["user": username, "passwd": password]),
        ]
        for (path, body) in attempts {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let token = Self.parseFnosToken(data) else { continue }
            return token
        }
        throw StreamResolveError.authFailed
    }

    // MARK: - 纯函数(可单测)

    static func baseURL(host: String, port: Int?, useSsl: Bool) -> URL? {
        var h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let r = h.range(of: "://") { scheme = String(h[..<r.lowerBound]).lowercased(); h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var hostPort = h
        if let port, port > 0, !h.contains(":") { hostPort = "\(h):\(port)" }
        return URL(string: "\(scheme)://\(hostPort)")
    }

    static func qnapDownloadURL(base: URL, path: String, sid: String) -> URL? {
        guard var comp = URLComponents(url: base.appendingPathComponent("cgi-bin/filemanager/utilRequest.cgi"),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [URLQueryItem(name: "func", value: "download"),
                           URLQueryItem(name: "source_path", value: path),
                           URLQueryItem(name: "sid", value: sid)]
        return comp.url
    }

    static func fnosDownloadURL(base: URL, path: String, token: String) -> URL? {
        guard var comp = URLComponents(url: base.appendingPathComponent("api/v1/file/download"),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "token", value: token)]
        return comp.url
    }

    static func parseQnapSID(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["authPassed"] as? Int) == 1, let sid = json["authSid"] as? String {
            return sid
        }
        // XML 兜底:<authPassed>1</authPassed> + <authSid><![CDATA[sid]]></authSid>
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.contains("<authPassed>1</authPassed>"),
              let lo = text.range(of: "<authSid><![CDATA["),
              let hi = text.range(of: "]]></authSid>") else { return nil }
        return String(text[lo.upperBound..<hi.lowerBound])
    }

    static func parseFnosToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = json["code"] as? Int ?? 0
        guard code == 200 || code == 0, let d = json["data"] as? [String: Any] else { return nil }
        return (d["token"] as? String) ?? (d["access_token"] as? String) ?? (d["session_id"] as? String)
    }

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamResolveError.authFailed }
        guard (200...299).contains(http.statusCode) else { throw StreamResolveError.badServerResponse(http.statusCode) }
    }
}
