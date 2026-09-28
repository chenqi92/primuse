import Foundation
import Testing
@testable import PrimuseKit

struct TVScanPipelineTests {
    private func song(
        id: String,
        title: String = "Song",
        path: String = "/Artist/Album/Song.flac",
        duration: TimeInterval = 0,
        revision: String? = "r1",
        dateAdded: Date = Date(timeIntervalSince1970: 10)
    ) -> Song {
        Song(
            id: id,
            title: title,
            duration: duration,
            fileFormat: .flac,
            filePath: path,
            sourceID: "source",
            fileSize: 4_096,
            dateAdded: dateAdded,
            revision: revision
        )
    }

    @Test func songIdentityUsesSharedPathAndProviderMaterial() {
        let pathID = TVScanPipelinePolicy.songID(
            sourceID: "source",
            path: "/Music/Track.flac",
            providerID: "provider-42",
            usesStableProviderIdentity: false
        )
        let stableProviderID = TVScanPipelinePolicy.songID(
            sourceID: "source",
            path: "/Music/Track.flac",
            providerID: "provider-42",
            usesStableProviderIdentity: true
        )

        #expect(pathID == TVScanPipelinePolicy.hash32(
            "source:/Music/Track.flac"
        ))
        #expect(stableProviderID == TVScanPipelinePolicy.hash32(
            "source:provider:provider-42"
        ))
        #expect(pathID.count == 32)
        #expect(stableProviderID.count == 32)
        #expect(pathID != stableProviderID)
    }

    @Test func cueIdentityMatchesGenericScannerMaterial() {
        let id = TVScanPipelinePolicy.cueSongID(
            sourceID: "source",
            path: "/Album/disc.flac",
            cuePath: "/Album/disc.cue",
            trackNumber: 3
        )

        #expect(id == TVScanPipelinePolicy.hash32(
            "source:/Album/disc.flac#cue:/Album/disc.cue#track:3"
        ))
        #expect(id.count == 32)
    }

    @Test func legacyDigestCanonicalizationOnlyTruncatesHexSHA256() {
        let legacy = String(repeating: "ab", count: 32)
        #expect(TVScanPipelinePolicy.canonicalSongID(legacy)
            == String(repeating: "ab", count: 16))
        #expect(TVScanPipelinePolicy.canonicalSongID("provider-track-id")
            == "provider-track-id")
        #expect(TVScanPipelinePolicy.canonicalSongID(String(repeating: "z", count: 64))
            == String(repeating: "z", count: 64))
    }

    @Test func rootsAndPublicationBatchesAreDeterministic() {
        #expect(TVScanPipelinePolicy.normalizedScanRoots([
            " /Music/ ", "/Music", "/Music/Rock/", "drive-item-id",
        ]) == ["/Music", "/Music/Rock", "drive-item-id"])

        let batches = TVScanPipelinePolicy.batches(Array(0..<45))
        #expect(batches.map(\.count) == [20, 20, 5])
        #expect(batches.flatMap { $0 } == Array(0..<45))
    }

    @Test func unchangedSkeletonKeepsEnrichmentAndOriginalInsertionDate() {
        var existing = song(
            id: String(repeating: "a", count: 64),
            title: "Embedded title",
            duration: 245,
            dateAdded: Date(timeIntervalSince1970: 123)
        )
        existing.bitRate = 1_411
        existing.lyricsText = "cached lyrics"
        let candidate = song(
            id: String(repeating: "a", count: 32),
            title: "Filename",
            duration: 0,
            dateAdded: Date(timeIntervalSince1970: 999)
        )

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.id == candidate.id)
        #expect(merged.title == "Embedded title")
        #expect(merged.duration == 245)
        #expect(merged.bitRate == 1_411)
        #expect(merged.lyricsText == "cached lyrics")
        #expect(merged.dateAdded == existing.dateAdded)
        #expect(TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func replacementPreservesExplicitUserMetadataButRefreshesBytes() {
        var existing = song(
            id: "old",
            title: "My title",
            duration: 200,
            revision: "r1"
        )
        existing.artistName = "My artist"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 500)
        var candidate = song(
            id: "new",
            title: "Filename",
            duration: 0,
            revision: "r2"
        )
        candidate.fileSize = 8_192

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.id == "new")
        #expect(merged.title == "My title")
        #expect(merged.artistName == "My artist")
        #expect(merged.revision == "r2")
        #expect(merged.fileSize == 8_192)
        #expect(merged.dateAdded == existing.dateAdded)
        #expect(!TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func skeletonOnlyRowsAreRetriedEvenWithStableRevision() {
        let existing = song(id: "same", duration: 0, revision: "r1")
        let candidate = song(id: "same", duration: 0, revision: "r1")

        #expect(!TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func unchangedStreamDescriptorKeepsParsedTargetMetadata() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        var candidate = song(
            id: "stream",
            path: "/Radio/live.strm",
            revision: "wrapper-r1"
        )
        candidate.fileSize = 128
        candidate.lastModified = modified
        var existing = candidate
        existing.fileFormat = .aac
        existing.fileSize = 0
        existing.revision = STRMRevision.songRevision(
            wrapperRevision: candidate.revision,
            wrapperSize: candidate.fileSize,
            wrapperModifiedDate: modified,
            contentRevision: "content-r1"
        )

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.fileFormat == .aac)
        #expect(merged.fileSize == 0)
        #expect(merged.revision == existing.revision)
        #expect(TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }
}

struct TVScanCommitPolicyTests {
    @Test func slowScansCommitByTimeInsteadOfEveryPublication() {
        // 一首一秒:每批 20 首隔 20 秒,但没到 15 秒的那几批要继续攒。
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 20, secondsSinceLastCommit: 1.5))
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 180, secondsSinceLastCommit: 14))
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 40, secondsSinceLastCommit: 15))
    }

    @Test func fastScansCommitByCount() {
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 200, secondsSinceLastCommit: 0.2))
    }

    @Test func firstBatchCommitsRightAwayAndEmptyNeverCommits() {
        let neverCommitted = Date().timeIntervalSince(.distantPast)
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 20, secondsSinceLastCommit: neverCommitted))
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 0, secondsSinceLastCommit: neverCommitted))
    }
}

struct TVScanReadStatisticsTests {
    @Test func separatesNetworkTimeFromPerSongTime() {
        var stats = TVScanReadStatistics()
        stats.recordRequest(bytes: 262_144, seconds: 0.2)
        stats.recordRequest(bytes: 65_536, seconds: 0.4)
        stats.recordFailure(timedOut: true, seconds: 12)
        stats.recordSong(seconds: 1.0, reused: false)
        stats.recordSong(seconds: 0, reused: true)
        #expect(stats.requests == 2)
        #expect(stats.bytes == 327_680)
        #expect(stats.failures == 1 && stats.timeouts == 1)
        #expect(abs(stats.networkSeconds - 12.6) < 0.0001)
        #expect(stats.averageReadSongMilliseconds == 1000)
        #expect(stats.requestPercentile(0.9) == 12)
        #expect(stats.requestPercentile(0.5) == 0.4)
    }

    @Test func mergeAccumulatesWindows() {
        var a = TVScanReadStatistics()
        a.recordRequest(bytes: 10, seconds: 1)
        var b = TVScanReadStatistics()
        b.recordRequest(bytes: 5, seconds: 2)
        b.recordSong(seconds: 3, reused: false)
        a.merge(b)
        #expect(a.requests == 2 && a.bytes == 15 && a.songs == 1)
        #expect(TVScanReadStatistics().requestPercentile(0.9) == 0)
    }
}

