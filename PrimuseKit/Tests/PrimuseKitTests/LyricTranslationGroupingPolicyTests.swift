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

    @Test func unknownLanguagesReceiveIndependentAutomaticGroups() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "short-1", text: "Yo", sourceLanguageCode: nil),
                .init(id: "short-2", text: "La", sourceLanguageCode: nil),
            ],
            targetLanguageCode: "fr"
        )

        #expect(groups.map(\.id) == ["auto:short-1", "auto:short-2"])
        #expect(groups.allSatisfy { $0.sourceLanguageCode == nil && $0.candidates.count == 1 })
    }
}
