import Testing
@testable import PrimuseKit

@Suite("Artwork store limit")
struct ArtworkStoreLimitPolicyTests {
    private let mib = ArtworkStoreLimitPolicy.bytesPerMiB
    private let gib = ArtworkStoreLimitPolicy.bytesPerGiB

    @Test("Unset means the default; negative means unlimited")
    func resolved() {
        #expect(ArtworkStoreLimitPolicy.resolved(nil) == 500 * mib)
        #expect(ArtworkStoreLimitPolicy.resolved(-5) == 0)
        #expect(ArtworkStoreLimitPolicy.resolved(2 * gib) == 2 * gib)
    }

    @Test("A non-standard limit stays listed, in order after unlimited")
    func options() {
        #expect(ArtworkStoreLimitPolicy.options(including: gib) == ArtworkStoreLimitPolicy.selectableBytes)
        #expect(ArtworkStoreLimitPolicy.options(including: 0) == ArtworkStoreLimitPolicy.selectableBytes)
        let custom = ArtworkStoreLimitPolicy.options(including: 750 * mib)
        #expect(custom.first == 0)
        #expect(custom.contains(750 * mib))
        #expect(Array(custom.dropFirst()) == Array(custom.dropFirst()).sorted())
    }

    @Test("Projection uses the local average, or a fallback with too few covers")
    func projection() {
        // 100 covers, 20 MiB in all: 204.8 KiB each.
        #expect(ArtworkStoreLimitPolicy.projectedBytes(
            existingBytes: 20 * mib, existingCount: 100, additionalCount: 50
        ) == 20 * mib + 50 * (20 * mib / 100))
        #expect(ArtworkStoreLimitPolicy.projectedBytes(
            existingBytes: 1_000, existingCount: 3, additionalCount: 10
        ) == 1_000 + 10 * ArtworkStoreLimitPolicy.fallbackAverageBytes)
        #expect(ArtworkStoreLimitPolicy.projectedBytes(
            existingBytes: 0, existingCount: 0, additionalCount: -4
        ) == 0)
    }

    @Test("A raise is suggested only when the projection exceeds a finite limit")
    func suggestion() {
        #expect(ArtworkStoreLimitPolicy.suggestedLimit(projectedBytes: 400 * mib, currentLimit: 500 * mib) == nil)
        #expect(ArtworkStoreLimitPolicy.suggestedLimit(projectedBytes: 10 * gib, currentLimit: 0) == nil)
        // 900 MiB with 20% headroom fits 2 GiB, not 1 GiB.
        #expect(ArtworkStoreLimitPolicy.suggestedLimit(projectedBytes: 900 * mib, currentLimit: 500 * mib) == 2 * gib)
        #expect(ArtworkStoreLimitPolicy.suggestedLimit(projectedBytes: 600 * mib, currentLimit: 500 * mib) == gib)
        #expect(ArtworkStoreLimitPolicy.suggestedLimit(projectedBytes: 20 * gib, currentLimit: 5 * gib) == 0)
    }
}
