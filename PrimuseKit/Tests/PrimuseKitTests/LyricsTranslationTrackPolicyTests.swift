import Foundation
import Testing
@testable import PrimuseKit

@Suite("Subtitle translation tracks")
struct LyricsTranslationTrackPolicyTests {
    /// yt-dlp's original track: word timing, rolling cues, sub-frame fillers.
    private let originalTrack = [
        "WEBVTT",
        "Kind: captions",
        "Language: en",
        "",
        "00:00:00.480 --> 00:00:02.869 align:start position:0%",
        " ",
        "never<00:00:00.880><c> gonna</c><00:00:01.199><c> give</c>"
            + "<00:00:01.439><c> you</c><00:00:01.760><c> up</c>",
        "",
        "00:00:02.869 --> 00:00:02.879 align:start position:0%",
        "never gonna give you up",
        " ",
        "",
        "00:00:02.879 --> 00:00:05.030 align:start position:0%",
        "never gonna give you up",
        "never<00:00:03.200><c> gonna</c><00:00:03.520><c> let</c>"
            + "<00:00:03.840><c> you</c><00:00:04.160><c> down</c>",
        "",
        "00:00:05.030 --> 00:00:05.040 align:start position:0%",
        "never gonna let you down",
        " ",
        "",
        "00:00:05.040 --> 00:00:07.500 align:start position:0%",
        "never gonna let you down",
        "never<00:00:05.440><c> run</c><00:00:05.760><c> around</c>",
    ].joined(separator: "\n")

    /// The same run's `zh-Hans` track: identical cue windows, no word timing.
    private let translatedTrack = [
        "WEBVTT",
        "Kind: captions",
        "Language: zh-Hans",
        "",
        "00:00:00.480 --> 00:00:02.869 align:start position:0%",
        " ",
        "永远不会放弃你",
        "",
        "00:00:02.869 --> 00:00:02.879 align:start position:0%",
        "永远不会放弃你",
        " ",
        "",
        "00:00:02.879 --> 00:00:05.030 align:start position:0%",
        "永远不会放弃你",
        "永远不会让你失望",
        "",
        "00:00:05.030 --> 00:00:05.040 align:start position:0%",
        "永远不会让你失望",
        " ",
        "",
        "00:00:05.040 --> 00:00:07.500 align:start position:0%",
        "永远不会让你失望",
        "永远不会到处乱跑",
    ].joined(separator: "\n")

    private func syncedLine(_ timestamp: TimeInterval, _ text: String) -> LyricLine {
        LyricLine(timestamp: timestamp, text: text, isSynchronized: true)
    }

    @Test("The translated track becomes the line under each sung line")
    func mergesIdenticallyTimedTracks() throws {
        let primary = SubtitleLyricsParser.parse(originalTrack)
        let translation = SubtitleLyricsParser.parse(translatedTrack)
        #expect(primary.count == 3)
        #expect(translation.count == 3)

        let merged = try #require(LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: "zh-Hans"
        ))

        let identifiers = merged.map(\.id)
        let originalIdentifiers = primary.map(\.id)
        #expect(identifiers == originalIdentifiers)

        let texts = merged.map(\.text)
        let originalTexts = primary.map(\.text)
        #expect(texts == originalTexts)

        let translations = merged.map { $0.manualTranslation?.text }
        let expectedTranslations = ["永远不会放弃你", "永远不会让你失望", "永远不会到处乱跑"]
        #expect(translations == expectedTranslations)

        let sources = merged.compactMap { $0.manualTranslation?.source }
        let expectedSources = [
            LyricManualTranslationSource.embeddedField,
            .embeddedField,
            .embeddedField,
        ]
        #expect(sources == expectedSources)

        let languageCodes = merged.map { $0.manualTranslation?.languageCode }
        let expectedLanguageCodes = ["zh-Hans", "zh-Hans", "zh-Hans"]
        #expect(languageCodes == expectedLanguageCodes)

        // The sung line keeps its own word timing; only a second line is added.
        let syllableCounts = merged.map { $0.syllables?.count }
        let originalSyllableCounts = primary.map { $0.syllables?.count }
        #expect(syllableCounts == originalSyllableCounts)
        let expectedSyllableCounts = [5, 5, 3]
        #expect(syllableCounts == expectedSyllableCounts)
    }

    @Test("Differently timed subtitles are not a translation of this document")
    func refusesMergeBelowCoverage() {
        let primary = [
            syncedLine(1, "one"),
            syncedLine(2, "two"),
            syncedLine(3, "three"),
            syncedLine(4, "four"),
            syncedLine(5, "five"),
        ]
        // Only two of five land on a shared timestamp: a human-authored
        // subtitle for the same song, not the machine translation of it.
        let translation = [
            syncedLine(1, "一"),
            syncedLine(2.5, "二"),
            syncedLine(3.4, "三"),
            syncedLine(4, "四"),
            syncedLine(6.2, "五"),
        ]
        #expect(LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: "zh-Hans"
        ) == nil)
    }

    @Test("An unsynchronized document has no timeline to match")
    func refusesUnsynchronizedInput() {
        let plainPrimary = [
            LyricLine(timestamp: 0, text: "one", isSynchronized: false),
            LyricLine(timestamp: 0, text: "two", isSynchronized: false),
        ]
        let translation = [syncedLine(1, "一"), syncedLine(2, "二")]
        #expect(LyricsTranslationTrackPolicy.merging(
            primary: plainPrimary,
            translation: translation,
            languageCode: "zh-Hans"
        ) == nil)
        #expect(LyricsTranslationTrackPolicy.merging(
            primary: translation,
            translation: plainPrimary,
            languageCode: "zh-Hans"
        ) == nil)
    }

    @Test("A cue that carries its own translation keeps it")
    func keepsBilingualCueTranslation() throws {
        var bilingual = syncedLine(2, "two")
        bilingual.manualTranslation = LyricManualTranslation(
            text: "第二行",
            languageCode: "zh-Hans",
            source: .bilingualLRC
        )
        let primary = [syncedLine(1, "one"), bilingual, syncedLine(3, "three")]
        let translation = [syncedLine(1, "一"), syncedLine(2, "二"), syncedLine(3, "三")]

        let merged = try #require(LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: "zh-Hans"
        ))
        #expect(merged[1].manualTranslation?.text == "第二行")
        #expect(merged[1].manualTranslation?.source == .bilingualLRC)
        #expect(merged[1].alternateManualTranslations.isEmpty)
        #expect(merged[0].manualTranslation?.text == "一")
        #expect(merged[2].manualTranslation?.text == "三")
    }

    @Test("A document translated throughout is left exactly as it is")
    func refusesMergeIntoFullyBilingualDocument() {
        var primary: [LyricLine] = []
        for index in 1...4 {
            var line = syncedLine(TimeInterval(index), "line \(index)")
            line.manualTranslation = LyricManualTranslation(
                text: "第 \(index) 行",
                languageCode: "zh-Hans",
                source: .bilingualLRC
            )
            primary.append(line)
        }
        let translation = (1...4).map { syncedLine(TimeInterval($0), "机翻 \($0)") }
        #expect(LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: "zh-Hans"
        ) == nil)
    }

    @Test("A line the translation never reached simply stays untranslated")
    func leavesUnmatchedLinesAlone() throws {
        let primary = [
            syncedLine(1, "one"),
            syncedLine(2, "two"),
            syncedLine(3, "three"),
            syncedLine(4, "four"),
        ]
        let translation = [syncedLine(1, "一"), syncedLine(2, "二"), syncedLine(3, "三")]

        let merged = try #require(LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: "zh-Hans"
        ))
        let translations = merged.map { $0.manualTranslation?.text }
        let expectedTranslations: [String?] = ["一", "二", "三", nil]
        #expect(translations == expectedTranslations)
    }
}
