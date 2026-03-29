import Foundation

actor QnapAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var sid: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
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
        let encoded = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        var body = "user=\(account)&pwd=\(encoded)&remme=1"
        if let otp = otpCode { body += "&otp_code=\(otp)" }

        do {
            var req = URLRequest(url: URL(string: "\(baseURLString)/cgi-bin/authLogin.cgi")!)
            req.httpMethod = "POST"
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

    // MARK: - Files

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String, offset: Int = 0, limit: Int = 500) async throws -> [FileItem] {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        var comps = URLComponents(string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi")!
        comps.queryItems = [
            .init(name: "sid", value: sid), .init(name: "func", value: "get_list"),
            .init(name: "path", value: path), .init(name: "list_mode", value: "all"),
            .init(name: "start", value: "\(offset)"), .init(name: "limit", value: "\(limit)"),
            .init(name: "sort", value: "filename"), .init(name: "dir", value: "ASC"),
            .init(name: "is_iso", value: "0"),
        ]
        let (data, _) = try await session().data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let items = json["datas"] as? [[String: Any]] ?? []
        return items.map { d in
            FileItem(
                name: d["filename"] as? String ?? "",
                path: d["path"] as? String ?? "",
                isDirectory: (d["isfolder"] as? Int) == 1,
                size: Int64(d["filesize"] as? Int ?? 0)
            )
        }
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

    private func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
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
