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
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        if response.expectedContentLength > 0,
           response.expectedContentLength <= Int64(maxBytes) {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maxBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, response)
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

        let (bytes, response) = try await session.bytes(for: request)
        let isWholeResponsePrefix = (response as? HTTPURLResponse)?.statusCode == 200
            && wholeResponsePrefixLimit != nil
        let bodyLimit = isWholeResponsePrefix
            ? wholeResponsePrefixLimit
            : (maximumRangedBodyBytes ?? wholeResponsePrefixLimit)
        guard let bodyLimit else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        if !isWholeResponsePrefix,
           response.expectedContentLength > Int64(bodyLimit) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var iterator = bytes.makeAsyncIterator()
        var buffer = Data()
        buffer.reserveCapacity(min(64 * 1_024, bodyLimit))
        var writtenBytes = 0
        while writtenBytes < bodyLimit, let byte = try await iterator.next() {
            buffer.append(byte)
            writtenBytes += 1
            if buffer.count == 64 * 1_024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        if !isWholeResponsePrefix,
           writtenBytes == bodyLimit,
           try await iterator.next() != nil {
            throw URLError(.dataLengthExceedsMaximum)
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
