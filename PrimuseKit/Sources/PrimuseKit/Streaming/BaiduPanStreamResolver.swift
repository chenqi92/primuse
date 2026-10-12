import Foundation

/// 百度网盘流式解析(逻辑 mirror iOS BaiduPanSource)。
///
/// 三步:① list 父目录按文件名找 `fs_id` ② filemetas 取 dlink ③ HEAD `dlink&access_token`
/// (UA=pan.baidu.com,不自动跳转)读 302 Location 得 CDN 直链。播放需带 UA/Referer
/// (走 resource loader)。song.filePath = 百度网盘完整路径。
public actor BaiduPanStreamResolver: StreamResolver {
    static let apiBase = "https://pan.baidu.com"
    static let userAgent = "pan.baidu.com"
    static let referer = "https://pan.baidu.com/"
    static let pageSize = 1000

    private var accessTokens: [String: String] = [:]
    private var accessTokenTasks: [String: (id: UUID, forceRefresh: Bool, task: Task<String, Error>)] = [:]
    private let session: URLSession
    private let requests: CloudResolverRequests
    private let noRedirectSession: URLSession

    public init(session: URLSession? = nil, quotaRegistry: RequestQuotaRegistry = .shared) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: cfg)
        self.requests = CloudResolverRequests(registry: quotaRegistry)
        self.noRedirectSession = URLSession(configuration: session?.configuration ?? cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func invalidateSession(sourceID: String) async {
        accessTokens[sourceID] = nil
        accessTokenTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        // 百度播放需 UA,不能直连;由 resolve 提供带头的结果。
        try await resolve(for: song, source: source, credential: credential).url
    }

    public func resolve(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> ResolvedStream {
        let cred = credential ?? SourceCredential()
        return try await CloudResolverRequests.$account.withValue(.init(source: source, credential: cred)) {
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            let cdn = try await resolveCdnURL(path: song.filePath, token: token)
            return ResolvedStream(url: cdn, headers: ["User-Agent": Self.userAgent, "Referer": Self.referer])
        }
    }

    // MARK: 解析链

    private func resolveCdnURL(path: String, token: String) async throws -> URL {
        guard let account = CloudResolverRequests.account else { throw StreamResolveError.missingCredential }
        let dlink = try await getDlink(path: path, token: token)
        let link = BaiduLinkAttempt(dlink: dlink)
        let initialURL = try Self.authenticatedDlink(dlink, token: token)
        let attempt = CloudResolverReadAttempt()
        return try await requests.execute(url: initialURL, account: account,
            replay: .idempotent, recover: { error in
                guard let failure = error as? HTTPResponseFailure,
                      [401, 403, 410].contains(failure.statusCode), failure.retryAfter == nil,
                      !failure.isRateLimited, await attempt.claimRecovery() else { return false }
                try await self.renew(account: account, rejectedToken: await attempt.token)
                let token = try await self.accessToken(for: account.source, cred: account.credential, forceRefresh: false)
                // Refresh the expired dlink only as authentication recovery. A
                // quota/transport failure must not restart the directory chain.
                let fresh = try await self.getDlink(path: path, token: token)
                await link.replace(with: fresh)
                return true
            }, operation: {
                let token = try await self.accessToken(for: account.source, cred: account.credential, forceRefresh: false)
                await attempt.record(token: token)
                let url = try Self.authenticatedDlink(await link.dlink, token: token)
                var head = URLRequest(url: url)
                head.httpMethod = "HEAD"
                head.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                head.setValue(Self.referer, forHTTPHeaderField: "Referer")
                let (data, response) = try await self.noRedirectSession.data(for: head)
                guard let http = response as? HTTPURLResponse else { throw StreamResolveError.cannotBuildURL }
                switch http.statusCode {
                case 301, 302, 303, 307, 308:
                    guard let location = http.value(forHTTPHeaderField: "Location"),
                          let result = URL(string: location, relativeTo: url)?.absoluteURL else {
                        throw StreamResolveError.cannotBuildURL
                    }
                    return result
                case 200: return url
                default:
                    throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                        retryAfter: HTTPResponseFailure.retryDelay(from: http))
                }
            })
    }

    private static func authenticatedDlink(_ value: String, token: String) throws -> URL {
        guard var components = URLComponents(string: value) else { throw StreamResolveError.cannotBuildURL }
        let item = "access_token=" + CloudDriveStreamResolver.formEncode(token)
        components.percentEncodedQuery = components.percentEncodedQuery.map { $0 + "&" + item } ?? item
        guard let url = components.url else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    private func renew(account: CloudResolverRequests.Account, rejectedToken: String?) async throws {
        if let cached = accessTokens[account.source.id], let rejectedToken, cached != rejectedToken { return }
        _ = try await accessToken(for: account.source, cred: account.credential, forceRefresh: true)
    }

    private func getDlink(path: String, token: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = try await listEntries(in: dir, token: token)
        guard let fsId = Self.fsId(in: entries, name: name) else { throw StreamResolveError.cannotBuildURL }

        let meta = try await callAPI(base: "\(Self.apiBase)/rest/2.0/xpan/multimedia", token: token, query: [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "fsids", value: "[\(fsId)]"),
            URLQueryItem(name: "dlink", value: "1"),
        ])
        guard let dlink = Self.dlink(in: meta) else { throw StreamResolveError.cannotBuildURL }
        return dlink
    }

    private func listEntries(in dir: String, token: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var start = 0
        while true {
            let json = try await callAPI(base: "\(Self.apiBase)/rest/2.0/xpan/file", token: token, query: [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ])
            let entries = json["list"] as? [[String: Any]] ?? []
            all.append(contentsOf: entries)
            if entries.count < Self.pageSize { break }
            start += Self.pageSize
        }
        return all
    }

    /// 百度的 errno 错误可出现在 2xx 或非 2xx 响应；附加当前 access_token。
    private func callAPI(base: String, token: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard let account = CloudResolverRequests.account, let endpoint = URL(string: base) else {
            throw StreamResolveError.cannotBuildURL
        }
        let attempt = CloudResolverReadAttempt()
        let data = try await requests.execute(url: endpoint, account: account,
            replay: .idempotent, recover: { error in
                let unauthorized = CloudResolverRequests.isAuthenticationFailure(error)
                guard unauthorized, await attempt.claimRecovery() else { return false }
                try await self.renew(account: account, rejectedToken: await attempt.token)
                return true
            }, operation: {
                let token = try await self.accessToken(for: account.source, cred: account.credential, forceRefresh: false)
                await attempt.record(token: token)
                guard var comp = URLComponents(string: base) else { throw StreamResolveError.cannotBuildURL }
                comp.queryItems = query + [URLQueryItem(name: "access_token", value: token)]
                guard let url = FormSafeQueryURLBuilder.url(from: comp) else { throw StreamResolveError.cannotBuildURL }
                let (data, response) = try await self.session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw StreamResolveError.cannotBuildURL }
                // HTTP/body quota signals take precedence over authentication;
                // errno 111/-6 also occurs on non-2xx Baidu responses.
                if [429, 503].contains(http.statusCode) || (!(200...299).contains(http.statusCode) && HTTPResponseFailure.retryDelay(from: http) != nil) {
                    _ = try CloudResolverRequests.validate(data, response: http)
                }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let errno = (json?["errno"] as? NSNumber)?.intValue ?? (json?["errno"] as? String).flatMap(Int.init) ?? 0
                if errno == 31034 {
                    throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                        retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true)
                }
                if errno == 111 || errno == -6 { throw StreamResolveError.authFailed }
                _ = try CloudResolverRequests.validate(data, response: http)
                guard json != nil else { throw StreamResolveError.cannotBuildURL }
                if errno != 0 { throw StreamResolveError.badServerResponse(errno) }
                return data
            })
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func accessToken(for source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = accessTokens[source.id] { return cached }
        if forceRefresh { accessTokens[source.id] = nil }
        if let inFlight = accessTokenTasks[source.id], !forceRefresh || inFlight.forceRefresh {
            return try await CloudResolverRequests.wait(for: inFlight.task)
        }
        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            // Completion owns cleanup/cache publication, even if the initiating
            // waiter has already cancelled. A replaced task cannot clear its successor.
            defer {
                if accessTokenTasks[source.id]?.id == taskID { accessTokenTasks[source.id] = nil }
            }
            let token = try await loadAccessToken(source: source, cred: cred, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            if accessTokenTasks[source.id]?.id == taskID { accessTokens[source.id] = token }
            return token
        }
        accessTokenTasks[source.id] = (taskID, forceRefresh, task)
        return try await CloudResolverRequests.wait(for: task)
    }

    private func loadAccessToken(source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let token = cred.token, !token.isEmpty { return token }
        guard let rt = cred.refreshToken, let cid = cred.clientID else {
            throw StreamResolveError.missingCredential
        }
        var comp = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
        comp.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "client_secret", value: cred.clientSecret ?? ""),
        ]
        guard let url = FormSafeQueryURLBuilder.url(from: comp) else {
            throw StreamResolveError.cannotBuildURL
        }
        guard let account = CloudResolverRequests.account else { throw StreamResolveError.missingCredential }
        let data = try await requests.execute(url: url, account: account,replay: .never, operation: { [session] in
            let (data, response) = try await session.data(from: url)
            _ = try CloudResolverRequests.validate(data, response: response)
            return data
        })
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { throw StreamResolveError.authFailed }
        return token
    }

    // MARK: 纯函数(可单测)

    static func fsId(in entries: [[String: Any]], name: String) -> Int64? {
        guard let entry = entries.first(where: { ($0["server_filename"] as? String) == name }) else { return nil }
        if let v = entry["fs_id"] as? Int64 { return v }
        if let v = entry["fs_id"] as? Int { return Int64(v) }
        return (entry["fs_id"] as? NSNumber)?.int64Value
    }

    static func dlink(in filemetas: [String: Any]) -> String? {
        guard let list = filemetas["list"] as? [[String: Any]] else { return nil }
        return list.first?["dlink"] as? String
    }
}

private actor BaiduLinkAttempt {
    private(set) var dlink: String
    init(dlink: String) { self.dlink = dlink }
    func replace(with dlink: String) { self.dlink = dlink }
}

/// 不自动跟随重定向,以便读取 302 的 Location(百度 dlink → CDN)。
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
