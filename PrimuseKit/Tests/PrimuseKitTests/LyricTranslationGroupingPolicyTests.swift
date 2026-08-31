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
