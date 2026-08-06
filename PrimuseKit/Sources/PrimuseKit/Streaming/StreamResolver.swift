import Foundation
#if os(tvOS)
import CryptoKit
import Observation
import Security
#endif

#if os(tvOS)
/// tvOS-local certificate pins for public NAS endpoints whose certificate does
/// not pass system validation (for example a reverse proxy presenting a NAS
/// certificate for a different hostname). Private/LAN hosts retain the legacy
/// automatic allowance; public endpoints always require an on-TV confirmation.
@MainActor
@Observable
public final class TVServerCertificateTrustStore {
    public struct Request: Identifiable {
        public let id = UUID()
        public let endpoint: String
        let fingerprint: String
        var continuations: [CheckedContinuation<Bool, Never>]
    }

    public static let shared = TVServerCertificateTrustStore()
    nonisolated private static let defaultsKey = "primuse.tv.server-certificate-pins.v1"

    public private(set) var pendingRequest: Request?
    private var waitingRequests: [Request] = []

    private init() {}

    public func requestTrust(endpoint: String, fingerprint: String) async -> Bool {
        if Self.isTrustedSync(endpoint: endpoint, fingerprint: fingerprint) { return true }
        return await withCheckedContinuation { continuation in
            if pendingRequest?.endpoint == endpoint,
               pendingRequest?.fingerprint == fingerprint {
                pendingRequest?.continuations.append(continuation)
                return
            }
            if let index = waitingRequests.firstIndex(where: {
                $0.endpoint == endpoint && $0.fingerprint == fingerprint
            }) {
                waitingRequests[index].continuations.append(continuation)
                return
            }
            let request = Request(
                endpoint: endpoint,
                fingerprint: fingerprint,
                continuations: [continuation]
            )
            if pendingRequest == nil {
                pendingRequest = request
            } else {
                waitingRequests.append(request)
            }
        }
    }

    public func resolvePendingRequest(approved: Bool) {
        guard let request = pendingRequest else { return }
        if approved {
            var pins = Self.storedPins()
            pins[request.endpoint] = request.fingerprint
            if let data = try? JSONEncoder().encode(pins) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
        pendingRequest = waitingRequests.isEmpty ? nil : waitingRequests.removeFirst()
        for continuation in request.continuations {
            continuation.resume(returning: approved)
        }
    }

    nonisolated static func isTrustedSync(endpoint: String, fingerprint: String) -> Bool {
        storedPins()[endpoint] == fingerprint
    }

    nonisolated private static func storedPins() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pins = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return pins
    }
}

public enum TVServerTrustPolicy {
    public static func disposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        var trustError: CFError?
        if SecTrustEvaluateWithError(trust, &trustError) {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        if InsecureHTTPHostPolicy.isLocalNetworkHost(host) {
            return (.useCredential, URLCredential(trust: trust))
        }
        guard let endpoint = NetworkEndpointIdentity(
            scheme: challenge.protectionSpace.protocol ?? "https",
            host: host,
            port: challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : nil
        )?.key,
        let fingerprint = leafFingerprint(trust) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if TVServerCertificateTrustStore.isTrustedSync(
            endpoint: endpoint,
            fingerprint: fingerprint
        ) {
            return (.useCredential, URLCredential(trust: trust))
        }
        let approved = await TVServerCertificateTrustStore.shared.requestTrust(
            endpoint: endpoint,
            fingerprint: fingerprint
        )
        return approved
            ? (.useCredential, URLCredential(trust: trust))
            : (.cancelAuthenticationChallenge, nil)
    }

    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return nil
        }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}
#endif

/// Resolver 登录请求使用的 session 工厂。tvOS 对私网 NAS 保留原有自签兼容；
/// 公网端点校验失败时由根视图确认并按 scheme/host/port 固定证书指纹。
enum StreamResolverSessionFactory {
    static func make(
        configuration: URLSessionConfiguration,
        fnMusicRedirects: Bool = false
    ) -> URLSession {
#if os(tvOS)
        URLSession(configuration: configuration,
                   delegate: PrivateNetworkTLSDelegate(fnMusicRedirects: fnMusicRedirects),
                   delegateQueue: nil)
#else
        if fnMusicRedirects {
            return URLSession(
                configuration: configuration,
                delegate: FnMusicRedirectSessionDelegate(),
                delegateQueue: nil
            )
        }
        return URLSession(configuration: configuration)
#endif
    }
}

private final class FnMusicRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let current = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(FnMusicRedirectPolicy.redirectedRequest(from: current, to: request))
    }
}

#if os(tvOS)
private final class PrivateNetworkTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fnMusicRedirects: Bool

    init(fnMusicRedirects: Bool) {
        self.fnMusicRedirects = fnMusicRedirects
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await TVServerTrustPolicy.disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard fnMusicRedirects else {
            completionHandler(request)
            return
        }
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let current = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(FnMusicRedirectPolicy.redirectedRequest(from: current, to: request))
    }

}
#endif

// MARK: - 流式解析(tvOS 播放)
//
// tvOS 不能用 iOS 那套 SFBAudioEngine + primuse-stream:// 自定义流(依赖原生库 +
// 音频引擎,不可移植)。tvOS 走 AVPlayer + 纯 https URL。这里定义"按音乐源把一首
// 歌解析成可直连播放的网络 URL"的共享契约,各源 resolver 都是纯 URLSession 实现,
// 放在 PrimuseKit 里以保持依赖只有 GRDB(不牵入任何 iOS-only 库)。

/// 解析一首歌所需的源凭据。Phase 1 只用到 username/password(Subsonic 家族);
/// Phase 2 会扩展 token / refreshToken / clientID / clientSecret 等。
public struct SourceCredential: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var token: String?
    public var refreshToken: String?
    public var clientID: String?
    public var clientSecret: String?
    public var extra: [String: String]

    public init(username: String? = nil,
                password: String? = nil,
                token: String? = nil,
                refreshToken: String? = nil,
                clientID: String? = nil,
                clientSecret: String? = nil,
                extra: [String: String] = [:]) {
        self.username = username
        self.password = password
        self.token = token
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.extra = extra
    }
}

public enum StreamResolveError: Error, Sendable, Equatable {
    /// 该音乐源类型在 tvOS 上无法直连播放(原生库源 / 本地文件等)。
    case unsupportedSourceType(MusicSourceType)
    /// 缺少必要凭据(密码 / token 未同步到本机)。
    case missingCredential
    /// 服务端鉴权失败(会话过期 / 密码错误),协调器据此触发刷新+重试。
    case authFailed
    /// 服务端要求两步验证(2FA / OTP),需用户在 TV 上输入一次性验证码。
    case needs2FA
    case badServerResponse(Int)
    case cannotBuildURL
    /// 该源需经 iPhone 中继播放,但中继端点未同步到(iPhone 未开启 / 不在同一局域网)。
    case relayUnavailable
}

/// 解析结果:可播放 URL + 播放时需附带的自定义 HTTP 头(UA / Bearer 等)。
/// 头为空时 AVPlayer 直连;非空时走 AVAssetResourceLoaderDelegate 代理(百度/115/Google)。
public struct ResolvedStream: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// 把一首歌解析成 AVPlayer 可播放的网络流。实现必须是 Sendable 的纯网络逻辑。
public protocol StreamResolver: Sendable {
    /// 解析成可直连播放的 URL(鉴权在 query 的源)。
    func streamURL(for song: Song,
                   source: MusicSource,
                   credential: SourceCredential?) async throws -> URL

    /// 解析成 URL + 播放头。默认包装 `streamURL`(无头);需要自定义播放头的源覆盖本方法。
    func resolve(for song: Song,
                 source: MusicSource,
                 credential: SourceCredential?) async throws -> ResolvedStream

    /// 会话失效时清掉缓存的会话(如 Synology `_sid`)。无状态源(Subsonic)空实现即可。
    func invalidateSession(sourceID: String) async

    /// 2FA:用一次性验证码登录,并申请「受信设备」令牌(deviceId)返回供持久化 ——
    /// 之后该设备登录即可跳过 OTP。不支持 2FA 设备令牌的源用默认实现(抛 authFailed)。
    func loginForDeviceToken(source: MusicSource,
                             credential: SourceCredential?,
                             otp: String) async throws -> String?
}

public extension StreamResolver {
    func resolve(for song: Song,
                 source: MusicSource,
                 credential: SourceCredential?) async throws -> ResolvedStream {
        ResolvedStream(url: try await streamURL(for: song, source: source, credential: credential))
    }

    func invalidateSession(sourceID: String) async {}

    func loginForDeviceToken(source: MusicSource,
                             credential: SourceCredential?,
                             otp: String) async throws -> String? {
        throw StreamResolveError.authFailed
    }
}
