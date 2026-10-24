import Foundation
import CryptoKit
import PrimuseKit

/// 一次"听歌记录" — 提供给 provider 的统一数据模型。
/// 跨 provider 共享, 字段命名遵循 ListenBrainz / Last.fm 共同语义。
public struct ScrobbleEntry: Codable, Sendable, Hashable {
    public let songID: String        // primuse 内部 song.id, 用于 dedup
    public let title: String
    public let artist: String
    public let album: String?
    public let albumArtist: String?
    public let durationSec: Int?
    public let trackNumber: Int?
    /// 听歌开始的 Unix timestamp (秒)。Last.fm / LB 都要求是开始时间。
    public let startedAt: Int64

    public init(
        songID: String, title: String, artist: String,
        album: String? = nil, albumArtist: String? = nil,
        durationSec: Int? = nil, trackNumber: Int? = nil,
        startedAt: Int64
    ) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.durationSec = durationSec
        self.trackNumber = trackNumber
        self.startedAt = startedAt
    }
}

/// Scrobble provider 抽象 — Last.fm / ListenBrainz / 后续 Maloja 等共享接口。
/// 所有方法都允许失败 (网络错 / 认证过期), ScrobbleService 处理重试。
public protocol ScrobbleProvider: Sendable {
    var id: ScrobbleProviderID { get }

    /// 当前这份凭据的摘要。服务端拒绝过的凭据按它记下, 不保存原文;
    /// 换了 token / 重新登录后摘要随之改变。
    var credentialFingerprint: String { get }

    /// 检查认证是否还有效 (token / sessionKey 还能用)。
    /// 网络异常时返回 nil 让 service 跳过这次而不是报错。
    func validateCredentials() async -> Bool?

    /// 上报 Now Playing — 用户正在听这首, 不计入听歌历史。
    /// Last.fm: track.updateNowPlaying / ListenBrainz: playing_now
    func sendNowPlaying(_ entry: ScrobbleEntry) async throws

    /// 提交一条 (或多条) 听歌历史 — 计入 history。
    /// 实现应该尽量批量发送, ScrobbleQueue 一次最多给 50 条。
    func submitListens(_ entries: [ScrobbleEntry]) async throws
}

enum ScrobbleCredentialFingerprint {
    static func of(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Scrobble 错误类型 — 让 service 决定是否重试 / 提示用户。
public enum ScrobbleError: Error, LocalizedError {
    case notConfigured            // 没有 token, 跳过
    case invalidCredentials       // token 无效, 用户需要重新登录
    case rateLimited              // 限速, 暂缓
    case network(Error)           // 网络错, 队列重试
    case http(Int, String?)       // 服务端错
    case invalidResponse          // 解析失败

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "error_scrobble_not_configured")
        case .invalidCredentials:
            return String(localized: "error_scrobble_invalid_credentials")
        case .rateLimited:
            return String(localized: "error_scrobble_rate_limited")
        case .network(let error):
            return String(
                format: String(localized: "error_scrobble_network %@"),
                error.localizedDescription
            )
        case .http(let code, let message):
            return String(
                format: String(localized: "error_scrobble_http %@ %@"),
                String(code),
                message ?? ""
            )
        case .invalidResponse:
            return String(localized: "error_scrobble_invalid_response")
        }
    }

    /// 是否值得放进失败队列重试 (vs. 立即丢弃)。
    /// 认证错 / 配置错 → 不重试 (不会变好)。认证错时 ScrobbleService 记下这份凭据,
    /// 记录留在队列里, 换了凭据再补。
    /// 网络 / 限速 / 5xx → 重试 (后台稳定时再发)。
    var isRetryable: Bool {
        switch self {
        case .notConfigured, .invalidCredentials: return false
        case .rateLimited, .network: return true
        case .http(let code, _): return code >= 500
        case .invalidResponse: return false
        }
    }
}

/// Provider writes share admission with Now Playing and retain server deadlines
/// across app launches. Only endpoint/account digests and timing/status are saved.
struct ScrobbleRequests: Sendable {
    static let listenBrainz = RequestQuota.Service(id: "listenbrainz.api", policy: .init(
        maximumConcurrentRequests: 1, maximumAttempts: 1, timeout: 30
    ))
    let registry: RequestQuotaRegistry
    let cooldowns: ScrobbleCooldownStore
    init(registry: RequestQuotaRegistry = .shared, cooldowns: ScrobbleCooldownStore = .shared) {
        self.registry = registry; self.cooldowns = cooldowns
    }

    func send(_ request: URLRequest, session: URLSession, service: RequestQuota.Service,
              account: String,
              inspect: @escaping @Sendable (Data, HTTPURLResponse) throws -> Void = { _, _ in }
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url,
              let quota = RequestQuota(service: service, url: url, account: .init(stableID: account)) else {
            throw URLError(.badURL)
        }
        let key = ScrobbleCooldownStore.key(service: service.id, endpoint: quota.endpoint.key, account: account)
        try await cooldowns.check(key)
        do {
            return try await registry.execute(for: quota, replay: .never, operation: {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ScrobbleError.invalidResponse }
                let retryAfter = HTTPResponseFailure.retryDelay(from: http)
                try inspect(data, http)
                guard (200...299).contains(http.statusCode) else {
                    throw HTTPResponseFailure(statusCode: http.statusCode, retryAfter: retryAfter)
                }
                return (data, http)
            })
        } catch let failure as HTTPResponseFailure {
            let delay = (failure.retryAfter ?? ((failure.isRateLimited || service.policy.rateLimitStatusCodes.contains(failure.statusCode))
                ? service.policy.defaultCooldown : nil)).map { min($0, ScrobbleCooldownStore.maximumDelay) }
            if let delay, delay.isFinite, delay >= 0 {
                await cooldowns.record(key, status: failure.statusCode, delay: delay)
                throw HTTPResponseFailure(statusCode: failure.statusCode, retryAfter: delay,
                    isRateLimited: failure.isRateLimited, isRetryable: failure.isRetryable)
            }
            if (400...499).contains(failure.statusCode), failure.isRetryable != true {
                throw ScrobbleError.http(failure.statusCode, nil)
            }
            throw failure
        } catch {
            if OperationCancellationPolicy.isCancellation(error) { throw CancellationError() }
            if let error = error as? ScrobbleError { throw error }
            throw ScrobbleError.network(error)
        }
    }
}

actor ScrobbleCooldownStore {
    static let shared = ScrobbleCooldownStore()
    /// 持久化的服务端截止时间最多一天。代理回了离谱的 Retry-After、或记下之后系统时钟往回拨,
    /// 都不能让上报和正在播放一直被挡着又没有入口解除;补报队列能留 90 天,晚一天不会丢记录。
    static let maximumDelay: TimeInterval = 86_400
    private struct Deadline: Codable {
        let until: TimeInterval
        let status: Int
    }
    private let defaults: UserDefaults
    private let now: @Sendable () -> TimeInterval
    private let storageKey = "primuse.scrobble.serverCooldowns.v1"
    private var deadlines: [String: Deadline]
    init(suiteName: String? = nil, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults; self.now = now
        deadlines = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Deadline].self, from: $0) } ?? [:]
    }
    nonisolated static func key(service: String, endpoint: String, account: String) -> String {
        SHA256.hash(data: Data("\(service)\n\(endpoint)\n\(account)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func check(_ key: String) throws {
        try Task.checkCancellation()
        if let deadline = deadlines[key] {
            let remaining = deadline.until - now()
            guard remaining > 0 else { return }
            if remaining > Self.maximumDelay {
                deadlines[key] = Deadline(until: now() + Self.maximumDelay, status: deadline.status)
                save()
            }
            throw HTTPResponseFailure(statusCode: deadline.status, retryAfter: min(remaining, Self.maximumDelay),
                isRateLimited: true)
        }
    }
    func record(_ key: String, status: Int, delay: TimeInterval) {
        let now = now()
        let ceiling = now + Self.maximumDelay
        deadlines = deadlines.filter { $0.value.until > now }
            .mapValues { Deadline(until: min($0.until, ceiling), status: $0.status) }
        let until = now + min(delay, Self.maximumDelay)
        if until > (deadlines[key]?.until ?? 0) { deadlines[key] = Deadline(until: until, status: status) }
        // Accounts are user-configured; expired records are removed on every write.
        // Never evict an active server deadline to make a retry appear eligible.
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(deadlines) { defaults.set(data, forKey: storageKey) }
    }
}
