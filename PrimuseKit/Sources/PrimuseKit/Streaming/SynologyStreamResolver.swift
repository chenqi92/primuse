import Foundation

/// Synology(SYNO.FileStation)流式解析:登录拿 `_sid` → FileStation Download URL。
/// `_sid` 会过期;协调器收到 `.authFailed` 会调用 `invalidateSession` 后重试一次(重登)。
///
/// 字段映射(同 iOS SynologySource):host/port/useSsl、username、password(凭据)、
/// deviceId(本机 2FA 受信设备令牌)。需要 OTP 时由电视输入并持久化令牌。
public actor SynologyStreamResolver: StreamResolver {
    public static let trustedDeviceName = "Apple TV"
    private struct Login: Sendable {
        let base: URL
        let sid: String
        let deviceToken: String?
    }
    private var sessions: [String: Login] = [:]
    private var sessionTasks: [String: (id: UUID, task: Task<Login, Error>)] = [:]
    private let session: URLSession
    private let quickConnectResolver: (@Sendable (String) async throws -> URL)?

    public init(session: URLSession? = nil, quickConnectResolver: (@Sendable (String) async throws -> URL)? = nil) {
        self.quickConnectResolver = quickConnectResolver
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        self.session = session ?? StreamResolverSessionFactory.make(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    public func invalidateSession(sourceID: String) async {
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
        let login = try await currentLogin(for: source, username: username, password: password)
        guard let url = Self.downloadURL(base: login.base, path: song.filePath, sid: login.sid) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    private func currentLogin(for source: MusicSource, username: String, password: String,
                              otp: String? = nil) async throws -> Login {
        try Task.checkCancellation()
        if let cached = sessions[source.id] { return cached }
        if let inFlight = sessionTasks[source.id] {
            return try await CloudResolverRequests.wait(for: inFlight.task)
        }
        let taskID = UUID()
        let task = Task<Login, Error> { [self] in
            // Completion owns publication even when the initiating waiter leaves.
            defer {
                if sessionTasks[source.id]?.id == taskID { sessionTasks[source.id] = nil }
            }
            // Route discovery and OTP login belong to the same invalidatable task.
            let base = try await resolvedBaseURL(for: source)
            try Task.checkCancellation()
            let result = try await performLogin(base: base, username: username, password: password,
                deviceID: source.deviceId, otp: otp)
            let value = Login(base: base, sid: result.sid, deviceToken: result.did)
            try Task.checkCancellation()
            guard sessionTasks[source.id]?.id == taskID else {
                throw URLError(.userAuthenticationRequired)
            }
            sessions[source.id] = value
            return value
        }
        sessionTasks[source.id] = (taskID, task)
        return try await CloudResolverRequests.wait(for: task)
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
        await invalidateSession(sourceID: source.id)
        return try await currentLogin(for: source, username: username, password: password, otp: otp).deviceToken
    }

    private func resolvedBaseURL(for source: MusicSource) async throws -> URL {
        guard source.effectiveSynologyConnectionMode == .quickConnect else {
            guard let base = Self.baseURL(
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl
            ) else {
                throw StreamResolveError.cannotBuildURL
            }
            return base
        }
        do {
            let endpoint: URL
            if let quickConnectResolver { endpoint = try await quickConnectResolver(source.host ?? "") }
            else { endpoint = try await SynologyQuickConnectResolver(session: session).resolve(source.host ?? "").baseURL }
            return endpoint
        } catch {
            try Task.checkCancellation()
            throw StreamResolveError.cannotBuildURL
        }
    }

    /// 执行登录。`otp` 非空时附带 `otp_code` + `enable_device_token` 申请受信设备。
    /// 返回(sid, did?);DSM 返回 2FA 错误码时抛 `.needs2FA`。
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
        // DSM 的免 OTP 登录需要同一对设备名称和令牌。
        if deviceID?.isEmpty == false || otp?.isEmpty == false {
            fields.append(("device_name", Self.trustedDeviceName))
        }
        if let otp, !otp.isEmpty {
            fields.append(("otp_code", otp))
            fields.append(("enable_device_token", "yes"))
        }
        var req = URLRequest(url: base.appendingPathComponent("webapi/auth.cgi"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: req,
            session: session
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StreamResolveError.badServerResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamResolveError.authFailed
        }
        if (json["success"] as? Bool) == true,
           let d = json["data"] as? [String: Any], let sid = d["sid"] as? String {
            return (sid, Self.trustedDeviceID(from: d))
        }
        // DSM 403/404/406 都需要回到验证码输入，不应退化成普通登录失败。
        if let err = json["error"] as? [String: Any], let code = err["code"] as? Int,
           SynologyAuthenticationPolicy.requiresTwoFactorAuthentication(errorCode: code) {
            throw StreamResolveError.needs2FA
        }
        throw StreamResolveError.authFailed   // 密码错 / 锁定
    }

    // MARK: - 纯函数(可单测)

    static func trustedDeviceID(from data: [String: Any]) -> String? {
        for key in ["did", "device_id"] {
            if let value = data[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func baseURL(host: String, port: Int?, useSsl: Bool) -> URL? {
        // 走统一构造:裸 IPv6 字面量必须先加方括号,否则 `http://fd7a::1` 会把
        // 地址尾段当成端口解析,host 只剩 `fd7a`。
        return NetworkHostAuthority.baseURL(
            address: host,
            defaultScheme: useSsl ? "https" : "http",
            port: port
        )
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
        return FormSafeQueryURLBuilder.url(from: comp)
    }
}
