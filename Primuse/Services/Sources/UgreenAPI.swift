import Foundation
import Security

actor UgreenAPI {
    private let host: String
    private let port: Int
    private let useSsl: Bool
    private(set) var token: String?
    private(set) var staticToken: String?
    private(set) var uid: String?

    /// pewee 逆向确认的 v2 header 鉴权字段(登录响应里取):
    /// token_id → x-ugreen-security-key 头; public_key → 加密 token 得 x-ugreen-token 头。
    /// 老固件登录响应不带这两项时, v2AuthHeaders 返回 nil, 全部 v2 路径自动退回 v1。
    private(set) var tokenId: String?
    private(set) var loginPublicKey: String?

    /// v2 三步下载得到的 dl_url 短期缓存(path → (url, 取得时刻))。dl_url 内嵌
    /// 一次性下载令牌, 播放时 fetchRange 高频取 URL, 不缓存会每个分片都重跑两次
    /// 网络请求(detectionPermissions + getDownloadToken)。TTL 取保守 60s。
    private var v2DownloadCache: [String: (url: URL, time: Date)] = [:]

    /// 本会话级 v2 探测禁用位: 有 v2 凭证却发现此固件不支持 / 响应结构不符时置位,
    /// 避免之后每个目录、每个播放分片都白跑一遍 v2 再退回 v1。invalidateSession
    /// (含重登)时清零, 下次登录重新探测。列目录与下载相互独立(端点不同)。
    private var v2ListDisabled = false
    private var v2DownloadDisabled = false

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
        guard let token else { return }
        // logout 与其余业务端点一样靠 ?token= 鉴权(UGOS 不认 Authorization 头),
        // 旧实现把 token 放 Authorization 头, 实际登出可能根本没生效。
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/verify/logout")
        comps?.queryItems = [.init(name: "token", value: token)]
        if let url = comps?.url {
            _ = try? await postJSON(url: url, body: [:])
        }
        invalidateSession()
    }

    /// 清除会话, 让下一次 connect() 真正重新登录。会话过期 / 权限错误后
    /// 必须调用它, 否则 isLoggedIn 仍为 true, connect() 短路, 重连永不发生。
    func invalidateSession() {
        token = nil
        staticToken = nil
        uid = nil
        tokenId = nil
        loginPublicKey = nil
        v2DownloadCache.removeAll()
        v2ListDisabled = false
        v2DownloadDisabled = false
    }

    struct FileItem: Sendable {
        let name: String; let path: String; let isDirectory: Bool; let size: Int64
    }

    func listDirectory(path: String) async throws -> [FileItem] {
        guard token != nil else { throw SourceError.connectionFailed("Not logged in") }
        // 优先 pewee 真机验证过的 v2 getDirFileListV2; 此固件不支持 / 响应不可
        // 解析 / 忽略 path 时, listAllV2 返回 nil, 自动退回 v1 filemgr/list,
        // 保证不低于既有行为。
        if !v2ListDisabled, v2AuthHeaders() != nil {
            if let v2 = await listAllV2(path: path) {
                return v2
            }
            // 有 v2 凭证却列目录不可用(端点缺失 / 结构不符 / 忽略 path) → 本会话
            // 停用 v2 列目录, 后续目录直接走 v1, 不再每个目录白跑一遍 v2。
            v2ListDisabled = true
        }
        return try await listAllV1(path: path)
    }

    private func listAllV1(path: String) async throws -> [FileItem] {
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
        // 1024 = UGOS 登录过期 / 无效 token, 这是权威逆向源(Tom-Bom-badil、
        // UGreenNASAdmin、ugos-cli)一致确认的会话失效码。命中后必须清 token,
        // 让下次 connect() 重新登录, 否则会一直拿过期 token 失败。
        code == 401 || code == 403 || code == 1001 || code == 1002 || code == 1024
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

    func downloadURL(path: String) async -> URL? {
        // 优先 pewee 三步流程(detectionPermissions → getDownloadToken → dl_url);
        // 任一步失败 / 无 v2 凭证时退回 v1 直链 file/download?path=&token=。
        if let v2 = await resolveDownloadURLV2(path: path) { return v2 }
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

    // MARK: - v2 私有接口 (pewee-live/ugos_pro_api 真机逆向)
    //
    // v2 与 v1 鉴权方式不同: v1 把 token 拼进 ?token= query, v2 走三个请求头 —
    //   x-ugreen-security-key = 登录响应 token_id
    //   x-ugreen-token        = RSA(登录响应 token 明文, 登录响应 public_key) 再 base64
    //   cookie(token / token_uid) 由 URLSession cookie jar 在登录后自动回带
    // 列目录 getDirFileListV2 与下载三步流程都用这套头鉴权。
    //
    // ⚠️ 以下几处来自逆向、未经目标真机最终确认, 是后续抓包微调点 —— 任一不符
    //    即自动退回 v1, 不会比现状更差:
    //   1. getDirFileListV2 的 path 字段名与响应结构(条目 name/path/is_dir/size、
    //      list vs files) —— pewee 只验证了 root_type=3 固定根、未解析响应。
    //   2. dl_url 是否支持 Range / 一次性令牌能否复用(影响 seek 与边下边播)。

    /// 组装 v2 header 鉴权。缺 token_id / public_key(老固件) 时返回 nil → 退回 v1。
    private func v2AuthHeaders() -> [String: String]? {
        guard let token, let tokenId, let pub = loginPublicKey,
              let keyData = Self.decodeBase64(pub),
              let xToken = try? Self.encrypt(password: token, withPublicKeyData: keyData) else {
            return nil
        }
        return [
            "x-ugreen-security-key": tokenId,
            "x-ugreen-token": xToken,
        ]
    }

    /// 经 v2 getDirFileListV2 列目录。返回 nil 表示"此固件 v2 不可用 / 响应不可信 /
    /// 忽略了 path", 调用方据此退回 v1。认证问题统一交由 v1 路径处理与重登。
    private func listAllV2(path: String) async -> [FileItem]? {
        guard let headers = v2AuthHeaders() else { return nil }
        let limit = 2000
        var page = 1
        var allItems: [FileItem] = []
        // 非根目录时用于自检 v2 是否真按 path 导航(pewee 未证实 path 字段)。
        let normalized = (path == "/" || path.isEmpty) ? "" :
            (path.hasSuffix("/") ? String(path.dropLast()) : path)

        while true {
            guard let dataDict = await listPageV2(path: path, page: page, limit: limit, headers: headers) else {
                return nil
            }
            guard let list = (dataDict["list"] as? [[String: Any]]) ?? (dataDict["files"] as? [[String: Any]]) else {
                return nil  // 成功响应但既无 list 也无 files → 结构不符, 退回 v1
            }
            let pageItems = list.map { f in
                FileItem(
                    name: f["name"] as? String ?? "",
                    path: f["path"] as? String ?? "",
                    isDirectory: f["is_dir"] as? Bool ?? false,
                    size: Int64(f["size"] as? Int ?? 0)
                )
            }
            // path 导航自检: 请求子目录却返回项的 path 都不在该目录下, 说明此固件
            // 忽略了 path(总回固定根), 退回 v1 以免列错目录 / 递归死循环。
            if !normalized.isEmpty {
                let pathed = pageItems.filter { !$0.path.isEmpty }
                if !pathed.isEmpty,
                   !pathed.contains(where: { $0.path == normalized || $0.path.hasPrefix(normalized + "/") }) {
                    return nil
                }
            }
            allItems.append(contentsOf: pageItems)
            let total = intValue(dataDict["total"])
            if pageItems.count < limit || (total > 0 && allItems.count >= total) {
                break
            }
            page += 1
        }
        return allItems
    }

    /// 请求单页 v2 目录。任何失败(端点不存在/非 200/结构不符)一律返回 nil 让上层
    /// 退回 v1; 不在此处抛认证错(交由 v1 路径统一识别 1024 并重登)。
    private func listPageV2(path: String, page: Int, limit: Int, headers: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: "\(baseURLString)/ugreen/v2/filemgr/getDirFileListV2") else { return nil }
        // pewee 默认 body + 额外补 path(逆向未证实字段名, 不符则上层退回 v1)。
        let body: [String: Any] = [
            "path": path,
            "limit": limit, "page": page,
            "is_shield_recycle": false, "data_type": 0,
            "left_no_page_show": false, "left_count": 5000,
            "sort_type": 1, "reverse": false,
            "permission": 4, "root_type": 3,
        ]
        var hdrs = headers
        hdrs["referer"] = "\(baseURLString)/filemgr/?_filemgr=primuse"
        guard let (data, _) = try? await postJSONResponse(url: url, body: body, extraHeaders: hdrs) else {
            return nil
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard intValue(json["code"]) == 200, let dataDict = json["data"] as? [String: Any] else {
            return nil
        }
        return dataDict
    }

    /// pewee 下载三步: detectionPermissions(权限) → getDownloadToken(取 dl_url) →
    /// 返回拼好的绝对 dl_url(内嵌一次性令牌)。任一步失败返回 nil → 退回 v1 直链。
    private func resolveDownloadURLV2(path: String) async -> URL? {
        guard !v2DownloadDisabled, let headers = v2AuthHeaders() else { return nil }
        if let cached = v2DownloadCache[path], Date().timeIntervalSince(cached.time) < 60 {
            return cached.url
        }
        if let url = await fetchDownloadURLV2(path: path, headers: headers) {
            v2DownloadCache[path] = (url, Date())
            return url
        }
        // 有 v2 凭证却三步失败 → 本会话停用 v2 下载, 避免每个分片都白跑两次请求,
        // 退回 v1 直链。
        v2DownloadDisabled = true
        return nil
    }

    /// pewee 下载三步实现: detectionPermissions → getDownloadToken → 拼绝对 dl_url。
    private func fetchDownloadURLV2(path: String, headers: [String: String]) async -> URL? {
        // 1) 权限校验
        guard let detURL = URL(string: "\(baseURLString)/ugreen/v1/filemgr/detectionPermissions") else { return nil }
        guard let (dData, _) = try? await postJSONResponse(
            url: detURL,
            body: ["paths": [path], "type": 4, "intranet_share_id": 0],
            extraHeaders: headers) else { return nil }
        let dJson = (try? JSONSerialization.jsonObject(with: dData)) as? [String: Any] ?? [:]
        guard intValue(dJson["code"]) == 200 else { return nil }
        // 2) 取下载令牌 (GET, paths 用表单编码, 头鉴权)
        let enc = Self.formEncode(path)
        guard let tokURL = URL(string: "\(baseURLString)/ugreen/v2/filemgr/getDownloadToken?paths=\(enc)&intranet_share_id=0&coding=true") else {
            return nil
        }
        var req = URLRequest(url: tokURL)
        req.httpMethod = "GET"
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 15
        guard let (tData, tResp) = try? await session().data(for: req),
              let http = tResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let tJson = (try? JSONSerialization.jsonObject(with: tData)) as? [String: Any] ?? [:]
        guard intValue(tJson["code"]) == 200,
              let data = tJson["data"] as? [String: Any],
              let dlUrl = data["dl_url"] as? String, dlUrl.isEmpty == false else {
            return nil
        }
        // 3) dl_url 为相对路径, 拼绝对 URL; 内嵌一次性令牌, 一般可直接 GET。
        let absolute = dlUrl.hasPrefix("http") ? dlUrl : "\(baseURLString)\(dlUrl)"
        return URL(string: absolute)
    }

    /// application/x-www-form-urlencoded 风格编码(对齐 pewee 的 Java URLEncoder):
    /// 连 "/" 也编码成 %2F; 空格编成 %20(表单解码下与 + 等价, 服务端可解)。
    private nonisolated static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.*")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - HTTP

    private func fetchLoginPublicKey(for account: String) async throws -> Data {
        var comps = URLComponents(string: "\(baseURLString)/ugreen/v1/verify/check")!
        comps.queryItems = [.init(name: "token", value: "")]
        let (_, response) = try await postJSONResponse(
            url: comps.url!,
            body: ["username": account]
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

        let data = try await postJSON(path: "/ugreen/v1/verify/login", body: body)
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
            // uid 服务端可能返回 Int 或 String, 统一成字符串。
            if let u = d?["uid"] as? String { self.uid = u }
            else if let n = d?["uid"] as? NSNumber { self.uid = n.stringValue }
            // pewee v2 header 鉴权所需(老固件可能不返回, 届时 v2 自动退回 v1)。
            self.tokenId = d?["token_id"] as? String
            self.loginPublicKey = d?["public_key"] as? String
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

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(baseURLString)\(path)") else { throw URLError(.badURL) }
        return try await postJSON(url: url, body: body)
    }

    private func postJSON(url: URL, body: [String: Any], extraHeaders: [String: String] = [:]) async throws -> Data {
        let (data, _) = try await postJSONResponse(url: url, body: body, extraHeaders: extraHeaders)
        return data
    }

    private func postJSONResponse(url: URL, body: [String: Any], extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // v2 端点的头鉴权(x-ugreen-token / x-ugreen-security-key / referer)经此传入。
        for (key, value) in extraHeaders { req.setValue(value, forHTTPHeaderField: key) }
        // token 经各业务端点的 ?token= query 携带; 会话 cookie(token / token_uid)
        // 由 URLSession 默认 cookie storage 在登录响应 Set-Cookie 后自动回带,
        // 无需手写。旧代码写死 "Cookie: HttpOnly" 是错误的 ——"HttpOnly" 是
        // Set-Cookie 的属性名而非 cookie 值; 且 UGOS 不用 Authorization 头携带
        // token, 一并去掉避免误导与潜在干扰。
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
