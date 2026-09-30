import Foundation
import Testing
@testable import PrimuseKit

@Suite("Upcoming Playback Prefetch Policy")
struct UpcomingPlaybackPrefetchPolicyTests {
    private let chunk: Int64 = 1024 * 1024

    @Test("Metered networks keep only the next two songs")
    func meteredNetworksLimitQueueDepth() {
        #expect(UpcomingPlaybackPrefetchPolicy.plannedSongCount(configured: 3, isMeteredNetwork: false) == 3)
        #expect(UpcomingPlaybackPrefetchPolicy.plannedSongCount(configured: 8, isMeteredNetwork: true) == 2)
        #expect(UpcomingPlaybackPrefetchPolicy.plannedSongCount(configured: 1, isMeteredNetwork: true) == 1)
        #expect(UpcomingPlaybackPrefetchPolicy.plannedSongCount(configured: -2, isMeteredNetwork: false) == 0)
    }

    @Test("The next song gets about twenty seconds of audio, later songs one chunk")
    func nextSongHeadCoversTwentySeconds() {
        // 320 kbps MP3: 40 KB/s → 800 KB for 20 s → one chunk.
        let mp3 = UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 9_600_000, duration: 240, chunkSize: chunk
        )
        #expect(mp3 == chunk)
        // CD FLAC ~ 110 KB/s → 2.2 MB → three chunks.
        let flac = UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 26_400_000, duration: 240, chunkSize: chunk
        )
        #expect(flac == 3 * chunk)
        // Hi-res FLAC ~ 400 KB/s → 8 MB → capped at eight chunks.
        let hiRes = UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 120_000_000, duration: 240, chunkSize: chunk
        )
        #expect(hiRes == 8 * chunk)
        let later = UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 1, fileSize: 120_000_000, duration: 240, chunkSize: chunk
        )
        #expect(later == chunk)
    }

    @Test("Unknown durations and tiny files never overshoot")
    func headStaysWithinFile() {
        #expect(UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 50_000_000, duration: 0, chunkSize: chunk
        ) == chunk)
        #expect(UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 50_000_000, duration: .nan, chunkSize: chunk
        ) == chunk)
        #expect(UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 300_000, duration: 1, chunkSize: chunk
        ) == 300_000)
        #expect(UpcomingPlaybackPrefetchPolicy.headByteCount(
            rank: 0, fileSize: 0, duration: 200, chunkSize: chunk
        ) == 0)
    }

    @Test("Complete-file transfers stay close to the playhead")
    func completeFilesAreRankLimited() {
        #expect(UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 0, kind: .original))
        #expect(!UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 1, kind: .original))
        #expect(UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 1, kind: .transcoded))
        #expect(!UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 2, kind: .transcoded))
        #expect(UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 1, kind: .medley))
        #expect(!UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: 2, kind: .medley))
    }

    @Test("Playback never waits for a whole-file prefetch it does not need")
    func joinDecisions() {
        typealias Policy = UpcomingPlaybackPrefetchPolicy
        #expect(Policy.joinDecision(phase: .queued, playbackRequiresCompleteFile: false, completedFraction: nil) == .cancelAndProceed)
        #expect(Policy.joinDecision(phase: .openSeed, playbackRequiresCompleteFile: false, completedFraction: nil) == .wait)
        #expect(Policy.joinDecision(phase: .extendingSeed, playbackRequiresCompleteFile: false, completedFraction: nil) == .cancelAndProceed)
        #expect(Policy.joinDecision(phase: .completeFile(.medley), playbackRequiresCompleteFile: false, completedFraction: 0.2) == .cancelAndProceed)
        #expect(Policy.joinDecision(phase: .completeFile(.original), playbackRequiresCompleteFile: false, completedFraction: nil) == .cancelAndProceed)
        #expect(Policy.joinDecision(phase: .completeFile(.medley), playbackRequiresCompleteFile: false, completedFraction: 0.9) == .wait)
        #expect(Policy.joinDecision(phase: .completeFile(.original), playbackRequiresCompleteFile: true, completedFraction: 0) == .wait)
        #expect(Policy.joinDecision(phase: .completeFile(.transcoded), playbackRequiresCompleteFile: false, completedFraction: nil) == .wait)
    }

    @Test("Only songs heard almost to the end are completed after a track change")
    func completionFillSkipsEarlySkips() {
        typealias Fill = StreamingSessionCompletionFillPolicy
        #expect(Fill.allowsFill(missingBytes: 128 * 1024, totalLength: 9_000_000))
        #expect(Fill.allowsFill(missingBytes: 4 * 1024 * 1024, totalLength: 9_000_000))
        #expect(!Fill.allowsFill(missingBytes: 7_000_000, totalLength: 9_000_000))
        #expect(Fill.allowsFill(missingBytes: 20_000_000, totalLength: 100_000_000))
        #expect(!Fill.allowsFill(missingBytes: 40_000_000, totalLength: 100_000_000))
        #expect(!Fill.allowsFill(missingBytes: 60_000_000, totalLength: 1_000_000_000))
        #expect(!Fill.allowsFill(missingBytes: 0, totalLength: 9_000_000))
    }

    @Test("Speculative reads bound every response to the requested window plus slack")
    func speculativeReadBoundsResponses() async {
        #expect(!SpeculativeRangeRead.isActive)
        #expect(SpeculativeRangeRead.effectiveLimit(20 * 1024 * 1024) == 20 * 1024 * 1024)
        let bounded = await SpeculativeRangeRead.withBoundedResponses(requestedLength: chunk) {
            (SpeculativeRangeRead.isActive, SpeculativeRangeRead.effectiveLimit(20 * 1024 * 1024))
        }
        #expect(bounded.0)
        #expect(bounded.1 == Int(2 * chunk))
        let small = await SpeculativeRangeRead.withBoundedResponses(requestedLength: chunk) {
            SpeculativeRangeRead.effectiveLimit(4096)
        }
        #expect(small == 4096)
        #expect(!SpeculativeRangeRead.isActive)
    }

    @Test("Queue seeds cover WebDAV, Synology and UPnP but not FTP or platform sources")
    func upcomingModes() {
        typealias Policy = RangeStreamingPrefetchPolicy
        for type: MusicSourceType in [.webdav, .synology, .synologyAudioStation, .smb, .baiduPan] {
            #expect(Policy.upcomingPrefetchMode(
                sourceType: type, transport: .connectorRange, hasKnownFileSize: true,
                rank: 2, prefersCompleteFile: false, rangeSeedOnly: false
            ) == .connectorSeed)
        }
        for type: MusicSourceType in [.upnp, .jellyfin, .navidrome, .qnap] {
            #expect(Policy.upcomingPrefetchMode(
                sourceType: type, transport: .directHTTPRange, hasKnownFileSize: true,
                rank: 0, prefersCompleteFile: false, rangeSeedOnly: false
            ) == .directSeed)
        }
        for type: MusicSourceType in [.ftp, .local, .appleMusic, .appleMusicLibrary] {
            #expect(Policy.upcomingPrefetchMode(
                sourceType: type, transport: .completeFile, hasKnownFileSize: true,
                rank: 0, prefersCompleteFile: false, rangeSeedOnly: false
            ) == .disabled)
        }
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .oneDrive, transport: .connectorRange, hasKnownFileSize: true,
            rank: 0, prefersCompleteFile: false, rangeSeedOnly: false
        ) == .linkOnly)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .jellyfin, transport: .directHTTPRange, hasKnownFileSize: false,
            rank: 0, prefersCompleteFile: false, rangeSeedOnly: false
        ) == .disabled)
    }

    @Test("Complete files are prefetched only for the next song or a medley's next slices")
    func upcomingCompleteFiles() {
        typealias Policy = RangeStreamingPrefetchPolicy
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .webdav, transport: .completeFile, hasKnownFileSize: true,
            rank: 0, prefersCompleteFile: false, rangeSeedOnly: false
        ) == .completeFile)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .webdav, transport: .completeFile, hasKnownFileSize: true,
            rank: 1, prefersCompleteFile: false, rangeSeedOnly: false
        ) == .disabled)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .smb, transport: .completeFile, hasKnownFileSize: true,
            rank: 0, prefersCompleteFile: false, rangeSeedOnly: true
        ) == .disabled)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .smb, transport: .connectorRange, hasKnownFileSize: true,
            rank: 1, prefersCompleteFile: true, rangeSeedOnly: false
        ) == .completeFile)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .smb, transport: .connectorRange, hasKnownFileSize: true,
            rank: 2, prefersCompleteFile: true, rangeSeedOnly: false
        ) == .connectorSeed)
        #expect(Policy.upcomingPrefetchMode(
            sourceType: .oneDrive, transport: .completeFile, hasKnownFileSize: true,
            rank: 1, prefersCompleteFile: false, rangeSeedOnly: false
        ) == .linkOnly)
    }
}
