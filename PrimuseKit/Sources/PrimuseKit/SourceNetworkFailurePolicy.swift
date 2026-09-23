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
        probe: @escaping EndpointProbe = SourceConnectionPreflight.check
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

    /// Endpoints that can still speak for a source's reachability. A private
    /// route inside its handshake cooldown has already shown that a TCP answer
    /// on this path does not reach the service — a VPN or proxy can complete
    /// that handshake on the device itself — so only the other routes decide.
    public static func availabilityEndpoints(
        _ candidates: [SourceConnectionCandidate],
        localRouteBackedOff: Bool
    ) -> [SourceConnectionEndpoint?] {
        guard localRouteBackedOff,
              candidates.contains(where: { $0.kind != .localAddress }) else {
            return candidates.map(\.endpoint)
        }
        return candidates.filter { $0.kind != .localAddress }.map(\.endpoint)
    }

    /// A handshake that reached a port and then stalled or broke: a timeout,
    /// a dropped connection, a failed TLS negotiation, or any transport
    /// failure. Trust decisions, authentication and cancellation are not.
    public static func isStalledHandshake(_ error: any Error) -> Bool {
        if isNetworkFailure(error) { return true }
        return containsURLErrorCode(
            error,
            codes: [URLError.Code.secureConnectionFailed.rawValue, URLError.Code.networkConnectionLost.rawValue],
            depth: 0
        )
    }

    private static func containsURLErrorCode(_ error: any Error, codes: Set<Int>, depth: Int) -> Bool {
        guard depth < 8, !(error is CancellationError) else { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, codes.contains(nsError.code) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return containsURLErrorCode(underlying, codes: codes, depth: depth + 1)
        }
        return false
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

/// When an already signed-in connector must prove its route again.
///
/// A server connector keeps its session across a network change, so its
/// `connect()` used to return at once. The router then trusted a private
/// route that a VPN or proxy answered on the device, and every request waited
/// out its full timeout. After the path changes, one lightweight request
/// inside `connect()` lets the router's handshake deadline catch that route.
public enum SourceSessionRouteValidation {
    /// - Parameter verifiedGeneration: the `SourceConnectionRuntime`
    ///   route generation of the last successful sign-in or check; `nil` when
    ///   none has been recorded.
    public static func needsRevalidation(verifiedGeneration: UInt64?, currentGeneration: UInt64) -> Bool {
        verifiedGeneration != currentGeneration
    }
}
