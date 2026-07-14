import CryptoKit
import Foundation

/// S3 / S3 兼容(MinIO 等)的流式解析 —— 生成 SigV4 **预签名 GET URL**(鉴权放 query,
/// AVPlayer 可直接播;iOS 端用的是 Authorization 头签名,不适合直接喂给 AVPlayer)。
///
/// 字段映射(同 iOS S3Source):host=endpoint、basePath=bucket、extraConfig JSON 的
/// `region`、username=accessKey、password(凭据)=secretKey。采用 path-style:
/// `scheme://endpoint/bucket/key`。
public struct S3StreamResolver: StreamResolver {
    static let service = "s3"
    static let presignExpires = 3600   // 预签名有效期(秒)

    public init() {}

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let accessKey = credential?.username ?? source.username ?? ""
        guard let secretKey = credential?.password, !secretKey.isEmpty, !accessKey.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        let endpoint = (source.host ?? "s3.amazonaws.com").trimmingCharacters(in: .whitespaces)
        let bucket = (source.basePath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let region = Self.region(from: source.extraConfig)
        let key = song.filePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !bucket.isEmpty, !key.isEmpty else { throw StreamResolveError.cannotBuildURL }

        let scheme = source.useSsl ? "https" : "http"
        let host = Self.host(from: endpoint, port: source.port, scheme: scheme)
        let canonicalURI = "/\(bucket)/\(key)"
        let (amzDate, dateStamp) = Self.timestamps(Date())

        guard let url = Self.presignedURL(method: "GET", scheme: scheme, host: host,
                                          canonicalURI: canonicalURI, accessKey: accessKey,
                                          secretKey: secretKey, region: region, service: Self.service,
                                          amzDate: amzDate, dateStamp: dateStamp, expires: Self.presignExpires) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    // MARK: - SigV4 预签名(纯函数,可单测)

    /// 生成 SigV4 预签名 URL。amzDate/dateStamp 注入以便测试对齐 AWS 官方向量。
    static func presignedURL(method: String, scheme: String, host: String, canonicalURI: String,
                             accessKey: String, secretKey: String, region: String, service: String,
                             amzDate: String, dateStamp: String, expires: Int) -> URL? {
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        // 待签名 query(不含 X-Amz-Signature),按名字典序。
        let params: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKey)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQuery = params
            .map { (uriEncode($0.0, encodeSlash: true), uriEncode($0.1, encodeSlash: true)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let canonicalRequest = [
            method,
            uriEncode(canonicalURI, encodeSlash: false),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let kDate = hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = hmac(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return URL(string: "\(scheme)://\(host)\(uriEncode(canonicalURI, encodeSlash: false))?\(canonicalQuery)&X-Amz-Signature=\(signature)")
    }

    static func region(from extraConfig: String?) -> String {
        guard let data = extraConfig?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let region = json["region"] as? String, !region.isEmpty else {
            return "us-east-1"
        }
        return region
    }

    /// 取 canonical host[:port]，去掉可能带的 scheme 与路径；若 endpoint
    /// 本身没有端口，则采用来源表单单独保存的端口。
    static func host(from endpoint: String, port: Int? = nil, scheme: String = "https") -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.contains("://")
        let candidateHost: String
        if !hasScheme,
           trimmed.filter({ $0 == ":" }).count > 1,
           !trimmed.hasPrefix("[") {
            candidateHost = "[\(trimmed)]"
        } else {
            candidateHost = trimmed
        }
        let candidate = hasScheme ? trimmed : "\(scheme)://\(candidateHost)"

        if let components = URLComponents(string: candidate),
           let parsedHost = components.host,
           !parsedHost.isEmpty {
            let hostPart = parsedHost.contains(":") && !parsedHost.hasPrefix("[")
                ? "[\(parsedHost)]"
                : parsedHost
            if let effectivePort = components.port ?? port {
                let defaultPort = scheme.lowercased() == "https" ? 443 : 80
                if effectivePort != defaultPort {
                    return "\(hostPart):\(effectivePort)"
                }
            }
            return hostPart
        }

        var fallback = trimmed
        if let range = fallback.range(of: "://") { fallback = String(fallback[range.upperBound...]) }
        if let slash = fallback.firstIndex(of: "/") { fallback = String(fallback[..<slash]) }
        return fallback
    }

    static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = f.string(from: date)
        f.dateFormat = "yyyyMMdd"
        let dateStamp = f.string(from: date)
        return (amzDate, dateStamp)
    }

    /// AWS 风格 URI 编码:只保留 unreserved 字符,其余 %XX;encodeSlash 决定 `/` 是否编码。
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var result = ""
        for byte in Array(string.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,  // A-Z a-z 0-9
                 0x2D, 0x2E, 0x5F, 0x7E:                 // - . _ ~
                result.unicodeScalars.append(UnicodeScalar(byte))
            case 0x2F where !encodeSlash:                // /
                result.append("/")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
