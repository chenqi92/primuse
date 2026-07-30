import Testing
@testable import PrimuseKit

@Suite("Full-download seek policy")
struct FullDownloadSeekPolicyTests {
    @Test("User scrubbing keeps uncached playback intact")
    func keepsPlaybackForUserSeekWithoutLocalFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: false,
            isInterruptionRecovery: false
        ) == .keepCurrentPlayback)
    }

    @Test("Interruption recovery never becomes an uncached no-op")
    func restartsForRecoveryWithoutLocalFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: false,
            isInterruptionRecovery: true
        ) == .restartCurrentSong)
    }

    @Test("A materialized file supports both seek intents")
    func proceedsWithSeekableFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: true,
            isInterruptionRecovery: false
        ) == .proceed)
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: true,
            isInterruptionRecovery: true
        ) == .proceed)
    }
}
