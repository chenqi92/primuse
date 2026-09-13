import Foundation
import NIOCore
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class SourceConnectionRouterTests: XCTestCase {
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

    func testRequestTimeoutsAndExternalMediaFailuresKeepReachableLAN() async throws {
        let errors: [any Error] = [
            URLError(.timedOut),
            URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://cdn.invalid/art.jpg")!]),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        ]
        for error in errors {
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
        let errors: [any Error] = [SourceError.authenticationFailed, SourceError.timeout,
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
            if let sourceError = error as? SourceError, case .timeout = sourceError {
                let disconnects = await fixture.local.disconnections
                XCTAssertEqual(disconnects, 1)
            }
            let preferred = await fixture.runtime.preferredKind(for: fixture.id,
                availableKinds: [.localAddress, .publicAddress], prefersLocalNetwork: true)
            XCTAssertEqual(preferred, .localAddress)
        }
    }

    func testHandshakeTimeoutDoesNotRetireReachableEndpoint() async throws {
        let fixture = Fixture()
        await fixture.local.failNextConnect(URLError(.timedOut))
        do { _ = try await fixture.read(); XCTFail("Expected handshake timeout") } catch {}
        let result = try await fixture.read()
        XCTAssertEqual(result, "lan")
        let publicConnections = await fixture.remote.connections
        XCTAssertEqual(publicConnections, 0)
    }

    func testUnreachableEndpointUsesPublicAddress() async throws {
        let fixture = Fixture()
        await fixture.probe.setReachable(false)
        let result = try await fixture.read()
        XCTAssertEqual(result, "wan")
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
    lazy var router = SourceConnectionRouter(sourceID: id, candidates: [
        .init(kind: .localAddress, endpoint: .init(host: "lan.invalid", port: 445, useSsl: false), connector: local),
        .init(kind: .publicAddress, endpoint: .init(host: "wan.invalid", port: 445, useSsl: false), connector: remote)
    ], runtime: runtime, endpointProbe: { [probe] in try await probe.check($0) }) { [events] in events.values.append($0) }
    func read() async throws -> String {
        try await router.withRead { try await ($0 as! RouterTestConnector).read() }
    }
}

private actor RouterTestConnector: MusicSourceConnector {
    let sourceID: String
    private var readError: (any Error)?
    private var connectError: (any Error)?
    var lastError: (any Error)?
    var connections = 0
    var disconnections = 0
    var reads = 0
    init(sourceID: String) { self.sourceID = sourceID }
    func failNextRead(_ error: any Error) { readError = error }
    func failNextConnect(_ error: any Error) { connectError = error }
    func connect() async throws {
        connections += 1
        if let error = connectError { connectError = nil; throw error }
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

private actor RouterEndpointProbe {
    private var reachable = true
    private var lanDelay: TimeInterval = 0
    func setReachable(_ reachable: Bool) { self.reachable = reachable }
    /// Simulates a private address that only answers after the public one, which
    /// is what a cold tunnel or an absent LAN looks like.
    func setLANDelay(_ seconds: TimeInterval) { lanDelay = seconds }
    func check(_ endpoint: SourceConnectionEndpoint) async throws {
        guard endpoint.host == "lan.invalid" else { return }
        if lanDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(lanDelay * 1_000_000_000))
        }
        if !reachable { throw URLError(.cannotConnectToHost) }
    }
}
