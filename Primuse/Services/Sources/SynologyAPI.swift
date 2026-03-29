import Foundation

actor SynologyAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var sid: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    private var baseURL: String { baseURLString }

    var isLoggedIn: Bool { sid != nil }

    init(host: String, port: Int, useSsl: Bool) {
        self.host = host
        self.port = port
        self.useSsl = useSsl
    }

    // MARK: - Login

    struct LoginResult: Sendable {
        var success: Bool
        var sid: String?
        var deviceId: String?
        var needs2FA: Bool
        var errorMessage: String?
    }

    func login(account: String, password: String, otpCode: String? = nil,
               deviceName: String? = nil, deviceId: String? = nil) async -> LoginResult {
        var params: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": "7",
            "method": "login",
            "account": account,
            "passwd": password,
            "session": "FileStation",
            "format": "sid",
        ]

        if let otpCode, !otpCode.isEmpty {
            params["otp_code"] = otpCode
        }
        if let deviceName, !deviceName.isEmpty {
            params["device_name"] = deviceName
            params["enable_device_token"] = "yes"
        }
        if let deviceId, !deviceId.isEmpty {
            params["device_id"] = deviceId
        }

        do {
            let data = try await request(path: "/webapi/auth.cgi", params: params)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let success = json["success"] as? Bool ?? false

            if success {
                let d = json["data"] as? [String: Any]
                let sid = d?["sid"] as? String
                let did = d?["did"] as? String ?? d?["device_id"] as? String
                self.sid = sid
                return LoginResult(success: true, sid: sid, deviceId: did, needs2FA: false)
            } else {
                let error = json["error"] as? [String: Any]
                let code = error?["code"] as? Int ?? 0

                if code == 403 {
                    return LoginResult(success: false, needs2FA: true,
                                      errorMessage: "Two-factor authentication required")
                }
                if code == 404 {
                    return LoginResult(success: false, needs2FA: true,
                                      errorMessage: synologyErrorMessage(code: code))
                }

                return LoginResult(success: false, needs2FA: false,
                                   errorMessage: synologyErrorMessage(code: code))
            }
        } catch {
            return LoginResult(success: false, needs2FA: false,
                               errorMessage: error.localizedDescription)
        }
    }

    func logout() async {
        guard sid != nil else { return }
        _ = try? await request(path: "/webapi/auth.cgi", params: [
            "api": "SYNO.API.Auth", "version": "7",
            "method": "logout", "session": "FileStation",
        ])
        sid = nil
    }

    // MARK: - File Station List

    struct FileItem: Sendable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let children: Int?
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard let sid else { throw SynologyError.notLoggedIn }
        let pageSize = 500
        var offset = 0
        var allFiles: [FileItem] = []

        while true {
            let data = try await request(path: "/webapi/entry.cgi", params: [
                "api": "SYNO.FileStation.List",
                "version": "2",
                "method": "list",
                "folder_path": path,
                "offset": String(offset),
                "limit": String(pageSize),
                "additional": "[\"size\",\"time\",\"type\"]",
                "sort_by": "name",
                "sort_direction": "ASC",
                "_sid": sid,
            ])

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard json["success"] as? Bool == true else {
                let err = json["error"] as? [String: Any]
                throw SynologyError.apiError(synologyErrorMessage(code: intValue(err?["code"])))
            }

            let pageData = json["data"] as? [String: Any] ?? [:]
            let files = pageData["files"] as? [[String: Any]] ?? []
            let total = max(intValue(pageData["total"]), files.count)

            let pageItems = files.map { f in
                let additional = f["additional"] as? [String: Any]
                return FileItem(
                    name: f["name"] as? String ?? "",
                    path: f["path"] as? String ?? "",
                    isDirectory: f["isdir"] as? Bool ?? false,
                    size: int64Value(additional?["size"]),
                    children: nil
                )
            }

            allFiles.append(contentsOf: pageItems)

            if files.isEmpty || allFiles.count >= total {
                break
            }

            offset += files.count
        }

        return allFiles
    }

    func listSharedFolders() async throws -> [FileItem] {
        guard let sid else { throw SynologyError.notLoggedIn }

        let data = try await request(path: "/webapi/entry.cgi", params: [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": "list_share",
            "additional": "[\"size\"]",
            "_sid": sid,
        ])

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true else {
            let err = json["error"] as? [String: Any]
            throw SynologyError.apiError(synologyErrorMessage(code: err?["code"] as? Int ?? 0))
        }

        let shares = (json["data"] as? [String: Any])?["shares"] as? [[String: Any]] ?? []
        return shares.map { s in
            FileItem(
                name: s["name"] as? String ?? "",
                path: s["path"] as? String ?? "/\(s["name"] as? String ?? "")",
                isDirectory: true, size: 0, children: nil
            )
        }
    }

    // MARK: - Download file (partial, for metadata extraction)

    func downloadFile(path: String) async throws -> Data {
        guard let sid else { throw SynologyError.notLoggedIn }

        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { throw SynologyError.invalidURL }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        let (data, _) = try await session.data(from: url)
        return data
    }

    func downloadFileHead(path: String, maxBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        guard let sid else { throw SynologyError.notLoggedIn }

        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { throw SynologyError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Get thumbnail URL for a file
    func thumbnailURL(path: String, size: String = "small") -> URL? {
        guard let sid else { return nil }
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Thumb"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "get"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "size", value: size),
            URLQueryItem(name: "_sid", value: sid),
        ]
        return components.url
    }

    // MARK: - Upload file (for sidecar writing)

    func uploadFile(data: Data, toDirectory directory: String, fileName: String) async throws {
        guard let sid else { throw SynologyError.notLoggedIn }

        let boundary = "Boundary-\(UUID().uuidString)"
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { throw SynologyError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Build multipart body
        var body = Data()
        let params: [(String, String)] = [
            ("api", "SYNO.FileStation.Upload"),
            ("version", "2"),
            ("method", "upload"),
            ("path", directory),
            ("create_parents", "true"),
            ("overwrite", "true"),
        ]
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        let (responseData, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true else {
            let err = json["error"] as? [String: Any]
            throw SynologyError.apiError("Upload failed: \(synologyErrorMessage(code: intValue(err?["code"])))")
        }
    }

    // MARK: - HTTP

    private func request(path: String, params: [String: String]) async throws -> Data {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw SynologyError.invalidURL }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func synologyErrorMessage(code: Int) -> String {
        switch code {
        case 400: return "用户名或密码错误"
        case 401: return "账户已被停用"
        case 402: return "权限不足"
        case 403: return "需要两步验证"
        case 404: return "验证码错误，请重新输入"
        case 406: return "需要强制两步验证"
        case 407: return "登录尝试次数过多，请稍后再试"
        case 408: return "IP 已被封锁"
        case 409: return "密码已过期"
        case 410: return "密码需要重置"
        default: return "连接失败 (错误码: \(code))"
        }
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    private func int64Value(_ value: Any?) -> Int64 {
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let int64 = Int64(string) { return int64 }
        return 0
    }
}

enum SynologyError: Error, LocalizedError {
    case notLoggedIn, invalidURL, invalidResponse, httpError(Int), apiError(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "未登录"
        case .invalidURL: return "无效的地址"
        case .invalidResponse: return "无效的响应"
        case .httpError(let c): return "HTTP 错误 \(c)"
        case .apiError(let m): return m
        }
    }
}