import Foundation
import Network
import Testing
@testable import PrimuseKit

@Suite struct SourceNetworkFailurePolicyTests {
    @Test func wholeSourceRequiresEveryConfiguredRouteToBeUnreachable() async {
        let lan = SourceConnectionEndpoint(host: "lan.invalid", port: 445, useSsl: false)
        let remote = SourceConnectionEndpoint(host: "remote.invalid", port: 443, useSsl: true)
        let offline: SourceNetworkFailurePolicy.EndpointProbe = { _ in throw URLError(.cannotConnectToHost) }
        #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable([lan, remote], probe: offline))
        #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable([lan, remote], probe: { endpoint in
            if endpoint.host == lan.host { throw URLError(.timedOut) }
        }) == false)
        for endpoints: [SourceConnectionEndpoint?] in [[], [nil], [lan, nil]] {
            #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable(endpoints, probe: offline) == false)
        }
        #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable([lan], probe: { _ in
            throw CancellationError()
        }) == false)
        #expect(await SourceNetworkFailurePolicy.allEndpointsAreUnreachable([lan], probe: { _ in
            throw URLError(.serverCertificateUntrusted)
        }) == false)
    }

    @Test func onlyTransportErrorsChangeNetworkHealth() {
        for code: URLError.Code in [.timedOut, .cannotFindHost, .cannotConnectToHost,
                                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet] {
            #expect(SourceNetworkFailurePolicy.isNetworkFailure(URLError(code)))
        }
        for code: URLError.Code in [.cancelled, .badServerResponse, .badURL,
                                    .cannotDecodeContentData, .fileDoesNotExist,
                                    .userAuthenticationRequired, .userCancelledAuthentication,
                                    .serverCertificateUntrusted, .secureConnectionFailed,
                                    .appTransportSecurityRequiresSecureConnection, .cannotWriteToFile] {
            #expect(!SourceNetworkFailurePolicy.isNetworkFailure(URLError(code)))
        }
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(CancellationError()))
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(StreamResolveError.badServerResponse(503)))
        #expect(SourceNetworkFailurePolicy.isNetworkFailure(NWError.posix(.ECONNRESET)))
        #expect(SourceNetworkFailurePolicy.isNetworkFailure(NWError.dns(-65538)))
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(NWError.posix(.EACCES)))
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(NWError.tls(-9807)))
        for code in [ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH, ECONNRESET, EPIPE] {
            #expect(SourceNetworkFailurePolicy.isNetworkFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        }
        for code in [ENOENT, EACCES, EPERM, ENOSPC, ECANCELED, EINVAL] {
            #expect(!SourceNetworkFailurePolicy.isNetworkFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        }
    }

    @Test func preservesUnderlyingEvidenceWithoutGuessingFromMessages() {
        let underlying = URLError(.networkConnectionLost)
        #expect(SourceNetworkFailurePolicy.isNetworkFailure(NSError(
            domain: "TransportWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying]
        )))
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(NSError(
            domain: "Service", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection timed out HTTP 503"]
        )))
        #expect(!SourceNetworkFailurePolicy.isNetworkFailure(NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )))
    }

    @Test func onlyIndependentEndpointFailureConfirmsUnreachableRoute() async {
        let endpoint = SourceConnectionEndpoint(host: "lan.invalid", port: 4533, useSsl: false)
        #expect(await SourceNetworkFailurePolicy.endpointIsUnreachable(endpoint, probe: { _ in }) == false)
        #expect(await SourceNetworkFailurePolicy.endpointIsUnreachable(endpoint, probe: { _ in
            throw URLError(.cannotConnectToHost)
        }))
        #expect(await SourceNetworkFailurePolicy.endpointIsUnreachable(endpoint, probe: { _ in
            throw URLError(.serverCertificateUntrusted)
        }) == false)
        #expect(await SourceNetworkFailurePolicy.endpointIsUnreachable(endpoint, probe: { _ in
            throw CancellationError()
        }) == false)
        #expect(await SourceNetworkFailurePolicy.endpointIsUnreachable(nil, probe: { _ in
            Issue.record("Missing endpoint must not be probed")
        }) == false)
    }

    @Test func temporaryLANFailureExpiresWithoutAWiFiChange() async {
        let runtime = SourceConnectionRuntime()
        let start = Date(timeIntervalSince1970: 100)
        let kinds: [SourceConnectionCandidateKind] = [.localAddress, .publicAddress]
        await runtime.recordFailure(of: .localAddress, for: "nas", now: start)
        await runtime.record(.publicAddress, for: "nas")
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds,
                                            prefersLocalNetwork: true, now: start) == .publicAddress)
        #expect(await runtime.preferredKind(for: "other", availableKinds: kinds,
                                            prefersLocalNetwork: true, now: start) == .localAddress)
        let retry = start.addingTimeInterval(SourceConnectionRuntime.localRetryInterval)
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds,
                                            prefersLocalNetwork: true, now: retry) == .localAddress)
        #expect(await runtime.preferredKind(for: "nas", availableKinds: kinds,
                                            prefersLocalNetwork: false, now: retry) == .publicAddress)
        await runtime.record(.localAddress, for: "nas")
        #expect(await runtime.activeKind(for: "nas") == .localAddress)
    }

    @Test func cancelledProbeDoesNotBecomeAConnectionFailure() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SourceConnectionPreflight.check(.init(host: "127.0.0.1", port: 9, useSsl: false))
        }
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func invalidProbeConfigurationIsNotANetworkFailure() async {
        do {
            try await SourceConnectionPreflight.check(.init(host: "localhost", port: 99999, useSsl: false))
            Issue.record("Expected invalid endpoint")
        } catch {
            #expect(!SourceNetworkFailurePolicy.isNetworkFailure(error))
        }
    }
}
