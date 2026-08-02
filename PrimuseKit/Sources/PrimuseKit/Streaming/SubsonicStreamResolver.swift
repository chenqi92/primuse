import CryptoKit
import Foundation

public enum SubsonicResponseCompatibility {
    /// Some compatible servers serialize XML attributes into an `_attributes`
    /// object even when `f=json` is requested. Flatten those objects so the
    /// regular Subsonic models can decode both response shapes.
    public static func normalizedJSONData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        let normalized = normalize(object)
        return try JSONSerialization.data(withJSONObject: normalized)
    }

    public static func shouldRetryWithEncodedPassword(
        errorCode: Int,
        alreadyUsingEncodedPassword: Bool
    ) -> Bool {
        errorCode == 41 && alreadyUsingEncodedPassword == false
    }

    private static func normalize(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(normalize)
        }

        guard let dictionary = value as? [String: Any] else {
            return value
        }

        var result: [String: Any] = [:]
        if let attributes = dictionary["_attributes"] as? [String: Any] {
            for (key, attributeValue) in attributes {
                result[key] = normalize(attributeValue)
            }
        }

        for (key, childValue) in dictionary where key != "_attributes" {
            result[key] = normalize(childValue)
        }
        return result
    }
}

/// Subsonic / OpenSubsonic 家族(Subsonic / Navidrome / Airsonic / gonic)的流式解析。
///
/// stream URL 是**无状态**的:Navidrome / gonic 通常以
/// salt + token=md5(password+salt) 鉴权；通用 Subsonic 与 Airsonic 兼容模式
/// 使用协议规定的 `p=enc:<UTF-8 hex>`。参数直接拼在 query 里,
/// 没有会话、不会过期,AVPlayer 可直接播。这是从 iOS `SubsonicSource` 抽出的纯逻辑核心,
/// 不依赖任何 iOS-only 类型(`NetworkURLBuilder` / `SmartSSLDelegate` 的逻辑在此内联)。
public struct SubsonicStreamResolver: StreamResolver {
    static let apiVersion = "1.16.1"
    static let airsonicAPIVersion = "1.15.0"
    static let clientName = "Primuse"
    static let transcodeBitRate = 320   // WMA → 服务端转码 mp3 的目标码率 kbps

    public init() {}

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let username = credential?.username ?? source.username ?? ""
        guard let password = credential?.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.makeBaseURL(host: source.host ?? "", port: source.port,
                                          useSsl: source.useSsl, basePath: source.basePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        guard let songID = Self.songID(from: song.filePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        let salt = Self.randomSalt()
        let token = Self.md5Hex(password + salt)
        let apiVersion = source.type == .airsonic ? Self.airsonicAPIVersion : Self.apiVersion
        // `.subsonic` is the compatibility entry point for implementations
        // that do not advertise a dedicated Primuse source type. Some of them
        // (including DaoLiYu) reject salted-token authentication with error 41
        // while accepting the protocol-standard encoded-password form.
        let encodedPassword = source.type == .airsonic || source.type == .subsonic
            ? Self.hexEncoded(password)
            : nil
        // 本地能解的格式取原文件(format=raw);WMA 让服务端转码 mp3 渐进流。
        let transcode = song.fileFormat == .wma
        guard let url = Self.streamURL(base: base, username: username, token: token, salt: salt,
                                       songID: songID, transcode: transcode, apiVersion: apiVersion,
                                       encodedPassword: encodedPassword) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    // MARK: - 纯函数(可单测)

    /// 构造 `{base}/rest/stream.view?u=&t=&s=&v=&c=&f=json&id=&format=...`。
    /// salt 作参数注入以便测试断言固定输出。
    static func streamURL(base: URL, username: String, token: String, salt: String,
                          songID: String, transcode: Bool, bitRate: Int = transcodeBitRate,
                          apiVersion: String = apiVersion, encodedPassword: String? = nil) -> URL? {
        var url = base
        url.appendPathComponent("rest")
        url.appendPathComponent("stream.view")
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = [
            URLQueryItem(name: "u", value: username),
        ]
        if let encodedPassword {
            items.append(URLQueryItem(name: "p", value: "enc:\(encodedPassword)"))
        } else {
            items.append(URLQueryItem(name: "t", value: token))
            items.append(URLQueryItem(name: "s", value: salt))
        }
        items.append(URLQueryItem(name: "v", value: apiVersion))
        items.append(URLQueryItem(name: "c", value: clientName))
        items.append(URLQueryItem(name: "f", value: "json"))
        items.append(URLQueryItem(name: "id", value: songID))
        if transcode {
            items.append(URLQueryItem(name: "format", value: "mp3"))
            items.append(URLQueryItem(name: "maxBitRate", value: String(bitRate)))
        } else {
            items.append(URLQueryItem(name: "format", value: "raw"))
        }
        comp.queryItems = items
        return comp.url
    }

    /// host 可能已含 scheme / 端口;basePath 逐段拼到路径。返回不含 /rest 的基址。
    static func makeBaseURL(host: String, port: Int?, useSsl: Bool, basePath: String?) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let r = h.range(of: "://") {
            scheme = String(h[..<r.lowerBound]).lowercased()
            h = String(h[r.upperBound...])
        }
        // 去掉 host 上多余的路径段(只保留 host[:port])。
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var hostPort = h
        if let port, port > 0, !h.contains(":") {
            hostPort = "\(h):\(port)"
        }
        guard var url = URL(string: "\(scheme)://\(hostPort)") else { return nil }
        if let bp = basePath?.trimmingCharacters(in: .whitespacesAndNewlines), !bp.isEmpty {
            for component in bp.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }
        return url
    }

    /// 从 `/songs/{id}.{suffix}` 形式的 filePath 取回服务端 songID。
    static func songID(from filePath: String) -> String? {
        let last = (filePath as NSString).lastPathComponent
        guard !last.isEmpty else { return nil }
        let id = (last as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hexEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func randomSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
