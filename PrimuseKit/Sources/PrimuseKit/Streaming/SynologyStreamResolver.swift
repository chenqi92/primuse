import Foundation

/// Synology(SYNO.FileStation)流式解析:登录拿 `_sid` → FileStation Download URL。
/// `_sid` 会过期;协调器收到 `.authFailed` 会调用 `invalidateSession` 后重试一次(重登)。
///
/// 字段映射(同 iOS SynologySource):host/port/useSsl、username、password(凭据)、
/// deviceId(2FA 受信设备,跳过 OTP)。注:tvOS 无 OTP 输入界面,需要 OTP 的账号
/// 会在登录失败时报 `.authFailed`(请在手机上勾选「记住此设备」后再同步)。
public actor SynologyStreamResolver: StreamResolver {
    private var sessions: [String: String] = [:]   // sourceID → _sid
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        self.session = URLSession(configuration: cfg)
    }

    public func invalidateSession(sourceID: String) {
        sessions[sourceID] = nil
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let username = credential?.username ?? source.username ?? ""
        guard let password = credential?.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.baseURL(host: source.host ?? "", port: source.port, useSsl: source.useSsl) else {
            throw StreamResolveError.cannotBuildURL
        }
        let sid = try await currentSID(for: source, base: base, username: username, password: password)
        guard let url = Self.downloadURL(base: base, path: song.filePath, sid: sid) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    private func currentSID(for source: MusicSource, base: URL,
                            username: String, password: String) async throws -> String {
        if let cached = sessions[source.id] { return cached }
        let sid = try await login(base: base, username: username, password: password, deviceID: source.deviceId)
        sessions[source.id] = sid
        return sid
    }

    private func login(base: URL, username: String, password: String, deviceID: String?) async throws -> String {
        // 凭据放进 POST 表单体,URL 上不携带账号/密码,避免进入 DSM/反向代理的访问日志。
        var fields = [
            ("api", "SYNO.API.Auth"),
            ("version", "7"),
            ("method", "login"),
            ("account", username),
            ("passwd", password),
            ("session", "FileStation"),
            ("format", "sid"),
        ]
        if let deviceID, !deviceID.isEmpty {
            fields.append(("device_id", deviceID))
        }
        var req = URLRequest(url: base.appendingPathComponent("webapi/auth.cgi"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StreamResolveError.badServerResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamResolveError.authFailed
        }
        if (json["success"] as? Bool) == true,
           let d = json["data"] as? [String: Any], let sid = d["sid"] as? String {
            return sid
        }
        throw StreamResolveError.authFailed   // 密码错 / 需要 OTP / 锁定
    }

    // MARK: - 纯函数(可单测)

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

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

    static func downloadURL(base: URL, path: String, sid: String) -> URL? {
        guard var comp = URLComponents(url: base.appendingPathComponent("webapi/entry.cgi"),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        return comp.url
    }
}
