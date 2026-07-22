#if os(tvOS)
import AVFoundation
import Foundation
import PrimuseKit
import Security
import UniformTypeIdentifiers

/// TLS 信任策略(TV 端)。AVPlayer 无 app 层 TLS 钩子,所以播放 / 歌词流都走带自定义
/// delegate 的 URLSession。但**不能**对所有主机一律放行证书:这些 session 会带云盘
/// Bearer / Subsonic salted token / NAS 登录会话等凭据,无条件信任等于把凭据交给任意
/// 中间人。策略对齐 iOS 的 SmartSSLDelegate:
///   1. 先跑系统默认校验(SecTrustEvaluateWithError)——公网云盘(Google Drive /
///      百度 / 115 等)证书合法,走默认握手,凭据安全。
///   2. 只有默认校验**失败**且主机是局域网 / 私有地址(自签证书的个人 NAS 常见)时,
///      才接受该证书。公网主机的非法证书一律拒绝,杜绝中间人。
enum TVServerTrust {
    /// 评估 server trust 挑战,返回应采用的处置。
    static func disposition(for challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // 1. 证书本身受系统信任(公网云盘 / 正规证书)→ 走默认握手。
        var trustError: CFError?
        if SecTrustEvaluateWithError(trust, &trustError) {
            return (.performDefaultHandling, nil)
        }
        // 2. 校验失败:仅放行私有 / 局域网主机(自签证书的个人 NAS),公网一律拒绝。
        // tvOS 当前没有证书变更确认 / 清除 pin 的 UI,所以不在这里持久化硬 pin;
        // 否则 NAS 自动续期或用户更换证书后会进入无法在 TV 端恢复的状态。
        let host = challenge.protectionSpace.host
        if isPrivateHost(host) {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    /// 主机是否为局域网 / 私有地址(RFC1918 / 链路本地 / 回环 / .local mDNS / .home)。
    /// 仅对这类主机才允许接受不受系统信任的自签证书。
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".home")
            || h.hasSuffix(".lan") || h.hasSuffix(".internal") {
            return true
        }
        // IPv6 回环 / 唯一本地地址(fc00::/7)/ 链路本地(fe80::/10)。
        // Prefix checks are only valid for IPv6 literals. Without the colon
        // guard, a public DNS name such as `fcloud.example` would be mistaken
        // for an fc00::/7 private address after a certificate failure.
        if h.contains(":"), h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd")
            || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea")
            || h.hasPrefix("feb") {
            return true
        }
        // IPv4 私有 / 回环 / 链路本地段。
        let parts = h.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else { return false }
        switch a {
        case 10: return true                       // 10.0.0.0/8
        case 127: return true                       // 127.0.0.0/8 回环
        case 172: return (16...31).contains(b)      // 172.16.0.0/12
        case 192: return b == 168                   // 192.168.0.0/16
        case 169: return b == 254                   // 169.254.0.0/16 链路本地
        default: return false
        }
    }
}

/// 让 AVPlayer 播放"需要自定义 HTTP 头(UA / Bearer)"的流(百度网盘 / 115 / Google Drive)。
///
/// 做法:把真实 https URL 换成自定义 scheme,AVPlayer 便把加载请求交给本 delegate;
/// 我们带上自定义头、按 AVPlayer 请求的字节范围去真实 URL 拉数据再回填,支持 Range 与 seek。
final class TVStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "primusehdr"

    private let realURL: URL
    private let headers: [String: String]
    private let explicitContentType: String?   // 已知文件格式推得的 UTType id(覆盖服务器误报的 octet-stream)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        // delegate 用弱持有 loader 的轻量转发对象,打破 loader ↔ session 强引用环:
        // URLSession 对 delegate 是强引用,若直接传 self,session 永远不释放,loader 亦
        // 随之泄漏(连同其线程 / 缓存 / 连接)。换曲时 TVAudioEngine 只替换 resourceLoader
        // 强引用,有了弱环 loader 便能正常析构,deinit 再 invalidate session 收尾。
        return URLSession(configuration: cfg, delegate: SessionDelegateProxy(self), delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var taskToRequestID: [Int: ObjectIdentifier] = [:]
    private var contexts: [Int: LoadingContext] = [:]

    private final class LoadingContext: @unchecked Sendable {
        let loadingRequest: AVAssetResourceLoadingRequest
        let offset: Int64
        let length: Int64
        let isInfoRequest: Bool
        var byteCount: Int = 0
        var loggedFirstData: Bool = false

        init(loadingRequest: AVAssetResourceLoadingRequest,
             offset: Int64,
             length: Int64,
             isInfoRequest: Bool) {
            self.loadingRequest = loadingRequest
            self.offset = offset
            self.length = length
            self.isInfoRequest = isInfoRequest
        }
    }

    /// session delegate 转发对象:弱持有 loader,打破 loader ↔ session 强引用环。
    /// session 强引用本对象,本对象弱引用 loader——loader 因此可随 TVAudioEngine 换曲正常析构。
    private final class SessionDelegateProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: TVStreamResourceLoader?
        init(_ owner: TVStreamResourceLoader) { self.owner = owner }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.urlSession(session, dataTask: dataTask, didReceive: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.urlSession(session, task: task, didCompleteWithError: error)
        }

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // loader 已析构也要给出 TLS 处置,否则握手挂起;沿用同一信任策略。
            let (disposition, credential) = TVServerTrust.disposition(for: challenge)
            completionHandler(disposition, credential)
        }
    }

    init(realURL: URL, headers: [String: String], fileExtension: String? = nil) {
        self.realURL = realURL
        self.headers = headers
        self.explicitContentType = fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        super.init()
    }

    deinit {
        // session 由弱持有 loader 的 proxy 当 delegate,loader 析构后 proxy 不再回调进来;
        // 这里主动 invalidate 释放 session 自身的线程 / 连接 / 缓存,并取消遗留 task。
        session.invalidateAndCancel()
    }

    /// 把真实 URL 换成自定义 scheme 给 AVURLAsset 用。
    static func maskedURL(from real: URL) -> URL? {
        guard var comp = URLComponents(url: real, resolvingAgainstBaseURL: false) else { return nil }
        comp.scheme = scheme
        return comp.url
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        var req = URLRequest(url: realURL)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }

        let offset: Int64
        let length: Int64           // <=0 表示开放式 Range(读到资源末尾)
        if let dataReq = loadingRequest.dataRequest {
            let requestedStart = max(0, dataReq.requestedOffset)
            let current = dataReq.currentOffset > 0 ? dataReq.currentOffset : requestedStart
            offset = max(0, current)
            if dataReq.requestsAllDataToEndOfResource {
                // “读到资源末尾”请求:requestedLength 可为 Int.max,offset+length 会算术溢出 trap,
                // 拼进 Range 头也会被部分服务器拒为 416。改发开放式 Range(bytes=offset-)。
                length = -1
            } else {
                let requestedLength = Int64(max(1, dataReq.requestedLength))
                if let requestedEnd = SafeByteRange.exclusiveEnd(
                    offset: requestedStart,
                    length: requestedLength
                ), requestedEnd > offset {
                    length = requestedEnd - offset
                } else {
                    // An invalid/extreme request is safer as an open-ended
                    // range than as wrapping signed arithmetic.
                    length = -1
                }
            }
        } else {
            offset = 0
            length = 2   // 仅取内容信息时拉头两字节即可拿到 Content-Range/Type
        }
        if length <= 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else if let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) {
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
        } else {
            loadingRequest.finishLoading(with: CocoaError(.fileReadInvalidFileName))
            return false
        }

        let id = ObjectIdentifier(loadingRequest)
        let isInfoReq = loadingRequest.contentInformationRequest != nil
        let task = session.dataTask(with: req)
        let context = LoadingContext(
            loadingRequest: loadingRequest,
            offset: offset,
            length: length,
            isInfoRequest: isInfoReq
        )
        lock.lock()
        tasks[id] = task
        taskToRequestID[task.taskIdentifier] = id
        contexts[task.taskIdentifier] = context
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks[id]
        tasks[id] = nil
        if let task {
            taskToRequestID[task.taskIdentifier] = nil
            contexts[task.taskIdentifier] = nil
        }
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        lock.lock()
        let context = contexts[dataTask.taskIdentifier]
        lock.unlock()
        guard let context else {
            completionHandler(.cancel)
            return
        }

        if let info = context.loadingRequest.contentInformationRequest {
            Self.fillContentInfo(info, from: http, explicit: explicitContentType)
            plog("📺 loader info status=\(http.statusCode) ct=\(info.contentType ?? "nil") len=\(info.contentLength) ranges=\(info.isByteRangeAccessSupported) serverCT=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil")")
        }

        switch http.statusCode {
        case 200, 206:
            completionHandler(.allow)
        default:
            let error = NSError(
                domain: "TVStreamResourceLoader",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
            context.loadingRequest.finishLoading(with: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        let context = contexts[dataTask.taskIdentifier]
        lock.unlock()
        guard let context else { return }

        context.byteCount += data.count
        if let dataRequest = context.loadingRequest.dataRequest {
            dataRequest.respond(with: data)
            if !context.loggedFirstData {
                context.loggedFirstData = true
                plog("📺 loader data first off=\(context.offset) len=\(context.length) got=\(data.count)")
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let context = contexts[task.taskIdentifier]
        let requestID = taskToRequestID[task.taskIdentifier]
        contexts[task.taskIdentifier] = nil
        taskToRequestID[task.taskIdentifier] = nil
        if let requestID {
            tasks[requestID] = nil
        }
        lock.unlock()

        guard let context else { return }
        if let error {
            if (error as NSError).code != NSURLErrorCancelled {
                plog("📺 loader \(context.isInfoRequest ? "info" : "data") off=\(context.offset) ERROR — \(error.localizedDescription)")
                context.loadingRequest.finishLoading(with: error)
            }
            return
        }
        if !context.isInfoRequest {
            plog("📺 loader data done off=\(context.offset) bytes=\(context.byteCount)")
        }
        context.loadingRequest.finishLoading()
    }

    /// TLS 信任:公网证书走系统默认校验,仅对局域网 / 私有主机的自签证书放行。
    /// 见 TVServerTrust —— 避免把云盘 Bearer / NAS 会话凭据暴露给中间人。
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = TVServerTrust.disposition(for: challenge)
        completionHandler(disposition, credential)
    }

    static func fillContentInfo(_ info: AVAssetResourceLoadingContentInformationRequest,
                                from http: HTTPURLResponse, explicit: String? = nil) {
        // 优先用「已知文件格式」推得的 UTType:个人 NAS / 云盘下载端常返回
        // application/octet-stream,UTType(mimeType:) 解析不出可播类型 → AVPlayer
        // 直接「Cannot Open」。显式给定 FLAC/MP3 等类型才能播。
        if let explicit {
            info.contentType = explicit
        } else if let raw = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           let uti = UTType(mimeType: raw) {
            info.contentType = uti.identifier
        }
        info.isByteRangeAccessSupported = http.statusCode == 206
            || http.value(forHTTPHeaderField: "Accept-Ranges")?.contains("bytes") == true
        // 优先用 Content-Range 的总长度(bytes a-b/total)
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = range.split(separator: "/").last,
           let total = Int64(totalStr), total >= 0 {
            info.contentLength = total
        } else if http.statusCode == 200,
                  let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                  let len = Int64(lenStr), len >= 0 {
            info.contentLength = len
        }
    }
}

/// 歌词等非播放请求的 TLS delegate。与播放流同策略(见 TVServerTrust):公网证书走系统
/// 默认校验,仅对局域网 / 私有主机的自签证书放行——歌词请求同样带源凭据,不能无条件信任。
final class TVInsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = TVServerTrust.disposition(for: challenge)
        completionHandler(disposition, credential)
    }
}

#endif
