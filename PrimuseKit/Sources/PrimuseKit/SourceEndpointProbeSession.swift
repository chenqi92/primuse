import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `SourceEndpointResolver` 的生产加载器:一个只为端口探测存在的会话。
///
/// 为什么不复用 app 的传输层:`SmartSSLDelegate` 在遇到公网明文或不受信证书时会
/// 弹框等用户决定,而端口探测要同时发四五个候选、其中多半是错的 —— 那会变成四五
/// 个信任框,而且任何一个没被展示出来,请求就永远悬着(NAS 一直转圈那次的成因)。
///
/// 为什么可以在这里接受任意证书:探测请求是免登录接口(`/System/Info/Public`、
/// `ping.view`、`OPTIONS`),**不携带任何凭据**,响应也只用来判断"这个端口后面
/// 是不是这个服务"。请求里没有可被窃取的秘密,最坏情况只是选错端口,而随后真正的
/// 登录仍然走原有传输层,该做的证书校验、该弹的信任框一个都不少。这里
/// **不写入任何信任记录**:会话是 ephemeral 的,证书豁免随本次探测一起消失。
public final class SourceEndpointProbeSession: @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // 探测不认账号,凭据容器留空才守得住"一个字节的秘密都不发出去"。
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        // 端口试不通就该立刻换下一个,不是排队等网络恢复。
        configuration.waitsForConnectivity = false
        session = URLSession(
            configuration: configuration,
            delegate: SourceEndpointProbeDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        // 带 delegate 的 URLSession 会强引用它,不主动作废就一直留着。
        session.finishTasksAndInvalidate()
    }

    /// 闭包持有 self,所以只要加载器还在用,会话就活着;两边都释放后 deinit 作废它。
    public func loader() -> SourceEndpointResolver.Loader {
        { [self] probe in try await run(probe) }
    }

    private func run(
        _ probe: SourceEndpointResolver.Probe
    ) async throws -> SourceServiceFingerprint.ProbeResponse {
        var request = URLRequest(url: probe.url)
        request.httpMethod = probe.method
        request.timeoutInterval = probe.timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceServiceProbeFailure(.connectionFailed)
            }
            return SourceServiceFingerprint.ProbeResponse(
                statusCode: http.statusCode,
                headerFields: Self.headerFields(of: http),
                bodyPrefix: Self.bodyPrefix(of: data, limit: probe.maximumBodyBytes)
            )
        } catch let probeFailure as SourceServiceProbeFailure {
            throw probeFailure
        } catch {
            throw Self.probeFailure(for: error)
        }
    }

    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            fields[name] = String(describing: value)
        }
        return fields
    }

    /// 正文只看开头几 KB:判定要的字段名都在最前面,而一个认错了的候选可能是一整页
    /// HTML。非 UTF-8 的正文(打到 TLS 端口时回来的二进制)按 latin-1 读,让子串
    /// 匹配仍能进行而不是整块丢掉。
    private static func bodyPrefix(of data: Data, limit: Int) -> String {
        let slice = data.prefix(limit)
        if let text = String(data: slice, encoding: .utf8) { return text }
        return String(data: slice, encoding: .isoLatin1) ?? ""
    }

    private static func probeFailure(for error: any Error) -> SourceServiceProbeFailure {
        guard let urlError = error as? URLError else {
            return SourceServiceProbeFailure(.connectionFailed)
        }
        switch urlError.code {
        case .cancelled:
            return SourceServiceProbeFailure(.cancelled)
        case .timedOut:
            return SourceServiceProbeFailure(.timedOut)
        case .cannotFindHost, .dnsLookupFailed:
            // 域名解析不出来不是"这个端口不通", 是地址写错了 —— 界面要能单独说。
            return SourceServiceProbeFailure(.hostNotFound)
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            // 证书我们已经放行了,还失败就说明对面根本不讲 TLS —— 多半是把 https
            // 打到了明文端口。换下一个候选。
            return SourceServiceProbeFailure(.tlsFailure)
        default:
            return SourceServiceProbeFailure(.connectionFailed)
        }
    }
}

private final class SourceEndpointProbeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }

    /// 只对服务器证书放行,而且只在本次探测内。HTTP Basic / NTLM 一律默认处理并且
    /// 不带凭据 —— 那样会拿到一个 401,而 401 本身就是"这个端口上有东西"的有效
    /// 信号,不需要也不应该拿用户的口令去换。
    private func disposition(
        for challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 只跟随同源跳转(协议、主机、端口都相同),同主机内的 `/` → `/web/` 照常跟随。
        //
        // 跨主机必须停下:跟过去就会把"某个门户站认得这个服务"当成"用户填的这台机器
        // 是这个服务"。**同主机换协议或换端口也必须停下**:`http://host` 被 301 到
        // `https://host` 时若跟过去, `http:80` 这个候选拿到的就是 https 那边的指纹,
        // 会被判成"确认"并存下来 —— 之后每一次登录请求都先走一遍明文再被重定向。
        // 停在这里, 这个候选只得到一个 301(`.responded`), 真正提供服务的那个候选
        // 会凭 `.confirmed` 胜出。
        guard let original = task.originalRequest?.url,
              let target = request.url,
              Self.isSameOrigin(original, target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              lhsHost == rhsHost else { return false }
        let defaultPort = lhsScheme == "https" ? 443 : 80
        return (lhs.port ?? defaultPort) == (rhs.port ?? defaultPort)
    }
}
