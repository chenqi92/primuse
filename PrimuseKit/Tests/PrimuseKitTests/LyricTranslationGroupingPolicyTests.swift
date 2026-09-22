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
        #expect(!LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "fa-Arab",
            targetLanguageCode: "fa"
        ))
        #expect(LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "fa-Latn",
            targetLanguageCode: "fa"
        ))
        #expect(LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "fa-Cyrl",
            targetLanguageCode: "fa"
        ))
    }

    @Test func translationTerminalPolicySeparatesNoWorkFromReadyWork() {
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 0,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 0
        ) == .notNeeded)
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 3,
            availableGroupCount: 1,
            preparationRequiredGroupCount: 1,
            unsupportedCandidateCount: 1
        ) == .ready)
    }

    @Test func translationTerminalPolicyKeepsRecoverableStatesPreparatory() {
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 1,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 1,
            unsupportedCandidateCount: 0
        ) == .preparationRequired)
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 1,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 0,
            encounteredUnknownStatus: true
        ) == .preparationRequired)
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 1,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 1,
            encounteredError: true
        ) == .preparationRequired)
    }

    @Test func translationTerminalPolicyUsesUnavailableOnlyForConfirmedUnsupportedPairs() {
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 2,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 2
        ) == .unavailable)
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 2,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 1
        ) == .preparationRequired)
        #expect(LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: 2,
            availableGroupCount: 0,
            preparationRequiredGroupCount: 0,
            unsupportedCandidateCount: 0
        ) == .preparationRequired)
    }

    @Test func translationTerminalPolicyReportsWorkRemainingAfterRunnableGroups() {
        #expect(LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: 0,
            unsupportedCandidateCount: 0
        ) == .notNeeded)
        #expect(LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: 0,
            unsupportedCandidateCount: 2
        ) == .unavailable)
        #expect(LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: 1,
            unsupportedCandidateCount: 2
        ) == .preparationRequired)
        #expect(LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: 0,
            unsupportedCandidateCount: 2,
            encounteredError: true
        ) == .preparationRequired)
    }

    @Test func containerLanguageCodesCanonicalizeBeforeComparison() {
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("eng") == "en")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("fas") == "fa")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("per") == "fa")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("chi") == "zh")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("ger") == "de")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("fre") == "fr")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("ace") == "ace")
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("not_a_real_language") == nil)
        #expect(LyricLanguageCodePolicy.canonicalIdentifier("zz") == nil)

        #expect(LyricTranslationGroupingPolicy.languageIdentity("eng") == "en")
        #expect(LyricTranslationGroupingPolicy.languageIdentity("fas") == "fa")
        #expect(LyricTranslationGroupingPolicy.languageIdentity("per") == "fa")
        #expect(!LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: "per",
            targetLanguageCode: "fa"
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

    @Test func shortSameScriptMisclassificationFallsBackRegardlessOfConfidence() {
        for (text, detectedLanguage) in [("Stay", "nb"), ("Again", "da")] {
            let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
                text: text,
                detectedLanguageCode: detectedLanguage,
                confidence: 0.999,
                alternativeConfidence: 0,
                fallbackSourceLanguageCode: "en"
            )
            #expect(source == "en")
        }
    }

    @Test func shortDistinctScriptLinesKeepTheirDetectedLanguage() {
        let english = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "Stay",
            detectedLanguageCode: "en",
            confidence: 0.40,
            alternativeConfidence: 0.35,
            fallbackSourceLanguageCode: "zh-Hans"
        )
        let chinese = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "再见",
            detectedLanguageCode: "zh-Hans",
            confidence: 0.40,
            alternativeConfidence: 0.35,
            fallbackSourceLanguageCode: "en"
        )
        let arabic = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "مرحبا",
            detectedLanguageCode: "ar",
            confidence: 0.40,
            alternativeConfidence: 0.35,
            fallbackSourceLanguageCode: "en"
        )

        #expect(english == "en")
        #expect(chinese == "zh-Hans")
        #expect(arabic == "ar")
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

    @Test func persianOrthographyCorrectsConfidentArabicDetection() {
        let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "این یک ترانه فارسی است که برای آزمون نوشته شده است",
            detectedLanguageCode: "ar",
            confidence: 0.999998,
            fallbackSourceLanguageCode: nil
        )

        #expect(source == "fa")
    }

    @Test func persianNeverUsesTheAppleSystemTranslationRoute() {
        #expect(!LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
            sourceLanguageCode: "fas",
            targetLanguageCode: "zh-Hans"
        ))
        #expect(!LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
            sourceLanguageCode: "en",
            targetLanguageCode: "fa-Arab"
        ))
        #expect(LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-Hans"
        ))
        #expect(LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
            sourceLanguageCode: nil,
            targetLanguageCode: "de"
        ))
    }

    @Test func arabicGlyphVariantsDoNotHidePersianLexicalEvidence() {
        let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "اين يك ترانه فارسي است كه براي آزمون نوشته شده است",
            detectedLanguageCode: "ar",
            confidence: 1,
            fallbackSourceLanguageCode: nil
        )

        #expect(source == "fa")
    }

    @Test func ordinaryArabicRemainsArabic() {
        for text in [
            "مرحبا بالعالم هذه أغنية عربية جميلة",
            "السلام عليكم ورحمة الله وبركاته",
            "السلام علیکم ورحمة الله وبركاته",
        ] {
            let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
                text: text,
                detectedLanguageCode: "ar",
                confidence: 1,
                fallbackSourceLanguageCode: nil
            )
            #expect(source == "ar")
        }
    }

    @Test func persianFallbackStillRequiresLineEvidence() {
        let persian = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "چشم من",
            detectedLanguageCode: "ar",
            confidence: 0.99,
            fallbackSourceLanguageCode: "fa"
        )
        let arabic = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
            text: "مرحبا بالعالم",
            detectedLanguageCode: "ar",
            confidence: 0.99,
            fallbackSourceLanguageCode: "fa"
        )

        #expect(persian == "fa")
        #expect(arabic == "ar")
    }

    @Test func declaredPersianCoversSharedArabicScriptWordsButNotLatinLines() {
        let sharedWord = LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "سلام",
            detectedLanguageCode: "ar",
            declaredSourceLanguageCode: "fa"
        )
        let latinLine = LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "English chorus",
            detectedLanguageCode: "en",
            declaredSourceLanguageCode: "fa"
        )

        #expect(sharedWord == "fa")
        #expect(latinLine == nil)
    }

    @Test func declaredPersianScriptTagPreservesItsIdentity() {
        #expect(LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "سلام",
            detectedLanguageCode: "ar",
            declaredSourceLanguageCode: "fa-Arab"
        ) == "fa-Arab")
        #expect(LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "salaam",
            detectedLanguageCode: "en",
            declaredSourceLanguageCode: "fa-Latn"
        ) == nil)
    }

    @Test func urduDetectionRequiresConfirmedPersianContext() {
        for text in [
            "چشم من",
            "عشق من تویی",
            "یہ ایک خوبصورت اردو گانا ہے",
            "میرے دوست کیسے ہیں",
            "پیارے دوست کیسے ہو",
            "اگر دوست ہے",
        ] {
            #expect(LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
                text: text,
                detectedLanguageCode: "ur"
            ) == nil)
        }

        #expect(LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "چشم من",
            detectedLanguageCode: "ur",
            fallbackSourceLanguageCode: "fa"
        ) == "fa")
        #expect(LyricTranslationGroupingPolicy.correctedPersianLanguageCode(
            text: "سلام",
            detectedLanguageCode: "ur",
            declaredSourceLanguageCode: "fa"
        ) == "fa")
    }

    @Test func shortLatinChorusDoesNotFallBackToPersian() {
        for (text, confidence) in [("English chorus", 0.213), ("Oh no", 0.447)] {
            let source = LyricTranslationGroupingPolicy.reconciledLineLanguageCode(
                text: text,
                detectedLanguageCode: "en",
                confidence: confidence,
                alternativeConfidence: 0.20,
                fallbackSourceLanguageCode: "fa"
            )
            #expect(source == "en")
        }
    }

    @Test func declaredLyricsLanguageParsesAndValidatesMetadata() {
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[ti:Sample]", " [LA: fa-IR] ",
        ]) == "fa")
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[la:fa_Latn]",
        ]) == "fa-Latn")
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[ar:Artist]", "[la:not_a_real_language]", "[la:zz]",
        ]) == nil)
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[la:eng]",
        ]) == "en")
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[la:fas]",
        ]) == "fa")
        #expect(LyricTranslationGroupingPolicy.declaredLanguageCode(in: [
            "[la:per]",
        ]) == "fa")
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

    @Test func synchronizedManualLyricsMergeOnlyUniqueTimestampMatches() {
        let originals = [
            LyricLine(id: "source-1", timestamp: 1, text: "First", isSynchronized: true),
            LyricLine(id: "source-2", timestamp: 2, text: "Second", isSynchronized: true),
            LyricLine(id: "source-3", timestamp: 3, text: "Third", isSynchronized: true),
        ]
        let translations = [
            LyricLine(id: "translation-3", timestamp: 3, text: "第三", isSynchronized: true),
            LyricLine(id: "translation-1", timestamp: 1, text: "第一", isSynchronized: true),
            LyricLine(id: "unmatched", timestamp: 4, text: "额外", isSynchronized: true),
        ]

        let merged = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: translations,
            translationLanguageCode: "zh-Hans"
        )

        #expect(merged.map(\.id) == originals.map(\.id))
        #expect(merged.map { $0.manualTranslation?.text } == ["第一", nil, "第三"])
        #expect(merged[0].manualTranslation?.id == "translation-1")
        #expect(merged[0].manualTranslation?.languageCode == "zh-Hans")
        #expect(merged[0].manualTranslation?.source == .embeddedField)
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(in: merged))
    }

    @Test func ambiguousDuplicateTimestampsAreNeverGuessed() {
        let originals = [
            LyricLine(timestamp: 1, text: "Lead", isSynchronized: true),
            LyricLine(timestamp: 1, text: "Backing", isSynchronized: true),
        ]
        let translations = [
            LyricLine(timestamp: 1, text: "主唱", isSynchronized: true),
            LyricLine(timestamp: 1, text: "和声", isSynchronized: true),
        ]

        let merged = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: translations,
            translationLanguageCode: "zh"
        )

        #expect(merged.allSatisfy { $0.manualTranslation == nil })
    }

    @Test func plainManualLyricsRequireAnExactIndexShape() {
        let originals = [
            LyricLine(timestamp: 0, text: "First", isSynchronized: false),
            LyricLine(timestamp: 0, text: "Second", isSynchronized: false),
        ]
        let translations = [
            LyricLine(timestamp: 0, text: "第一", isSynchronized: false),
            LyricLine(timestamp: 0, text: "第二", isSynchronized: false),
        ]

        let complete = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: translations,
            translationLanguageCode: "zh"
        )
        #expect(complete.map { $0.manualTranslation?.text } == ["第一", "第二"])
        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(in: complete))

        let incompleteShape = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: Array(translations.prefix(1)),
            translationLanguageCode: "zh"
        )
        #expect(incompleteShape.allSatisfy { $0.manualTranslation == nil })

        let mixedSynchronization = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: [
                LyricLine(timestamp: 1, text: "第一", isSynchronized: true),
                translations[1],
            ],
            translationLanguageCode: "zh"
        )
        #expect(mixedSynchronization.allSatisfy { $0.manualTranslation == nil })
    }

    @Test func additionalLanguageFieldsAreRetainedWithoutChangingThePreferredTranslation() {
        let originals = [
            LyricLine(timestamp: 0, text: "原文", isSynchronized: false),
        ]
        let english = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: [
                LyricLine(id: "en", timestamp: 0, text: "English", isSynchronized: false),
            ],
            translationLanguageCode: "en"
        )
        let withFrenchAlternate = LyricManualTranslationPolicy.merging(
            originalLines: english,
            translatedLines: [
                LyricLine(id: "fr", timestamp: 0, text: "Français", isSynchronized: false),
            ],
            translationLanguageCode: "fr",
            makePreferred: false
        )

        #expect(withFrenchAlternate[0].manualTranslation?.languageCode == "en")
        #expect(withFrenchAlternate[0].alternateManualTranslations.map(\.languageCode) == ["fr"])
        #expect(withFrenchAlternate[0].allManualTranslations.map(\.text) == [
            "English", "Français",
        ])
        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(in: withFrenchAlternate))
    }

    @Test func aNonPreferredFieldCannotReplaceAnExplicitTranslationInTheSameLanguage() {
        let originals = [
            LyricLine(timestamp: 0, text: "原文", isSynchronized: false),
        ]
        let explicit = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: [
                LyricLine(id: "explicit", timestamp: 0, text: "Explicit", isSynchronized: false),
            ],
            translationLanguageCode: "en"
        )
        let merged = LyricManualTranslationPolicy.merging(
            originalLines: explicit,
            translatedLines: [
                LyricLine(id: "tagged", timestamp: 0, text: "Tagged", isSynchronized: false),
            ],
            translationLanguageCode: "eng",
            makePreferred: false
        )

        #expect(merged[0].manualTranslation?.text == "Explicit")
        #expect(merged[0].alternateManualTranslations.isEmpty)
    }

    @Test func targetLanguageSelectsAnExactEmbeddedAlternate() {
        let line = LyricLine(
            timestamp: 0,
            text: "Original",
            isSynchronized: false,
            manualTranslation: LyricManualTranslation(
                text: "Français",
                languageCode: "fr",
                source: .embeddedField
            ),
            alternateManualTranslations: [
                LyricManualTranslation(
                    text: "中文",
                    languageCode: "zh-CN",
                    source: .embeddedField
                ),
            ]
        )

        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: line,
            targetLanguageCode: "zh-Hans"
        )?.text == "中文")
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: line,
            targetLanguageCode: "de"
        ) == nil)

        var persian = line
        persian.alternateManualTranslations.append(
            LyricManualTranslation(
                text: "فارسی",
                languageCode: "fa-Arab",
                source: .embeddedField
            )
        )
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: persian,
            targetLanguageCode: "fa"
        )?.text == "فارسی")
    }

    @Test func targetLanguageUsesAuthoredSourcePriorityWithinAnExactMatch() {
        let line = LyricLine(
            timestamp: 1,
            text: "Original",
            isSynchronized: true,
            manualTranslation: .init(
                text: "Source bilingual",
                languageCode: "fr",
                source: .bilingualLRC
            ),
            alternateManualTranslations: [
                .init(
                    text: "Local correction",
                    languageCode: "fr",
                    source: .localEditor
                ),
            ]
        )

        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: line,
            targetLanguageCode: "fr"
        )?.text == "Local correction")
    }

    @Test func persianScriptAliasesOccupyOneTranslationSlot() {
        let line = LyricLine(
            timestamp: 1,
            text: "Original",
            isSynchronized: true,
            manualTranslation: .init(
                text: "فارسی",
                languageCode: "fa",
                source: .bilingualLRC
            )
        )
        let merged = LyricManualTranslationPolicy.merging(
            originalLines: [line],
            translatedLines: [
                LyricLine(timestamp: 1, text: "فارسی", isSynchronized: true),
            ],
            translationLanguageCode: "fa-Arab",
            source: .bilingualLRC,
            makePreferred: false
        )

        #expect(merged[0].alternateManualTranslations.isEmpty)
    }

    @Test func persianArabicScriptCandidatesAreNoOpsForPersianTargets() {
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: [
                .init(id: "fa", text: "من اینجا هستم", sourceLanguageCode: "fa-Arab"),
            ],
            targetLanguageCode: "fa"
        )
        #expect(groups.isEmpty)
    }

    @Test func untaggedBilingualRowsCoverAnyRequestedTarget() {
        let lines = [
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: LyricManualTranslation(
                    text: "人工译文",
                    source: .bilingualLRC
                )
            ),
        ]

        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(
            in: lines,
            targetLanguageCode: "fa"
        ))
    }

    @Test func nonPreferredLanguageFieldRemainsSelectableByTarget() {
        let originals = [
            LyricLine(timestamp: 0, text: "Original", isSynchronized: false),
        ]
        let merged = LyricManualTranslationPolicy.merging(
            originalLines: originals,
            translatedLines: [
                LyricLine(timestamp: 0, text: "فارسی", isSynchronized: false),
            ],
            translationLanguageCode: "per",
            makePreferred: false
        )

        #expect(merged[0].manualTranslation == nil)
        #expect(merged[0].alternateManualTranslations.map(\.languageCode) == ["per"])
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: merged[0],
            targetLanguageCode: "fa"
        )?.text == "فارسی")
        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(
            in: merged,
            targetLanguageCode: "fa"
        ))
    }

    @Test func aNewPreferredLanguagePreservesThePreviousAuthoredTranslation() {
        let source = LyricLine(
            timestamp: 0,
            text: "原文",
            isSynchronized: false,
            manualTranslation: LyricManualTranslation(
                id: "bilingual",
                text: "English",
                languageCode: "en",
                source: .bilingualLRC
            )
        )
        let merged = LyricManualTranslationPolicy.merging(
            originalLines: [source],
            translatedLines: [
                LyricLine(id: "embedded", timestamp: 0, text: "Français", isSynchronized: false),
            ],
            translationLanguageCode: "fr",
            source: .embeddedField
        )

        #expect(merged[0].manualTranslation?.text == "Français")
        #expect(merged[0].manualTranslation?.source == .embeddedField)
        #expect(merged[0].alternateManualTranslations.first?.text == "English")
        #expect(merged[0].alternateManualTranslations.first?.source == .bilingualLRC)
    }

    @Test func authoritativeSourceCanRestoreOnlyMatchingStoredTranslations() {
        let stored = [
            LyricLine(
                timestamp: 12.3,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "La brise du soir",
                    languageCode: "fr",
                    source: .embeddedField
                ),
                alternateManualTranslations: [
                    .init(text: "Abendbrise", languageCode: "de", source: .embeddedField),
                ]
            ),
        ]
        let authoritative = [
            LyricLine(
                id: "authoritative",
                timestamp: 12.3,
                text: "The evening breeze",
                isSynchronized: true,
                endTimestamp: 15
            ),
        ]

        let restored = LyricManualTranslationPolicy.restoringStoredTranslations(
            from: stored,
            into: authoritative
        )

        #expect(restored?.first?.id == "authoritative")
        #expect(restored?.first?.manualTranslation?.text == "La brise du soir")
        #expect(restored?.first?.alternateManualTranslations.first?.text == "Abendbrise")

        let changedSource = [
            LyricLine(timestamp: 12.3, text: "A different lyric", isSynchronized: true),
        ]
        #expect(LyricManualTranslationPolicy.restoringStoredTranslations(
            from: stored,
            into: changedSource
        ) == nil)
    }

    @Test func knownSameScriptBilingualPairsSurvivePrefixAndTimelineChanges() throws {
        let stored = [
            LyricLine(
                timestamp: 1,
                text: "First",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Premier",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
            LyricLine(
                timestamp: 2,
                text: "Second",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Deuxième",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
        ]
        let authoritative = [
            LyricLine(timestamp: 0.5, text: "Intro", isSynchronized: true),
            LyricLine(timestamp: 1.1, text: "First", isSynchronized: true),
            LyricLine(timestamp: 1.1, text: "Premier", isSynchronized: true),
            LyricLine(timestamp: 2.1, text: "Second", isSynchronized: true),
            LyricLine(timestamp: 2.1, text: "Deuxième", isSynchronized: true),
        ]

        let merged = try #require(
            LyricManualTranslationPolicy.preservingStoredTranslations(
                from: stored,
                in: authoritative
            )
        )
        #expect(merged.map(\.text) == ["Intro", "First", "Second"])
        #expect(merged[0].manualTranslation == nil)
        #expect(merged[1].manualTranslation?.text == "Premier")
        #expect(merged[2].manualTranslation?.text == "Deuxième")
        #expect(merged.dropFirst().allSatisfy {
            $0.manualTranslation?.source == .bilingualLRC
        })
    }

    @Test func protectedTranslationsDoNotFollowChangedLanguageOrVoiceOwners() {
        let stored = [
            LyricLine(
                timestamp: 1,
                text: "Shared text",
                isSynchronized: true,
                voice: .primary,
                languageCode: "fr",
                manualTranslation: .init(
                    text: "Local translation",
                    languageCode: "en",
                    source: .localEditor
                )
            ),
        ]
        let changedLanguage = [
            LyricLine(
                timestamp: 1,
                text: "Shared text",
                isSynchronized: true,
                voice: .primary,
                languageCode: "de"
            ),
        ]
        let changedVoice = [
            LyricLine(
                timestamp: 1,
                text: "Shared text",
                isSynchronized: true,
                voice: .secondary,
                languageCode: "fr"
            ),
        ]

        #expect(LyricManualTranslationPolicy.preservingStoredTranslations(
            from: stored,
            in: changedLanguage
        ) == nil)
        #expect(LyricManualTranslationPolicy.preservingStoredTranslations(
            from: stored,
            in: changedVoice
        ) == nil)
    }

    @Test func protectedTranslationsDoNotCrossChangedDocumentLanguages() {
        let stored = [
            LyricLine(
                timestamp: 1,
                text: "Shared text",
                isSynchronized: true,
                metadataLines: ["[la:fr]"],
                manualTranslation: .init(
                    text: "Local translation",
                    languageCode: "en",
                    source: .localEditor
                )
            ),
        ]
        let authoritative = [
            LyricLine(
                timestamp: 1,
                text: "Shared text",
                isSynchronized: true,
                metadataLines: ["[la:de]"]
            ),
        ]

        #expect(LyricManualTranslationPolicy.preservingStoredTranslations(
            from: stored,
            in: authoritative
        ) == nil)
    }

    @Test func knownSameScriptPairsRebuildAlongsideAlreadyParsedPairs() throws {
        let stored = [
            LyricLine(
                timestamp: 1,
                text: "你好",
                isSynchronized: true,
                manualTranslation: .init(text: "Hello", source: .bilingualLRC)
            ),
            LyricLine(
                timestamp: 2,
                text: "Good night",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Bonne nuit",
                    languageCode: "fr",
                    source: .bilingualLRC
                )
            ),
        ]
        let authoritative = [
            LyricLine(
                timestamp: 1,
                text: "你好",
                isSynchronized: true,
                manualTranslation: .init(text: "Hello", source: .bilingualLRC)
            ),
            LyricLine(timestamp: 2.1, text: "Good night", isSynchronized: true),
            LyricLine(timestamp: 2.1, text: "Bonne nuit", isSynchronized: true),
        ]

        let merged = try #require(
            LyricManualTranslationPolicy.preservingStoredTranslations(
                from: stored,
                in: authoritative
            )
        )
        #expect(merged.count == 2)
        #expect(merged[0].manualTranslation?.text == "Hello")
        #expect(merged[1].manualTranslation?.text == "Bonne nuit")
    }

    @Test func changedSameTimestampRowIsNotConsumedAsAKnownTranslation() throws {
        let stored = [
            LyricLine(
                timestamp: 1,
                text: "Lead line",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Known translation",
                    languageCode: "en",
                    source: .bilingualLRC
                )
            ),
        ]
        let authoritative = [
            LyricLine(timestamp: 1, text: "Lead line", isSynchronized: true),
            LyricLine(timestamp: 1, text: "New duet line", isSynchronized: true),
        ]

        let merged = try #require(
            LyricManualTranslationPolicy.preservingStoredTranslations(
                from: stored,
                in: authoritative
            )
        )
        #expect(merged.map(\.text) == ["Lead line", "New duet line"])
        #expect(merged.allSatisfy { $0.manualTranslation == nil })
    }

    @Test func storedTranslationMergePreservesSourceBilingualTextAndPrefersEmbeddedFields() {
        let bilingual = LyricManualTranslation(
            text: "Source translation",
            source: .bilingualLRC
        )
        let source = [
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: bilingual
            ),
        ]
        let noStoredTranslation = [
            LyricLine(timestamp: 1, text: "Original", isSynchronized: true),
        ]
        #expect(LyricManualTranslationPolicy.restoringStoredTranslations(
            from: noStoredTranslation,
            into: source
        )?.first?.manualTranslation == bilingual)

        let embedded = LyricManualTranslation(
            text: "Embedded translation",
            languageCode: "fr",
            source: .embeddedField
        )
        let storedEmbedded = [
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: embedded
            ),
        ]
        let merged = LyricManualTranslationPolicy.restoringStoredTranslations(
            from: storedEmbedded,
            into: source
        )
        #expect(merged?.first?.manualTranslation == embedded)
        #expect(merged?.first?.alternateManualTranslations == [bilingual])
    }

    @Test func storedTranslationMergeRecursesIntoProvenBackgroundRows() {
        let backgroundTranslation = LyricManualTranslation(
            text: "Backing translation",
            languageCode: "en",
            source: .embeddedField
        )
        let stored = [
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
                        manualTranslation: backgroundTranslation
                    ),
                ]
            ),
        ]
        let authoritative = [
            LyricLine(
                timestamp: 1,
                text: "Lead",
                isSynchronized: true,
                background: [
                    LyricLine(
                        timestamp: 1.2,
                        text: "Backing",
                        isSynchronized: true,
                        voice: .secondary
                    ),
                ]
            ),
        ]

        let restored = LyricManualTranslationPolicy.restoringStoredTranslations(
            from: stored,
            into: authoritative
        )

        #expect(restored?.first?.background?.first?.manualTranslation == backgroundTranslation)
    }

    @Test func bilingualLRCPersistenceRejectsAmbiguousStructuredRows() {
        let translation = LyricManualTranslation(
            text: "Translation",
            source: .embeddedField
        )
        #expect(LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Ordinary line",
                isSynchronized: true,
                manualTranslation: translation
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Word-level line",
                isSynchronized: true,
                syllables: [.init(text: "Word", start: 1, end: 2)],
                manualTranslation: translation
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Meet at [02:25] by the bridge",
                    source: .embeddedField
                )
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Keep <02:25> as text",
                    source: .embeddedField
                )
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 0,
                text: "Plain line",
                isSynchronized: false,
                manualTranslation: translation
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Several translations",
                isSynchronized: true,
                manualTranslation: translation,
                alternateManualTranslations: [
                    .init(text: "Other language", languageCode: "de", source: .embeddedField),
                ]
            ),
        ]))
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC([
            LyricLine(
                timestamp: 1,
                text: "Ordinary line",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "First translation line\nSecond translation line",
                    source: .embeddedField
                )
            ),
        ]))
    }

    @Test func emptyOrPartialAuthoredLyricsDoNotClaimCompleteCoverage() {
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(in: []))
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(in: [
            LyricLine(timestamp: 0, text: "Unsupported language", isSynchronized: false),
        ]))

        let partial = [
            LyricLine(
                timestamp: 0,
                text: "First",
                isSynchronized: false,
                manualTranslation: LyricManualTranslation(
                    text: "第一",
                    languageCode: "zh",
                    source: .embeddedField
                )
            ),
            LyricLine(timestamp: 0, text: "Second", isSynchronized: false),
        ]
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(in: partial))
        #expect(LyricTranslationGroupingPolicy.needsTranslation(
            detectedSourceLanguageCode: nil,
            targetLanguageCode: "zh"
        ))
    }
}

/// refs #105 —— 逐字原文与整行译文共用同一时间戳时的配对。
@Suite("Bilingual pairing with word-level source lines")
struct LyricBilingualWordLevelPairingTests {

    /// Lyrico 之类的工具会把逐字原文和整行译文写成同一个时间戳的相邻两行。
    /// 原文因为带音节曾被排除在配对之外，译文于是留成独立一行，高亮落在译文上。
    private let bilingualWordLevelLRC = """
    [00:12.00]<00:12.00>Hello <00:12.50>world
    [00:12.00]你好世界
    [00:15.00]<00:15.00>Second <00:15.40>line
    [00:15.00]第二行歌词
    [00:18.00]<00:18.00>Third <00:18.30>one
    [00:18.00]第三行歌词
    """

    @Test("译文并入原文，而不是留成独立一行")
    func mergesTranslationIntoWordLevelSource() {
        let lines = LyricsContentParser.parse(bilingualWordLevelLRC)

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.manualTranslation != nil })
        #expect(lines[0].text == "Hello world")
        #expect(lines[0].manualTranslation?.text == "你好世界")
        #expect(lines[0].manualTranslation?.source == .bilingualLRC)
        #expect(lines[1].manualTranslation?.text == "第二行歌词")
        #expect(lines[2].manualTranslation?.text == "第三行歌词")
    }

    /// 配对后逐字时间轴必须原样保留，否则原文的扫光和点按依然是坏的。
    @Test("逐字时间轴在配对后完整保留")
    func keepsSyllableTimingAfterPairing() {
        let lines = LyricsContentParser.parse(bilingualWordLevelLRC)

        #expect(lines.allSatisfy { $0.syllables?.isEmpty == false })
        #expect(lines[0].syllables?.count == 2)
        #expect(lines[0].syllables?.first?.text.trimmingCharacters(in: .whitespaces) == "Hello")
        #expect(lines[0].isWordLevel)
        // 高亮不再落到译文上：每个时间戳只剩一行，且它就是原文。
        #expect(Set(lines.map(\.timestamp)).count == lines.count)
    }

    /// 两行都带音节时更像双声部或对唱，吞掉一行会真的丢内容。
    @Test("两行都是逐字时不做配对")
    func doesNotPairTwoWordLevelLines() {
        let lines = LyricsContentParser.parse("""
        [00:12.00]<00:12.00>Hello <00:12.50>world
        [00:12.00]<00:12.00>你好 <00:12.50>世界
        [00:15.00]<00:15.00>Second <00:15.40>line
        [00:15.00]<00:15.00>第二 <00:15.40>行
        """)

        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
    }

    /// 纯行级的双语 LRC 是既有能力，放宽原文侧不能把它弄坏。
    @Test("纯行级双语仍然照常配对")
    func stillPairsPlainBilingualLines() {
        let lines = LyricsContentParser.parse("""
        [00:12.00]Hello world
        [00:12.00]你好世界
        [00:15.00]Second line
        [00:15.00]第二行歌词
        [00:18.00]Third one
        [00:18.00]第三行歌词
        """)

        #expect(lines.count == 3)
        #expect(lines[0].manualTranslation?.text == "你好世界")
        #expect(lines.allSatisfy { $0.syllables?.isEmpty != false })
    }

    /// 单语逐字歌词不该因为放宽判定就被两两吞并。
    @Test("单语逐字歌词不受影响")
    func leavesMonolingualWordLevelLyricsAlone() {
        let lines = LyricsContentParser.parse("""
        [00:12.00]<00:12.00>Hello <00:12.50>world
        [00:15.00]<00:15.00>Second <00:15.40>line
        [00:18.00]<00:18.00>Third <00:18.30>one
        [00:21.00]<00:21.00>Fourth <00:21.30>line
        """)

        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
        #expect(lines.allSatisfy { $0.syllables?.isEmpty == false })
    }
}

/// refs #105 —— 同一个时间戳上不止两行，以及整篇里只有几句外语带译文的文档。
@Suite("Bilingual pairing across mixed lyric documents")
struct LyricBilingualMixedDocumentPairingTests {

    /// 中文歌里夹着几句外语，外语那几句才带译文。此前整篇的比例达不到门槛，
    /// 这几句的译文于是留成独立行，外语原文一直高亮不了。
    @Test("中文歌里少量外语句也能配对")
    func pairsSparseForeignLinesInsideChineseLyrics() {
        let lines = LyricsContentParser.parse("""
        [00:10.00]第一句中文歌词
        [00:13.00]第二句中文歌词
        [00:16.00]Sometimes I feel alone
        [00:16.00]有时候我觉得孤单
        [00:19.00]第三句中文歌词
        [00:22.00]Nothing left at all
        [00:22.00]什么都没有剩下
        [00:25.00]第四句中文歌词
        [00:28.00]第五句中文歌词
        """)

        #expect(lines.count == 7)
        #expect(lines.map(\.text) == [
            "第一句中文歌词",
            "第二句中文歌词",
            "Sometimes I feel alone",
            "第三句中文歌词",
            "Nothing left at all",
            "第四句中文歌词",
            "第五句中文歌词",
        ])
        #expect(lines[2].manualTranslation?.text == "有时候我觉得孤单")
        #expect(lines[4].manualTranslation?.text == "什么都没有剩下")
        // 中文行本身没有译文，不该被相邻句连坐。
        #expect(lines[0].manualTranslation == nil)
        #expect(lines[3].manualTranslation == nil)
        // 每个时间戳只剩一行，高亮不会再落到译文上。
        #expect(Set(lines.map(\.timestamp)).count == lines.count)
    }

    private let trilingualLRC = """
    [00:12.00]<00:12.00>君の <00:12.50>声が
    [00:12.00]kimi no koe ga
    [00:12.00]你的声音
    [00:15.00]<00:15.00>遠くに <00:15.40>消える
    [00:15.00]tooku ni kieru
    [00:15.00]消失在远方
    [00:18.00]<00:18.00>夜の <00:18.30>果てで
    [00:18.00]yoru no hate de
    [00:18.00]在夜的尽头
    """

    /// 原文、注音、译文共用一个时间戳时，原文此前完全不参与配对，
    /// 高亮落在最后那条译文上。
    @Test("原文 + 注音 + 译文三行归到同一句")
    func pairsSourceWithBothPronunciationAndTranslation() {
        let lines = LyricsContentParser.parse(trilingualLRC)

        #expect(lines.count == 3)
        #expect(lines[0].text == "君の 声が")
        #expect(lines[0].isWordLevel)
        // 文件里的先后顺序就是阅读顺序：注音写在译文前面就先跟着原文。
        #expect(lines[0].manualTranslation?.text == "kimi no koe ga")
        #expect(lines[0].alternateManualTranslations.map(\.text) == ["你的声音"])
        #expect(lines[1].manualTranslation?.text == "tooku ni kieru")
        #expect(lines[1].alternateManualTranslations.map(\.text) == ["消失在远方"])
        #expect(lines[2].alternateManualTranslations.map(\.text) == ["在夜的尽头"])
        #expect(lines.allSatisfy {
            $0.allManualTranslations.allSatisfy { $0.source == .bilingualLRC }
        })
        #expect(Set(lines.map(\.timestamp)).count == lines.count)
    }

    /// 三行配对后仍要能原样写回。只落首选译文的话，一次回写就会把注音吃掉。
    @Test("三行结构序列化后可以原样读回")
    func roundTripsTrilingualRowsThroughSerialization() {
        let lines = LyricsContentParser.parse(trilingualLRC)
        let serialized = LyricsContentParser.serialize(lines)

        #expect(serialized.components(separatedBy: "\n").count == 9)
        #expect(serialized.contains("[00:12.000]kimi no koe ga"))
        #expect(serialized.contains("[00:12.000]你的声音"))

        let reparsed = LyricsContentParser.parse(serialized)
        #expect(reparsed.count == 3)
        #expect(reparsed.map(\.text) == lines.map(\.text))
        #expect(reparsed.map { $0.manualTranslation?.text } == lines.map { $0.manualTranslation?.text })
        #expect(reparsed.map { $0.alternateManualTranslations.map(\.text) }
            == lines.map { $0.alternateManualTranslations.map(\.text) })
        // 逐字原文的双语文档依旧走本地结构化存储 —— 双语 LRC 不承诺能还原音节。
        #expect(!LyricManualTranslationPolicy.canPersistAsBilingualLRC(reparsed))
    }

    /// 纯行级的三行文档可以整体写回双语 LRC：注音和译文按原顺序落在同一时间戳上。
    @Test("纯行级三行结构可以写回双语 LRC")
    func persistsPlainTrilingualRowsAsBilingualLRC() {
        let lines = LyricsContentParser.parse("""
        [00:12.00]사랑해 그대여
        [00:12.00]saranghae geudaeyeo
        [00:12.00]我爱你 亲爱的
        [00:15.00]바람이 스쳐가
        [00:15.00]barami seuchyeoga
        [00:15.00]风轻轻吹过
        [00:18.00]밤이 깊어가
        [00:18.00]bami gipeoga
        [00:18.00]夜色渐深
        """)

        #expect(lines.count == 3)
        #expect(lines[0].text == "사랑해 그대여")
        #expect(lines[0].manualTranslation?.text == "saranghae geudaeyeo")
        #expect(lines[0].alternateManualTranslations.map(\.text) == ["我爱你 亲爱的"])
        #expect(LyricManualTranslationPolicy.canPersistAsBilingualLRC(lines))

        let reparsed = LyricsContentParser.parse(LyricsContentParser.serialize(lines))
        #expect(reparsed.map { $0.allManualTranslations.map(\.text) }
            == lines.map { $0.allManualTranslations.map(\.text) })
    }

    /// 三行里有两行带逐字时间轴，更像多声部叠唱，吞掉任何一行都会丢内容。
    @Test("三行里出现第二条逐字行时不配对")
    func doesNotAbsorbASecondWordLevelRow() {
        let lines = LyricsContentParser.parse("""
        [00:12.00]<00:12.00>君の <00:12.50>声が
        [00:12.00]<00:12.00>kimi no <00:12.50>koe ga
        [00:12.00]你的声音
        [00:15.00]<00:15.00>遠くに <00:15.40>消える
        [00:15.00]<00:15.00>tooku ni <00:15.40>kieru
        [00:15.00]消失在远方
        """)

        #expect(lines.count == 6)
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
    }

    /// 同时间戳的重复行朝向对不上时仍然不猜：一半中译外、一半外译中，
    /// 更可能是对唱或排版错乱，配错了就是把一整句唱词吞掉。
    @Test("重复行朝向不一致时整篇放弃配对")
    func leavesInconsistentlyOrientedRepeatsAlone() {
        let lines = LyricsContentParser.parse("""
        [00:10.00]First english line
        [00:10.00]第一句中文
        [00:13.00]Second english line
        [00:13.00]第二句中文
        [00:16.00]第三句中文
        [00:16.00]Third english line
        [00:19.00]第四句中文
        [00:19.00]Fourth english line
        """)

        #expect(lines.count == 8)
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
    }
}

/// refs #152 —— 原文本身就是混合语（韩语夹英文、日文夹英文、中文夹英文）的
/// 双语文档，以及整篇只出现一次、或者根本分不出文字构成的那几簇。
@Suite("Bilingual pairing with mixed-script source lines")
struct LyricMixedScriptSourcePairingTests {

    /// K-pop 歌词里夹英文单词是常态。此前原文必须有七成以上是同一种文字才
    /// 参与配对，「두고 봐 Babe」达不到，于是译文留成独立一行，高亮落在译文上，
    /// 原文一直不亮。
    @Test("韩语夹英文的原文也配对")
    func pairsKoreanSourceWithEmbeddedEnglish() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]nol bo nun nun bi chi
        [00:06.00]看着你的眼神
        [00:09.00]두고 봐 Babe
        [00:09.00]du go bwa Babe
        [00:09.00]走着瞧吧 宝贝
        [00:12.00]흐린 공간속에서
        [00:12.00]he lin gong gan so ge so
        [00:12.00]在模糊的空间里
        """)

        #expect(lines.count == 3)
        #expect(lines[1].text == "두고 봐 Babe")
        #expect(lines[1].manualTranslation?.text == "du go bwa Babe")
        #expect(lines[1].alternateManualTranslations.map(\.text) == ["走着瞧吧 宝贝"])
        // 每个时间戳只剩一行，高亮不会再落到注音或译文上。
        #expect(Set(lines.map(\.timestamp)).count == lines.count)
    }

    /// 英文单词多到超过原文本身时，原文此前会被判成拉丁文字，于是和它的注音
    /// 撞成同一种文字；这样的句子一多，整篇都不配对了。
    @Test("英文占多数的混合原文不会让整篇放弃配对")
    func pairsWhenEmbeddedEnglishOutnumbersTheSourceScript() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]줄게 내 galaxy
        [00:06.00]jul ge nae galaxy
        [00:06.00]把我的宇宙给你
        [00:09.00]내 맘 속 shooting star
        [00:09.00]nae mam sok shooting star
        [00:09.00]我心里的流星
        [00:12.00]흐린 공간속에서
        [00:12.00]he lin gong gan so ge so
        [00:12.00]在模糊的空间里
        """)

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.allManualTranslations.count == 2 })
        #expect(lines[0].text == "줄게 내 galaxy")
    }

    @Test("日文夹英文、中文夹英文同样配对")
    func pairsOtherMixedScriptSources() {
        let japanese = LyricsContentParser.parse("""
        [00:06.00]君の声が聞こえる
        [00:06.00]kimi no koe ga kikoeru
        [00:06.00]听见你的声音
        [00:09.00]夢の中の Wonderland
        [00:09.00]yume no naka no Wonderland
        [00:09.00]梦中的仙境
        [00:12.00]夜の果てで
        [00:12.00]yoru no hate de
        [00:12.00]在夜的尽头
        """)
        #expect(japanese.count == 3)
        #expect(japanese[1].text == "夢の中の Wonderland")
        #expect(japanese[1].allManualTranslations.count == 2)

        let chinese = LyricsContentParser.parse("""
        [00:06.00]我的心里只有你
        [00:06.00]My heart only has you
        [00:09.00]你是我的 baby
        [00:09.00]You are my baby
        [00:12.00]夜色渐渐深了
        [00:12.00]The night grows deep
        """)
        #expect(chinese.count == 3)
        #expect(chinese[1].text == "你是我的 baby")
        #expect(chinese[1].manualTranslation?.text == "You are my baby")
    }

    /// 结构一旦成立，分不出文字构成的那几簇也跟着走：一个字的感叹词两边都
    /// 太短，符号行和数字行根本没有字母。
    @Test("短感叹词与符号行跟着整篇结构")
    func adoptsRowsWithoutScriptEvidence() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]看着你的眼神
        [00:09.00]아
        [00:09.00]啊
        [00:12.00]1, 2, 3
        [00:12.00]一二三
        [00:15.00]흐린 공간속에서
        [00:15.00]在模糊的空间里
        [00:18.00]바람이 스쳐가
        [00:18.00]风轻轻吹过
        """)

        #expect(lines.count == 5)
        #expect(lines.map(\.text) == ["널 보는 눈빛이", "아", "1, 2, 3", "흐린 공간속에서", "바람이 스쳐가"])
        #expect(lines[1].manualTranslation?.text == "啊")
        #expect(lines[2].manualTranslation?.text == "一二三")
    }

    /// 整篇只有一句外语带译文时凑不出第二票。附属行用的正是整篇歌词的文字，
    /// 原文不是 —— 这就是一条译文，而不是另一个声部。
    @Test("整篇只出现一次的外语配译文也配对")
    func pairsASingleTranslatedCoupletInsideAMonolingualDocument() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]第一句中文歌词
        [00:09.00]第二句中文歌词
        [00:12.00]Sometimes I feel alone
        [00:12.00]有时候我觉得孤单
        [00:15.00]第三句中文歌词
        [00:18.00]第四句中文歌词
        """)

        #expect(lines.count == 5)
        #expect(lines[2].text == "Sometimes I feel alone")
        #expect(lines[2].manualTranslation?.text == "有时候我觉得孤单")
        #expect(Set(lines.map(\.timestamp)).count == lines.count)
    }

    @Test("收录范围之外的文字不再整篇失配")
    func pairsScriptsBeyondTheOriginalCoverage() {
        let greek = LyricsContentParser.parse("""
        [00:06.00]Θέλω να σε δω
        [00:06.00]我想见你
        [00:09.00]Είσαι η ζωή μου
        [00:09.00]你是我的生命
        [00:12.00]Μη φύγεις τώρα
        [00:12.00]现在别走
        """)
        #expect(greek.count == 3)
        #expect(greek[0].manualTranslation?.text == "我想见你")

        let tamil = LyricsContentParser.parse("""
        [00:06.00]என் காதல் நீ
        [00:06.00]你是我的爱
        [00:09.00]வானம் நீலமாய்
        [00:09.00]天空一片蓝
        [00:12.00]கனவு காண்கிறேன்
        [00:12.00]我在做梦
        """)
        #expect(tamil.count == 3)
        #expect(tamil[2].manualTranslation?.text == "我在做梦")
    }

    /// 行首的括号是和声或语气词，后面还接着正文时它就是普通的一句歌词。
    @Test("行首括号的和声不再当成注记")
    func treatsABracketedPrefixAsOrdinaryLyrics() {
        let lines = LyricsContentParser.parse("""
        [00:06.00](Hey) 두고 봐 Babe
        [00:06.00]走着瞧吧 宝贝
        [00:09.00]널 보는 눈빛이
        [00:09.00]看着你的眼神
        [00:12.00](Oh) 흐린 공간속에서
        [00:12.00]在模糊的空间里
        [00:15.00]바람이 스쳐가
        [00:15.00]风轻轻吹过
        """)

        #expect(lines.count == 4)
        #expect(lines[0].text == "(Hey) 두고 봐 Babe")
        #expect(lines[0].manualTranslation?.text == "走着瞧吧 宝贝")
    }

    /// 手抄的双语文件常把译文整句写进括号里。
    @Test("括号包住的译文也能并进原文")
    func pairsABracketedTranslationRow() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]（看着你的眼神）
        [00:09.00]흐린 공간속에서
        [00:09.00]（在模糊的空间里）
        [00:12.00]바람이 스쳐가
        [00:12.00]（风轻轻吹过）
        """)

        #expect(lines.count == 3)
        #expect(lines[0].manualTranslation?.text == "（看着你的眼神）")
    }

    /// 整行都在括号里的注记不能当原文：它不是被唱出来的那一句。
    @Test("整行括号的注记不当原文")
    func neverTreatsAFullyBracketedRowAsTheSource() {
        let lines = LyricsContentParser.parse("""
        [00:06.00](Guitar solo)
        [00:06.00]（吉他独奏）
        [00:09.00]널 보는 눈빛이
        [00:09.00]看着你的眼神
        [00:12.00]흐린 공간속에서
        [00:12.00]在模糊的空间里
        """)

        #expect(lines.count == 4)
        #expect(lines[0].text == "(Guitar solo)")
        #expect(lines[0].manualTranslation == nil)
        #expect(lines[1].text == "（吉他独奏）")
        #expect(lines[2].manualTranslation?.text == "看着你的眼神")
    }

    /// 「原文 + 注音 + 中译 + 英译」四行共用一个时间戳的文件（动漫歌常见）。
    @Test("四行结构也归到同一句并能写回")
    func pairsFourRowStructures() {
        let source = """
        [00:06.00]君の声が聞こえる
        [00:06.00]kimi no koe ga kikoeru
        [00:06.00]听见你的声音
        [00:06.00]I can hear your voice
        [00:09.00]夜の果てで
        [00:09.00]yoru no hate de
        [00:09.00]在夜的尽头
        [00:09.00]At the end of the night
        [00:12.00]遠くに消える
        [00:12.00]tooku ni kieru
        [00:12.00]消失在远方
        [00:12.00]Fading far away
        """
        let lines = LyricsContentParser.parse(source)

        #expect(lines.count == 3)
        #expect(lines[0].text == "君の声が聞こえる")
        #expect(lines[0].allManualTranslations.map(\.text) == [
            "kimi no koe ga kikoeru",
            "听见你的声音",
            "I can hear your voice",
        ])

        // 一次回写不能把第三、第四行吃掉。
        let reparsed = LyricsContentParser.parse(LyricsContentParser.serialize(lines))
        #expect(reparsed.map { $0.allManualTranslations.map(\.text) }
            == lines.map { $0.allManualTranslations.map(\.text) })
    }

    /// 韩语歌里夹的英文句不需要注音，于是整篇是三行、它只有两行。此前这一簇
    /// 凑不出第二票，译文便留成独立一行，高亮落在译文上。
    @Test("整篇三行结构里少一条注音的那句也配对")
    func pairsAShorterClusterInsideAProvenStructure() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]nol bo nun nun bi chi
        [00:06.00]看着你的眼神
        [00:09.00]Sometimes I feel alone
        [00:09.00]有时候我觉得孤单
        [00:12.00]흐린 공간속에서
        [00:12.00]he lin gong gan so ge so
        [00:12.00]在模糊的空间里
        [00:15.00]바람이 스쳐가
        [00:15.00]ba ra mi seu chyeo ga
        [00:15.00]风轻轻吹过
        """)

        #expect(lines.count == 4)
        #expect(lines[1].text == "Sometimes I feel alone")
        #expect(lines[1].manualTranslation?.text == "有时候我觉得孤单")
        #expect(lines[1].alternateManualTranslations.isEmpty)
        #expect(lines[0].allManualTranslations.count == 2)
    }

    /// 原文是英文、里面夹了两个汉字，而译文正好也是汉字。两行的文字构成撞在
    /// 一起，但原文并不是整行汉字 —— 这不是双声部，仍然要按整篇的结构配对。
    @Test("原文夹的字与译文同种文字时仍跟着结构")
    func pairsWhenEmbeddedCharactersMatchTheTranslationScript() {
        let lines = LyricsContentParser.parse("""
        [00:06.00]I love 上海 at night
        [00:06.00]我爱夜晚的上海
        [00:09.00]Tell me what you need
        [00:09.00]告诉我你要什么
        [00:12.00]Nothing left at all
        [00:12.00]什么都没有剩下
        """)

        #expect(lines.count == 3)
        #expect(lines[0].text == "I love 上海 at night")
        #expect(lines[0].manualTranslation?.text == "我爱夜晚的上海")
    }

    /// 放宽文字判定之后，同一句唱两遍、以及两个声部各唱一句，仍然不能配对。
    @Test("重复行与双声部仍然不配对")
    func stillRefusesRepeatsAndDuets() {
        let repeated = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]널 보는 눈빛이
        [00:09.00]흐린 공간속에서
        [00:09.00]흐린 공간속에서
        [00:12.00]바람이 스쳐가
        [00:12.00]바람이 스쳐가
        """)
        #expect(repeated.count == 6)
        #expect(repeated.allSatisfy { $0.manualTranslation == nil })

        let duet = LyricsContentParser.parse("""
        [00:06.00]널 보는 눈빛이
        [00:06.00]바람이 스쳐가
        [00:09.00]흐린 공간속에서
        [00:09.00]밤이 깊어가
        [00:12.00]사랑해 그대여
        [00:12.00]두고 봐 그대여
        """)
        #expect(duet.count == 6)
        #expect(duet.allSatisfy { $0.manualTranslation == nil })
    }
}
