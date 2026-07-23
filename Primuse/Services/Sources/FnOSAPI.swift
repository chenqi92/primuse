import Foundation
import PrimuseKit

actor FnOSAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var token: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return NetworkURLBuilder.baseURLString(host: host, scheme: scheme, port: port)
            ?? "\(scheme)://localhost:\(port)"
    }
    var isLoggedIn: Bool { token != nil }

    init(host: String, port: Int, useSsl: Bool) {
        self.host = host; self.port = port; self.useSsl = useSsl
    }

    struct LoginResult: Sendable {
        var success: Bool; var token: String?; var needs2FA: Bool; var errorMessage: String?
    }

    /// Tries multiple endpoint formats for compatibility
    func login(account: String, password: String, otpCode: String? = nil) async -> LoginResult {
        let attempts: [(path: String, body: [String: Any])] = [
            ("/api/v1/auth/login", buildBody(user: "username", pass: "password", otpKey: "otp_code",
                                              account: account, password: password, otpCode: otpCode)),
            ("/api/auth/login", buildBody(user: "username", pass: "password", otpKey: "otp",
                                           account: account, password: password, otpCode: otpCode)),
            ("/user/login", buildBody(user: "user", pass: "passwd", otpKey: "otp",
                                      account: account, password: password, otpCode: otpCode)),
        ]

        for attempt in attempts {
            let result = await tryLogin(path: attempt.path, body: attempt.body)
            if result.success || result.needs2FA { return result }
        }
        return LoginResult(success: false, needs2FA: false, errorMessage: "无法连接到 fnOS")
    }

    private func tryLogin(path: String, body: [String: Any]) async -> LoginResult {
        do {
            let data = try await postJSON(path: path, body: body)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let code = json["code"] as? Int ?? 0
            let d = json["data"] as? [String: Any]

            let t = d?["token"] as? String ?? d?["access_token"] as? String ?? d?["session_id"] as? String
            if (code == 200 || code == 0) && t != nil {
                self.token = t
                return LoginResult(success: true, token: t, needs2FA: false)
            }

            let msg = json["message"] as? String ?? json["msg"] as? String ?? ""
            if code == 1001 || (json["require_2fa"] as? Bool == true)
                || (json["need_otp"] as? Bool == true) || msg.lowercased().contains("2fa") {
                return LoginResult(success: false, needs2FA: true, errorMessage: "需要两步验证")
            }
            return LoginResult(success: false, needs2FA: false, errorMessage: msg.isEmpty ? nil : msg)
        } catch {
            return LoginResult(success: false, needs2FA: false, errorMessage: nil) // silent, try next
        }
    }

    func logout() async {
        guard token != nil else { return }
        _ = try? await postJSON(path: "/api/v1/auth/logout", body: [:])
        token = nil
    }

    /// 清除会话, 让下一次 connect() 真正重新登录。会话过期 / 权限错误后
    /// 必须调用它, 否则 isLoggedIn 仍为 true, connect() 短路, 重连永不发生。
    func invalidateSession() {
        self.token = nil
    }

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }

        // 平铺式音乐目录单层超过 1000 个文件很常见, 必须翻页到尾,
        // 否则超出 limit 的歌永远扫不进库且无任何提示。
        let limit = 1000
        var page = 1
        var allItems: [FileItem] = []

        while true {
            let body: [String: Any] = ["path": path, "page": page, "limit": limit]
            let json = try await listPage(path: path, body: body)
            let dataDict = json["data"] as? [String: Any]
            let list = (dataDict?["list"] as? [[String: Any]]) ?? []
            let pageItems = list.map { f in
                FileItem(
                    name: f["name"] as? String ?? "",
                    path: f["path"] as? String ?? "",
                    isDirectory: f["is_dir"] as? Bool ?? false,
                    size: Int64(f["size"] as? Int ?? 0)
                )
            }
            allItems.append(contentsOf: pageItems)

            // total (若服务端提供) 优先, 否则按"满页继续 / 不满页停"判断。
            let total = intValue(dataDict?["total"])
            if pageItems.count < limit || (total > 0 && allItems.count >= total) {
                break
            }
            page += 1
        }

        return allItems
    }

    /// 请求单页目录列表并校验错误。绝不能把"无 list"当成"空目录"返回 ——
    /// token 过期 / 权限不足 时响应里根本没有 `data.list` 字段, 若静默返回
    /// 空数组会让 scanner 误判该目录被清空, 把整源曲库删掉。所以: 只有响应
    /// 明确成功 (code==200/0 且带 data.list) 才解析; 任何 HTTP 错误 / 非成功
    /// code / 不可信响应都抛错并清 token, 让 ConnectorScanner 走
    /// hadDirectoryFailure 分支保护既有曲库。
    private func listPage(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }
        let data: Data
        do {
            data = try await postJSON(path: "/api/v1/file/list", body: body, auth: token)
        } catch {
            // Fallback GET
            var comps = URLComponents(string: "\(baseURLString)/api/v1/file/list")!
            comps.queryItems = [.init(name: "path", value: path)]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 15
            let (d, response) = try await session().data(for: req)
            try checkHTTPStatus(response)
            data = d
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hasCode = json["code"] != nil
        let code = intValue(json["code"])
        let hasList = (json["data"] as? [String: Any])?["list"] != nil
        // 成功判据: 明确成功 code (200/0), 或带 data.list 字段。带 list 即使
        // 为空也是合法的空目录。缺 code 又缺 list 的响应不可信, 绝不当空目录。
        if (hasCode && (code == 200 || code == 0)) || hasList {
            return json
        }
        // 非成功 code: 认证类 (401/403/1001) 清 token 抛 authenticationFailed,
        // 其余抛 connectionFailed。缺 list 字段的不可信响应一律不返回空数组。
        invalidateSession()
        if isAuthFailureCode(code) {
            throw SourceError.authenticationFailed
        }
        let msg = json["message"] as? String ?? json["msg"] as? String ?? "code \(code)"
        throw SourceError.connectionFailed("fnOS list failed: \(msg)")
    }

    private func isAuthFailureCode(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 1001
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    func listSharedFolders() async throws -> [FileItem] {
        try await listDirectory(path: "/")
    }

    /// fnOS file-service deletion. The API call is authenticated and its
    /// business result must be explicit before the caller removes local data.
    func deleteFile(path: String) async throws {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }
        let data = try await postJSON(
            path: "/api/v1/file/delete",
            body: ["paths": [path], "path": path, "permanent": false],
            auth: token
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hasCode = json["code"] != nil
        let code = intValue(json["code"])
        if isAuthFailureCode(code) {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        let success = (hasCode && (code == 200 || code == 0))
            || json["success"] as? Bool == true
        guard success else {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "code \(code)"
            throw SourceError.connectionFailed("fnOS delete not confirmed: \(message)")
        }
    }

    func downloadURL(path: String) -> URL? {
        guard let token else { return nil }
        // 用 URLComponents 让系统正确编码查询值: .urlQueryAllowed 不会转义
        // & / + / = / ?, 路径含这些字符 (R&B、AC+DC 类专辑名) 时手工拼接会
        // 截断 path 参数导致下载/播放必败。
        var comps = URLComponents(string: "\(baseURLString)/api/v1/file/download")
        comps?.queryItems = [
            .init(name: "path", value: path),
            .init(name: "token", value: token),
        ]
        return comps?.url
    }

    // MARK: - HTTP

    private func buildBody(user: String, pass: String, otpKey: String,
                           account: String, password: String, otpCode: String?) -> [String: Any] {
        var b: [String: Any] = [user: account, pass: password]
        if let otp = otpCode { b[otpKey] = otp }
        return b
    }

    private func postJSON(path: String, body: [String: Any], auth: String? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURLString)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        else if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try SafeJSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, response) = try await session().data(for: req)
        try checkHTTPStatus(response)
        return data
    }

    /// HTTP 状态码校验: 401/403 视为会话失效 (清 token 抛 authenticationFailed),
    /// 其余非 2xx 抛 connectionFailed。会话过期时 fnOS 可能返回 401 而非业务
    /// code, 不看 HTTP 码就会把错误体当数据。
    private func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.connectionFailed("fnOS HTTP \(http.statusCode)")
        }
    }

    /// 长生命周期 session 复用: 带 delegate 的 session 在被 invalidate 前
    /// 强持有 delegate 与连接池, 每次新建且从不 invalidate 会随扫描线性泄漏
    /// 内存与文件描述符, 同时丢失 keep-alive 复用 (每请求重新 TLS 握手)。
    private lazy var sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    private func session() -> URLSession { sharedSession }
}
