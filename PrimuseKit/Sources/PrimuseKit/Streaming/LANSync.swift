import CryptoKit
import Foundation

/// Completion semantics for transfers that promise both a library snapshot and
/// its credential snapshot. A disabled iCloud credential channel is an explicit
/// skip, while LAN pairing always requires a successfully prepared bundle.
public enum SnapshotCredentialTransferOutcome: Sendable, Equatable {
    case skipped
    case succeeded
    case failed
}

public enum SnapshotTransferCompletionPolicy {
    public static func iCloudSucceeded(
        snapshotUploaded: Bool,
        credentialOutcome: SnapshotCredentialTransferOutcome
    ) -> Bool {
        snapshotUploaded && credentialOutcome != .failed
    }

    public static func canSendLAN(
        hasLibrarySnapshot: Bool,
        credentialOutcome: SnapshotCredentialTransferOutcome
    ) -> Bool {
        hasLibrarySnapshot && credentialOutcome == .succeeded
    }
}

/// A user-visible Apple TV transfer failure. The case identifies the failed
/// stage while `diagnosticCode` gives support a stable value that can be copied
/// from screenshots regardless of the device language.
public enum AppleTVTransferFailure: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case cloudUnavailable
    case snapshotMissing
    case snapshotPreparationFailed
    case cloudConflict
    case cloudUploadFailed(detail: String)
    case sourceDataUnavailable(detail: String)
    case credentialReadFailed(
        sourceName: String,
        component: String,
        status: Int32,
        temporary: Bool
    )
    case credentialUploadFailed(detail: String)
    case invalidPairingLink
    case payloadEncodingFailed(detail: String)
    case payloadEncryptionFailed
    case localNetworkFailed(detail: String)
    case invalidTVResponse
    case tvRejected(statusCode: Int)

    public var diagnosticCode: String {
        switch self {
        case .cancelled: return "TV-CANCELLED"
        case .cloudUnavailable: return "TV-ICLOUD-UNAVAILABLE"
        case .snapshotMissing: return "TV-SNAPSHOT-MISSING"
        case .snapshotPreparationFailed: return "TV-SNAPSHOT-PREPARE"
        case .cloudConflict: return "TV-ICLOUD-CONFLICT"
        case .cloudUploadFailed: return "TV-ICLOUD-UPLOAD"
        case .sourceDataUnavailable: return "TV-SOURCES-READ"
        case .credentialReadFailed: return "TV-CREDENTIAL-READ"
        case .credentialUploadFailed: return "TV-CREDENTIAL-UPLOAD"
        case .invalidPairingLink: return "TV-PAIRING-LINK"
        case .payloadEncodingFailed: return "TV-PAYLOAD-ENCODE"
        case .payloadEncryptionFailed: return "TV-PAYLOAD-ENCRYPT"
        case .localNetworkFailed: return "TV-LAN-CONNECTION"
        case .invalidTVResponse: return "TV-LAN-RESPONSE"
        case .tvRejected(let statusCode): return "TV-HTTP-\(statusCode)"
        }
    }

    public var errorDescription: String? { userFacingMessage }

    public var userFacingMessage: String {
        switch self {
        case .cancelled:
            return PMString("send_to_tv_error_cancelled")
        case .cloudUnavailable:
            return PMString("send_to_tv_error_cloud_unavailable")
        case .snapshotMissing:
            return PMString("send_to_tv_error_snapshot_missing")
        case .snapshotPreparationFailed:
            return PMString("send_to_tv_error_snapshot_preparation")
        case .cloudConflict:
            return PMString("send_to_tv_error_cloud_conflict")
        case .cloudUploadFailed(let detail):
            return PMString("send_to_tv_error_cloud_upload", detail)
        case .sourceDataUnavailable(let detail):
            return PMString("send_to_tv_error_source_data", detail)
        case let .credentialReadFailed(sourceName, component, status, temporary):
            return PMString(
                temporary
                    ? "send_to_tv_error_credential_temporary"
                    : "send_to_tv_error_credential_read",
                sourceName,
                component,
                String(status)
            )
        case .credentialUploadFailed(let detail):
            return PMString("send_to_tv_error_credential_upload", detail)
        case .invalidPairingLink:
            return PMString("send_to_tv_error_pairing_link")
        case .payloadEncodingFailed(let detail):
            return PMString("send_to_tv_error_payload_encoding", detail)
        case .payloadEncryptionFailed:
            return PMString("send_to_tv_error_payload_encryption")
        case .localNetworkFailed(let detail):
            return PMString("send_to_tv_error_local_network", detail)
        case .invalidTVResponse:
            return PMString("send_to_tv_error_invalid_response")
        case .tvRejected(let statusCode):
            switch statusCode {
            case 400:
                return PMString("send_to_tv_error_tv_bad_request")
            case 403:
                return PMString("send_to_tv_error_tv_forbidden")
            case 500:
                return PMString("send_to_tv_error_tv_persistence")
            case 503:
                return PMString("send_to_tv_error_tv_not_ready")
            default:
                return PMString("send_to_tv_error_tv_status", String(statusCode))
            }
        }
    }
}

/// 局域网「扫码直传」的载荷:与 CloudKit 快照同构的整库 + 源 + 歌词 + 凭据,经
/// AES-GCM 加密后由 iPhone 直接 POST 给 Apple TV。绕开 iCloud —— 不受 Apple ID /
/// 区域 / Development·Production 环境隔离,只要两台设备在同一局域网即可。
///
/// 各 `*Gz` 字段是 gzip(zlib) 压缩后的 JSON,与 `LibrarySnapshotSync` 上传 CloudKit
/// 用的 `libraryGz`/`sourcesGz`/`lyricsGz` 是同一份字节,TV 端落盘逻辑也共用。
public struct LANSyncPayload: Codable, Sendable {
    public var version: Int
    public var libraryGz: Data?              // gzip(library-cache.json)
    public var sourcesGz: Data?              // gzip(sources.json)
    public var radioStationsGz: Data?        // gzip(radio-stations.json)
    public var lyricsGz: Data?               // gzip(歌词 blob JSON)
    public var credentials: CredentialBundle?

    public init(version: Int = 2, libraryGz: Data? = nil, sourcesGz: Data? = nil,
                radioStationsGz: Data? = nil, lyricsGz: Data? = nil,
                credentials: CredentialBundle? = nil) {
        self.version = version
        self.libraryGz = libraryGz
        self.sourcesGz = sourcesGz
        self.radioStationsGz = radioStationsGz
        self.lyricsGz = lyricsGz
        self.credentials = credentials
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }

    /// Optional fields remain decodable for compatibility with older payloads,
    /// but a new transfer is complete only when it carries both the library and
    /// the prepared credential bundle promised by LAN pairing.
    public var isCompleteForTransfer: Bool {
        SnapshotTransferCompletionPolicy.canSendLAN(
            hasLibrarySnapshot: libraryGz?.isEmpty == false,
            credentialOutcome: credentials == nil ? .failed : .succeeded
        )
    }

    public static func decode(_ data: Data) -> LANSyncPayload? {
        try? JSONDecoder().decode(LANSyncPayload.self, from: data)
    }
}

/// 扫码配对的端点 + 一次性密钥。二维码内容形如
/// `primuse://pair?host=192.168.1.50&port=54321&k=<base64url 32B>&code=123456`。
/// `key` 是 TV 每次展示二维码时新生成的 256-bit 随机密钥,既作 AES-GCM 对称密钥,
/// 也是「只有扫到这张码的人才有」的鉴权凭证 —— 解不开即拒。
public struct LANPairLink: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var key: Data        // 32 bytes
    public var pairCode: String // 6 digits shown on both devices

    public init(host: String, port: Int, key: Data, pairCode: String = LANPairLink.randomPairCode()) {
        self.host = host
        self.port = port
        self.key = key
        self.pairCode = LANPairLink.normalizedPairCode(pairCode) ?? LANPairLink.randomPairCode()
    }

    /// 从扫码得到的 `primuse://pair?...` 解析。
    public init?(url: URL) {
        guard url.scheme == "primuse", url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        guard let host = q("host"), !host.isEmpty,
              let portStr = q("port"), let port = Int(portStr), port > 0,
              let k = q("k"), let key = Data(base64URLEncoded: k), key.count == 32 else { return nil }
        self.host = host
        self.port = port
        self.key = key
        self.pairCode = LANPairLink.normalizedPairCode(q("code")) ?? LANPairLink.shortCode(from: key)
    }

    /// 编码进二维码的字符串。
    public var qrContent: String {
        var c = URLComponents()
        c.scheme = "primuse"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "k", value: key.base64URLEncodedString()),
            URLQueryItem(name: "code", value: pairCode),
        ]
        return c.url?.absoluteString ?? "primuse://pair"
    }

    /// iPhone POST 配置的目标 URL(局域网明文 HTTP,载荷已 AES-GCM 加密)。
    public var configURL: URL? { URL(string: "http://\(host):\(port)/config") }

    public var displayPairCode: String {
        pairCode.count == 6
            ? "\(pairCode.prefix(3)) \(pairCode.suffix(3))"
            : pairCode
    }

    public static func randomPairCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func normalizedPairCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count == 6 else { return nil }
        return String(digits)
    }

    private static func shortCode(from key: Data) -> String {
        let digest = SHA256.hash(data: key)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06d", value)
    }
}

/// AES-GCM 封装。密钥 = 32B 均匀随机,直接作 `SymmetricKey`(无需再 HKDF 派生)。
/// `combined` 形态 = nonce‖ciphertext‖tag,自带完整性校验。
public enum LANSyncCrypto {
    public static func seal(_ plaintext: Data, key: Data) -> Data? {
        guard key.count == 32 else { return nil }
        return try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined
    }

    public static func open(_ box: Data, key: Data) -> Data? {
        guard key.count == 32, let sealed = try? AES.GCM.SealedBox(combined: box) else { return nil }
        return try? AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }

    public static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

private extension Data {
    init?(base64URLEncoded s: String) {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        guard let d = Data(base64Encoded: str) else { return nil }
        self = d
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
