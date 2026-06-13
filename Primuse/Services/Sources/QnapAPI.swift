import Foundation

actor QnapAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var sid: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return NetworkURLBuilder.baseURLString(host: host, scheme: scheme, port: port)
            ?? "\(scheme)://localhost:\(port)"
    }
    var isLoggedIn: Bool { sid != nil }

    init(host: String, port: Int, useSsl: Bool) {
        self.host = host; self.port = port; self.useSsl = useSsl
    }

    // MARK: - Auth

    struct LoginResult: Sendable {
        var success: Bool
        var sid: String?
        var needs2FA: Bool
        var errorMessage: String?
    }

    func login(account: String, password: String, otpCode: String? = nil) async -> LoginResult {
        var formFields: [(String, String)] = [
            ("user", account),
            ("pwd", password),
            ("remme", "1"),
        ]
        if let otpCode {
            formFields.append(("otp_code", otpCode))
        }

        do {
            var req = URLRequest(url: URL(string: "\(baseURLString)/cgi-bin/authLogin.cgi")!)
            req.httpMethod = "POST"
            // 手工 form-encode: URL query 规则不转义 '+', 但表单解码把 '+' 当
            // 空格 —— 密码含 '+' 时 percentEncodedQuery 会让服务端把它解码成
            // 空格, 正确密码也永远报"用户名或密码错误"。移除 "+&=" 后逐字段
            // percent-encode 再拼接。
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=")
            let body = formFields.map { (k, v) -> String in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15

            let (data, _) = try await session().data(for: req)
            // QNAP returns XML sometimes, try JSON first
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let authPassed = (json["authPassed"] as? Int) == 1
                let needOtp = (json["need_otp"] as? Int) == 1
                let authCode = json["authCode"] as? Int ?? 0
                let sessionId = json["authSid"] as? String

                if authPassed, let sid = sessionId {
                    self.sid = sid
                    return LoginResult(success: true, sid: sid, needs2FA: false)
                }
                if needOtp || authCode == 5 {
                    return LoginResult(success: false, needs2FA: true, errorMessage: "需要两步验证")
                }
                if authCode == 6 {
                    return LoginResult(success: false, needs2FA: true, errorMessage: "验证码错误")
                }
                return LoginResult(success: false, needs2FA: false, errorMessage: qnapError(authCode))
            }
            // Try XML parsing (simple)
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("<authPassed>1</authPassed>"),
               let sidRange = text.range(of: "<authSid><![CDATA["),
               let sidEnd = text.range(of: "]]></authSid>") {
                let sid = String(text[sidRange.upperBound..<sidEnd.lowerBound])
                self.sid = sid
                return LoginResult(success: true, sid: sid, needs2FA: false)
            }
            if text.contains("need_otp") { return LoginResult(success: false, needs2FA: true) }
            return LoginResult(success: false, needs2FA: false, errorMessage: "Login failed")
        } catch {
            return LoginResult(success: false, needs2FA: false, errorMessage: error.localizedDescription)
        }
    }

    func logout() async {
        guard let sid else { return }
        _ = try? await session().data(from: URL(string: "\(baseURLString)/cgi-bin/authLogout.cgi?sid=\(sid)")!)
        self.sid = nil
    }

    /// 清除会话, 让下一次 connect() 真正重新登录。会话过期 / 权限错误后
    /// 必须调用它, 否则 isLoggedIn 仍为 true, connect() 短路, 重连永不发生。
    func invalidateSession() {
        self.sid = nil
    }

    // MARK: - Files

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String, offset: Int = 0, limit: Int = 500) async throws -> [FileItem] {
        // 平铺式音乐目录单层超过 limit 个文件很常见, 必须从 offset 起翻页到
        // 尾, 否则超出部分的歌永远扫不进库且无任何提示。对照 SynologyAPI 的
        // while 翻页循环。
        var start = offset
        var allItems: [FileItem] = []

        while true {
            let (pageItems, total) = try await listPage(path: path, offset: start, limit: limit)
            allItems.append(contentsOf: pageItems)

            if pageItems.count < limit || (total > 0 && allItems.count >= total) {
                break
            }
            start += pageItems.count
        }

        return allItems
    }

    /// 请求单页目录列表并校验错误。返回 (本页条目, total 总数)。
    private func listPage(path: String, offset: Int, limit: Int) async throws -> ([FileItem], Int) {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        var comps = URLComponents(string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi")!
        comps.queryItems = [
            .init(name: "sid", value: sid), .init(name: "func", value: "get_list"),
            .init(name: "path", value: path), .init(name: "list_mode", value: "all"),
            .init(name: "start", value: "\(offset)"), .init(name: "limit", value: "\(limit)"),
            .init(name: "sort", value: "filename"), .init(name: "dir", value: "ASC"),
            .init(name: "is_iso", value: "0"),
        ]
        let (data, response) = try await session().data(from: comps.url!)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // QNAP utilRequest.cgi 用响应体里的 `status` 码报错误, 而不是 HTTP 码;
        // sid 过期 / 权限不足 时响应里根本没有 `datas` 字段。
        // 绝不能把"无 datas"当成"空目录"返回 —— 那会让 scanner 误判该目录
        // 被清空, 把整源曲库删掉。所以: 只有响应明确成功 (status==1 或带 datas)
        // 才解析; 任何错误状态 / 不可信响应都抛错并清 sid, 让 ConnectorScanner
        // 走 hadDirectoryFailure 分支保护既有曲库。
        let status = qnapStatus(json)
        let hasDatas = (json["datas"] as? [[String: Any]]) != nil
        if status == 1 || (status == nil && hasDatas) {
            // 成功 —— 继续解析 datas。
        } else {
            // status==2 (Permission denied) / 未登录 等都视为会话失效;
            // 其余非成功状态及缺字段的不可信响应一律抛错, 不返回空数组。
            invalidateSession()
            if let status, status != 2 {
                throw SourceError.connectionFailed("QNAP list_dir failed: status \(status)")
            }
            throw SourceError.authenticationFailed
        }
        let items = json["datas"] as? [[String: Any]] ?? []
        let total = qnapInt(json["total"]) ?? 0
        return (items.map { d in
            FileItem(
                name: d["filename"] as? String ?? "",
                path: d["path"] as? String ?? "",
                isDirectory: (d["isfolder"] as? Int) == 1,
                size: Int64(d["filesize"] as? Int ?? 0)
            )
        }, total)
    }

    func listSharedFolders() async throws -> [FileItem] {
        try await listDirectory(path: "/")
    }

    func downloadURL(path: String) -> URL? {
        guard let sid else { return nil }
        var comps = URLComponents(string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi")!
        comps.queryItems = [
            .init(name: "func", value: "download"),
            .init(name: "source_path", value: path),
            .init(name: "sid", value: sid),
        ]
        return comps.url
    }

    // MARK: - Helpers

    /// 长生命周期 session 复用: 带 delegate 的 session 在被 invalidate 前
    /// 强持有 delegate 与连接池, 每次新建且从不 invalidate 会随扫描线性泄漏
    /// 内存与文件描述符, 同时丢失 keep-alive 复用 (每请求重新 TLS 握手)。
    private lazy var sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    private func session() -> URLSession { sharedSession }

    /// 从 utilRequest.cgi 响应里取 `status` 码 (QNAP 用它而非 HTTP 码报错误)。
    /// 数值可能以 Int / NSNumber / String 出现, 全部归一成 Int。
    private func qnapStatus(_ json: [String: Any]) -> Int? {
        qnapInt(json["status"])
    }

    /// 把可能以 Int / NSNumber / String 出现的数值归一成 Int。
    private func qnapInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return nil
    }

    private func qnapError(_ code: Int) -> String {
        switch code {
        case 0: return "登录失败"
        case 1: return "用户名或密码错误"
        case 2: return "账户已停用"
        case 3: return "权限不足"
        case 4: return "连接数已满"
        case 5: return "需要两步验证"
        case 6: return "验证码错误"
        case 7: return "IP 已被封锁"
        default: return "错误 \(code)"
        }
    }
}
