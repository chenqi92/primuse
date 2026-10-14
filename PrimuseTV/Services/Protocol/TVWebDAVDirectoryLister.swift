#if os(tvOS)
import Foundation
import PrimuseKit

/// Owns directory transport so status and Retry-After reach the shared quota
/// before an HTTP failure is converted into a scanner-facing error.
actor TVWebDAVDirectoryLister: TVDirectoryLister {
    private let baseURL: URL
    private let session: URLSession
    private let authorization: String?
    private let quota: RequestQuota
    private let registry: RequestQuotaRegistry
    private let timing: RequestExecutor.Timing

    init?(source: MusicSource, credential: SourceCredential?,
          sessionConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral },
          quotaRegistry: RequestQuotaRegistry = .shared, timing: RequestExecutor.Timing = .init()) {
        guard source.type == .webdav || source.type == .infiniCloud else { return nil }
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = source.useSsl ? "https" : "http"
        components.host = host
        if let port = source.port, port > 0 { components.port = port }
        let root = TVServerPathPolicy.providerPath(base: source.basePath ?? "", path: "/")
        components.path = root.hasSuffix("/") ? root : root + "/"
        let username = credential?.username ?? ""
        let password = credential?.password ?? ""
        guard let url = components.url,
              let quota = WebDAVDirectoryRequestPolicy.quota(url: url, username: username) else { return nil }
        baseURL = url
        self.quota = quota
        registry = quotaRegistry
        self.timing = timing
        authorization = username.isEmpty && password.isEmpty ? nil
            : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let configuration = sessionConfiguration()
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration,
                             delegate: TVWebDAVSessionDelegate(baseURL: url, credential: credential),
                             delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func list(_ path: String) async throws -> [TVDirEntry] {
        try Task.checkCancellation()
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relative = RemotePathScopePolicy(rootPath: "/")
            .resolvedPath(forStoredPath: normalized.isEmpty ? "/" : normalized) else {
            throw SourceError.pathNotFound(path)
        }
        var url = baseURL
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:resourcetype/>
        <D:getcontentlength/><D:getlastmodified/><D:getetag/></D:prop></D:propfind>
        """.utf8)
        let data = try await directoryData(for: request, path: path)
        try Task.checkCancellation()
        let policy = WebDAVPathPolicy(basePath: baseURL.path)
        let entries = try WebDAVMultistatusParser.parse(data).compactMap { entry -> (WebDAVMultistatusEntry, String)? in
            guard let path = policy.sourcePath(forHref: entry.href, baseURL: baseURL) else { return nil }
            return (entry, path)
        }
        guard entries.contains(where: { $0.1 == relative }) else {
            throw SourceError.connectionFailed("WebDAV directory response did not describe the requested resource")
        }
        return entries.compactMap { entry, path -> TVDirEntry? in
            guard path != relative else { return nil }
            let fallback = (path as NSString).lastPathComponent
            let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name?.isEmpty == false ? name! : fallback
            guard !resolvedName.isEmpty, !resolvedName.hasPrefix(".") else { return nil }
            return TVDirEntry(name: resolvedName, isDir: entry.isDirectory, size: entry.contentLength ?? -1,
                              path: path, parentPath: relative, modifiedDate: WebDAVMultistatusParser.lastModifiedDate(entry.lastModified))
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func directoryData(for request: URLRequest, path: String) async throws -> Data {
        let deadline = timing.now() + quota.service.policy.timeout
        var completedWaits = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline - timing.now()
            guard remaining > 0 else { throw URLError(.timedOut) }
            let waits = completedWaits
            let session = session
            let timing = timing
            do {
                // This loop alone owns retries. The shared registry records the
                // full deadline even when it is too long for this call to wait.
                return try await registry.execute(for: quota, replay: .never, timeout: remaining, operation: {
                    let (data, response) = try await StreamResolverHTTPTransport.data(
                        for: request, session: session, maximumBytes: 16 * 1024 * 1024
                    )
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authenticationFailed }
                    if http.statusCode == 404 { throw SourceError.pathNotFound(path) }
                    guard (200...299).contains(http.statusCode) else {
                        throw WebDAVDirectoryRequestPolicy.failure(
                            statusCode: http.statusCode,
                            retryAfter: HTTPResponseFailure.retryDelay(from: http, now: timing.date()),
                            completedWaits: waits
                        )
                    }
                    return data
                })
            } catch let failure as HTTPResponseFailure {
                try Task.checkCancellation()
                guard failure.isRateLimited,
                      let delay = RemoteDirectoryRateLimitPolicy.delay(
                        completedWaits: completedWaits, retryAfter: failure.retryAfter
                      ), delay < deadline - timing.now() else {
                    throw RemoteDirectoryHTTPStatusError(service: "WebDAV", statusCode: failure.statusCode,
                                                        retryAfter: failure.retryAfter, isRateLimited: failure.isRateLimited)
                }
                completedWaits += 1
                try await timing.sleep(delay)
            }
        }
    }
}

private final class TVWebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let credential: URLCredential?

    init(baseURL: URL, credential: SourceCredential?) {
        self.baseURL = baseURL
        self.credential = credential.map { URLCredential(user: $0.username ?? "", password: $0.password ?? "", persistence: .forSession) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await disposition(for: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await disposition(for: challenge)
    }

    private func disposition(for challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return await TVServerTrust.disposition(for: challenge)
        }
        guard !space.isProxy(),
              [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod),
              let endpoint = NetworkEndpointIdentity(scheme: space.protocol ?? "https", host: space.host, port: space.port),
              let url = URL(string: endpoint.key), HTTPRedirectSecurityPolicy.allows(from: baseURL, to: url),
              challenge.previousFailureCount == 0, let credential else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.currentRequest ?? task.originalRequest else { return nil }
        return HTTPRedirectRequestPolicy.redirectedRequest(from: original, response: response)
    }
}
#endif
