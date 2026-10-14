import Foundation

/// REST discovers the account's node once; file operations use the existing WebDAV transport.
public enum InfiniCloudAPIClient {
    public static let apiKeyInfoKey = "PrimuseInfiniCloudAPIKey"
    static let userURL = URL(string: "https://api.infini-cloud.net/v2/api/ba/user")!

    public struct Account: Sendable, Equatable {
        public let webDAVURL: URL
        public let username: String?
        public let capacity: Int64?
    }

    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case missingAPIKey, authenticationFailed, invalidResponse
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: PMString("infinicloud_missing_api_key")
            case .authenticationFailed: PMString("ext.tv.test.authFailed")
            case .invalidResponse: URLError(.badServerResponse).localizedDescription
            case .http(let status): PMString("ext.tv.playback.httpError", status)
            }
        }
    }

    public static func bundledAPIKey(bundle: Bundle = .main) -> String? {
        normalizedAPIKey(bundle.object(forInfoDictionaryKey: apiKeyInfoKey) as? String)
    }

    static func normalizedAPIKey(_ value: String?) -> String? {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.utf8.count == 32,
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return key
    }

    public static func needsDiscovery(source: MusicSource?, username: String, hasNewPassword: Bool) -> Bool {
        guard let source, source.type == .infiniCloud,
              source.username == username.trimmingCharacters(in: .whitespacesAndNewlines),
              !hasNewPassword, source.useSsl else { return true }
        var components = URLComponents()
        components.scheme = "https"
        components.host = source.host
        components.port = source.port
        components.path = source.basePath ?? ""
        guard let url = components.url else { return true }
        return validWebDAVURL(url) == nil
    }

    public static func fetchAccount(
        username: String,
        password: String,
        apiKey: String? = bundledAPIKey(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) async throws -> Account {
        let request = try userRequest(username: username, password: password, apiKey: apiKey)
        // Neither the app key nor Basic credentials may follow a redirect to another server.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: sessionConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request, session: session, maximumBytes: 1_048_576
        )
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return try account(from: data, statusCode: http.statusCode)
    }

    static func userRequest(username: String, password: String, apiKey: String?) throws -> URLRequest {
        guard let key = normalizedAPIKey(apiKey) else { throw Failure.missingAPIKey }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !username.contains(":"), !password.isEmpty else {
            throw Failure.authenticationFailed
        }
        var request = URLRequest(url: userURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-InfiniCLOUD-API-KEY")
        request.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("Primuse/\(version) (com.welape.yuanyin; Apple platforms)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func account(from data: Data, statusCode: Int) throws -> Account {
        if statusCode == 401 { throw Failure.authenticationFailed }
        guard (200...299).contains(statusCode) else { throw Failure.http(statusCode) }
        struct Response: Decodable {
            let result: Int
            let webdav_url: String?
            let user: String?
            let capacity: Int64?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.result == 0,
              let rawURL = response.webdav_url, let url = URL(string: rawURL),
              let webDAVURL = validWebDAVURL(url) else { throw Failure.invalidResponse }
        return Account(webDAVURL: webDAVURL, username: response.user, capacity: response.capacity)
    }

    private static func validWebDAVURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host?.lowercased(),
              host.hasSuffix(".infini-cloud.net") || host.hasSuffix(".teracloud.jp"),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/dav" || components.path == "/dav/" else { return nil }
        return url
    }
}
