import CryptoKit
import Foundation
import PrimuseKit

actor QnapAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private let alternateTLSValidationHostname: String?
    private(set) var sid: String?

    var baseURLString: String {
        let scheme = useSsl ? "https" : "http"
        return NetworkURLBuilder.baseURLString(host: host, scheme: scheme, port: port)
            ?? "\(scheme)://localhost:\(port)"
    }
    var isLoggedIn: Bool { sid != nil }

    init(
        host: String,
        port: Int,
        useSsl: Bool,
        alternateTLSValidationHostname: String? = nil
    ) {
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.alternateTLSValidationHostname = alternateTLSValidationHostname
    }

    // MARK: - Auth

    struct LoginResult: Sendable {
        var success: Bool
        var sid: String?
        var needs2FA: Bool
        var errorMessage: String?
        var underlyingError: (any Error)?
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
            guard let url = URL(string: "\(baseURLString)/cgi-bin/authLogin.cgi") else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
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

            let (data, _) = try await TrustedHTTPTransport.data(for: req, session: session())
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
                    return LoginResult(success: false, needs2FA: true, errorMessage: String(localized: "auth_two_factor_required"))
                }
                if authCode == 6 {
                    return LoginResult(success: false, needs2FA: true, errorMessage: String(localized: "auth_verification_code_invalid"))
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
            return LoginResult(
                success: false,
                needs2FA: false,
                errorMessage: String(localized: "auth_login_failed")
            )
        } catch {
            return LoginResult(
                success: false,
                needs2FA: false,
                errorMessage: error.localizedDescription,
                underlyingError: error
            )
        }
    }

    func logout() async {
        guard let sid else { return }
        guard var components = URLComponents(string: "\(baseURLString)/cgi-bin/authLogout.cgi") else {
            self.sid = nil
            return
        }
        components.queryItems = [URLQueryItem(name: "sid", value: sid)]
        if let url = FormSafeQueryURLBuilder.url(from: components) {
            _ = try? await TrustedHTTPTransport.data(from: url, session: session())
        }
        self.sid = nil
    }

    /// 清除会话, 让下一次 connect() 真正重新登录。会话过期 / 权限错误后
    /// 必须调用它, 否则 isLoggedIn 仍为 true, connect() 短路, 重连永不发生。
    func invalidateSession() {
        self.sid = nil
    }

    // MARK: - Files

    struct FileItem: Sendable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modifiedDate: Date?
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
        guard let url = FormSafeQueryURLBuilder.url(from: comps) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await TrustedHTTPTransport.data(
            from: url,
            session: session()
        )
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
                size: qnapInt64(d["filesize"]) ?? 0,
                modifiedDate: qnapInt64(d["epochmt"]).flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                }
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
        return FormSafeQueryURLBuilder.url(from: comps)
    }

    func createDirectory(name: String, at path: String) async throws {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        var components = URLComponents(
            string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi"
        )!
        components.queryItems = [
            .init(name: "func", value: "createdir"),
            .init(name: "sid", value: sid),
            .init(name: "dest_folder", value: name),
            .init(name: "dest_path", value: path.isEmpty ? "/" : path),
        ]
        guard let url = FormSafeQueryURLBuilder.url(from: components) else {
            throw URLError(.badURL)
        }
        let json = try await confirmedJSONRequest(url: url, operation: "create directory")
        guard qnapStatus(json) == 1 else {
            throw SourceError.connectionFailed(
                "QNAP create directory failed: status \(qnapStatus(json) ?? -1)"
            )
        }
    }

    func uploadFile(
        data: Data,
        toDirectory directory: String,
        fileName: String,
        overwrite: Bool
    ) async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-qnap-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try data.write(to: sourceURL, options: .atomic)
        try await uploadFile(
            localURL: sourceURL,
            toDirectory: directory,
            fileName: fileName,
            overwrite: overwrite
        )
    }

    func uploadFile(
        localURL: URL,
        toDirectory directory: String,
        fileName: String,
        overwrite: Bool
    ) async throws {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        let safeName = try validatedUploadFileName(fileName)
        let boundary = "primuse-qnap-\(UUID().uuidString)"
        let multipart = try makeMultipartUploadFile(
            sourceURL: localURL,
            fileName: safeName,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        let normalizedDirectory = directory.isEmpty ? "/" : directory
        let destination = (normalizedDirectory as NSString).appendingPathComponent(safeName)
        var components = URLComponents(
            string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi"
        )!
        components.queryItems = [
            .init(name: "func", value: "upload"),
            .init(name: "type", value: "standard"),
            .init(name: "sid", value: sid),
            .init(name: "dest_path", value: normalizedDirectory),
            .init(name: "overwrite", value: overwrite ? "1" : "0"),
            .init(name: "progress", value: destination.replacingOccurrences(of: "/", with: "-")),
            .init(name: "check_sum", value: "1"),
            .init(name: "md5", value: multipart.md5),
        ]
        guard let url = FormSafeQueryURLBuilder.url(from: components) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 3_600

        let responseData: Data
        let response: URLResponse
        if TrustedHTTPTransport.requiresPlainSocket(for: url) {
            request.httpBody = try Data(contentsOf: multipart.url, options: .mappedIfSafe)
            (responseData, response) = try await TrustedHTTPTransport.data(
                for: request,
                session: session(),
                maxBytes: 1024 * 1024
            )
        } else {
            (responseData, response) = try await session().upload(
                for: request,
                fromFile: multipart.url
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid QNAP upload response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              qnapStatus(json) == 1 else {
            let detail = String(data: responseData.prefix(4_096), encoding: .utf8) ?? ""
            throw SourceError.connectionFailed(
                "QNAP upload not confirmed: HTTP \(http.statusCode) \(detail)"
            )
        }
    }

    func moveFile(
        named fileName: String,
        from sourceDirectory: String,
        to destinationDirectory: String,
        overwrite: Bool
    ) async throws {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        var components = URLComponents(
            string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi"
        )!
        components.queryItems = [
            .init(name: "func", value: "move"),
            .init(name: "sid", value: sid),
            .init(name: "source_file", value: fileName),
            .init(name: "source_total", value: "1"),
            .init(name: "source_path", value: sourceDirectory),
            .init(name: "dest_path", value: destinationDirectory),
            .init(name: "mode", value: overwrite ? "0" : "1"),
            .init(name: "checksum", value: "1"),
        ]
        guard let url = FormSafeQueryURLBuilder.url(from: components) else {
            throw URLError(.badURL)
        }
        let json = try await confirmedJSONRequest(url: url, operation: "move")
        guard qnapStatus(json) == 1 else {
            throw SourceError.connectionFailed(
                "QNAP move failed: status \(qnapStatus(json) ?? -1)"
            )
        }
    }

    func deleteTemporaryItem(path: String) async throws {
        try await deleteFile(path: path, force: true)
    }

    /// File Station API v5 delete. `force=0` preserves QNAP's recycle-bin
    /// semantics. Only status=1/success=true is accepted as server confirmation.
    func deleteFile(path: String) async throws {
        try await deleteFile(path: path, force: false)
    }

    private func deleteFile(path: String, force: Bool) async throws {
        guard let sid else { throw SourceError.connectionFailed("Not logged in") }
        let normalized = path.isEmpty ? "/" : path
        let parent = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        guard !name.isEmpty else { throw SourceError.fileNotFound(path) }

        var comps = URLComponents(string: "\(baseURLString)/cgi-bin/filemanager/utilRequest.cgi")!
        comps.queryItems = [
            .init(name: "func", value: "delete"),
            .init(name: "sid", value: sid),
            .init(name: "path", value: parent.isEmpty ? "/" : parent),
            .init(name: "file_total", value: "1"),
            .init(name: "file_name", value: name),
            .init(name: "v", value: "1"),
            .init(name: "force", value: force ? "1" : "0"),
        ]
        guard let url = FormSafeQueryURLBuilder.url(from: comps) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await TrustedHTTPTransport.data(
            from: url,
            session: session()
        )
        if let http = response as? HTTPURLResponse,
           http.statusCode == 401 || http.statusCode == 403 {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("QNAP delete HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let success = (json["success"] as? Bool == true)
            || (json["success"] as? String)?.lowercased() == "true"
        guard qnapStatus(json) == 1, success || json["pid"] != nil else {
            let message = json["error"] as? String ?? json["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw SourceError.connectionFailed("QNAP delete not confirmed: \(message)")
        }
    }

    // MARK: - Helpers

    /// 长生命周期 session 复用: 带 delegate 的 session 在被 invalidate 前
    /// 强持有 delegate 与连接池, 每次新建且从不 invalidate 会随扫描线性泄漏
    /// 内存与文件描述符, 同时丢失 keep-alive 复用 (每请求重新 TLS 握手)。
    private lazy var sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: NetworkEndpointIdentity(
                    scheme: useSsl ? "https" : "http",
                    host: host,
                    port: port
                )
            ),
            delegateQueue: nil
        )
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

    private func qnapInt64(_ value: Any?) -> Int64? {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private func confirmedJSONRequest(
        url: URL,
        operation: String
    ) async throws -> [String: Any] {
        let (data, response) = try await TrustedHTTPTransport.data(
            from: url,
            session: session()
        )
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid QNAP \(operation) response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateSession()
            throw SourceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.connectionFailed(
                "QNAP \(operation) returned an invalid response"
            )
        }
        return json
    }

    private func validatedUploadFileName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              !trimmed.contains("\r"),
              !trimmed.contains("\n"),
              trimmed.utf8.count <= 255 else {
            throw SourceError.connectionFailed("Invalid QNAP upload file name")
        }
        return trimmed
    }

    private func makeMultipartUploadFile(
        sourceURL: URL,
        fileName: String,
        boundary: String
    ) throws -> (url: URL, md5: String) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-qnap-multipart-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw SourceError.connectionFailed("Unable to create QNAP upload body")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let input = try FileHandle(forReadingFrom: sourceURL)
        var digest = Insecure.MD5()
        do {
            let quotedName = fileName.replacingOccurrences(of: "\"", with: "_")
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\(fileName)\r\n".utf8
            ))
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(quotedName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
            ))
            while true {
                let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
                try output.write(contentsOf: data)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        let md5 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return (outputURL, md5)
    }

    private func qnapError(_ code: Int) -> String {
        switch code {
        case 0: return String(localized: "auth_login_failed")
        case 1: return String(localized: "auth_username_password_invalid")
        case 2: return String(localized: "auth_account_disabled")
        case 3: return String(localized: "auth_permission_denied")
        case 4: return String(localized: "auth_connection_limit_reached")
        case 5: return String(localized: "auth_two_factor_required")
        case 6: return String(localized: "auth_verification_code_invalid")
        case 7: return String(localized: "auth_ip_blocked")
        default: return String(format: String(localized: "auth_error_code_format"), code)
        }
    }
}
