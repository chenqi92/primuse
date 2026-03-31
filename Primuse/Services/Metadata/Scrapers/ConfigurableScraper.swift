import CommonCrypto
import Foundation
import JavaScriptCore

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

        // Provide _noop helper for source_a CDN URL construction
        let encryptBlock: @convention(block) (String) -> String = { idStr in
            Self._noop(idStr)
        }
        context.setObject(encryptBlock, forKeyedSubscript: "_noop" as NSString)

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

    // MARK: - Helper removed

    /// Removed.
    /// 
    nonisolated static func _noop(_ id: String) -> String {
        let key = Array("REMOVED_KEY".utf8)
        let idBytes = Array(id.utf8)
        var xored = [UInt8](repeating: 0, count: idBytes.count)
        for i in 0..<idBytes.count {
            xored[i] = idBytes[i] ^ key[i % key.count]
        }
        var digest = [UInt8](repeating: 0, count: 16)
        let data = Data(xored)
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

// MARK: - Scraper Session Manager

/// URLSession manager with SSL bypass for trusted domains.
/// Follows the exact same pattern as the proven source_bSessionManager:
/// - NSObject subclass as URLSessionTaskDelegate
/// - Stored session property keeps delegate alive
/// - data(for:delegate:self) ensures task-level delegate is called
final class ScraperSessionManager: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var _session: URLSession!
    private let trustDomains: [String]

    init(headers: [String: String], trustDomains: [String]) {
        self.trustDomains = trustDomains
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        if !headers.isEmpty {
            config.httpAdditionalHeaders = headers
        }
        _session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let scheme = request.url?.scheme ?? "?"
        let host = request.url?.host ?? "?"
        plog("🔒 ScraperSession: \(scheme)://\(host) trustDomains=\(trustDomains)")

        // HTTP requests must use URLSession.shared (ATS bypass only works with shared/default sessions)
        // Custom sessions with delegates are not covered by NSAllowsArbitraryLoads
        if scheme == "http" {
            return try await URLSession.shared.data(for: request)
        }

        return try await _session.data(for: request, delegate: self)
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
            if trustDomains.contains(where: { host.hasSuffix($0) }) {
                plog("🔒 SSL: TRUSTING \(host) (overriding hostname validation)")
                // Override the SSL policy to skip hostname validation
                // This is needed for CDNs where cert CN doesn't match the requested domain
                // (e.g. *.cdn.myqcloud.com serving source-b.invalid)
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
