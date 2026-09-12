import Testing
@testable import PrimuseKit

@Suite("Audio cache prewarm seed retention")
struct AudioCachePrewarmSeedRetentionTests {
    @Test("An unclaimed path keeps the seed that was just written")
    func unclaimedPathKeepsSeed() {
        #expect(AudioCachePrewarmSeedPolicy.keepsSeedAfterWrite(
            isActiveSessionPath: false,
            activePlaybackUses: 0,
            hasPlaybackLease: false
        ))
    }

    @Test("A claim that appeared during the write discards the seed")
    func claimDuringWriteDiscardsSeed() {
        #expect(AudioCachePrewarmSeedPolicy.keepsSeedAfterWrite(
            isActiveSessionPath: true,
            activePlaybackUses: 0,
            hasPlaybackLease: false
        ) == false)
        #expect(AudioCachePrewarmSeedPolicy.keepsSeedAfterWrite(
            isActiveSessionPath: false,
            activePlaybackUses: 1,
            hasPlaybackLease: false
        ) == false)
        #expect(AudioCachePrewarmSeedPolicy.keepsSeedAfterWrite(
            isActiveSessionPath: false,
            activePlaybackUses: 0,
            hasPlaybackLease: true
        ) == false)
    }

    @Test("Head and tail ranges match the bytes a seed writes")
    func headAndTailRanges() {
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 1_048_576,
            tailCount: 262_144,
            fileSize: 10_000_000
        ) == [[0, 1_048_576], [9_737_856, 10_000_000]])
    }

    @Test("A short file keeps the head only")
    func shortFileKeepsHeadOnly() {
        // Tail would start inside the head: overlapping bytes are not written.
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 1_000,
            tailCount: 500,
            fileSize: 1_200
        ) == [[0, 1_000]])
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 1_000,
            tailCount: 500,
            fileSize: 1_000
        ) == [[0, 1_000]])
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 1_000,
            tailCount: 0,
            fileSize: 10_000
        ) == [[0, 1_000]])
    }

    @Test("An exactly adjacent tail is still written")
    func adjacentTailIsWritten() {
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 1_000,
            tailCount: 500,
            fileSize: 1_500
        ) == [[0, 1_000], [1_000, 1_500]])
    }

    @Test("An unknown file size or empty head yields no tail range")
    func unknownSizeYieldsNoTail() {
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 4_096,
            tailCount: 128,
            fileSize: 0
        ) == [[0, 4_096]])
        #expect(AudioCachePrewarmSeedPolicy.seedRanges(
            headCount: 0,
            tailCount: 128,
            fileSize: 10_000
        ).isEmpty)
    }
}
