import Foundation
import Testing
@testable import PrimuseKit

struct LyricRomanizationPolicyTests {
    private static func line(
        _ id: String,
        _ text: String,
        at timestamp: TimeInterval = 1,
        romanization: String? = nil,
        languageCode: String? = nil,
        syllables: [LyricSyllable]? = nil,
        background: [LyricLine]? = nil
    ) -> LyricLine {
        LyricLine(
            id: id,
            timestamp: timestamp,
            text: text,
            syllables: syllables,
            background: background,
            languageCode: languageCode,
            romanization: romanization
        )
    }

    // MARK: 文字判定

    @Test func scriptCountsSeparateKanaHanHangulAndOthers() {
        let japanese = LyricRomanizationScriptPolicy.counts(in: "君の名前 Love")
        #expect(japanese.kana == 1)
        #expect(japanese.han == 3)
        #expect(japanese.latin == 4)
        #expect(LyricRomanizationScriptPolicy.counts(in: "사랑해").hangul == 3)
        #expect(LyricRomanizationScriptPolicy.counts(in: "Привет").dominantOtherScript == .cyrillic)
        #expect(LyricRomanizationScriptPolicy.counts(in: "สวัสดี").dominantOtherScript == .thai)
        #expect(!LyricRomanizationScriptPolicy.needsRomanization("Hello, world! 123"))
        #expect(!LyricRomanizationScriptPolicy.needsRomanization("Café déjà vu"))
        #expect(LyricRomanizationScriptPolicy.needsRomanization("ありがとう"))
    }

    @Test(arguments: [
        ("Привет мир", "ru"),
        ("Привіт, як справи", "uk"),
        ("Добры дзень, ўсё", "be"),
        ("Љубав је", "sr"),
        ("Γειά σου", "el"),
        ("مرحبا", "ar"),
        ("سلام چطوری", "fa"),
        ("שלום", "he"),
        ("नमस्ते", "hi"),
        ("வணக்கம்", "ta"),
    ])
    func otherScriptLanguageCodes(_ text: String, _ expected: String) throws {
        let script = try #require(LyricRomanizationScriptPolicy.counts(in: text).dominantOtherScript)
        #expect(LyricRomanizationScriptPolicy.languageCode(for: script, text: text) == expected)
    }

    // MARK: 规划

    @Test func japaneseDocumentReadsKanjiOnlyLinesAsJapanese() {
        let lines = [
            Self.line("a", "君の名は", at: 1),
            Self.line("b", "永遠", at: 2),
            Self.line("c", "Oh baby", at: 3),
        ]
        let plan = LyricRomanizationPlanner.plan(
            lines: lines,
            generates: true,
            enabledLanguages: Set(LyricRomanizationLanguage.allCases)
        )
        #expect(plan.groups.count == 1)
        #expect(plan.groups.first?.language == .japanese)
        #expect(plan.groups.first?.languageCode == "ja")
        #expect(plan.groups.first?.candidates.map(\.lineID) == ["a", "b"])
    }

    @Test func chineseKoreanAndOtherScriptsFormSeparateGroups() {
        let lines = [
            Self.line("zh", "我爱你", at: 1),
            Self.line("ko", "사랑해", at: 2),
            Self.line("ru", "Я люблю тебя", at: 3),
            Self.line("zh2", "我爱你", at: 4),
        ]
        let plan = LyricRomanizationPlanner.plan(
            lines: lines,
            generates: true,
            enabledLanguages: Set(LyricRomanizationLanguage.allCases)
        )
        #expect(plan.groups.map(\.languageCode) == ["zh", "ko", "ru"])
        #expect(plan.groups[0].candidates.map(\.lineID) == ["zh", "zh2"])
        #expect(plan.groups[0].uniqueTexts == ["我爱你"])
    }

    @Test func declaredTraditionalChineseKeepsItsScript() {
        let lines = [Self.line("a", "我愛你", languageCode: "zh-Hant")]
        let plan = LyricRomanizationPlanner.plan(lines: lines, generates: true, enabledLanguages: [.chinese])
        #expect(plan.groups.first?.languageCode == "zh-Hant")
    }

    @Test func skipsAuthoredRomanizationDisabledLanguagesAndCredits() {
        let lines = [
            Self.line("credit", "作詞：秋元康", at: 0),
            Self.line("a", "君の名は", at: 1, romanization: "kimi no na wa"),
            Self.line("b", "夢を見た", at: 2),
            Self.line("k", "사랑해", at: 3),
        ]
        let plan = LyricRomanizationPlanner.plan(lines: lines, generates: true, enabledLanguages: [.japanese])
        #expect(plan.groups.count == 1)
        #expect(plan.groups.first?.candidates.map(\.lineID) == ["b"])

        let none = LyricRomanizationPlanner.plan(lines: lines, generates: false, enabledLanguages: [.japanese])
        #expect(none.groups.isEmpty)
    }

    @Test func backgroundVocalsAreRomanizedToo() {
        let lines = [
            Self.line("a", "君の名は", at: 1, background: [Self.line("bg", "ねえ", at: 1.5)]),
        ]
        let plan = LyricRomanizationPlanner.plan(lines: lines, generates: true, enabledLanguages: [.japanese])
        #expect(Set(plan.groups.flatMap(\.candidates).map(\.lineID)) == ["a", "bg"])
    }

    // MARK: 默认开哪些语言

    @Test func defaultsSkipThePreferredLanguages() {
        let chineseUser = ["zh-Hans-CN", "en-US"]
        #expect(!LyricRomanizationLanguagePolicy.isEnabledByDefault(.chinese, preferredLanguages: chineseUser))
        #expect(LyricRomanizationLanguagePolicy.isEnabledByDefault(.japanese, preferredLanguages: chineseUser))
        #expect(LyricRomanizationLanguagePolicy.isEnabledByDefault(.korean, preferredLanguages: chineseUser))
        #expect(LyricRomanizationLanguagePolicy.isEnabledByDefault(.other, preferredLanguages: chineseUser))

        let japaneseUser = ["ja-JP"]
        #expect(!LyricRomanizationLanguagePolicy.isEnabledByDefault(.japanese, preferredLanguages: japaneseUser))
        #expect(LyricRomanizationLanguagePolicy.isEnabledByDefault(.chinese, preferredLanguages: japaneseUser))

        let russianUser = ["ru-RU"]
        #expect(!LyricRomanizationLanguagePolicy.isEnabledByDefault(.other, preferredLanguages: russianUser))

        let enabled = LyricRomanizationLanguagePolicy.enabledLanguages(
            overrides: ["chinese": true, "japanese": false],
            preferredLanguages: chineseUser
        )
        #expect(enabled == [.chinese, .korean, .other])
    }

    @Test func googleCloudOnlyOutsideMainlandChinaAndUnknownRegions() {
        #expect(LyricRomanizationMethodPolicy.offersGoogleCloud(region: .international))
        #expect(!LyricRomanizationMethodPolicy.offersGoogleCloud(region: .mainlandChina))
        #expect(!LyricRomanizationMethodPolicy.offersGoogleCloud(region: .unknown))
        #expect(LyricRomanizationMethodPolicy.effectiveMethod(
            .googleCloud, region: .unknown, exposesIntelligentServices: true
        ) == .local)
        #expect(LyricRomanizationMethodPolicy.effectiveMethod(
            .intelligent, region: .international, exposesIntelligentServices: false
        ) == .local)
        #expect(LyricRomanizationMethodPolicy.effectiveMethod(
            .googleCloud, region: .international, exposesIntelligentServices: false
        ) == .googleCloud)
    }

    // MARK: 显示

    @Test func belowOriginalAddsGeneratedRomanizationButKeepsAuthoredFirst() {
        let lines = [
            Self.line("a", "君の名は", romanization: "kimi no na wa"),
            Self.line("b", "夢を見た"),
        ]
        let overlay = LyricRomanizationOverlay(generatedTextByLineID: ["a": "generated", "b": "yume o mita"])
        let display = LyricRomanizationDisplayPolicy.displayLines(lines, overlay: overlay, mode: .belowOriginal)
        #expect(display[0].romanization == "kimi no na wa")
        #expect(display[1].romanization == "yume o mita")
        #expect(display[1].text == "夢を見た")
        #expect(display.map(\.id) == ["a", "b"])
        #expect(LyricCompanionTextPolicy.texts(for: display[1], translatedText: "I had a dream")
            == ["yume o mita", "I had a dream"])
    }

    @Test func romanizationOnlyReplacesTextAndDropsWordTiming() {
        let syllables = [
            LyricSyllable(text: "夢", start: 1, end: 1.5),
            LyricSyllable(text: "を見た", start: 1.5, end: 3),
        ]
        let lines = [
            Self.line("a", "夢を見た", syllables: syllables),
            Self.line("b", "Oh baby"),
        ]
        let overlay = LyricRomanizationOverlay(generatedTextByLineID: ["a": "yume o mita"])
        let display = LyricRomanizationDisplayPolicy.displayLines(lines, overlay: overlay, mode: .romanizationOnly)
        #expect(display[0].text == "yume o mita")
        #expect(display[0].syllables == nil)
        #expect(!display[0].isWordLevel)
        #expect(display[0].endTime == 3)
        #expect(display[0].timestamp == lines[0].timestamp)
        #expect(display[0].romanization == nil)
        #expect(display[1] == lines[1])
    }

    @Test func hiddenRemovesAuthoredRomanization() {
        let lines = [Self.line("a", "君の名は", romanization: "kimi no na wa")]
        let display = LyricRomanizationDisplayPolicy.displayLines(lines, overlay: .empty, mode: .hidden)
        #expect(display[0].romanization == nil)
        #expect(LyricCompanionTextPolicy.texts(for: display[0], translatedText: nil).isEmpty)
    }

    @Test func untouchedLyricsComeBackAsIs() {
        let lines = [Self.line("a", "Hello")]
        #expect(LyricRomanizationDisplayPolicy.displayLines(lines, overlay: .empty, mode: .belowOriginal) == lines)
        #expect(LyricRomanizationDisplayPolicy.displayLines(lines, overlay: .empty, mode: .hidden) == lines)
        #expect(LyricRomanizationDisplayPolicy.displayLines(lines, overlay: .empty, mode: .romanizationOnly) == lines)
    }

    @Test func bilingualReadingRowsCountAsAuthoredRomanization() {
        let reading = LyricManualTranslation(id: "r", text: "kimi no na wa", source: .bilingualLRC)
        let translation = LyricManualTranslation(id: "t", text: "Your name", source: .bilingualLRC)
        var source = Self.line("a", "君の名は")
        source.manualTranslation = reading
        source.alternateManualTranslations = [translation]
        let overlay = LyricRomanizationOverlay(readingTranslationIDs: ["r"])

        let only = LyricRomanizationDisplayPolicy.row(
            for: source,
            generatedRomanization: nil,
            mode: .romanizationOnly,
            readingTranslationIDs: overlay.readingTranslationIDs
        )
        #expect(only.text == "kimi no na wa")
        #expect(only.showsRomanizationAsText)
        #expect(only.companions == ["Your name"])

        let hidden = LyricRomanizationDisplayPolicy.row(
            for: source,
            generatedRomanization: nil,
            mode: .hidden,
            readingTranslationIDs: overlay.readingTranslationIDs
        )
        #expect(hidden.text == "君の名は")
        #expect(hidden.companions == ["Your name"])

        #expect(LyricRomanizationPlanner.hasAuthoredRomanization(source, readingIDs: ["r"]))
    }

    @Test func rowPresentationForAPreviewLine() {
        let source = Self.line("a", "사랑해")
        let below = LyricRomanizationDisplayPolicy.row(
            for: source,
            generatedRomanization: "saranghae",
            mode: .belowOriginal,
            translatedText: "I love you"
        )
        #expect(below.text == "사랑해")
        #expect(!below.showsRomanizationAsText)
        #expect(below.companions == ["saranghae", "I love you"])

        let only = LyricRomanizationDisplayPolicy.row(
            for: source,
            generatedRomanization: "saranghae",
            mode: .romanizationOnly,
            translatedText: "I love you"
        )
        #expect(only.text == "saranghae")
        #expect(only.companions == ["I love you"])

        let missing = LyricRomanizationDisplayPolicy.row(for: source, generatedRomanization: nil, mode: .romanizationOnly)
        #expect(missing.text == "사랑해")
        #expect(!missing.showsRomanizationAsText)
    }

    @Test func backgroundLinesFollowTheMode() {
        let lines = [Self.line("a", "君の名は", background: [Self.line("bg", "ねえ", at: 1.5)])]
        let overlay = LyricRomanizationOverlay(generatedTextByLineID: ["a": "kimi no na wa", "bg": "nee"])
        let only = LyricRomanizationDisplayPolicy.displayLines(lines, overlay: overlay, mode: .romanizationOnly)
        #expect(only[0].background?.first?.text == "nee")
        let below = LyricRomanizationDisplayPolicy.displayLines(lines, overlay: overlay, mode: .belowOriginal)
        #expect(below[0].background?.first?.romanization == "nee")
    }

    @Test func decisionPrefersAuthoredRomanizationAndHonorsTheMode() {
        let below = LyricRomanizationDisplayPolicy.decision(authored: " kimi ", generated: "gen", mode: .belowOriginal)
        #expect(below.companion == "kimi")
        #expect(below.replacementText == nil)
        let only = LyricRomanizationDisplayPolicy.decision(authored: "", generated: "gen", mode: .romanizationOnly)
        #expect(only.replacementText == "gen")
        #expect(only.companion == nil)
        let hidden = LyricRomanizationDisplayPolicy.decision(authored: "kimi", generated: "gen", mode: .hidden)
        #expect(hidden == .init(replacementText: nil, companion: nil))
        let none = LyricRomanizationDisplayPolicy.decision(authored: nil, generated: nil, mode: .romanizationOnly)
        #expect(none.replacementText == nil)
    }

    // MARK: 缓存键

    @Test func cacheKeyChangesWithEngineLanguageAndContent() {
        let base = LyricRomanizationCacheKey(engineID: "local", engineVersion: "1", languageCode: "ja", texts: ["君", "夢"])
        #expect(base == LyricRomanizationCacheKey(engineID: "local", engineVersion: "1", languageCode: "ja", texts: ["君", "夢"]))
        #expect(base.contentFingerprint.count == 32)
        #expect(base.storageName.count == 32)
        #expect(base != LyricRomanizationCacheKey(engineID: "google", engineVersion: "1", languageCode: "ja", texts: ["君", "夢"]))
        #expect(base != LyricRomanizationCacheKey(engineID: "local", engineVersion: "2", languageCode: "ja", texts: ["君", "夢"]))
        #expect(base != LyricRomanizationCacheKey(engineID: "local", engineVersion: "1", languageCode: "ko", texts: ["君", "夢"]))
        #expect(base.contentFingerprint != LyricRomanizationCacheKey.fingerprint(of: ["君夢"]))
        #expect(base.contentFingerprint != LyricRomanizationCacheKey.fingerprint(of: ["夢", "君"]))
    }

    // MARK: 日文、中文拼装

    @Test func japaneseAssemblerFixesParticlesAndPunctuation() {
        let pieces: [JapaneseRomajiAssembler.Piece] = [
            .word(surface: "私", reading: "watashi"),
            .word(surface: "は", reading: "ha"),
            .word(surface: "君", reading: "kimi"),
            .word(surface: "へ", reading: "he"),
            .word(surface: "歌", reading: "uta"),
            .word(surface: "を", reading: "wo"),
            .gap("、"),
            .word(surface: "では", reading: "deha"),
            .gap("「"),
            .word(surface: "Love", reading: nil),
            .gap("」！"),
        ]
        #expect(JapaneseRomajiAssembler.assemble(pieces)
            == "watashi wa kimi e uta o, dewa \u{201C}Love\u{201D}!")
        #expect(JapaneseRomajiAssembler.assemble([.word(surface: "こんにちは", reading: "konnichiha")]) == "konnichiwa")
        #expect(JapaneseRomajiAssembler.assemble([.word(surface: "はい", reading: "hai")]) == "hai")
    }

    @Test func pinyinAssemblerJoinsSyllablesWithinWords() {
        let pieces: [PinyinWordAssembler.Piece] = [
            .word(surface: "我们", reading: "wǒ men"),
            .word(surface: "天安门", reading: "tiān ān mén"),
            .gap("，"),
            .word(surface: "好", reading: "hǎo"),
            .gap("。"),
        ]
        #expect(PinyinWordAssembler.assemble(pieces) == "wǒmen tiān'ānmén, hǎo.")
    }
}
