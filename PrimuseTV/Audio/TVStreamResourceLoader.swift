#if os(tvOS)
import AVFoundation
import Foundation
import PrimuseKit
import UniformTypeIdentifiers

/// Playback, lyrics, and resolver sessions share the same endpoint-scoped
/// tvOS trust policy from PrimuseKit.
enum TVServerTrust {
    static func disposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await TVServerTrustPolicy.disposition(for: challenge)
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
    private let enforcesFnMusicRangeResponses: Bool
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
    private var plainHTTPTasks: [ObjectIdentifier: PlainHTTPTaskBox] = [:]
    private var taskToRequestID: [Int: ObjectIdentifier] = [:]
    private var contexts: [Int: LoadingContext] = [:]

    private final class PlainHTTPTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var isCancelled = false

        func install(_ task: Task<Void, Never>) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                task.cancel()
            } else {
                self.task = task
                lock.unlock()
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            self.task = nil
            lock.unlock()
            task?.cancel()
        }

        func finish() {
            lock.lock()
            task = nil
            lock.unlock()
        }
    }

    private final class LoadingContext: @unchecked Sendable {
        let loadingRequest: AVAssetResourceLoadingRequest
        let offset: Int64
        let length: Int64
        let isInfoRequest: Bool
        var byteCount: Int64 = 0
        var expectedByteCount: Int64?
        var terminalErrorReported = false
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

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let owner else {
                completionHandler(nil)
                return
            }
            owner.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler
            )
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            // loader 已析构也要给出 TLS 处置,否则握手挂起;沿用同一信任策略。
            await TVServerTrust.disposition(for: challenge)
        }
    }

    init(realURL: URL, headers: [String: String], fileExtension: String? = nil) {
        self.realURL = realURL
        self.headers = headers
        self.explicitContentType = fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        let fnMusicStreamPath = "\(FnMusicAPIProtocol.apiPath)/track/stream"
        self.enforcesFnMusicRangeResponses = headers[FnMusicAPIProtocol.authxHeaderField] != nil
            && FnMusicAPIProtocol.authxPath(for: realURL) == fnMusicStreamPath
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

        // 飞牛音乐的 authx 含短时效时间戳。解析阶段给出的首个签名只能用于立即探测，
        // 长曲播放或稍后 seek 时必须为 AVPlayer 发起的每个 Range 请求重新签名。
        if enforcesFnMusicRangeResponses {
            FnMusicAPIProtocol.applyAuthx(to: &req)
        }

        let id = ObjectIdentifier(loadingRequest)
        let isInfoReq = loadingRequest.contentInformationRequest != nil
        let context = LoadingContext(
            loadingRequest: loadingRequest,
            offset: offset,
            length: length,
            isInfoRequest: isInfoReq
        )

        if StreamResolverHTTPTransport.requiresPlainHTTPTransport(realURL) {
            let box = PlainHTTPTaskBox()
            lock.lock()
            plainHTTPTasks[id] = box
            lock.unlock()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let events = try await StreamResolverHTTPTransport.stream(
                        for: req,
                        session: session,
                        redirectMode: enforcesFnMusicRangeResponses ? .fnMusic : .safe
                    )
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .response(let response):
                            try prepare(response: response, context: context)
                        case .data(let data):
                            if !consume(data: data, context: context) {
                                throw CancellationError()
                            }
                        }
                    }
                    completePlainHTTP(
                        requestID: id,
                        box: box,
                        context: context,
                        error: nil
                    )
                } catch is CancellationError {
                    removePlainHTTPTask(requestID: id, box: box)
                } catch {
                    completePlainHTTP(
                        requestID: id,
                        box: box,
                        context: context,
                        error: error
                    )
                }
            }
            box.install(task)
            return true
        }

        let task = session.dataTask(with: req)
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
        let plainHTTPTask = plainHTTPTasks.removeValue(forKey: id)
        tasks[id] = nil
        if let task {
            taskToRequestID[task.taskIdentifier] = nil
            contexts[task.taskIdentifier] = nil
        }
        lock.unlock()
        task?.cancel()
        plainHTTPTask?.cancel()
    }

    private func prepare(response http: HTTPURLResponse, context: LoadingContext) throws {
        if enforcesFnMusicRangeResponses {
            context.expectedByteCount = try Self.validatedFnMusicRangeResponseLength(
                http,
                requestedOffset: context.offset,
                requestedLength: context.length
            )
        }

        if let info = context.loadingRequest.contentInformationRequest {
            Self.fillContentInfo(info, from: http, explicit: explicitContentType)
            plog("📺 loader info status=\(http.statusCode) ct=\(info.contentType ?? "nil") len=\(info.contentLength) ranges=\(info.isByteRangeAccessSupported) serverCT=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil")")
        }

        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw NSError(
                domain: "TVStreamResourceLoader",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
    }

    @discardableResult
    private func consume(data: Data, context: LoadingContext) -> Bool {
        guard !context.terminalErrorReported else { return false }
        let incomingCount = Int64(data.count)
        if let expectedByteCount = context.expectedByteCount,
           (context.byteCount > expectedByteCount
            || incomingCount > expectedByteCount - context.byteCount) {
            let error = FnMusicRangeResponseError(
                detail: PMString(
                    "ext.tv.error.range.bodyTooLarge",
                    String(expectedByteCount)
                )
            )
            context.terminalErrorReported = true
            context.loadingRequest.finishLoading(with: error)
            return false
        }
        context.byteCount += incomingCount
        if let dataRequest = context.loadingRequest.dataRequest {
            dataRequest.respond(with: data)
            if !context.loggedFirstData {
                context.loggedFirstData = true
                plog("📺 loader data first off=\(context.offset) len=\(context.length) got=\(data.count)")
            }
        }
        return true
    }

    private func complete(context: LoadingContext, error: Error?) {
        guard !context.terminalErrorReported else { return }
        if let error {
            if (error as NSError).code != NSURLErrorCancelled {
                plog("📺 loader \(context.isInfoRequest ? "info" : "data") off=\(context.offset) ERROR — \(error.localizedDescription)")
                context.loadingRequest.finishLoading(with: error)
            }
            return
        }
        if let expectedByteCount = context.expectedByteCount,
           context.byteCount != expectedByteCount {
            context.loadingRequest.finishLoading(
                with: FnMusicRangeResponseError(
                    detail: PMString(
                        "ext.tv.error.range.bodyLengthMismatch",
                        String(context.byteCount),
                        String(expectedByteCount)
                    )
                )
            )
            return
        }
        if !context.isInfoRequest {
            plog("📺 loader data done off=\(context.offset) bytes=\(context.byteCount)")
        }
        context.loadingRequest.finishLoading()
    }

    private func removePlainHTTPTask(
        requestID: ObjectIdentifier,
        box: PlainHTTPTaskBox
    ) {
        box.finish()
        lock.lock()
        if plainHTTPTasks[requestID] === box {
            plainHTTPTasks[requestID] = nil
        }
        lock.unlock()
    }

    private func completePlainHTTP(
        requestID: ObjectIdentifier,
        box: PlainHTTPTaskBox,
        context: LoadingContext,
        error: Error?
    ) {
        removePlainHTTPTask(requestID: requestID, box: box)
        complete(context: context, error: error)
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

        do {
            try prepare(response: http, context: context)
            completionHandler(.allow)
        } catch {
            context.terminalErrorReported = true
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

        if !consume(data: data, context: context) {
            dataTask.cancel()
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
        complete(context: context, error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard enforcesFnMusicRangeResponses else {
            completionHandler(request)
            return
        }
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let currentRequest = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(
            FnMusicRedirectPolicy.redirectedRequest(
                from: currentRequest,
                to: request
            )
        )
    }

    /// TLS 信任见 TVServerTrust：私网兼容自签证书，公网异常证书需明确确认并固定指纹，
    /// 避免把云盘 Bearer / NAS 会话凭据暴露给未经确认的中间人。
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await TVServerTrust.disposition(for: challenge)
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

    /// 飞牛音乐的播放端点必须对每个实际 Range 请求返回严格匹配的 206。
    /// 初始两字节探测不能代替播放期间的校验，尤其是 seek 后的非零起点。
    private static func validatedFnMusicRangeResponseLength(
        _ response: HTTPURLResponse,
        requestedOffset: Int64,
        requestedLength: Int64
    ) throws -> Int64 {
        guard response.statusCode == 206 else {
            throw FnMusicRangeResponseError(
                detail: PMString(
                    "ext.tv.error.range.httpStatus",
                    String(response.statusCode)
                )
            )
        }
        guard requestedOffset >= 0,
              let header = response.value(forHTTPHeaderField: "Content-Range") else {
            throw FnMusicRangeResponseError(
                detail: PMString("ext.tv.error.range.missingContentRange")
            )
        }

        let unitAndValue = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes" else {
            throw FnMusicRangeResponseError(
                detail: PMString("ext.tv.error.range.invalidUnit")
            )
        }

        let rangeAndTotal = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              rangeAndTotal[1] != "*",
              let totalLength = Int64(rangeAndTotal[1]),
              totalLength > 0 else {
            throw FnMusicRangeResponseError(
                detail: PMString("ext.tv.error.range.invalidTotalLength")
            )
        }

        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start == requestedOffset,
              end >= start,
              end < totalLength else {
            throw FnMusicRangeResponseError(
                detail: PMString("ext.tv.error.range.invalidBounds")
            )
        }

        let expectedEnd: Int64
        if requestedLength > 0 {
            guard let exclusiveEnd = SafeByteRange.exclusiveEnd(
                offset: requestedOffset,
                length: requestedLength
            ), requestedOffset < totalLength else {
                throw FnMusicRangeResponseError(
                    detail: PMString("ext.tv.error.range.invalidRequest")
                )
            }
            expectedEnd = min(exclusiveEnd - 1, totalLength - 1)
        } else {
            guard requestedOffset < totalLength else {
                throw FnMusicRangeResponseError(
                    detail: PMString("ext.tv.error.range.invalidOpenRequest")
                )
            }
            expectedEnd = totalLength - 1
        }
        guard end == expectedEnd else {
            throw FnMusicRangeResponseError(
                detail: PMString(
                    "ext.tv.error.range.unexpectedEnd",
                    String(end),
                    String(expectedEnd)
                )
            )
        }

        let responseLength = end - start + 1
        if let rawContentLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard let contentLength = Int64(
                rawContentLength.trimmingCharacters(in: .whitespacesAndNewlines)
            ), contentLength == responseLength else {
                throw FnMusicRangeResponseError(
                    detail: PMString("ext.tv.error.range.headerMismatch")
                )
            }
        }
        return responseLength
    }

    private struct FnMusicRangeResponseError: LocalizedError {
        let detail: String

        var errorDescription: String? {
            PMString("ext.tv.error.fnMusicRange", detail)
        }
    }
}

/// 歌词等非播放请求的 TLS delegate。与播放流同策略(见 TVServerTrust):系统证书正常
/// 通过；私网延续原有自签兼容；公网异常证书必须经用户确认并固定指纹。
final class TVInsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await TVServerTrust.disposition(for: challenge)
    }

}

#endif
