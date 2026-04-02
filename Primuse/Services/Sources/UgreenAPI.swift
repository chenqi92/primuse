import Foundation

actor UgreenAPI {
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

    func login(account: String, password: String, otpCode: String? = nil) async -> LoginResult {
        do {
            // Step 1: get RSA public key (optional — skip if not supported)
            // Step 2: login
            var body: [String: Any] = [
                "username": account,
                "password": password,
                "is_simple": true,
                "keepalive": true,
                "otp": otpCode != nil,
            ]
            if let otp = otpCode { body["otp_code"] = otp }

            let data = try await postJSON(path: "/ugreen/v1/verify/login", body: body)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let code = json["code"] as? Int ?? 0
            let d = json["data"] as? [String: Any]

            if code == 200, let t = d?["token"] as? String {
                self.token = t
                return LoginResult(success: true, token: t, needs2FA: false)
            }
            if code == 1001 || (json["need_otp"] as? Bool == true) || (json["require_2fa"] as? Bool == true) {
                return LoginResult(success: false, needs2FA: true, errorMessage: "需要两步验证")
            }
            let msg = json["message"] as? String ?? json["msg"] as? String ?? "登录失败 (\(code))"
            return LoginResult(success: false, needs2FA: false, errorMessage: msg)
        } catch {
            return LoginResult(success: false, needs2FA: false, errorMessage: error.localizedDescription)
        }
    }

    func logout() async {
        guard token != nil else { return }
        _ = try? await postJSON(path: "/ugreen/v1/verify/logout", body: [:])
        token = nil
    }

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/filemgr/list")!
        comps.queryItems = [.init(name: "token", value: token)]
        let body: [String: Any] = ["path": path, "page": 1, "page_size": 1000]

        let data = try await postJSON(url: comps.url!, body: body)
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
        return URL(string: "\(baseURLString)/ugreen/v1/file/download?path=\(encoded)&token=\(token)")
    }

    // MARK: - HTTP

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        try await postJSON(url: URL(string: "\(baseURLString)\(path)")!, body: body)
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, _) = try await session().data(for: req)
        return data
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }
}
