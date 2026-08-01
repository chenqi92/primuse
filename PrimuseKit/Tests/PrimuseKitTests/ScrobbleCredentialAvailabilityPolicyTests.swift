import Testing
@testable import PrimuseKit

@Suite("Scrobble credential availability")
struct ScrobbleCredentialAvailabilityPolicyTests {
    @Test("Fallbacks are used only for definitively absent custom credentials")
    func fallbackRequiresDefinitiveAbsence() {
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(
                .notFound,
                fallback: "built-in"
            ) == .ready("built-in")
        )
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(
                .found("custom"),
                fallback: "built-in"
            ) == .ready("custom")
        )
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(
                .temporarilyUnavailable(-25308),
                fallback: "built-in"
            ) == .unavailable
        )
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(
                .failed(-34018),
                fallback: "built-in"
            ) == .unavailable
        )
    }

    @Test("Unavailable providers stay queueable while unconfigured providers do not")
    func queueDecisionPreservesTransientFailures() {
        let ready = ScrobbleCredentialAvailabilityPolicy.resolveProvider([
            .ready("api-key"),
            .ready("api-secret"),
            .ready("session"),
        ])
        let unavailable = ScrobbleCredentialAvailabilityPolicy.resolveProvider([
            .ready("api-key"),
            .unavailable,
            .ready("session"),
        ])
        let notConfigured = ScrobbleCredentialAvailabilityPolicy.resolveProvider([
            .ready("api-key"),
            .notConfigured,
            .ready("session"),
        ])

        #expect(ready == .ready)
        #expect(unavailable == .unavailable)
        #expect(notConfigured == .notConfigured)
        #expect(ScrobbleCredentialAvailabilityPolicy.shouldQueue(ready))
        #expect(ScrobbleCredentialAvailabilityPolicy.shouldQueue(unavailable))
        #expect(!ScrobbleCredentialAvailabilityPolicy.shouldQueue(notConfigured))
    }

    @Test("Empty credentials remain definitively unconfigured without a fallback")
    func emptyCredentialIsNotConfigured() {
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(.found(""))
                == .notConfigured
        )
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveValue(.notFound)
                == .notConfigured
        )
        #expect(
            ScrobbleCredentialAvailabilityPolicy.resolveProvider([])
                == .notConfigured
        )
    }
}
