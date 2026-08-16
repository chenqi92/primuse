import Testing
@testable import PrimuseKit

struct LyricTranslationGroupingPolicyTests {
    @Test func groupsDetectedLinesBySourceLanguageAndPreservesOrder() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "en-1", text: "Hello", sourceLanguageCode: "en-US"),
                .init(id: "ko-1", text: "annyeong", sourceLanguageCode: "ko"),
                .init(id: "en-2", text: "World", sourceLanguageCode: "en-GB"),
            ],
            targetLanguageCode: "zh-Hans"
        )

        #expect(groups.map(\.sourceLanguageCode) == ["en", "ko"])
        #expect(groups[0].candidates.map(\.id) == ["en-1", "en-2"])
        #expect(groups[1].candidates.map(\.id) == ["ko-1"])
    }

    @Test func skipsOnlyLinesThatAlreadyMatchTheTargetLanguage() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "simplified", text: "简体", sourceLanguageCode: "zh-CN"),
                .init(id: "traditional", text: "繁體", sourceLanguageCode: "zh-TW"),
                .init(id: "english", text: "English", sourceLanguageCode: "en"),
            ],
            targetLanguageCode: "zh-Hans"
        )

        #expect(groups.map(\.sourceLanguageCode) == ["zh-Hant", "en"])
        #expect(groups.flatMap(\.candidates).map(\.id) == ["traditional", "english"])
    }

    @Test func unknownLanguagesShareOneAutomaticGroup() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "short-1", text: "Yo", sourceLanguageCode: nil),
                .init(id: "short-2", text: "La", sourceLanguageCode: nil),
            ],
            targetLanguageCode: "fr"
        )

        #expect(groups.map(\.id) == ["auto"])
        #expect(groups[0].sourceLanguageCode == nil)
        #expect(groups[0].candidates.map(\.id) == ["short-1", "short-2"])
    }

    @Test func unknownLinesUseTheWholeLyricsLanguageWhenAvailable() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "known", text: "Hello world", sourceLanguageCode: "en-US"),
                .init(id: "short", text: "Oh", sourceLanguageCode: nil),
            ],
            targetLanguageCode: "zh-Hans",
            fallbackSourceLanguageCode: "en-GB"
        )

        #expect(groups.map(\.sourceLanguageCode) == ["en"])
        #expect(groups[0].candidates.map(\.id) == ["known", "short"])
    }

    @Test func automaticSessionsRequestAtMostOneDownload() {
        let installed = [
            LyricTranslationGroup(
                id: "en",
                sourceLanguageCode: "en",
                candidates: [.init(id: "en-1", text: "Hello", sourceLanguageCode: "en")]
            )
        ]
        let downloadable = [
            LyricTranslationGroup(
                id: "ko",
                sourceLanguageCode: "ko",
                candidates: [.init(id: "ko-1", text: "A", sourceLanguageCode: "ko")]
            ),
            LyricTranslationGroup(
                id: "ja",
                sourceLanguageCode: "ja",
                candidates: [
                    .init(id: "ja-1", text: "B", sourceLanguageCode: "ja"),
                    .init(id: "ja-2", text: "C", sourceLanguageCode: "ja"),
                ]
            ),
        ]

        let selected = LyricTranslationGroupingPolicy.automaticSessionGroups(
            installed: installed,
            downloadable: downloadable
        )

        #expect(selected.map(\.id) == ["en", "ja"])
    }
}
