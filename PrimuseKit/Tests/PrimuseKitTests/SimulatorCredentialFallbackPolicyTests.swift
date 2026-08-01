import Testing
@testable import PrimuseKit

@Suite("Simulator credential fallback policy")
struct SimulatorCredentialFallbackPolicyTests {
    @Test("Fallback recovers both missing-item and missing-entitlement reads")
    func recoversEligiblePrimaryMisses() {
        #expect(SimulatorCredentialFallbackPolicy.readSource(
            primary: .itemNotFound,
            fallbackExists: true
        ) == .fallback)
        #expect(SimulatorCredentialFallbackPolicy.readSource(
            primary: .missingEntitlement,
            fallbackExists: true
        ) == .fallback)
    }

    @Test("Readable primary wins and unrelated failures remain fail-closed")
    func primaryWinsAndFailuresStayClosed() {
        #expect(SimulatorCredentialFallbackPolicy.readSource(
            primary: .found,
            fallbackExists: true
        ) == .primary)
        #expect(SimulatorCredentialFallbackPolicy.readSource(
            primary: .unavailable,
            fallbackExists: true
        ) == .unavailable)
        #expect(SimulatorCredentialFallbackPolicy.readSource(
            primary: .itemNotFound,
            fallbackExists: false
        ) == .notFound)
    }

    @Test("Overwrite replaces stale fallback and explicit delete removes it")
    func mutationsCannotReviveStaleCredentials() {
        #expect(SimulatorCredentialFallbackPolicy.mutation(
            after: .primarySucceeded
        ) == .replace)
        #expect(SimulatorCredentialFallbackPolicy.mutation(
            after: .missingEntitlement
        ) == .replace)
        #expect(SimulatorCredentialFallbackPolicy.mutation(
            after: .otherFailure
        ) == .preserve)
        #expect(SimulatorCredentialFallbackPolicy.mutation(
            after: .explicitDelete
        ) == .remove)
    }
}
