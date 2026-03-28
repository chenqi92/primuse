import Foundation

actor FnOSAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var token: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
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

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }

        // Try POST first, then GET
        let body: [String: Any] = ["path": path, "page": 1, "limit": 1000]
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
            let (d, _) = try await session().data(for: req)
            data = d
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let list = ((json["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return list.map { f in
            FileItem(
                name: f["name"] as? String ?? "",
                path: f["path"] as? String ?? "",
                isDirectory: f["is_dir"] as? Bool ?? false,
                size: Int64(f["size"] as? Int ?? 0)
            )
        }
    }

    func listSharedFolders() async throws -> [FileItem] {
        try await listDirectory(path: "/")
    }

    func downloadURL(path: String) -> URL? {
        guard let token else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return URL(string: "\(baseURLString)/api/v1/file/download?path=\(encoded)&token=\(token)")
    }

    // MARK: - HTTP

    private func buildBody(user: String, pass: String, otpKey: String,
                           account: String, password: String, otpCode: String?) -> [String: Any] {
        var b: [String: Any] = [user: account, pass: password]
        if let otp = otpCode { b[otpKey] = otp }
        return b
    }

    private func postJSON(path: String, body: [String: Any], auth: String? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(baseURLString)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        else if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, _) = try await session().data(for: req)
        return data
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
    }
}
