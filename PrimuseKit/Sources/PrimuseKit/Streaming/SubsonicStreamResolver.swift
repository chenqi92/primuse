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
        return FormSafeQueryURLBuilder.url(from: comp)
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

public enum SubsonicLyricsReadResult: Equatable, Sendable {
    case content(String)
    case absent
    case unavailable
}

/// Lightweight Subsonic lyrics reader shared by clients that only need the
/// protocol document and should not depend on the full library connector.
public struct SubsonicLyricsClient: @unchecked Sendable {
    private struct RequestContext: Sendable {
        let baseURL: URL
        let username: String
        let password: String
        let salt: String
        let token: String
        let apiVersion: String
        var usesEncodedPassword: Bool

        var authQueryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "u", value: username)]
            if usesEncodedPassword {
                items.append(URLQueryItem(
                    name: "p",
                    value: "enc:\(SubsonicStreamResolver.hexEncoded(password))"
                ))
            } else {
                items.append(URLQueryItem(name: "t", value: token))
                items.append(URLQueryItem(name: "s", value: salt))
            }
            items.append(URLQueryItem(name: "v", value: apiVersion))
            items.append(URLQueryItem(name: "c", value: SubsonicStreamResolver.clientName))
            items.append(URLQueryItem(name: "f", value: "json"))
            return items
        }
    }

    private enum RequestError: Error {
        case invalidURL
        case httpStatus(Int)
        case server(Int)
    }

    private struct APIError: Decodable {
        let code: Int
        let message: String?
    }

    private protocol ResponsePayload: Decodable {
        var status: String { get }
        var error: APIError? { get }
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let response: Payload

        enum CodingKeys: String, CodingKey {
            case response = "subsonic-response"
        }
    }

    private struct PingPayload: ResponsePayload {
        let status: String
        let error: APIError?
        let type: String?
        let openSubsonic: Bool?
    }

    private struct LyricsPayload: ResponsePayload {
        let status: String
        let error: APIError?
        let lyricsList: LyricsList?
    }

    private struct LyricsList: Decodable {
        let structuredLyrics: [OpenSubsonicLyricsConverter.Track]?
    }

    private struct SongPayload: ResponsePayload {
        let status: String
        let error: APIError?
        let song: SongIdentity?
    }

    private struct SongIdentity: Decodable {
        let title: String?
        let artist: String?
        let displayArtist: String?
    }

    private struct LegacyLyricsPayload: ResponsePayload {
        let status: String
        let error: APIError?
        let lyrics: LegacyLyrics?
    }

    private struct LegacyLyrics: Decodable {
        let value: String?
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func readLyrics(
        forSongPath path: String,
        source: MusicSource,
        credential: SourceCredential?
    ) async -> SubsonicLyricsReadResult {
        guard source.type.isSubsonicFamily,
              let password = credential?.password,
              !password.isEmpty else {
            return .unavailable
        }
        let username = credential?.username.flatMap { $0.isEmpty ? nil : $0 }
            ?? source.username
            ?? ""
        guard !username.isEmpty,
              let baseURL = SubsonicStreamResolver.makeBaseURL(
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath
              ),
              let songID = SubsonicStreamResolver.songID(from: path) else {
            return .unavailable
        }

        let salt = SubsonicStreamResolver.randomSalt()
        var context = RequestContext(
            baseURL: baseURL,
            username: username,
            password: password,
            salt: salt,
            token: SubsonicStreamResolver.md5Hex(password + salt),
            apiVersion: source.type == .airsonic
                ? SubsonicStreamResolver.airsonicAPIVersion
                : SubsonicStreamResolver.apiVersion,
            usesEncodedPassword: source.type == .airsonic || source.type == .subsonic
        )

        do {
            let ping: PingPayload
            do {
                ping = try await request("ping", context: context)
            } catch let error as RequestError {
                guard case .server(let code) = error,
                      SubsonicResponseCompatibility.shouldRetryWithEncodedPassword(
                        errorCode: code,
                        alreadyUsingEncodedPassword: context.usesEncodedPassword
                      ) else {
                    throw error
                }
                context.usesEncodedPassword = true
                ping = try await request("ping", context: context)
            }

            let text: String?
            if ping.openSubsonic == true {
                text = try await modernLyrics(songID: songID, context: context)
            } else {
                text = try await legacyLyrics(songID: songID, context: context)
            }
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .absent
            }
            return .content(text)
        } catch {
            return .unavailable
        }
    }

    private func modernLyrics(songID: String, context: RequestContext) async throws -> String? {
        let payload: LyricsPayload
        do {
            payload = try await request(
                "getLyricsBySongId",
                query: [
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "enhanced", value: "true"),
                ],
                context: context
            )
        } catch {
            try Task.checkCancellation()
            payload = try await request(
                "getLyricsBySongId",
                query: [URLQueryItem(name: "id", value: songID)],
                context: context
            )
        }
        guard let tracks = payload.lyricsList?.structuredLyrics else { return nil }
        return OpenSubsonicLyricsConverter.text(from: tracks)
    }

    private func legacyLyrics(songID: String, context: RequestContext) async throws -> String? {
        let song: SongPayload = try await request(
            "getSong",
            query: [URLQueryItem(name: "id", value: songID)],
            context: context
        )
        guard let title = cleaned(song.song?.title) else { return nil }
        var query = [URLQueryItem(name: "title", value: title)]
        if let artist = cleaned(song.song?.artist) ?? cleaned(song.song?.displayArtist) {
            query.append(URLQueryItem(name: "artist", value: artist))
        }
        let lyrics: LegacyLyricsPayload = try await request(
            "getLyrics",
            query: query,
            context: context
        )
        return cleaned(lyrics.lyrics?.value)
    }

    private func request<Payload: ResponsePayload>(
        _ method: String,
        query: [URLQueryItem] = [],
        context: RequestContext
    ) async throws -> Payload {
        guard let url = requestURL(method, query: query, context: context) else {
            throw RequestError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            maximumBytes: 4 * 1_024 * 1_024
        )
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw RequestError.httpStatus(response.statusCode)
        }
        let normalized = try SubsonicResponseCompatibility.normalizedJSONData(data)
        let payload = try JSONDecoder().decode(Envelope<Payload>.self, from: normalized).response
        guard payload.status.caseInsensitiveCompare("ok") == .orderedSame else {
            throw RequestError.server(payload.error?.code ?? -1)
        }
        return payload
    }

    private func requestURL(
        _ method: String,
        query: [URLQueryItem],
        context: RequestContext
    ) -> URL? {
        var url = context.baseURL
        url.appendPathComponent("rest")
        url.appendPathComponent("\(method).view")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = context.authQueryItems + query
        return FormSafeQueryURLBuilder.url(from: components)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
