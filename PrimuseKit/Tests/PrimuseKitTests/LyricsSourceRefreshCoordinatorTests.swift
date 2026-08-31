import Foundation
import Testing
@testable import PrimuseKit

struct LyricsSourceRefreshCoordinatorTests {
    @Test func fingerprintIgnoresParserIDsButCoversMiddleLinesAndWordTiming() {
        let original = Self.document(lineIDs: ["first-a", "middle-a", "last-a"])
        let reparsed = Self.document(lineIDs: ["first-b", "middle-b", "last-b"])
        #expect(LyricsDocumentFingerprint(lines: original)
            == LyricsDocumentFingerprint(lines: reparsed))

        var middleChanged = reparsed
        middleChanged[1].text = "changed middle"
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: middleChanged))

        var timingChanged = reparsed
        timingChanged[1].syllables?[0].end = 1.75
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: timingChanged))
    }

    @Test func fingerprintCoversDocumentCuesAndBackgroundVoices() {
        let original = Self.document(lineIDs: ["a", "b", "c"])
        var metadataChanged = original
        metadataChanged[0].metadataLines = ["[ar:Different Artist]"]
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: metadataChanged))

        var backgroundChanged = original
        backgroundChanged[1].background?[0].endTimestamp = 2.8
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: backgroundChanged))
    }

    @Test func unchangedDocumentSkipsReplacement() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let original = Self.document(lineIDs: ["a", "b", "c"])
        let replacementCount = Counter()

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "song"),
            currentDocument: original,
            trigger: .explicit,
            fetch: { Self.document(lineIDs: ["x", "y", "z"]) },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        #expect(result == .unchanged)
        #expect(await replacementCount.value == 0)
    }

    @Test func sourceWordTimingAuthoritativelyReplacesLineOnlyCache() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [LyricLine(timestamp: 1, text: "whole line")]
        let source = [
            LyricLine(
                timestamp: 1,
                text: "whole line",
                syllables: [
                    LyricSyllable(text: "whole ", start: 1, end: 1.5),
                    LyricSyllable(text: "line", start: 1.5, end: 2),
                ]
            )
        ]
        let stored = DocumentBox()

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "song"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { source },
            replace: { lines in
                await stored.set(lines)
                return true
            }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated.first?.isWordLevel == true)
        #expect(await stored.value == source)
    }

    @Test func emptyAndFailedFetchesPreserveExistingCache() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = Self.document(lineIDs: ["a", "b", "c"])
        let replacementCount = Counter()

        let empty = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "empty"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { nil },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )
        let failed = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "failed"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { throw TestError.fetchFailed },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        #expect(empty == .emptyPreservingCache)
        #expect(failed == .failedPreservingCache)
        #expect(await replacementCount.value == 0)
    }

    @Test func concurrentRequestsForSameSourceAndSongShareOneFetch() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let fetchCount = Counter()
        let replacementCount = Counter()
        let fetched = Self.document(lineIDs: ["a", "b", "c"])
        let key = LyricsSourceRefreshKey(sourceID: "source", songID: "song")

        async let first = coordinator.refresh(
            key: key,
            currentDocument: nil,
            trigger: .automatic,
            fetch: {
                await fetchCount.increment()
                try await Task.sleep(for: .milliseconds(40))
                return fetched
            },
            replace: { lines in
                await replacementCount.increment()
                return !lines.isEmpty
            }
        )
        async let second = coordinator.refresh(
            key: key,
            currentDocument: nil,
            trigger: .explicit,
            fetch: {
                await fetchCount.increment()
                try await Task.sleep(for: .milliseconds(40))
                return fetched
            },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        let results = await [first, second]
        #expect(results.allSatisfy { $0.updatedDocument == fetched })
        #expect(await fetchCount.value == 1)
        #expect(await replacementCount.value == 1)
    }

    @Test func automaticRefreshIsRateLimitedPerSourceAndSong() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 60)
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let fetched = Self.document(lineIDs: ["a", "b", "c"])
        let fetchCount = Counter()

        func refresh(sourceID: String, songID: String, now: Date) async -> LyricsSourceRefreshResult {
            await coordinator.refresh(
                key: .init(sourceID: sourceID, songID: songID),
                currentDocument: nil,
                trigger: .automatic,
                now: now,
                fetch: {
                    await fetchCount.increment()
                    return fetched
                },
                replace: { _ in true }
            )
        }

        #expect(await refresh(sourceID: "one", songID: "song", now: base).updatedDocument == fetched)
        #expect(await refresh(sourceID: "one", songID: "song", now: base.addingTimeInterval(30)) == .throttled)
        #expect(await refresh(sourceID: "one", songID: "other", now: base.addingTimeInterval(30)).updatedDocument == fetched)
        #expect(await refresh(sourceID: "two", songID: "song", now: base.addingTimeInterval(30)).updatedDocument == fetched)
        #expect(await refresh(sourceID: "one", songID: "song", now: base.addingTimeInterval(61)).updatedDocument == fetched)
        #expect(await fetchCount.value == 4)
    }

    @Test func explicitRefreshBypassesAutomaticRateLimit() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 60)
        let key = LyricsSourceRefreshKey(sourceID: "source", songID: "song")
        let fetched = Self.document(lineIDs: ["a", "b", "c"])
        let fetchCount = Counter()

        func refresh(
            trigger: LyricsSourceRefreshTrigger,
            now: Date
        ) async -> LyricsSourceRefreshResult {
            await coordinator.refresh(
                key: key,
                currentDocument: nil,
                trigger: trigger,
                now: now,
                fetch: {
                    await fetchCount.increment()
                    return fetched
                },
                replace: { _ in true }
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        #expect(await refresh(trigger: .automatic, now: base).updatedDocument == fetched)
        #expect(await refresh(trigger: .automatic, now: base.addingTimeInterval(1)) == .throttled)
        #expect(await refresh(trigger: .explicit, now: base.addingTimeInterval(2)).updatedDocument == fetched)
        #expect(await fetchCount.value == 2)
    }

    @Test func sourcePolicyPreservesAppleLocalAndSidecarSemantics() {
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(.navidrome))
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(.subsonic))
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(.jellyfin))
        #expect(!LyricsAuthoritativeSourcePolicy.supportsServerDocument(.plex))
        #expect(!LyricsAuthoritativeSourcePolicy.supportsServerDocument(.appleMusic))
        #expect(!LyricsAuthoritativeSourcePolicy.supportsServerDocument(.appleMusicLibrary))
        #expect(!LyricsAuthoritativeSourcePolicy.supportsServerDocument(.local))
        #expect(!LyricsAuthoritativeSourcePolicy.supportsServerDocument(.smb))
    }

    @Test func lateResponseCannotApplyAfterFastSongSwitch() {
        #expect(LyricsAuthoritativeSourcePolicy.shouldApply(
            responseForSongID: "song-a",
            currentlyPlayingSongID: "song-a"
        ))
        #expect(!LyricsAuthoritativeSourcePolicy.shouldApply(
            responseForSongID: "song-a",
            currentlyPlayingSongID: "song-b"
        ))
    }

    private static func document(lineIDs: [String]) -> [LyricLine] {
        [
            LyricLine(
                id: lineIDs[0],
                timestamp: 0,
                text: "first",
                isSynchronized: false,
                metadataLines: ["[ar:Artist]", "[ti:Title]"]
            ),
            LyricLine(
                id: lineIDs[1],
                timestamp: 1,
                text: "middle",
                syllables: [
                    LyricSyllable(text: "mid", start: 1, end: 1.4),
                    LyricSyllable(text: "dle", start: 1.4, end: 2),
                ],
                endTimestamp: 2,
                background: [
                    LyricLine(
                        id: "background-\(lineIDs[1])",
                        timestamp: 1.2,
                        text: "echo",
                        endTimestamp: 2.4,
                        voice: .secondary
                    )
                ]
            ),
            LyricLine(id: lineIDs[2], timestamp: 3, text: "last"),
        ]
    }
}

private extension LyricsSourceRefreshResult {
    var updatedDocument: [LyricLine]? {
        guard case let .updated(lines) = self else { return nil }
        return lines
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor DocumentBox {
    private(set) var value: [LyricLine]?

    func set(_ lines: [LyricLine]) {
        value = lines
    }
}

private enum TestError: Error {
    case fetchFailed
}
