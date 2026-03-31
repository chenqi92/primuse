import CommonCrypto
import Foundation
import JavaScriptCore

/// A generic scraper driven by a ScraperConfig JSON definition.
/// URL templates use {{var}} placeholders; response parsing is done via embedded JavaScript.
actor ConfigurableScraper: MusicScraper {
    let type: MusicScraperType
    let config: ScraperConfig

    private let session: URLSession
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration

    init(config: ScraperConfig, cookie: String? = nil) {
        self.config = config
        self.type = .custom(config.id)
        self.minInterval = .milliseconds(config.rateLimit ?? 300)

        // Build session with global headers + optional SSL trust
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        var headers = config.headers ?? [:]
        if let cookie = cookie ?? config.cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        if !headers.isEmpty {
            sessionConfig.httpAdditionalHeaders = headers
        }

        if let trustDomains = config.sslTrustDomains, !trustDomains.isEmpty {
            let delegate = SSLBypassDelegate(trustedDomains: trustDomains)
            self.session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        } else {
            self.session = URLSession(configuration: sessionConfig)
        }
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
        let parsed = try runScript(endpoint.script, data: data)

        guard let items = parsed as? [[String: Any]] else {
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

            let (data, _) = try await session.data(for: request)
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

            let (data, _) = try await session.data(for: request)
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

        // Try to parse as JSON
        if var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Inject externalId so scripts can parse compound IDs
            if let externalId { json["_externalId"] = externalId }
            context.setObject(json, forKeyedSubscript: "response" as NSString)
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            context.setObject(json, forKeyedSubscript: "response" as NSString)
        } else {
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

// MARK: - SSL Bypass Delegate

/// URLSession delegate that trusts specific domains (for CDNs with certificate issues).
/// Implements both session-level and task-level challenge handlers for full coverage.
final class SSLBypassDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let trustedDomains: [String]

    init(trustedDomains: [String]) {
        self.trustedDomains = trustedDomains
    }

    // Session-level SSL challenge (used by async data(for:) API)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    // Task-level SSL challenge (used by data(for:delegate:) API)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host
            if trustedDomains.contains(where: { host.hasSuffix($0) }) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
