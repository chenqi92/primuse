import Foundation
import PrimuseKit

/// 百度网盘 Source — 使用百度开放平台 REST API
///
/// 注意：百度 xpan API 永远返回 HTTP 200，错误信息在 body 的 errno 里。
/// 必须显式检查 errno，否则错误会被静默吞掉（list 字段缺失 → 返回空数组 → 扫描 0 首）。
actor BaiduPanSource: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://pan.baidu.com"
    private static let oauthBase = "https://openapi.baidu.com/oauth/2.0"

    /// 单文件夹分页大小。百度 list 接口最大 1000。
    private static let pageSize = 1000

    /// 频控退避：每次 listFiles 之间至少间隔这么久，避免 errno 31034。
    /// 百度 file/list 免费档大约 5-10 QPS。100ms 留出 10 QPS 上限，
    /// 实测无 31034 命中；如果撞到了 31034 退避会自动兜底。
    private static let minRequestInterval: TimeInterval = 0.1

    /// errno 31034 命中时最多重试次数（指数退避）
    private static let rateLimitMaxRetries = 4

    /// 解析过的 dlink 缓存有效期。百度 dlink 实际有效 ~8 小时，但保守
    /// 一点用 30 分钟——避免 token 刷新或服务端策略变化时拿到老链接。
    /// 对一次播放来说远超够用：5MB 的歌按 256KB 一块拉 20 次，全程
    /// 命中缓存，省下 38 次 list/filemetas API 调用。
    private static let dlinkTTL: TimeInterval = 30 * 60

    private var lastRequestAt: Date?

    /// path → (dlink, expiry). Reset on token refresh because the access
    /// token is appended to the dlink at request time, but the dlink
    /// itself is signed for the user account; existing entries stay valid.
    private var dlinkCache: [String: (url: String, expiresAt: Date)] = [:]

    /// path → (resolved CDN URL, expiry). The CDN URL is the 302 target of
    /// the dlink (host typically `d.pcs.baidu.com`), pre-signed and good
    /// for the dlink's lifetime. We resolve it once via HEAD and pin it so
    /// subsequent range GETs go straight to the CDN with our `pan.baidu.com`
    /// UA — URLSession does NOT preserve custom headers across the
    /// `pan.baidu.com → d.pcs.baidu.com` cross-origin redirect, so the
    /// auto-followed GET would otherwise hit the CDN with the default
    /// `CFNetwork/...` UA and 403.
    private var cdnURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    /// Concurrent fetchRange callers that arrive while the CDN URL is being
    /// resolved should share the same in-flight HEAD instead of issuing N
    /// parallel HEADs (which would themselves stampede Baidu).
    private var cdnURLResolveTasks: [String: Task<URL, Error>] = [:]

    /// path → cooldown-until-this-time. After a 403/410 from a fresh
    /// dlink, refuse to re-resolve for `dlinkRetryCooldown` seconds —
    /// otherwise CloudPlaybackSource's prefetch-ahead spawns parallel
    /// `fetchRange` Tasks per chunk, each failure triggers another
    /// `invalidate + getDlink` chain, and Baidu's anti-abuse system
    /// rate-limits the account globally (then even the dlink-resolve
    /// API starts returning 403 — observed in production as a 1+
    /// minute "no sound after tap" window plus a logged storm).
    private var dlinkRetryCooldownUntil: [String: Date] = [:]
    private static let dlinkRetryCooldown: TimeInterval = 30

    /// Required for any dlink fetch (range or full download). See
    /// `rangeRequestUsingCachedDlink` — Baidu's CDN refuses or throttles
    /// to ~10KB/s otherwise, mimicking what alist & openlist's official
    /// driver pin verbatim ("pan.baidu.com").
    private static let dlinkUserAgent = "pan.baidu.com"
    private static let dlinkReferer = "https://pan.baidu.com/"

    /// dir → (full paginated listing, expiry).
    /// Lets backfill skip the file/list call entirely for songs that share
    /// a directory with a previously-resolved song. For a typical album
    /// folder of 10-20 tracks this turns "20 list calls + 20 filemetas"
    /// into "1 list call + 20 filemetas" — and during backfill of a
    /// 2200-song library, dropping ~2000 redundant list calls is what
    /// cuts the throughput floor from minutes/song to seconds/song.
    private var dirListingCache: [String: (entries: [[String: Any]], expiresAt: Date)] = [:]
    /// 5 min: long enough to amortize across a backfill batch, short
    /// enough that a user who adds files to Baidu sees them re-listed.
    private static let dirListingTTL: TimeInterval = 5 * 60

    /// Lazy-load 标志:第一次 dlink/cdnURL 读写时从磁盘 load 一次。
    /// 不能在 init 里做(actor init 不能 await)。
    private var didLoadPersistedDlinks = false

    /// Debounced save task。命中频繁的播放会触发多次 cache 写入,
    /// 用 2s 节流避免每次都写盘。
    private var dlinkPersistTask: Task<Void, Never>?

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    // MARK: - Persisted dlink cache

    /// 持久化条目。dlink 和 cdnURL 共享 expiresAt(取两者较晚者)。
    /// 启动时同时 load,跳过 cold-start 第一首歌的 300-800ms dlink resolve。
    private struct PersistedDlinkEntry: Codable {
        let path: String
        let dlink: String?
        let cdnURL: String?
        let expiresAt: Date
    }

    private var dlinkPersistFileURL: URL {
        helper.cacheDirectory.appendingPathComponent("dlink_cache.json")
    }

    /// 第一次访问 dlink/cdnURL 时从 disk load。expired 的条目跳过。
    private func loadPersistedDlinksIfNeeded() {
        guard !didLoadPersistedDlinks else { return }
        didLoadPersistedDlinks = true

        let url = dlinkPersistFileURL
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([PersistedDlinkEntry].self, from: data) else {
            plog("⚠️ Baidu dlink cache decode failed at \(url.path)")
            return
        }
        let now = Date()
        var loadedDlink = 0
        var loadedCdn = 0
        for entry in entries where entry.expiresAt > now {
            if let dlink = entry.dlink {
                dlinkCache[entry.path] = (dlink, entry.expiresAt)
                loadedDlink += 1
            }
            if let cdnStr = entry.cdnURL, let url = URL(string: cdnStr) {
                cdnURLCache[entry.path] = (url, entry.expiresAt)
                loadedCdn += 1
            }
        }
        plog("☁️ Baidu loaded persisted dlink cache: \(loadedDlink) dlinks, \(loadedCdn) CDN URLs (\(entries.count - loadedDlink) expired skipped)")
    }

    /// Debounce 2s 后写盘。频繁刮削 / 播放时多次触发只写一次。
    private func scheduleDlinkPersist() {
        dlinkPersistTask?.cancel()
        dlinkPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.persistDlinksNow()
        }
    }

    private func persistDlinksNow() {
        let now = Date()
        var entries: [PersistedDlinkEntry] = []
        let allPaths = Set(dlinkCache.keys).union(cdnURLCache.keys)
        for path in allPaths {
            let dlinkEntry = dlinkCache[path]
            let cdnEntry = cdnURLCache[path]
            let expiresAt = max(
                dlinkEntry?.expiresAt ?? .distantPast,
                cdnEntry?.expiresAt ?? .distantPast
            )
            guard expiresAt > now else { continue }
            entries.append(PersistedDlinkEntry(
                path: path,
                dlink: dlinkEntry?.url,
                cdnURL: cdnEntry?.url.absoluteString,
                expiresAt: expiresAt
            ))
        }
        let url = dlinkPersistFileURL
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
            plog("☁️ Baidu persisted \(entries.count) dlink entries to \(url.lastPathComponent)")
        } catch {
            plog("⚠️ Baidu failed to persist dlink cache: \(error.localizedDescription)")
        }
    }

    func connect() async throws { _ = try await getToken() }

    /// `xpan/nas?method=uinfo` returns the Baidu Pan user record. The
    /// stable account identifier is `uk` (an Int64 user key, distinct
    /// from the device id `device_id`). Routed through `callAPI` so it
    /// inherits the throttle, errno, and 31034 retry handling.
    func accountIdentifier() async throws -> String {
        let json = try await callAPI(
            base: "https://pan.baidu.com/rest/2.0/xpan/nas",
            queryItems: [.init(name: "method", value: "uinfo")]
        )
        if let uk = json["uk"] as? Int64 { return String(uk) }
        if let uk = json["uk"] as? Int { return String(uk) }
        if let uk = json["uk"] as? String, !uk.isEmpty { return uk }
        plog("⚠️ Baidu accountIdentifier: missing 'uk' in response: \(json)")
        throw CloudDriveError.invalidResponse
    }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let dir = path.isEmpty ? "/" : path
        var all: [RemoteFileItem] = []
        var start = 0
        plog("☁️ Baidu listFiles dir=\(dir)")
        // 翻页：单文件夹超过 pageSize 时继续取，直到返回 < pageSize 为止
        while true {
            let page = try await listFilesPage(dir: dir, start: start)
            all.append(contentsOf: page)
            if page.count < Self.pageSize { break }
            start += Self.pageSize
        }
        plog("☁️ Baidu listFiles dir=\(dir) → \(all.count) items (\(all.filter{$0.isDirectory}.count) dirs)")
        return all
    }

    private func listFilesPage(dir: String, start: Int) async throws -> [RemoteFileItem] {
        let json = try await callAPI(
            base: "\(Self.apiBase)/rest/2.0/xpan/file",
            queryItems: [
                .init(name: "method", value: "list"),
                .init(name: "dir", value: dir),
                .init(name: "order", value: "name"),
                .init(name: "start", value: String(start)),
                .init(name: "limit", value: String(Self.pageSize)),
            ]
        )
        guard let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let p = item["path"] as? String,
                  let name = item["server_filename"] as? String else { return nil }
            let isDir = (item["isdir"] as? Int ?? 0) == 1
            let size = item["size"] as? Int64 ?? 0
            // Baidu's list API returns md5 for files. Use it as the
            // content fingerprint so re-scan can detect overwrites with
            // the same size (modifiedDate isn't surfaced here either).
            let md5 = item["md5"] as? String
            return RemoteFileItem(name: name, path: p, isDirectory: isDir, size: size, modifiedDate: nil, revision: md5)
        }
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let data = try await downloadFile(at: path)
        try helper.cacheData(data, for: path)
        return helper.cachedURL(for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        // Pre-check cooldown BEFORE any network I/O. Without this, every
        // serve()/prefetch hammers Baidu with a fresh HTTP request just to
        // catch the 403 inside the do/catch — observed as 100+ HTTP
        // requests / 500ms when SFB drives parallel reads on a bad path.
        if let cooldownUntil = dlinkRetryCooldownUntil[path], cooldownUntil > Date() {
            throw CloudDriveError.apiError(403, "Range request failed (cooldown)")
        }
        do {
            let data = try await rangeRequestUsingCachedCdnURL(path: path, offset: offset, length: length)
            clearRetryCooldown(for: path)
            return data
        } catch CloudDriveError.apiError(let code, _) where code == 401 || code == 403 || code == 410 {
            // Re-check: another suspended task may have set the cooldown
            // while we were in flight. If so, fail fast — don't burn a
            // second HTTP request on a known-bad path.
            if let cooldownUntil = dlinkRetryCooldownUntil[path], cooldownUntil > Date() {
                throw CloudDriveError.apiError(code, "Range request failed (cooldown)")
            }
            plog("⚠️ Baidu fetchRange got HTTP \(code) for \(path) — invalidating CDN+dlink, retrying once (then 30s cooldown)")
            invalidateCdnURL(for: path)
            invalidateDlink(for: path)
            dlinkRetryCooldownUntil[path] = Date().addingTimeInterval(Self.dlinkRetryCooldown)
            return try await rangeRequestUsingCachedCdnURL(path: path, offset: offset, length: length)
        }
    }

    /// Range GET via the cached CDN URL (the 302 destination of the
    /// `pan.baidu.com` dlink). Resolving once and pinning the resolved CDN
    /// URL avoids relying on URLSession to preserve `User-Agent` across the
    /// cross-origin redirect — which it does NOT do reliably for
    /// `pan.baidu.com → d.pcs.baidu.com`, leaving the redirected GET with
    /// the default `CFNetwork/...` UA and a 403 from Baidu's CDN.
    /// This mirrors alist's `linkOfficial`: HEAD with no-redirect, ship
    /// the Location to the client, range GET it directly with the UA.
    private func rangeRequestUsingCachedCdnURL(path: String, offset: Int64, length: Int64) async throws -> Data {
        plog("☁️ Baidu fetchRange entry path=\(path) offset=\(offset) length=\(length)")
        let cdnURL = try await getCdnURL(for: path)
        plog("☁️ Baidu fetchRange got CDN URL for \(path) → \(cdnURL.host ?? "?")\(cdnURL.path.prefix(80))")
        let data = try await helper.rangeRequest(
            url: cdnURL,
            offset: offset,
            length: length,
            userAgent: Self.dlinkUserAgent,
            referer: Self.dlinkReferer
        )
        plog("☁️ Baidu fetchRange got \(data.count) bytes for \(path) [offset=\(offset)]")
        return data
    }

    private func invalidateDlink(for path: String) {
        dlinkCache.removeValue(forKey: path)
        scheduleDlinkPersist()
    }

    private func invalidateCdnURL(for path: String) {
        cdnURLCache.removeValue(forKey: path)
        cdnURLResolveTasks[path]?.cancel()
        cdnURLResolveTasks[path] = nil
        scheduleDlinkPersist()
    }

    /// Resolve `path` to a pre-signed CDN URL by HEAD-ing the dlink with
    /// `User-Agent: pan.baidu.com` and reading the 302 `Location` header.
    /// Cached for `dlinkTTL` (matches the dlink lifetime — once dlink is
    /// stale the CDN sig also is).
    private func getCdnURL(for path: String) async throws -> URL {
        loadPersistedDlinksIfNeeded()
        if let cached = cdnURLCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        if let inFlight = cdnURLResolveTasks[path] {
            return try await inFlight.value
        }
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CloudDriveError.invalidResponse }
            return try await self.resolveCdnURL(for: path)
        }
        cdnURLResolveTasks[path] = task
        defer { cdnURLResolveTasks[path] = nil }
        let resolved = try await task.value
        cdnURLCache[path] = (resolved, Date().addingTimeInterval(Self.dlinkTTL))
        scheduleDlinkPersist()
        return resolved
    }

    private func resolveCdnURL(for path: String) async throws -> URL {
        plog("☁️ Baidu resolveCdnURL start path=\(path)")
        let dlink = try await getDlink(for: path)
        let token = try await getToken()
        guard let dlinkURL = URL(string: "\(dlink)&access_token=\(token)") else {
            throw CloudDriveError.invalidResponse
        }
        plog("☁️ Baidu resolveCdnURL HEAD \(dlinkURL.host ?? "?")\(dlinkURL.path.prefix(80))")
        var head = URLRequest(url: dlinkURL)
        head.httpMethod = "HEAD"
        head.setValue(Self.dlinkUserAgent, forHTTPHeaderField: "User-Agent")
        head.setValue(Self.dlinkReferer, forHTTPHeaderField: "Referer")
        head.timeoutInterval = 30

        // Don't auto-follow redirects — we want the Location header.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: head)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        plog("☁️ Baidu resolveCdnURL HEAD status=\(http.statusCode) for \(path)")
        // 302 → location is the CDN URL. 200 means no redirect (rare,
        // some test paths) — dlink itself is the CDN URL.
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            guard let loc = http.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: loc, relativeTo: dlinkURL)?.absoluteURL else {
                throw CloudDriveError.invalidResponse
            }
            plog("☁️ Baidu resolveCdnURL → \(url.host ?? "?")\(url.path.prefix(80))")
            return url
        case 200:
            return dlinkURL
        default:
            plog("⚠️ Baidu dlink HEAD returned HTTP \(http.statusCode) for \(path)")
            throw CloudDriveError.apiError(http.statusCode, "dlink HEAD failed")
        }
    }

    /// Clear cooldown markers — used after a successful range request
    /// (path is healthy again) and on token refresh (new auth might fix
    /// the underlying 403). Not currently called automatically; cleanup
    /// happens passively after the cooldown expires.
    private func clearRetryCooldown(for path: String) {
        dlinkRetryCooldownUntil.removeValue(forKey: path)
    }

    // MARK: - Private

    private func downloadFile(at path: String) async throws -> Data {
        let token = try await getToken()
        let dlink = try await getDlink(for: path)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        guard let url = URL(string: "\(dlink)&access_token=\(token)") else {
            throw CloudDriveError.invalidResponse
        }
        var request = URLRequest(url: url)
        // Same UA pinning as range path — Baidu throttles / 403s without it.
        request.setValue(Self.dlinkUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.dlinkReferer, forHTTPHeaderField: "Referer")
        let (fileData, _) = try await URLSession(configuration: config).data(for: request)
        return fileData
    }

    /// Resolve a remote path to a Baidu dlink URL (without access_token suffix).
    /// Cached at two levels:
    /// - `dlinkCache[path]` — once we have a dlink, reuse it for `dlinkTTL`
    /// - `dirListingCache[dir]` — when we have to look up `fs_id`, the
    ///   directory listing is shared with any sibling song that needs
    ///   resolution within `dirListingTTL`
    private func getDlink(for path: String) async throws -> String {
        loadPersistedDlinksIfNeeded()
        if let cached = dlinkCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent

        let entries = try await listEntries(in: dir)
        guard let entry = entries.first(where: { ($0["server_filename"] as? String) == name }),
              let fsId = entry["fs_id"] as? Int64 else {
            throw CloudDriveError.fileNotFound(path)
        }

        let metaJson = try await callAPI(
            base: "\(Self.apiBase)/rest/2.0/xpan/multimedia",
            queryItems: [
                .init(name: "method", value: "filemetas"),
                .init(name: "fsids", value: "[\(fsId)]"),
                .init(name: "dlink", value: "1"),
            ]
        )
        guard let metas = metaJson["list"] as? [[String: Any]],
              let dlink = metas.first?["dlink"] as? String else {
            throw CloudDriveError.fileNotFound(path)
        }
        dlinkCache[path] = (dlink, Date().addingTimeInterval(Self.dlinkTTL))
        scheduleDlinkPersist()
        return dlink
    }

    /// Returns the full paginated entries of a directory, cached briefly
    /// so concurrent dlink lookups for sibling songs share one list call.
    private func listEntries(in dir: String) async throws -> [[String: Any]] {
        if let cached = dirListingCache[dir], cached.expiresAt > Date() {
            return cached.entries
        }
        var all: [[String: Any]] = []
        var start = 0
        while true {
            let json = try await callAPI(
                base: "\(Self.apiBase)/rest/2.0/xpan/file",
                queryItems: [
                    .init(name: "method", value: "list"),
                    .init(name: "dir", value: dir),
                    .init(name: "start", value: String(start)),
                    .init(name: "limit", value: String(Self.pageSize)),
                ]
            )
            let entries = json["list"] as? [[String: Any]] ?? []
            all.append(contentsOf: entries)
            if entries.count < Self.pageSize { break }
            start += Self.pageSize
        }
        dirListingCache[dir] = (all, Date().addingTimeInterval(Self.dirListingTTL))
        return all
    }

    /// 统一封装百度 API 调用：节流 + errno 检查 + 31034 退避重试。
    /// queryItems 不要包含 access_token，本方法会自动附加最新 token。
    private func callAPI(
        base: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        var attempt = 0
        var backoff: TimeInterval = 0.5
        while true {
            try await throttle()
            let token = try await getToken()
            var components = URLComponents(string: base)!
            components.queryItems = queryItems + [.init(name: "access_token", value: token)]
            guard let url = components.url else { throw CloudDriveError.invalidResponse }

            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                plog("☁️ Baidu HTTP \(http.statusCode) url=\(base) body=\(body.prefix(500))")
                throw CloudDriveError.apiError(http.statusCode, body)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let errno = (json["errno"] as? Int) ?? 0
            if errno == 0 {
                return json
            }

            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            plog("☁️ Baidu errno=\(errno) attempt=\(attempt) url=\(base) body=\(bodyPreview)")

            // 31034: 接口频次超限 — 退避重试
            if errno == 31034, attempt < Self.rateLimitMaxRetries {
                plog("☁️ Baidu rate-limited, backoff \(backoff)s and retry")
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff *= 2
                attempt += 1
                continue
            }

            let msg = (json["errmsg"] as? String) ?? humanReadable(errno: errno)
            throw CloudDriveError.apiError(errno, msg)
        }
    }

    private func throttle() async throws {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let wait = Self.minRequestInterval - elapsed
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    private func humanReadable(errno: Int) -> String {
        switch errno {
        case -6: return "access_token 无效或未授权 netdisk scope (errno -6)"
        case 2: return "参数错误 (errno 2)"
        case 111: return "access_token 已过期 (errno 111)"
        case 31034: return "接口请求频次超限 (errno 31034)"
        case 42213: return "目录参数非法 (errno 42213)"
        default: return "百度网盘 errno \(errno)"
        }
    }

    private func getToken() async throws -> String {
        guard var tokens = await helper.tokenManager.getTokens() else { throw CloudDriveError.notAuthenticated }
        if tokens.isExpired {
            tokens = try await refreshToken(tokens)
            await helper.tokenManager.saveTokens(tokens)
        }
        return tokens.accessToken
    }

    private func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = await helper.tokenManager.getAppCredentials()
        guard let cid = creds?.clientId else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var c = URLComponents(string: "\(Self.oauthBase)/token")!
        c.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: rt), .init(name: "client_id", value: cid), .init(name: "client_secret", value: creds?.clientSecret ?? "")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let err = json["error"] as? String {
            throw CloudDriveError.tokenRefreshFailed("\(err): \(json["error_description"] as? String ?? "")")
        }
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "\(oauthBase)/authorize",
            tokenURL: "\(oauthBase)/token",
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: ["basic", "netdisk"],
            redirectURI: "https://baidu.callback.welape.com/",
            scopeSeparator: ",",
            usesPKCE: false,
            // 百度不支持自定义 scheme，redirect_uri 必须 https，
            // 由 baidu.callback.welape.com 上的中转页 JS 跳回 primuse:// 让 App 收到 code。
            explicitCallbackScheme: CloudOAuthConfig.callbackScheme
        )
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
