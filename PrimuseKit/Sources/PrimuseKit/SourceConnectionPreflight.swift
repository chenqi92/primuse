import Foundation
import Network

/// A TCP probe establishes reachability only; the connector still owns service
/// authentication. Preserve probe errors so cancellation and policy denials
/// cannot be relabelled as an unreachable network.
public enum SourceConnectionPreflight {
    /// The default probe used everywhere a route's reachability is checked. Its
    /// budget follows the observed network path and the kind of address, and a
    /// tunnel whose first packet timed out gets exactly one retry: a cold
    /// WireGuard/Tailscale handshake otherwise looked identical to an
    /// unreachable NAS and quarantined a route that was about to work.
    public static func check(_ rawEndpoint: SourceConnectionEndpoint) async throws {
        let condition = await SourceConnectionRuntime.shared.pathCondition()
        try await check(rawEndpoint, condition: condition)
    }

    public static func check(
        _ rawEndpoint: SourceConnectionEndpoint,
        condition: SourceRoutePathCondition
    ) async throws {
        try Task.checkCancellation()
        guard condition.canProbeAddressFamily(of: rawEndpoint) else {
            // The path carries no route for this address family, so an address
            // literal of that family cannot be reached however long we wait.
            throw URLError(.cannotConnectToHost)
        }
        let timeout = condition.probeTimeout(for: rawEndpoint)
        do {
            try await connect(rawEndpoint, timeout: timeout)
        } catch {
            guard !Task.isCancelled,
                  condition.retriesTimedOutProbe(for: rawEndpoint),
                  SourceRouteFailureReason.classify(error) == .timedOut else {
                throw error
            }
            try await connect(rawEndpoint, timeout: timeout)
        }
    }

    public static func connect(
        _ rawEndpoint: SourceConnectionEndpoint,
        timeout: TimeInterval = SourceRoutePathCondition.directProbeTimeout
    ) async throws {
        try Task.checkCancellation()
        let endpoint = rawEndpoint.normalized
        guard endpoint.isUsable,
              let rawPort = UInt16(exactly: endpoint.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw URLError(.badURL)
        }
        let connection = NWConnection(host: resolvedHost(endpoint.host), port: port, using: .tcp)
        let race = CancellableResultRace<Void>()
        @Sendable func finish(_ result: Result<Void, Error>) {
            if race.resolve(result) {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
        let deadline = max(0.2, timeout)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error): finish(.failure(error))
                    case .waiting(let error) where !SourceNetworkFailurePolicy.isNetworkFailure(error):
                        finish(.failure(error))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue.global(qos: .userInitiated))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                    finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }

    /// Address literals are handed to `NWConnection` as literals. Going through
    /// `.name` would ask DNS to resolve `fd7a::1`, and a bracketed literal never
    /// resolved at all.
    private static func resolvedHost(_ rawHost: String) -> NWEndpoint.Host {
        let literal = NetworkHostAuthority.canonicalHost(rawHost)
        if let ipv4 = IPv4Address(literal) { return .ipv4(ipv4) }
        if let ipv6 = IPv6Address(literal) { return .ipv6(ipv6) }
        return .name(literal, nil)
    }
}
