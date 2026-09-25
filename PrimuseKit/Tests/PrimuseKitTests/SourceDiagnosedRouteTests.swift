import Foundation
import Testing
@testable import PrimuseKit

@Suite("Connection check verdict feeds route memory")
struct SourceDiagnosedRouteTests {
    let kinds: [SourceConnectionCandidateKind] = [.localAddress, .publicAddress]

    @Test func verdictPrefersAWorkingLANAndOtherwiseTheFirstWorkingRoute() {
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.localAddress, true), (.publicAddress, true)])
            == SourceDiagnosedRouteVerdict(workingKind: .localAddress, localFailed: false))
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.localAddress, false), (.publicAddress, true)])
            == SourceDiagnosedRouteVerdict(workingKind: .publicAddress, localFailed: true))
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [
            (.localAddress, false), (.publicAddress, false), (.vendorRemote, true),
        ]) == SourceDiagnosedRouteVerdict(workingKind: .vendorRemote, localFailed: true))
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.publicAddress, false), (.vendorRemote, true)])
            == SourceDiagnosedRouteVerdict(workingKind: .vendorRemote, localFailed: false))
    }

    @Test func noVerdictWhenNothingWorkedOrThereWasNoChoice() {
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.localAddress, false), (.publicAddress, false)]) == nil)
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.localAddress, false)]) == nil)
        #expect(SourceDiagnosedRoutePolicy.verdict(results: [(.publicAddress, true)]) == nil)
        #expect(SourceDiagnosedRoutePolicy.verdict(results: []) == nil)
    }

    @Test func aFailedLANIsSkippedForFiveMinutesAfterTheCheck() async {
        let runtime = SourceConnectionRuntime()
        let now = Date(timeIntervalSince1970: 1_000)
        await runtime.recordDiagnosis(.init(workingKind: .publicAddress, localFailed: true), for: "nas", now: now)
        #expect(await runtime.activeKind(for: "nas") == .publicAddress)
        // A plain timed-out probe would have let the LAN back after 8 seconds.
        for offset in [0.0, 8, 60, 299] {
            #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds, prefersLocalNetwork: true,
                                                now: now.addingTimeInterval(offset)) == .publicAddress)
        }
        #expect(await runtime.isLocalRouteBackedOff(for: "nas", now: now.addingTimeInterval(299)))
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas", now: now.addingTimeInterval(301)))
        // It does not count towards the handshake-failure escalation.
        #expect(await runtime.localHandshakeFailureCount(for: "nas") == 0)
        // A LAN-only source still keeps its one route.
        #expect(await runtime.preferredKind(for: "nas", availableKinds: [.localAddress], prefersLocalNetwork: true,
                                            now: now) == .localAddress)
    }

    @Test func aWorkingLANClearsEarlierCooldowns() async {
        let runtime = SourceConnectionRuntime()
        await runtime.recordLocalHandshakeFailure(for: "nas")
        await runtime.recordDiagnosis(.init(workingKind: .localAddress, localFailed: false), for: "nas")
        #expect(await runtime.activeKind(for: "nas") == .localAddress)
        #expect(await !runtime.isLocalRouteBackedOff(for: "nas"))
    }

    @Test func aNetworkChangeDropsTheVerdict() async {
        let runtime = SourceConnectionRuntime()
        await runtime.recordDiagnosis(.init(workingKind: .publicAddress, localFailed: true), for: "nas")
        await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
        #expect(await runtime.activeKind(for: "nas") == nil)
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds, prefersLocalNetwork: true) == .localAddress)
    }
}
