import Testing
@testable import PrimuseKit

struct LyricTranslationNoticePolicyTests {
    @Test func matchingTargetLanguageDoesNotShowUnavailable() {
        let lyrics = lines(["晚风轻轻吹过", "我们沿着河岸走"])
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: lyrics.map {
                LyricTranslationCandidate(id: $0.id, text: $0.text, sourceLanguageCode: "zh-Hans")
            },
            targetLanguageCode: "zh-Hans"
        )

        #expect(groups.isEmpty)
        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(groups.flatMap(\.candidates).map(\.id))
        ))
    }

    @Test(arguments: [1, 2])
    func smallUnsupportedPortionStaysQuiet(unsupportedCount: Int) {
        let lyrics = lines(Array(repeating: "We walk beside the river", count: 10))

        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(lyrics.prefix(unsupportedCount).map(\.id))
        ))
    }

    @Test func substantialUnsupportedPortionStillShowsNotice() {
        let lyrics = lines(Array(repeating: "We walk beside the river", count: 10))

        #expect(showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(lyrics.prefix(3).map(\.id))
        ))
    }

    @Test func entirelyUnsupportedShortLyricsStillShowNotice() {
        let lyrics = lines(["We walk beside the river"])

        #expect(showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: [lyrics[0].id]
        ))
    }

    @Test func foreignCreditsDoNotMakeTargetLanguageLyricsUnavailable() {
        let lyrics = lines([
            "作曲：ASKA", "Lyrics by: Someone", "Producer: Someone",
            "晚风轻轻吹过", "我们沿着河岸走",
        ])

        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(lyrics.prefix(3).map(\.id))
        ))
    }

    @Test func blankSymbolAndCreditRowsDoNotDiluteActualFailures() {
        let lyrics = lines([
            "We walk beside the river", " ", "♪", "…", "123", "作曲：Someone",
        ])

        #expect(showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: [lyrics[0].id]
        ))
        #expect(!showsUnavailable(
            lyrics: Array(lyrics.dropFirst()),
            unsupportedLineIDs: Set(lyrics.dropFirst().map(\.id))
        ))
    }

    @Test func staleLineIDsCannotShowNoticeForCurrentLyrics() {
        #expect(!showsUnavailable(
            lyrics: lines(["晚风轻轻吹过"]),
            unsupportedLineIDs: ["previous-song"]
        ))
        #expect(!showsUnavailable(
            lyrics: [],
            unsupportedLineIDs: ["previous-song"]
        ))
    }

    @Test func quietNoticeDoesNotRemoveMinorityLanguageTranslationWork() {
        let lyrics = lines(["晚风轻轻吹过", "我们沿着河岸走", "星光落在水面", "等下一次相逢", "Good night"])
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: lyrics.enumerated().map { index, line in
                LyricTranslationCandidate(
                    id: line.id,
                    text: line.text,
                    sourceLanguageCode: index == 4 ? "en" : "zh-Hans"
                )
            },
            targetLanguageCode: "zh-Hans"
        )

        #expect(groups.count == 1)
        #expect(groups.first?.candidates.map(\.id) == [lyrics[4].id])
        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(groups.flatMap(\.candidates).map(\.id))
        ))
    }

    @Test func backgroundVocalsUseTheSameCoverageAsTranslationPreparation() {
        let background = LyricLine(id: "background", timestamp: 1, text: "Good night")
        var lyrics = lines(Array(repeating: "晚风轻轻吹过", count: 4))
        lyrics[0].background = [background]

        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: [background.id]
        ))
        #expect(showsUnavailable(
            lyrics: [lyrics[0]],
            unsupportedLineIDs: [background.id]
        ))
    }

    @Test(arguments: ["zh", "zh-TW", "zh-Hant"])
    func sameLanguageScriptConversionFailureStaysQuiet(sourceLanguage: String) {
        let lyrics = lines(["晚風輕輕吹過", "我們沿著河岸走"])
        #expect(!showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(lyrics.map(\.id)),
            sourceLanguageCode: sourceLanguage
        ))
        #expect(!LyricTranslationGroupingPolicy.groups(
            candidates: lyrics.map {
                LyricTranslationCandidate(id: $0.id, text: $0.text, sourceLanguageCode: sourceLanguage)
            },
            targetLanguageCode: "zh-Hans"
        ).isEmpty)
    }

    @Test func unknownSourceDoesNotHideAConfirmedUnsupportedPair() {
        let lyrics = lines(["Unrecognized foreign lyrics"])
        #expect(showsUnavailable(
            lyrics: lyrics,
            unsupportedLineIDs: Set(lyrics.map(\.id)),
            sourceLanguageCode: nil
        ))
    }

    @Test func scriptVariantsDoNotInflateTheForeignFailureRatio() {
        let lyrics = lines(["晚風轻轻吹過", "我們沿著河岸走", "星光落在水面", "等下一次相逢", "Good night"])
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: lyrics.enumerated().map { index, line in
                LyricTranslationCandidate(
                    id: line.id,
                    text: line.text,
                    sourceLanguageCode: index == 4 ? "en" : "zh-Hant"
                )
            },
            targetLanguageCode: "zh-Hans"
        )

        #expect(groups.count == 2)
        #expect(!LyricTranslationNoticePolicy.shouldShowUnavailable(
            lyrics: lyrics,
            unsupportedGroups: groups,
            targetLanguageCode: "zh-Hans"
        ))
    }

    private func showsUnavailable(
        lyrics: [LyricLine],
        unsupportedLineIDs: Set<String>,
        sourceLanguageCode: String? = "en"
    ) -> Bool {
        let group = LyricTranslationGroup(
            id: sourceLanguageCode ?? "auto",
            sourceLanguageCode: sourceLanguageCode,
            candidates: unsupportedLineIDs.map {
                LyricTranslationCandidate(id: $0, text: "Foreign lyric", sourceLanguageCode: sourceLanguageCode)
            }
        )
        return LyricTranslationNoticePolicy.shouldShowUnavailable(
            lyrics: lyrics,
            unsupportedGroups: [group],
            targetLanguageCode: "zh-Hans"
        )
    }

    private func lines(_ texts: [String]) -> [LyricLine] {
        texts.enumerated().map {
            LyricLine(id: "line-\($0.offset)", timestamp: Double($0.offset), text: $0.element)
        }
    }
}
