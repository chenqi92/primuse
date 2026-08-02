import Foundation

/// QNAP NAS streaming resolver. It authenticates with QTS and places the
/// resulting SID in the QNAP file-manager download URL.
public actor NasHttpStreamResolver: StreamResolver {
    private var sessions: [String: String] = [:]
    private var sessionTasks: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        self.session = StreamResolverSessionFactory.make(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func invalidateSession(sourceID: String) {
        sessions[sourceID] = nil
        sessionTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> URL {
        guard source.type == .qnap else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let credential = credential ?? SourceCredential()
        let username = credential.username ?? source.username ?? ""
        guard let password = credential.password,
              !password.isEmpty,
              !username.isEmpty else {
            throw StreamResolveError.missingCredential
        }
        guard let base = Self.baseURL(
            host: source.host ?? "",
            port: source.port,
            useSsl: source.useSsl
        ) else {
            throw StreamResolveError.cannotBuildURL
        }
        let sid = try await currentSession(
            sourceID: source.id,
            base: base,
            username: username,
            password: password
        )
        guard let url = Self.qnapDownloadURL(base: base, path: song.filePath, sid: sid) else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }

    private func currentSession(
        sourceID: String,
        base: URL,
        username: String,
        password: String
    ) async throws -> String {
        if let cached = sessions[sourceID] { return cached }
        if let inFlight = sessionTasks[sourceID] {
            let sid = try await inFlight.task.value
            if sessions[sourceID] == sid { return sid }
            guard sessionTasks[sourceID]?.id == inFlight.id else {
                throw CancellationError()
            }
            sessions[sourceID] = sid
            sessionTasks[sourceID] = nil
            return sid
        }

        let taskID = UUID()
        let task = Task<String, Error> { [self] in
            try await qnapLogin(base: base, username: username, password: password)
        }
        sessionTasks[sourceID] = (taskID, task)

        let sid: String
        do {
            sid = try await task.value
        } catch {
            if sessionTasks[sourceID]?.id == taskID { sessionTasks[sourceID] = nil }
            throw error
        }
        if sessions[sourceID] == sid { return sid }
        guard sessionTasks[sourceID]?.id == taskID else {
            throw CancellationError()
        }
        sessions[sourceID] = sid
        sessionTasks[sourceID] = nil
        return sid
    }

    private func qnapLogin(base: URL, username: String, password: String) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("cgi-bin/authLogin.cgi"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "user=\(Self.formEncode(username))&pwd=\(Self.formEncode(password))&remme=1"
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try Self.checkAuth(response)
        guard let sid = Self.parseQnapSID(data) else {
            throw StreamResolveError.authFailed
        }
        return sid
    }

    static func baseURL(host: String, port: Int?, useSsl: Bool) -> URL? {
        var host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        var scheme = useSsl ? "https" : "http"
        if let range = host.range(of: "://") {
            scheme = String(host[..<range.lowerBound]).lowercased()
            host = String(host[range.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        var hostPort = host
        if let port, port > 0, !host.contains(":") { hostPort = "\(host):\(port)" }
        return URL(string: "\(scheme)://\(hostPort)")
    }

    static func qnapDownloadURL(base: URL, path: String, sid: String) -> URL? {
        guard var components = URLComponents(
            url: base.appendingPathComponent("cgi-bin/filemanager/utilRequest.cgi"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "func", value: "download"),
            URLQueryItem(name: "source_path", value: path),
            URLQueryItem(name: "sid", value: sid),
        ]
        return components.url
    }

    static func parseQnapSID(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["authPassed"] as? Int) == 1,
           let sid = json["authSid"] as? String {
            return sid
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.contains("<authPassed>1</authPassed>"),
              let lower = text.range(of: "<authSid><![CDATA["),
              let upper = text.range(of: "]]></authSid>") else { return nil }
        return String(text[lower.upperBound..<upper.lowerBound])
    }

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StreamResolveError.authFailed
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw StreamResolveError.authFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
    }
}
