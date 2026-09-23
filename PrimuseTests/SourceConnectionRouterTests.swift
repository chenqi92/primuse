import Foundation
import NIOCore
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class SourceConnectionRouterTests: XCTestCase {
    func testBrokenLocalProtocolTriesConfiguredPublicHandshakeDespiteReachableTCP() async throws {
        for error in [URLError(.networkConnectionLost), URLError(.secureConnectionFailed)] {
            let fixture = Fixture()
            await fixture.local.failNextConnect(error)
            let value = try await fixture.read()
            XCTAssertEqual(value, "wan")
            XCTAssertEqual(fixture.events.values, [.publicAddress])
            let localDisconnects = await fixture.local.disconnections
            XCTAssertEqual(localDisconnects, 1)
            let nextRead = try await fixture.read()
            XCTAssertEqual(nextRead, "wan")
            let localConnections = await fixture.local.connections
            XCTAssertEqual(localConnections, 1, "Do not repeat the failed LAN handshake on every read")
            let preferred = await fixture.runtime.preferredKind(for: fixture.id,
                availableKinds: [.localAddress, .publicAddress], prefersLocalNetwork: true)
            XCTAssertEqual(preferred, .publicAddress, "Every connector of the source shares the LAN cooldown")
            let backedOff = await fixture.runtime.isLocalRouteBackedOff(for: fixture.id)
            XCTAssertTrue(backedOff)
            await fixture.runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
            let recovered = try await fixture.read()
            XCTAssertEqual(recovered, "lan", "A network change should allow immediate LAN recovery")
        }
    }

    func testRecoveredLocalHandshakeClearsPublicPreferenceAfterPublicFailure() async throws {
        let fixture = Fixture()
        await fixture.local.failNextConnect(URLError(.networkConnectionLost))
        let initial = try await fixture.read()
        XCTAssertEqual(initial, "wan")
        await fixture.remote.failNextRead(URLError(.networkConnectionLost))
        await fixture.probe.setWANReachable(false)
        let recovered = try await fixture.read()
        XCTAssertEqual(recovered, "lan")
        let next = try await fixture.read()
        XCTAssertEqual(next, "lan")
        let publicConnections = await fixture.remote.connections
        XCTAssertEqual(publicConnections, 1, "Keep the recovered LAN instead of retrying the failed public route")
    }

    func testBusinessAuthenticationTrustAndCancellationErrorsKeepLAN() async throws {
        let errors: [any Error] = [
            PagedSongCatalogError.snapshotChangedDuringPagination, PagedSongCatalogError.unavailable,
            SourceError.connectionFailed("Navidrome server scan failed"), SourceError.connectionFailed("HTTP 503"),
            SourceError.timeout, SourceError.authenticationFailed, SourceError.credentialUnavailable("missing"),
            SourceError.fileNotFound("song"), SourceError.pathNotFound("directory"),
            SourceConnectionTerminalError(message: "password expired"),
            CancellationError(), URLError(.cancelled), URLError(.serverCertificateUntrusted),
            URLError(.badServerResponse), CocoaError(.fileReadCorruptFile),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid JSON"))
        ]
        for error in errors {
            let fixture = Fixture()
            _ = try await fixture.read()
            await fixture.local.failNextRead(error)
            do {
                _ = try await fixture.read()
                XCTFail("Expected original error: \(error)")
            } catch {
                let original = await fixture.local.lastError
                XCTAssertEqual((error as NSError).domain, (original! as NSError).domain)
                XCTAssertEqual((error as NSError).code, (original! as NSError).code)
            }
            let value = try await fixture.read()
            XCTAssertEqual(value, "lan")
            let active = await fixture.runtime.activeKind(for: fixture.id)
            XCTAssertEqual(active, .localAddress)
            let remoteConnections = await fixture.remote.connections
            let localDisconnects = await fixture.local.disconnections
            XCTAssertEqual(remoteConnections, 0)
            XCTAssertEqual(localDisconnects, 0)
            XCTAssertEqual(fixture.events.values, [.localAddress])
        }
    }

    func testExternalMediaFailureKeepsReachableLAN() async throws {
        let error = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://cdn.invalid/art.jpg")!])
        let fixture = Fixture()
        _ = try await fixture.read()
        await fixture.local.failNextRead(error)
        do { _ = try await fixture.read(); XCTFail("Expected request failure") } catch {}
        let next = try await fixture.read()
        XCTAssertEqual(next, "lan")
        await fixture.router.noteDeferredReadFailure(error, routeIndex: 0)
        await fixture.local.failNextRead(error)
        do {
            _ = try await fixture.router.withMutation { try await ($0 as! RouterTestConnector).read() }
            XCTFail("Expected mutation failure")
        } catch {}
        XCTAssertEqual(fixture.events.values, [.localAddress])
        let disconnects = await fixture.local.disconnections
        let publicConnections = await fixture.remote.connections
        XCTAssertEqual(disconnects, 0)
        XCTAssertEqual(publicConnections, 0)
    }

    // Pending Apple-side run.
    /// A connector whose session survived a network change skips its handshake,
    /// so the private route is only found out by the request itself. A VPN or
    /// proxy keeps answering the TCP probe; the read must still move to the
    /// public route, and later reads must not wait on the LAN again.
    func testStalledRequestOnReusedLANSessionMovesReadsToPublicRoute() async throws {
        for error: any Error in [URLError(.networkConnectionLost), URLError(.timedOut),
                                 NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))] {
            let fixture = Fixture()
            _ = try await fixture.read()
            await fixture.local.failNextRead(error)
            let moved = try await fixture.read()
            XCTAssertEqual(moved, "wan")
            let backedOff = await fixture.runtime.isLocalRouteBackedOff(for: fixture.id)
            XCTAssertTrue(backedOff)
            let next = try await fixture.read()
            XCTAssertEqual(next, "wan")
            let localReads = await fixture.local.reads
            XCTAssertEqual(localReads, 2, "The second read must not wait on the LAN again")
            XCTAssertEqual(fixture.events.values, [.localAddress, nil, .publicAddress])
        }
    }

    // Pending Apple-side run.
    func testStalledMutationOnLANIsNotReplayedButRetiresTheRoute() async throws {
        let fixture = Fixture()
        _ = try await fixture.read()
        await fixture.local.failNextRead(URLError(.timedOut))
        do {
            _ = try await fixture.router.withMutation { try await ($0 as! RouterTestConnector).read() }
            XCTFail("Expected mutation failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let remoteReads = await fixture.remote.reads
        XCTAssertEqual(remoteReads, 0, "A mutation is never replayed")
        let backedOff = await fixture.runtime.isLocalRouteBackedOff(for: fixture.id)
        XCTAssertTrue(backedOff)
        let next = try await fixture.read()
        XCTAssertEqual(next, "wan")
    }

    // Pending Apple-side run.
    func testPublicRouteRequestFailureStillNeedsProbeEvidence() async throws {
        for error: any Error in [URLError(.networkConnectionLost), URLError(.timedOut)] {
            let fixture = Fixture()
            await fixture.runtime.observeNetworkPath(prefersLocalNetwork: false, pathChanged: false)
            let first = try await fixture.read()
            XCTAssertEqual(first, "wan")
            await fixture.remote.failNextRead(error)
            do { _ = try await fixture.read(); XCTFail("Expected request failure") } catch {}
            let active = await fixture.runtime.activeKind(for: fixture.id)
            XCTAssertEqual(active, .publicAddress)
            let localConnections = await fixture.local.connections
            XCTAssertEqual(localConnections, 0)
            let next = try await fixture.read()
            XCTAssertEqual(next, "wan")
        }
    }

    // Pending Apple-side run.
    func testSingleRouteRequestFailureStillNeedsProbeEvidence() async throws {
        let runtime = SourceConnectionRuntime()
        let local = RouterTestConnector(sourceID: "lan")
        let router = SourceConnectionRouter(sourceID: UUID().uuidString, candidates: [
            .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), connector: local)
        ], runtime: runtime, endpointProbe: { _ in }) { _ in }
        _ = try await router.withRead { try await ($0 as! RouterTestConnector).read() }
        await local.failNextRead(URLError(.timedOut))
        do { _ = try await router.withRead { try await ($0 as! RouterTestConnector).read() }; XCTFail("Expected failure") } catch {}
        let disconnects = await local.disconnections
        XCTAssertEqual(disconnects, 0)
    }

    func testTransportErrorsFailOverAndClearCurrentDisplayBeforeFallback() async throws {
        let errors: [any Error] = [URLError(.timedOut), URLError(.networkConnectionLost),
                                  NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)),
                                  IOError(errnoCode: ECONNREFUSED, reason: "connection refused"),
                                  ChannelError.connectTimeout(.seconds(1))]
        for error in errors {
            let fixture = Fixture()
            _ = try await fixture.read()
            await fixture.local.failNextRead(error)
            await fixture.probe.setReachable(false)
            let result = try await fixture.read()
            XCTAssertEqual(result, "wan")
            XCTAssertEqual(fixture.events.values, [.localAddress, nil, .publicAddress])
            let next = try await fixture.read()
            XCTAssertEqual(next, "wan")
            let localReads = await fixture.local.reads
            XCTAssertEqual(localReads, 2)
        }
    }

    func testHandshakeBusinessFailureDoesNotTryPublicAddress() async throws {
        let errors: [any Error] = [SourceError.authenticationFailed,
                                  SourceConnectionTerminalError(message: "trust required"), CancellationError()]
        for error in errors {
            let fixture = Fixture()
            await fixture.local.failNextConnect(error)
            do {
                _ = try await fixture.read()
                XCTFail("Expected handshake failure")
            } catch {}
            let remoteConnections = await fixture.remote.connections
            XCTAssertEqual(remoteConnections, 0)
            let preferred = await fixture.runtime.preferredKind(for: fixture.id,
                availableKinds: [.localAddress, .publicAddress], prefersLocalNetwork: true)
            XCTAssertEqual(preferred, .localAddress)
        }
    }

    // Pending Apple-side run: the router target links NIO and cannot build on Linux.
    /// A VPN/proxy in TUN mode answers the private TCP probe on the device, then
    /// the connector's own login times out. That is a handshake failure, not a
    /// replayable request: the configured public route must still be tried.
    func testConnectorTimeoutDuringLocalHandshakeTriesPublicDespiteReachableTCP() async throws {
        for error: any Error in [URLError(.timedOut), SourceError.timeout] {
            let fixture = Fixture()
            await fixture.local.failNextConnect(error)
            let result = try await fixture.read()
            XCTAssertEqual(result, "wan")
            let next = try await fixture.read()
            XCTAssertEqual(next, "wan")
            let localConnections = await fixture.local.connections
            XCTAssertEqual(localConnections, 1, "The LAN cooldown keeps later reads on the public route")
            let backedOff = await fixture.runtime.isLocalRouteBackedOff(for: fixture.id)
            XCTAssertTrue(backedOff)
            XCTAssertEqual(fixture.events.values, [.publicAddress])
        }
    }

    func testRemoteHandshakeDeadlineTriesLANWithoutPublishingFailedRoute() async throws {
        for kind: SourceConnectionCandidateKind in [.publicAddress, .vendorRemote] {
            let fixture = Fixture(remoteKind: kind, deadline: 0.1)
            await fixture.runtime.observeNetworkPath(prefersLocalNetwork: false, pathChanged: false)
            await fixture.remote.delayNextConnect(5)
            let result = try await fixture.read()
            XCTAssertEqual(result, "lan")
            let remoteConnections = await fixture.remote.connections
            let remoteDisconnects = await fixture.remote.disconnections
            let localConnections = await fixture.local.connections
            XCTAssertEqual(remoteConnections, 1)
            XCTAssertEqual(remoteDisconnects, 1)
            XCTAssertEqual(localConnections, 1)
            XCTAssertEqual(fixture.events.values, [.localAddress])
        }
    }

    // Pending Apple-side run.
    func testLocalHandshakeDeadlineCooldownIsSharedByEveryConnector() async throws {
        let fixture = Fixture(deadline: 0.1)
        await fixture.local.delayNextConnect(5)
        let fallback = try await fixture.read()
        XCTAssertEqual(fallback, "wan")
        let retry = try await fixture.read()
        XCTAssertEqual(retry, "wan", "The next read must not handshake the LAN again")
        let localConnections = await fixture.local.connections
        let remoteConnections = await fixture.remote.connections
        XCTAssertEqual(localConnections, 1)
        XCTAssertEqual(remoteConnections, 1)
        XCTAssertEqual(fixture.events.values, [.publicAddress])

        // A write-back or scan connector is a separate router over the same
        // runtime; it goes straight to the public route too.
        let sibling = fixture.makeSiblingRouter()
        let siblingValue = try await sibling.router.withRead { try await ($0 as! RouterTestConnector).read() }
        XCTAssertEqual(siblingValue, "wan")
        let siblingLocalConnections = await sibling.local.connections
        XCTAssertEqual(siblingLocalConnections, 0)

        // A real network change gives the LAN an immediate new chance.
        await fixture.runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
        let recovered = try await fixture.read()
        XCTAssertEqual(recovered, "lan")
    }

    // Pending Apple-side run.
    /// At home without NAT hairpinning the public address never answers; a LAN
    /// cooldown must not push every request through that dead route first.
    func testBackedOffLANStillLeadsWhenNoAlternativeAnswers() async throws {
        let fixture = Fixture(deadline: 0.1)
        await fixture.local.delayNextConnect(5)
        let fallback = try await fixture.read()
        XCTAssertEqual(fallback, "wan")
        await fixture.probe.setWANReachable(false)
        let sibling = fixture.makeSiblingRouter()
        let value = try await sibling.router.withRead { try await ($0 as! RouterTestConnector).read() }
        XCTAssertEqual(value, "lan")
        let siblingRemoteConnections = await sibling.remote.connections
        XCTAssertEqual(siblingRemoteConnections, 0)
        let backedOff = await fixture.runtime.isLocalRouteBackedOff(for: fixture.id)
        XCTAssertFalse(backedOff, "A completed LAN handshake ends the cooldown")
    }

    // Pending Apple-side run.
    /// A scan joined the playback request's LAN login. When the playback
    /// request's deadline tears that login down, the scan must fall back too
    /// instead of failing — and never cancel the playback's public login.
    func testCallerJoinedToAnAbandonedLANLoginFallsBackToo() async throws {
        let runtime = SourceConnectionRuntime()
        let id = UUID().uuidString
        let local = JoiningLoginConnector()
        let remote = RouterTestConnector(sourceID: "wan")
        let router = SourceConnectionRouter(sourceID: id, candidates: [
            .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), connector: local),
            .init(kind: .publicAddress, endpoint: .init(host: "wan.invalid", port: 445, useSsl: false), connector: remote)
        ], runtime: runtime, endpointProbe: { _ in }, handshakeTimeout: { kind, _ in
            kind == .localAddress ? 0.3 : 5
        }) { _ in }
        let first = Task { try await router.withRead { try await ($0 as! RouterTestConnector).read() } }
        await local.waitForLogin()
        let joined = Task { try await router.withRead { try await ($0 as! RouterTestConnector).read() } }
        let firstValue = try await first.value
        let joinedValue = try await joined.value
        XCTAssertEqual(firstValue, "wan")
        XCTAssertEqual(joinedValue, "wan")
        let remoteDisconnects = await remote.disconnections
        XCTAssertEqual(remoteDisconnects, 0)
    }

    func testFailbackDeadlineKeepsTheWorkingRouteAlive() async throws {
        let fixture = Fixture(deadline: 0.1)
        await fixture.probe.setReachable(false)
        _ = try await fixture.read()
        await fixture.runtime.recordFailure(of: .localAddress, for: fixture.id, now: .distantPast)
        await fixture.probe.setReachable(true)
        await fixture.local.delayNextConnect(5)
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
        let remoteDisconnects = await fixture.remote.disconnections
        XCTAssertEqual(remoteDisconnects, 0)
        XCTAssertEqual(fixture.events.values, [.publicAddress])
    }

    func testRemoteBusinessTimeoutAuthenticationAndTrustDoNotTryLAN() async throws {
        let errors: [any Error] = [SourceError.timeout, SourceError.authenticationFailed,
                                  SourceConnectionTerminalError(message: "trust required"),
                                  URLError(.serverCertificateUntrusted), CancellationError()]
        for kind: SourceConnectionCandidateKind in [.publicAddress, .vendorRemote] {
            for expected in errors {
                let fixture = Fixture(remoteKind: kind, deadline: 0.1)
                await fixture.runtime.observeNetworkPath(prefersLocalNetwork: false, pathChanged: false)
                await fixture.remote.failNextConnect(expected)
                do {
                    _ = try await fixture.read()
                    XCTFail("Expected original service error")
                } catch {
                    XCTAssertEqual((error as NSError).domain, (expected as NSError).domain)
                    XCTAssertEqual((error as NSError).code, (expected as NSError).code)
                }
                let localConnections = await fixture.local.connections
                XCTAssertEqual(localConnections, 0)
                XCTAssertTrue(fixture.events.values.isEmpty)
            }
        }
    }

    func testExhaustedHandshakeDeadlinesReturnTimeoutWithoutLooping() async throws {
        let fixture = Fixture(deadline: 0.1)
        await fixture.local.delayNextConnect(5)
        await fixture.remote.delayNextConnect(5)
        do {
            _ = try await fixture.read()
            XCTFail("Expected timeout after both candidates")
        } catch SourceError.timeout {} catch {
            XCTFail("Expected source timeout, got \(error)")
        }
        let localConnections = await fixture.local.connections
        let remoteConnections = await fixture.remote.connections
        XCTAssertEqual(localConnections, 1)
        XCTAssertEqual(remoteConnections, 1)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testUnreachableEndpointUsesPublicAddress() async throws {
        let fixture = Fixture()
        await fixture.probe.setReachable(false)
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
    }

    func testFailedPreflightIsNotImmediatelyProbedAgain() async throws {
        let fixture = Fixture(remoteKind: .vendorRemote)
        await fixture.probe.failNextCheck(URLError(.timedOut))
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
        let hosts = await fixture.probe.hosts
        let localConnections = await fixture.local.connections
        XCTAssertEqual(hosts, ["lan.invalid"])
        XCTAssertEqual(localConnections, 0)
        XCTAssertEqual(fixture.events.values, [.vendorRemote])
    }

    func testPreflightTrustAndCancellationErrorsDoNotTryFallback() async throws {
        for expected: any Error in [CancellationError(), URLError(.cancelled), URLError(.serverCertificateUntrusted)] {
            let fixture = Fixture(remoteKind: .vendorRemote)
            await fixture.probe.failNextCheck(expected)
            do {
                _ = try await fixture.read()
                XCTFail("Expected original probe error")
            } catch {
                XCTAssertEqual((error as NSError).domain, (expected as NSError).domain)
                XCTAssertEqual((error as NSError).code, (expected as NSError).code)
            }
            let hosts = await fixture.probe.hosts
            let remoteConnections = await fixture.remote.connections
            XCTAssertEqual(hosts, ["lan.invalid"])
            XCTAssertEqual(remoteConnections, 0)
            XCTAssertTrue(fixture.events.values.isEmpty)
        }
    }

    func testChangedNetworkDoesNotReuseOldPreflightFailure() async throws {
        let fixture = Fixture(remoteKind: .vendorRemote)
        await fixture.probe.failNextCheck(URLError(.timedOut), changingNetwork: fixture.runtime)
        do {
            _ = try await fixture.read()
            XCTFail("Expected original failure after the current endpoint was proven reachable")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let hosts = await fixture.probe.hosts
        let remoteConnections = await fixture.remote.connections
        XCTAssertEqual(hosts, ["lan.invalid", "lan.invalid"])
        XCTAssertEqual(remoteConnections, 0)
        let retry = try await fixture.read()
        XCTAssertEqual(retry, "lan")
    }

    func testReadFailureStillRequiresFreshEndpointEvidence() async throws {
        let fixture = Fixture(remoteKind: .vendorRemote)
        _ = try await fixture.read()
        await fixture.local.failNextRead(URLError(.networkConnectionLost))
        await fixture.probe.setReachable(false)
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
        // A private route with an alternative leaves on its own transport
        // failure; only the initial preflight probed it.
        let hosts = await fixture.probe.hosts
        XCTAssertEqual(hosts, ["lan.invalid"])
    }

    func testSlowPrivateRouteDoesNotBlockTheReachablePublicRoute() async throws {
        let fixture = Fixture()
        await fixture.probe.setLANDelay(3)
        let started = Date()
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // The race only probes; it must never open a second authenticated
        // connection behind the caller's back.
        let localConnections = await fixture.local.connections
        XCTAssertEqual(localConnections, 0)
        XCTAssertEqual(fixture.events.values, [.publicAddress])
    }

    func testTunnelledPathStillPrefersThePrivateRoute() async throws {
        let fixture = Fixture()
        // A VPN or Tailscale tunnel surfaces as NWInterface type `.other`, which
        // used to be read as "not on the LAN" and pushed the request to WAN.
        await fixture.runtime.observeNetworkPath(
            condition: SourceRoutePathCondition(interfaceClass: .tunnel, usesTunnel: true),
            pathChanged: false
        )
        let result = try await fixture.read()
        XCTAssertEqual(result, "lan")
        let remoteConnections = await fixture.remote.connections
        XCTAssertEqual(remoteConnections, 0)
        XCTAssertEqual(fixture.events.values, [.localAddress])
    }

    func testMutationsAreNeverReplayedAndBusinessErrorsDoNotRetireLAN() async throws {
        for error: any Error in [SourceError.connectionFailed("write rejected"), URLError(.networkConnectionLost)] {
            let fixture = Fixture()
            _ = try await fixture.read()
            await fixture.probe.setReachable(false)
            await fixture.local.failNextRead(error)
            do {
                _ = try await fixture.router.withMutation { try await ($0 as! RouterTestConnector).read() }
                XCTFail("Expected write failure")
            } catch {}
            let remoteReads = await fixture.remote.reads
            XCTAssertEqual(remoteReads, 0)
            let active = await fixture.runtime.activeKind(for: fixture.id)
            XCTAssertEqual(active, SourceNetworkFailurePolicy.isNetworkFailure(error) ? nil : .localAddress)
        }
    }

    func testDeferredBusinessFailureDoesNotRetireRouteButNetworkFailureDoes() async throws {
        let fixture = Fixture()
        let read = try await fixture.router.withReadAndRoute { $0.sourceID }
        await fixture.router.noteDeferredReadFailure(PagedSongCatalogError.unavailable, routeIndex: read.routeIndex)
        let active = await fixture.runtime.activeKind(for: fixture.id)
        XCTAssertEqual(active, .localAddress)
        await fixture.probe.setReachable(false)
        await fixture.router.noteDeferredReadFailure(URLError(.networkConnectionLost), routeIndex: read.routeIndex)
        XCTAssertNil(fixture.events.values.last!)
        let next = try await fixture.read()
        XCTAssertEqual(next, "wan")
    }

    func testExpiredNetworkFailureRetriesLANWhilePublicRouteRemainsUsable() async throws {
        let fixture = Fixture()
        await fixture.probe.setReachable(false)
        _ = try await fixture.read()
        await fixture.runtime.recordFailure(of: .localAddress, for: fixture.id, now: .distantPast)
        await fixture.probe.setReachable(true)
        let result = try await fixture.read()
        XCTAssertEqual(result, "lan")
        let publicDisconnects = await fixture.remote.disconnections
        XCTAssertEqual(publicDisconnects, 0)
    }

    func testFailedFailbackDoesNotTurnBusinessErrorIntoNetworkRejection() async throws {
        let fixture = Fixture()
        await fixture.probe.setReachable(false)
        _ = try await fixture.read()
        await fixture.runtime.recordFailure(of: .localAddress, for: fixture.id, now: .distantPast)
        await fixture.probe.setReachable(true)
        await fixture.local.failNextConnect(SourceError.authenticationFailed)
        do {
            _ = try await fixture.read()
            XCTFail("Expected authentication failure")
        } catch {}
        let preferred = await fixture.runtime.preferredKind(for: fixture.id,
            availableKinds: [.localAddress, .publicAddress], prefersLocalNetwork: true)
        XCTAssertEqual(preferred, .localAddress)
        let publicDisconnects = await fixture.remote.disconnections
        XCTAssertEqual(publicDisconnects, 0)
    }

    func testNetworkChangeClearsStaleDisplayEvenIfReconnectFails() async throws {
        let fixture = Fixture()
        await fixture.probe.setReachable(false)
        _ = try await fixture.read()
        await fixture.runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
        await fixture.probe.setReachable(true)
        await fixture.local.failNextConnect(SourceError.authenticationFailed)
        do { _ = try await fixture.read(); XCTFail("Expected authentication failure") } catch {}
        XCTAssertNil(fixture.events.values.last!)
    }

    func testCancelledCallerDoesNotConnectOrPoisonNetworkState() async throws {
        let fixture = Fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.read()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let connections = await fixture.local.connections
        XCTAssertEqual(connections, 0)
        let result = try await fixture.read()
        XCTAssertEqual(result, "lan")
    }
}

@MainActor private final class RouteEvents {
    var values: [SourceConnectionCandidateKind?] = []
}

@MainActor private final class Fixture {
    let id = UUID().uuidString
    let runtime = SourceConnectionRuntime()
    let local = RouterTestConnector(sourceID: "lan")
    let remote = RouterTestConnector(sourceID: "wan")
    let events = RouteEvents()
    let probe = RouterEndpointProbe()
    let remoteKind: SourceConnectionCandidateKind
    let deadline: TimeInterval?

    init(remoteKind: SourceConnectionCandidateKind = .publicAddress, deadline: TimeInterval? = nil) {
        self.remoteKind = remoteKind
        self.deadline = deadline
    }

    lazy var router = SourceConnectionRouter(sourceID: id, candidates: [
        .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), connector: local),
        .init(kind: remoteKind, endpoint: remoteKind == .vendorRemote ? nil : .init(host: "wan.invalid", port: 445, useSsl: false), connector: remote)
    ], runtime: runtime, endpointProbe: { [probe] in try await probe.check($0) }, handshakeTimeout: { [deadline] kind, kinds in
        guard let production = SourceConnectionHandshakePolicy.timeout(for: kind, availableKinds: kinds) else { return nil }
        return deadline ?? production
    }) { [events] in events.values.append($0) }
    func read() async throws -> String {
        try await router.withRead { try await ($0 as! RouterTestConnector).read() }
    }

    func makeSiblingRouter() -> (router: SourceConnectionRouter, local: RouterTestConnector, remote: RouterTestConnector) {
        let local = RouterTestConnector(sourceID: "lan")
        let remote = RouterTestConnector(sourceID: "wan")
        let router = SourceConnectionRouter(sourceID: id, candidates: [
            .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), connector: local),
            .init(kind: remoteKind, endpoint: remoteKind == .vendorRemote ? nil : .init(host: "wan.invalid", port: 445, useSsl: false), connector: remote)
        ], runtime: runtime, endpointProbe: { [probe] in try await probe.check($0) }) { _ in }
        return (router, local, remote)
    }
}

private actor RouterTestConnector: MusicSourceConnector {
    let sourceID: String
    private var readError: (any Error)?
    private var connectError: (any Error)?
    private var connectDelay: TimeInterval = 0
    var lastError: (any Error)?
    var connections = 0
    var disconnections = 0
    var reads = 0
    init(sourceID: String) { self.sourceID = sourceID }
    func failNextRead(_ error: any Error) { readError = error }
    func failNextConnect(_ error: any Error) { connectError = error }
    func delayNextConnect(_ seconds: TimeInterval) { connectDelay = seconds }
    func connect() async throws {
        connections += 1
        if let error = connectError { connectError = nil; throw error }
        let delay = connectDelay
        connectDelay = 0
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
    func disconnect() async { disconnections += 1 }
    func read() throws -> String {
        reads += 1
        if let error = readError { readError = nil; lastError = error; throw error }
        return sourceID
    }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { URL(fileURLWithPath: path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

/// Models a connector whose concurrent `connect()` calls join one in-flight
/// login, and whose `disconnect()` cancels it for every waiter.
private actor JoiningLoginConnector: MusicSourceConnector {
    nonisolated let sourceID = "lan"
    private var login: Task<Void, Error>?
    private var loginObservers: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        if login == nil {
            login = Task { try await Task.sleep(nanoseconds: 5_000_000_000) }
            loginObservers.forEach { $0.resume() }
            loginObservers.removeAll()
        }
        try await login!.value
    }

    func waitForLogin() async {
        if login != nil { return }
        await withCheckedContinuation { loginObservers.append($0) }
    }

    func disconnect() async {
        login?.cancel()
        login = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { URL(fileURLWithPath: path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor RouterEndpointProbe {
    private(set) var hosts: [String] = []
    private var reachable = true
    private var wanReachable = true
    private var lanDelay: TimeInterval = 0
    private var nextFailure: (error: any Error, runtime: SourceConnectionRuntime?)?
    func setReachable(_ reachable: Bool) { self.reachable = reachable }
    func setWANReachable(_ reachable: Bool) { wanReachable = reachable }
    func failNextCheck(_ error: any Error, changingNetwork runtime: SourceConnectionRuntime? = nil) {
        nextFailure = (error, runtime)
    }
    /// Simulates a private address that only answers after the public one, which
    /// is what a cold tunnel or an absent LAN looks like.
    func setLANDelay(_ seconds: TimeInterval) { lanDelay = seconds }
    func check(_ endpoint: SourceConnectionEndpoint) async throws {
        hosts.append(endpoint.host)
        if endpoint.host == "wan.invalid", !wanReachable { throw URLError(.cannotConnectToHost) }
        guard endpoint.host == "lan.invalid" else { return }
        if let failure = nextFailure {
            nextFailure = nil
            if let runtime = failure.runtime {
                await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
            }
            throw failure.error
        }
        if lanDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(lanDelay * 1_000_000_000))
        }
        if !reachable { throw URLError(.cannotConnectToHost) }
    }
}
