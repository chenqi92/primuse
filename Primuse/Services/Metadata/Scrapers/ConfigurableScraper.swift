import CryptoKit
import Foundation
import JavaScriptCore
import Network

/// A generic scraper driven by a ScraperConfig JSON definition.
/// URL templates use {{var}} placeholders; response parsing is done via embedded JavaScript.
actor ConfigurableScraper: MusicScraper {
    let type: MusicScraperType
    let config: ScraperConfig

    private let sessionManager: ScraperSessionManager
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration

    init(config: ScraperConfig, cookie: String? = nil) {
        self.config = config
        self.type = .custom(config.id)
        self.minInterval = .milliseconds(config.rateLimit ?? 300)

        var headers = config.headers ?? [:]
        if let cookie = cookie ?? config.cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }

        plog("🔧 ConfigurableScraper init: id=\(config.id) sslTrustDomains=\(config.sslTrustDomains ?? [])")
        self.sessionManager = ScraperSessionManager(
            headers: headers,
            trustDomains: config.sslTrustDomains ?? []
        )
    }

    nonisolated static func downloadResource(
        from urlString: String,
        sourceConfig: ScraperSourceConfig? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Data? {
        guard let request = buildResourceRequest(from: urlString, sourceConfig: sourceConfig, timeout: timeout) else {
            return nil
        }

        let sessionManager = resourceSessionManager(for: sourceConfig)
        let (data, response) = try await sessionManager.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        guard let endpoint = config.search else { return .empty(type) }

        var keyword = query
        if let artist, !artist.isEmpty { keyword += " \(artist)" }
        if let album, !album.isEmpty { keyword += " \(album)" }

        let vars: [String: String] = [
            "query": keyword,
            "limit": String(limit),
            "artist": artist ?? "",
            "album": album ?? "",
        ]

        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        plog("🔧 \(config.id) search: got \(data.count) bytes, responseText preview: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
        let parsed = try runScript(endpoint.script, data: data)
        plog("🔧 \(config.id) search: JS returned items=\((parsed as? [Any])?.count ?? -1)")

        guard let items = parsed as? [[String: Any]] else {
            plog("🔧 \(config.id) search: parsed is NOT [[String:Any]], actual=\(String(describing: parsed).prefix(200))")
            return .empty(type)
        }

        let searchItems = items.compactMap { item -> ScraperSearchItem? in
            guard let id = item["id"] as? String ?? (item["id"] as? NSNumber)?.stringValue else { return nil }
            let title = item["title"] as? String ?? ""
            return ScraperSearchItem(
                externalId: id,
                source: type,
                title: title,
                artist: item["artist"] as? String,
                album: item["album"] as? String,
                year: item["year"] as? Int ?? (item["year"] as? NSNumber)?.intValue,
                durationMs: item["durationMs"] as? Int ?? (item["durationMs"] as? NSNumber)?.intValue,
                coverUrl: item["coverUrl"] as? String,
                trackNumber: item["trackNumber"] as? Int ?? (item["trackNumber"] as? NSNumber)?.intValue,
                genres: item["genres"] as? [String]
            )
        }

        return ScraperSearchResult(items: searchItems, source: type)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        guard let endpoint = config.detail else { return nil }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try runScript(endpoint.script, data: data, externalId: externalId)

        guard let dict = parsed as? [String: Any] else { return nil }

        return ScraperDetail(
            externalId: externalId,
            source: type,
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String,
            albumArtist: dict["albumArtist"] as? String,
            album: dict["album"] as? String,
            year: dict["year"] as? Int ?? (dict["year"] as? NSNumber)?.intValue,
            trackNumber: dict["trackNumber"] as? Int ?? (dict["trackNumber"] as? NSNumber)?.intValue,
            discNumber: dict["discNumber"] as? Int ?? (dict["discNumber"] as? NSNumber)?.intValue,
            durationMs: dict["durationMs"] as? Int ?? (dict["durationMs"] as? NSNumber)?.intValue,
            genres: dict["genres"] as? [String],
            coverUrl: dict["coverUrl"] as? String
        )
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        guard let endpoint = config.cover else { return [] }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try runScript(endpoint.script, data: data, externalId: externalId)

        guard let items = parsed as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let coverUrl = item["coverUrl"] as? String else { return nil }
            return ScraperCoverResult(
                source: type,
                coverUrl: coverUrl,
                thumbnailUrl: item["thumbnailUrl"] as? String
            )
        }
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        guard let endpoint = config.lyrics else { return nil }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try runScript(endpoint.script, data: data, externalId: externalId)

        guard let dict = parsed as? [String: Any] else { return nil }

        let lrcContent = dict["lrcContent"] as? String
        let plainText = dict["plainText"] as? String
        guard lrcContent != nil || plainText != nil else { return nil }

        return ScraperLyricsResult(source: type, lrcContent: lrcContent, plainText: plainText)
    }

    // MARK: - Request Execution

    private func executeRequest(endpoint: EndpointConfig, vars: [String: String]) async throws -> Data {
        // Rate limiting
        if let last = lastRequestTime {
            let elapsed = ContinuousClock.now - last
            if elapsed < minInterval {
                try await Task.sleep(for: minInterval - elapsed)
            }
        }
        lastRequestTime = .now

        // Build URL with variable substitution
        var urlString = endpoint.url
        for (key, value) in vars {
            urlString = urlString.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        // Enforce HTTPS unless domain is in sslTrustDomains or is a local network address
        urlString = Self.enforceHTTPPolicy(urlString, trustDomains: config.sslTrustDomains ?? [])

        let method = endpoint.method.uppercased()

        if method == "POST" {
            // POST: params or bodyTemplate as JSON body
            guard let url = URL(string: urlString) else {
                throw ScraperError.networkError("Invalid URL: \(urlString)")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            // Merge endpoint-specific headers
            for (k, v) in endpoint.headers ?? [:] {
                request.setValue(v, forHTTPHeaderField: k)
            }

            if let bodyTemplate = endpoint.bodyTemplate {
                // Use body template with variable substitution
                var body = bodyTemplate
                for (key, value) in vars {
                    body = body.replacingOccurrences(of: "{{\(key)}}", with: value)
                }
                request.httpBody = body.data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if let params = endpoint.params {
                // Build JSON body from params
                var bodyDict: [String: String] = [:]
                for (k, v) in params {
                    var val = v
                    for (vk, vv) in vars {
                        val = val.replacingOccurrences(of: "{{\(vk)}}", with: vv)
                    }
                    bodyDict[k] = val
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }

            let (data, _) = try await sessionManager.data(for: request)
            return data
        } else {
            // GET: params as query items
            var components = URLComponents(string: urlString)
            if let params = endpoint.params {
                var queryItems = components?.queryItems ?? []
                for (k, v) in params {
                    var val = v
                    for (vk, vv) in vars {
                        val = val.replacingOccurrences(of: "{{\(vk)}}", with: vv)
                    }
                    queryItems.append(URLQueryItem(name: k, value: val))
                }
                components?.queryItems = queryItems
            }

            guard let url = components?.url else {
                throw ScraperError.networkError("Invalid URL: \(urlString)")
            }

            var request = URLRequest(url: url)
            for (k, v) in endpoint.headers ?? [:] {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let (data, _) = try await sessionManager.data(for: request)
            return data
        }
    }

    // MARK: - JavaScript Execution

    private func runScript(_ script: String, data: Data, externalId: String? = nil) throws -> Any? {
        let context = JSContext()!

        // Provide console.log for debugging
        let logBlock: @convention(block) (String) -> Void = { msg in
            plog("📜 JS[\(self.config.id)]: \(msg)")
        }
        context.setObject(logBlock, forKeyedSubscript: "log" as NSString)

        ScraperNativeResolvers.register(in: context)


        // Inject response as string and parsed JSON
        let responseText = String(data: data, encoding: .utf8) ?? ""
        context.setObject(responseText, forKeyedSubscript: "responseText" as NSString)

        // Try to parse as JSON (with fallback for non-standard formats like single-quoted JSON)
        var parsed: Any?
        if let json = try? JSONSerialization.jsonObject(with: data) {
            parsed = json
        } else {
            // Fallback: try fixing single-quoted JSON (e.g. source_e) or JSONP
            var text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip JSONP callback: starts with word chars followed by (
            if text.range(of: #"^\w+\("#, options: .regularExpression) != nil,
               let openParen = text.firstIndex(of: "("),
               let closeParen = text.lastIndex(of: ")"),
               openParen < closeParen {
                text = String(text[text.index(after: openParen)..<closeParen])
            }
            // Replace single quotes with double quotes
            text = text.replacingOccurrences(of: "'", with: "\"")
            // Fix &nbsp; entities
            text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            if let fixedData = text.data(using: .utf8) {
                parsed = try? JSONSerialization.jsonObject(with: fixedData)
                if parsed == nil {
                    plog("🔧 JSON fallback parse failed for \(config.id), first 200: \(text.prefix(200))")
                }
            }
        }

        if var json = parsed as? [String: Any] {
            if let externalId { json["_externalId"] = externalId }
            context.setObject(json, forKeyedSubscript: "response" as NSString)
        } else if let parsed {
            context.setObject(parsed, forKeyedSubscript: "response" as NSString)
        } else {
            // Let JS parse it via responseText if Swift can't
            var fallback: [String: Any] = [:]
            if let externalId { fallback["_externalId"] = externalId }
            context.setObject(fallback, forKeyedSubscript: "response" as NSString)
        }

        // Also inject externalId as a top-level variable
        if let externalId {
            context.setObject(externalId, forKeyedSubscript: "externalId" as NSString)
        }

        // Handle exceptions
        context.exceptionHandler = { _, exception in
            plog("📜 JS error[\(self.config.id)]: \(exception?.toString() ?? "unknown")")
        }

        // Execute script — wrap in IIFE if not already
        let wrappedScript: String
        if script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(") {
            wrappedScript = script
        } else {
            wrappedScript = "(function() { \(script) })()"
        }

        guard let result = context.evaluateScript(wrappedScript) else {
            throw ScraperError.parseError("Script returned nil")
        }

        if result.isUndefined || result.isNull {
            return nil
        }

        return result.toObject()
    }

    // MARK: - HTTP Policy

    nonisolated private static func buildResourceRequest(
        from urlString: String,
        sourceConfig: ScraperSourceConfig?,
        timeout: TimeInterval
    ) -> URLRequest? {
        let trustDomains = resourceTrustDomains(for: sourceConfig)
        let safeURLString = enforceHTTPPolicy(urlString, trustDomains: trustDomains)
        guard let url = URL(string: safeURLString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (header, value) in resourceHeaders(for: sourceConfig) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    nonisolated private static func resourceSessionManager(for sourceConfig: ScraperSourceConfig?) -> ScraperSessionManager {
        ScraperSessionManager(
            headers: resourceHeaders(for: sourceConfig),
            trustDomains: resourceTrustDomains(for: sourceConfig)
        )
    }

    nonisolated private static func resourceHeaders(for sourceConfig: ScraperSourceConfig?) -> [String: String] {
        let context = configContext(for: sourceConfig)
        var headers = context?.config.headers ?? [:]
        if let cookie = context?.cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        }
        return headers
    }

    nonisolated private static func resourceTrustDomains(for sourceConfig: ScraperSourceConfig?) -> [String] {
        configContext(for: sourceConfig)?.config.sslTrustDomains ?? []
    }

    nonisolated private static func configContext(
        for sourceConfig: ScraperSourceConfig?
    ) -> (config: ScraperConfig, cookie: String?)? {
        guard let sourceConfig,
              case .custom(let configID) = sourceConfig.type,
              let config = ScraperConfigStore.shared.config(for: configID) else {
            return nil
        }
        return (config, sourceConfig.cookie ?? config.cookie)
    }

    /// Only allow HTTP for trusted domains and local network addresses.
    /// All other HTTP URLs are upgraded to HTTPS.
    nonisolated static func enforceHTTPPolicy(_ urlString: String, trustDomains: [String]) -> String {
        guard urlString.hasPrefix("http://") else { return urlString }
        guard let url = URL(string: urlString), let host = url.host else { return urlString }

        // Allow HTTP for local network addresses
        if isLocalNetwork(host) { return urlString }

        // Allow HTTP for trusted domains
        if trustDomains.contains(where: { host.hasSuffix($0) }) { return urlString }

        // Upgrade to HTTPS
        return "https://" + urlString.dropFirst(7)
    }

    /// Check if host is a local network address (IP, .local, private ranges)
    nonisolated private static func isLocalNetwork(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }

        // IPv6 link-local or private
        if host.hasPrefix("[") || host.contains(":") { return true }

        // IPv4 private ranges
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            if parts[0] == 10 { return true }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 127 { return true }
        }

        return false
    }

    nonisolated static func describeNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "localized=\(nsError.localizedDescription)",
        ]

        if let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString {
            parts.append("url=\(failingURL)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)")
        }

        return parts.joined(separator: " ")
    }

}

private enum PlainHTTPClient {
    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private var received = Data()

        func append(_ data: Data) {
            lock.lock()
            received.append(data)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        func markResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.scheme == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw ScraperError.networkError("Invalid HTTP URL: \(request.url?.absoluteString ?? "nil")")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "Primuse.PlainHTTPClient.\(UUID().uuidString)")

        return try await withCheckedThrowingContinuation { continuation in
            let stateBox = StateBox()

            @Sendable func finish(_ result: Result<(Data, URLResponse), Error>) {
                guard stateBox.markResumed() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            @Sendable func receiveLoop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }

                    if let data, !data.isEmpty {
                        stateBox.append(data)
                    }

                    if isComplete || data?.isEmpty == true {
                        do {
                            let parsed = try parseResponse(stateBox.snapshot(), for: url)
                            finish(.success(parsed))
                        } catch {
                            finish(.failure(error))
                        }
                    } else {
                        receiveLoop()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    do {
                        let payload = try buildRequestData(for: request)
                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                            } else {
                                receiveLoop()
                            }
                        })
                    } catch {
                        finish(.failure(error))
                    }
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(ScraperError.networkError("HTTP connection cancelled")))
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private static func buildRequestData(for request: URLRequest) throws -> Data {
        guard let url = request.url,
              let host = url.host else {
            throw ScraperError.networkError("Invalid HTTP request URL")
        }

        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let pathWithQuery = path + (url.query.map { "?\($0)" } ?? "")

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = host
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        if let body = request.httpBody, headers["Content-Length"] == nil {
            headers["Content-Length"] = String(body.count)
        }

        var lines = ["\(method) \(pathWithQuery) HTTP/1.1"]
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        if let body = request.httpBody {
            data.append(body)
        }
        return data
    }

    private static func parseResponse(_ responseData: Data, for url: URL) throws -> (Data, URLResponse) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = responseData.range(of: separator) else {
            throw ScraperError.networkError("Invalid HTTP response")
        }

        let headerData = responseData[..<headerRange.lowerBound]
        var body = Data(responseData[headerRange.upperBound...])
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        guard let statusLine = lines.first else {
            throw ScraperError.networkError("Missing HTTP status line")
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ScraperError.networkError("Invalid HTTP status line: \(statusLine)")
        }

        var headerFields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headerFields[key], !existing.isEmpty {
                headerFields[key] = "\(existing), \(value)"
            } else {
                headerFields[key] = value
            }
        }

        if headerFields["Transfer-Encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            body = try decodeChunked(body)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
            throw ScraperError.networkError("Failed to construct HTTPURLResponse")
        }

        return (body, response)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        let lineBreak = Data("\r\n".utf8)

        while cursor < data.endIndex {
            guard let sizeLineRange = data[cursor...].range(of: lineBreak) else {
                throw ScraperError.networkError("Invalid chunked body")
            }

            let sizeLine = String(decoding: data[cursor..<sizeLineRange.lowerBound], as: UTF8.self)
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let chunkSize = Int(hexPart.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw ScraperError.networkError("Invalid chunk size: \(sizeLine)")
            }

            cursor = sizeLineRange.upperBound
            if chunkSize == 0 {
                break
            }

            guard let chunkEnd = data.index(cursor, offsetBy: chunkSize, limitedBy: data.endIndex) else {
                throw ScraperError.networkError("Chunk exceeds response body")
            }

            decoded.append(data[cursor..<chunkEnd])
            cursor = chunkEnd

            guard data[cursor...].starts(with: lineBreak) else {
                throw ScraperError.networkError("Missing chunk terminator")
            }
            cursor = data.index(cursor, offsetBy: lineBreak.count)
        }

        return decoded
    }
}

// MARK: - Scraper Session Manager

/// URLSession manager with SSL bypass for trusted domains.
/// URLSession manager that supports SSL bypass for user-configured trusted domains.
/// - NSObject subclass as URLSessionTaskDelegate
/// - Stored session property keeps delegate alive
/// - data(for:delegate:self) ensures task-level delegate is called
final class ScraperSessionManager: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var _session: URLSession!
    private let defaultHeaders: [String: String]
    private let trustDomains: [String]

    init(headers: [String: String], trustDomains: [String]) {
        self.defaultHeaders = headers
        self.trustDomains = trustDomains
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !headers.isEmpty {
            config.httpAdditionalHeaders = headers
        }
        _session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var mergedRequest = request
        mergedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (header, value) in defaultHeaders where mergedRequest.value(forHTTPHeaderField: header) == nil {
            mergedRequest.setValue(value, forHTTPHeaderField: header)
        }

        let scheme = mergedRequest.url?.scheme ?? "?"
        let host = mergedRequest.url?.host ?? "?"
        plog("🔒 ScraperSession: \(scheme)://\(host) trustDomains=\(trustDomains)")

        // HTTP requests must use URLSession.shared (ATS bypass only works with shared/default sessions)
        if scheme == "http" {
            return try await PlainHTTPClient.data(for: mergedRequest)
        }

        do {
            return try await _session.data(for: mergedRequest, delegate: self)
        } catch {
            if let fallbackRequest = fallbackRequestForTrustedHTTPRetry(from: mergedRequest, error: error) {
                plog("⚠️ HTTPS failed for trusted host \(host); retrying over HTTP: \(fallbackRequest.url?.absoluteString ?? "?")")
                do {
                    return try await PlainHTTPClient.data(for: fallbackRequest)
                } catch {
                    plog("⚠️ HTTP retry failed: \(fallbackRequest.httpMethod ?? "GET") \(fallbackRequest.url?.absoluteString ?? "?") \(ConfigurableScraper.describeNetworkError(error))")
                    throw error
                }
            }
            plog("⚠️ Request failed: \(mergedRequest.httpMethod ?? "GET") \(mergedRequest.url?.absoluteString ?? "?") \(ConfigurableScraper.describeNetworkError(error))")
            throw error
        }
    }

    private func fallbackRequestForTrustedHTTPRetry(from request: URLRequest, error: Error) -> URLRequest? {
        guard let url = request.url,
              url.scheme == "https",
              let host = url.host,
              SSLTrustStore.sslErrorDomain(from: error) != nil else {
            return nil
        }

        let trustedByConfig = trustDomains.contains(where: { host.hasSuffix($0) })
        let trustedByUser = SSLTrustStore.isTrustedSync(domain: host)
        guard trustedByConfig || trustedByUser else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        guard let fallbackURL = components?.url else { return nil }

        var fallbackRequest = request
        fallbackRequest.url = fallbackURL
        fallbackRequest.cachePolicy = .reloadIgnoringLocalCacheData
        return fallbackRequest
    }

    // Task-level delegate — called by async data(for:delegate:) API
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let method = challenge.protectionSpace.authenticationMethod
        plog("🔒 SSL challenge: host=\(host) method=\(method) trustDomains=\(trustDomains)")

        if method == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let trustedByConfig = trustDomains.contains(where: { host.hasSuffix($0) })
            let trustedByUser = SSLTrustStore.isTrustedSync(domain: host)
            if trustedByConfig || trustedByUser {
                plog("🔒 SSL: TRUSTING \(host) (trustedByConfig=\(trustedByConfig) trustedByUser=\(trustedByUser))")
                // Override the SSL policy to skip hostname validation
                // This is needed for CDNs where cert CN doesn't match the requested domain
                SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    plog("🔒 SSL: trust evaluation failed for \(host): \(error?.localizedDescription ?? "?")")
                    completionHandler(.useCredential, URLCredential(trust: trust))
                }
                return
            }
        }
        plog("🔒 SSL: DEFAULT handling for \(host)")
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Native Resolvers

/// Swift-side helpers exposed to scraper JavaScript via the `nativeResolver` global.
/// Source-specific transforms that would otherwise live as plaintext in shared
/// scraper JSON are kept here so the public configs stay neutral.
enum ScraperNativeResolvers {
    static func register(in context: JSContext) {
        context.evaluateScript("var nativeResolver = nativeResolver || {};")
        guard let resolver = context.objectForKeyedSubscript("nativeResolver") else { return }

        let neteaseCoverBlock: @convention(block) (Any?, Any?) -> String? = { picIdArg, sizeArg in
            normalizedPicId(picIdArg).flatMap { picId in
                neteaseCoverURL(picId: picId, size: normalizedSize(sizeArg))
            }
        }
        resolver.setObject(neteaseCoverBlock, forKeyedSubscript: "neteaseCover" as NSString)
    }

    private static func normalizedPicId(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty, s != "0" { return s }
        if let n = value as? NSNumber, n.int64Value > 0 { return n.stringValue }
        return nil
    }

    private static func normalizedSize(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let v = Int(s) { return v }
        return 0
    }

    // Stored as bytes so the literal seed never appears in source as a single string.
    private static let neteaseCoverSeed: [UInt8] = [
        0x33, 0x67, 0x6F, 0x38, 0x26, 0x24, 0x38, 0x2A, 0x33,
        0x2A, 0x33, 0x68, 0x30, 0x6B, 0x28, 0x32, 0x29, 0x32,
    ]

    private static func neteaseCoverURL(picId: String, size: Int) -> String {
        let src = Array(picId.utf8)
        var mixed = [UInt8](repeating: 0, count: src.count)
        for i in 0..<src.count {
            mixed[i] = src[i] ^ neteaseCoverSeed[i % neteaseCoverSeed.count]
        }
        let digest = Insecure.MD5.hash(data: mixed)
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        var url = "https://p1.music.126.net/\(encoded)/\(picId).jpg"
        if size > 0 { url += "?param=\(size)y\(size)" }
        return url
    }
}
