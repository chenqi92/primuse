import Foundation
import Network

/// Route health needs transport evidence. Service responses, trust decisions,
/// cancellation and unknown errors must not quarantine a reachable endpoint.
public enum SourceNetworkFailurePolicy {
    public typealias EndpointProbe = @Sendable (SourceConnectionEndpoint) async throws -> Void

    /// A request may reach a CDN, wait for transcoding, or lose just one socket.
    /// Only an independent probe of the configured endpoint can retire a route.
    public static func endpointIsUnreachable(
        _ endpoint: SourceConnectionEndpoint?,
        probe: EndpointProbe = SourceConnectionPreflight.check
    ) async -> Bool {
        guard !Task.isCancelled, let endpoint, endpoint.normalized.isUsable else { return false }
        do {
            try await probe(endpoint)
            return false
        } catch {
            return !Task.isCancelled && isNetworkFailure(error)
        }
    }

    /// A whole source is unavailable only when every configured route has
    /// independent transport evidence. Unknown vendor routes remain eligible.
    public static func allEndpointsAreUnreachable(
        _ endpoints: [SourceConnectionEndpoint?],
        probe: EndpointProbe = SourceConnectionPreflight.check
    ) async -> Bool {
        guard !endpoints.isEmpty else { return false }
        var checked: Set<SourceConnectionEndpoint> = []
        var probed: [SourceConnectionEndpoint] = []
        for candidate in endpoints {
            guard let endpoint = candidate?.normalized, endpoint.isUsable,
                  !Task.isCancelled else { return false }
            if checked.insert(endpoint).inserted { probed.append(endpoint) }
        }
        guard probed.isEmpty == false else { return false }
        // Probe the routes concurrently. Sequential probes made a source that
        // answers on one address wait out every other address' full timeout
        // before playback was allowed to start, which is several seconds once a
        // tunnelled route is in the list.
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for endpoint in probed {
                group.addTask { await Self.endpointIsUnreachable(endpoint, probe: probe) }
            }
            var allUnreachable = true
            for await unreachable in group where unreachable == false {
                allUnreachable = false
                group.cancelAll()
                break
            }
            return allUnreachable && !Task.isCancelled
        }
    }

    public static func isNetworkFailure(_ error: any Error) -> Bool {
        classify(error, depth: 0)
    }

    private static func classify(_ error: any Error, depth: Int) -> Bool {
        guard depth < 8, !(error is CancellationError) else { return false }
        if let networkError = error as? NWError {
            switch networkError {
            case .posix(let code): return isNetworkPOSIXCode(Int(code.rawValue))
            case .dns: return true
            default: return false
            }
        }

        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: error.code) {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            return isNetworkPOSIXCode(error.code)
        }
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            return false
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return classify(underlying, depth: depth + 1)
        }
        return false
    }

    private static func isNetworkPOSIXCode(_ code: Int) -> Bool {
        [ENETDOWN, ENETUNREACH, ENETRESET, ECONNABORTED, ECONNRESET,
         ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, EPIPE]
            .contains { Int($0) == code }
    }
}
