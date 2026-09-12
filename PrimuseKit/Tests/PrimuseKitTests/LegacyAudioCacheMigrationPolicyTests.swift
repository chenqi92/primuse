import Testing
@testable import PrimuseKit

@Suite("Legacy audio cache migration policy")
struct LegacyAudioCacheMigrationPolicyTests {
    @Test("A remembered probe short-circuits every other input")
    func rememberedProbeSkips() {
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 1_000,
            expectedSize: 1_000,
            alreadyResolved: true
        ) == .skip)
    }

    @Test("An existing destination or a missing legacy file is nothing to do")
    func nothingToDoCases() {
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: true,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 1_000,
            expectedSize: 1_000,
            alreadyResolved: false
        ) == .skip)
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: false,
            matchCount: 1,
            legacyByteCount: nil,
            expectedSize: 1_000,
            alreadyResolved: false
        ) == .skip)
    }

    @Test("An ambiguous legacy name is rejected and remembered")
    func ambiguousMatchIsRemembered() {
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 2,
            legacyByteCount: 1_000,
            expectedSize: 1_000,
            alreadyResolved: false
        ) == .rejectAndRemember)
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 0,
            legacyByteCount: 1_000,
            expectedSize: 1_000,
            alreadyResolved: false
        ) == .rejectAndRemember)
    }

    @Test("Byte counts inside the tolerance are adopted")
    func sizeWithinToleranceMoves() {
        #expect(LegacyAudioCacheMigrationPolicy.sizeTolerance(expectedSize: 1_000) == 4_096)
        #expect(LegacyAudioCacheMigrationPolicy.sizeTolerance(expectedSize: 10_000_000) == 100_000)
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 10_050_000,
            expectedSize: 10_000_000,
            alreadyResolved: false
        ) == .move)
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 9_900_001,
            expectedSize: 10_000_000,
            alreadyResolved: false
        ) == .move)
    }

    @Test("Byte counts outside the tolerance are rejected and remembered")
    func sizeOutsideToleranceIsRemembered() {
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 9_000_000,
            expectedSize: 10_000_000,
            alreadyResolved: false
        ) == .rejectAndRemember)
    }

    @Test("An unknown expected size or byte count keeps today's adoption")
    func unknownSizesMove() {
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: 12,
            expectedSize: 0,
            alreadyResolved: false
        ) == .move)
        #expect(LegacyAudioCacheMigrationPolicy.decision(
            destinationExists: false,
            legacyExists: true,
            matchCount: 1,
            legacyByteCount: nil,
            expectedSize: 10_000_000,
            alreadyResolved: false
        ) == .move)
    }
}
