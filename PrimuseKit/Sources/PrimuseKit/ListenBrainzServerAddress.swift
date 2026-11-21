import Foundation

/// ListenBrainz 兼容服务的 API 根地址。路径可区分同一主机上的不同实例。
public enum ListenBrainzServerAddress {
    public static let officialURL = URL(string: "https://api.listenbrainz.org")!
    public static let keychainAccount = "scrobble.listenBrainz.serverURL" // 旧版独立地址项

    public enum ParseResult: Equatable, Sendable {
        /// 留空,或填的就是官方地址。
        case official
        case custom(URL)
        case invalid
    }

    private static let officialHosts: Set<String> = [
        "api.listenbrainz.org", "listenbrainz.org", "www.listenbrainz.org",
    ]

    /// 接口路径接在根地址后面,用户常把整条接口地址贴进来,只留根地址。
    private static let endpointSuffixes = ["/1/submit-listens", "/1/validate-token", "/1"]

    /// 用户填的文字 → 接口根地址。没写协议的按 https 补上;查询串与锚点不要。
    public static func parse(_ input: String) -> ParseResult {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .official }
        if !text.contains("://") { text = "https://" + text }
        return normalized(text, stripEndpoint: true)
    }

    fileprivate static func normalized(_ text: String, stripEndpoint: Bool) -> ParseResult {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              !host.contains(" ") else {
            return .invalid
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if stripEndpoint, let suffix = endpointSuffixes.first(where: { path.lowercased().hasSuffix($0) }) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        if path.isEmpty, officialHosts.contains(host), scheme == "https", components.port == nil {
            return .official
        }
        guard let url = components.url else { return .invalid }
        return .custom(url)
    }

    /// 钥匙串里存的文字 → 实际请求的根地址。存进去的都是 `parse` 归一过的,这里只防损坏的值。
    public static func resolvedURL(stored: String) -> URL? {
        switch parse(stored) {
        case .official: return officialURL
        case .custom(let url): return url
        case .invalid: return nil
        }
    }
}

/// A single Keychain and transfer value keeps the credential paired with its destination.
public struct ListenBrainzCredentials: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    public init?(baseURL: URL, token: String) {
        switch ListenBrainzServerAddress.normalized(baseURL.absoluteString, stripEndpoint: false) {
        case .official: self.baseURL = ListenBrainzServerAddress.officialURL
        case .custom(let url): self.baseURL = url
        case .invalid: return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.token = trimmed
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try fields.decode(URL.self, forKey: .baseURL)
        let token = try fields.decode(String.self, forKey: .token)
        guard let credentials = Self(baseURL: baseURL, token: token) else {
            throw DecodingError.dataCorruptedError(forKey: .baseURL, in: fields, debugDescription: "Invalid ListenBrainz configuration")
        }
        self = credentials
    }
}

/// A saved or edited token is only shown for the API root it belongs to.
public struct ListenBrainzConnectionDraft: Equatable {
    private let savedBaseURL: URL
    private let savedToken: String
    public var serverText: String
    private var editedToken: String?
    private var editedTokenBaseURL: URL?

    public init(baseURL: URL = ListenBrainzServerAddress.officialURL, token: String = "") {
        savedBaseURL = baseURL
        savedToken = token
        serverText = baseURL == ListenBrainzServerAddress.officialURL ? "" : baseURL.absoluteString
    }

    public var baseURL: URL? {
        if serverText == savedBaseURL.absoluteString { return savedBaseURL }
        return ListenBrainzServerAddress.resolvedURL(stored: serverText)
    }

    public var token: String {
        get {
            guard let baseURL else { return "" }
            if editedTokenBaseURL == baseURL, let editedToken { return editedToken }
            return savedBaseURL == baseURL ? savedToken : ""
        }
        set {
            editedTokenBaseURL = baseURL
            editedToken = newValue
        }
    }

    public var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var matchesSavedCredentials: Bool {
        baseURL == savedBaseURL && !savedToken.isEmpty && trimmedToken == savedToken
    }

    public var canSave: Bool {
        guard let baseURL else { return false }
        return !trimmedToken.isEmpty || (baseURL == savedBaseURL && !savedToken.isEmpty)
    }
}
