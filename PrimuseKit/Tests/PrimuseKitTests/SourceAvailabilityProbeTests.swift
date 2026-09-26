import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source availability probe")
struct SourceAvailabilityProbeTests {

    private static let wifi = SourceRoutePathCondition(interfaceClass: .directLocal)

    @Test(arguments: ["nas.synology.me", "2408:8207:1234::5"])
    func publicRouteGetsASecondAttemptBeforeTheSourceIsParked(host: String) async throws {
        let endpoint = SourceConnectionEndpoint(host: host, port: 5001, useSsl: true)
        let probe = AvailabilityProbeRecorder(failures: 1, error: URLError(.timedOut))
        try await SourceConnectionPreflight.availabilityCheck(endpoint, condition: Self.wifi) { _, _ in
            try await probe.attempt()
        }
        #expect(await probe.attempts == 2)
    }

    @Test func deadPublicRouteStillFailsAfterTwoAttempts() async {
        let endpoint = SourceConnectionEndpoint(host: "nas.synology.me", port: 5001, useSsl: true)
        let probe = AvailabilityProbeRecorder(failures: .max, error: URLError(.networkConnectionLost))
        await #expect(throws: URLError.self) {
            try await SourceConnectionPreflight.availabilityCheck(endpoint, condition: Self.wifi) { _, _ in
                try await probe.attempt()
            }
        }
        #expect(await probe.attempts == 2)
    }

    @Test(arguments: ["192.168.1.20", "fd00::20", "fd7a:115c:a1e0::1", "nas.local"])
    func privateAndOverlayRoutesKeepTheirOwnAttempts(host: String) async {
        let endpoint = SourceConnectionEndpoint(host: host, port: 5001, useSsl: true)
        let probe = AvailabilityProbeRecorder(failures: .max, error: URLError(.timedOut))
        await #expect(throws: URLError.self) {
            try await SourceConnectionPreflight.availabilityCheck(endpoint, condition: Self.wifi) { _, _ in
                try await probe.attempt()
            }
        }
        let expected = Self.wifi.retriesTimedOutProbe(for: endpoint) ? 2 : 1
        #expect(await probe.attempts == expected)
    }

    @Test func tunnelPathDoesNotStackRetries() async {
        let tunnel = SourceRoutePathCondition(interfaceClass: .tunnel)
        let endpoint = SourceConnectionEndpoint(host: "nas.synology.me", port: 5001, useSsl: true)
        let probe = AvailabilityProbeRecorder(failures: .max, error: URLError(.timedOut))
        await #expect(throws: URLError.self) {
            try await SourceConnectionPreflight.availabilityCheck(endpoint, condition: tunnel) { _, _ in
                try await probe.attempt()
            }
        }
        #expect(await probe.attempts == 2)
    }

    @Test func serviceErrorsAreNotRetried() async {
        let endpoint = SourceConnectionEndpoint(host: "nas.synology.me", port: 5001, useSsl: true)
        let probe = AvailabilityProbeRecorder(failures: .max, error: URLError(.serverCertificateUntrusted))
        await #expect(throws: URLError.self) {
            try await SourceConnectionPreflight.availabilityCheck(endpoint, condition: Self.wifi) { _, _ in
                try await probe.attempt()
            }
        }
        #expect(await probe.attempts == 1)
    }
}

private actor AvailabilityProbeRecorder {
    private(set) var attempts = 0
    private let failures: Int
    private let error: URLError

    init(failures: Int, error: URLError) {
        self.failures = failures
        self.error = error
    }

    func attempt() throws {
        attempts += 1
        if attempts <= failures { throw error }
    }
}
