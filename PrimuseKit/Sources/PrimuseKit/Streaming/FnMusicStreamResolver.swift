import Foundation

/// Streaming resolver dedicated to the Feiniu Music app. Authentication uses
/// the music service's `music-token` cookie; no generic fnOS filesystem
/// endpoint is used here.
public actor FnMusicStreamResolver: StreamResolver {
    private struct SessionIdentity: Hashable, Sendable {
        let server: String
        let username: String
        let passwordHash: String
        let accessCodeHash: String
        let usesRelay: Bool
    }

    private struct EndpointIdentity: Hashable, Sendable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let connectionMode: FnMusicConnectionMode
        let accessCodeHash: String
    }

    private struct EndpointCacheEntry {
        let identity: EndpointIdentity
        let provider: FnMusicEndpointProvider
    }

    private struct CachedSession: Sendable {
        let identity: SessionIdentity
        let token: String
    }

    private struct LoginOperation {
        let id: UUID
        let identity: SessionIdentity
        let task: Task<String, Error>
    }

    private var sessions: [String: CachedSession] = [:]
    private var sessionTasks: [String: LoginOperation] = [:]
    private var endpointProviders: [String: EndpointCacheEntry] = [:]
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = StreamResolverSessionFactory.make(
            configuration: cfg,
            fnMusicRedirects: true
        )
    }

    deinit { session.invalidateAndCancel() }

    public func invalidateSession(sourceID: String) {
        sessions[sourceID] = nil
        sessionTasks.removeValue(forKey: sourceID)?.task.cancel()
        endpointProviders[sourceID] = nil
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        try await resolvedTarget(for: song, source: source, credential: credential).url
    }

    public func resolve(for song: Song,
                        source: MusicSource,
                        credential: SourceCredential?) async throws -> ResolvedStream {
        let target = try await resolvedTarget(for: song, source: source, credential: credential)
        var headers: [String: String] = [:]
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: target.token,
            usesRelay: target.endpoint.usesRelay
        ) {
            headers["Cookie"] = cookie
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(target.accessCode) {
            headers[name] = value
        }
        var signedRequest = URLRequest(url: target.url)
        signedRequest.httpMethod = "GET"
        FnMusicAPIProtocol.applyAuthx(to: &signedRequest)
        headers[FnMusicAPIProtocol.authxHeaderField] = signedRequest.value(
            forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField
        )
        return ResolvedStream(url: target.url, headers: headers)
    }

    private func resolvedTarget(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> (url: URL, token: String, endpoint: FnMusicResolvedEndpoint, accessCode: String?) {
        do {
            return try await resolvedTargetOnce(for: song, source: source, credential: credential)
        } catch {
            guard source.effectiveFnMusicConnectionMode == .fnConnect,
                  FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            sessions[source.id] = nil
            sessionTasks.removeValue(forKey: source.id)?.task.cancel()
            let accessCode = credential?.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey]
            let provider = endpointProvider(for: source, accessCode: accessCode)
            await provider.invalidate()
            return try await resolvedTargetOnce(for: song, source: source, credential: credential)
        }
    }

    private func resolvedTargetOnce(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> (url: URL, token: String, endpoint: FnMusicResolvedEndpoint, accessCode: String?) {
        guard source.type == .fnMusic else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let cred = credential ?? SourceCredential()
        let username = cred.username ?? source.username ?? ""
        guard let password = cred.password, !password.isEmpty, !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        let accessCode = cred.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey]
        let provider = endpointProvider(for: source, accessCode: accessCode)
        let endpoint = try await provider.endpoint()
        let base = endpoint.baseURL
        var token = try await currentSession(
            source: source,
            base: base,
            username: username,
            password: password,
            accessCode: accessCode,
            usesRelay: endpoint.usesRelay
        )
        guard let guid = FnMusicAPIProtocol.trackGUID(from: song.filePath) else {
            throw StreamResolveError.cannotBuildURL
        }
        let url = Self.fnMusicStreamURL(base: base, trackGUID: guid)
        guard let url else { throw StreamResolveError.cannotBuildURL }
        do {
            try await validateFnMusicStream(
                url: url,
                token: token,
                accessCode: accessCode,
                usesRelay: endpoint.usesRelay
            )
        } catch StreamResolveError.authFailed {
            // Only evict the token that actually failed. Another resolve may
            // already have replaced it while this probe was suspended.
            if sessions[source.id]?.token == token {
                sessions[source.id] = nil
            }
            token = try await currentSession(
                source: source,
                base: base,
                username: username,
                password: password,
                accessCode: accessCode,
                usesRelay: endpoint.usesRelay
            )
            try await validateFnMusicStream(
                url: url,
                token: token,
                accessCode: accessCode,
                usesRelay: endpoint.usesRelay
            )
        }
        return (url, token, endpoint, accessCode)
    }

    private func currentSession(source: MusicSource, base: URL, username: String,
                                password: String, accessCode: String?,
                                usesRelay: Bool) async throws -> String {
        let identity = SessionIdentity(
            server: base.absoluteString,
            username: username,
            passwordHash: FnMusicAPIProtocol.passwordHash(password),
            accessCodeHash: FnMusicAPIProtocol.passwordHash(accessCode ?? ""),
            usesRelay: usesRelay
        )
        if let cached = sessions[source.id], cached.identity == identity {
            return cached.token
        }
        sessions[source.id] = nil

        if let existingOperation = sessionTasks[source.id],
           existingOperation.identity != identity {
            existingOperation.task.cancel()
            sessionTasks[source.id] = nil
        }
        if let inFlight = sessionTasks[source.id] {
            let token = try await inFlight.task.value
            if let cached = sessions[source.id],
               cached.identity == identity,
               cached.token == token {
                return token
            }
            guard sessionTasks[source.id]?.id == inFlight.id else {
                throw CancellationError()
            }
            sessions[source.id] = CachedSession(identity: identity, token: token)
            sessionTasks[source.id] = nil
            return token
        }
        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            try await fnMusicLogin(
                base: base,
                sourceID: source.id,
                username: username,
                password: password,
                accessCode: accessCode,
                usesRelay: usesRelay
            )
        }
        let operation = LoginOperation(id: taskID, identity: identity, task: task)
        sessionTasks[source.id] = operation
        let token: String
        do {
            token = try await task.value
        } catch {
            if sessionTasks[source.id]?.id == taskID { sessionTasks[source.id] = nil }
            throw error
        }
        if let cached = sessions[source.id],
           cached.identity == identity,
           cached.token == token {
            return token
        }
        guard sessionTasks[source.id]?.id == taskID else {
            throw CancellationError()
        }
        sessions[source.id] = CachedSession(identity: identity, token: token)
        sessionTasks[source.id] = nil
        return token
    }

    private func endpointProvider(
        for source: MusicSource,
        accessCode: String?
    ) -> FnMusicEndpointProvider {
        let identity = EndpointIdentity(
            host: source.host,
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath,
            connectionMode: source.effectiveFnMusicConnectionMode,
            accessCodeHash: FnMusicAPIProtocol.passwordHash(accessCode ?? "")
        )
        if let cached = endpointProviders[source.id], cached.identity == identity {
            return cached.provider
        }
        let provider = FnMusicEndpointProvider(
            source: source,
            accessCode: accessCode,
            session: session
        )
        endpointProviders[source.id] = EndpointCacheEntry(identity: identity, provider: provider)
        return provider
    }

    // MARK: - Feiniu Music

    private func fnMusicLogin(
        base: URL,
        sourceID: String,
        username: String,
        password: String,
        accessCode: String?,
        usesRelay: Bool
    ) async throws -> String {
        guard let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: base,
            path: "/user/password-login"
        ) else { throw StreamResolveError.cannotBuildURL }
        let body = try SafeJSONSerialization.data(
            withJSONObject: [
                "username": username,
                "password": FnMusicAPIProtocol.passwordHash(password),
                "deviceId": FnMusicAPIProtocol.deviceID(sourceID: sourceID),
            ],
            options: [.sortedKeys]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.httpBody = body
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: nil,
            usesRelay: usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request, bodyData: body)
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            redirectMode: .fnMusic
        )
        try Self.checkAuth(response)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamResolveError.badServerResponse(200)
        }
        let code = (envelope["code"] as? NSNumber)?.intValue
            ?? Int(envelope["code"] as? String ?? "")
            ?? -1
        guard code == 0 || code == 200 else {
            if code == 120001 || code == 401 || code == 403 {
                throw StreamResolveError.authFailed
            }
            throw StreamResolveError.badServerResponse(code)
        }
        guard let token = Self.parseFnMusicToken(data) else {
            throw StreamResolveError.badServerResponse(200)
        }
        return token
    }

    /// Validate the exact Cookie/header/media path before handing it to
    /// AVFoundation. Resource-loader HTTP errors happen after resolution and
    /// cannot refresh this actor's token, so a two-byte probe prevents an
    /// expired token from remaining cached across every later playback.
    private func validateFnMusicStream(
        url: URL,
        token: String,
        accessCode: String?,
        usesRelay: Bool
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(HTTPRangeProbePolicy.requestHeaderValue, forHTTPHeaderField: "Range")
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: token,
            usesRelay: usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request)

        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            maximumBytes: 64 * 1_024,
            redirectMode: .fnMusic
        )
        guard let http = response as? HTTPURLResponse else {
            throw StreamResolveError.badServerResponse(-1)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw StreamResolveError.authFailed
        }
        guard http.statusCode == 206 else {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
        let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        guard let totalLength = HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: contentLength
        ) else {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }

        let expectedByteCount = Int(min(Int64(2), totalLength))
        guard data.count == expectedByteCount else {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
    }

    // MARK: - 纯函数(可单测)

    static func fnMusicStreamURL(base: URL, trackGUID: String) -> URL? {
        FnMusicAPIProtocol.endpointURL(
            serverBaseURL: base,
            path: "/track/stream",
            queryItems: [URLQueryItem(name: "guid", value: trackGUID)]
        )
    }

    static func parseFnMusicToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = (json["code"] as? NSNumber)?.intValue ?? Int(json["code"] as? String ?? "") ?? -1
        guard code == 200 || code == 0, let d = json["data"] as? [String: Any] else { return nil }
        guard let token = (d["userToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StreamResolveError.badServerResponse(-1)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamResolveError.authFailed }
        guard (200...299).contains(http.statusCode) else { throw StreamResolveError.badServerResponse(http.statusCode) }
    }
}
