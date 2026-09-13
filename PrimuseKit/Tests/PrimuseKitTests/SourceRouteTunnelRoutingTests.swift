import Foundation
import Network
import Testing
@testable import PrimuseKit

@Suite struct SourceRoutePathConditionTests {
    @Test func tunnelPathsKeepThePrivateRouteEligible() {
        #expect(SourceRoutePathCondition(interfaceClass: .directLocal).prefersPrivateRouteFirst)
        // A VPN or Tailscale tunnel is reported as `.other`, which used to demote
        // every private candidate to second place.
        #expect(SourceRoutePathCondition(interfaceClass: .tunnel, usesTunnel: true)
            .prefersPrivateRouteFirst)
        #expect(SourceRoutePathCondition(interfaceClass: .unknown).prefersPrivateRouteFirst)
        #expect(SourceRoutePathCondition(interfaceClass: .cellular).prefersPrivateRouteFirst == false)
        // Cellular carrying a tunnel can still reach an overlay peer.
        #expect(SourceRoutePathCondition(interfaceClass: .cellular, usesTunnel: true)
            .prefersPrivateRouteFirst)
        #expect(SourceRoutePathCondition(interfaceClass: .unavailable).prefersPrivateRouteFirst == false)
        // An expensive Wi-Fi path (a shared hotspot) still has a LAN.
        #expect(SourceRoutePathCondition(interfaceClass: .directLocal, isExpensive: true)
            .prefersPrivateRouteFirst)
    }

    @Test func probeBudgetFollowsTheTunnelAndTheAddress() {
        let lan = SourceConnectionEndpoint(host: "192.168.1.20", port: 5000, useSsl: false)
        let tailnet = SourceConnectionEndpoint(host: "100.96.0.7", port: 5000, useSsl: false)
        let magicDNS = SourceConnectionEndpoint(host: "nas.tail1a2b.ts.net", port: 5000, useSsl: true)

        let direct = SourceRoutePathCondition(interfaceClass: .directLocal)
        #expect(direct.probeTimeout(for: lan) == SourceRoutePathCondition.directProbeTimeout)
        // A split tunnel reports Wi-Fi while the overlay peer behind it still
        // needs the tunnel budget.
        #expect(direct.probeTimeout(for: tailnet) == SourceRoutePathCondition.tunnelProbeTimeout)
        #expect(direct.probeTimeout(for: magicDNS) == SourceRoutePathCondition.tunnelProbeTimeout)

        let tunnel = SourceRoutePathCondition(interfaceClass: .tunnel, usesTunnel: true)
        #expect(tunnel.probeTimeout(for: lan) == SourceRoutePathCondition.tunnelProbeTimeout)
        #expect(SourceRoutePathCondition(interfaceClass: .cellular).probeTimeout(for: lan)
            == SourceRoutePathCondition.cellularProbeTimeout)

        // Only paths that can be waiting on a tunnel handshake retry.
        #expect(direct.retriesTimedOutProbe(for: lan) == false)
        #expect(direct.retriesTimedOutProbe(for: tailnet))
        #expect(tunnel.retriesTimedOutProbe(for: lan))
        #expect(direct.retriesTimedOutProbe(for: nil) == false)
    }

    @Test func addressLiteralsAreNotProbedOnAPathWithoutThatFamily() {
        let ipv4 = SourceConnectionEndpoint(host: "192.168.1.20", port: 445, useSsl: false)
        let ipv6 = SourceConnectionEndpoint(host: "fd7a:115c:a1e0::1", port: 445, useSsl: false)
        let name = SourceConnectionEndpoint(host: "nas.example.com", port: 445, useSsl: false)

        let ipv4Only = SourceRoutePathCondition(interfaceClass: .directLocal, supportsIPv6: false)
        #expect(ipv4Only.canProbeAddressFamily(of: ipv4))
        #expect(ipv4Only.canProbeAddressFamily(of: ipv6) == false)
        // A hostname still resolves through DNS64/NAT64.
        #expect(ipv4Only.canProbeAddressFamily(of: name))

        let ipv6Only = SourceRoutePathCondition(interfaceClass: .cellular, supportsIPv4: false)
        #expect(ipv6Only.canProbeAddressFamily(of: ipv4) == false)
        #expect(ipv6Only.canProbeAddressFamily(of: ipv6))
        #expect(SourceRoutePathCondition.unknown.canProbeAddressFamily(of: ipv6))
    }

    @Test func onlyTimeoutsGetTheShortPrivateRouteCooldown() async {
        #expect(SourceRouteFailureReason.classify(URLError(.timedOut)) == .timedOut)
        #expect(SourceRouteFailureReason.classify(URLError(.dnsLookupFailed)) == .timedOut)
        #expect(SourceRouteFailureReason.classify(URLError(.cannotConnectToHost)) == .refused)
        #expect(SourceRouteFailureReason.classify(NWError.posix(.ETIMEDOUT)) == .timedOut)
        #expect(SourceRouteFailureReason.classify(NWError.posix(.ECONNREFUSED)) == .refused)
        #expect(SourceRouteFailureReason.classify(NWError.dns(-65554)) == .timedOut)
        #expect(SourceRouteFailureReason.classify(NSError(
            domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]
        )) == .timedOut)

        let runtime = SourceConnectionRuntime()
        let start = Date(timeIntervalSince1970: 1_000)
        let kinds: [SourceConnectionCandidateKind] = [.localAddress, .publicAddress]
        await runtime.recordFailure(of: .localAddress, for: "nas", reason: .timedOut, now: start)
        let shortRetry = start.addingTimeInterval(SourceConnectionRuntime.localTimeoutRetryInterval)
        #expect(await runtime.preferredKind(
            for: "nas", availableKinds: kinds, prefersLocalNetwork: true, now: shortRetry
        ) == .localAddress)

        await runtime.recordFailure(of: .localAddress, for: "other", reason: .refused, now: start)
        #expect(await runtime.preferredKind(
            for: "other", availableKinds: kinds, prefersLocalNetwork: true, now: shortRetry
        ) == .publicAddress)
    }

    @Test func observedTunnelPathPrefersThePrivateRoute() async {
        let runtime = SourceConnectionRuntime()
        await runtime.observeNetworkPath(
            condition: SourceRoutePathCondition(interfaceClass: .tunnel, usesTunnel: true),
            pathChanged: false
        )
        #expect(await runtime.pathCondition().interfaceClass == .tunnel)
        #expect(await runtime.preferredKind(
            for: "nas", availableKinds: [.localAddress, .publicAddress]
        ) == .localAddress)

        await runtime.observeNetworkPath(
            condition: SourceRoutePathCondition(interfaceClass: .cellular),
            pathChanged: true
        )
        #expect(await runtime.preferredKind(
            for: "nas", availableKinds: [.localAddress, .publicAddress]
        ) == .publicAddress)
    }

    @Test func everyRouteWithAFallbackGetsAHandshakeDeadline() {
        let both: [SourceConnectionCandidateKind] = [.localAddress, .publicAddress]
        #expect(SourceConnectionHandshakePolicy.timeout(for: .localAddress, availableKinds: both)
            == SourceConnectionHandshakePolicy.localFallbackTimeout)
        // Previously nil: a stalled public handshake had no deadline at all.
        #expect(SourceConnectionHandshakePolicy.timeout(for: .publicAddress, availableKinds: both)
            == SourceConnectionHandshakePolicy.remoteFallbackTimeout)
        #expect(SourceConnectionHandshakePolicy.timeout(
            for: .vendorRemote, availableKinds: [.localAddress, .vendorRemote]
        ) == SourceConnectionHandshakePolicy.vendorFallbackTimeout)
        // A single-route source must keep waiting for its own errors.
        #expect(SourceConnectionHandshakePolicy.timeout(for: .publicAddress, availableKinds: [.publicAddress]) == nil)
        #expect(SourceConnectionHandshakePolicy.timeout(for: .localAddress, availableKinds: [.localAddress]) == nil)
    }

    @Test func reachableRouteDoesNotWaitBehindAnotherRoutesTimeout() async {
        let lan = SourceConnectionEndpoint(host: "192.168.40.5", port: 4533, useSsl: false)
        let remote = SourceConnectionEndpoint(host: "public.invalid", port: 443, useSsl: true)
        let started = Date()
        let unreachable = await SourceNetworkFailurePolicy.allEndpointsAreUnreachable(
            [lan, remote],
            probe: { endpoint in
                guard endpoint.host == lan.host else { return }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw URLError(.timedOut)
            }
        )
        #expect(unreachable == false)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }
}

@Suite struct PrivateOverlayHostPolicyTests {
    @Test func tailnetAddressesCountAsPrivateForRouting() {
        for host in ["100.64.0.1", "100.96.0.7", "100.127.255.254",
                     "nas.tail1a2b.ts.net", "NAS.TAIL1A2B.TS.NET",
                     "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12::5]"] {
            #expect(PrivateOverlayHostPolicy.isOverlayHost(host), "expected overlay: \(host)")
            #expect(PrivateOverlayHostPolicy.isPrivateOrOverlayHost(host))
        }
        for host in ["100.63.255.255", "100.128.0.1", "8.8.8.8", "nas.example.com",
                     "example.ts.net.evil.com", "192.168.1.10", "2001:4860:4860::8888"] {
            #expect(PrivateOverlayHostPolicy.isOverlayHost(host) == false, "unexpected overlay: \(host)")
        }
        #expect(PrivateOverlayHostPolicy.isPrivateOrOverlayHost("192.168.1.10"))
        #expect(PrivateOverlayHostPolicy.isPrivateOrOverlayHost("8.8.8.8") == false)
    }

    @Test func certificateAndCleartextRulesStayStrict() {
        // Deliberate boundary: an overlay address is good enough to pick a route,
        // never to silently accept a certificate or cleartext HTTP. A carrier-grade
        // NAT address can also appear on a hostile mobile network.
        #expect(InsecureHTTPHostPolicy.isPrivateIPAddressLiteral("100.64.0.1") == false)
        #expect(InsecureHTTPHostPolicy.isLocalNetworkHost("nas.tail1a2b.ts.net") == false)
        #expect(InsecureHTTPHostPolicy.requiresExplicitTrust(
            for: URL(string: "http://100.64.0.1:5000/stream")!
        ))
    }
}

@Suite struct NetworkHostAuthorityTests {
    @Test func ipv6LiteralsKeepTheirPortAndBrackets() {
        #expect(NetworkHostAuthority.addressFamily(of: "fd7a:115c:a1e0::1") == .ipv6)
        #expect(NetworkHostAuthority.addressFamily(of: "[fd7a::1]") == .ipv6)
        #expect(NetworkHostAuthority.addressFamily(of: "fe80::1%en0") == .ipv6)
        #expect(NetworkHostAuthority.addressFamily(of: "192.168.1.4") == .ipv4)
        #expect(NetworkHostAuthority.addressFamily(of: "nas.local") == .name)

        #expect(NetworkHostAuthority.urlHost("fd7a::1") == "[fd7a::1]")
        #expect(NetworkHostAuthority.urlHost("[fd7a::1]") == "[fd7a::1]")
        #expect(NetworkHostAuthority.urlHost("nas.local.") == "nas.local")
        #expect(NetworkHostAuthority.authority(host: "fd7a::1", port: 5000) == "[fd7a::1]:5000")
        #expect(NetworkHostAuthority.authority(host: "nas.local", port: nil) == "nas.local")

        var split = NetworkHostAuthority.splitHostAndPort("[fd7a::1]:5001")
        #expect(split.host == "fd7a::1")
        #expect(split.port == 5001)
        split = NetworkHostAuthority.splitHostAndPort("fd7a::1")
        #expect(split.host == "fd7a::1")
        #expect(split.port == nil)
        split = NetworkHostAuthority.splitHostAndPort("nas.local:5002")
        #expect(split.host == "nas.local")
        #expect(split.port == 5002)
    }

    @Test func baseURLKeepsSchemePortAndProxyPath() {
        #expect(NetworkHostAuthority.baseURL(
            address: "fd7a:115c:a1e0::1", defaultScheme: "http", port: 8096
        )?.absoluteString == "http://[fd7a:115c:a1e0::1]:8096")
        #expect(NetworkHostAuthority.baseURL(
            address: "https://ug.example.com:9443/ug-proxy", defaultScheme: "http", port: 9999
        )?.absoluteString == "https://ug.example.com:9443/ug-proxy")
        #expect(NetworkHostAuthority.baseURL(
            address: "nas.local", defaultScheme: "https", port: 5001
        )?.absoluteString == "https://nas.local:5001")
        #expect(NetworkHostAuthority.baseURL(
            address: "[fd7a::1]:5001", defaultScheme: "http", port: 80
        )?.absoluteString == "http://[fd7a::1]:5001")
        #expect(NetworkHostAuthority.baseURL(address: "   ", defaultScheme: "http", port: 80) == nil)
    }

    @Test func resolversBuildUsableIPv6BaseURLs() {
        #expect(MediaServerStreamResolver.baseURL(
            host: "fd7a::1", port: 8096, useSsl: false, basePath: "/jf"
        )?.absoluteString == "http://[fd7a::1]:8096/jf")
        #expect(SubsonicStreamResolver.makeBaseURL(
            host: "fd7a::1", port: 4533, useSsl: false, basePath: nil
        )?.absoluteString == "http://[fd7a::1]:4533")
        #expect(SynologyStreamResolver.baseURL(
            host: "fd7a::1", port: 5001, useSsl: true
        )?.absoluteString == "https://[fd7a::1]:5001")
        #expect(NasHttpStreamResolver.baseURL(
            host: "[fd7a::1]:8443", port: 8080, useSsl: false
        )?.absoluteString == "http://[fd7a::1]:8443")
    }

    @Test func endpointNormalizationCanonicalizesIPv6Literals() {
        var endpoint = SourceConnectionEndpoint(host: "fd7a:115c:a1e0::1", port: 5000, useSsl: false)
        #expect(endpoint.normalized.host == "fd7a:115c:a1e0::1")
        #expect(endpoint.normalized.port == 5000)
        #expect(endpoint.isUsable)
        #expect(endpoint.urlHost == "[fd7a:115c:a1e0::1]")
        #expect(endpoint.displayDescription == "[fd7a:115c:a1e0::1]:5000")

        // A bracketed literal may carry its own port, which wins over the field.
        endpoint = SourceConnectionEndpoint(host: "[fd7a::1]:5555", port: 5000, useSsl: false)
        #expect(endpoint.normalized.host == "fd7a::1")
        #expect(endpoint.normalized.port == 5555)

        // A full URL keeps working and stores the canonical literal.
        endpoint = SourceConnectionEndpoint(host: "https://[fd7a::1]:5001/dav", port: 80, useSsl: false)
        let normalized = endpoint.normalized
        #expect(normalized.host == "fd7a::1")
        #expect(normalized.port == 5001)
        #expect(normalized.useSsl)
        #expect(normalized.pathPrefix == "/dav")

        // IPv4 and hostnames are untouched.
        #expect(SourceConnectionEndpoint(host: "192.168.1.4", port: 445, useSsl: false)
            .normalized.host == "192.168.1.4")
        #expect(SourceConnectionEndpoint(host: "nas.local:445", port: 139, useSsl: false)
            .normalized.port == 445)
    }
}
