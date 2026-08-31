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

        var localOverride = original
        localOverride[0].documentIsLocalOverride = true
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: localOverride))
    }

    @Test func fingerprintCoversAuthoredTranslationsButIgnoresTheirParserIDs() {
        var original = Self.document(lineIDs: ["a", "b", "c"])
        original[1].manualTranslation = LyricManualTranslation(
            id: "translation-a",
            text: "译文",
            languageCode: "zh-Hans",
            source: .embeddedField
        )
        var reparsed = original
        reparsed[1].manualTranslation?.id = "translation-b"
        #expect(LyricsDocumentFingerprint(lines: original)
            == LyricsDocumentFingerprint(lines: reparsed))

        var changed = reparsed
        changed[1].manualTranslation?.text = "新译文"
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: changed))

        changed = reparsed
        changed[1].alternateManualTranslations = [
            .init(text: "Traduction", languageCode: "fr", source: .embeddedField),
        ]
        #expect(LyricsDocumentFingerprint(lines: original)
            != LyricsDocumentFingerprint(lines: changed))
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

    @Test func refreshRefusesToDiscardAnUnmatchedAuthoredTranslation() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        var cached = Self.document(lineIDs: ["a", "b", "c"])
        for index in cached.indices {
            cached[index].manualTranslation = LyricManualTranslation(
                text: "translation-\(index)",
                source: .localEditor
            )
        }
        var fetched = Self.document(lineIDs: ["x", "y", "z"])
        fetched[0].timestamp = 0.5 // Timing-only changes retain the same authored translation.
        fetched[1].text = "server rewrote this lyric"
        let fetchedDocument = fetched
        let replacementCount = Counter()

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "manual"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetchedDocument },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        #expect(result == .failedPreservingCache)
        #expect(await replacementCount.value == 0)
    }

    @Test func refreshDoesNotReviveBilingualTextDeletedByTheSource() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Old source translation",
                    source: .bilingualLRC
                )
            ),
        ]
        let fetched = [
            LyricLine(timestamp: 1, text: "Original", isSynchronized: true),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "removed-translation"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated.first?.manualTranslation == nil)
    }

    @Test func exactSameScriptBilingualSourceKeepsEstablishedStructure() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "La brise du soir",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
        ]
        let conservativelyReparsed = LyricsContentParser.parseText(
            LyricsContentParser.serialize(cached),
            options: .literal
        )
        let replacementCount = Counter()

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "same-script"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { conservativelyReparsed },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        #expect(result == .unchanged)
        #expect(await replacementCount.value == 0)
    }

    @Test func changedSameScriptSourceTranslationKeepsEstablishedPair() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Ancienne traduction",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
        ]
        let fetched = [
            LyricLine(timestamp: 1, text: "The evening breeze", isSynchronized: true),
            LyricLine(timestamp: 1, text: "Nouvelle traduction", isSynchronized: true),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "same-script-changed"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated.count == 1)
        #expect(updated[0].manualTranslation?.text == "Nouvelle traduction")
        #expect(updated[0].manualTranslation?.source == .bilingualLRC)
    }

    @Test func partialSameScriptSourceDeletionKeepsTheRemainingEstablishedPair() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "First original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Première traduction",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
            LyricLine(
                timestamp: 2,
                text: "Second original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Deuxième traduction",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
        ]
        let fetched = [
            LyricLine(timestamp: 1, text: "First original", isSynchronized: true),
            LyricLine(timestamp: 2, text: "Second original", isSynchronized: true),
            LyricLine(timestamp: 2, text: "Nouvelle deuxième traduction", isSynchronized: true),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "partial-source-pairs"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated.count == 2)
        #expect(updated[0].manualTranslation == nil)
        #expect(updated[1].manualTranslation?.text == "Nouvelle deuxième traduction")
    }

    @Test func embeddedPreferredTranslationKeepsUpdatedSourceBilingualAlternate() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "人工译文",
                    languageCode: "zh-Hans",
                    source: .embeddedField
                ),
                alternateManualTranslations: [
                    .init(
                        text: "Ancienne traduction",
                        languageCode: "fr",
                        source: .bilingualLRC
                    ),
                ]
            ),
        ]
        let fetched = [
            LyricLine(timestamp: 1, text: "The evening breeze", isSynchronized: true),
            LyricLine(timestamp: 1, text: "Nouvelle traduction", isSynchronized: true),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "preferred-and-source"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated.count == 1)
        #expect(updated[0].manualTranslation?.text == "人工译文")
        #expect(updated[0].manualTranslation?.source == .embeddedField)
        #expect(updated[0].alternateManualTranslations.contains {
            $0.text == "Nouvelle traduction" && $0.source == .bilingualLRC
        })
    }

    @Test func refreshRefusesToOrphanANestedAuthoredTranslation() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.2,
                        text: "Backing",
                        isSynchronized: true,
                        voice: .secondary,
                        manualTranslation: .init(
                            text: "Local backing translation",
                            source: .localEditor
                        )
                    ),
                ]
            ),
        ]
        let fetched = [
            LyricLine(timestamp: 1, text: "Lead", isSynchronized: true),
        ]
        let replacementCount = Counter()

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "nested-local"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in
                await replacementCount.increment()
                return true
            }
        )

        #expect(result == .failedPreservingCache)
        #expect(await replacementCount.value == 0)
    }

    @Test func nestedAuthoredTranslationFollowsAProvenTimingOnlyRefresh() async throws {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.2,
                        text: "Backing",
                        isSynchronized: true,
                        voice: .secondary,
                        manualTranslation: .init(
                            text: "Local backing translation",
                            source: .localEditor
                        )
                    ),
                ]
            ),
        ]
        let fetched = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.5,
                        text: "Backing",
                        isSynchronized: true,
                        voice: .secondary
                    ),
                ]
            ),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "nested-timing"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        let updated = try #require(result.updatedDocument)
        #expect(updated[0].background?[0].timestamp == 1.5)
        #expect(updated[0].background?[0].manualTranslation?.text
            == "Local backing translation")
    }

    @Test func duplicateBackgroundCuesCannotSwapAuthoredTranslations() async {
        let coordinator = LyricsSourceRefreshCoordinator(minimumAutomaticRefreshInterval: 0)
        let cached = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.2,
                        text: "Echo",
                        isSynchronized: true,
                        voice: .secondary,
                        manualTranslation: .init(
                            text: "First",
                            source: .localEditor
                        )
                    ),
                    LyricLine(
                        timestamp: 1.6,
                        text: "Echo",
                        isSynchronized: true,
                        voice: .secondary,
                        manualTranslation: .init(
                            text: "Second",
                            source: .localEditor
                        )
                    ),
                ]
            ),
        ]
        let fetched = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.6,
                        text: "Echo",
                        isSynchronized: true,
                        voice: .secondary
                    ),
                    LyricLine(
                        timestamp: 1.2,
                        text: "Echo",
                        isSynchronized: true,
                        voice: .secondary
                    ),
                ]
            ),
        ]

        let result = await coordinator.refresh(
            key: .init(sourceID: "source", songID: "ambiguous-background"),
            currentDocument: cached,
            trigger: .explicit,
            fetch: { fetched },
            replace: { _ in true }
        )

        #expect(result == .failedPreservingCache)
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
