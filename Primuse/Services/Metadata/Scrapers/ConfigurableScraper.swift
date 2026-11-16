import CommonCrypto
import CryptoKit
import zlib
import Foundation
import Network
import PrimuseKit

/// A generic scraper driven by a ScraperConfig JSON definition.
/// URL templates and fixed JSON rules describe requests and response fields.
actor ConfigurableScraper: MusicScraper {
    let type: MusicScraperType
    let config: ScraperConfig

    private let sessionManager: ScraperSessionManager
    private let allowExpensiveNetwork: Bool
    private let requestPool: ScraperRequestPool
    private let anonymousDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    nonisolated static let maxEndpointResponseBytes = 5 * 1024 * 1024
    nonisolated static let maxResourceResponseBytes = 20 * 1024 * 1024
    /// RFC-reserved example domains are commonly used by scraper manifests to
    /// mark an unsupported optional endpoint. Treat them as absent instead of
    /// issuing a real request and trying to parse the Example Domain HTML.
    nonisolated private static func isPlaceholderEndpoint(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
        return ["example.com", "example.net", "example.org"].contains { reserved in
            host == reserved || host.hasSuffix(".\(reserved)")
        }
    }

    init(
        config: ScraperConfig, cookie: String? = nil, session: URLSession? = nil,
        requestPool: ScraperRequestPool = .shared, allowExpensiveNetwork: Bool = true
    ) {
        self.allowExpensiveNetwork = allowExpensiveNetwork
        self.config = config
        self.type = .custom(config.id)
        self.requestPool = requestPool

        var headers = config.headers ?? [:]
        if let cookie = cookie ?? config.cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }

        plog("🔧 ConfigurableScraper init: id=\(config.id) sslTrustDomains=\(config.sslTrustDomains ?? [])")
        self.sessionManager = ScraperSessionManager(
            headers: headers,
            trustDomains: config.sslTrustDomains ?? [], credentialOrigins: ScraperNetworkScope.credentialOrigins(config), session: session
        )
    }

    nonisolated static func downloadResource(
        from urlString: String,
        sourceConfig: ScraperSourceConfig? = nil,
        timeout: TimeInterval = 10,
        session: URLSession? = nil,
        requestPool: ScraperRequestPool = .shared
    ) async throws -> Data? {
        guard !isPlaceholderEndpoint(urlString) else { return nil }
        guard let request = buildResourceRequest(from: urlString, sourceConfig: sourceConfig, timeout: timeout) else {
            return nil
        }

        let sessionManager = resourceSessionManager(for: sourceConfig, session: session)
        let executor = await requestPool.executor(for: ScraperRequestPool.resourceKey(source: sourceConfig, url: request.url))
        let context = configContext(for: sourceConfig)
        let interval = context.map { Double(max(0, $0.config.rateLimit ?? 300)) / 1000 }
        let data: Data
        do {
            data = try await executor.execute(minimumInterval: interval) {
                try await sessionManager.data(for: request, maxBytes: maxResourceResponseBytes)
            }.data
        } catch ScraperTransportError.responseTooLarge {
            return nil
        } catch let failure as HTTPResponseFailure {
            // Optional missing artwork remains a miss. Quota and server errors
            // must reach the caller instead of marking the whole batch missing.
            if (400..<500).contains(failure.statusCode), failure.statusCode != 429 { return nil }
            throw ScraperRequestPool.scraperError(failure)
        } catch {
            throw ScraperRequestPool.scraperError(error)
        }
        guard data.count <= maxResourceResponseBytes else {
            plog("⚠️ Scraper resource too large: \(data.count)B")
            return nil
        }
        return data
    }

    func isCoolingDown() async -> Bool {
        await requestPool.isCoolingDown(for: .custom(config.id))
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        guard let endpoint = config.search,
              !Self.isPlaceholderEndpoint(endpoint.url) else { return .empty(type) }

        guard limit > 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty(type) }
        let count = max(20, (min(limit, 50) + 9) / 10 * 10)
        let combined = ([query, artist, album].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " ")
        var items = try await searchItems(endpoint: endpoint, keyword: combined, title: query, artist: artist, album: album, limit: count)
        let usesQuery = ([endpoint.url, endpoint.bodyTemplate ?? ""] + Array((endpoint.params ?? [:]).values)).contains { $0.contains("{{query}}") }
        if usesQuery && combined != query && !items.contains(where: { ScraperIdentity.matchTier($0, title: query, artist: artist) == 0 && ScraperIdentity.albumTier(album, $0.album) == 0 }) {
            let broader = try await searchItems(endpoint: endpoint, keyword: query, title: query, artist: artist, album: album, limit: count)
            var seen = Set(items.map(\.externalId))
            items += broader.filter { seen.insert($0.externalId).inserted }
        }
        return ScraperSearchResult(items: ScraperManager.topMatches(in: items, title: query, artist: artist,
            durationMs: nil, maxCount: limit, album: album), source: type)
    }

    private func searchItems(endpoint: EndpointConfig, keyword: String, title: String, artist: String?, album: String?, limit: Int) async throws -> [ScraperSearchItem] {
        let vars = ["query": keyword, "title": title, "limit": String(limit), "artist": artist ?? "", "album": album ?? ""]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try parse(endpoint: endpoint, data: data)
        guard let items = parsed as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String ?? (item["id"] as? NSNumber)?.stringValue,
                  !id.isEmpty, let title = item["title"] as? String, !title.isEmpty else { return nil }
            return ScraperSearchItem(externalId: id, source: type, title: title,
                artist: item["artist"] as? String, album: item["album"] as? String,
                year: (item["year"] as? NSNumber)?.intValue,
                durationMs: (item["durationMs"] as? NSNumber)?.intValue,
                coverUrl: item["coverUrl"] as? String,
                trackNumber: (item["trackNumber"] as? NSNumber)?.intValue,
                genres: item["genres"] as? [String], artistAliases: item["artistAliases"] as? [String] ?? [])
        }
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        guard let endpoint = config.detail,
              !Self.isPlaceholderEndpoint(endpoint.url) else { return nil }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try parse(endpoint: endpoint, data: data, externalId: externalId)

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
        guard let endpoint = config.cover,
              !Self.isPlaceholderEndpoint(endpoint.url) else { return [] }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try parse(endpoint: endpoint, data: data, externalId: externalId)

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
        guard let endpoint = config.lyrics,
              !Self.isPlaceholderEndpoint(endpoint.url) else { return nil }

        let vars = ["id": externalId]
        let data = try await executeRequest(endpoint: endpoint, vars: vars)
        let parsed = try parse(endpoint: endpoint, data: data, externalId: externalId)

        guard let dict = parsed as? [String: Any] else { return nil }

        // === 通用二次请求 + 二进制解密分支 ===
        // 第一步 script 返回 `{_fetchEncryptedLyrics: true, vars: {...}}` 标记后,
        // framework 用 secrets 提供的 URL 模板拉二进制，再用 secrets 提供的
        // magic + xorKey 解密、按相对偏移格式转 A2 LRC。
        //
        // 新配置也可用 _fetchLyrics 标记请求配置中的明文回退。
        if dict["_fetchEncryptedLyrics"] as? Bool == true || dict["_fetchLyrics"] as? Bool == true {
            // vars 支持两种形式:
            // - dict（单个 candidate）: 直接 fetch
            // - array（多个 candidate）: 依次 try, 选 lrcContent 最长的 (有些
            //   源 candidates 按 score 排但 score 高 ≠ 完整, 常出现"官方推荐
            //   4 行残缺, ugc 投稿版才是全曲"的情况)
            if let varsList = dict["vars"] as? [[String: Any]], !varsList.isEmpty {
                plog("🔐 \(config.id) getLyrics → _fetchEncryptedLyrics with \(varsList.count) candidates")
                let result = try await fetchBestEncryptedLyrics(varsList: varsList)
                plog("🔐 \(config.id) fetchBestEncryptedLyrics result: hasResult=\(result != nil) lrcLen=\(result?.lrcContent?.count ?? 0)")
                return result
            }
            if let vars = dict["vars"] as? [String: Any] {
                plog("Encrypted lyrics: fetching one candidate")
                let result = try await fetchEncryptedLyrics(vars: vars)
                plog("🔐 \(config.id) fetchEncryptedLyrics result: hasResult=\(result != nil) lrcLen=\(result?.lrcContent?.count ?? 0)")
                return result
            }
        }

        // `wordLevelLrc` 是兼容性字段：JSON 配置同时返回行级 (`lrcContent`) 和字级
        // (`wordLevelLrc`) 让老版本 app 不至于看到带 `<00:01.23>` 标记的丑文本。
        // 新版优先取字级，没有再退回行级。
        let wordLevelLrc = dict["wordLevelLrc"] as? String
        let lrcContent = dict["lrcContent"] as? String
        let plainText = dict["plainText"] as? String
        let finalLrc = (wordLevelLrc?.isEmpty == false) ? wordLevelLrc : lrcContent
        guard finalLrc != nil || plainText != nil else { return nil }

        return ScraperLyricsResult(source: type, lrcContent: finalLrc, plainText: plainText)
    }

    /// 多候选版本:依次 try, 选解密后 plain text 最长的那个 (= 最完整歌词)。
    /// 有些源 candidates 按 score 排但 score 高 ≠ 内容全, 第一个常是 4 行
    /// 残缺版, 第 2-3 个 ugc 投稿才是全曲。最多 try 5 个避免拉太多。
    private func fetchBestEncryptedLyrics(varsList: [[String: Any]]) async throws -> ScraperLyricsResult? {
        var best: ScraperLyricsResult?
        var bestLen = 0
        for vars in varsList.prefix(5) {
            let candidate: ScraperLyricsResult?
            do {
                candidate = try await fetchEncryptedLyrics(vars: vars)
            } catch {
                // 已经解出一份时, 后面的候选出错(超时、5xx、限流)就停在这份上, 不把整首歌词丢掉;
                // 一份都还没有时照常抛出, 限流和服务器故障要让调用方知道。
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                guard best != nil, !cancelled else { throw error }
                break
            }
            guard let result = candidate else { continue }
            let len = result.lrcContent?.count ?? 0
            if len > bestLen {
                bestLen = len
                best = result
            }
        }
        return best
    }

    /// 通用二次请求：URL 模板和解密参数全部来自 `config.secrets`。
    /// 所需 secrets 字段：
    /// - `lyricsFetchUrl`: URL 模板，{{var}} 占位符由 first-step 返回的 vars 填充
    /// - `lyricsContentField`: JSON 路径取 base64 内容字段名（如 `"content"`）
    /// - `lyricsMagicHex`: 二进制 magic 前缀的 hex 串
    /// - `lyricsXorKeyHex`: 异或 key 的 hex 串
    private func fetchEncryptedLyrics(vars: [String: Any]) async throws -> ScraperLyricsResult? {
        guard let secrets = config.secrets,
              let template = secrets["lyricsFetchUrl"], !template.isEmpty,
              let contentField = secrets["lyricsContentField"], !contentField.isEmpty,
              let magicHex = secrets["lyricsMagicHex"], let magic = Data(hexString: magicHex),
              let xorHex = secrets["lyricsXorKeyHex"], let xorKey = [UInt8](hexString: xorHex)
        else {
            if let fallback = LegacyScraperCompatibility.lyricsFallback(for: config) {
                return try await fetchFallbackLyrics(fallback, vars: vars)
            }
            plog("⚠️ Encrypted lyrics: missing secrets, skip")
            return nil
        }

        let stringVars = vars.reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        }
        let urlString = Self.applyURLTemplate(template, vars: stringVars)
        let safe = Self.enforceHTTPPolicy(urlString, trustDomains: config.sslTrustDomains ?? [])
        guard let url = URL(string: safe) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        do {
            data = try await performRequest(request)
        } catch let failure as HTTPResponseFailure
                    where (400..<500).contains(failure.statusCode) && failure.statusCode != 429 {
            // 和下载封面一样, 除限流外的 4xx 只说明这个候选拿不到, 接着试下一个。
            return nil
        } catch {
            throw ScraperRequestPool.scraperError(error)
        }
        plog("🔐 Encrypted lyrics: fetched \(data.count) bytes from \(Self.redactedURLDescription(url))")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            plog("Encrypted lyrics: invalid JSON response")
            return nil
        }
        guard let base64 = json[contentField] as? String, !base64.isEmpty else {
            plog("⚠️ Encrypted lyrics: missing/empty contentField '\(contentField)' in response keys=\(Array(json.keys))")
            return nil
        }
        guard let binary = Data(base64Encoded: base64) else {
            plog("⚠️ Encrypted lyrics: base64 decode failed (len=\(base64.count))")
            return nil
        }
        guard let plain = XorZlibLyricsDecoder.decrypt(binary, magicPrefix: magic, xorKey: xorKey) else {
            plog("⚠️ Encrypted lyrics: xor+zlib decrypt failed (binary len=\(binary.count) magicMatch=\(binary.prefix(magic.count) == magic))")
            return nil
        }
        let (lineLrc, wordLrc) = XorZlibLyricsDecoder.relativeOffsetToA2(plain)
        let final = wordLrc.isEmpty ? lineLrc : wordLrc
        plog("🔐 Encrypted lyrics: decoded plain=\(plain.count) chars → wordLrc=\(wordLrc.count) lineLrc=\(lineLrc.count)")
        guard !final.isEmpty else { return nil }
        return ScraperLyricsResult(source: type, lrcContent: final)
    }

    private func fetchFallbackLyrics(_ fallback: LyricsFallbackConfig, vars: [String: Any]) async throws -> ScraperLyricsResult? {
        var stringVars = vars.mapValues { String(describing: $0) }
        if stringVars["id"] == nil { stringVars["id"] = stringVars["lyricId"] }
        if stringVars["accesskey"] == nil { stringVars["accesskey"] = stringVars["accessKey"] }
        guard fallback.requiredVariables.allSatisfy({ stringVars[$0]?.isEmpty == false }) else { return nil }
        let expanded = Self.applyURLTemplate(fallback.url, vars: stringVars)
        let safe = Self.enforceHTTPPolicy(expanded, trustDomains: config.sslTrustDomains ?? [])
        guard let target = URL(string: safe),
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              !Self.isPlaceholderEndpoint(safe) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        let data: Data
        do {
            data = try await performRequest(request)
        } catch let failure as HTTPResponseFailure
            where (400..<500).contains(failure.statusCode) && failure.statusCode != 429 {
            return nil
        } catch {
            throw ScraperRequestPool.scraperError(error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json[fallback.contentField] as? String else { return nil }
        let text: String?
        switch fallback.encoding {
        case .base64UTF8:
            text = Data(base64Encoded: content).flatMap { String(data: $0, encoding: .utf8) }
        case .utf8:
            text = content
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ScraperLyricsResult(source: type, lrcContent: text)
    }

    #if !os(tvOS)
    func motionArtwork(
        input: MotionArtworkLookupInput,
        title: String?,
        trackArtist: String?,
        durationMs: Int?,
        client: MotionArtworkEndpointClient
    ) async throws -> MotionArtworkEndpointResolveResult {
        guard let endpoint = config.dynamicCover else { return .notFound }
        var variables = [
            "title": title ?? "", "artist": input.albumArtist ?? "", "album": input.albumTitle ?? "",
            "catalogAlbumId": input.appleCatalogAlbumID ?? "", "storefront": input.storefront ?? "us",
            "id": "",
        ]
        let requiresID = endpoint.url.contains("{{id")
            || endpoint.bodyTemplate?.contains("{{id") == true
            || endpoint.params?.values.contains(where: { $0.contains("{{id") }) == true
        if requiresID {
            guard let title, !title.isEmpty else { return .notFound }
            let result = try await search(query: title, artist: trackArtist, album: nil, limit: 10)
            guard let candidate = ScraperManager.bestMatch(
                in: result.items.filter { input.albumTitle?.isEmpty != false || $0.album?.isEmpty != false
                    || ScraperIdentity.albumTier(input.albumTitle, $0.album) == 0 },
                title: title, artist: trackArtist, durationMs: durationMs, album: input.albumTitle
            ) else { return .notFound }
            variables["id"] = candidate.externalId
            if let album = input.albumTitle, !album.isEmpty, let candidateAlbum = candidate.album,
               Self.normalizedArtworkText(album) != Self.normalizedArtworkText(candidateAlbum) {
                return .notFound
            }
        }
        let segments = variables["id", default: ""].components(separatedBy: "|")
        if let required = endpoint.requiredIdSegments,
           !required.allSatisfy({ $0 >= 0 && $0 < segments.count && !segments[$0].isEmpty }) {
            return .notFound
        }
        let data = try await executeRequest(endpoint: endpoint, vars: variables)
        let parsed = try parse(endpoint: endpoint, data: data, externalId: variables["id"])
        guard let candidates = parsed as? [[String: Any]] else { return .notFound }
        for candidate in candidates.prefix(5) {
            try Task.checkCancellation()
            if let album = candidate["album"] as? String,
               Self.normalizedArtworkText(album) != Self.normalizedArtworkText(input.albumTitle ?? "") { continue }
            if let artist = candidate["artist"] as? String,
               Self.normalizedArtworkText(artist) != Self.normalizedArtworkText(input.albumArtist ?? "") { continue }
            guard let address = candidate["coverUrl"] as? String ?? candidate["url"] as? String,
                  let url = URL(string: address),
                  let configuredURL = URL(string: endpoint.url),
                  MotionArtworkEndpointClient.isAuthorizedScriptAssetURL(
                    url, configuredEndpoint: configuredURL, allowedHosts: endpoint.assetHosts ?? []
                  ) else { continue }
            var assetURL = url
            if endpoint.playlist == "boundedHLS",
               url.pathExtension.lowercased() == "m3u8" || (candidate["mimeType"] as? String)?.contains("mpegurl") == true {
                assetURL = try await resolvePlaylist(url, endpoint: configuredURL, config: endpoint, client: client)
            }
            let kind = (candidate["kind"] as? String).flatMap(MotionArtworkAssetKind.init(rawValue:))
                ?? (assetURL.pathExtension.lowercased() == "mp4" ? .video : .animatedImage)
            let asset = MotionArtworkAsset(
                providerIdentifier: config.id, assetIdentifier: candidate["id"] as? String,
                kind: kind, assetURL: assetURL, mimeType: candidate["mimeType"] as? String
            )
            let result = try await client.downloadScriptAsset(
                asset, endpoint: configuredURL, allowedHosts: endpoint.assetHosts ?? [],
                allowExpensiveNetwork: allowExpensiveNetwork
            )
            if case .notFound = result { continue }
            return result
        }
        return .notFound
    }

    private func resolvePlaylist(
        _ original: URL, endpoint: URL, config: EndpointConfig, client: MotionArtworkEndpointClient
    ) async throws -> URL {
        var url = original
        var visited = Set<URL>()
        for _ in 0..<4 {
            guard visited.insert(url).inserted else { throw ScraperError.parseError("Playlist loop") }
            let bytes = try await client.downloadScriptPlaylist(
                url, endpoint: endpoint, allowedHosts: config.assetHosts ?? [], allowExpensiveNetwork: allowExpensiveNetwork
            )
            let value = try ScraperArtworkPlaylist.resolve(bytes)
            guard let next = URL(string: value.reference, relativeTo: url)?.absoluteURL,
                  MotionArtworkEndpointClient.isAuthorizedScriptAssetURL(next, configuredEndpoint: endpoint, allowedHosts: config.assetHosts ?? [])
            else { throw ScraperError.parseError("Unsupported artwork playlist") }
            if value.complete { return next }
            url = next
        }
        throw ScraperError.parseError("Too many artwork playlists")
    }
    #endif

    private nonisolated static func normalizedArtworkText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Request Execution

    private func parameter(_ name: String, endpoint: EndpointConfig) -> String? {
        config.secrets?[name] ?? ScraperNativeResolvers.protocolParameter(name, format: endpoint.rule?.format)
    }

    private func executeRequest(endpoint: EndpointConfig, vars: [String: String]) async throws -> Data {
        do { try endpoint.validateRules() }
        catch { throw ScraperError.parseError(error.localizedDescription) }
        let data = try await executeRawRequest(endpoint: endpoint, vars: vars)
        let decoded: Data
        if let crypto = endpoint.crypto, crypto["algorithm"] == "aes-128-ecb",
           String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") != true {
            guard let keyName = crypto["keySecret"], let key = parameter(keyName, endpoint: endpoint) else {
                throw ScraperError.parseError("Missing response parameters")
            }
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let encrypted = !text.isEmpty && text.allSatisfy(\.isHexDigit) ? Data(hexString: text) : data
            guard let encrypted, let plain = ScraperNativeResolvers.aes(encrypted, key: key, decrypt: true) else {
                throw ScraperError.parseError("Invalid encrypted response")
            }
            decoded = ScraperNativeResolvers.gunzip(plain) ?? plain
        } else { decoded = data }
        guard let path = endpoint.responsePath else { return decoded }
        guard let value = try ScraperJSONRule(path: path).parse(decoded), JSONSerialization.isValidJSONObject(value) else {
            throw ScraperError.parseError("Invalid response data path")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func executeRawRequest(endpoint: EndpointConfig, vars: [String: String]) async throws -> Data {
        if endpoint.method.uppercased() == "LOCAL" { return Data("{}".utf8) }
        let urlString = Self.enforceHTTPPolicy(Self.applyURLTemplate(endpoint.url, vars: vars), trustDomains: config.sslTrustDomains ?? [])
        guard let url = URL(string: urlString), MotionArtworkServiceResolver.isSafeRemoteURL(url),
              ScraperNetworkScope.origin(url) == ScraperNetworkScope.origin(template: endpoint.url, trustDomains: config.sslTrustDomains ?? []) else {
            throw ScraperError.networkError("Invalid scraper URL")
        }
        let method = endpoint.method.uppercased()
        guard ["GET", "POST"].contains(method) else { throw ScraperError.networkError("Unsupported request method") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = method
        request.allHTTPHeaderFields = endpoint.headers
        var params = endpoint.params?.mapValues { Self.applyTemplate($0, vars: vars) } ?? [:]
        var body = endpoint.bodyTemplate.map { Self.applyJSONTemplate($0, vars: vars) }
        if let sign = endpoint.sign {
            guard let salt = sign["saltSecret"].flatMap({ parameter($0, endpoint: endpoint) }) ?? sign["salt"], !salt.isEmpty else {
                throw ScraperError.parseError("Missing signing parameter")
            }
            let joined = params.keys.sorted().map { $0 + "=" + (params[$0] ?? "") }.joined()
            params[sign["param"] ?? "signature"] = ScraperNativeResolvers.md5(salt + joined + salt)
            request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: sign["clientTimeHeader"] ?? "clienttime")
            if let key = sign["deviceIDSecret"], let value = config.secrets?[key] ?? (key == "requestDeviceID" ? anonymousDeviceID : nil) {
                request.setValue(value, forHTTPHeaderField: "mid")
            }
        }
        if let crypto = endpoint.crypto {
            guard let keyName = crypto["keySecret"], let key = parameter(keyName, endpoint: endpoint),
                  let separatorName = crypto["separatorSecret"], let separator = parameter(separatorName, endpoint: endpoint),
                  let messageTemplate = crypto["messageTemplate"], let plainTemplate = crypto["plainTemplate"],
                  let field = crypto["requestField"] else { throw ScraperError.parseError("Missing request parameters") }
            var values = ["path": crypto["path"] ?? "", "text": body ?? "", separatorName: separator]
            values["digest"] = ScraperNativeResolvers.md5(Self.applyTemplate(messageTemplate, vars: values))
            guard let encrypted = ScraperNativeResolvers.aes(Data(Self.applyTemplate(plainTemplate, vars: values).utf8), key: key, decrypt: false) else {
                throw ScraperError.parseError("Invalid encryption parameters")
            }
            var text = encrypted.map { String(format: "%02x", $0) }.joined()
            if crypto["requestEncoding"] == "hex-upper" { text = text.uppercased() }
            body = Self.applyURLTemplate("{{field}}={{value}}", vars: ["field": field, "value": text])
        }
        if (method == "GET" || endpoint.sign != nil) && !params.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
            request.url = components.url
        } else if body == nil {
            body = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        }
        if method == "POST" {
            request.httpBody = body?.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(endpoint.crypto == nil ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return try await performValidatedRequest(request)
    }

    /// - 429 / 503 读取 Retry-After 抛 `ScraperError.rateLimited`,让 ScraperManager 退避或本轮跳过
    /// - 其它非 2xx 抛 `ScraperError.networkError`,避免把错误页当成正常元数据响应。
    private func performValidatedRequest(_ request: URLRequest) async throws -> Data {
        do { return try await performRequest(request) }
        catch ScraperTransportError.responseTooLarge { throw ScraperError.networkError("Response too large") }
        catch { throw ScraperRequestPool.scraperError(error) }
    }

    private func performRequest(_ original: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        var request = original
        request.allowsExpensiveNetworkAccess = allowExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowExpensiveNetwork
        let executor = await requestPool.executor(for: .custom(config.id))
        let interval = Double(max(0, config.rateLimit ?? 300)) / 1000
        // Manifests may use POST; replay is deliberately left at .never.
        let data = try await executor.execute(minimumInterval: interval) { [sessionManager, request] in
            try await sessionManager.data(for: request)
        }.data
        guard data.count <= Self.maxEndpointResponseBytes else {
            throw ScraperError.networkError("Response too large: \(data.count)B")
        }
        if let validation = LegacyScraperCompatibility.responseValidation(for: config, url: request.url),
           let code = validation.firstFailure(in: data) {
            throw ScraperError.networkError("Scraper API error \(code)")
        }
        return data
    }

    // MARK: - Template Substitution

    /// 把 `{{key}}` 和 `{{key[N]}}` 占位符替换成 vars 里的值。
    ///   - `{{key}}` 整体替换
    ///   - `{{key[N]}}` 把 vars[key] 按 `|` 切分,取第 N 段(0 起);N 越界则空串
    /// 用 `{{key[N]}}` 是为了能从复合 externalId (例如某些源的
    /// `hash|albumId|songname|singer|duration|cover` 格式) 里精确取字段,
    /// 而不是把整串当 keyword 传给服务端。
    nonisolated static func applyTemplate(_ template: String, vars: [String: String]) -> String {
        applyingTemplate(template, vars: vars) { $0 }
    }

    /// Template substitution for placeholders embedded in a URL path/query.
    /// Only RFC 3986 unreserved bytes remain literal, preventing a value from
    /// injecting a second query item or fragment.
    nonisolated static func applyURLTemplate(_ template: String, vars: [String: String]) -> String {
        applyingTemplate(template, vars: vars) { value in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
    }

    /// Escapes substituted values as JSON string contents. The manifest owns
    /// the surrounding JSON syntax (normally `"{{query}}"`).
    nonisolated static func applyJSONTemplate(_ template: String, vars: [String: String]) -> String {
        applyingTemplate(template, vars: vars) { value in
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8),
                  encoded.count >= 2 else { return "" }
            return String(encoded.dropFirst().dropLast())
        }
    }

    nonisolated private static func applyingTemplate(
        _ template: String,
        vars: [String: String],
        transform: (String) -> String
    ) -> String {
        var result = template
        // 先处理带索引的：`{{key[N]}}`
        let indexedPattern = #"\{\{(\w+)\[(\d+)\]\}\}"#
        if let regex = try? NSRegularExpression(pattern: indexedPattern) {
            // 多次扫描直到没有匹配。加迭代上限: 替换值本身若含 `{{key[N]}}` 形式
            // (如某源返回的 externalId = "{{id[0]}}")会不断重新引入匹配, 否则死循环。
            var iterations = 0
            while iterations < 256 {
                iterations += 1
                let nsResult = result as NSString
                let range = NSRange(location: 0, length: nsResult.length)
                guard let match = regex.firstMatch(in: result, range: range),
                      match.numberOfRanges >= 3 else { break }
                let key = nsResult.substring(with: match.range(at: 1))
                let idxStr = nsResult.substring(with: match.range(at: 2))
                let idx = Int(idxStr) ?? 0
                let raw = vars[key] ?? ""
                let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let value = (idx >= 0 && idx < parts.count) ? parts[idx] : ""
                result = nsResult.replacingCharacters(in: match.range, with: transform(value))
            }
        }
        // 再处理整体 `{{key}}`
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: transform(value))
        }
        return result
    }

    private func parse(endpoint: EndpointConfig, data: Data, externalId: String? = nil) throws -> Any? {
        do {
            try endpoint.validateRules()
            return try (endpoint.rule ?? .init()).parse(data, externalID: externalId) { id in
                guard let seed = config.secrets?["coverSeedHex"], let template = config.secrets?["coverUrlTemplate"] else { return nil }
                return ScraperNativeResolvers.coverURL(id: id, seed: seed, template: template)
            }
        } catch { throw ScraperError.parseError(error.localizedDescription) }
    }

    nonisolated private static func buildResourceRequest(
        from urlString: String,
        sourceConfig: ScraperSourceConfig?,
        timeout: TimeInterval
    ) -> URLRequest? {
        let trustDomains = resourceTrustDomains(for: sourceConfig)
        let safeURLString = enforceHTTPPolicy(urlString, trustDomains: trustDomains)
        guard let url = URL(string: safeURLString), MotionArtworkServiceResolver.isSafeRemoteURL(url) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    nonisolated private static func resourceSessionManager(for sourceConfig: ScraperSourceConfig?, session: URLSession?) -> ScraperSessionManager {
        ScraperSessionManager(
            headers: resourceHeaders(for: sourceConfig),
            trustDomains: resourceTrustDomains(for: sourceConfig),
            credentialOrigins: configContext(for: sourceConfig).map { ScraperNetworkScope.credentialOrigins($0.config) } ?? [],
            isResource: true, session: session
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
        // 用户填的 Cookie 在钥匙串里；没填才用清单自带的。
        return (config, ScraperSourceCookieStore.cookie(for: sourceConfig) ?? config.cookie)
    }

    /// Whether `host` matches a trusted domain at a DNS label boundary.
    /// `host == domain` 或 `host` 以 `.domain` 结尾才算匹配，避免
    /// "untrusted-example.com".hasSuffix("example.com") 这类后缀混淆绕过信任校验。
    nonisolated static func host(_ host: String, matchesTrustDomain domain: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty, !normalizedDomain.isEmpty else { return false }
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    /// Whether `host` matches any of `trustDomains` at a DNS label boundary.
    nonisolated static func isTrustedHost(_ host: String, trustDomains: [String]) -> Bool {
        trustDomains.contains { Self.host(host, matchesTrustDomain: $0) }
    }

    /// Only allow HTTP for trusted domains and local network addresses.
    /// All other HTTP URLs are upgraded to HTTPS.
    nonisolated static func enforceHTTPPolicy(_ urlString: String, trustDomains: [String]) -> String {
        guard urlString.hasPrefix("http://") else { return urlString }
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let normalizedHost = normalizedHost(host)

        // Allow HTTP for local network addresses
        if isLocalNetwork(normalizedHost) { return urlString }

        // Allow HTTP for trusted domains
        if isTrustedHost(normalizedHost, trustDomains: trustDomains) { return urlString }

        // Upgrade to HTTPS
        return "https://" + urlString.dropFirst(7)
    }

    /// Check if host is a local network address (IP, .local, private ranges)
    nonisolated static func isLocalNetwork(_ host: String) -> Bool {
        let host = normalizedHost(host)
        if host == "localhost" || host.hasSuffix(".local") { return true }

        if let ipv6 = IPv6Address(host) {
            let bytes = Array(ipv6.rawValue)
            if bytes.count == 16 {
                // ::1, fc00::/7 unique-local, fe80::/10 link-local.
                if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
                if (bytes[0] & 0xfe) == 0xfc { return true }
                if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
            }
            return false
        }

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

    nonisolated private static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        if let zoneIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<zoneIndex])
        }
        return normalized
    }

    nonisolated static func describeNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "localized=\(nsError.localizedDescription)",
        ]

        if let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString {
            parts.append("url=\(redactedURLDescription(URL(string: failingURL)))")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)")
        }

        return parts.joined(separator: " ")
    }

    nonisolated static func redactedURLDescription(_ url: URL?) -> String {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "?"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "?"
    }

}

/// 裸 socket (NWConnection) 明文 HTTP 客户端，绕过 ATS 对公网明文 http 的
/// -1022 拦截。仅供 ATSHTTP 在「公网 + 明文 http」时调用；局域网明文 http
/// 与所有 https 仍走 URLSession 以保留 keep-alive / 证书信任。
enum PlainHTTPClient {
    /// 内存缓冲版 data(for:) 的默认上限（沿用 scraper resource 上限）。
    /// 整文件下载请改用 download(for:) 落盘，避免大文件全量驻留内存。
    static let defaultMaxBytes = ConfigurableScraper.maxResourceResponseBytes

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private var established = false
        private var received = Data()

        /// The TCP connection came up; a reset from here on is the peer
        /// dropping it, not the host being unreachable.
        var isEstablished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return established
        }

        func markEstablished() {
            lock.lock()
            defer { lock.unlock() }
            established = true
        }

        func append(_ data: Data, maxBytes: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard received.count + data.count <= maxBytes else { return false }
            received.append(data)
            return true
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

    private struct ParsedResponseHeader {
        let response: HTTPURLResponse
        let contentLength: Int?
        let isChunked: Bool
    }

    final class DownloadStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private var headerBuffer = Data()
        private var parsedHeader: ParsedResponseHeader?
        private var chunkedDecoder: HTTPChunkedBodyDecoder?
        /// 已写进文件的正文字节数；分块响应按解出的正文算。
        private var bodyBytes = 0
        private var fileHandle: FileHandle?
        private var returnedFile = false
        private var intentionallyTruncatedWholeResponse = false
        private let maximumRangedBodyBytes: Int?
        private let wholeResponsePrefixLimit: Int?
        let fileURL: URL

        init(
            maximumRangedBodyBytes: Int? = nil,
            wholeResponsePrefixLimit: Int? = nil
        ) throws {
            self.maximumRangedBodyBytes = maximumRangedBodyBytes
            self.wholeResponsePrefixLimit = wholeResponsePrefixLimit
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Primuse-HTTP-\(UUID().uuidString).download")
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw ScraperError.networkError("Unable to create HTTP download file")
            }
            fileHandle = try FileHandle(forWritingTo: fileURL)
        }

        func consume(_ data: Data, responseURL: URL) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }

            if parsedHeader == nil {
                headerBuffer.append(data)
                let separator = Data("\r\n\r\n".utf8)
                guard let headerRange = headerBuffer.range(of: separator) else {
                    guard headerBuffer.count <= 64 * 1024 else {
                        throw ScraperError.networkError("HTTP response headers too large")
                    }
                    return false
                }

                let headerData = Data(headerBuffer[..<headerRange.lowerBound])
                let parsed = try PlainHTTPClient.parseResponseHeader(headerData, for: responseURL)
                parsedHeader = parsed
                if parsed.isChunked { chunkedDecoder = HTTPChunkedBodyDecoder() }
                let initialBody = Data(headerBuffer[headerRange.upperBound...])
                headerBuffer.removeAll(keepingCapacity: false)
                if try appendBody(initialBody) { return true }
            } else {
                if try appendBody(data) { return true }
            }

            guard let parsedHeader, !parsedHeader.isChunked,
                  let contentLength = parsedHeader.contentLength else { return false }
            return bodyBytes >= contentLength
        }

        func finalize() throws -> (URL, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            guard let parsedHeader else {
                throw ScraperError.networkError("Invalid HTTP response")
            }
            if let contentLength = parsedHeader.contentLength,
               !parsedHeader.isChunked,
               bodyBytes < contentLength,
               !intentionallyTruncatedWholeResponse {
                throw ScraperError.networkError("Truncated HTTP response")
            }
            if parsedHeader.isChunked,
               chunkedDecoder?.isComplete != true,
               !intentionallyTruncatedWholeResponse {
                throw ScraperError.networkError("Truncated chunked HTTP response")
            }

            if let contentLength = parsedHeader.contentLength,
               !parsedHeader.isChunked,
               bodyBytes > contentLength {
                try fileHandle?.truncate(atOffset: UInt64(contentLength))
            }
            try fileHandle?.close()
            fileHandle = nil
            returnedFile = true
            return (fileURL, parsedHeader.response)
        }

        func markResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }

        func cleanup() {
            lock.lock()
            defer { lock.unlock() }
            try? fileHandle?.close()
            fileHandle = nil
            if !returnedFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        private func appendBody(_ data: Data) throws -> Bool {
            guard !data.isEmpty, let parsedHeader else { return false }
            guard var decoder = chunkedDecoder else {
                return try writeBody(data, header: parsedHeader)
            }

            // 分块正文边收边解：只要前缀时按解出的正文算，够了就停，
            // 不会因为分块就把整首歌、甚至没有尽头的电台流一直收下去。
            var reachedPrefixLimit = false
            do {
                try decoder.append(data) { decoded in
                    guard !reachedPrefixLimit else { return }
                    reachedPrefixLimit = try writeBody(decoded, header: parsedHeader)
                }
            } catch {
                guard reachedPrefixLimit else { throw error }
            }
            chunkedDecoder = decoder
            return reachedPrefixLimit || decoder.isComplete
        }

        private func writeBody(_ data: Data, header: ParsedResponseHeader) throws -> Bool {
            // A metadata head request only needs the requested prefix when a
            // non-compliant server returns HTTP 200 for Range. Stop the socket
            // as soon as that prefix is safely on disk instead of downloading
            // the entire song.
            if header.response.statusCode == 200,
               let wholeResponsePrefixLimit {
                let remaining = max(0, wholeResponsePrefixLimit - bodyBytes)
                if remaining > 0 {
                    let accepted = min(remaining, data.count)
                    try fileHandle?.write(contentsOf: data.prefix(accepted))
                    bodyBytes += accepted
                }
                if bodyBytes >= wholeResponsePrefixLimit {
                    intentionallyTruncatedWholeResponse = header.isChunked
                        || (header.contentLength.map { $0 > bodyBytes } ?? true)
                    return true
                }
                return false
            }

            if let maximumRangedBodyBytes {
                guard maximumRangedBodyBytes >= 0,
                      bodyBytes <= maximumRangedBodyBytes,
                      data.count <= maximumRangedBodyBytes - bodyBytes else {
                    throw ScraperError.networkError("HTTP response too large")
                }
            }
            try fileHandle?.write(contentsOf: data)
            bodyBytes += data.count
            return false
        }
    }

    /// The network cut an exchange off. Carries what the caller sees when the
    /// exchange is not tried again.
    private struct InterruptedExchange: Error {
        let failure: CleartextHTTPExchangeFailure
        let underlying: (any Error)?

        var callerError: any Error {
            underlying ?? ScraperError.networkError(failure.diagnosticDescription)
        }
    }

    /// Queueing this long for a connection slot is worth a diagnostic line.
    private static let noticeableSlotWait: Duration = .seconds(1)

    /// The network cut the exchange off: the connection closed before the
    /// headers or the promised body arrived, or the peer reset it. Unlike an
    /// HTTP status or a body that is not what was asked for, it says nothing
    /// about what the server holds.
    static func isInterruptedExchange(_ error: any Error) -> Bool {
        if case ScraperError.networkError(let message) = error {
            return CleartextHTTPExchangeFailure.allCases.contains { $0.diagnosticDescription == message }
        }
        if CleartextHTTPExchangeFailure.isPeerReset(error) { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost
    }

    static func data(for request: URLRequest, maxBytes: Int = defaultMaxBytes) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url,
              url.scheme == "http",
              let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 80),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw ScraperError.networkError("Invalid HTTP URL: \(request.url?.absoluteString ?? "nil")")
        }

        // Every exchange opens its own TCP connection. Bound how many run at
        // once against one host:port so a scrolling wall of covers does not
        // open a burst of sockets to one server.
        let endpoint = NetworkEndpointIdentity(url: url)?.key ?? "\(host):\(rawPort)"
        let lane: HTTPEndpointConnectionGate.Lane =
            request.value(forHTTPHeaderField: "Range") == nil ? .standard : .media
        let permit = try await HTTPEndpointConnectionGate.shared.acquire(endpoint: endpoint, lane: lane)
        defer { permit.release() }
        if permit.waited >= noticeableSlotWait {
            plog("Cleartext HTTP waited for a connection slot endpoint=\(endpoint) path=\(diagnosticPath(of: url)) "
                + "waited=\(secondsText(permit.waited)) ahead=\(permit.ahead)")
        }

        // URLRequest 默认 timeoutInterval 为 60s; 未显式设置(<= 0)时退回 15s,
        // 与 ScraperSessionManager 的 URLSession timeoutIntervalForRequest 一致。
        // 重试与第一次共用这一份时限。
        let timeout = request.timeoutInterval > 0 && request.timeoutInterval.isFinite
            ? min(request.timeoutInterval, 24 * 60 * 60) : 15
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started + .seconds(timeout)
        let hasBody = request.httpBody != nil || request.httpBodyStream != nil
        var retries = 0
        var firstFailure: CleartextHTTPExchangeFailure?
        while true {
            do {
                let result = try await exchange(
                    request, url: url, host: host, port: port, maxBytes: maxBytes,
                    timeout: seconds(deadline - clock.now)
                )
                if let firstFailure {
                    logRetry(endpoint: endpoint, url: url, first: firstFailure, result: "ok", elapsed: clock.now - started)
                }
                return result
            } catch let interrupted as InterruptedExchange {
                let backoff = CleartextHTTPRetryPolicy.backoff(randomFraction: Double.random(in: 0...1))
                if CleartextHTTPRetryPolicy.shouldRetry(
                    method: request.httpMethod,
                    hasBody: hasBody,
                    failure: interrupted.failure,
                    retriesSoFar: retries,
                    remainingTime: seconds(deadline - clock.now) - backoff
                ) {
                    retries += 1
                    firstFailure = interrupted.failure
                    try await Task.sleep(for: .seconds(backoff))
                    continue
                }
                if let firstFailure {
                    logRetry(endpoint: endpoint, url: url, first: firstFailure,
                             result: interrupted.failure.rawValue, elapsed: clock.now - started)
                }
                throw interrupted.callerError
            } catch {
                if let firstFailure {
                    logRetry(endpoint: endpoint, url: url, first: firstFailure,
                             result: retryResultLabel(error), elapsed: clock.now - started)
                }
                throw error
            }
        }
    }

    /// One request on one fresh connection. A response the network cut off
    /// is thrown as `InterruptedExchange`; everything else as the caller sees it.
    private static func exchange(
        _ request: URLRequest,
        url: URL,
        host: String,
        port: NWEndpoint.Port,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = !request.allowsExpensiveNetworkAccess
        parameters.prohibitConstrainedPaths = !request.allowsConstrainedNetworkAccess
        let connection = NWConnection(host: socketHost(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "Primuse.PlainHTTPClient.\(UUID().uuidString)")
        let method = (request.httpMethod ?? "GET").uppercased()
        // Read here: the receive callbacks run on the socket queue, outside the task.
        let progress = TrustedHTTPTransport.DownloadProgress.observer

        let stateBox = StateBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                @Sendable func finish(_ result: Result<(Data, URLResponse), Error>) {
                    guard stateBox.markResumed() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }

                /// After the connection came up, a reset means the peer
                /// dropped it mid-exchange rather than that it is unreachable.
                @Sendable func fail(_ error: Error) {
                    if stateBox.isEstablished, CleartextHTTPExchangeFailure.isPeerReset(error) {
                        finish(.failure(InterruptedExchange(failure: .resetByPeer, underlying: error)))
                    } else {
                        finish(.failure(error))
                    }
                }

                @Sendable func finishFramed(_ response: Data) {
                    finish(Result { try parseResponse(response, for: url) })
                }

                /// The peer closed the connection: decide from the framing
                /// whether what arrived is the whole response.
                @Sendable func finishAtEndOfStream() {
                    let snapshot = stateBox.snapshot()
                    switch HTTPResponseFramingPolicy.endOfStream(in: snapshot, requestMethod: method) {
                    case .complete(let messageLength):
                        finishFramed(Data(snapshot.prefix(messageLength)))
                    case .closedBeforeResponse:
                        finish(.failure(InterruptedExchange(failure: .closedBeforeResponse, underlying: nil)))
                    case .truncatedBody:
                        finish(.failure(InterruptedExchange(failure: .truncatedBody, underlying: nil)))
                    case .malformed:
                        // The parser names what is wrong (Content-Length, chunk size).
                        finishFramed(snapshot)
                    }
                }

                // 整体超时:连接卡在 .preparing 或服务器接受连接后不回包时,
                // receiveLoop 永不回调,这里兜底 cancel 连接并 finish,避免 continuation
                // 永久挂起及 NWConnection 泄漏。finish 幂等,正常完成后此回调是 no-op。
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(URLError(.timedOut)))
                }

                @Sendable func receiveLoop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error {
                            fail(error)
                            return
                        }

                        if let data, !data.isEmpty {
                            progress?(data.count)
                            guard stateBox.append(data, maxBytes: maxBytes) else {
                                finish(.failure(ScraperError.networkError("HTTP response too large")))
                                return
                            }

                            let snapshot = stateBox.snapshot()
                            if let messageLength = HTTPResponseFramingPolicy.completeMessageLength(
                                in: snapshot, requestMethod: method
                            ) {
                                finishFramed(Data(snapshot.prefix(messageLength)))
                                return
                            }
                        }

                        if isComplete || data?.isEmpty == true {
                            finishAtEndOfStream()
                        } else {
                            receiveLoop()
                        }
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        stateBox.markEstablished()
                        do {
                            let payload = try buildRequestData(for: request)
                            connection.send(content: payload, completion: .contentProcessed { error in
                                if let error {
                                    fail(error)
                                } else {
                                    receiveLoop()
                                }
                            })
                        } catch {
                            finish(.failure(error))
                        }
                    case .failed(let error):
                        fail(error)
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func logRetry(
        endpoint: String, url: URL, first: CleartextHTTPExchangeFailure, result: String, elapsed: Duration
    ) {
        plog("Cleartext HTTP retried endpoint=\(endpoint) path=\(diagnosticPath(of: url)) "
            + "first=\(first.rawValue) result=\(result) elapsed=\(secondsText(elapsed))")
    }

    private static func retryResultLabel(_ error: any Error) -> String {
        if OperationCancellationPolicy.isCancellation(error) { return "cancelled" }
        if (error as? URLError)?.code == .timedOut { return "timedOut" }
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code)"
    }

    /// Path only: query strings carry credentials (Subsonic u/t/s/p, tokens).
    private static func diagnosticPath(of url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard !path.isEmpty else { return "/" }
        return path.count > 96 ? String(path.prefix(96)) + "..." : path
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private static func secondsText(_ duration: Duration) -> String {
        String(format: "%.1fs", seconds(duration))
    }

    /// Disk-backed download for large cleartext responses. The returned file
    /// has the same temporary lifetime contract as URLSession.download(for:).
    static func download(
        for request: URLRequest,
        maximumRangedBodyBytes: Int? = nil,
        wholeResponsePrefixLimit: Int? = nil
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 80),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw ScraperError.networkError("Invalid HTTP URL: \(request.url?.absoluteString ?? "nil")")
        }

        let connection = NWConnection(host: socketHost(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "Primuse.PlainHTTPDownload.\(UUID().uuidString)")
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 300
        let stateBox = try DownloadStateBox(
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit
        )
        // Read here: the receive callbacks run on the socket queue, outside the task.
        let progress = TrustedHTTPTransport.DownloadProgress.observer

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                @Sendable func finish(_ result: Result<(URL, URLResponse), Error>) {
                    guard stateBox.markResumed() else { return }
                    connection.cancel()
                    if case .failure = result { stateBox.cleanup() }
                    continuation.resume(with: result)
                }

                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(URLError(.timedOut)))
                }

                @Sendable func completeDownload() {
                    do {
                        finish(.success(try stateBox.finalize()))
                    } catch {
                        finish(.failure(error))
                    }
                }

                @Sendable func receiveLoop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        if let data, !data.isEmpty { progress?(data.count) }
                        do {
                            if let data, !data.isEmpty,
                               try stateBox.consume(data, responseURL: url) {
                                completeDownload()
                                return
                            }
                        } catch {
                            finish(.failure(error))
                            return
                        }

                        if isComplete || data?.isEmpty == true {
                            completeDownload()
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
                                if let error { finish(.failure(error)) } else { receiveLoop() }
                            })
                        } catch {
                            finish(.failure(error))
                        }
                    case .failed(let error):
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// `URL.host` 在不同 Foundation 版本上对 IPv6 字面量带不带方括号并不一致,
    /// 而 `NWEndpoint.Host("[fd00::1]")` 会当成主机名去做一次永远解析不出来的
    /// DNS 查询。套接字统一拿裸字面量, Host 头统一拿带方括号的形式。
    private static func socketHost(_ rawHost: String) -> NWEndpoint.Host {
        let literal = NetworkHostAuthority.canonicalHost(rawHost)
        if let ipv4 = IPv4Address(literal) { return .ipv4(ipv4) }
        if let ipv6 = IPv6Address(literal) { return .ipv6(ipv6) }
        return .name(literal, nil)
    }

    private static func buildRequestData(for request: URLRequest) throws -> Data {
        guard let url = request.url,
              let host = url.host else {
            throw ScraperError.networkError("Invalid HTTP request URL")
        }

        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath ?? url.path
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let encodedQuery = components?.percentEncodedQuery ?? url.query
        let pathWithQuery = path + (encodedQuery.map { "?\($0)" } ?? "")

        var headers = request.allHTTPHeaderFields ?? [:]
        let bracketedHost = NetworkHostAuthority.urlHost(host)
        headers["Host"] = url.port == nil || url.port == 80 ? bracketedHost : "\(bracketedHost):\(url.port!)"
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
        // 1xx interim heads (100 Continue, 103 Early Hints) come before the real response.
        let finalResponse = responseData.dropFirst(HTTPResponseFramingPolicy.finalResponseOffset(in: responseData))
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = finalResponse.range(of: separator) else {
            throw ScraperError.networkError("Invalid HTTP response")
        }

        let headerData = Data(finalResponse[..<headerRange.lowerBound])
        var body = Data(finalResponse[headerRange.upperBound...])
        let parsedHeader = try parseResponseHeader(headerData, for: url)
        // HEAD, 204 and 304 replies may announce chunked framing without any body.
        if parsedHeader.isChunked, !body.isEmpty {
            body = try decodeChunked(body)
        }
        return (body, parsedHeader.response)
    }

    private static func parseResponseHeader(_ headerData: Data, for url: URL) throws -> ParsedResponseHeader {
        let headerText = String(data: headerData, encoding: .isoLatin1)
            ?? String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ScraperError.networkError("Missing HTTP status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ScraperError.networkError("Invalid HTTP status line: \(statusLine)")
        }

        var headerFields: [String: String] = [:]
        var contentLength: Int?
        var isChunked = false
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headerFields[key], !existing.isEmpty {
                headerFields[key] = "\(existing), \(value)"
            } else {
                headerFields[key] = value
            }
            switch key.lowercased() {
            case "content-length":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw ScraperError.networkError("Invalid Content-Length")
                }
                contentLength = parsed
            case "transfer-encoding":
                isChunked = value.localizedCaseInsensitiveContains("chunked")
            default:
                break
            }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
            throw ScraperError.networkError("Failed to construct HTTPURLResponse")
        }
        return ParsedResponseHeader(response: response, contentLength: contentLength, isChunked: isChunked)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var decoder = HTTPChunkedBodyDecoder()
        var decoded = Data()
        do {
            try decoder.append(data) { decoded.append($0) }
        } catch {
            throw ScraperError.networkError("Invalid chunked body")
        }
        // A body that stops at a chunk boundary without the last chunk must
        // never pass for the whole response.
        guard decoder.isComplete else {
            throw ScraperError.networkError(CleartextHTTPExchangeFailure.truncatedBody.diagnosticDescription)
        }
        return decoded
    }
}

// MARK: - Scraper Session Manager

/// URLSession manager that supports SSL bypass for user-configured trusted domains.
/// SSL 校验完全委托给共享的 `SmartSSLDelegate`(TOFU 钉扎 + 轮换征询),scraper 这里
/// 只保留 enforceHTTPPolicy / isTrustedHost 的 host 策略,不再自己实现证书钉扎逻辑。
private enum ScraperTransportError: Error { case responseTooLarge }

final class ScraperSessionManager: NSObject, @unchecked Sendable {
    private var _session: URLSession!
    private let transportDelegate: ScraperTransportDelegate
    private let credentialOrigins: Set<String>
    private let defaultHeaders: [String: String]
    private let trustDomains: [String]
    private let ownsSession: Bool

    init(headers: [String: String], trustDomains: [String], credentialOrigins: Set<String> = [], isResource: Bool = false, session: URLSession? = nil) {
        self.credentialOrigins = credentialOrigins
        self.transportDelegate = ScraperTransportDelegate(isResource: isResource)
        self.defaultHeaders = headers
        self.trustDomains = trustDomains
        self.ownsSession = session == nil
        super.init()
        if let session {
            _session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        _session = URLSession(configuration: config, delegate: transportDelegate, delegateQueue: nil)
    }

    deinit {
        // 带 delegate 的 URLSession 会强引用其 delegate 直到显式失效。downloadResource
        // 每次刮削资源都新建一个本类实例, 不失效就会在整库刮削时累积泄漏 session +
        // SmartSSLDelegate + 底层 socket。finishTasksAndInvalidate 让在途请求跑完再释放。
        if ownsSession { _session?.finishTasksAndInvalidate() }
    }

    func data(for request: URLRequest, maxBytes: Int = ConfigurableScraper.maxEndpointResponseBytes) async throws -> (Data, URLResponse) {
        var mergedRequest = request
        mergedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (header, value) in defaultHeaders where mergedRequest.value(forHTTPHeaderField: header) == nil {
            mergedRequest.setValue(value, forHTTPHeaderField: header)
        }

        let sendsCredentials = mergedRequest.url.flatMap(ScraperNetworkScope.origin).map { credentialOrigins.contains($0) } ?? false
        if !sendsCredentials {
            for name in (mergedRequest.allHTTPHeaderFields ?? [:]).keys where !ScraperNetworkScope.isPublicHeader(name) {
                mergedRequest.setValue(nil, forHTTPHeaderField: name)
            }
        }
        let scheme = mergedRequest.url?.scheme ?? "?"
        let host = mergedRequest.url?.host ?? "?"
        plog("🔒 ScraperSession: \(scheme)://\(host) trustDomains=\(trustDomains)")

        // HTTP requests must use URLSession.shared (ATS bypass only works with shared/default sessions)
        if scheme == "http" {
            return try await PlainHTTPClient.data(for: mergedRequest, maxBytes: maxBytes)
        }

        do {
            // SSL 校验由 session-level 的 SmartSSLDelegate 统一处理(TOFU 钉扎/轮换征询),
            // 不再传 per-task delegate。
            let (bytes, response) = try await _session.bytes(for: mergedRequest)
            guard response.expectedContentLength <= maxBytes else { throw ScraperTransportError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxBytes else { throw ScraperTransportError.responseTooLarge }
                data.append(byte)
            }
            return (data, response)
        } catch {
            plog("⚠️ Request failed: \(mergedRequest.httpMethod ?? "GET") \(ConfigurableScraper.redactedURLDescription(mergedRequest.url)) \(ConfigurableScraper.describeNetworkError(error))")
            throw error
        }
    }
}

final class ScraperTransportDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let ssl = SmartSSLDelegate()
    private let isResource: Bool
    init(isResource: Bool) { self.isResource = isResource }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await ssl.urlSession(session, didReceive: challenge)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = Int(task.taskDescription ?? "0") ?? 0
        guard count < 5, let source = response.url, let target = request.url else { completionHandler(nil); return }
        task.taskDescription = String(count + 1)
        completionHandler(Self.redirect(request, from: source, to: target, isResource: isResource))
    }
    static func redirect(_ request: URLRequest, from source: URL, to target: URL, isResource: Bool) -> URLRequest? {
        guard MotionArtworkServiceResolver.isSafeRemoteURL(target) else { return nil }
        if HTTPRedirectSecurityPolicy.allows(from: source, to: target) { return request }
        guard isResource, target.scheme?.lowercased() == "https", let host = target.host,
              !ConfigurableScraper.isLocalNetwork(host), ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { return nil }
        var clean = request
        for name in (clean.allHTTPHeaderFields ?? [:]).keys where !ScraperNetworkScope.isPublicHeader(name) {
            clean.setValue(nil, forHTTPHeaderField: name)
        }
        return clean
    }
}

// MARK: - Fixed codecs

enum ScraperNativeResolvers {
    // Fixed, publicly documented protocol constants, not account credentials.
    static func protocolParameter(_ name: String, format: ScraperJSONRule.Format?) -> String? {
        switch (format, name) {
        case (.albumCatalogMotionArtwork, "eapiKey"): "e82ckenh8dichen8"
        case (.albumCatalogMotionArtwork, "eapiSeparator"): "36cd479b6b5"
        case (.hashCatalogMotionArtwork, "requestSalt"): "OIlwieks28dk2k092lksi2UIkp"
        default: nil
        }
    }
    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func aes(_ data: Data, key: String, decrypt: Bool) -> Data? {
        guard let keyData = key.data(using: .utf8), [16, 24, 32].contains(keyData.count),
              data.count <= ConfigurableScraper.maxEndpointResponseBytes else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var count = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                keyData.withUnsafeBytes { key in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key.baseAddress, key.count,
                        nil, source.baseAddress, source.count, destination.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = count
        return output
    }
    static func gunzip(_ data: Data) -> Data? {
        guard data.count <= ConfigurableScraper.maxEndpointResponseBytes else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let status = buffer.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard output.count + count <= ConfigurableScraper.maxEndpointResponseBytes else { return nil }
                output.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { return nil }
            }
        }
    }
    static func coverURL(id: String, seed: String, template: String) -> String? {
        guard !id.isEmpty, let seed = [UInt8](hexString: seed), !seed.isEmpty else { return nil }
        let bytes = Array(id.utf8)
        let mixed = bytes.enumerated().map { $0.element ^ seed[$0.offset % seed.count] }
        let hash = Data(Insecure.MD5.hash(data: Data(mixed))).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return template.replacingOccurrences(of: "{{hash}}", with: hash).replacingOccurrences(of: "{{id}}", with: id)
    }
}
