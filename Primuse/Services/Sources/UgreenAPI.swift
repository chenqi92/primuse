import Foundation
import Security

actor UgreenAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var token: String?
    private(set) var staticToken: String?
    private(set) var uid: String?

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
        var success: Bool
        var token: String?
        var needs2FA: Bool
        var errorMessage: String?

        init(success: Bool, token: String? = nil, needs2FA: Bool = false, errorMessage: String? = nil) {
            self.success = success
            self.token = token
            self.needs2FA = needs2FA
            self.errorMessage = errorMessage
        }
    }

    func login(account: String, password: String, otpCode: String? = nil) async -> LoginResult {
        do {
            let publicKeyData = try await fetchLoginPublicKey(for: account)
            let encryptedPassword = try Self.encrypt(password: password, withPublicKeyData: publicKeyData)
            return try await performLogin(account: account, passwordPayload: encryptedPassword, otpCode: otpCode)
        } catch {
            // Some early UGOS builds did not expose /verify/check. Keep the
            // previous plaintext path as a compatibility fallback.
            do {
                let fallback = try await performLogin(
                    account: account,
                    passwordPayload: password,
                    otpCode: otpCode
                )
                if fallback.success || fallback.needs2FA {
                    return fallback
                }
                let message = fallback.errorMessage ?? error.localizedDescription
                return LoginResult(
                    success: false,
                    errorMessage: "\(message)；RSA 登录初始化失败：\(error.localizedDescription)"
                )
            } catch {
                return LoginResult(success: false, errorMessage: error.localizedDescription)
            }
        }
    }

    func logout() async {
        guard token != nil else { return }
        _ = try? await postJSON(path: "/ugreen/v1/verify/logout", body: [:])
        token = nil
        staticToken = nil
        uid = nil
    }

    /// 清除会话, 让下一次 connect() 真正重新登录。会话过期 / 权限错误后
    /// 必须调用它, 否则 isLoggedIn 仍为 true, connect() 短路, 重连永不发生。
    func invalidateSession() {
        token = nil
        staticToken = nil
        uid = nil
    }

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }

        // 平铺式音乐目录单层超过 1000 个文件很常见, 必须翻页到尾,
        // 否则超出 page_size 的歌永远扫不进库且无任何提示。
        let pageSize = 1000
        var page = 1
        var allItems: [FileItem] = []

        while true {
            let dataDict = try await listPage(path: path, page: page, pageSize: pageSize)
            let list = (dataDict["list"] as? [[String: Any]]) ?? []
            let pageItems = list.map { f in
                FileItem(
                    name: f["name"] as? String ?? "",
                    path: f["path"] as? String ?? "",
                    isDirectory: f["is_dir"] as? Bool ?? false,
                    size: Int64(f["size"] as? Int ?? 0)
                )
            }
            allItems.append(contentsOf: pageItems)

            let total = intValue(dataDict["total"])
            if pageItems.count < pageSize || (total > 0 && allItems.count >= total) {
                break
            }
            page += 1
        }

        return allItems
    }

    /// 请求单页目录列表并校验响应体 code。绝不能把"无 list"当成"空目录"
    /// 返回 —— token 过期 / 权限不足 时响应里根本没有 `data.list` 字段, 静默
    /// 返回空数组会让 scanner 误判目录被清空, 把整源曲库删掉。只有 code==200
    /// 才解析; 认证失败清 token 抛 authenticationFailed, 其余抛 connectionFailed。
    private func listPage(path: String, page: Int, pageSize: Int) async throws -> [String: Any] {
        guard let token else { throw SourceError.connectionFailed("Not logged in") }
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/filemgr/list")!
        comps.queryItems = [.init(name: "token", value: token)]
        let body: [String: Any] = ["path": path, "page": page, "page_size": pageSize]

        let data = try await postJSON(url: comps.url!, body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let code = intValue(json["code"])
        let dataDict = json["data"] as? [String: Any]
        if code == 200 {
            // 成功 —— 即使 list 为空也是合法空目录。
            return dataDict ?? [:]
        }
        // 非成功 code: 认证类清 token 抛 authenticationFailed, 其余抛
        // connectionFailed。缺 list 字段的不可信响应一律不返回空数组。
        let hasList = dataDict?["list"] != nil
        if isAuthFailureCode(code) || !hasList {
            invalidateSession()
            if isAuthFailureCode(code) {
                throw SourceError.authenticationFailed
            }
        }
        let msg = json["message"] as? String ?? json["msg"] as? String ?? "code \(code)"
        throw SourceError.connectionFailed("Ugreen list failed: \(msg)")
    }

    private func isAuthFailureCode(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 1001 || code == 1002
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

    func downloadURL(path: String) -> URL? {
        guard let token else { return nil }
        // 用 URLComponents 让系统正确编码查询值: .urlQueryAllowed 不会转义
        // & / + / = / ?, 路径含这些字符 (R&B、AC+DC 类专辑名) 时手工拼接会
        // 截断 path 参数导致下载/播放必败。
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/file/download")
        comps?.queryItems = [
            .init(name: "path", value: path),
            .init(name: "token", value: token),
        ]
        return comps?.url
    }

    // MARK: - HTTP

    private func fetchLoginPublicKey(for account: String) async throws -> Data {
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/verify/check")!
        comps.queryItems = [.init(name: "token", value: "")]
        let (_, response) = try await postJSONResponse(
            url: comps.url!,
            body: ["username": account],
            authorize: false
        )

        guard let rsaToken = response.value(forHTTPHeaderField: "x-rsa-token"),
              rsaToken.isEmpty == false else {
            throw SourceError.connectionFailed("Ugreen RSA public key is missing")
        }
        return Self.decodeBase64(rsaToken) ?? Data(rsaToken.utf8)
    }

    private func performLogin(
        account: String,
        passwordPayload: String,
        otpCode: String?
    ) async throws -> LoginResult {
        var body: [String: Any] = [
            "username": account,
            "password": passwordPayload,
            "is_simple": true,
            "keepalive": true,
            "otp": otpCode != nil,
        ]
        if let otp = otpCode { body["otp_code"] = otp }

        let data = try await postJSON(path: "/ugreen/v1/verify/login", body: body, authorize: false)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let code = json["code"] as? Int ?? 0
        let d = json["data"] as? [String: Any]

        if code == 200 {
            let sessionToken = d?["token"] as? String
            let persistentToken = d?["static_token"] as? String
            guard let resolvedToken = sessionToken ?? persistentToken else {
                return LoginResult(success: false, errorMessage: "绿联登录成功但未返回 token")
            }
            self.token = resolvedToken
            self.staticToken = persistentToken
            self.uid = d?["uid"] as? String
            return LoginResult(success: true, token: resolvedToken)
        }
        if code == 1001 || (json["need_otp"] as? Bool == true) || (json["require_2fa"] as? Bool == true) {
            return LoginResult(success: false, needs2FA: true, errorMessage: "需要两步验证")
        }
        let msg = json["message"] as? String
            ?? json["msg"] as? String
            ?? json["debug"] as? String
            ?? "登录失败 (\(code))"
        return LoginResult(success: false, errorMessage: msg)
    }

    private func postJSON(path: String, body: [String: Any], authorize: Bool = true) async throws -> Data {
        try await postJSON(url: URL(string: "\(baseURLString)\(path)")!, body: body, authorize: authorize)
    }

    private func postJSON(url: URL, body: [String: Any], authorize: Bool = true) async throws -> Data {
        let (data, _) = try await postJSONResponse(url: url, body: body, authorize: authorize)
        return data
    }

    private func postJSONResponse(url: URL, body: [String: Any], authorize: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("HttpOnly", forHTTPHeaderField: "Cookie")
        if authorize, let token {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, response) = try await session().data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid Ugreen response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.connectionFailed("Ugreen HTTP \(http.statusCode)")
        }
        return (data, http)
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

    private nonisolated static func encrypt(password: String, withPublicKeyData keyData: Data) throws -> String {
        let derData = try derData(from: keyData)
        let keyCandidates = [derData, stripX509Header(from: derData)].compactMap { $0 }

        var lastError: String?
        for candidate in keyCandidates {
            var keyError: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: candidate.count * 8,
            ]
            guard let key = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, &keyError) else {
                lastError = keyError?.takeRetainedValue().localizedDescription
                continue
            }
            let algorithm = SecKeyAlgorithm.rsaEncryptionPKCS1
            guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
                lastError = "RSA PKCS#1 encryption is not supported"
                continue
            }
            var encryptError: Unmanaged<CFError>?
            guard let encrypted = SecKeyCreateEncryptedData(
                key,
                algorithm,
                Data(password.utf8) as CFData,
                &encryptError
            ) as Data? else {
                lastError = encryptError?.takeRetainedValue().localizedDescription
                continue
            }
            return encrypted.base64EncodedString()
        }

        throw SourceError.connectionFailed(lastError ?? "Invalid Ugreen RSA public key")
    }

    private nonisolated static func derData(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("BEGIN") else {
            return data
        }
        let base64 = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("-----") == false }
            .joined()
        guard let decoded = decodeBase64(base64) else {
            throw SourceError.connectionFailed("Invalid Ugreen RSA PEM")
        }
        return decoded
    }

    private nonisolated static func decodeBase64(_ value: String) -> Data? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private nonisolated static func stripX509Header(from data: Data) -> Data? {
        let rsaEncryptionOID = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        guard let oidRange = data.range(of: rsaEncryptionOID) else { return nil }
        var index = oidRange.upperBound
        let bytes = [UInt8](data)
        guard index < bytes.count, bytes[index] == 0x03 else { return nil }
        index += 1
        guard readASN1Length(bytes, index: &index) != nil else { return nil }
        guard index < bytes.count, bytes[index] == 0x00 else { return nil }
        index += 1
        guard index < data.count else { return nil }
        return data.subdata(in: index..<data.count)
    }

    private nonisolated static func readASN1Length(_ bytes: [UInt8], index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let first = Int(bytes[index])
        index += 1
        if first & 0x80 == 0 { return first }

        let byteCount = first & 0x7f
        guard byteCount > 0, byteCount <= 4, index + byteCount <= bytes.count else { return nil }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(bytes[index])
            index += 1
        }
        return length
    }
}
