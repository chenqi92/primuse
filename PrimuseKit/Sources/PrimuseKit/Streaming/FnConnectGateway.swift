import CommonCrypto
import CryptoKit
import Foundation
import Security

// MARK: - Domain & Rejection Recognition

/// Parsed FN Connect gateway host. Recognizes both subdomain proxies
/// (`navidrome.program.fnos.net`) and path-proxied gateway hosts
/// (`program.fnos.net/app/...`) across fnOS's official relay domains.
public struct FnConnectGatewayAddress: Codable, Equatable, Hashable, Sendable {
    public static let knownSuffixes = ["fnos.net", "5ddd.com", "trzznas.com"]

    public let host: String
    public let fnID: String
    public let suffix: String
    public let gatewayHost: String
    public let serviceLabel: String?

    public var isSubdomainProxy: Bool { serviceLabel != nil }

    public init(
        host: String,
        fnID: String,
        suffix: String,
        gatewayHost: String,
        serviceLabel: String?
    ) {
        self.host = host
        self.fnID = fnID
        self.suffix = suffix
        self.gatewayHost = gatewayHost
        self.serviceLabel = serviceLabel
    }

    public static func parseHost(_ rawHost: String) -> FnConnectGatewayAddress? {
        var host = NetworkHostAuthority.canonicalHost(rawHost)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        for suffix in knownSuffixes {
            let dotSuffix = ".\(suffix)"
            guard host.hasSuffix(dotSuffix) else { continue }
            let prefix = String(host.dropLast(dotSuffix.count))
            guard !prefix.isEmpty else { return nil }
            let labels = prefix.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return nil }

            let candidateFNID = String(labels.last!)
            guard !isIPStyleLabel(candidateFNID),
                  let fnID = FnConnectResolver.fnID(from: candidateFNID) else {
                return nil
            }
            let serviceLabel: String? = labels.count > 1
                ? labels.dropLast().joined(separator: ".")
                : nil
            return FnConnectGatewayAddress(
                host: host,
                fnID: fnID,
                suffix: suffix,
                gatewayHost: "\(fnID).\(suffix)",
                serviceLabel: serviceLabel
            )
        }
        return nil
    }

    public static func parse(url: URL) -> FnConnectGatewayAddress? {
        guard let host = url.host else { return nil }
        return parseHost(host)
    }

    /// Returns the parsed gateway address when an HTTPS request should carry
    /// FN Connect gateway authentication. Skips Feiniu Music's own API and the
    /// gateway's control endpoints so they never recurse or mix sessions.
    public static func interceptedAddress(for url: URL) -> FnConnectGatewayAddress? {
        guard url.scheme?.lowercased() == "https",
              let address = parse(url: url) else {
            return nil
        }
        let lowerPath = url.path.lowercased()
        if lowerPath == "/access_code_verify" || lowerPath.hasPrefix("/access_code_verify/")
            || lowerPath == "/websocket" || lowerPath.hasPrefix("/websocket/")
            || lowerPath == "/trimcon" || lowerPath.hasPrefix("/trimcon/")
            || lowerPath.contains(FnMusicAPIProtocol.apiPath) {
            return nil
        }
        return address
    }

    /// Detects whether an HTTP response came from the FN Connect gateway
    /// denying access rather than from the underlying third-party service.
    public static func gatewayRejection(
        for requestURL: URL,
        method: String? = nil,
        response: HTTPURLResponse,
        bodyPrefix: Data?
    ) -> FnConnectGatewayRejection? {
        guard let address = interceptedAddress(for: requestURL) else { return nil }

        if [401, 403, 429].contains(response.statusCode),
           let challenge = response.value(forHTTPHeaderField: "X-Trim-Safe-Code-Challenge"),
           challenge.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return .accessCodeRequired
        }

        if (301...308).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: requestURL)?.absoluteURL {
            let targetHost = target.host?.lowercased() ?? ""
            let targetPath = target.path.lowercased()
            if (targetHost == address.gatewayHost || knownSuffixes.contains(targetHost))
                && (targetPath.contains("/login") || targetPath == "/" || targetPath.hasPrefix("/v/")) {
                return .sessionRejected
            }
        }

        guard response.statusCode == 403 || response.statusCode == 401 else { return nil }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.contains("text/html") else { return nil }

        if let bodyPrefix, !bodyPrefix.isEmpty {
            let text = String(data: bodyPrefix.prefix(4096), encoding: .utf8)
                ?? String(data: bodyPrefix.prefix(4096), encoding: .isoLatin1)
                ?? ""
            let lower = text.lowercased()
            if lower.contains("fn connect")
                || lower.contains("fn-connect")
                || lower.contains("trim-connect")
                || text.contains("暂无权限访问该服务") {
                return .sessionRejected
            }
            return nil
        }

        if method?.uppercased() == "HEAD", response.statusCode == 403 {
            return .sessionRejected
        }
        return nil
    }

    private static func isIPStyleLabel(_ label: String) -> Bool {
        let parts = label.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == part
        }
    }
}

public enum FnConnectGatewayRejection: Equatable, Sendable {
    case sessionRejected
    case accessCodeRequired
}

// MARK: - Binding, Credentials & Session Models

public enum FnConnectGatewayScope: String, Codable, Equatable, Hashable, Sendable {
    /// Stored under `fnconnect-gateway.shared.<fnID>` and shared across sources
    /// targeting the same NAS. Independent of any `.fnMusic` source lifecycle.
    case shared
    /// Stored under `fnconnect-gateway.source.<sourceID>` for a source that
    /// intentionally uses a different NAS account than the shared profile.
    case dedicated
}

public struct FnConnectGatewayBinding: Codable, Equatable, Hashable, Sendable {
    public var fnID: String
    public var username: String
    public var scope: FnConnectGatewayScope

    public init(fnID: String, username: String, scope: FnConnectGatewayScope) {
        self.fnID = fnID.lowercased()
        self.username = username
        self.scope = scope
    }
}

/// Syncable NAS gateway login secret (username, password, optional access code).
public struct FnConnectGatewayCredential: Codable, Equatable, Hashable, Sendable {
    public var fnID: String
    public var username: String
    public var password: String
    public var accessCode: String?

    public init(
        fnID: String,
        username: String,
        password: String,
        accessCode: String? = nil
    ) {
        self.fnID = fnID.lowercased()
        self.username = username
        self.password = password
        let trimmedCode = accessCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessCode = trimmedCode?.isEmpty == false ? trimmedCode : nil
    }

    public func encodedJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from jsonString: String) -> FnConnectGatewayCredential? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FnConnectGatewayCredential.self, from: data)
    }
}

/// Device-local gateway session (tokens + HMAC secret tied to this device's `did`).
/// Must never be synced across devices.
public struct FnConnectGatewayPersistedSession: Codable, Equatable, Sendable {
    public var gatewayHost: String
    public var fnID: String
    public var username: String
    public var deviceID: String
    public var token: String
    public var longToken: String
    public var secretBase64: String
    public var entryToken: String
    public var backID: String
    public var updatedAt: Date

    public init(
        gatewayHost: String,
        fnID: String,
        username: String,
        deviceID: String,
        token: String,
        longToken: String,
        secretBase64: String,
        entryToken: String,
        backID: String = "0000000000000000",
        updatedAt: Date = Date()
    ) {
        self.gatewayHost = gatewayHost.lowercased()
        self.fnID = fnID.lowercased()
        self.username = username
        self.deviceID = deviceID
        self.token = token
        self.longToken = longToken
        self.secretBase64 = secretBase64
        self.entryToken = entryToken
        self.backID = backID
        self.updatedAt = updatedAt
    }

    public func encodedJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from jsonString: String) -> FnConnectGatewayPersistedSession? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FnConnectGatewayPersistedSession.self, from: data)
    }

    public func headers(accessCode: String?) -> [String: String] {
        var result = FnMusicAPIProtocol.accessCodeHeaders(accessCode)
        result["Cookie"] = mergedCookieHeader(existing: nil)
        return result
    }

    public func mergedCookieHeader(existing: String?) -> String {
        let managedNames: Set<String> = ["entry-token", "fnos-token", "mode"]
        var pairs: [String] = []
        if let existing, !existing.isEmpty {
            for part in existing.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let name = trimmed.split(separator: "=", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                guard !managedNames.contains(name) else { continue }
                pairs.append(trimmed)
            }
        }
        if !entryToken.isEmpty {
            pairs.append("entry-token=\(entryToken)")
        }
        if !token.isEmpty {
            pairs.append("fnos-token=\(token)")
        }
        pairs.append("mode=relay")
        return pairs.joined(separator: "; ")
    }
}

public struct FnConnectTwoFactorChallenge: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let gatewayHost: String
    public let fnID: String
    public let username: String
    public let accessToken: String
    public let secureEmail: String?
    public let accessCode: String?
    public let deviceID: String

    public init(
        id: UUID = UUID(),
        gatewayHost: String,
        fnID: String,
        username: String,
        accessToken: String,
        secureEmail: String? = nil,
        accessCode: String? = nil,
        deviceID: String
    ) {
        self.id = id
        self.gatewayHost = gatewayHost.lowercased()
        self.fnID = fnID.lowercased()
        self.username = username
        self.accessToken = accessToken
        self.secureEmail = secureEmail
        self.accessCode = accessCode
        self.deviceID = deviceID
    }
}

public enum FnConnectGatewayError: Error, LocalizedError, Equatable, Sendable {
    case missingCredential
    case accessCodeRequired
    case accessCodeRejected
    case authenticationFailed(String?)
    case ipBanned
    case twoFactorRequired(FnConnectTwoFactorChallenge)
    case twoFactorSetupRequired
    case invalidTwoFactorCode
    case entryTokenUnavailable
    case invalidResponse
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return PMString("error.fnConnectGateway.missingCredential")
        case .accessCodeRequired:
            return PMString("error.fnConnect.accessCodeRequired")
        case .accessCodeRejected:
            return PMString("error.fnConnect.accessCodeRejected")
        case .authenticationFailed(let message):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return PMString("error.fnConnectGateway.authenticationFailed")
        case .ipBanned:
            return PMString("error.fnConnectGateway.ipBanned")
        case .twoFactorRequired:
            return PMString("error.fnConnectGateway.twoFactorRequired")
        case .twoFactorSetupRequired:
            return PMString("error.fnConnectGateway.twoFactorSetupRequired")
        case .invalidTwoFactorCode:
            return PMString("error.fnConnectGateway.invalidTwoFactorCode")
        case .entryTokenUnavailable:
            return PMString("error.fnConnectGateway.entryTokenUnavailable")
        case .invalidResponse:
            return PMString("error.fnConnect.invalidResponse")
        case .unreachable:
            return PMString("error.fnConnect.unreachable")
        }
    }

    var shouldBackOffAutomaticRetries: Bool {
        switch self {
        case .accessCodeRequired, .accessCodeRejected, .authenticationFailed,
             .ipBanned, .twoFactorRequired, .twoFactorSetupRequired, .invalidTwoFactorCode:
            return true
        case .missingCredential, .entryTokenUnavailable, .invalidResponse, .unreachable:
            return false
        }
    }
}

public enum FnConnectGatewayProtocol {
    public static let credentialExtraKey = "fnconnect_gateway_credential"
    private static let deviceIDDefaultsKey = "com.primuse.fnconnect.gateway.device-id.v1"
    private static let deviceIDLock = NSLock()

    public static func sharedCredentialAccount(fnID: String) -> String {
        "fnconnect-gateway.shared.\(fnID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public static func sourceCredentialAccount(sourceID: String) -> String {
        "fnconnect-gateway.source.\(sourceID)"
    }

    public static func localSessionAccount(fnID: String, username: String) -> String {
        let normalizedFNID = fnID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUser = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalizedUser.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "fnconnect-gateway.session.\(normalizedFNID).\(digest)"
    }

    /// Stable per-device browser-class device ID used only for FN Connect gateway
    /// WebSocket sessions, kept separate from Feiniu Music's `FnMusicAPIProtocol.deviceID`
    /// so the two sessions never evict each other while 2FA trusted-device state persists.
    public static func gatewayDeviceID(defaults: UserDefaults = .standard) -> String {
        deviceIDLock.lock()
        defer { deviceIDLock.unlock() }

        if let stored = defaults.string(forKey: deviceIDDefaultsKey), isValidDeviceID(stored) {
            return stored.lowercased()
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(generated, forKey: deviceIDDefaultsKey)
        return generated
    }

    public static func applyingHeaders(
        _ gatewayHeaders: [String: String],
        to request: URLRequest
    ) -> URLRequest {
        var updated = request
        for (name, value) in gatewayHeaders {
            if name.caseInsensitiveCompare("Cookie") == .orderedSame {
                let merged = mergeCookies(existing: updated.value(forHTTPHeaderField: "Cookie"), incoming: value)
                updated.setValue(merged, forHTTPHeaderField: "Cookie")
            } else {
                updated.setValue(value, forHTTPHeaderField: name)
            }
        }
        return updated
    }

    public static func mergeHeaders(
        existing: [String: String],
        gatewayHeaders: [String: String]
    ) -> [String: String] {
        var merged = existing
        for (name, value) in gatewayHeaders {
            if name.caseInsensitiveCompare("Cookie") == .orderedSame {
                let existingKey = merged.keys.first { $0.caseInsensitiveCompare("Cookie") == .orderedSame }
                let existingCookie = existingKey.flatMap { merged.removeValue(forKey: $0) }
                merged["Cookie"] = mergeCookies(existing: existingCookie, incoming: value)
            } else {
                if let existingKey = merged.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                   existingKey != name {
                    merged.removeValue(forKey: existingKey)
                }
                merged[name] = value
            }
        }
        return merged
    }

    private static func mergeCookies(existing: String?, incoming: String) -> String {
        let incomingPairs = parseCookiePairs(incoming)
        let incomingNames = Set(incomingPairs.map { $0.name.lowercased() })
        var ordered: [String] = []
        if let existing {
            for pair in parseCookiePairs(existing) where !incomingNames.contains(pair.name.lowercased()) {
                ordered.append(pair.raw)
            }
        }
        ordered.append(contentsOf: incomingPairs.map(\.raw))
        return ordered.joined(separator: "; ")
    }

    private static func parseCookiePairs(_ header: String) -> [(name: String, raw: String)] {
        header.split(separator: ";").compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let eq = trimmed.firstIndex(of: "=") else { return nil }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, trimmed)
        }
    }

    private static func isValidDeviceID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        }
    }
}

// MARK: - TaskLocal Context

public enum FnConnectGatewayContext {
    @TaskLocal public static var overrideCredential: FnConnectGatewayCredential?
    @TaskLocal public static var sourceID: String?
}

// MARK: - Crypto Primitives (Apple Native Frameworks Only)

public enum FnConnectGatewayCrypto {
    private static let aesKeyAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let rsaOIDBytes: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    public static func randomAESKeyString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        }
        let chars = bytes.map { aesKeyAlphabet[Int($0) % aesKeyAlphabet.count] }
        return String(decoding: chars, as: UTF8.self)
    }

    public static func randomIV() -> Data {
        var bytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        }
        return Data(bytes)
    }

    public static func makeReqID(
        backID: String = "0000000000000000",
        sequence: UInt16,
        timestamp: UInt32? = nil
    ) -> String {
        let ts = timestamp ?? UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
        let trimmedBack = backID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBack: String
        if trimmedBack.count == 16 {
            normalizedBack = trimmedBack
        } else if trimmedBack.count > 16 {
            normalizedBack = String(trimmedBack.prefix(16))
        } else {
            normalizedBack = String(repeating: "0", count: 16 - trimmedBack.count) + trimmedBack
        }
        return String(format: "%08x%@%04x", ts, normalizedBack, sequence)
    }

    public static func parseRSAPublicKey(pem: String) throws -> SecKey {
        let body = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body), !der.isEmpty else {
            throw FnConnectGatewayError.invalidResponse
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) {
            return key
        }
        if let pkcs1 = unwrapRSASubjectPublicKeyInfo(der),
           let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) {
            return key
        }
        throw FnConnectGatewayError.invalidResponse
    }

    public static func encryptRSA(_ data: Data, publicKeyPEM: String) throws -> Data {
        let key = try parseRSAPublicKey(pem: publicKeyPEM)
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionPKCS1,
            data as CFData,
            &error
        ) as Data? else {
            throw FnConnectGatewayError.invalidResponse
        }
        return encrypted
    }

    public static func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try aes256CBC(operation: CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    public static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try aes256CBC(operation: CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
    }

    public static func hmacSHA256Base64(message: String, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: secret)
        )
        return Data(mac).base64EncodedString()
    }

    public static func signedFrame(jsonString: String, secret: Data) -> String {
        hmacSHA256Base64(message: jsonString, secret: secret) + jsonString
    }

    public static func encryptedEnvelope(
        payloadJSON: Data,
        publicKeyPEM: String,
        aesKeyString: String,
        iv: Data
    ) throws -> String {
        let keyData = Data(aesKeyString.utf8)
        let rsaEncrypted = try encryptRSA(keyData, publicKeyPEM: publicKeyPEM)
        let aesEncrypted = try aes256CBCEncrypt(payloadJSON, key: keyData, iv: iv)
        let envelope: [String: String] = [
            "req": "encrypted",
            "iv": iv.base64EncodedString(),
            "rsa": rsaEncrypted.base64EncodedString(),
            "aes": aesEncrypted.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw FnConnectGatewayError.invalidResponse
        }
        return text
    }

    /// Unwraps an X.509 SubjectPublicKeyInfo DER blob to its inner PKCS#1
    /// `RSAPublicKey` sequence when a platform Security build expects PKCS#1.
    public static func unwrapRSASubjectPublicKeyInfo(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var cursor = 0
        guard let outer = readASN1Element(bytes, cursor: &cursor, expectedTag: 0x30) else { return nil }
        var innerCursor = outer.contentStart
        guard let algSeq = readASN1Element(bytes, cursor: &innerCursor, expectedTag: 0x30) else { return nil }
        let algSlice = Array(bytes[algSeq.contentStart..<algSeq.end])
        guard algSlice.starts(with: rsaOIDBytes) else { return nil }
        guard let bitString = readASN1Element(bytes, cursor: &innerCursor, expectedTag: 0x03),
              bitString.end > bitString.contentStart,
              bytes[bitString.contentStart] == 0x00 else {
            return nil
        }
        let pkcs1Start = bitString.contentStart + 1
        guard pkcs1Start < bitString.end, bytes[pkcs1Start] == 0x30 else { return nil }
        return Data(bytes[pkcs1Start..<bitString.end])
    }

    private struct ASN1Element {
        let contentStart: Int
        let end: Int
    }

    private static func readASN1Element(
        _ bytes: [UInt8],
        cursor: inout Int,
        expectedTag: UInt8
    ) -> ASN1Element? {
        guard cursor + 2 <= bytes.count, bytes[cursor] == expectedTag else { return nil }
        cursor += 1
        let firstLen = bytes[cursor]
        cursor += 1
        let length: Int
        if firstLen < 0x80 {
            length = Int(firstLen)
        } else {
            let count = Int(firstLen & 0x7F)
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[cursor])
                cursor += 1
            }
            length = value
        }
        let contentStart = cursor
        let end = contentStart + length
        guard end <= bytes.count else { return nil }
        cursor = end
        return ASN1Element(contentStart: contentStart, end: end)
    }

    private static func aes256CBC(
        operation: CCOperation,
        input: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw FnConnectGatewayError.invalidResponse
        }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            input.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, input.count,
                            outBuf.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw FnConnectGatewayError.invalidResponse
        }
        output.count = moved
        return output
    }
}

// MARK: - WebSocket Seam

public protocol FnConnectGatewayWebSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receiveText() async throws -> String
    func close()
}

private final class URLSessionGatewayWebSocket: FnConnectGatewayWebSocketConnection, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let timeout: TimeInterval

    init(request: URLRequest, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 2, 30)
        self.session = URLSession(configuration: configuration)
        self.task = session.webSocketTask(with: request)
        self.timeout = timeout
        self.task.resume()
    }

    func send(_ text: String) async throws {
        try await withTimeout(timeout) {
            try await self.task.send(.string(text))
        }
    }

    func receiveText() async throws -> String {
        try await withTimeout(timeout) {
            let message = try await self.task.receive()
            switch message {
            case .string(let text):
                return text
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    throw FnConnectGatewayError.invalidResponse
                }
                return text
            @unknown default:
                throw FnConnectGatewayError.invalidResponse
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw URLError(.timedOut)
            }
            return first
        }
    }
}

// MARK: - Protocol Client

public struct FnConnectGatewayClient: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias WebSocketFactory = @Sendable (URLRequest) async throws -> any FnConnectGatewayWebSocketConnection

    public struct PreparedTwoFactorSocket: Sendable {
        let socket: any FnConnectGatewayWebSocketConnection
        let publicKeyPEM: String
        let si: String
        let nextSequence: UInt16
    }

    public enum LoginOutcome: Sendable {
        case authenticated(FnConnectGatewayPersistedSession)
        case twoFactorRequired(FnConnectTwoFactorChallenge, PreparedTwoFactorSocket)
    }

    private let dataLoader: DataLoader
    private let webSocketFactory: WebSocketFactory
    private let timeout: TimeInterval

    public init(
        timeout: TimeInterval = 15,
        dataLoader: DataLoader? = nil,
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.timeout = timeout
        self.dataLoader = dataLoader ?? { request in
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
        self.webSocketFactory = webSocketFactory ?? { request in
            URLSessionGatewayWebSocket(request: request, timeout: timeout)
        }
    }

    public func verifyAccessCode(
        gatewayHost: String,
        accessCode: String?
    ) async throws {
        guard let url = URL(string: "https://\(gatewayHost)/access_code_verify") else {
            throw FnConnectGatewayError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("mode=relay", forHTTPHeaderField: "Cookie")
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await dataLoader(request)
        } catch {
            if error is CancellationError { throw error }
            throw FnConnectGatewayError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw FnConnectGatewayError.invalidResponse
        }
        switch http.statusCode {
        case 200...299, 404:
            return
        case 401, 403, 429:
            throw accessCode?.isEmpty == false
                ? FnConnectGatewayError.accessCodeRejected
                : FnConnectGatewayError.accessCodeRequired
        default:
            throw FnConnectGatewayError.unreachable
        }
    }

    public func refreshWithLongToken(
        gatewayHost: String,
        fnID: String,
        session: FnConnectGatewayPersistedSession,
        accessCode: String?
    ) async throws -> FnConnectGatewayPersistedSession {
        guard !session.longToken.isEmpty,
              let secretBytes = Data(base64Encoded: session.secretBase64),
              !secretBytes.isEmpty else {
            throw FnConnectGatewayError.authenticationFailed(nil)
        }

        let socket = try await openWebSocket(gatewayHost: gatewayHost, accessCode: accessCode)
        defer { socket.close() }

        var sequence: UInt16 = 1
        let siReqID = FnConnectGatewayCrypto.makeReqID(sequence: sequence)
        sequence &+= 1
        let siResp = try await sendPlainJSON(
            ["req": "util.getSI", "reqid": siReqID],
            reqID: siReqID,
            on: socket
        )
        guard (siResp["result"] as? String) == "succ",
              let si = nonEmptyString(siResp["si"]) else {
            throw FnConnectGatewayError.invalidResponse
        }

        let loginReqID = FnConnectGatewayCrypto.makeReqID(backID: session.backID, sequence: sequence)
        sequence &+= 1
        let loginResp = try await sendSignedJSON(
            [
                "req": "user.tokenLogin",
                "reqid": loginReqID,
                "token": session.longToken,
                "deviceType": "Browser",
                "deviceName": "Primuse",
                "did": session.deviceID,
                "si": si,
            ],
            reqID: loginReqID,
            secret: secretBytes,
            on: socket
        )
        guard (loginResp["result"] as? String) == "succ" else {
            let errno = intValue(loginResp["errno"])
            if errno == 131_089 { throw FnConnectGatewayError.ipBanned }
            throw FnConnectGatewayError.authenticationFailed(nonEmptyString(loginResp["errmsg"]))
        }

        let token = nonEmptyString(loginResp["token"]) ?? session.token
        let longToken = nonEmptyString(loginResp["longToken"]) ?? session.longToken
        let backID = nonEmptyString(loginResp["backId"]) ?? session.backID
        guard !token.isEmpty else { throw FnConnectGatewayError.invalidResponse }

        let entryToken = try await exchangeEntryToken(
            on: socket,
            secret: secretBytes,
            backID: backID,
            previousEntryToken: session.entryToken,
            sequence: &sequence
        )
        return FnConnectGatewayPersistedSession(
            gatewayHost: gatewayHost,
            fnID: fnID,
            username: session.username,
            deviceID: session.deviceID,
            token: token,
            longToken: longToken,
            secretBase64: secretBytes.base64EncodedString(),
            entryToken: entryToken,
            backID: backID,
            updatedAt: Date()
        )
    }

    public func login(
        gatewayHost: String,
        fnID: String,
        credential: FnConnectGatewayCredential,
        deviceID: String
    ) async throws -> LoginOutcome {
        try await verifyAccessCode(gatewayHost: gatewayHost, accessCode: credential.accessCode)

        let socket = try await openWebSocket(gatewayHost: gatewayHost, accessCode: credential.accessCode)
        var keepSocketOpen = false
        defer {
            if !keepSocketOpen { socket.close() }
        }

        var sequence: UInt16 = 1
        let pubReqID = FnConnectGatewayCrypto.makeReqID(sequence: sequence)
        sequence &+= 1
        let pubResp = try await sendPlainJSON(
            ["req": "util.crypto.getRSAPub", "reqid": pubReqID],
            reqID: pubReqID,
            on: socket
        )
        guard (pubResp["result"] as? String) == "succ",
              let pubPEM = nonEmptyString(pubResp["pub"]),
              let si = nonEmptyString(pubResp["si"]) else {
            throw FnConnectGatewayError.invalidResponse
        }

        let aesKeyStr = FnConnectGatewayCrypto.randomAESKeyString()
        let iv = FnConnectGatewayCrypto.randomIV()
        let loginReqID = FnConnectGatewayCrypto.makeReqID(sequence: sequence)
        sequence &+= 1

        let payload: [String: Any] = [
            "req": "user.login",
            "reqid": loginReqID,
            "user": credential.username,
            "password": credential.password,
            "deviceName": "Primuse",
            "deviceType": "Browser",
            "stay": true,
            "did": deviceID,
            "si": si,
        ]
        let loginResp = try await sendEncryptedJSON(
            payload,
            reqID: loginReqID,
            publicKeyPEM: pubPEM,
            aesKeyString: aesKeyStr,
            iv: iv,
            on: socket
        )

        guard (loginResp["result"] as? String) == "succ" else {
            let errno = intValue(loginResp["errno"])
            if errno == 131_089 { throw FnConnectGatewayError.ipBanned }
            throw FnConnectGatewayError.authenticationFailed(nonEmptyString(loginResp["errmsg"]))
        }

        let isBindTwofa = intValue(loginResp["isBindTwofaSecret"]) == 1
        let isTrusted = intValue(loginResp["isTrustedDevice"]) == 1
        let isEnforced = intValue(loginResp["isTwofaEnforced"]) == 1

        if isEnforced && !isBindTwofa {
            throw FnConnectGatewayError.twoFactorSetupRequired
        }
        if isBindTwofa && !isTrusted {
            guard let accessToken = nonEmptyString(loginResp["accessToken"]) else {
                throw FnConnectGatewayError.invalidResponse
            }
            let challenge = FnConnectTwoFactorChallenge(
                gatewayHost: gatewayHost,
                fnID: fnID,
                username: credential.username,
                accessToken: accessToken,
                secureEmail: nonEmptyString(loginResp["secureEmail"]),
                accessCode: credential.accessCode,
                deviceID: deviceID
            )
            let prepared = PreparedTwoFactorSocket(
                socket: socket,
                publicKeyPEM: pubPEM,
                si: si,
                nextSequence: sequence
            )
            keepSocketOpen = true
            return .twoFactorRequired(challenge, prepared)
        }

        let session = try await finalizeAuthenticatedLogin(
            response: loginResp,
            gatewayHost: gatewayHost,
            fnID: fnID,
            username: credential.username,
            deviceID: deviceID,
            aesKeyString: aesKeyStr,
            iv: iv,
            socket: socket,
            sequence: &sequence
        )
        return .authenticated(session)
    }

    public func verifyTwoFactor(
        challenge: FnConnectTwoFactorChallenge,
        code: String,
        trustDevice: Bool,
        preparedSocket: PreparedTwoFactorSocket? = nil
    ) async throws -> FnConnectGatewayPersistedSession {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw FnConnectGatewayError.invalidTwoFactorCode
        }

        if let preparedSocket {
            do {
                return try await submitTwoFactor(
                    challenge: challenge,
                    code: trimmedCode,
                    trustDevice: trustDevice,
                    socket: preparedSocket.socket,
                    publicKeyPEM: preparedSocket.publicKeyPEM,
                    si: preparedSocket.si,
                    startingSequence: preparedSocket.nextSequence,
                    closeOnExit: false
                )
            } catch let gatewayError as FnConnectGatewayError {
                throw gatewayError
            } catch {
                // Fall back to a fresh WebSocket if the held connection timed out
                // while the user was reading their authenticator app.
                preparedSocket.socket.close()
            }
        }

        let socket = try await openWebSocket(
            gatewayHost: challenge.gatewayHost,
            accessCode: challenge.accessCode
        )
        defer { socket.close() }

        var sequence: UInt16 = 1
        let pubReqID = FnConnectGatewayCrypto.makeReqID(sequence: sequence)
        sequence &+= 1
        let pubResp = try await sendPlainJSON(
            ["req": "util.crypto.getRSAPub", "reqid": pubReqID],
            reqID: pubReqID,
            on: socket
        )
        guard (pubResp["result"] as? String) == "succ",
              let pubPEM = nonEmptyString(pubResp["pub"]),
              let si = nonEmptyString(pubResp["si"]) else {
            throw FnConnectGatewayError.invalidResponse
        }

        return try await submitTwoFactor(
            challenge: challenge,
            code: trimmedCode,
            trustDevice: trustDevice,
            socket: socket,
            publicKeyPEM: pubPEM,
            si: si,
            startingSequence: sequence,
            closeOnExit: false
        )
    }

    // MARK: - Private WebSocket Steps

    private func submitTwoFactor(
        challenge: FnConnectTwoFactorChallenge,
        code: String,
        trustDevice: Bool,
        socket: any FnConnectGatewayWebSocketConnection,
        publicKeyPEM: String,
        si: String,
        startingSequence: UInt16,
        closeOnExit: Bool
    ) async throws -> FnConnectGatewayPersistedSession {
        defer { if closeOnExit { socket.close() } }
        var sequence = startingSequence
        let aesKeyStr = FnConnectGatewayCrypto.randomAESKeyString()
        let iv = FnConnectGatewayCrypto.randomIV()
        let reqID = FnConnectGatewayCrypto.makeReqID(sequence: sequence)
        sequence &+= 1

        let payload: [String: Any] = [
            "req": "user.2fa.loginVerify",
            "reqid": reqID,
            "code": code,
            "isTrustedDevice": trustDevice,
            "accessToken": challenge.accessToken,
            "stay": 1,
            "deviceName": "Primuse",
            "deviceType": "Browser",
            "did": challenge.deviceID,
            "si": si,
        ]
        let verifyResp = try await sendEncryptedJSON(
            payload,
            reqID: reqID,
            publicKeyPEM: publicKeyPEM,
            aesKeyString: aesKeyStr,
            iv: iv,
            on: socket
        )
        guard (verifyResp["result"] as? String) == "succ" else {
            let errno = intValue(verifyResp["errno"])
            if errno == 135_168 { throw FnConnectGatewayError.invalidTwoFactorCode }
            if errno == 131_089 { throw FnConnectGatewayError.ipBanned }
            throw FnConnectGatewayError.authenticationFailed(nonEmptyString(verifyResp["errmsg"]))
        }

        return try await finalizeAuthenticatedLogin(
            response: verifyResp,
            gatewayHost: challenge.gatewayHost,
            fnID: challenge.fnID,
            username: challenge.username,
            deviceID: challenge.deviceID,
            aesKeyString: aesKeyStr,
            iv: iv,
            socket: socket,
            sequence: &sequence
        )
    }

    private func finalizeAuthenticatedLogin(
        response: [String: Any],
        gatewayHost: String,
        fnID: String,
        username: String,
        deviceID: String,
        aesKeyString: String,
        iv: Data,
        socket: any FnConnectGatewayWebSocketConnection,
        sequence: inout UInt16
    ) async throws -> FnConnectGatewayPersistedSession {
        guard let token = nonEmptyString(response["token"]),
              let encryptedSecretB64 = nonEmptyString(response["secret"]),
              let encryptedSecret = Data(base64Encoded: encryptedSecretB64) else {
            throw FnConnectGatewayError.invalidResponse
        }
        let secretBytes = try FnConnectGatewayCrypto.aes256CBCDecrypt(
            encryptedSecret,
            key: Data(aesKeyString.utf8),
            iv: iv
        )
        guard !secretBytes.isEmpty else { throw FnConnectGatewayError.invalidResponse }

        let longToken = nonEmptyString(response["longToken"]) ?? ""
        let backID = nonEmptyString(response["backId"]) ?? "0000000000000000"

        let entryToken = try await exchangeEntryToken(
            on: socket,
            secret: secretBytes,
            backID: backID,
            previousEntryToken: nil,
            sequence: &sequence
        )
        return FnConnectGatewayPersistedSession(
            gatewayHost: gatewayHost,
            fnID: fnID,
            username: username,
            deviceID: deviceID,
            token: token,
            longToken: longToken,
            secretBase64: secretBytes.base64EncodedString(),
            entryToken: entryToken,
            backID: backID,
            updatedAt: Date()
        )
    }

    private func exchangeEntryToken(
        on socket: any FnConnectGatewayWebSocketConnection,
        secret: Data,
        backID: String,
        previousEntryToken: String?,
        sequence: inout UInt16
    ) async throws -> String {
        let attempts: [[String: Any]] = {
            if let previousEntryToken, !previousEntryToken.isEmpty {
                return [["token": previousEntryToken], [:]]
            }
            return [[:]]
        }()

        for dataPayload in attempts {
            let reqID = FnConnectGatewayCrypto.makeReqID(backID: backID, sequence: sequence)
            sequence &+= 1
            let resp = try await sendSignedJSON(
                [
                    "req": "appcgi.sac.entry.v1.exchangeEntryToken",
                    "reqid": reqID,
                    "data": dataPayload,
                ],
                reqID: reqID,
                secret: secret,
                on: socket
            )
            if (resp["result"] as? String) == "succ",
               let data = resp["data"] as? [String: Any],
               let entryToken = nonEmptyString(data["token"]) {
                return entryToken
            }
        }
        throw FnConnectGatewayError.entryTokenUnavailable
    }

    private func openWebSocket(
        gatewayHost: String,
        accessCode: String?
    ) async throws -> any FnConnectGatewayWebSocketConnection {
        guard let url = URL(string: "wss://\(gatewayHost)/websocket?type=main") else {
            throw FnConnectGatewayError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("mode=relay", forHTTPHeaderField: "Cookie")
        request.setValue("https://\(gatewayHost)", forHTTPHeaderField: "Origin")
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            return try await webSocketFactory(request)
        } catch {
            if error is CancellationError { throw error }
            throw FnConnectGatewayError.unreachable
        }
    }

    private func sendPlainJSON(
        _ object: [String: Any],
        reqID: String,
        on socket: any FnConnectGatewayWebSocketConnection
    ) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw FnConnectGatewayError.invalidResponse
        }
        return try await sendAndAwaitResponse(frame: text, reqID: reqID, on: socket)
    }

    private func sendEncryptedJSON(
        _ object: [String: Any],
        reqID: String,
        publicKeyPEM: String,
        aesKeyString: String,
        iv: Data,
        on socket: any FnConnectGatewayWebSocketConnection
    ) async throws -> [String: Any] {
        let payloadJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let frame = try FnConnectGatewayCrypto.encryptedEnvelope(
            payloadJSON: payloadJSON,
            publicKeyPEM: publicKeyPEM,
            aesKeyString: aesKeyString,
            iv: iv
        )
        return try await sendAndAwaitResponse(frame: frame, reqID: reqID, on: socket)
    }

    private func sendSignedJSON(
        _ object: [String: Any],
        reqID: String,
        secret: Data,
        on socket: any FnConnectGatewayWebSocketConnection
    ) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw FnConnectGatewayError.invalidResponse
        }
        let frame = FnConnectGatewayCrypto.signedFrame(jsonString: jsonString, secret: secret)
        return try await sendAndAwaitResponse(frame: frame, reqID: reqID, on: socket)
    }

    private func sendAndAwaitResponse(
        frame: String,
        reqID: String,
        on socket: any FnConnectGatewayWebSocketConnection
    ) async throws -> [String: Any] {
        do {
            try await socket.send(frame)
            for _ in 0..<32 {
                let text = try await socket.receiveText()
                guard let jsonData = text.data(using: .utf8),
                      let dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
                    continue
                }
                if let incomingReqID = dict["reqid"] as? String {
                    if incomingReqID == reqID { return dict }
                    continue
                }
                // Some fatal gateway frames omit reqid.
                if dict["result"] != nil { return dict }
            }
            throw FnConnectGatewayError.invalidResponse
        } catch let error as FnConnectGatewayError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FnConnectGatewayError.unreachable
        }
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

// MARK: - Session Store & Runtime Coordination

public actor FnConnectGatewaySessionStore {
    public static let shared = FnConnectGatewaySessionStore()

    public typealias CredentialResolver = @Sendable (
        _ gatewayHost: String,
        _ fnID: String,
        _ requestHost: String,
        _ sourceID: String?
    ) -> FnConnectGatewayCredential?

    public typealias SessionLoader = @Sendable (_ fnID: String, _ username: String) -> FnConnectGatewayPersistedSession?
    public typealias SessionSaver = @Sendable (_ session: FnConnectGatewayPersistedSession) -> Void
    public typealias SessionRemover = @Sendable (_ fnID: String, _ username: String) -> Void

    private struct SessionKey: Hashable, Sendable {
        let fnID: String
        let username: String

        init(fnID: String, username: String) {
            self.fnID = fnID.lowercased()
            self.username = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private struct PendingChallengeRecord {
        let challenge: FnConnectTwoFactorChallenge
        let prepared: FnConnectGatewayClient.PreparedTwoFactorSocket
        let createdAt: Date
    }

    private struct FailureBackoff {
        let error: FnConnectGatewayError
        let until: Date
    }

    private let client: FnConnectGatewayClient
    private let now: @Sendable () -> Date
    private var credentialResolver: CredentialResolver?
    private var sessionLoader: SessionLoader?
    private var sessionSaver: SessionSaver?
    private var sessionRemover: SessionRemover?
    private var deviceIDProvider: @Sendable () -> String

    private var sessions: [SessionKey: FnConnectGatewayPersistedSession] = [:]
    private var inFlightAuth: [SessionKey: Task<FnConnectGatewayPersistedSession, Error>] = [:]
    private var pendingChallenges: [UUID: PendingChallengeRecord] = [:]
    private var failureBackoffs: [SessionKey: FailureBackoff] = [:]

    private static let automaticFailureBackoffInterval: TimeInterval = 60
    private static let challengeLifetime: TimeInterval = 5 * 60

    public init(
        client: FnConnectGatewayClient = FnConnectGatewayClient(),
        deviceIDProvider: @escaping @Sendable () -> String = { FnConnectGatewayProtocol.gatewayDeviceID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.deviceIDProvider = deviceIDProvider
        self.now = now
    }

    public func configure(
        credentialResolver: CredentialResolver?,
        sessionLoader: SessionLoader? = nil,
        sessionSaver: SessionSaver? = nil,
        sessionRemover: SessionRemover? = nil,
        deviceIDProvider: (@Sendable () -> String)? = nil
    ) {
        self.credentialResolver = credentialResolver
        self.sessionLoader = sessionLoader
        self.sessionSaver = sessionSaver
        self.sessionRemover = sessionRemover
        if let deviceIDProvider {
            self.deviceIDProvider = deviceIDProvider
        }
    }

    /// Interactive authentication used when adding/editing a source. Bypasses
    /// automatic failure backoff and throws `.twoFactorRequired` if OTP is needed.
    public func authenticate(
        gatewayHost: String,
        credential: FnConnectGatewayCredential
    ) async throws -> FnConnectGatewayPersistedSession {
        let key = SessionKey(fnID: credential.fnID, username: credential.username)
        failureBackoffs.removeValue(forKey: key)
        return try await authenticateLocked(
            gatewayHost: gatewayHost.lowercased(),
            credential: credential,
            forceRefresh: true,
            interactive: true
        )
    }

    public func verifyTwoFactor(
        challenge: FnConnectTwoFactorChallenge,
        code: String,
        trustDevice: Bool
    ) async throws -> FnConnectGatewayPersistedSession {
        pruneExpiredChallenges()
        let record = pendingChallenges[challenge.id]
        let session: FnConnectGatewayPersistedSession
        do {
            session = try await client.verifyTwoFactor(
                challenge: challenge,
                code: code,
                trustDevice: trustDevice,
                preparedSocket: record?.prepared
            )
        } catch let error as FnConnectGatewayError where error == .invalidTwoFactorCode {
            // Keep the pending challenge intact so the user can retry the code.
            throw error
        } catch {
            if let removed = pendingChallenges.removeValue(forKey: challenge.id) {
                removed.prepared.socket.close()
            }
            throw error
        }

        if let removed = pendingChallenges.removeValue(forKey: challenge.id) {
            removed.prepared.socket.close()
        }
        let key = SessionKey(fnID: session.fnID, username: session.username)
        failureBackoffs.removeValue(forKey: key)
        sessions[key] = session
        sessionSaver?(session)
        return session
    }

    public func cancelTwoFactor(challengeID: UUID) {
        if let removed = pendingChallenges.removeValue(forKey: challengeID) {
            removed.prepared.socket.close()
        }
    }

    /// Resolves headers to attach to an outgoing request targeting an FN Connect
    /// gateway URL. Returns `nil` when the URL is not a gateway URL or when no
    /// gateway credentials are configured for that `fnID`.
    public func headers(
        for url: URL,
        forceRefresh: Bool = false
    ) async throws -> [String: String]? {
        guard let address = FnConnectGatewayAddress.interceptedAddress(for: url) else {
            return nil
        }
        guard let credential = resolveCredential(for: address) else {
            return nil
        }

        let key = SessionKey(fnID: credential.fnID, username: credential.username)
        if !forceRefresh, let cached = cachedSession(for: key, gatewayHost: address.gatewayHost) {
            return cached.headers(accessCode: credential.accessCode)
        }

        if !forceRefresh, let backoff = failureBackoffs[key], now() < backoff.until {
            throw backoff.error
        }

        let session = try await authenticateLocked(
            gatewayHost: address.gatewayHost,
            credential: credential,
            forceRefresh: forceRefresh,
            interactive: false
        )
        return session.headers(accessCode: credential.accessCode)
    }

    public func applyingHeaders(
        to request: URLRequest,
        forceRefresh: Bool = false
    ) async throws -> (request: URLRequest, applied: Bool) {
        guard let url = request.url,
              let gatewayHeaders = try await headers(for: url, forceRefresh: forceRefresh) else {
            return (request, false)
        }
        return (FnConnectGatewayProtocol.applyingHeaders(gatewayHeaders, to: request), true)
    }

    /// Called when the gateway rejects a request with an FN Connect 403 HTML
    /// page or login redirect. Drops the expired `entry-token` (while retaining
    /// `longToken` + HMAC secret for silent refresh) and refreshes once.
    public func refreshRequestAfterRejection(
        _ request: URLRequest,
        rejection: FnConnectGatewayRejection
    ) async throws -> URLRequest? {
        guard let url = request.url,
              let address = FnConnectGatewayAddress.interceptedAddress(for: url),
              let credential = resolveCredential(for: address) else {
            return nil
        }
        if rejection == .accessCodeRequired && credential.accessCode?.isEmpty != false {
            throw FnConnectGatewayError.accessCodeRequired
        }
        let key = SessionKey(fnID: credential.fnID, username: credential.username)
        if var existing = sessions[key] {
            existing.entryToken = ""
            sessions[key] = existing
        }
        failureBackoffs.removeValue(forKey: key)
        guard let refreshedHeaders = try await headers(for: url, forceRefresh: true) else {
            return nil
        }
        return FnConnectGatewayProtocol.applyingHeaders(refreshedHeaders, to: request)
    }

    public func invalidate(fnID: String, username: String? = nil, clearPersisted: Bool = false) {
        let normalizedFNID = fnID.lowercased()
        let normalizedUser = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for key in Array(sessions.keys) where key.fnID == normalizedFNID {
            if let normalizedUser, key.username != normalizedUser { continue }
            sessions.removeValue(forKey: key)
            inFlightAuth.removeValue(forKey: key)?.cancel()
            failureBackoffs.removeValue(forKey: key)
            if clearPersisted {
                sessionRemover?(key.fnID, key.username)
            }
        }
        if let normalizedUser, clearPersisted {
            sessionRemover?(normalizedFNID, normalizedUser)
        }
    }

    public func invalidateAll(clearPersisted: Bool = false) {
        let keys = Array(sessions.keys)
        sessions.removeAll()
        for (_, task) in inFlightAuth { task.cancel() }
        inFlightAuth.removeAll()
        failureBackoffs.removeAll()
        for (_, record) in pendingChallenges { record.prepared.socket.close() }
        pendingChallenges.removeAll()
        if clearPersisted {
            for key in keys { sessionRemover?(key.fnID, key.username) }
        }
    }

    // MARK: - Private

    private func resolveCredential(for address: FnConnectGatewayAddress) -> FnConnectGatewayCredential? {
        if let override = FnConnectGatewayContext.overrideCredential,
           override.fnID.lowercased() == address.fnID.lowercased() {
            return override
        }
        return credentialResolver?(
            address.gatewayHost,
            address.fnID,
            address.host,
            FnConnectGatewayContext.sourceID
        )
    }

    private func cachedSession(
        for key: SessionKey,
        gatewayHost: String
    ) -> FnConnectGatewayPersistedSession? {
        if let mem = sessions[key], !mem.entryToken.isEmpty, mem.gatewayHost == gatewayHost {
            return mem
        }
        if let loaded = sessionLoader?(key.fnID, key.username),
           !loaded.entryToken.isEmpty,
           loaded.gatewayHost == gatewayHost {
            sessions[key] = loaded
            return loaded
        }
        return nil
    }

    private func authenticateLocked(
        gatewayHost: String,
        credential: FnConnectGatewayCredential,
        forceRefresh: Bool,
        interactive: Bool
    ) async throws -> FnConnectGatewayPersistedSession {
        let key = SessionKey(fnID: credential.fnID, username: credential.username)

        if !forceRefresh, let cached = cachedSession(for: key, gatewayHost: gatewayHost) {
            return cached
        }
        if let existingTask = inFlightAuth[key] {
            return try await existingTask.value
        }

        let existingSession = sessions[key] ?? sessionLoader?(key.fnID, key.username)
        let deviceID = existingSession?.deviceID ?? deviceIDProvider()
        let client = self.client

        let task = Task<FnConnectGatewayPersistedSession, Error> {
            // 1. Try silent refresh via longToken + HMAC first when available.
            if let existingSession,
               !existingSession.longToken.isEmpty,
               !existingSession.secretBase64.isEmpty {
                do {
                    return try await client.refreshWithLongToken(
                        gatewayHost: gatewayHost,
                        fnID: credential.fnID,
                        session: existingSession,
                        accessCode: credential.accessCode
                    )
                } catch FnConnectGatewayError.ipBanned {
                    throw FnConnectGatewayError.ipBanned
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Long token expired or rotated — fall through to full login.
                }
            }

            // 2. Full RSA/AES WebSocket login.
            let outcome = try await client.login(
                gatewayHost: gatewayHost,
                fnID: credential.fnID,
                credential: credential,
                deviceID: deviceID
            )
            switch outcome {
            case .authenticated(let session):
                return session
            case .twoFactorRequired(let challenge, let prepared):
                if interactive {
                    self.storePendingChallenge(challenge, prepared: prepared)
                } else {
                    prepared.socket.close()
                }
                throw FnConnectGatewayError.twoFactorRequired(challenge)
            }
        }

        inFlightAuth[key] = task
        defer { inFlightAuth.removeValue(forKey: key) }

        do {
            let session = try await task.value
            failureBackoffs.removeValue(forKey: key)
            sessions[key] = session
            sessionSaver?(session)
            return session
        } catch let gatewayError as FnConnectGatewayError {
            if !interactive && gatewayError.shouldBackOffAutomaticRetries {
                failureBackoffs[key] = FailureBackoff(
                    error: gatewayError,
                    until: now().addingTimeInterval(Self.automaticFailureBackoffInterval)
                )
            }
            throw gatewayError
        }
    }

    private func storePendingChallenge(
        _ challenge: FnConnectTwoFactorChallenge,
        prepared: FnConnectGatewayClient.PreparedTwoFactorSocket
    ) {
        pruneExpiredChallenges()
        pendingChallenges[challenge.id] = PendingChallengeRecord(
            challenge: challenge,
            prepared: prepared,
            createdAt: now()
        )
    }

    private func pruneExpiredChallenges() {
        let cutoff = now().addingTimeInterval(-Self.challengeLifetime)
        for (id, record) in pendingChallenges where record.createdAt < cutoff {
            record.prepared.socket.close()
            pendingChallenges.removeValue(forKey: id)
        }
    }
}
