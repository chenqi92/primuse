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
    nonisolated static let maxEndpointResponseBytes = 5 * 1024 * 1024
    nonisolated static let maxResourceResponseBytes = 20 * 1024 * 1024
    nonisolated static let maxScriptCharacters = 200_000
    /// 单次脚本执行的墙钟上限。JSContext 无公开看门狗 API
    /// (JSContextGroupSetExecutionTimeLimit 是私有符号, 上架会被静态扫描拒),
    /// 因此把执行放到独立线程并在此时限后放弃, 避免 while(true) 挂死 actor。
    nonisolated static let maxScriptExecutionSeconds: TimeInterval = 4

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
        guard data.count <= maxResourceResponseBytes else {
            plog("⚠️ Scraper resource too large: \(data.count)B")
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
        let parsed = try await runScript(endpoint.script, data: data)
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
        let parsed = try await runScript(endpoint.script, data: data, externalId: externalId)

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
        let parsed = try await runScript(endpoint.script, data: data, externalId: externalId)

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
        let parsed = try await runScript(endpoint.script, data: data, externalId: externalId)

        guard let dict = parsed as? [String: Any] else { return nil }

        // === 通用二次请求 + 二进制解密分支 ===
        // 第一步 script 返回 `{_fetchEncryptedLyrics: true, vars: {...}}` 标记后,
        // framework 用 secrets 提供的 URL 模板拉二进制，再用 secrets 提供的
        // magic + xorKey 解密、按相对偏移格式转 A2 LRC。
        //
        // URL 模板、解密 key 都从用户本地的 `<id>.secrets.json` 旁路加载——
        // app 二进制不携带任何平台特定常量。
        if dict["_fetchEncryptedLyrics"] as? Bool == true {
            // vars 支持两种形式:
            // - dict（单个 candidate）: 直接 fetch
            // - array（多个 candidate）: 依次 try, 选 lrcContent 最长的 (有些
            //   源 candidates 按 score 排但 score 高 ≠ 完整, 常出现"官方推荐
            //   4 行残缺, ugc 投稿版才是全曲"的情况)
            if let varsList = dict["vars"] as? [[String: Any]], !varsList.isEmpty {
                plog("🔐 \(config.id) getLyrics → _fetchEncryptedLyrics with \(varsList.count) candidates")
                let result = await fetchBestEncryptedLyrics(varsList: varsList)
                plog("🔐 \(config.id) fetchBestEncryptedLyrics result: hasResult=\(result != nil) lrcLen=\(result?.lrcContent?.count ?? 0)")
                return result
            }
            if let vars = dict["vars"] as? [String: Any] {
                plog("🔐 \(config.id) getLyrics → _fetchEncryptedLyrics with vars=\(vars)")
                let result = await fetchEncryptedLyrics(vars: vars)
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
    private func fetchBestEncryptedLyrics(varsList: [[String: Any]]) async -> ScraperLyricsResult? {
        var best: ScraperLyricsResult?
        var bestLen = 0
        for vars in varsList.prefix(5) {
            guard let result = await fetchEncryptedLyrics(vars: vars) else { continue }
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
    private func fetchEncryptedLyrics(vars: [String: Any]) async -> ScraperLyricsResult? {
        guard let secrets = config.secrets,
              let template = secrets["lyricsFetchUrl"], !template.isEmpty,
              let contentField = secrets["lyricsContentField"], !contentField.isEmpty,
              let magicHex = secrets["lyricsMagicHex"], let magic = Data(hexString: magicHex),
              let xorHex = secrets["lyricsXorKeyHex"], let xorKey = [UInt8](hexString: xorHex)
        else {
            plog("⚠️ Encrypted lyrics: missing secrets, skip")
            return nil
        }

        var urlString = template
        for (k, v) in vars {
            urlString = urlString.replacingOccurrences(of: "{{\(k)}}", with: "\(v)")
        }
        let safe = Self.enforceHTTPPolicy(urlString, trustDomains: config.sslTrustDomains ?? [])
        guard let url = URL(string: safe) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, _) = try await sessionManager.data(for: request)
            guard data.count <= Self.maxEndpointResponseBytes else {
                plog("⚠️ Encrypted lyrics: response too large (\(data.count)B)")
                return nil
            }
            plog("🔐 Encrypted lyrics: fetched \(data.count) bytes from \(safe.prefix(80))")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                plog("⚠️ Encrypted lyrics: response not JSON, head=\(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
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
        } catch {
            plog("⚠️ Encrypted lyrics: network failure \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Request Execution

    private func executeRequest(endpoint: EndpointConfig, vars: [String: String]) async throws -> Data {
        // Rate limiting
        let now = ContinuousClock.now
        let nextAllowed = lastRequestTime?.advanced(by: minInterval) ?? now
        let reservedTime = nextAllowed > now ? nextAllowed : now
        // Reserve the slot before suspending. Otherwise actor reentrancy lets
        // every concurrent caller observe the same old timestamp and wake at
        // once, defeating the configured request interval.
        lastRequestTime = reservedTime
        if reservedTime > now {
            try await Task.sleep(for: now.duration(to: reservedTime))
        }

        // Build URL with variable substitution
        var urlString = endpoint.url
        urlString = Self.applyTemplate(urlString, vars: vars)

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
            request.timeoutInterval = 15

            // Merge endpoint-specific headers
            for (k, v) in endpoint.headers ?? [:] {
                request.setValue(v, forHTTPHeaderField: k)
            }

            if let bodyTemplate = endpoint.bodyTemplate {
                // Use body template with variable substitution
                let body = Self.applyTemplate(bodyTemplate, vars: vars)
                request.httpBody = body.data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if let params = endpoint.params {
                // Build JSON body from params
                var bodyDict: [String: String] = [:]
                for (k, v) in params {
                    bodyDict[k] = Self.applyTemplate(v, vars: vars)
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }

            return try await performValidatedRequest(request)
        } else {
            // GET: params as query items
            var components = URLComponents(string: urlString)
            if let params = endpoint.params {
                var queryItems = components?.queryItems ?? []
                for (k, v) in params {
                    queryItems.append(URLQueryItem(name: k, value: Self.applyTemplate(v, vars: vars)))
                }
                components?.queryItems = queryItems
            }

            guard let url = components?.url else {
                throw ScraperError.networkError("Invalid URL: \(urlString)")
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            for (k, v) in endpoint.headers ?? [:] {
                request.setValue(v, forHTTPHeaderField: k)
            }

            return try await performValidatedRequest(request)
        }
    }

    /// 发请求并校验 HTTP 状态码:
    /// - 2xx 返回 body
    /// - 429 / 503 读取 Retry-After 抛 `ScraperError.rateLimited`,让 ScraperManager 退避或本轮跳过
    /// - 其它非 2xx 抛 `ScraperError.networkError`,避免把错误页/JSON 错误体当成正常响应喂给 JS 脚本(脚本会静默返回空)
    private func performValidatedRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await sessionManager.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            // 非 HTTP 响应(理论上不会出现),按原行为返回 body
            return data
        }
        if (200 ..< 300).contains(http.statusCode) {
            guard data.count <= Self.maxEndpointResponseBytes else {
                throw ScraperError.networkError("Response too large: \(data.count)B")
            }
            return data
        }
        if http.statusCode == 429 || http.statusCode == 503 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            plog("⛔️ \(config.id) HTTP \(http.statusCode) rate limited, retryAfter=\(retryAfter.map(String.init) ?? "?")")
            throw ScraperError.rateLimited(retryAfter: retryAfter)
        }
        plog("⛔️ \(config.id) HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "?")")
        throw ScraperError.networkError("HTTP \(http.statusCode)")
    }

    // MARK: - Template Substitution

    /// 把 `{{key}}` 和 `{{key[N]}}` 占位符替换成 vars 里的值。
    ///   - `{{key}}` 整体替换
    ///   - `{{key[N]}}` 把 vars[key] 按 `|` 切分,取第 N 段(0 起);N 越界则空串
    /// 用 `{{key[N]}}` 是为了能从复合 externalId (例如某些源的
    /// `hash|albumId|songname|singer|duration|cover` 格式) 里精确取字段,
    /// 而不是把整串当 keyword 传给服务端。
    nonisolated static func applyTemplate(_ template: String, vars: [String: String]) -> String {
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
                result = nsResult.replacingCharacters(in: match.range, with: value)
            }
        }
        // 再处理整体 `{{key}}`
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    // MARK: - JavaScript Execution

    private func runScript(_ script: String, data: Data, externalId: String? = nil) async throws -> Any? {
        guard script.count <= Self.maxScriptCharacters else {
            throw ScraperError.parseError("Script too large")
        }
        guard data.count <= Self.maxEndpointResponseBytes else {
            throw ScraperError.parseError("Response too large")
        }
        // 在独立线程上执行 JS, 与墙钟超时竞速。evaluateScript 同步阻塞,
        // 放在 actor 上会被 while(true) 永久挂死整个源; 移出 actor 后即便
        // 脚本死循环, 也只是泄漏一个线程 + 该 JSContext, actor 仍可继续服务。
        let box = try await Self.evaluateScriptOffActor(
            configID: config.id,
            secrets: config.secrets,
            script: script,
            data: data,
            externalId: externalId,
            timeout: Self.maxScriptExecutionSeconds
        )
        return box.value
    }

    /// JS 求值结果跨越 actor / 线程边界。JSValue.toObject() 返回的是
    /// NSString/NSNumber/NSArray/NSDictionary 等 Foundation 值, 求值完成后
    /// 即被丢弃, 不再共享; 用 @unchecked Sendable 盒子安全地穿过隔离边界。
    private struct ResultBox: @unchecked Sendable {
        let value: Any?
    }

    /// 在专用线程执行嵌入式脚本, 超过 `timeout` 秒则放弃等待并抛出 parseError。
    /// 入参全部为 Sendable 值类型, 不捕获 actor, 满足 Swift 6 严格并发。
    nonisolated private static func evaluateScriptOffActor(
        configID: String,
        secrets: [String: String]?,
        script: String,
        data: Data,
        externalId: String?,
        timeout: TimeInterval
    ) async throws -> ResultBox {
        final class Guard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let guardBox = Guard()
        let watchdog = DispatchQueue(label: "Primuse.ScraperJS.watchdog")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResultBox, Error>) in
            // 超时兜底: 时限到则放弃(死循环线程会继续跑直到进程退出, 但无法
            // 用公开 API 安全中断 JSContext; 这是不引私有符号下的合理代价)。
            watchdog.asyncAfter(deadline: .now() + timeout) {
                if guardBox.claim() {
                    plog("⏱️ JS[\(configID)] execution timed out after \(Int(timeout))s, abandoning")
                    continuation.resume(throwing: ScraperError.parseError("Script execution timed out"))
                }
            }

            let thread = Thread {
                let result = Self.runScriptBody(
                    configID: configID,
                    secrets: secrets,
                    script: script,
                    data: data,
                    externalId: externalId
                )
                if guardBox.claim() {
                    continuation.resume(with: result)
                }
            }
            thread.stackSize = 4 * 1024 * 1024
            thread.name = "Primuse.ScraperJS.\(configID)"
            thread.start()
        }
    }

    /// 同步执行脚本体——只在 `evaluateScriptOffActor` 的专用线程上调用。
    nonisolated private static func runScriptBody(
        configID: String,
        secrets: [String: String]?,
        script: String,
        data: Data,
        externalId: String?
    ) -> Result<ResultBox, Error> {
        guard let context = JSContext() else {
            return .failure(ScraperError.parseError("Failed to create JSContext"))
        }

        // Provide console.log for debugging
        let logBlock: @convention(block) (String) -> Void = { msg in
            plog("📜 JS[\(configID)]: \(msg)")
        }
        context.setObject(logBlock, forKeyedSubscript: "log" as NSString)

        ScraperNativeResolvers.register(in: context)

        // 把 config.secrets 注入为 JS 全局 `secrets`，让 JSON 配置可以引用
        // 本地敏感配置（URL 模板 / hash seed 等），而 app 二进制不携带任何
        // 平台特征。secrets 不存在时 JS 端读到 undefined，需要做 null 检查
        // 走 fallback。
        if let secrets, !secrets.isEmpty {
            context.setObject(secrets, forKeyedSubscript: "secrets" as NSString)
        }

        // 注入 JS helper：用 secrets 提供的 seed/template 把任意 id 转成 CDN URL。
        // 如果 secrets 缺字段就返回 null，让 JS 上游 fallback 到 API 直给的 URL。
        context.evaluateScript("""
        function nativeCoverUrl(id) {
          if (!id) return null;
          if (typeof secrets === 'undefined' || !secrets) return null;
          if (!secrets.coverSeedHex || !secrets.coverUrlTemplate) return null;
          return nativeResolver.xorMd5UrlHash(String(id), secrets.coverSeedHex, secrets.coverUrlTemplate);
        }
        """)

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
                    plog("🔧 JSON fallback parse failed for \(configID), first 200: \(text.prefix(200))")
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
            plog("📜 JS error[\(configID)]: \(exception?.toString() ?? "unknown")")
        }

        // Execute script — wrap in IIFE if not already
        let wrappedScript: String
        if script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(") {
            wrappedScript = script
        } else {
            wrappedScript = "(function() { \(script) })()"
        }

        guard let result = context.evaluateScript(wrappedScript) else {
            return .failure(ScraperError.parseError("Script returned nil"))
        }

        if result.isUndefined || result.isNull {
            return .success(ResultBox(value: nil))
        }

        return .success(ResultBox(value: result.toObject()))
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

    /// Whether `host` matches a trusted domain at a DNS label boundary.
    /// `host == domain` 或 `host` 以 `.domain` 结尾才算匹配，避免
    /// "evil-kugou.com".hasSuffix("kugou.com") 这类后缀混淆绕过信任校验。
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
            parts.append("url=\(failingURL)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)")
        }

        return parts.joined(separator: " ")
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
        private var received = Data()

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

    static func data(for request: URLRequest, maxBytes: Int = defaultMaxBytes) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.scheme == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw ScraperError.networkError("Invalid HTTP URL: \(request.url?.absoluteString ?? "nil")")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "Primuse.PlainHTTPClient.\(UUID().uuidString)")

        // URLRequest 默认 timeoutInterval 为 60s; 未显式设置(<= 0)时退回 15s,
        // 与 ScraperSessionManager 的 URLSession timeoutIntervalForRequest 一致。
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 15

        return try await withCheckedThrowingContinuation { continuation in
            let stateBox = StateBox()

            @Sendable func finish(_ result: Result<(Data, URLResponse), Error>) {
                guard stateBox.markResumed() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            // 整体超时:连接卡在 .preparing 或服务器接受连接后不回包时,
            // receiveLoop 永不回调,这里兜底 cancel 连接并 finish,避免 continuation
            // 永久挂起及 NWConnection 泄漏。finish 幂等,正常完成后此回调是 no-op。
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(ScraperError.networkError("HTTP request timed out after \(Int(timeout))s")))
            }

            @Sendable func receiveLoop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }

                    if let data, !data.isEmpty {
                        guard stateBox.append(data, maxBytes: maxBytes) else {
                            finish(.failure(ScraperError.networkError("HTTP response too large")))
                            return
                        }
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

    /// 落盘版下载：边收边写临时文件，避免整文件全量驻留内存（整曲可达数十~
    /// 上百 MB）。返回 (tempURL, URLResponse)，与 URLSession.download(for:)
    /// 的语义一致——调用方负责把 tempURL move 到目标位置并清理。
    static func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (data, response) = try await data(for: request, maxBytes: .max)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primuse_plainhttp_\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        return (tempURL, response)
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

/// URLSession manager that supports SSL bypass for user-configured trusted domains.
/// SSL 校验完全委托给共享的 `SmartSSLDelegate`(TOFU 钉扎 + 轮换征询),scraper 这里
/// 只保留 enforceHTTPPolicy / isTrustedHost 的 host 策略,不再自己实现证书钉扎逻辑。
final class ScraperSessionManager: NSObject, @unchecked Sendable {
    private var _session: URLSession!
    private let sslDelegate = SmartSSLDelegate()
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
        _session = URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)
    }

    deinit {
        // 带 delegate 的 URLSession 会强引用其 delegate 直到显式失效。downloadResource
        // 每次刮削资源都新建一个本类实例, 不失效就会在整库刮削时累积泄漏 session +
        // SmartSSLDelegate + 底层 socket。finishTasksAndInvalidate 让在途请求跑完再释放。
        _session?.finishTasksAndInvalidate()
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
            // SSL 校验由 session-level 的 SmartSSLDelegate 统一处理(TOFU 钉扎/轮换征询),
            // 不再传 per-task delegate。
            return try await _session.data(for: mergedRequest)
        } catch {
            plog("⚠️ Request failed: \(mergedRequest.httpMethod ?? "GET") \(mergedRequest.url?.absoluteString ?? "?") \(ConfigurableScraper.describeNetworkError(error))")
            throw error
        }
    }
}

// MARK: - Native Resolvers

/// Swift-side helpers exposed to scraper JavaScript via the `nativeResolver` global.
/// 通用算法工具集——任何平台特定常量（seed / URL / key）都不在本文件出现，
/// 由 JSON 配置的 `secrets` 字段动态注入。
enum ScraperNativeResolvers {
    static func register(in context: JSContext) {
        context.evaluateScript("var nativeResolver = nativeResolver || {};")
        guard let resolver = context.objectForKeyedSubscript("nativeResolver") else { return }

        // 通用：input → XOR(seed) → MD5 → URL-safe base64 → 套用 URL 模板。
        // urlTemplate 占位符：{{hash}}（base64 后的 MD5）, {{id}}（原始 input）
        let xorMd5UrlHashBlock: @convention(block) (Any?, Any?, Any?) -> String? = {
            inputArg, seedHexArg, templateArg in
            guard let input = stringValue(inputArg), !input.isEmpty,
                  let seedHex = stringValue(seedHexArg), let seed = [UInt8](hexString: seedHex), !seed.isEmpty,
                  let template = stringValue(templateArg), !template.isEmpty else {
                return nil
            }
            let src = Array(input.utf8)
            var mixed = [UInt8](repeating: 0, count: src.count)
            for i in 0..<src.count {
                mixed[i] = src[i] ^ seed[i % seed.count]
            }
            let digest = Insecure.MD5.hash(data: mixed)
            let hash = Data(digest).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
            return template
                .replacingOccurrences(of: "{{hash}}", with: hash)
                .replacingOccurrences(of: "{{id}}", with: input)
        }
        resolver.setObject(xorMd5UrlHashBlock, forKeyedSubscript: "xorMd5UrlHash" as NSString)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
