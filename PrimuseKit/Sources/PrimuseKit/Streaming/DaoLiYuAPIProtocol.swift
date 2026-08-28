import Foundation

/// 道理鱼 vNext 原生 API 的共享 URL/引用约定。
///
/// 曲目在 Primuse 中使用不含服务器文件路径的合成引用，播放时始终回到
/// `/api/tracks/{id}/stream` 并附带 Bearer token。
public enum DaoLiYuAPIProtocol {
    public static let apiPath = "/api"

    public static func serverBaseURL(
        host rawHost: String,
        port: Int?,
        useSSL: Bool,
        basePath: String? = nil
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let defaultScheme = useSSL ? "https" : "http"
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if isIPv6Literal(trimmed) {
            let literal = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            candidate = "\(defaultScheme)://[\(literal)]"
        } else {
            candidate = "\(defaultScheme)://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              components.host?.isEmpty == false else { return nil }
        if components.scheme?.isEmpty != false { components.scheme = defaultScheme }
        if components.port == nil, let port, port > 0 { components.port = port }
        if components.path.isEmpty || components.path == "/" {
            components.path = normalizedPrefix(basePath ?? "")
        } else {
            components.path = normalizedPrefix(components.path)
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func endpointURL(
        serverBaseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var prefix = normalizedPrefix(components.path)
        if !prefix.hasSuffix(apiPath) { prefix += apiPath }
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = endpoint.isEmpty ? prefix : "\(prefix)/\(endpoint)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        return FormSafeQueryURLBuilder.url(from: components)
    }

    public static func streamURL(serverBaseURL: URL, trackID: String) -> URL? {
        endpointURL(
            serverBaseURL: serverBaseURL,
            path: "/tracks/\(encodedPathComponent(trackID))/stream"
        )
    }

    public static func trackPath(id: String, fileExtension: String) -> String {
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "/daoliyu/tracks/\(encodedPathComponent(id)).\(suffix.isEmpty ? "bin" : suffix.lowercased())"
    }

    public static func trackID(from path: String) -> String? {
        guard path.hasPrefix("/daoliyu/tracks/") else { return nil }
        let name = (path as NSString).lastPathComponent
        let value = (name as NSString).deletingPathExtension
        guard !value.isEmpty else { return nil }
        return value.removingPercentEncoding ?? value
    }

    /// 将服务端的封面字段变为可跨 iOS/macOS/tvOS 直接加载的绝对 URL。
    /// 绝对 URL 和 `/api/...` 路径原样保留语义；本地文件路径经公开 cover 路由转换。
    public static func coverURL(serverBaseURL: URL, reference: String?) -> URL? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { return nil }
        if let absolute = URL(string: reference), absolute.scheme != nil { return absolute }

        if reference.hasPrefix("/api/") || reference == "/api" {
            guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            let basePrefix = normalizedPrefix(components.path)
            components.path = "\(basePrefix)\(reference)"
            components.query = nil
            components.fragment = nil
            return components.url
        }

        return endpointURL(
            serverBaseURL: serverBaseURL,
            path: "/cover",
            queryItems: [URLQueryItem(name: "path", value: reference)]
        )
    }

    private static func normalizedPrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/\(trimmed)"
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return candidate.contains(":") && !candidate.contains("/")
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
