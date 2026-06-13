import Foundation
import Security

/// 绿联(Ugreen)NAS 流式解析。登录需 RSA 加密密码(服务端先下发公钥),拿到 token 后
/// 下载地址把 token 放 query,AVPlayer 直连。RSA 加密逻辑与 iOS UgreenAPI 一致。
public actor UgreenStreamResolver: StreamResolver {
    private var tokens: [String: String] = [:]   // sourceID → token
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    public func invalidateSession(sourceID: String) { tokens[sourceID] = nil }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        let username = cred.username ?? source.username ?? ""
        guard let password = cred.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.baseURL(host: source.host ?? "", port: source.port, useSsl: source.useSsl) else {
            throw StreamResolveError.cannotBuildURL
        }
        let token = try await currentToken(source: source, base: base, username: username, password: password)
        guard let url = Self.downloadURL(base: base, path: song.filePath, token: token) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    private func currentToken(source: MusicSource, base: URL, username: String, password: String) async throws -> String {
        if let cached = tokens[source.id] { return cached }
        let keyData = try await fetchPublicKey(base: base, username: username)
        let encrypted = try Self.encrypt(password: password, withPublicKeyData: keyData)
        let token = try await login(base: base, username: username, encryptedPassword: encrypted)
        tokens[source.id] = token
        return token
    }

    private func fetchPublicKey(base: URL, username: String) async throws -> Data {
        var comp = URLComponents(url: base.appendingPathComponent("ugreen/v1/verify/check"),
                                 resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "token", value: "")]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              let rsaToken = http.value(forHTTPHeaderField: "x-rsa-token"), !rsaToken.isEmpty else {
            throw StreamResolveError.authFailed
        }
        return Self.decodeBase64(rsaToken) ?? Data(rsaToken.utf8)
    }

    private func login(base: URL, username: String, encryptedPassword: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("ugreen/v1/verify/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": username, "password": encryptedPassword,
            "is_simple": true, "keepalive": true, "otp": false,
        ])
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let token = Self.parseToken(data) else { throw StreamResolveError.authFailed }
        return token
    }

    // MARK: - 纯函数(可单测)

    static func baseURL(host: String, port: Int?, useSsl: Bool) -> URL? {
        var h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let r = h.range(of: "://") { scheme = String(h[..<r.lowerBound]).lowercased(); h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var hostPort = h
        if let port, port > 0, !h.contains(":") { hostPort = "\(h):\(port)" }
        return URL(string: "\(scheme)://\(hostPort)")
    }

    static func downloadURL(base: URL, path: String, token: String) -> URL? {
        guard var comp = URLComponents(url: base.appendingPathComponent("ugreen/v1/file/download"),
                                       resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "token", value: token)]
        return comp.url
    }

    static func parseToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 200, let d = json["data"] as? [String: Any] else { return nil }
        return (d["token"] as? String) ?? (d["static_token"] as? String)
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamResolveError.authFailed }
        guard (200...299).contains(http.statusCode) else { throw StreamResolveError.badServerResponse(http.statusCode) }
    }

    // MARK: - RSA 加密(与 iOS UgreenAPI 一致)

    static func encrypt(password: String, withPublicKeyData keyData: Data) throws -> String {
        let der = try derData(from: keyData)
        let candidates = [der, stripX509Header(from: der)].compactMap { $0 }
        var lastError: String?
        for candidate in candidates {
            var keyError: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: candidate.count * 8,
            ]
            guard let key = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, &keyError) else {
                lastError = keyError?.takeRetainedValue().localizedDescription; continue
            }
            guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
                lastError = "RSA PKCS#1 not supported"; continue
            }
            var encryptError: Unmanaged<CFError>?
            guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1,
                                                            Data(password.utf8) as CFData, &encryptError) as Data? else {
                lastError = encryptError?.takeRetainedValue().localizedDescription; continue
            }
            return encrypted.base64EncodedString()
        }
        _ = lastError
        throw StreamResolveError.authFailed
    }

    static func derData(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("BEGIN") else { return data }
        let base64 = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = decodeBase64(base64) else { throw StreamResolveError.cannotBuildURL }
        return decoded
    }

    static func decodeBase64(_ value: String) -> Data? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    static func stripX509Header(from data: Data) -> Data? {
        let oid = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        guard let oidRange = data.range(of: oid) else { return nil }
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

    static func readASN1Length(_ bytes: [UInt8], index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let first = Int(bytes[index]); index += 1
        if first & 0x80 == 0 { return first }
        let byteCount = first & 0x7f
        guard byteCount > 0, byteCount <= 4, index + byteCount <= bytes.count else { return nil }
        var length = 0
        for _ in 0..<byteCount { length = (length << 8) | Int(bytes[index]); index += 1 }
        return length
    }
}
