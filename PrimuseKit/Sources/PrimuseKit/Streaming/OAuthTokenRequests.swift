import Foundation

/// Token issuance shares a client quota across authorization and refresh.
public struct OAuthTokenRequests: Sendable {
    private let registry: RequestQuotaRegistry
    public init(registry: RequestQuotaRegistry = .shared) { self.registry = registry }

    public func data(for request: URLRequest, clientID: String,
                     session: URLSession = .shared) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let quota = Self.quota(for: url, clientID: clientID) else { throw URLError(.badURL) }
        // Before authorization no stable account is known. A client-wide quota
        // conservatively joins code exchange, refresh and rotating credentials.
        return try await registry.execute(for: quota, replay: .never, operation: {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let code = Self.providerErrorCode(in: data)
            if !(200...299).contains(http.statusCode) || code != nil {
                // Provider bodies can echo an authorization code or token. Keep
                // only recognized machine-readable errors in diagnostics.
                let safeBody = code.map { Data("{\"error\":\"\($0)\"}".utf8) } ?? Data()
                throw HTTPResponseFailure(statusCode: http.statusCode, body: safeBody,
                    retryAfter: HTTPResponseFailure.retryDelay(from: http),
                    isRateLimited: code == "slow_down" || code == "rate_limited" || code == "rate_limit_exceeded" || code == "too_many_requests")
            }
            return (data, response)
        })
    }

    public static func quota(for url: URL, clientID: String) -> RequestQuota? {
        // 115 refresh only carries a token. Do not add an optional keychain
        // lookup that could change its quota identity while credentials are locked.
        let account: RequestQuota.Account = url.host?.lowercased() == "passportapi.115.com"
            ? .anonymous : .init(stableID: clientID)
        return RequestQuota(service: .oauthToken, url: url, account: account)
    }

    public static func providerErrorCode(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? String,
              ["invalid_grant", "invalid_client", "unauthorized_client", "access_denied",
               "invalid_request", "invalid_scope", "unsupported_grant_type", "temporarily_unavailable",
               "server_error", "slow_down", "rate_limited", "rate_limit_exceeded", "too_many_requests"].contains(code) else { return nil }
        return code
    }
}
