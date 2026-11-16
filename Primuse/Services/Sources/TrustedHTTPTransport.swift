import Foundation
import PrimuseKit

enum TrustedHTTPTransportError: LocalizedError, Equatable {
    case permissionRequired(host: String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired(let host):
            return String(
                format: String(localized: "insecure_http_permission_required %@"),
                host
            )
        }
    }
}

/// Keeps ATS enabled globally and uses a lower-level cleartext transport only
/// for public hosts the user explicitly approved. Local HTTP and all HTTPS
/// requests remain on URLSession.
enum TrustedHTTPTransport {
    static func makeMediaSession(
        configuration: URLSessionConfiguration = .ephemeral,
        trust: SmartSSLDelegate = SmartSSLDelegate()
    ) -> URLSession {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "cookie2", "referer"]
        configuration.httpAdditionalHeaders = configuration.httpAdditionalHeaders?.filter {
            !credentialHeaders.contains(String(describing: $0.key).lowercased())
        }
        return URLSession(
            configuration: configuration,
            delegate: MediaHTTPRedirectSessionDelegate(trust: trust),
            delegateQueue: nil
        )
    }

    static func mediaData(
        for request: URLRequest, session: URLSession,
        maxBytes: Int = PlainHTTPClient.defaultMaxBytes
    ) async throws -> (Data, URLResponse) {
        try await mediaResponseFollowingRedirects(
            for: request, session: session,
            load: { request, session in
                try await dataWithoutRedirects(for: request, session: session, maxBytes: maxBytes)
            },
            discard: { _ in }
        )
    }

    static func mediaDownload(
        for request: URLRequest, session: URLSession,
        maximumRangedBodyBytes: Int? = nil,
        wholeResponsePrefixLimit: Int? = nil
    ) async throws -> (URL, URLResponse) {
        try await mediaResponseFollowingRedirects(
            for: request, session: session,
            load: { request, session in
                try await downloadWithoutRedirects(
                    for: request, session: session,
                    maximumRangedBodyBytes: maximumRangedBodyBytes,
                    wholeResponsePrefixLimit: wholeResponsePrefixLimit
                )
            },
            discard: { try? FileManager.default.removeItem(at: $0) }
        )
    }

    /// Login protocols must capture every Set-Cookie before following a
    /// redirect. The supplied session must also reject automatic redirects.
    static func dataWithoutRedirects(
        for request: URLRequest, session: URLSession, maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        let maxBytes = SpeculativeRangeRead.effectiveLimit(maxBytes)
        guard let url = request.url else { throw URLError(.badURL) }
        if requiresPlainSocket(for: url) {
            _ = try await trustedPublicHTTPHost(for: url)
            return try await PlainHTTPClient.data(for: request, maxBytes: maxBytes)
        }
        return try await boundedSessionData(for: request, session: session, maxBytes: maxBytes)
    }

    /// The media session rejects implicit redirects so every hop uses the
    /// same credential isolation, retry budget, and cancellation checks.
    static func mediaResponseFollowingRedirects<Payload: Sendable>(
        for request: URLRequest,
        session: URLSession,
        validate: @Sendable () async throws -> Void = { try Task.checkCancellation() },
        redirectRequest: @Sendable (URLRequest, HTTPURLResponse) async -> URLRequest? = {
            HTTPMediaRedirectRequestPolicy.redirectedRequest(from: $0, response: $1)
        },
        load: @Sendable (URLRequest, URLSession) async throws -> (Payload, URLResponse),
        discard: @Sendable (Payload) -> Void
    ) async throws -> (Payload, URLResponse) {
        attempts: for attempt in 0..<HTTPMediaRedirectRetryPolicy.maximumAttempts {
            var currentRequest = request
            currentRequest.httpShouldHandleCookies = false
            var hasRedirected = false
            for redirectCount in 0...HTTPMediaRedirectRequestPolicy.maximumRedirects {
                try await validate()
                let result: (Payload, URLResponse)
                do {
                    result = try await load(currentRequest, session)
                } catch {
                    try await validate()
                    if hasRedirected, attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                       HTTPMediaRedirectRetryPolicy.isRetryable(error: error) {
                        continue attempts
                    }
                    throw error
                }
                do {
                    try await validate()
                } catch {
                    discard(result.0)
                    throw error
                }
                guard let http = result.1 as? HTTPURLResponse else { return result }
                if let redirected = await redirectRequest(currentRequest, http) {
                    discard(result.0)
                    guard redirectCount < HTTPMediaRedirectRequestPolicy.maximumRedirects else {
                        throw URLError(.httpTooManyRedirects)
                    }
                    currentRequest = redirected
                    hasRedirected = true
                    continue
                }
                if hasRedirected, attempt + 1 < HTTPMediaRedirectRetryPolicy.maximumAttempts,
                   http.statusCode != 429, RemoteMediaHTTPError.retryDelay(from: http) == nil,
                   HTTPMediaRedirectRetryPolicy.isRetryable(statusCode: http.statusCode) {
                    discard(result.0)
                    continue attempts
                }
                return result
            }
        }
        throw URLError(.httpTooManyRedirects)
    }

    static func requiresPlainSocket(for url: URL) -> Bool {
        InsecureHTTPHostPolicy.requiresExplicitTrust(for: url)
    }

    /// The caller owns the complete media redirect chain, including public
    /// HTTP hops. The supplied session must reject automatic redirects.
    static func downloadWithoutRedirects(
        for request: URLRequest, session: URLSession,
        maximumRangedBodyBytes: Int? = nil,
        wholeResponsePrefixLimit: Int? = nil
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url else { throw URLError(.badURL) }
        if requiresPlainSocket(for: url) {
            _ = try await trustedPublicHTTPHost(for: url)
            return try await PlainHTTPClient.download(
                for: request,
                maximumRangedBodyBytes: maximumRangedBodyBytes,
                wholeResponsePrefixLimit: wholeResponsePrefixLimit
            )
        }
        if maximumRangedBodyBytes != nil || wholeResponsePrefixLimit != nil {
            return try await boundedSessionDownload(
                for: request, session: session,
                maximumRangedBodyBytes: maximumRangedBodyBytes,
                wholeResponsePrefixLimit: wholeResponsePrefixLimit
            )
        }
        return try await session.download(for: request)
    }

    static func trustTarget(for url: URL) -> String? {
        guard let endpoint = NetworkEndpointIdentity(url: url), endpoint.scheme == "http" else {
            return nil
        }
        return endpoint.key
    }

    static func data(
        for request: URLRequest,
        session: URLSession,
        maxBytes: Int = PlainHTTPClient.defaultMaxBytes
    ) async throws -> (Data, URLResponse) {
        try await data(
            for: request,
            session: session,
            maxBytes: maxBytes,
            redirectCount: 0
        )
    }

    private static func data(
        for request: URLRequest,
        session: URLSession,
        maxBytes: Int,
        redirectCount: Int
    ) async throws -> (Data, URLResponse) {
        // A queue prefetch seed must not turn into a whole-file transfer when
        // a server or proxy ignores `Range`; see `SpeculativeRangeRead`.
        let maxBytes = SpeculativeRangeRead.effectiveLimit(maxBytes)
        guard let url = request.url else { throw URLError(.badURL) }
        guard requiresPlainSocket(for: url) else {
            return try await boundedSessionData(
                for: request,
                session: session,
                maxBytes: maxBytes
            )
        }
        let host = try await trustedPublicHTTPHost(for: url)
        plog("⚠️ Trusted cleartext HTTP request host=\(host) method=\(request.httpMethod ?? "GET")")
        let result = try await PlainHTTPClient.data(for: request, maxBytes: maxBytes)
        guard let response = result.1 as? HTTPURLResponse,
              let redirected = HTTPRedirectRequestPolicy.redirectedRequest(
                from: request,
                response: response
              ) else {
            return result
        }
        guard redirectCount < HTTPRedirectRequestPolicy.maximumRedirects else {
            throw URLError(.httpTooManyRedirects)
        }
        return try await data(
            for: redirected,
            session: session,
            maxBytes: maxBytes,
            redirectCount: redirectCount + 1
        )
    }

    /// URLSession's `data(for:)` buffers the entire response before callers can
    /// validate a Range response. A proxy that silently returns the whole media
    /// resource would therefore bypass `maxBytes` and can exhaust memory. Read
    /// the response incrementally so HTTPS and local HTTP have the same hard
    /// bound as `PlainHTTPClient`.
    private static func boundedSessionData(
        for request: URLRequest,
        session: URLSession,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard maxBytes >= 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let progress = DownloadProgress.observer
        let delegate = BoundedDataTaskDelegate(maxBytes: maxBytes, progress: progress)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    static func data(
        from url: URL,
        session: URLSession,
        maxBytes: Int = PlainHTTPClient.defaultMaxBytes
    ) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), session: session, maxBytes: maxBytes)
    }

    static func download(
        from url: URL,
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return try await download(for: request, session: session)
    }

    static func download(
        for request: URLRequest,
        session: URLSession,
        maximumRangedBodyBytes: Int? = nil,
        wholeResponsePrefixLimit: Int? = nil
    ) async throws -> (URL, URLResponse) {
        try await download(
            for: request,
            session: session,
            redirectCount: 0,
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit
        )
    }

    private static func download(
        for request: URLRequest,
        session: URLSession,
        redirectCount: Int,
        maximumRangedBodyBytes: Int?,
        wholeResponsePrefixLimit: Int?
    ) async throws -> (URL, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard requiresPlainSocket(for: url) else {
            if maximumRangedBodyBytes != nil || wholeResponsePrefixLimit != nil {
                return try await boundedSessionDownload(
                    for: request,
                    session: session,
                    maximumRangedBodyBytes: maximumRangedBodyBytes,
                    wholeResponsePrefixLimit: wholeResponsePrefixLimit
                )
            }
            return try await session.download(for: request)
        }
        let host = try await trustedPublicHTTPHost(for: url)
        plog("⚠️ Trusted cleartext HTTP download host=\(host)")
        let result = try await PlainHTTPClient.download(
            for: request,
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit
        )
        guard let response = result.1 as? HTTPURLResponse,
              let redirected = HTTPRedirectRequestPolicy.redirectedRequest(
                from: request,
                response: response
              ) else {
            return result
        }
        guard redirectCount < HTTPRedirectRequestPolicy.maximumRedirects else {
            try? FileManager.default.removeItem(at: result.0)
            throw URLError(.httpTooManyRedirects)
        }
        try? FileManager.default.removeItem(at: result.0)
        return try await download(
            for: redirected,
            session: session,
            redirectCount: redirectCount + 1,
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit
        )
    }

    /// Told how many bytes arrived, chunk by chunk, while a media download or
    /// range read runs in this task; 0 means a response arrived with no body
    /// yet. A caller that waits on the transfer uses it to tell a slow source
    /// that keeps answering from one that has stopped.
    enum DownloadProgress {
        @TaskLocal static var observer: (@Sendable (Int) -> Void)?
    }

    /// Streams a URLSession response into a temporary file while preserving
    /// the same body limits used by the explicitly trusted cleartext path.
    /// This is also used after a cleartext endpoint redirects to HTTPS so a
    /// redirect cannot silently replace a bounded transfer with an unbounded
    /// `URLSession.download(for:)` task.
    static func boundedSessionDownload(
        for request: URLRequest,
        session: URLSession,
        maximumRangedBodyBytes: Int?,
        wholeResponsePrefixLimit: Int?
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        if let maximumRangedBodyBytes, maximumRangedBodyBytes < 0 {
            throw URLError(.dataLengthExceedsMaximum)
        }
        if let wholeResponsePrefixLimit, wholeResponsePrefixLimit < 0 {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primuse-HTTPS-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        var returnedFile = false
        var closedFile = false
        defer {
            if !closedFile { try? handle.close() }
            if !returnedFile { try? FileManager.default.removeItem(at: fileURL) }
        }

        let progress = DownloadProgress.observer
        let delegate = BoundedDownloadTaskDelegate(
            handle: handle,
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit,
            progress: progress
        )
        let task = session.dataTask(with: request)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
        try Task.checkCancellation()
        try handle.close()
        closedFile = true
        returnedFile = true
        return (fileURL, response)
    }

    private static func trustedPublicHTTPHost(for url: URL) async throws -> String {
        guard let endpoint = trustTarget(for: url) else {
            throw URLError(.badURL)
        }
        if SSLTrustStore.allowsInsecureHTTPHostSync(domain: endpoint) {
            await SSLTrustStore.shared.migrateLegacyInsecureHTTPTrustIfNeeded(
                to: endpoint
            )
            return endpoint
        }
        let approved = await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: endpoint)
        guard approved else {
            throw TrustedHTTPTransportError.permissionRequired(host: endpoint)
        }
        return endpoint
    }
}

final class MediaHTTPRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let trust: SmartSSLDelegate
    init(trust: SmartSSLDelegate) { self.trust = trust }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust.urlSession(session, task: task, didReceive: challenge)
    }
}

private final class BoundedDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let progress: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var isCancelled = false
    private var terminalError: Error?
    private var response: URLResponse?
    private var data = Data()
    private var unreported = 0

    init(maxBytes: Int, progress: (@Sendable (Int) -> Void)?) {
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func start(
        task: URLSessionDataTask,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.delegate = self
        task.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = response
        if response.expectedContentLength > 0,
           response.expectedContentLength <= Int64(maxBytes) {
            data.reserveCapacity(min(Int(response.expectedContentLength), 4 * 1_024 * 1_024))
        }
        lock.unlock()
        progress?(0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        var toReport = 0
        var exceededLimit = false
        lock.lock()
        if isCancelled || terminalError != nil {
            lock.unlock()
            return
        }
        if chunk.count > maxBytes - data.count {
            terminalError = URLError(.dataLengthExceedsMaximum)
            exceededLimit = true
        } else {
            data.append(chunk)
            unreported += chunk.count
            if unreported >= 16 * 1_024 {
                toReport = unreported
                unreported = 0
            }
        }
        lock.unlock()
        if exceededLimit {
            dataTask.cancel()
            return
        }
        if toReport > 0 {
            progress?(toReport)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let isCancelled = self.isCancelled
        let terminalError = self.terminalError
        let finalResponse = self.response ?? task.response
        let finalData = self.data
        let remainingProgress = self.unreported
        self.data = Data()
        self.unreported = 0
        lock.unlock()

        guard let continuation else { return }
        if isCancelled {
            continuation.resume(throwing: error ?? CancellationError())
            return
        }
        if let terminalError {
            continuation.resume(throwing: terminalError)
            return
        }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let finalResponse else {
            continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        if remainingProgress > 0 {
            progress?(remainingProgress)
        }
        continuation.resume(returning: (finalData, finalResponse))
    }
}

private final class BoundedDownloadTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let maximumRangedBodyBytes: Int?
    private let wholeResponsePrefixLimit: Int?
    private let progress: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var isCancelled = false
    private var completedEarly = false
    private var terminalError: Error?
    private var response: URLResponse?
    private var isWholeResponsePrefix = false
    private var bodyLimit = 0
    private var writtenBytes = 0

    init(
        handle: FileHandle,
        maximumRangedBodyBytes: Int?,
        wholeResponsePrefixLimit: Int?,
        progress: (@Sendable (Int) -> Void)?
    ) {
        self.handle = handle
        self.maximumRangedBodyBytes = maximumRangedBodyBytes
        self.wholeResponsePrefixLimit = wholeResponsePrefixLimit
        self.progress = progress
    }

    func start(
        task: URLSessionDataTask,
        continuation: CheckedContinuation<URLResponse, Error>
    ) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.delegate = self
        task.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let wholePrefix = (response as? HTTPURLResponse)?.statusCode == 200
            && wholeResponsePrefixLimit != nil
        let resolvedLimit = wholePrefix
            ? wholeResponsePrefixLimit
            : (maximumRangedBodyBytes ?? wholeResponsePrefixLimit)

        lock.lock()
        if isCancelled {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = response
        guard let resolvedLimit else {
            terminalError = URLError(.dataLengthExceedsMaximum)
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if !wholePrefix, response.expectedContentLength > Int64(resolvedLimit) {
            terminalError = URLError(.dataLengthExceedsMaximum)
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.isWholeResponsePrefix = wholePrefix
        self.bodyLimit = resolvedLimit
        if wholePrefix, resolvedLimit == 0 {
            completedEarly = true
            lock.unlock()
            progress?(0)
            completionHandler(.cancel)
            return
        }
        lock.unlock()
        progress?(0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !chunk.isEmpty else { return }
        var sliceToWrite: Data?
        var shouldCancelTask = false

        lock.lock()
        if isCancelled || completedEarly || terminalError != nil {
            lock.unlock()
            return
        }
        let remaining = bodyLimit - writtenBytes
        if isWholeResponsePrefix {
            let count = min(chunk.count, max(0, remaining))
            if count > 0 {
                sliceToWrite = count == chunk.count ? chunk : Data(chunk.prefix(count))
                writtenBytes += count
            }
            if writtenBytes >= bodyLimit {
                completedEarly = true
                shouldCancelTask = true
            }
        } else if chunk.count > remaining {
            terminalError = URLError(.dataLengthExceedsMaximum)
            shouldCancelTask = true
        } else {
            sliceToWrite = chunk
            writtenBytes += chunk.count
        }
        lock.unlock()

        if let sliceToWrite {
            do {
                try handle.write(contentsOf: sliceToWrite)
                progress?(sliceToWrite.count)
            } catch {
                lock.lock()
                if terminalError == nil { terminalError = error }
                lock.unlock()
                dataTask.cancel()
                return
            }
        }
        if shouldCancelTask {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let isCancelled = self.isCancelled
        let completedEarly = self.completedEarly
        let terminalError = self.terminalError
        let finalResponse = self.response ?? task.response
        lock.unlock()

        guard let continuation else { return }
        if isCancelled {
            continuation.resume(throwing: error ?? CancellationError())
            return
        }
        if let terminalError {
            continuation.resume(throwing: terminalError)
            return
        }
        if completedEarly, let finalResponse {
            continuation.resume(returning: finalResponse)
            return
        }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let finalResponse else {
            continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        continuation.resume(returning: finalResponse)
    }
}
