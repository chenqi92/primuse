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

    /// A public address is never on the LAN, whatever interface the device is
    /// using. It has to be resolved and then reached across the Internet — a
    /// DDNS name whose only record is an AAAA is the slowest case — so the LAN
    /// budget used to retire a route whose own handshake is allowed 20 seconds.
    @Test func publicAddressesAreNotJudgedByTheLANProbeBudget() {
        let lan = SourceConnectionEndpoint(host: "192.168.1.20", port: 5006, useSsl: false)
        let lanName = SourceConnectionEndpoint(host: "nas.local", port: 5006, useSsl: false)
        let ula = SourceConnectionEndpoint(host: "fd00::5", port: 5006, useSsl: false)
        let tailnet = SourceConnectionEndpoint(host: "nas.tail1a2b.ts.net", port: 5000, useSsl: true)
        let remoteName = SourceConnectionEndpoint(host: "dav.example.com", port: 8443, useSsl: true)
        let remoteLiteral = SourceConnectionEndpoint(host: "2408:8207::1", port: 8443, useSsl: true)
        let remoteURL = SourceConnectionEndpoint(
            host: "https://dav.example.com:8443/dav", port: 443, useSsl: false
        )

        let wifi = SourceRoutePathCondition(interfaceClass: .directLocal)
        #expect(wifi.probeTimeout(for: lan) == SourceRoutePathCondition.directProbeTimeout)
        #expect(wifi.probeTimeout(for: lanName) == SourceRoutePathCondition.directProbeTimeout)
        #expect(wifi.probeTimeout(for: ula) == SourceRoutePathCondition.directProbeTimeout)
        #expect(wifi.probeTimeout(for: nil) == SourceRoutePathCondition.directProbeTimeout)
        #expect(wifi.probeTimeout(for: tailnet) == SourceRoutePathCondition.tunnelProbeTimeout)
        #expect(wifi.probeTimeout(for: remoteName) == SourceRoutePathCondition.remoteProbeTimeout)
        #expect(wifi.probeTimeout(for: remoteLiteral) == SourceRoutePathCondition.remoteProbeTimeout)
        #expect(wifi.probeTimeout(for: remoteURL) == SourceRoutePathCondition.remoteProbeTimeout)
        #expect(SourceRoutePathCondition.remoteProbeTimeout
            > SourceRoutePathCondition.directProbeTimeout)
        #expect(SourceRoutePathCondition.remoteProbeTimeout
            < SourceConnectionHandshakePolicy.localFallbackTimeout)

        // A slower path never shrinks below its own budget.
        let tunnel = SourceRoutePathCondition(interfaceClass: .tunnel, usesTunnel: true)
        #expect(tunnel.probeTimeout(for: remoteName) >= SourceRoutePathCondition.tunnelProbeTimeout)
        #expect(tunnel.probeTimeout(for: lan) == SourceRoutePathCondition.tunnelProbeTimeout)
        let cellular = SourceRoutePathCondition(interfaceClass: .cellular)
        #expect(cellular.probeTimeout(for: remoteName)
            >= SourceRoutePathCondition.cellularProbeTimeout)
        #expect(cellular.probeTimeout(for: lan) == SourceRoutePathCondition.cellularProbeTimeout)

        // The wider budget must not turn every dead WAN route into two waits.
        #expect(wifi.retriesTimedOutProbe(for: remoteName) == false)
    }

    @Test(arguments: ["192.168.1.20", "fd7a:115c:a1e0::1", "nas.example.com"])
    func defaultPathAddressFamiliesCannotRejectAnEndpoint(host: String) async throws {
        let endpoint = SourceConnectionEndpoint(host: host, port: 445, useSsl: false)
        for interfaceClass: SourceRouteInterfaceClass in [.directLocal, .tunnel, .cellular, .unavailable] {
            let condition = SourceRoutePathCondition(
                interfaceClass: interfaceClass, supportsIPv4: false, supportsIPv6: false
            )
            let probe = PreflightProbeRecorder()
            try await SourceConnectionPreflight.check(endpoint, condition: condition) { target, timeout in
                #expect(target == endpoint)
                #expect(timeout == condition.probeTimeout(for: endpoint))
                await probe.record()
            }
            #expect(await probe.attempts == 1)
        }
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
        // 单路由源没有可退的路,但也不能永远等:兜底上限比任何一条 fallback 预算都宽,
        // 到点了以超时收场,而不是让界面一直转圈。
        #expect(SourceConnectionHandshakePolicy.timeout(for: .publicAddress, availableKinds: [.publicAddress])
            == SourceConnectionHandshakePolicy.soleRouteTimeout)
        #expect(SourceConnectionHandshakePolicy.timeout(for: .localAddress, availableKinds: [.localAddress])
            == SourceConnectionHandshakePolicy.soleRouteTimeout)
        #expect(SourceConnectionHandshakePolicy.soleRouteTimeout
            > SourceConnectionHandshakePolicy.vendorFallbackTimeout)
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

        // A zone identifier only survives a URL in escaped form: a raw `%` makes
        // URLComponents reject the string and traps `percentEncodedHost`.
        #expect(NetworkHostAuthority.urlHost("fe80::1%en0") == "[fe80::1%en0]")
        #expect(NetworkHostAuthority.percentEncodedURLHost("fe80::1%en0") == "[fe80::1%25en0]")
        #expect(NetworkHostAuthority.percentEncodedURLHost("fe80::1%25en0") == "[fe80::1%25en0]")
        #expect(NetworkHostAuthority.percentEncodedURLHost("nas.local") == "nas.local")
        #expect(NetworkHostAuthority.authority(host: "fe80::1%en0", port: 5000) == "[fe80::1%25en0]:5000")
        #expect(NetworkHostAuthority.baseURL(
            address: "fe80::1%en0", defaultScheme: "http", port: 5005
        )?.absoluteString == "http://[fe80::1%25en0]:5005")

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

    @Test(arguments: ["/music%20proxy", "/%E9%9F%B3%E4%B9%90", "/escaped%2Fsegment/%25", "/proxy//nested/"])
    func encodedProxyPathSurvivesURLReconstruction(path: String) throws {
        let address = "https://nas.example.com:5443" + path
        #expect(NetworkHostAuthority.baseURL(
            address: address, defaultScheme: "http", port: 80
        )?.absoluteString == address)
        #expect(SynologyStreamResolver.baseURL(
            host: address, port: 80, useSsl: false
        )?.absoluteString == address)
        #expect(NasHttpStreamResolver.baseURL(
            host: address, port: 80, useSsl: false
        )?.absoluteString == address)
    }

    @Test func rawProxyPathIsEncodedOnceAcrossSourceProjectionAndResolver() throws {
        let source = MusicSource(name: "NAS", type: .synology)
        let projected = source.applyingConnectionCandidate(.init(
            kind: .publicAddress,
            endpoint: .init(host: "nas.example.com", port: 5443, useSsl: true, pathPrefix: "/音乐 proxy/100%")
        ))
        let expected = "https://nas.example.com:5443/%E9%9F%B3%E4%B9%90%20proxy/100%25"
        #expect(projected.host == expected)
        let host = try #require(projected.host)
        #expect(SynologyStreamResolver.baseURL(host: host, port: 5443, useSsl: true)?.absoluteString == expected)
        #expect(NetworkHostAuthority.baseURL(
            address: host + "/", defaultScheme: "http", port: 80, path: "/a%20b #?"
        )?.absoluteString == expected + "/a%2520b%20%23%3F")
    }

    @Test func unescapedAddressPathsEncodeChineseAndSpaces() {
        for (raw, encoded) in [
            ("我的音乐", "%E6%88%91%E7%9A%84%E9%9F%B3%E4%B9%90"),
            ("my music", "my%20music"),
            ("我的 音乐", "%E6%88%91%E7%9A%84%20%E9%9F%B3%E4%B9%90")
        ] {
            let base = NetworkHostAuthority.baseURL(
                address: "https://nas.example.com/" + raw, defaultScheme: "http", port: nil
            )
            #expect(base?.absoluteString == "https://nas.example.com/" + encoded)
            #expect(base?.appendingPathComponent("api").absoluteString == "https://nas.example.com/" + encoded + "/api")
        }
    }

    @Test func addressURLDelimitersAndLiteralPathCharactersStayDistinct() {
        #expect(NetworkHostAuthority.baseURL(
            address: "https://nas.example.com/dav?key=value#fragment",
            defaultScheme: "http", port: nil, path: "/music"
        )?.absoluteString == "https://nas.example.com/dav/music?key=value#fragment")
        #expect(NetworkHostAuthority.baseURL(
            address: "https://nas.example.com/dav%3Fkey%23fragment",
            defaultScheme: "http", port: nil, path: "/music"
        )?.absoluteString == "https://nas.example.com/dav%3Fkey%23fragment/music")
        #expect(NetworkHostAuthority.baseURL(
            address: "https://nas.example.com", defaultScheme: "http", port: nil, path: "/dav?key#fragment/music"
        )?.absoluteString == "https://nas.example.com/dav%3Fkey%23fragment/music")
        for address in ["https://nas.example.com", "https://nas.example.com/"] {
            #expect(NetworkHostAuthority.baseURL(
                address: address, defaultScheme: "http", port: nil
            )?.appendingPathComponent("api").absoluteString == "https://nas.example.com/api")
        }
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

    /// A WebDAV source reached by a DNS name whose only record is an AAAA. The
    /// name must survive every builder as a name: bracketing it, or storing it
    /// as a literal, makes the lookup fail before a packet is ever sent.
    @Test(arguments: ["dav.example.com", "ddns.example.com.", "my-nas.dyndns.example.org"])
    func dnsNamesNeverBecomeAddressLiterals(name: String) throws {
        let canonical = NetworkHostAuthority.canonicalHost(name)
        #expect(canonical.hasSuffix(".") == false)
        #expect(NetworkHostAuthority.addressFamily(of: name) == .name)
        #expect(NetworkHostAuthority.urlHost(name) == canonical)
        #expect(NetworkHostAuthority.percentEncodedURLHost(name) == canonical)
        #expect(NetworkHostAuthority.authority(host: name, port: 8443) == "\(canonical):8443")
        #expect(NetworkHostAuthority.baseURL(
            address: name, defaultScheme: "https", port: 8443, path: "/dav"
        )?.absoluteString == "https://\(canonical):8443/dav")
        let embeddedPortURL = try #require(NetworkHostAuthority.baseURL(
            address: "http://\(name):8080/dav/", defaultScheme: "https", port: 8443
        ))
        #expect(embeddedPortURL.host == canonical)
        #expect(embeddedPortURL.absoluteString == "http://\(canonical):8080/dav/")

        var endpoint = SourceConnectionEndpoint(host: name, port: 8443, useSsl: true).normalized
        #expect(endpoint.host == canonical)
        #expect(endpoint.urlHost == canonical)
        #expect(endpoint.displayDescription == "\(canonical):8443")
        endpoint = SourceConnectionEndpoint(
            host: "https://\(name):8443/dav", port: 443, useSsl: false
        ).normalized
        #expect(endpoint.host == canonical)
        #expect(endpoint.port == 8443)
        #expect(endpoint.useSsl)
        #expect(endpoint.pathPrefix == "/dav")

        // Such a name is a public route, never a LAN or overlay one.
        #expect(InsecureHTTPHostPolicy.isLocalNetworkHost(name) == false)
        #expect(PrivateOverlayHostPolicy.isPrivateOrOverlayHost(name) == false)
    }
}

private actor PreflightProbeRecorder {
    private(set) var attempts = 0
    func record() { attempts += 1 }
}
