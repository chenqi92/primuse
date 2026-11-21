import Foundation
import Testing
@testable import PrimuseKit

/// 批量刮削按部分结算：只有真的补上并落了地才算更新，存失败要记下来，失效的引用当缺失。
struct BatchScrapeTallyTests {
    private func song() -> Song {
        Song(id: "song", title: "Window at Dawn", albumTitle: "Quiet Windows", artistName: "Paper Harbor",
             duration: 180, fileFormat: .flac, filePath: "/Music/Window at Dawn.flac", sourceID: "nas",
             bitRate: 900, sampleRate: 44_100, bitDepth: 16)
    }

    @Test func technicalParametersAloneAreNotAnUpdate() {
        let original = song()
        var updated = original
        updated.duration = 181.5
        updated.bitRate = 1_411
        updated.sampleRate = 96_000
        updated.bitDepth = 24
        updated.mvPath = "/Music/Window at Dawn.mp4"
        #expect(ScrapeTagChange.changedFields(from: original, to: updated).isEmpty)
        let tags = ScrapePartJudgment.outcome(considered: true, fetched: true,
                                              received: !ScrapeTagChange.changedFields(from: original, to: updated).isEmpty,
                                              stored: true)
        #expect(tags == .notFound)
        let parts = ScrapeSongParts(cover: .notFound, lyrics: .notFound, tags: tags)
        #expect(parts.result == .unchanged)

        updated.year = 2026
        #expect(ScrapeTagChange.changedFields(from: original, to: updated) == [.year])
    }

    @Test func coverThatCouldNotBeStoredCountsAsAFailure() {
        let cover = ScrapePartJudgment.outcome(considered: true, fetched: true, received: true, stored: false)
        #expect(cover == .saveFailed)
        // 歌词补上了也不能把这首算成成功悄悄过去。
        let parts = ScrapeSongParts(cover: cover, lyrics: .filled, tags: .notFound)
        #expect(parts.result == .failed)

        var tally = BatchScrapeTally()
        tally.record(parts)
        #expect(tally.cover == BatchScrapePartCounts(saveFailed: 1))
        #expect(tally.lyrics == BatchScrapePartCounts(filled: 1))
        #expect(tally.summary.foundNothing == false)
        #expect(tally.summary.cover == [.saveFailed(1)])
    }

    @Test func lyricsRejectedByTheCacheAreNotFilled() {
        let lines = [LyricLine(timestamp: 1, text: "Paper lanterns cross the sky")]
        #expect(ScrapedLyricsValidity.hasUsableLines(lines))
        let rejected = ScrapePartJudgment.outcome(considered: true, fetched: true,
                                                  received: ScrapedLyricsValidity.hasUsableLines(lines), stored: false)
        #expect(rejected == .saveFailed)

        let blank = [LyricLine(timestamp: 1, text: "  "), LyricLine(timestamp: 2, text: "")]
        #expect(!ScrapedLyricsValidity.hasUsableLines(blank))
        #expect(!ScrapedLyricsValidity.hasUsableLines([]))
        #expect(!ScrapedLyricsValidity.hasUsableLines(nil))
    }

    @Test func partJudgmentSeparatesScopePresenceAndMisses() {
        #expect(ScrapePartJudgment.outcome(considered: false, fetched: true, received: true, stored: true) == .notRequested)
        #expect(ScrapePartJudgment.outcome(considered: true, fetched: false, received: false, stored: false) == .alreadyPresent)
        #expect(ScrapePartJudgment.outcome(considered: true, fetched: true, received: false, stored: false) == .notFound)
        #expect(ScrapePartJudgment.outcome(considered: true, fetched: true, received: true, stored: true) == .filled)
        #expect(ScrapeSongParts(cover: .alreadyPresent, lyrics: .notRequested, tags: .alreadyPresent).result == .unchanged)
        #expect(ScrapeSongParts(cover: .filled, lyrics: .notFound, tags: .alreadyPresent).result == .updated)
    }

    @Test func staleLocalReferencesAreTreatedAsMissing() {
        // 本机缓存的封面引用还在、文件没了。
        #expect(ScrapeAssetPresencePolicy.coverState(reference: "scraped-abc.jpg", isLocalCacheName: true,
                                                     referenceReadable: false, contentEvicted: false, songCacheReadable: true) == .staleLocal)
        #expect(ScrapeAssetPresencePolicy.coverState(reference: "scraped-abc.jpg", isLocalCacheName: true,
                                                     referenceReadable: true, contentEvicted: false, songCacheReadable: false) == .present)
        // 被容量清理掉内容、留着标记的封面靠按需恢复，不算失效。
        #expect(ScrapeAssetPresencePolicy.coverState(reference: "scraped-abc.jpg", isLocalCacheName: true,
                                                     referenceReadable: false, contentEvicted: true, songCacheReadable: false) == .present)
        // 音乐源上的封面文件不做网络探测。
        var probed = false
        func probe() -> Bool { probed = true; return false }
        let remote = ScrapeAssetPresencePolicy.coverState(reference: "/Music/Album/cover.jpg", isLocalCacheName: false,
                                                          referenceReadable: probe(), contentEvicted: probe(), songCacheReadable: probe())
        #expect(remote == .present)
        #expect(probed == false)
        #expect(ScrapeAssetPresencePolicy.coverState(reference: nil, isLocalCacheName: false,
                                                     referenceReadable: false, contentEvicted: false, songCacheReadable: true) == .present)
        #expect(ScrapeAssetPresencePolicy.coverState(reference: "", isLocalCacheName: false,
                                                     referenceReadable: true, contentEvicted: false, songCacheReadable: false) == .absent)

        let cacheName = String(repeating: "a", count: 32) + ".json"
        #expect(ScrapeAssetPresencePolicy.isLocalLyricsCacheName(cacheName))
        #expect(!ScrapeAssetPresencePolicy.isLocalLyricsCacheName("Window at Dawn.lrc"))
        #expect(!ScrapeAssetPresencePolicy.isLocalLyricsCacheName(String(repeating: "A", count: 32) + ".json"))
        #expect(ScrapeAssetPresencePolicy.lyricsState(reference: cacheName, isLocalCacheName: true, songCacheExists: false,
                                                      referenceExists: false, sourceConfirmedAbsent: false) == .staleLocal)
        #expect(ScrapeAssetPresencePolicy.lyricsState(reference: cacheName, isLocalCacheName: true, songCacheExists: true,
                                                      referenceExists: false, sourceConfirmedAbsent: false) == .present)
        #expect(ScrapeAssetPresencePolicy.lyricsState(reference: "/Music/a.lrc", isLocalCacheName: false, songCacheExists: false,
                                                      referenceExists: false, sourceConfirmedAbsent: false) == .present)
        #expect(ScrapeAssetPresencePolicy.lyricsState(reference: "/Music/a.lrc", isLocalCacheName: false, songCacheExists: false,
                                                      referenceExists: false, sourceConfirmedAbsent: true) == .staleSource)
        #expect(ScrapeAssetReferenceState.staleLocal.clearsReferenceWhenMissed)
        #expect(!ScrapeAssetReferenceState.staleSource.clearsReferenceWhenMissed)

        let presence = ScrapeAssetPresence(cover: .staleLocal, lyrics: .absent)
        #expect(presence.treatingStaleAsPresent == ScrapeAssetPresence(cover: .present, lyrics: .absent))
        #expect(ScrapeAssetPresence.referencesOnly(cover: "x.jpg", lyrics: nil) == ScrapeAssetPresence(cover: .present, lyrics: .absent))
    }

    @Test func tallyRoundTripsAndOldCheckpointsDecode() throws {
        var tally = BatchScrapeTally()
        tally.record(ScrapeSongParts(cover: .filled, lyrics: .alreadyPresent, tags: .filled))
        tally.record(ScrapeSongParts(cover: .notFound, lyrics: .saveFailed, tags: .notRequested))
        tally.recordWriteback(.written)
        tally.recordWriteback(.failed(.conflict))
        tally.recordFailure(.init(songID: "b", title: "Second", part: .writeback, reason: .conflict, detail: "changed"))
        let data = try JSONEncoder().encode(tally)
        #expect(try JSONDecoder().decode(BatchScrapeTally.self, from: data) == tally)

        // 老断点没有这些字段，或者只有一部分。
        let empty = try JSONDecoder().decode(BatchScrapeTally.self, from: Data("{}".utf8))
        #expect(empty == BatchScrapeTally())
        let partial = try JSONDecoder().decode(BatchScrapeTally.self,
                                               from: Data(#"{"cover":{"filled":3},"writebackWritten":2}"#.utf8))
        #expect(partial.cover == BatchScrapePartCounts(filled: 3))
        #expect(partial.writebackWritten == 2)
        #expect(partial.failures.isEmpty)
    }

    @Test func summaryHidesZeroItemsAndSaysWhenNothingWasFound() {
        var nothing = BatchScrapeTally()
        nothing.record(ScrapeSongParts(cover: .alreadyPresent, lyrics: .notFound, tags: .notFound))
        #expect(nothing.summary.foundNothing)

        var tally = BatchScrapeTally()
        for _ in 0..<3 { tally.record(ScrapeSongParts(cover: .filled, lyrics: .filled, tags: .notFound)) }
        for _ in 0..<6 { tally.record(ScrapeSongParts(cover: .alreadyPresent, lyrics: .alreadyPresent, tags: .filled)) }
        tally.recordWriteback(.written)
        tally.recordWriteback(.failed(.timeout))
        let summary = tally.summary
        #expect(!summary.foundNothing)
        #expect(summary.cover == [.filled(3), .alreadyPresent(6)])
        #expect(summary.lyrics == [.filled(3), .alreadyPresent(6)])
        #expect(summary.tagsFilled == 6)
        #expect(summary.writebackWritten == 1)
        #expect(summary.writebackFailed == 1)
    }

    @Test func lyricsAndCoversReadFromTheFileAreNotWrittenBack() {
        #expect(!ScrapeWritebackSourcePolicy.writesBackLyrics(sourceKind: .embedded))
        #expect(!ScrapeWritebackSourcePolicy.writesBackLyrics(sourceKind: .file))
        #expect(ScrapeWritebackSourcePolicy.writesBackLyrics(sourceKind: .online))
        #expect(ScrapeWritebackSourcePolicy.writesBackLyrics(sourceKind: nil))
        #expect(!ScrapeWritebackSourcePolicy.writesBackCover(readFromFile: true))
        #expect(ScrapeWritebackSourcePolicy.writesBackCover(readFromFile: false))
    }

    @Test func batchLyricsEmbeddingAsksOnceAndResumesNeverEmbedWithoutConsent() {
        let embeds = BatchLyricsEmbeddingConsentPolicy.wouldEmbed(lyricsRequested: true, lyricsWritebackEnabled: true,
                                                                  embeddingMode: .alongside)
        #expect(embeds)
        #expect(!BatchLyricsEmbeddingConsentPolicy.wouldEmbed(lyricsRequested: true, lyricsWritebackEnabled: false,
                                                              embeddingMode: .embedOnly))
        #expect(!BatchLyricsEmbeddingConsentPolicy.wouldEmbed(lyricsRequested: false, lyricsWritebackEnabled: true,
                                                              embeddingMode: .embedOnly))
        #expect(!BatchLyricsEmbeddingConsentPolicy.wouldEmbed(lyricsRequested: true, lyricsWritebackEnabled: true,
                                                              embeddingMode: .off))
        // 升级上来的用户没有「已知晓」标记：第一次一定问。
        #expect(BatchLyricsEmbeddingConsentPolicy.needsConfirmation(wouldEmbed: true, acknowledged: false))
        #expect(!BatchLyricsEmbeddingConsentPolicy.needsConfirmation(wouldEmbed: true, acknowledged: true))
        #expect(!BatchLyricsEmbeddingConsentPolicy.needsConfirmation(wouldEmbed: false, acknowledged: false))
        // 续跑按开始时的选择；旧断点没记时，没确认过就不嵌入。
        #expect(!BatchLyricsEmbeddingConsentPolicy.resumedRunEmbeds(recordedChoice: nil, acknowledged: false))
        #expect(BatchLyricsEmbeddingConsentPolicy.resumedRunEmbeds(recordedChoice: nil, acknowledged: true))
        #expect(!BatchLyricsEmbeddingConsentPolicy.resumedRunEmbeds(recordedChoice: false, acknowledged: true))
    }

    @Test func writebackWaitFollowsTheSlowestEmbed() {
        #expect(ScrapeWritebackWaitPolicy.stallLimit(sidecarTimeout: 30, longestObservedWrite: 0) == 180)
        #expect(ScrapeWritebackWaitPolicy.stallLimit(sidecarTimeout: 120, longestObservedWrite: 10) == 480)
        #expect(ScrapeWritebackWaitPolicy.stallLimit(sidecarTimeout: 30, longestObservedWrite: 200) == 600)
    }

    @Test func interruptedWritebacksAreFailuresWithTheirOwnReason() throws {
        var tally = BatchScrapeTally()
        tally.recordWriteback(.failed(.interrupted))
        tally.recordFailure(.init(songID: "a", title: "A", part: .writeback, reason: .interrupted))
        #expect(tally.writebackFailedInterrupted == 1)
        #expect(tally.writebackFailed == 1)
        #expect(tally.summary.writebackFailed == 1)
        let decoded = try JSONDecoder().decode(BatchScrapeTally.self, from: JSONEncoder().encode(tally))
        #expect(decoded == tally)
    }

    @Test func writebackOutcomesCombineToTheFirstFailure() {
        #expect(ScrapeWritebackOutcome.written.combined(with: .failed(.conflict)) == .failed(.conflict))
        #expect(ScrapeWritebackOutcome.failed(.timeout).combined(with: .failed(.conflict)) == .failed(.timeout))
        #expect(ScrapeWritebackOutcome.notAttempted.combined(with: .written) == .written)
        #expect(ScrapeWritebackOutcome.notAttempted.combined(with: .notAttempted) == .notAttempted)
    }

    @Test func failureListIsBoundedAndKeepsOneRowPerPart() {
        var tally = BatchScrapeTally()
        tally.recordFailure(.init(songID: "a", title: "A", part: .cover))
        tally.recordFailure(.init(songID: "a", title: "A", part: .cover, detail: "again"))
        #expect(tally.failures.count == 1)
        #expect(tally.failures.first?.detail == "again")
        for index in 0..<(BatchScrapeTally.maximumFailureEntries + 5) {
            tally.recordFailure(.init(songID: "s\(index)", title: "S", part: .writeback, reason: .other))
        }
        #expect(tally.failures.count == BatchScrapeTally.maximumFailureEntries)
        #expect(tally.omittedFailureCount == 6)
        #expect(tally.hasFailures)

        var errored = BatchScrapeTally()
        errored.recordSongError(songID: "x", title: "X", detail: "timed out")
        #expect(errored.songErrors == 1)
        #expect(errored.failures.first?.part == .song)
        #expect(!errored.summary.foundNothing)
        #expect(errored.summary.songErrors == 1)
    }
}
