import Foundation
import PrimuseKit
#if os(macOS)
import AppKit
typealias CommentAvatarPlatformImage = NSImage
#else
import UIKit
typealias CommentAvatarPlatformImage = UIImage
#endif

/// 拉取单曲评论时的查询上下文。
struct SongCommentQuery: Equatable, Hashable, Sendable {
    let songID: String
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?

    init(
        songID: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    init(song: Song) {
        self.init(
            songID: song.id,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil
        )
    }
}

/// 评论拉取结果。
struct SongCommentFetchResult: Equatable, Sendable {
    let server: CommentAPIServer
    let page: SongCommentsPage
    let fetchedAt: Date
}

/// 设置页「用当前歌曲测试」的结果。
enum SongCommentProbeResult: Equatable, Sendable {
    case found(total: Int?, loadedCount: Int)
    case empty
    case failed(String)
}

enum SongCommentClientError: LocalizedError, Sendable {
    case noConfiguredServers
    case invalidAddress
    case invalidFormat
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noConfiguredServers:
            return String(localized: "comments_server_none")
        case .invalidAddress:
            return String(localized: "comments_server_invalid_address")
        case .invalidFormat:
            return String(localized: "comments_error_invalid_format")
        case .httpStatus(let code):
            return String(
                format: String(localized: "comments_error_http_format"),
                code,
                HTTPURLResponse.localizedString(forStatusCode: code)
            )
        case .network(let message):
            return message
        }
    }
}

/// 歌曲评论网络客户端 + 有界内存缓存（最多保留 24 条会话结果，TTL 10 分钟，避免常驻内存膨胀）。
actor SongCommentService {
    static let shared = SongCommentService()

    enum AuthorizationSource: Sendable {
        case keychain
        case draft
    }

    private struct CacheKey: Hashable, Sendable {
        let songID: String
        let serverID: String?
        let sort: SongCommentSort
    }

    private struct CacheEntry: Sendable {
        let result: SongCommentFetchResult
        let storedAt: Date
    }

    private static let cacheCapacity = 24
    private static let cacheTTL: TimeInterval = 600

    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheOrder: [CacheKey] = []
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// 读取第一页评论：
    /// - 指定 `preferredServerID` 时只请求该服务；
    /// - 否则按列表顺序依次尝试所有启用的服务，首个返回非空评论的结果即停。
    func fetchFirstPage(
        query: SongCommentQuery,
        servers: [CommentAPIServer],
        preferredServerID: String? = nil,
        sort: SongCommentSort = .hot,
        limit: Int = CommentAPIServerPolicy.defaultPageSize,
        forceRefresh: Bool = false
    ) async throws -> SongCommentFetchResult? {
        let candidates: [CommentAPIServer]
        if let preferredServerID {
            candidates = servers.filter { $0.id == preferredServerID }
        } else {
            candidates = servers
        }
        guard !candidates.isEmpty else {
            throw SongCommentClientError.noConfiguredServers
        }

        let cacheKey = CacheKey(songID: query.songID, serverID: preferredServerID, sort: sort)
        if !forceRefresh, let cached = cachedResult(for: cacheKey) {
            // 确保命中的缓存源仍在当前启用列表中且地址未改。
            if candidates.contains(where: { $0.id == cached.server.id && $0.address == cached.server.address }) {
                return cached
            }
        }

        var sawEmpty = false
        var firstError: (any Error)?

        for server in candidates {
            try Task.checkCancellation()
            switch await request(
                server: server,
                query: query,
                sort: sort,
                page: 1,
                limit: limit,
                cursor: nil,
                authorizationSource: .keychain
            ) {
            case .comments(let page):
                let result = SongCommentFetchResult(server: server, page: page, fetchedAt: Date())
                storeCache(result, for: cacheKey)
                return result
            case .empty:
                sawEmpty = true
            case .failed(let error):
                if Self.isCancellation(error) { throw error }
                if firstError == nil { firstError = error }
            }
        }

        try Task.checkCancellation()
        if sawEmpty { return nil }
        if let firstError { throw firstError }
        return nil
    }

    /// 加载指定服务的下一页评论（分页）。
    func fetchNextPage(
        server: CommentAPIServer,
        query: SongCommentQuery,
        sort: SongCommentSort,
        page: Int,
        limit: Int = CommentAPIServerPolicy.defaultPageSize,
        cursor: String?
    ) async throws -> SongCommentsPage {
        switch await request(
            server: server,
            query: query,
            sort: sort,
            page: page,
            limit: limit,
            cursor: cursor,
            authorizationSource: .keychain
        ) {
        case .comments(let nextPage):
            return nextPage
        case .empty:
            return SongCommentsPage(total: nil, hasMore: false, hotComments: [], comments: [])
        case .failed(let error):
            throw error
        }
    }

    /// 设置页「用当前歌曲测试」探测入口（使用草稿凭据，不查钥匙串）。
    static func probe(
        server: CommentAPIServer,
        query: SongCommentQuery,
        session suppliedSession: URLSession? = nil
    ) async -> SongCommentProbeResult {
        let service = SongCommentService(session: suppliedSession ?? makeSession())
        defer {
            if suppliedSession == nil {
                Task { await service.invalidateOwnedSession() }
            }
        }
        switch await service.request(
            server: server,
            query: query,
            sort: .hot,
            page: 1,
            limit: CommentAPIServerPolicy.defaultPageSize,
            cursor: nil,
            authorizationSource: .draft
        ) {
        case .comments(let page):
            return .found(total: page.total, loadedCount: page.visibleCount)
        case .empty:
            return .empty
        case .failed(let error):
            return .failed(error.localizedDescription)
        }
    }

    private func invalidateOwnedSession() {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Request & Cache

    private enum RequestOutcome: Sendable {
        case comments(SongCommentsPage)
        case empty
        case failed(any Error)
    }

    private func request(
        server: CommentAPIServer,
        query: SongCommentQuery,
        sort: SongCommentSort,
        page: Int,
        limit: Int,
        cursor: String?,
        authorizationSource: AuthorizationSource
    ) async -> RequestOutcome {
        let host = CommentAPIServerPolicy.displayHost(for: server.address) ?? "<invalid>"
        guard let url = CommentAPIServerPolicy.requestURL(
            address: server.address,
            title: query.title,
            artist: query.artist,
            album: query.album,
            duration: query.duration,
            sort: sort,
            page: page,
            limit: limit,
            cursor: cursor
        ) else {
            plog("💬 [CommentsAPI] skip server \(host): invalid request URL")
            return .failed(SongCommentClientError.invalidAddress)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Primuse/1.0 (Comment API Client)", forHTTPHeaderField: "User-Agent")
        if let authorization = Self.resolvedAuthorization(for: server, source: authorizationSource) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(SongCommentClientError.invalidFormat)
            }
            let classification = CommentAPIServerPolicy.classifyResponse(
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: data
            )
            switch classification {
            case .comments(let commentsPage):
                plog("💬 [CommentsAPI] \(host): loaded \(commentsPage.visibleCount) comments (page \(page))")
                return .comments(commentsPage)
            case .empty:
                plog("💬 [CommentsAPI] \(host): no comments (HTTP \(http.statusCode))")
                return .empty
            case .failed(let statusCode):
                plog("💬 [CommentsAPI] \(host): failed HTTP \(statusCode)")
                return .failed(SongCommentClientError.httpStatus(statusCode))
            case .invalidFormat:
                plog("💬 [CommentsAPI] \(host): invalid JSON response")
                return .failed(SongCommentClientError.invalidFormat)
            }
        } catch {
            if !Self.isCancellation(error) {
                plog("💬 [CommentsAPI] \(host): request error \(error.localizedDescription)")
            }
            return .failed(Self.isCancellation(error) ? error : SongCommentClientError.network(error.localizedDescription))
        }
    }

    private func cachedResult(for key: CacheKey) -> SongCommentFetchResult? {
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) <= Self.cacheTTL else {
            cache.removeValue(forKey: key)
            cacheOrder.removeAll { $0 == key }
            return nil
        }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return entry.result
    }

    private func storeCache(_ result: SongCommentFetchResult, for key: CacheKey) {
        cache[key] = CacheEntry(result: result, storedAt: Date())
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private static func resolvedAuthorization(
        for server: CommentAPIServer,
        source: AuthorizationSource
    ) -> String? {
        let raw: String?
        switch source {
        case .keychain:
            raw = CommentAPIServerCredentialStore.authorization(for: server.id) ?? server.authorization
        case .draft:
            raw = server.authorization
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// 评论头像有界内存缓存（最多 80 张、上限 8 MB），防止长列表滚动闪烁与内存失控。
final class CommentAvatarCache: @unchecked Sendable {
    static let shared = CommentAvatarCache()

    private let cache: NSCache<NSString, CommentAvatarPlatformImage> = {
        let cache = NSCache<NSString, CommentAvatarPlatformImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    func cachedImage(for urlString: String) -> CommentAvatarPlatformImage? {
        cache.object(forKey: urlString as NSString)
    }

    func loadImage(from urlString: String) async -> CommentAvatarPlatformImage? {
        if let existing = cachedImage(for: urlString) { return existing }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 2 * 1024 * 1024
            else { return nil }
            guard let image = CommentAvatarPlatformImage(data: data) else { return nil }
            cache.setObject(image, forKey: urlString as NSString, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}
