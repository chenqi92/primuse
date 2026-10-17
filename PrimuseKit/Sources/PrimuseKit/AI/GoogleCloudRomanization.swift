import Foundation

// MARK: - 服务账号密钥

/// Google Cloud 服务账号密钥（下载下来的那份 JSON）里用得到的字段。Cloud Translation 的
/// romanizeText 不收 API key，只认 OAuth2 访问令牌，所以要用服务账号自己签令牌。
public struct GoogleServiceAccountKey: Equatable, Sendable {
    public let projectID: String
    public let clientEmail: String
    /// PKCS#8 PEM（「-----BEGIN PRIVATE KEY-----」）。
    public let privateKeyPEM: String
    public let privateKeyID: String?
    public let tokenURI: String

    public static let defaultTokenURI = "https://oauth2.googleapis.com/token"

    public enum ParseError: Error, Equatable, Sendable {
        case notJSON
        case notServiceAccount
        case missingField(String)
        case invalidProjectID
        case invalidTokenURI
        case invalidPrivateKey
    }

    public init(
        projectID: String,
        clientEmail: String,
        privateKeyPEM: String,
        privateKeyID: String? = nil,
        tokenURI: String = GoogleServiceAccountKey.defaultTokenURI
    ) {
        self.projectID = projectID
        self.clientEmail = clientEmail
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyID = privateKeyID
        self.tokenURI = tokenURI
    }

    /// 解析导入的 JSON（文件或粘贴的文字）。私钥要能解出 RSA 密钥，令牌地址只认 Google 自己的。
    public static func parse(_ data: Data) throws -> GoogleServiceAccountKey {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw ParseError.notJSON
        }
        if let type = root["type"] as? String, type != "service_account" {
            throw ParseError.notServiceAccount
        }
        func field(_ name: String) throws -> String {
            guard let value = (root[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw ParseError.missingField(name)
            }
            return value
        }
        let projectID = try field("project_id")
        guard isValidProjectID(projectID) else { throw ParseError.invalidProjectID }
        let clientEmail = try field("client_email")
        guard clientEmail.contains("@") else { throw ParseError.missingField("client_email") }
        let privateKey = try field("private_key")
        do {
            _ = try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPEM: privateKey)
        } catch {
            throw ParseError.invalidPrivateKey
        }
        let tokenURI = (root["token_uri"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .googleKeyFieldOrNil ?? defaultTokenURI
        guard isTrustedTokenURI(tokenURI) else { throw ParseError.invalidTokenURI }
        let keyID = (root["private_key_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .googleKeyFieldOrNil
        return GoogleServiceAccountKey(
            projectID: projectID,
            clientEmail: clientEmail,
            privateKeyPEM: privateKey,
            privateKeyID: keyID,
            tokenURI: tokenURI
        )
    }

    /// 只存用得到的字段，存进钥匙串的就是这一份。
    public func storedJSON() -> Data {
        var object: [String: String] = [
            "type": "service_account",
            "project_id": projectID,
            "client_email": clientEmail,
            "private_key": privateKeyPEM,
            "token_uri": tokenURI,
        ]
        if let privateKeyID { object["private_key_id"] = privateKeyID }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// 项目 ID：小写字母、数字、连字符，域名项目多一段「example.com:」。
    static func isValidProjectID(_ value: String) -> Bool {
        guard (4...100).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "-" || scalar == "." || scalar == ":"
        }
    }

    /// 签好的令牌请求等于这个服务账号的通行证，只发给 Google 自己的令牌地址。
    static func isTrustedTokenURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else { return false }
        return host == "oauth2.googleapis.com"
            || host == "accounts.google.com"
            || host.hasSuffix(".googleapis.com")
    }
}

private extension String {
    var googleKeyFieldOrNil: String? { isEmpty ? nil : self }
}

// MARK: - PKCS#8 → PKCS#1

/// 服务账号的私钥是 PKCS#8 PEM，Security 框架的 `SecKeyCreateWithData` 要的是 PKCS#1 的
/// RSAPrivateKey DER。这里只做 DER 解包：PrivateKeyInfo ::= SEQUENCE { version, algorithm,
/// OCTET STRING privateKey }，取出 OCTET STRING 里的那份。
public enum RSAPrivateKeyDERUnwrapper {
    public enum UnwrapError: Error, Equatable, Sendable {
        case invalidPEM
        case invalidDER
        case notRSA
    }

    /// rsaEncryption 1.2.840.113549.1.1.1
    static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    public static func pkcs1DER(fromPEM pem: String) throws -> Data {
        let normalized = pem.replacingOccurrences(of: "\\n", with: "\n")
        let isPKCS1 = normalized.contains("BEGIN RSA PRIVATE KEY")
        guard isPKCS1 || normalized.contains("BEGIN PRIVATE KEY") else { throw UnwrapError.invalidPEM }
        let body = normalized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: body) else { throw UnwrapError.invalidPEM }
        if isPKCS1 {
            var reader = DERReader(bytes: [UInt8](der))
            guard (try? reader.element(tag: 0x30)) != nil, reader.isAtEnd else { throw UnwrapError.invalidDER }
            return der
        }
        return try pkcs1DER(fromPKCS8: der)
    }

    public static func pkcs1DER(fromPKCS8 der: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](der))
        let info = try outer.element(tag: 0x30)
        var reader = DERReader(bytes: info)
        _ = try reader.element(tag: 0x02)                     // version
        var algorithm = DERReader(bytes: try reader.element(tag: 0x30))
        let oid = try algorithm.element(tag: 0x06)
        guard oid == rsaEncryptionOID else { throw UnwrapError.notRSA }
        let privateKey = try reader.element(tag: 0x04)
        // 里面应当是一个完整的 RSAPrivateKey SEQUENCE。
        var inner = DERReader(bytes: privateKey)
        _ = try inner.element(tag: 0x30)
        guard inner.isAtEnd else { throw UnwrapError.invalidDER }
        return Data(privateKey)
    }

    struct DERReader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func element(tag expected: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == expected else { throw UnwrapError.invalidDER }
            offset += 1
            let length = try readLength()
            guard length <= bytes.count - offset else { throw UnwrapError.invalidDER }
            let value = Array(bytes[offset..<(offset + length)])
            offset += length
            return value
        }

        private mutating func readLength() throws -> Int {
            guard offset < bytes.count else { throw UnwrapError.invalidDER }
            let first = bytes[offset]
            offset += 1
            guard first & 0x80 != 0 else { return Int(first) }
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), count <= bytes.count - offset else { throw UnwrapError.invalidDER }
            var length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
            return length
        }
    }
}

// MARK: - 访问令牌

/// 服务账号换访问令牌：RS256 签一个 JWT（iss = 服务账号邮箱、aud = 令牌地址、一小时有效），
/// 用 jwt-bearer 授权方式换回 access_token。签名本身在 App 层用 Security 框架做。
public enum GoogleServiceAccountJWT {
    public static let translationScope = "https://www.googleapis.com/auth/cloud-translation"
    public static let lifetime: TimeInterval = 3600

    private struct Header: Encodable {
        let alg = "RS256"
        let typ = "JWT"
        let kid: String?
    }

    private struct Claims: Encodable {
        let iss: String
        let scope: String
        let aud: String
        let iat: Int
        let exp: Int
    }

    /// 要签名的那一段：base64url(header) + "." + base64url(claims)。
    public static func signingInput(
        for key: GoogleServiceAccountKey,
        issuedAt: Date,
        scope: String = translationScope
    ) -> String {
        let issued = Int(issuedAt.timeIntervalSince1970.rounded(.down))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = (try? encoder.encode(Header(kid: key.privateKeyID))) ?? Data()
        let claims = (try? encoder.encode(Claims(
            iss: key.clientEmail,
            scope: scope,
            aud: key.tokenURI,
            iat: issued,
            exp: issued + Int(lifetime)
        ))) ?? Data()
        return base64URL(header) + "." + base64URL(claims)
    }

    public static func assertion(signingInput: String, signature: Data) -> String {
        signingInput + "." + base64URL(signature)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// application/x-www-form-urlencoded 的请求体。
    public static func tokenRequestBody(assertion: String) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let body = "grant_type=" + encoded("urn:ietf:params:oauth:grant-type:jwt-bearer")
            + "&assertion=" + encoded(assertion)
        return Data(body.utf8)
    }
}

public struct GoogleAccessToken: Equatable, Sendable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// 过期前 5 分钟就换新的，免得请求发到一半令牌失效。
    public func isUsable(at now: Date, margin: TimeInterval = 300) -> Bool {
        now < expiresAt.addingTimeInterval(-margin)
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidResponse
    }

    public static func decode(_ data: Data, receivedAt: Date) throws -> GoogleAccessToken {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (root["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw DecodeError.invalidResponse
        }
        let lifetime: TimeInterval
        if let seconds = root["expires_in"] as? Double {
            lifetime = seconds
        } else if let seconds = root["expires_in"] as? Int {
            lifetime = TimeInterval(seconds)
        } else {
            lifetime = GoogleServiceAccountJWT.lifetime
        }
        return GoogleAccessToken(
            value: token,
            expiresAt: receivedAt.addingTimeInterval(max(0, min(lifetime, 24 * 3600)))
        )
    }
}

// MARK: - romanizeText

/// Cloud Translation v3 的 romanizeText（预览版）。
public enum GoogleCloudRomanizeText {
    /// 官方支持表。韩文、中文不在里面，这两种直接用本机生成。
    public static let supportedLanguageCodes: Set<String> = [
        "ar", "am", "bn", "be", "gu", "hi", "ja", "kn", "my", "ru", "sr", "ta", "te", "uk",
    ]

    public static let maximumLinesPerRequest = 50
    public static let maximumCharactersPerRequest = 5_000

    public static func supports(languageCode: String) -> Bool {
        supportedLanguageCodes.contains(LyricRomanizationLanguagePolicy.baseLanguage(languageCode))
    }

    public static func endpoint(projectID: String) -> URL? {
        guard GoogleServiceAccountKey.isValidProjectID(projectID) else { return nil }
        return URL(string: "https://translation.googleapis.com/v3/projects/\(projectID)/locations/global:romanizeText")
    }

    private struct RequestBody: Encodable {
        let sourceLanguageCode: String
        let contents: [String]

        enum CodingKeys: String, CodingKey {
            case sourceLanguageCode = "source_language_code"
            case contents
        }
    }

    public static func requestBody(sourceLanguageCode: String, contents: [String]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(RequestBody(
            sourceLanguageCode: LyricRomanizationLanguagePolicy.baseLanguage(sourceLanguageCode),
            contents: contents
        ))) ?? Data()
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidResponse
        case countMismatch(expected: Int, actual: Int)
    }

    /// 结果与 contents 同序同数，数目对不上整批作废。
    public static func decodeResponse(_ data: Data, expectedCount: Int) throws -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["romanizations"] as? [[String: Any]] else {
            throw DecodeError.invalidResponse
        }
        guard items.count == expectedCount else {
            throw DecodeError.countMismatch(expected: expectedCount, actual: items.count)
        }
        return items.map {
            (($0["romanizedText"] ?? $0["romanized_text"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// 分批：每批不超过 50 行、5000 个字符（按 Unicode 码位数）。超长的单行自成一批。
    public static func batches(
        _ texts: [String],
        maximumLines: Int = maximumLinesPerRequest,
        maximumCharacters: Int = maximumCharactersPerRequest
    ) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        var characters = 0
        for (index, text) in texts.enumerated() {
            let length = text.unicodeScalars.count
            let lines = index - start
            if lines > 0, lines >= maximumLines || characters + length > maximumCharacters {
                batches.append(start..<index)
                start = index
                characters = 0
            }
            characters += length
        }
        if start < texts.count { batches.append(start..<texts.count) }
        return batches
    }
}

/// Google 返回的错误，给设置页显示「最近一次错误原因」。
public struct GoogleCloudErrorSummary: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case unauthorized
        case permissionDenied
        case quotaExceeded
        case invalidRequest
        case serverError
        case other
    }

    public let statusCode: Int
    public let kind: Kind
    /// 服务端给的说明（例如「项目里没有启用 Cloud Translation API」），截到 300 字。
    public let message: String?

    public init(statusCode: Int, kind: Kind, message: String?) {
        self.statusCode = statusCode
        self.kind = kind
        self.message = message
    }

    /// 兼容两种错误体：API 的 `{"error":{"code","message","status"}}` 和令牌地址的
    /// `{"error":"invalid_grant","error_description":"…"}`。
    public static func parse(statusCode: Int, body: Data) -> GoogleCloudErrorSummary {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var message: String?
        var status: String?
        if let error = root?["error"] as? [String: Any] {
            message = error["message"] as? String
            status = error["status"] as? String
        } else if let error = root?["error"] as? String {
            status = error
            message = (root?["error_description"] as? String) ?? error
        }
        let trimmed = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let bounded = trimmed.map { String($0.prefix(300)) }.flatMap { $0.isEmpty ? nil : $0 }
        return GoogleCloudErrorSummary(
            statusCode: statusCode,
            kind: kind(statusCode: statusCode, status: status),
            message: bounded
        )
    }

    static func kind(statusCode: Int, status: String?) -> Kind {
        switch (statusCode, status?.uppercased()) {
        case (401, _), (_, "UNAUTHENTICATED"), (_, "INVALID_GRANT"): return .unauthorized
        case (403, _), (_, "PERMISSION_DENIED"): return .permissionDenied
        case (429, _), (_, "RESOURCE_EXHAUSTED"): return .quotaExceeded
        case (400, _), (_, "INVALID_ARGUMENT"): return .invalidRequest
        case (500...599, _): return .serverError
        default: return .other
        }
    }
}
