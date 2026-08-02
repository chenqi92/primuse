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

    static func data(
        for request: URLRequest,
        session: URLSession,
        maxBytes: Int = PlainHTTPClient.defaultMaxBytes
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard requiresPlainSocket(for: url) else {
            return try await session.data(for: request)
        }
        let host = try trustedPublicHTTPHost(for: url)
        plog("⚠️ Trusted cleartext HTTP request host=\(host) method=\(request.httpMethod ?? "GET")")
        return try await PlainHTTPClient.data(for: request, maxBytes: maxBytes)
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
        guard requiresPlainSocket(for: url) else {
            return try await session.download(for: request)
        }
        let host = try trustedPublicHTTPHost(for: url)
        plog("⚠️ Trusted cleartext HTTP download host=\(host)")
        return try await PlainHTTPClient.download(for: request)
    }

    private static func trustedPublicHTTPHost(for url: URL) throws -> String {
        guard let host = url.host,
              let normalized = InsecureHTTPHostPolicy.normalizedHost(host) else {
            throw URLError(.badURL)
        }
        guard SSLTrustStore.allowsInsecureHTTPHostSync(domain: normalized) else {
            throw TrustedHTTPTransportError.permissionRequired(host: normalized)
        }
        return normalized
    }
}
