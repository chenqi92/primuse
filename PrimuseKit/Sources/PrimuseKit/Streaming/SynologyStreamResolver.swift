import Foundation

/// Synology(SYNO.FileStation)流式解析:登录拿 `_sid` → FileStation Download URL。
/// `_sid` 会过期;协调器收到 `.authFailed` 会调用 `invalidateSession` 后重试一次(重登)。
///
/// 字段映射(同 iOS SynologySource):host/port/useSsl、username、password(凭据)、
/// deviceId(2FA 受信设备,跳过 OTP)。注:tvOS 无 OTP 输入界面,需要 OTP 的账号
/// 会在登录失败时报 `.authFailed`(请在手机上勾选「记住此设备」后再同步)。
public actor SynologyStreamResolver: StreamResolver {
    private var sessions: [String: String] = [:]   // sourceID → _sid
    private var sessionTasks: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
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
        if let inFlight = sessionTasks[source.id] { return try await inFlight.task.value }
        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            let (sid, _) = try await performLogin(base: base, username: username, password: password,
                                                  deviceID: source.deviceId, otp: nil)
            return sid
        }
        sessionTasks[source.id] = (taskID, task)
        let sid: String
        do {
            sid = try await task.value
        } catch {
            if sessionTasks[source.id]?.id == taskID { sessionTasks[source.id] = nil }
            throw error
        }
        if sessionTasks[source.id]?.id == taskID {
            sessions[source.id] = sid
            sessionTasks[source.id] = nil
        }
        return sid
    }

    /// 2FA:用一次性验证码登录 + 申请受信设备令牌(`enable_device_token`),返回 `did`
    /// 供 TV 持久化到 `source.deviceId`,之后即可跳过 OTP。
    public func loginForDeviceToken(source: MusicSource,
                                    credential: SourceCredential?,
                                    otp: String) async throws -> String? {
        let username = credential?.username ?? source.username ?? ""
        guard let password = credential?.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.baseURL(host: source.host ?? "", port: source.port, useSsl: source.useSsl) else {
            throw StreamResolveError.cannotBuildURL
        }
        sessionTasks.removeValue(forKey: source.id)?.task.cancel()
        sessions[source.id] = nil
        let (sid, did) = try await performLogin(base: base, username: username, password: password,
                                                deviceID: source.deviceId, otp: otp)
        sessions[source.id] = sid
        return did
    }

    /// 执行登录。`otp` 非空时附带 `otp_code` + `enable_device_token` 申请受信设备。
    /// 返回(sid, did?);DSM 返回 2FA 错误码(403/404)时抛 `.needs2FA`。
    private func performLogin(base: URL, username: String, password: String,
                             deviceID: String?, otp: String?) async throws -> (sid: String, did: String?) {
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
        if let otp, !otp.isEmpty {
            fields.append(("otp_code", otp))
            fields.append(("enable_device_token", "yes"))
            fields.append(("device_name", "Apple TV"))
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
            return (sid, d["did"] as? String)
        }
        // DSM 错误码 403 = 需要 OTP,404 = OTP 校验失败 → 让 TV 弹验证码输入。
        if let err = json["error"] as? [String: Any], let code = err["code"] as? Int,
           code == 403 || code == 404 {
            throw StreamResolveError.needs2FA
        }
        throw StreamResolveError.authFailed   // 密码错 / 锁定
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
