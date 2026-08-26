import Foundation
import Testing
@testable import PrimuseKit

struct LyricTranslationGroupingPolicyTests {
    @Test func wholeLyricsMatchingTargetDoNotNeedTranslation() {
        #expect(!LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "zh-CN",
            targetLanguageCode: "zh-Hans"
        ))
        #expect(LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "zh-TW",
            targetLanguageCode: "zh-Hans"
        ))
        #expect(LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: nil,
            targetLanguageCode: "zh-Hans"
        ))
    }

    @Test func shortLocalizedCreditFallsBackFromNoisyTurkishDetection() {
        let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "作曲 : ASKA",
            detectedLanguageCode: "tr",
            confidence: 0.555,
            alternativeConfidence: 0.20,
            fallbackSourceLanguageCode: "zh-Hans"
        )

        #expect(source == "zh-Hans")
    }

    @Test func confidentForeignLineCanOverrideWholeLyricsLanguage() {
        let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "I will always love you",
            detectedLanguageCode: "en-US",
            confidence: 0.99,
            alternativeConfidence: 0.01,
            fallbackSourceLanguageCode: "zh-Hans"
        )

        #expect(source == "en")
    }

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

    @Test func automaticSessionsUseOnlyInstalledKnownLanguagePairs() {
        let installed = [
            LyricTranslationGroup(
                id: "en",
                sourceLanguageCode: "en",
                candidates: [.init(id: "en-1", text: "Hello", sourceLanguageCode: "en")]
            ),
            LyricTranslationGroup(
                id: "auto",
                sourceLanguageCode: nil,
                candidates: [.init(id: "auto-1", text: "Yo", sourceLanguageCode: nil)]
            )
        ]

        let selected = LyricTranslationGroupingPolicy.automaticSessionGroups(
            installed: installed
        )

        #expect(selected.map(\.id) == ["en"])
    }

    @Test func explicitPreparationChoosesOnlyTheLargestLanguageGroup() {
        let preparationRequired = [
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

        let selected = LyricTranslationGroupingPolicy.explicitlyRequestedSessionGroup(
            preparationRequired: preparationRequired
        )

        #expect(selected?.id == "ja")
    }

    @Test func wholeLyricsFallbackDoesNotHideConfidentForeignLines() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "target", text: "这是中文歌词", sourceLanguageCode: "zh-Hans"),
                .init(id: "foreign", text: "I will always love you", sourceLanguageCode: "en"),
            ],
            targetLanguageCode: "zh-Hans",
            fallbackSourceLanguageCode: "zh-Hans"
        )

        #expect(groups.map(\.id) == ["en"])
        #expect(groups[0].candidates.map(\.id) == ["foreign"])
    }

    @Test func preparationAuthorizationIsConsumedOnlyOnce() {
        var gate = LyricTranslationPreparationRequestGate()
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let revision = gate.issue(at: issuedAt)

        let firstConsumption = gate.consume(
            revision: revision,
            at: issuedAt.addingTimeInterval(1)
        )
        let repeatedConsumption = gate.consume(
            revision: revision,
            at: issuedAt.addingTimeInterval(2)
        )
        #expect(firstConsumption)
        #expect(!repeatedConsumption)
    }

    @Test func expiredPreparationAuthorizationCannotReappearAfterRemount() {
        var gate = LyricTranslationPreparationRequestGate()
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let revision = gate.issue(at: issuedAt)

        let expiredConsumption = gate.consume(
            revision: revision,
            at: issuedAt.addingTimeInterval(31),
            maximumAge: 30
        )
        let remountedConsumption = gate.consume(
            revision: revision,
            at: issuedAt.addingTimeInterval(5)
        )
        #expect(!expiredConsumption)
        #expect(!remountedConsumption)
    }

    @Test func invalidatedPreparationAuthorizationCannotFollowASettingsChange() {
        var gate = LyricTranslationPreparationRequestGate()
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let revision = gate.issue(at: issuedAt)
        gate.invalidate()

        let consumption = gate.consume(
            revision: revision,
            at: issuedAt.addingTimeInterval(1)
        )
        #expect(!consumption)
    }
}
