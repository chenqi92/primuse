#if os(tvOS)
import Foundation
import Testing
@testable import PrimuseKit

@Suite(.serialized)
@MainActor
struct TVTrustCancellationTests {
    @Test func cancellingHTTPTransportWithdrawsItsUnansweredTrustPrompt() async throws {
        let endpoint = "http://" + UUID().uuidString.lowercased() + ".invalid:80"
        let store = TVServerCertificateTrustStore.shared
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            if store.pendingInsecureHTTPRequest?.endpoint == endpoint {
                store.resolvePendingInsecureHTTPRequest(approved: false)
            }
        }
        let request = Task {
            try await StreamResolverHTTPTransport.data(
                for: URLRequest(url: URL(string: endpoint + "/fixture")!), session: session
            )
        }
        defer { request.cancel() }
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint == endpoint })
        request.cancel()
        _ = await request.result
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint != endpoint },
                "Cancelling the transport must release its trust waiter and dismiss its prompt")
    }

    @Test func cancellingTLSWaiterCompletesAndDismissesItsPrompt() async throws {
        let endpoint = "https://" + UUID().uuidString.lowercased() + ".invalid:443"
        let store = TVServerCertificateTrustStore.shared
        let completion = Completion()
        let request = Task {
            let approved = await store.requestTrust(endpoint: endpoint, fingerprint: "fixture")
            completion.value = approved
            return approved
        }
        defer {
            request.cancel()
            if store.pendingRequest?.endpoint == endpoint { store.resolvePendingRequest(approved: false) }
        }
        #expect(await eventually { store.pendingRequest?.endpoint == endpoint })
        request.cancel()
        #expect(await eventually { completion.value != nil }, "TLS trust must cooperate with cancellation")
        #expect(store.pendingRequest?.endpoint != endpoint)
        // Release the original implementation's blocked continuation after RED.
        if store.pendingRequest?.endpoint == endpoint { store.resolvePendingRequest(approved: false) }
        #expect(await request.value == false)
    }

    @Test func cancellingOneHTTPCallerPreservesAnotherPurpose() async throws {
        let endpoint = "http://" + UUID().uuidString.lowercased() + ".invalid:80"
        let store = TVServerCertificateTrustStore.shared
        let first = Task { await store.requestInsecureHTTPTrust(endpoint: endpoint, purpose: .server) }
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint == endpoint })
        let survivor = Task { await store.requestInsecureHTTPTrust(endpoint: endpoint, purpose: .podcast) }
        first.cancel()
        #expect(await first.value == false)
        #expect(await eventually { store.pendingInsecureHTTPRequest?.purpose == .podcast })
        store.resolvePendingInsecureHTTPRequest(approved: true)
        #expect(await survivor.value)
        #expect(await store.requestInsecureHTTPTrust(endpoint: endpoint), "Approved trust remains reusable")
    }

    @Test func cancellingOneCertificateCallerPreservesTheOther() async throws {
        let endpoint = "https://" + UUID().uuidString.lowercased() + ".invalid:443"
        let store = TVServerCertificateTrustStore.shared
        let first = Task { await store.requestTrust(endpoint: endpoint, fingerprint: "same") }
        #expect(await eventually { store.pendingRequest?.endpoint == endpoint })
        let started = Completion()
        let survivor = Task {
            started.value = true
            return await store.requestTrust(endpoint: endpoint, fingerprint: "same")
        }
        #expect(await eventually { started.value == true })
        first.cancel()
        #expect(await first.value == false)
        #expect(await eventually { store.pendingRequest?.endpoint == endpoint })
        store.resolvePendingRequest(approved: true)
        #expect(await survivor.value)
        #expect(await store.requestTrust(endpoint: endpoint, fingerprint: "same"))
    }

    @Test func cancellingQueuedRequestsDoesNotReplaceTheVisiblePrompt() async throws {
        let store = TVServerCertificateTrustStore.shared
        let prefix = UUID().uuidString.lowercased()
        let visibleEndpoint = "https://visible-" + prefix + ".invalid:443"
        let queuedEndpoint = "https://queued-" + prefix + ".invalid:443"
        let first = Task { await store.requestTrust(endpoint: visibleEndpoint, fingerprint: "first") }
        #expect(await eventually { store.pendingRequest?.endpoint == visibleEndpoint })
        let started = Completion()
        let queued = Task {
            started.value = true
            return await store.requestTrust(endpoint: queuedEndpoint, fingerprint: "second")
        }
        #expect(await eventually { started.value == true })
        queued.cancel()
        #expect(await queued.value == false)
        #expect(store.pendingRequest?.endpoint == visibleEndpoint)
        store.resolvePendingRequest(approved: false)
        #expect(await first.value == false)
        #expect(store.pendingRequest == nil)
    }

    @Test func cancellingVisibleHTTPPromptPromotesTheNextEndpoint() async throws {
        let store = TVServerCertificateTrustStore.shared
        let prefix = UUID().uuidString.lowercased()
        let firstEndpoint = "http://first-" + prefix + ".invalid:80"
        let nextEndpoint = "http://next-" + prefix + ".invalid:80"
        let first = Task { await store.requestInsecureHTTPTrust(endpoint: firstEndpoint) }
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint == firstEndpoint })
        let next = Task { await store.requestInsecureHTTPTrust(endpoint: nextEndpoint) }
        first.cancel()
        #expect(await first.value == false)
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint == nextEndpoint })
        store.resolvePendingInsecureHTTPRequest(approved: false)
        #expect(await next.value == false)
        #expect(store.pendingInsecureHTTPRequest == nil)
    }

    @Test func explicitWithdrawalPreservesOtherPurposesOnTheSameEndpoint() async throws {
        let store = TVServerCertificateTrustStore.shared
        let endpoint = "http://" + UUID().uuidString.lowercased() + ".invalid:80"
        let server = Task { await store.requestInsecureHTTPTrust(endpoint: endpoint, purpose: .server) }
        #expect(await eventually { store.pendingInsecureHTTPRequest?.endpoint == endpoint })
        let started = Completion()
        let ended = Completion()
        let playlist = Task {
            started.value = true
            let approved = await store.requestInsecureHTTPTrust(endpoint: endpoint, purpose: .radioPlaylist)
            ended.value = approved
            return approved
        }
        #expect(await eventually { started.value == true })
        store.withdrawInsecureHTTPRequest(endpoint: endpoint, purpose: .radioPlaylist)
        #expect(await eventually { ended.value == false })
        #expect(store.pendingInsecureHTTPRequest?.purpose == .server)
        store.resolvePendingInsecureHTTPRequest(approved: false)
        #expect(await playlist.value == false)
        #expect(await server.value == false)
    }

    @Test func alreadyCancelledCallsNeverCreateTrustPrompts() async throws {
        let store = TVServerCertificateTrustStore.shared
        let endpoint = "https://" + UUID().uuidString.lowercased() + ".invalid:443"
        let certificate = Task { await store.requestTrust(endpoint: endpoint, fingerprint: "fixture") }
        certificate.cancel()
        #expect(await certificate.value == false)
        let http = Task { await store.requestInsecureHTTPTrust(endpoint: endpoint) }
        http.cancel()
        #expect(await http.value == false)
        #expect(store.pendingRequest == nil)
        #expect(store.pendingInsecureHTTPRequest == nil)
    }

    private final class Completion {
        var value: Bool?
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
#endif
