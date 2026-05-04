import Foundation
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
        case .notConfigured: return "Scrobble: token not configured"
        case .invalidCredentials: return "Scrobble: credentials invalid (re-login required)"
        case .rateLimited: return "Scrobble: rate limited"
        case .network(let e): return "Scrobble network: \(e.localizedDescription)"
        case .http(let code, let msg): return "Scrobble HTTP \(code): \(msg ?? "")"
        case .invalidResponse: return "Scrobble: invalid response"
        }
    }

    /// 是否值得放进失败队列重试 (vs. 立即丢弃)。
    /// 认证错 / 配置错 → 不重试 (不会变好)。
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
