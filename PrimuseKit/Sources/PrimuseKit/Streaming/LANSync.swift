import CryptoKit
import Foundation

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
    public var lyricsGz: Data?               // gzip(歌词 blob JSON)
    public var credentials: CredentialBundle?

    public init(version: Int = 1, libraryGz: Data? = nil, sourcesGz: Data? = nil,
                lyricsGz: Data? = nil, credentials: CredentialBundle? = nil) {
        self.version = version
        self.libraryGz = libraryGz
        self.sourcesGz = sourcesGz
        self.lyricsGz = lyricsGz
        self.credentials = credentials
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> LANSyncPayload? {
        try? JSONDecoder().decode(LANSyncPayload.self, from: data)
    }
}

/// 扫码配对的端点 + 一次性密钥。二维码内容形如
/// `primuse://pair?host=192.168.1.50&port=54321&k=<base64url 32B>`。
/// `key` 是 TV 每次展示二维码时新生成的 256-bit 随机密钥,既作 AES-GCM 对称密钥,
/// 也是「只有扫到这张码的人才有」的鉴权凭证 —— 解不开即拒。
public struct LANPairLink: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var key: Data        // 32 bytes

    public init(host: String, port: Int, key: Data) {
        self.host = host
        self.port = port
        self.key = key
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
        ]
        return c.url?.absoluteString ?? "primuse://pair"
    }

    /// iPhone POST 配置的目标 URL(局域网明文 HTTP,载荷已 AES-GCM 加密)。
    public var configURL: URL? { URL(string: "http://\(host):\(port)/config") }
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
