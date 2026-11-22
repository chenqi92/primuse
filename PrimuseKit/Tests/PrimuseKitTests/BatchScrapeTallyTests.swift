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

    /// 刮削嵌歌词：文件里一份歌词都没有才整段写；已有又要换时按字段替换；只补缺失时不换；一样时不重写。
    @Test func scrapedLyricsUseFieldReplacementWhenTheFileAlreadyHasLyrics() {
        let new = "[00:01.00]Paper lanterns"
        let wordLevel = "[00:01.00]<00:01.00>Paper <00:01.40>lanterns"
        func plan(_ chosen: String?, has: Bool, keeps: Bool = false, byField: Bool = true) -> ScrapedLyricsEmbedPlan {
            ScrapedLyricsEmbedPlan.plan(incoming: [new, wordLevel], fileChosen: chosen, fileHasLyrics: has,
                                        keepsExisting: keeps, skipsUnchanged: true, replacesByField: byField)
        }
        #expect(plan(nil, has: false) == .setInTransaction)
        #expect(plan(nil, has: false, keeps: true) == .setInTransaction, "Missing lyrics are filled even when only filling gaps")
        #expect(plan("[00:01.00]Old words", has: true) == .replaceByField)
        // 只有一份译文、读不出选中的原文也算已有：整段写会把 MP3 里的译文帧合掉。
        #expect(plan(nil, has: true) == .replaceByField)
        #expect(plan("[00:01.00]Old words", has: true, keeps: true) == .keepExisting)
        #expect(plan("[00:01.00]Paper lanterns\r\n", has: true) == .unchanged)
        #expect(plan(wordLevel, has: true) == .unchanged, "The word-level form written by field counts as the same")
        #expect(plan("[00:01.00]Old words", has: true, byField: false) == .setInTransaction)
    }

    @Test func anyReadableOrRawLyricsFieldMeansTheFileHasLyrics() {
        #expect(!ScrapedLyricsEmbedPlan.fileHasLyrics(texts: [], rawFieldCount: nil))
        #expect(!ScrapedLyricsEmbedPlan.fileHasLyrics(texts: ["  ", "\n"], rawFieldCount: 0))
        #expect(ScrapedLyricsEmbedPlan.fileHasLyrics(texts: ["", "[00:01.00]晚潮"], rawFieldCount: nil))
        #expect(ScrapedLyricsEmbedPlan.fileHasLyrics(texts: [], rawFieldCount: 1), "A frame whose text cannot be decoded still counts")
    }

    @Test func lyricsThatCannotBeLocatedAreAWritebackFailure() {
        var tally = BatchScrapeTally()
        tally.recordWriteback(.failed(.lyricsNotLocated))
        tally.recordFailure(.init(songID: "s", title: "Window at Dawn", part: .writeback, reason: .lyricsNotLocated))
        let failed = tally.writebackFailed
        #expect(failed == 1)
        #expect(tally.failures.first?.reason == .lyricsNotLocated)
        #expect(!tally.summary.foundNothing)
        #expect(ScrapeWritebackOutcome.written.combined(with: .failed(.lyricsNotLocated)) == .failed(.lyricsNotLocated))
    }

    /// 播放时在线取到的歌词只在 Primuse 里；音乐源上看得出有这首歌自己的歌词，或者分不清从哪来的，都不算。
    @Test func onlineLyricsLiveOnlyInAppUnlessTheSourceHasItsOwn() {
        #expect(ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: .online, retainedKinds: [.online], reference: "0123456789abcdef0123456789abcdef.json",
            hasEmbeddedRecord: false))
        #expect(ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: .online, retainedKinds: [], reference: nil, hasEmbeddedRecord: false))
        // 没有来源标记的老缓存、读文件来的都不算。
        #expect(!ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: nil, retainedKinds: [], reference: nil, hasEmbeddedRecord: false))
        #expect(!ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: .embedded, retainedKinds: [], reference: nil, hasEmbeddedRecord: false))
        // 来源页选了在线那份，文件里、歌旁边、服务端其实有自己的。
        for kind: LyricsDocumentSource.Kind in [.file, .embedded, .server, .appleMusic] {
            #expect(!ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
                cachedKind: .online, retainedKinds: [.online, kind], reference: nil, hasEmbeddedRecord: false))
        }
        #expect(!ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: .online, retainedKinds: [], reference: "/Music/Window at Dawn.lrc", hasEmbeddedRecord: false))
        #expect(!ScrapeAssetPresencePolicy.lyricsLiveOnlyInApp(
            cachedKind: .online, retainedKinds: [], reference: nil, hasEmbeddedRecord: true))
    }

    /// 封面只认存下时记了「还没写进音乐源」的那一张；换了图、读文件来的、没有记录的都不算。
    @Test func coverLivesOnlyInAppOnlyForTheRecordedLocalCopy() {
        let id = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        #expect(ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "scraped-\(id).jpg", pendingContentID: id))
        #expect(ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "selected-\(id).jpg", pendingContentID: id))
        #expect(!ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "scraped-\(id).jpg", pendingContentID: other))
        #expect(!ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "scraped-\(id).jpg", pendingContentID: nil))
        #expect(!ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "embedded-\(id).jpg", pendingContentID: id))
        #expect(!ScrapeAssetPresencePolicy.coverLivesOnlyInApp(reference: "/Music/cover.jpg", pendingContentID: id))
        #expect(ScrapeAssetReferenceState.appOnly.hasLocalCopy)
        #expect(ScrapeAssetPresence(cover: .appOnly, lyrics: .appOnly).treatingStaleAsPresent
            == ScrapeAssetPresence(cover: .present, lyrics: .present))
    }

    /// 本机那份写进音乐源之后才从「已有」挪成「用已有的写回」，不算更新；写回开关关着、只在 Primuse 里的
    /// 也要列出来，并提示怎么写进去。
    @Test func localCopiesAreListedInTheSummary() {
        #expect(ScrapeSongParts(cover: .alreadyPresent, lyrics: .copiedToSource, tags: .notFound).result == .unchanged)
        #expect(ScrapeSongParts(cover: .onlyInApp, lyrics: .onlyInApp, tags: .notFound).result == .unchanged)

        var copied = BatchScrapeTally()
        copied.record(ScrapeSongParts(cover: .alreadyPresent, lyrics: .alreadyPresent, tags: .notRequested))
        copied.recordCopiedToSource(cover: false, lyrics: true)
        #expect(copied.lyrics.copiedToSource == 1)
        #expect(copied.lyrics.alreadyPresent == 0)
        #expect(copied.cover.alreadyPresent == 1)
        #expect(!copied.summary.foundNothing)
        #expect(copied.summary.lyrics == [.copiedToSource(1)])
        #expect(!copied.summary.hasOnlyInApp)
        // 没有可挪的「已有」时不凭空多出一首。
        copied.recordCopiedToSource(cover: false, lyrics: true)
        #expect(copied.lyrics.copiedToSource == 1)

        var kept = BatchScrapeTally()
        kept.record(ScrapeSongParts(cover: .onlyInApp, lyrics: .alreadyPresent, tags: .notRequested))
        #expect(!kept.summary.foundNothing)
        #expect(kept.summary.cover == [.onlyInApp(1)])
        #expect(kept.summary.hasOnlyInApp)
    }

    @Test func oldCheckpointCountsDecodeWithoutTheLocalCopyFields() throws {
        let data = Data(#"{"filled":2,"alreadyPresent":3,"notFound":1,"saveFailed":0}"#.utf8)
        let counts = try JSONDecoder().decode(BatchScrapePartCounts.self, from: data)
        #expect(counts == BatchScrapePartCounts(filled: 2, alreadyPresent: 3, notFound: 1))
        #expect(counts.copiedToSource == 0 && counts.onlyInApp == 0)
    }
}
