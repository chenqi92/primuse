import Foundation
import PrimuseKit

/// 用户自填的歌词 API 服务器（音流「自定义 API」/ LrcApi 事实标准）：
/// `GET <地址>?title=&artist=&album=&duration=`，可选 `Authorization` 头。
///
/// 地址不设限制：不做 http→https 升级，不拒绝任何主机（用户明确要求，App 的 ATS 已全开）。
actor LyricsAPIServerScraper: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lyricsServer

    private let servers: [LyricsAPIServer]
    private let session: URLSession
    private let requestPool: ScraperRequestPool

    init(
        servers: [LyricsAPIServer], session: URLSession? = nil,
        requestPool: ScraperRequestPool = .shared
    ) {
        self.servers = servers
        self.requestPool = requestPool
        self.session = session ?? Self.makeSession()
    }

    func isCoolingDown() async -> Bool {
        guard !servers.isEmpty else { return false }
        for server in servers {
            if await !requestPool.isCoolingDown(for: ScraperRequestPool.lyricsKey(server.address)) { return false }
        }
        return true
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .empty(.lyricsServer) // 只提供歌词
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        nil
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        []
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        // externalId format: title|artist|album|duration（与 LRCLIB 相同）
        let parts = externalId.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard let title = parts.first, !title.isEmpty else { return nil }
        let artist = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let album = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let duration = parts.count > 3 ? TimeInterval(parts[3]) : nil
        return try await fetchLyrics(title: title, artist: artist, album: album, duration: duration)
    }

    /// 按列表顺序逐个请求，找到即停。
    /// - 有服务器返回歌词 → 返回该结果；
    /// - 有服务器限流 → 抛出限流, 不被别的服务器的「没有」盖住；
    /// - 有服务器明确说没有 → nil, 别的服务器宕机不算这个源失败(否则连着几首就把能用的那台一起熔断)；
    /// - 全都出错 → 抛出第一个错误。
    func fetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> ScraperLyricsResult? {
        guard !servers.isEmpty else { return nil }

        var sawNotFound = false
        var firstError: (any Error)?
        var rateLimit: (any Error)?

        for server in servers {
            try Task.checkCancellation()
            switch await Self.query(
                server: server, session: session, requestPool: requestPool,
                title: title, artist: artist, album: album, duration: duration
            ) {
            case .lyrics(let lrc, let plain):
                return ScraperLyricsResult(source: .lyricsServer, lrcContent: lrc, plainText: plain)
            case .notFound:
                sawNotFound = true
            case .failed(let error):
                if Self.isCancellation(error) { throw error }
                if rateLimit == nil, case .rateLimited? = error as? ScraperError { rateLimit = error }
                if firstError == nil { firstError = error }
            }
        }

        try Task.checkCancellation()
        if let rateLimit { throw rateLimit }
        if sawNotFound { return nil }
        if let firstError { throw firstError }
        return nil
    }

    // MARK: - Shared request path

    enum QueryOutcome: Sendable {
        case lyrics(lrc: String?, plain: String?)
        case notFound
        case failed(any Error)
    }

    /// Authorization 凭据从哪来。正常刮削每次请求时从钥匙串取，刮削实例可以长期缓存，
    /// 改了凭据不用重建；设置页「测试」按钮传的是输入框里的草稿，不查钥匙串，用户清空
    /// 输入框再测就是真的不带凭据去试。
    enum AuthorizationSource: Sendable {
        case keychain
        case draft
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    static func query(
        server: LyricsAPIServer,
        session: URLSession,
        authorizationSource: AuthorizationSource = .keychain,
        requestPool: ScraperRequestPool = .shared,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async -> QueryOutcome {
        let host = logHost(for: server)
        guard let url = LyricsAPIServerPolicy.requestURL(
            address: server.address, title: title, artist: artist, album: album, duration: duration
        ) else {
            plog("🎤 [LyricsAPI] skip server \(host): address cannot form a request URL")
            return .failed(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/plain, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Primuse/1.0 (Lyrics API Client)", forHTTPHeaderField: "User-Agent")
        if let authorization = resolvedAuthorization(for: server, source: authorizationSource) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            let executor = await requestPool.executor(for: ScraperRequestPool.lyricsKey(server.address))
            let (data, http) = try await executor.execute { [request] in
                try await session.data(for: request)
            }
            let classification = LyricsAPIServerPolicy.classifyResponse(
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: data
            )
            switch classification {
            case .lyrics(let lrc, let plain):
                plog("🎤 [LyricsAPI] \(host): lyrics found (\(lrc != nil ? "lrc" : "plain"), \(data.count) bytes)")
                return .lyrics(lrc: lrc, plain: plain)
            case .notFound:
                plog("🎤 [LyricsAPI] \(host): no lyrics (HTTP \(http.statusCode))")
                return .notFound
            case .failed(let statusCode):
                plog("🎤 [LyricsAPI] \(host): failed with HTTP \(statusCode)")
                // 状态码说明用系统自带的本地化文案。
                return .failed(ScraperError.networkError(
                    "HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
                ))
            }
        } catch let failure as HTTPResponseFailure where failure.statusCode == 404 {
            return .notFound
        } catch let failure as HTTPResponseFailure where failure.statusCode != 429 && failure.statusCode != 503 {
            plog("🎤 [LyricsAPI] \(host): failed with HTTP \(failure.statusCode)")
            // 设置页「测试」要看得出是凭据错还是服务器坏了, 状态码说明用系统自带的本地化文案。
            return .failed(ScraperError.networkError(
                "HTTP \(failure.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: failure.statusCode))"
            ))
        } catch {
            if !isCancellation(error) {
                plog("🎤 [LyricsAPI] \(host): request error \(error.localizedDescription)")
            }
            return .failed(ScraperRequestPool.scraperError(error))
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func resolvedAuthorization(
        for server: LyricsAPIServer,
        source: AuthorizationSource
    ) -> String? {
        let raw: String?
        switch source {
        case .keychain:
            // 钥匙串优先；server 上还带着值只可能是旧版本 blob 里尚未搬家的凭据，兜底照用。
            raw = LyricsAPIServerCredentialStore.authorization(for: server.id) ?? server.authorization
        case .draft:
            raw = server.authorization
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// 日志只记主机（含端口），不记路径、query 与凭据。
    private static func logHost(for server: LyricsAPIServer) -> String {
        guard let components = URLComponents(string: server.address), let host = components.host else {
            return "<invalid>"
        }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Probe (设置页「测试」按钮)

enum LyricsAPIServerProbeResult: Sendable, Equatable {
    case found(lineCount: Int)
    case notFound
    case failed(String)
}

extension LyricsAPIServerScraper {
    static func probe(
        server: LyricsAPIServer,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        session suppliedSession: URLSession? = nil,
        requestPool: ScraperRequestPool = .shared
    ) async -> LyricsAPIServerProbeResult {
        let session = suppliedSession ?? makeSession()
        defer { if suppliedSession == nil { session.finishTasksAndInvalidate() } }
        switch await query(
            server: server, session: session, authorizationSource: .draft, requestPool: requestPool,
            title: title, artist: artist, album: album, duration: duration
        ) {
        case .lyrics(let lrc, let plain):
            return .found(lineCount: lyricLineCount(lrc: lrc, plain: plain))
        case .notFound:
            return .notFound
        case .failed(let error):
            return .failed(error.localizedDescription)
        }
    }

    /// LRC 数带时间戳且有文字的行，纯文本数非空行；TTML 与逐字格式（yrc / qrc / lys）
    /// 的时间不写成 `[mm:ss]`，交给共享解析器数有文字的行。
    private static func lyricLineCount(lrc: String?, plain: String?) -> Int {
        if let lrc, !lrc.isEmpty {
            if LyricsContentParser.isTTML(lrc) || WordTimedLyricsParser.detect(lrc) != nil {
                return LyricsContentParser.parseText(lrc).filter {
                    !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
                }.count
            }
            return lrc.split(separator: "\n").filter { line in
                let text = line.replacingOccurrences(
                    of: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#,
                    with: "",
                    options: .regularExpression
                )
                return text.count != line.count
                    && !text.trimmingCharacters(in: .whitespaces).isEmpty
            }.count
        }
        return (plain ?? "").split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }
}
