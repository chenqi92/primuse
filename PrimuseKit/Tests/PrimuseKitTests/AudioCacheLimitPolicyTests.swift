import Testing
@testable import PrimuseKit

@Suite("Audio cache limit policy")
struct AudioCacheLimitPolicyTests {
    @Test("Unlimited caching skips automatic eviction")
    func unlimitedSkipsEviction() {
        #expect(AudioCacheLimitPolicy.evictionTarget(
            limitBytes: AudioCacheLimitPolicy.unlimitedBytes,
            reserveBytes: 512 * 1_024 * 1_024
        ) == nil)
        #expect(AudioCacheLimitPolicy.evictionTarget(
            limitBytes: -1,
            reserveBytes: 1
        ) == nil)
    }

    @Test("Finite limits reserve room without producing a negative target")
    func finiteLimitTarget() {
        #expect(AudioCacheLimitPolicy.evictionTarget(
            limitBytes: 2 * AudioCacheLimitPolicy.bytesPerGiB,
            reserveBytes: 512 * 1_024 * 1_024
        ) == 1_610_612_736)
        #expect(AudioCacheLimitPolicy.evictionTarget(
            limitBytes: 100,
            reserveBytes: 200
        ) == 0)
    }

    @Test("Selectable limits use whole binary-gigabyte steps")
    func selectableLimits() {
        #expect(AudioCacheLimitPolicy.defaultBytes == 2_147_483_648)
        #expect(AudioCacheLimitPolicy.selectableBytes == [
            0,
            1_073_741_824,
            2_147_483_648,
            5_368_709_120,
            10_737_418_240,
            21_474_836_480,
        ])
    }

    @Test("Legacy custom limits remain selectable without changing their value")
    func legacyCustomLimit() {
        let legacyLimit: Int64 = 500 * 1_048_576
        #expect(AudioCacheLimitPolicy.options(including: legacyLimit) == [
            0,
            legacyLimit,
            1_073_741_824,
            2_147_483_648,
            5_368_709_120,
            10_737_418_240,
            21_474_836_480,
        ])
        #expect(AudioCacheLimitPolicy.options(
            including: AudioCacheLimitPolicy.defaultBytes
        ) == AudioCacheLimitPolicy.selectableBytes)
    }
}
