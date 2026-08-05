import Foundation
import PrimuseKit

actor SynologyAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private let connectionMode: SynologyConnectionMode
    private var resolvedEndpoint: SynologyResolvedEndpoint?
    private(set) var sid: String?

    private var directBaseURL: URL? {
        let scheme = useSsl ? "https" : "http"
        return NetworkURLBuilder.baseURL(host: host, scheme: scheme, port: port)
    }

    var isLoggedIn: Bool { sid != nil }

    /// Clears a rejected session locally without sending a logout request that
    /// could race with and invalidate a newer session.
    func invalidateSession(ifMatches rejectedSID: String?) {
        guard rejectedSID == nil || sid == rejectedSID else { return }
        sid = nil
        if connectionMode == .quickConnect {
            resolvedEndpoint = nil
        }
    }

    init(
        host: String,
        port: Int,
        useSsl: Bool,
        connectionMode: SynologyConnectionMode = .address
    ) {
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.connectionMode = connectionMode
    }

    /// 长生命周期 session 复用所有 API 请求 (list / download / upload / head)。
    /// 带 delegate 的 session 在被 invalidate 前强持有 delegate 与连接池, 每个
    /// 请求新建且从不 invalidate 会随大规模扫描线性泄漏内存与文件描述符, 同时
    /// 丢失 keep-alive 复用 (每请求重新 TLS 握手)。逐请求的 timeout 由各
    /// URLRequest.timeoutInterval 覆盖, 故共用一个 session 的全局 timeout 即可。
    private lazy var sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    /// QuickConnect discovery itself always uses system TLS validation. A NAS
    /// endpoint with a certificate problem is returned only as a final fallback;
    /// the regular session then asks the user to trust that exact hostname and
    /// pins its leaf certificate through `SmartSSLDelegate`.
    private lazy var quickConnectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func resolveBaseURL() async throws -> URL {
        if let resolvedEndpoint { return resolvedEndpoint.baseURL }
        guard connectionMode == .quickConnect else {
            guard let directBaseURL else { throw SynologyError.invalidURL }
            return directBaseURL
        }

        let endpoint = try await SynologyQuickConnectResolver(session: quickConnectSession)
            .resolve(host)
        resolvedEndpoint = endpoint
        plog(
            "☁️ Synology QuickConnect resolved id=\(redactedHost(host)) "
                + "route=\(endpoint.route.rawValue) host=\(redactedHost(endpoint.baseURL.host ?? ""))"
        )
        return endpoint.baseURL
    }

    func resolvedBaseURLString() async throws -> String {
        let url = try await resolveBaseURL()
        return url.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    // MARK: - Login

    struct LoginResult: Sendable {
        var success: Bool
        var sid: String?
        var deviceId: String?
        var needs2FA: Bool
        /// Raw DSM authentication error code. Keep this structured so callers
        /// never have to infer credential state from a localized message.
        var errorCode: Int?
        var errorMessage: String?
        var underlyingError: (any Error)?

        var requiresCredentialPrompt: Bool {
            errorCode == 400
        }
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

        plog("☁️ Synology login start host=\(redactedHost(host)) port=\(port) ssl=\(useSsl) accountSet=\(!account.isEmpty) passwordSet=\(!password.isEmpty) otpSet=\(!(otpCode ?? "").isEmpty) deviceNameSet=\(!(deviceName ?? "").isEmpty) deviceIdSet=\(!(deviceId ?? "").isEmpty)")

        do {
            // POST + form-urlencoded body for login: avoids GET query-string
            // encoding quirks where multi-byte chars (e.g. CJK punctuation
            // accidentally typed in a password) get mangled by some Synology
            // versions, causing a deceptive 400 "wrong password" with the
            // exact bytes the user typed.
            let data = try await request(path: "/webapi/auth.cgi", params: params, usePost: true)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let success = json["success"] as? Bool ?? false

            if success {
                let d = json["data"] as? [String: Any]
                let sid = d?["sid"] as? String
                let did = d?["did"] as? String ?? d?["device_id"] as? String
                self.sid = sid
                plog("☁️ Synology login OK host=\(redactedHost(host)) sidPresent=\(sid?.isEmpty == false) deviceIdPresent=\(did?.isEmpty == false)")
                return LoginResult(
                    success: true,
                    sid: sid,
                    deviceId: did,
                    needs2FA: false,
                    errorCode: nil
                )
            } else {
                let error = json["error"] as? [String: Any]
                let code = error?["code"] as? Int ?? 0
                plog("⚠️ Synology login failed host=\(redactedHost(host)) code=\(code) message=\(synologyErrorMessage(code: code))")

                if SynologyAuthenticationPolicy.requiresTwoFactorAuthentication(errorCode: code) {
                    return LoginResult(success: false, needs2FA: true,
                                      errorCode: code,
                                      errorMessage: synologyErrorMessage(code: code))
                }

                return LoginResult(success: false, needs2FA: false,
                                   errorCode: code,
                                   errorMessage: synologyErrorMessage(code: code))
            }
        } catch {
            plog("⚠️ Synology login request error host=\(redactedHost(host)): \(error.localizedDescription)")
            return LoginResult(success: false, needs2FA: false,
                               errorCode: nil,
                               errorMessage: error.localizedDescription,
                               underlyingError: error)
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
        /// 远端修改时间(来自 List API 的 additional.time.mtime), 用于重扫时按
        /// size+mtime 做指纹比对, 检测同名覆盖文件。
        var modifiedTime: Date? = nil
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

            let pageItems = files.map { f -> FileItem in
                let additional = f["additional"] as? [String: Any]
                // Synology additional.time.mtime 是 Unix 秒。
                let mtime = int64Value((additional?["time"] as? [String: Any])?["mtime"])
                return FileItem(
                    name: f["name"] as? String ?? "",
                    path: f["path"] as? String ?? "",
                    isDirectory: f["isdir"] as? Bool ?? false,
                    size: int64Value(additional?["size"]),
                    children: nil,
                    modifiedTime: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
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

        let baseURL = try await resolvedBaseURLString()
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

        let (data, response) = try await TrustedHTTPTransport.data(from: url, session: sharedSession)
        try validateDownloadResponse(data: data, response: response)
        return data
    }

    func downloadFileHead(path: String, maxBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        guard let sid else { throw SynologyError.notLoggedIn }

        let baseURL = try await resolvedBaseURLString()
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

        let responseLimit = maxBytes > Int.max - 64 * 1024 ? Int.max : maxBytes + 64 * 1024
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: sharedSession,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
        try validateDownloadResponse(data: data, response: response)
        // Some reverse proxies strip Range and return the whole file. Keep the
        // scanner's memory contract even in that configuration.
        return data.count > maxBytes ? Data(data.prefix(maxBytes)) : data
    }

    func downloadFileRange(path: String, offset: Int64, length: Int) async throws -> Data {
        guard let sid else { throw SynologyError.notLoggedIn }
        guard offset >= 0, length > 0 else { throw SynologyError.invalidResponse }

        let baseURL = try await resolvedBaseURLString()
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
        let end = offset.addingReportingOverflow(Int64(length - 1))
        guard !end.overflow else { throw SynologyError.invalidResponse }
        request.setValue("bytes=\(offset)-\(end.partialValue)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        let responseLimit = length > Int.max - 64 * 1024 ? Int.max : length + 64 * 1024
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: sharedSession,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
        try validateDownloadResponse(data: data, response: response)
        guard let http = response as? HTTPURLResponse else { throw SynologyError.invalidResponse }

        if http.statusCode == 206 {
            return data.count > length ? Data(data.prefix(length)) : data
        }
        // Range was ignored. A full-body response is already in memory, but
        // never pass it onward; select the requested window when possible.
        let start = Int(clamping: offset)
        if start < data.count {
            let end = min(data.count, start + length)
            return data.subdata(in: start..<end)
        }
        return data.count > length ? Data(data.suffix(length)) : data
    }

    private func validateDownloadResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SynologyError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                sid = nil
                throw SynologyError.notLoggedIn
            }
            throw SynologyError.httpError(http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("json") || data.first == UInt8(ascii: "{") else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == false else { return }
        let error = json["error"] as? [String: Any]
        let code = intValue(error?["code"])
        if code == 100 || code == 105 || code == 106 || code == 107 || code == 119 {
            sid = nil
            throw SynologyError.notLoggedIn
        }
        throw SynologyError.apiError(synologyErrorMessage(code: code))
    }

    /// Get thumbnail URL for a file
    func thumbnailURL(path: String, size: String = "small") -> URL? {
        guard let sid else { return nil }
        guard let baseURL = resolvedEndpoint?.baseURL ?? directBaseURL else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
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
        let baseURL = try await resolvedBaseURLString()
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

        let (responseData, response) = try await TrustedHTTPTransport.data(for: request, session: sharedSession)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true else {
            let err = json["error"] as? [String: Any]
            throw SynologyError.apiError("Upload failed: \(synologyErrorMessage(code: intValue(err?["code"])))")
        }
    }

    func deleteFile(path: String) async throws {
        guard let sid else { throw SynologyError.notLoggedIn }
        let pathData = try SafeJSONSerialization.data(withJSONObject: [path])
        let pathJSON = String(data: pathData, encoding: .utf8) ?? "[\"\(path)\"]"

        let data = try await request(path: "/webapi/entry.cgi", params: [
            "api": "SYNO.FileStation.Delete",
            "version": "2",
            "method": "start",
            "path": pathJSON,
            "recursive": "false",
            "_sid": sid,
        ])

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true else {
            let err = json["error"] as? [String: Any]
            throw SynologyError.apiError("Delete failed: \(synologyErrorMessage(code: intValue(err?["code"])))")
        }
    }

    // MARK: - HTTP

    private func request(path: String, params: [String: String], usePost: Bool = false) async throws -> Data {
        let baseURL = try await resolvedBaseURLString()
        let urlRequest: URLRequest
        if usePost {
            guard let url = URL(string: "\(baseURL)\(path)") else { throw SynologyError.invalidURL }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // Form-encode params: same percent-encoding rules as URL query
            // but '+' is reserved for space in form bodies — encode it as %2B
            // to avoid Synology decoding it as space.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=")
            let body = params.map { (k, v) -> String in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
            urlRequest = req
        } else {
            var components = URLComponents(string: "\(baseURL)\(path)")!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else { throw SynologyError.invalidURL }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            urlRequest = req
        }

        let (data, response) = try await TrustedHTTPTransport.data(for: urlRequest, session: sharedSession)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func synologyErrorMessage(code: Int) -> String {
        switch code {
        case 400: return String(localized: "synology_auth_error_400")
        case 401: return String(localized: "synology_auth_error_401")
        case 402: return String(localized: "synology_auth_error_402")
        case 403: return String(localized: "synology_auth_error_403")
        case 404: return String(localized: "synology_auth_error_404")
        case 406: return String(localized: "synology_auth_error_406")
        case 407: return String(localized: "synology_auth_error_407")
        case 408: return String(localized: "synology_auth_error_408")
        case 409: return String(localized: "synology_auth_error_409")
        case 410: return String(localized: "synology_auth_error_410")
        default:
            return String(
                format: String(localized: "synology_auth_error_unknown_format"),
                code
            )
        }
    }

    private func redactedHost(_ host: String) -> String {
        let parts = host.split(separator: ".")
        if parts.count >= 3, let first = parts.first {
            return "\(first.prefix(3))….\(parts.suffix(2).joined(separator: "."))"
        }
        guard !host.isEmpty else { return "(empty)" }
        return "\(host.prefix(3))…"
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
        case .notLoggedIn: return String(localized: "synology_error_not_logged_in")
        case .invalidURL: return String(localized: "synology_error_invalid_url")
        case .invalidResponse: return String(localized: "synology_error_invalid_response")
        case .httpError(let code):
            return String(format: String(localized: "synology_error_http_format"), code)
        case .apiError(let m): return m
        }
    }
}
