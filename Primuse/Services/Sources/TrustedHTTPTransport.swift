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
    static func requiresPlainSocket(for url: URL) -> Bool {
        InsecureHTTPHostPolicy.requiresExplicitTrust(for: url)
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
