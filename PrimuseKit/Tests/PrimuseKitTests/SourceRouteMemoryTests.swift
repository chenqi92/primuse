import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source route memory")
struct SourceRouteMemoryTests {
    let kinds: [SourceConnectionCandidateKind] = [.localAddress, .publicAddress]

    @Test func handshakeCooldownSteersEveryCallerToThePublicRoute() async {
        let runtime = SourceConnectionRuntime()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds, prefersLocalNetwork: true, now: now) == .localAddress)
        let interval = await runtime.recordLocalHandshakeFailure(for: "nas", now: now)
        #expect(interval == 30)
        // Any connector instance asks the same actor: scan, playback, write-back.
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds, prefersLocalNetwork: true, now: now) == .publicAddress)
        #expect(await runtime.isLocalRouteBackedOff(for: "nas", now: now.addingTimeInterval(29)))
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas", now: now.addingTimeInterval(31)))
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds, prefersLocalNetwork: true,
                                            now: now.addingTimeInterval(31)) == .localAddress)
        // Other sources are unaffected.
        #expect(await runtime.preferredKind(for: "other", availableKinds: kinds, prefersLocalNetwork: true, now: now) == .localAddress)
    }

    @Test func cooldownOverridesAnActiveLANRecord() async {
        let runtime = SourceConnectionRuntime()
        await runtime.record(.localAddress, for: "nas")
        await runtime.recordLocalHandshakeFailure(for: "nas")
        #expect(await runtime.activeKind(for: "nas") == nil)
        // Vendor relays count as the alternative too.
        #expect(await runtime.preferredKind(for: "nas", availableKinds: [.localAddress, .vendorRemote],
                                            prefersLocalNetwork: true) == .vendorRemote)
        // A LAN-only source always keeps its one route.
        #expect(await runtime.preferredKind(for: "nas", availableKinds: [.localAddress],
                                            prefersLocalNetwork: true) == .localAddress)
    }

    @Test func cooldownGrowsWithConsecutiveFailuresAndResetsOnSuccess() async {
        let runtime = SourceConnectionRuntime()
        let now = Date(timeIntervalSince1970: 5_000)
        var intervals: [TimeInterval] = []
        for _ in 0..<6 { intervals.append(await runtime.recordLocalHandshakeFailure(for: "nas", now: now)) }
        #expect(intervals == [30, 60, 120, 300, 300, 300])
        #expect(await runtime.localHandshakeFailureCount(for: "nas") == 6)
        await runtime.record(.localAddress, for: "nas")
        #expect(await runtime.localHandshakeFailureCount(for: "nas") == 0)
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas", now: now))
        #expect(await runtime.recordLocalHandshakeFailure(for: "nas", now: now) == 30)
        // Recording the public route does not reset the LAN's history.
        await runtime.record(.publicAddress, for: "nas")
        #expect(await runtime.recordLocalHandshakeFailure(for: "nas", now: now) == 60)
    }

    @Test func onlyARealPathChangeClearsTheCooldown() async {
        let runtime = SourceConnectionRuntime()
        await runtime.recordLocalHandshakeFailure(for: "nas")
        let generation = await runtime.routeGeneration()
        await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: false)
        #expect(await runtime.isLocalRouteBackedOff(for: "nas"))
        #expect(await runtime.routeGeneration() == generation)
        await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas"))
        #expect(await runtime.localHandshakeFailureCount(for: "nas") == 0)
        #expect(await runtime.routeGeneration() == generation &+ 1)
        await runtime.recordLocalHandshakeFailure(for: "nas")
        await runtime.invalidate(sourceID: "nas")
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas"))
    }

    @Test func fingerprintAdvancesOnlyOnMaterialChange() {
        func path(
            _ interfaces: [String] = ["wifi:en0"], gateways: [String] = ["192.168.1.1:0"],
            status: String = "satisfied", expensive: Bool = false
        ) -> SourceNetworkPathFingerprint {
            SourceNetworkPathFingerprint(status: status, interfaces: interfaces, gateways: gateways,
                                         supportsIPv4: true, supportsIPv6: true,
                                         isExpensive: expensive, isConstrained: false)
        }
        let home = path()
        #expect(SourceNetworkPathFingerprint.transition(from: nil, to: home) == .initial)
        #expect(SourceNetworkPathFingerprint.transition(from: home, to: path()) == .unchanged)
        // Order of the interface list is not a change.
        #expect(SourceNetworkPathFingerprint.transition(
            from: path(["wifi:en0", "other:utun3"]), to: path(["other:utun3", "wifi:en0"])) == .unchanged)
        #expect(SourceNetworkPathFingerprint.transition(from: home, to: path(gateways: ["10.0.0.1:0"])) == .changed)
        #expect(SourceNetworkPathFingerprint.transition(from: home, to: path(["wifi:en0", "other:utun3"])) == .changed)
        #expect(SourceNetworkPathFingerprint.transition(from: home, to: path(["cellular:pdp_ip0"], expensive: true)) == .changed)
        #expect(SourceNetworkPathFingerprint.transition(from: home, to: path(status: "unsatisfied")) == .changed)
        let summary = path(["wifi:en0", "other:utun3"]).diagnosticSummary(
            condition: SourceRoutePathCondition(interfaceClass: .directLocal, usesTunnel: true))
        #expect(summary.contains("tunnel=true"))
        #expect(summary.contains("interfaces=other,wifi"))
        #expect(!summary.contains("192.168"))
    }

    @Test func backedOffPrivateEndpointDoesNotSpeakForReachability() async {
        let lan = SourceConnectionEndpoint(host: "192.168.0.50", port: 5001, useSsl: true)
        let wan = SourceConnectionEndpoint(host: "nas.example.com", port: 5001, useSsl: true)
        let candidates = [
            SourceConnectionCandidate(kind: .localAddress, endpoint: lan),
            SourceConnectionCandidate(kind: .publicAddress, endpoint: wan),
        ]
        // A TUN proxy answers the private address; the public one is down.
        let probe: SourceNetworkFailurePolicy.EndpointProbe = { endpoint in
            if endpoint.host == "nas.example.com" { throw URLError(.cannotConnectToHost) }
        }
        let trusted = await SourceNetworkFailurePolicy.allEndpointsAreUnreachable(
            SourceNetworkFailurePolicy.availabilityEndpoints(candidates, localRouteBackedOff: false), probe: probe)
        #expect(trusted == false)
        let backedOff = await SourceNetworkFailurePolicy.allEndpointsAreUnreachable(
            SourceNetworkFailurePolicy.availabilityEndpoints(candidates, localRouteBackedOff: true), probe: probe)
        #expect(backedOff == true)
        // With a vendor relay left, the source is never declared down.
        let relay = [candidates[0], SourceConnectionCandidate(kind: .vendorRemote)]
        #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable(
            SourceNetworkFailurePolicy.availabilityEndpoints(relay, localRouteBackedOff: true), probe: probe) == false)
        // A LAN-only source keeps its only endpoint.
        #expect(SourceNetworkFailurePolicy.availabilityEndpoints([candidates[0]], localRouteBackedOff: true) == [lan])
    }

    @Test func stalledHandshakeClassification() {
        #expect(SourceNetworkFailurePolicy.isStalledHandshake(URLError(.timedOut)))
        #expect(SourceNetworkFailurePolicy.isStalledHandshake(URLError(.networkConnectionLost)))
        #expect(SourceNetworkFailurePolicy.isStalledHandshake(URLError(.secureConnectionFailed)))
        #expect(SourceNetworkFailurePolicy.isStalledHandshake(NSError(domain: "wrapper", code: 1, userInfo: [
            NSUnderlyingErrorKey: URLError(.secureConnectionFailed)])))
        #expect(!SourceNetworkFailurePolicy.isStalledHandshake(URLError(.serverCertificateUntrusted)))
        #expect(!SourceNetworkFailurePolicy.isStalledHandshake(URLError(.userAuthenticationRequired)))
        #expect(!SourceNetworkFailurePolicy.isStalledHandshake(CancellationError()))
        #expect(!SourceNetworkFailurePolicy.isStalledHandshake(URLError(.cancelled)))
    }

    @Test func signedInConnectorsProveTheirRouteAgainAfterAPathChange() async {
        let runtime = SourceConnectionRuntime()
        let signedInOn = await runtime.routeGeneration()
        #expect(!SourceSessionRouteValidation.needsRevalidation(
            verifiedGeneration: signedInOn, currentGeneration: await runtime.routeGeneration()))
        // Repeated callbacks for the same path do not cost a request.
        await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: false)
        #expect(!SourceSessionRouteValidation.needsRevalidation(
            verifiedGeneration: signedInOn, currentGeneration: await runtime.routeGeneration()))
        await runtime.observeNetworkPath(prefersLocalNetwork: false, pathChanged: true)
        #expect(SourceSessionRouteValidation.needsRevalidation(
            verifiedGeneration: signedInOn, currentGeneration: await runtime.routeGeneration()))
        #expect(SourceSessionRouteValidation.needsRevalidation(verifiedGeneration: nil, currentGeneration: 0))
    }
}
