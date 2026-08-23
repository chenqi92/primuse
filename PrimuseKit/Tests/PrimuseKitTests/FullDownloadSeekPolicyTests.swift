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

    @Test("Cold remote restoration never blocks first Play on a complete download")
    func coldRestorePrefersRangeRecovery() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: true,
            isColdSessionRestore: true
        ) == .tryRangeWithoutMaterialization)
    }

    @Test("Runtime recovery retains exact complete-file materialization")
    func runtimeRecoveryRetainsMaterialization() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: true,
            isColdSessionRestore: false
        ) == .materializeCompleteFile)
    }

    @Test("A cached file and disabled cache keep their direct paths")
    func cachedAndNonCachingPathsRemainStable() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: true,
            cacheEnabled: true,
            isColdSessionRestore: true
        ) == .useExistingFile)
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: false,
            isColdSessionRestore: false
        ) == .tryRangeWithoutMaterialization)
    }
}
