#if os(tvOS)
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 让 AVPlayer 播放"需要自定义 HTTP 头(UA / Bearer)"的流(百度网盘 / 115 / Google Drive)。
///
/// 做法:把真实 https URL 换成自定义 scheme,AVPlayer 便把加载请求交给本 delegate;
/// 我们带上自定义头、按 AVPlayer 请求的字节范围去真实 URL 拉数据再回填,支持 Range 与 seek。
final class TVStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "primusehdr"

    private let realURL: URL
    private let headers: [String: String]
    private let explicitContentType: String?   // 已知文件格式推得的 UTType id(覆盖服务器误报的 octet-stream)
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(realURL: URL, headers: [String: String], fileExtension: String? = nil) {
        self.realURL = realURL
        self.headers = headers
        self.explicitContentType = fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 关键:带一个接受自签/不受信任证书的 TLS delegate。个人 NAS(Synology 等)
        // 多用自签或非公认 CA 证书,AVPlayer 裸播会直接「Cannot Open」;经此 session
        // 代理拉数据即可正常播放(与 iOS 端 SmartSSLDelegate 同策略)。
        self.session = URLSession(configuration: cfg,
                                  delegate: TVInsecureTLSDelegate(),
                                  delegateQueue: nil)
        super.init()
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
        let length: Int
        if let dataReq = loadingRequest.dataRequest {
            offset = dataReq.requestedOffset
            length = dataReq.requestedLength
        } else {
            offset = 0
            length = 2   // 仅取内容信息时拉头两字节即可拿到 Content-Range/Type
        }
        req.setValue("bytes=\(offset)-\(offset + Int64(max(1, length)) - 1)", forHTTPHeaderField: "Range")

        let id = ObjectIdentifier(loadingRequest)
        let isInfoReq = loadingRequest.contentInformationRequest != nil
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            self?.lock.lock(); self?.tasks[id] = nil; self?.lock.unlock()
            if let error {
                plog("📺 loader \(isInfoReq ? "info" : "data") off=\(offset) ERROR — \(error.localizedDescription)")
                if (error as NSError).code != NSURLErrorCancelled { loadingRequest.finishLoading(with: error) }
                return
            }
            if let info = loadingRequest.contentInformationRequest, let http = response as? HTTPURLResponse {
                Self.fillContentInfo(info, from: http, explicit: self?.explicitContentType)
                plog("📺 loader info status=\(http.statusCode) ct=\(info.contentType ?? "nil") len=\(info.contentLength) ranges=\(info.isByteRangeAccessSupported) serverCT=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil")")
            }
            if let dataReq = loadingRequest.dataRequest, let data {
                dataReq.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        lock.lock(); tasks[id] = task; lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        lock.lock(); let task = tasks[id]; tasks[id] = nil; lock.unlock()
        task?.cancel()
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
           let totalStr = range.split(separator: "/").last, let total = Int64(totalStr) {
            info.contentLength = total
        } else if http.statusCode == 200,
                  let lenStr = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenStr) {
            info.contentLength = len
        }
    }
}

/// 接受自签 / 不受信任的服务器证书(个人 NAS 常见)。AVPlayer 无 app 层 TLS 钩子,
/// 所以把流走这条带此 delegate 的 URLSession 代理,才能播放自签证书的 NAS。
final class TVInsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
