import Foundation
import Testing
@testable import PrimuseKit

@Suite("Embedded lyrics variants")
struct EmbeddedLyricsVariantPolicyTests {
    @Test func customFieldsKeepEveryRoleAndRepeatedValueInFileOrder() throws {
        let timed = "[00:01.00]灯舟靠岸"
        let duet = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"1s\">银帆归港</p></div></body></tt>"
        let fields = [
            ("SYNCED_LYRICS", timed), ("org.studio.private", duet), ("TIMED-LYRICS", timed),
            ("lyrics.translation:eng", "Lantern boats return"), ("lyrics.translation:eng", "A lantern skiff returns"),
            ("LYRICS_PINYIN:zh-Hans", "dēng zhōu kào àn"), ("COMMENT", "[00:02.00]雾灯掠过"),
            ("COMMENT", "Mix notes for the studio"), ("LYRICS_URL", "https://example.invalid/lyrics"),
            ("LYRICS_LANGUAGE", "zho"), ("LYRICIST", "编词者"), ("TITLE", "[00:01.00]Album clock"),
        ]
        #expect(ID3EmbeddedLyrics.userField(name: "org.studio.LYRICS", text: "Copper arc")?.role == .original)
        #expect(ID3EmbeddedLyrics.userField(name: "CUSTOM_LYRICS", text: "铜弦一动\n白帆初醒")?.role == .original)
        #expect(ID3EmbeddedLyrics.userField(name: "CUSTOM_LYRICS", text: "Annotation") == nil)
        let metadata = EmbeddedTagMetadataParser.metadata(fromOrderedTagValues: fields)
        #expect(metadata.lyricFields.map(\.name) == fields.prefix(7).map(\.0))
        #expect(metadata.lyricFields.map(\.role) == [.original, .original, .original, .translation, .translation, .romanization, .original])
        #expect(metadata.lyricFields[3].languageCode == "en")
        #expect(metadata.lyricFields[5].languageCode == "zh-Hans")
        #expect(metadata.lyricsVariants.map(\.text) == [timed, duet, fields[6].1])
        #expect(metadata.lyricsLanguageCode == "zh")
        var merged = metadata
        merged.fillMissing(from: metadata)
        #expect(merged.lyricFields == metadata.lyricFields)
        let readingOnly = EmbeddedTagMetadataParser.metadata(fromOrderedTagValues: [("ROMAJI", "sora")])
        #expect(!readingOnly.isEmpty)
        #expect(readingOnly.lyrics == nil)
    }

    @Test func companionFieldsPreserveTimedReadingsAndRecoverAlternateTranslations() throws {
        let original = [LyricLine(timestamp: 1, text: "苇灯",
                                  background: [.init(timestamp: 2, text: "归岸", isBackingVocal: true)]),
                        LyricLine(timestamp: 4, text: "青帆")]
        let reading = EmbeddedLyricField(name: "PINYIN", text: "[00:01.00]<00:01.00>wěi <00:01.45>dēng\n[00:02.00]guī àn\n[00:04.00]qīng fān", role: .romanization)
        var result = LyricManualTranslationPolicy.mergingEmbeddedField(reading, into: original)
        #expect(result[0].romanization == "wěi dēng")
        #expect(result[0].romanizationSyllables?.map(\.start) == [1, 1.45])
        #expect(result[0].background?.first?.romanization == "guī àn")
        for text in ["[00:01]Reed lamp", "[00:01]Light in the reeds"] {
            result = LyricManualTranslationPolicy.mergingEmbeddedField(.init(name: "TRANSLATION", text: text, languageCode: "en", role: .translation), into: result)
        }
        #expect(result[0].allManualTranslations.map(\.text) == ["Reed lamp", "Light in the reeds"])
        #expect(result[1].romanization == "qīng fān")
        #expect(result[1].manualTranslation == nil)
    }

    @Test func unorderedFallbackCannotMoveTheInUseFieldBehindAnotherEqualRankedLyric() {
        let edited = EmbeddedLyricsVariant(text: "[00:01]The glass ferry returns")
        let other = EmbeddedLyricsVariant(text: "[00:01]The copper bell rings")
        let newField = EmbeddedLyricsVariant(text: "[00:01]Beyond the quay")
        var physical = [edited, other]
        let selected = EmbeddedLyricsVariantPolicy.merge(other.text, languageCode: nil, variants: [other, newField, edited],
            current: edited.text, currentLanguage: nil, into: &physical, preferringIncomingOrder: false)
        #expect(physical == [edited, other, newField])
        #expect(selected == edited)
    }

    @Test func fieldCacheReadsPreviousSchemaAndPreservesIdenticalTagOccurrences() throws {
        let old = Data(#"{"variants":[{"text":"a reed lantern"}],"languageTaggedLyrics":{},"languageTaggedTranslations":{}}"#.utf8)
        let legacy = try JSONDecoder().decode(EmbeddedLyricsAlternatives.self, from: old)
        #expect(legacy.fields == nil)
        let field = EmbeddedLyricField(name: "LYRICS", text: "a reed lantern")
        let record = EmbeddedLyricsAlternatives(variants: legacy.variants, fields: [field, field, .init(name: "LYRICS_PINYIN", text: "wěi dēng", role: .romanization)])
        #expect(record.hasSourceFields && !record.offersChoice)
        #expect(try JSONDecoder().decode(EmbeddedLyricsAlternatives.self, from: JSONEncoder().encode(record)) == record)
    }

    private let plain = "First line\nSecond line"
    private let lineTimed = "[00:01.00]First line\n[00:03.00]Second line"
    private let wordTimed = "[00:01.00]<00:01.00>First <00:01.40>line\n[00:03.00]<00:03.00>Second <00:03.50>line"

    private func variants(_ texts: [String]) -> [EmbeddedLyricsVariant] {
        texts.map { EmbeddedLyricsVariant(text: $0) }
    }

    @Test("时间轴最细的胜出：逐字 > 逐行 > 纯文本")
    func finestTimingWins() {
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, lineTimed, wordTimed]), priority: .timingType) == 2)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, lineTimed]), priority: .timingType) == 1)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([wordTimed, plain]), priority: .timingType) == 0)
    }

    @Test("一样细的取文件里排在前面的")
    func tiesKeepTheEarlierCopy() {
        let other = "[00:02.00]Another\n[00:04.00]Copy"
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([lineTimed, other]), priority: .timingType) == 0)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, "Plain again"]), priority: .timingType) == 0)
    }

    @Test("按文件里的先后：不看时间轴")
    func firstInFileIgnoresTiming() {
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, wordTimed]), priority: .firstInFile) == 0)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(in: [], priority: .timingType) == nil)
    }

    @Test("两套优先顺序独立保存，缺少首选时继续向后挑")
    func independentOrders() throws {
        let suite = "embedded-orders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("lineLevel,plain,wordLevel", forKey: EmbeddedLyricsVariantPriority.timingOrderKey)
        defaults.set("ttml,lrc,plainText", forKey: EmbeddedLyricsVariantPriority.formatOrderKey)
        let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="3s">Cinder rain</p></div></body></tt>"#
        func pick(_ texts: [String], _ priority: EmbeddedLyricsVariantPriority) -> Int? {
            EmbeddedLyricsVariantPolicy.preferredIndex(in: variants(texts), priority: priority, defaults: defaults)
        }
        #expect(pick([wordTimed, plain, lineTimed, ttml], .timingType) == 2)
        #expect(pick([wordTimed, plain], .timingType) == 1)
        #expect(pick([plain, "[1200,3400]Copper tide"], .timingType) == 1)
        #expect(pick(["<tt><body>", lineTimed], .lyricsFormat) == 1)
        #expect(pick([wordTimed, plain, lineTimed, ttml], .lyricsFormat) == 3)
        #expect(pick([plain, lineTimed, wordTimed], .lyricsFormat) == 2)
        #expect(pick([plain, lineTimed, wordTimed], .firstInFile) == 0)
        defaults.set("plainText,lrc", forKey: EmbeddedLyricsVariantPriority.formatOrderKey)
        #expect(pick([lineTimed, plain], .lyricsFormat) == 1)
        #expect(pick([lineTimed, plain], .timingType) == 0)
    }

    @Test("旧设置和残缺顺序可读，未知项和重复项不影响其余顺序")
    func orderCompatibility() {
        #expect(EmbeddedLyricsVariantPriority(rawValue: "finestTiming") == .timingType)
        #expect(EmbeddedLyricsVariantPriority.timingType.order(from: "plain,unknown,plain") ==
            ["plain", "wordLevel", "lineLevel"])
        let formats = EmbeddedLyricsVariantPriority.lyricsFormat.order(from: "qrc,unknown,qrc")
        #expect(formats.first == "qrc")
        #expect(Set(formats) == Set(EmbeddedLyricsContentFormat.allCases.map(\.rawValue)))
        #expect(formats.count == EmbeddedLyricsContentFormat.allCases.count)
    }

    @Test("无扩展名的内嵌文本按内容识别")
    func embeddedFormatDetection() {
        let fixtures: [(EmbeddedLyricsContentFormat, String)] = [
            (.plainText, plain), (.lrc, lineTimed), (.lrc, wordTimed),
            (.lrc, "[type:LyricifyLines]\n[1200,3400]Copper sky"),
            (.ttml, #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="3s">Copper sky</p></div></body></tt>"#),
            (.lys, "[0]Copper (1000,300)sky(1300,500)"),
            (.yrc, "[1000,800](1000,300,0)Copper (1300,500,0)sky"),
            (.qrc, "[1000,800]Copper (1000,300)sky(1300,500)"),
            (.krc, "[1000,800]<0,300,0>Copper <300,500,0>sky"),
            (.webVTT, "WEBVTT\n\n00:01.000 --> 00:02.000\nCopper sky"),
            (.subRip, "1\n00:00:01,000 --> 00:00:02,000\nCopper sky"),
            (.substationAlpha, "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Copper sky"),
        ]
        for (format, text) in fixtures {
            #expect(EmbeddedLyricsContentFormat.detect(text, timing: LyricsTimingLevel(lines: LyricsContentParser.parseText(text))) == format)
        }
    }

    @Test("内容相同的只记一次，补上后来才知道的语言；空白不记")
    func appendDeduplicates() {
        var list: [EmbeddedLyricsVariant] = []
        EmbeddedLyricsVariantPolicy.append(plain, languageCode: nil, to: &list)
        EmbeddedLyricsVariantPolicy.append(plain, languageCode: "en", to: &list)
        EmbeddedLyricsVariantPolicy.append("  \n", languageCode: nil, to: &list)
        EmbeddedLyricsVariantPolicy.append(nil, languageCode: nil, to: &list)
        EmbeddedLyricsVariantPolicy.append(lineTimed, languageCode: "en", to: &list)
        #expect(list == [
            EmbeddedLyricsVariant(text: plain, languageCode: "en"),
            EmbeddedLyricsVariant(text: lineTimed, languageCode: "en"),
        ])
        #expect(EmbeddedLyricsAlternatives(variants: list).offersChoice)
        #expect(!EmbeddedLyricsAlternatives(variants: Array(list.prefix(1))).offersChoice)
    }

    @Test("设置值认不出时按默认")
    func storedPriority() throws {
        let defaults = try #require(UserDefaults(suiteName: "embedded-variant-priority-\(UUID().uuidString)"))
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .timingType)
        defaults.set(EmbeddedLyricsVariantPriority.firstInFile.rawValue, forKey: EmbeddedLyricsVariantPriority.storageKey)
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .firstInFile)
        defaults.set("somethingElse", forKey: EmbeddedLyricsVariantPriority.storageKey)
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .timingType)
    }

    @Test("LYRICS 是纯文本、SYNCEDLYRICS 是 LRC 时显示 LRC，几份都按先后记下")
    func vorbisFieldsKeepEveryCopy() {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "LYRICS": [plain],
            "SYNCEDLYRICS": [lineTimed],
            "UNSYNCEDLYRICS": [plain],
        ])
        #expect(metadata.lyrics == lineTimed)
        #expect(metadata.lyricsVariants.map(\.text) == [plain, lineTimed])
    }

    @Test("同一原文语言的不同字段一起参与选择，其他语言仍保留作译文")
    func multipleTaggedCopiesOfTheOriginalLanguage() {
        let fields = [("LYRICS:de", "Kupferwind"), ("SYNCEDLYRICS:en", wordTimed),
                      ("LYRICS:en", plain), ("LYRICS_LANGUAGE", "eng")]
        let metadata = EmbeddedTagMetadataParser.metadata(fromOrderedTagValues: fields)
        #expect(metadata.lyricsVariants == [.init(text: wordTimed, languageCode: "en"),
                                           .init(text: plain, languageCode: "en")])
        #expect(metadata.translatedLyrics == "Kupferwind")
        let oneLanguage = EmbeddedTagMetadataParser.metadata(fromTagValues: ["LYRICS:en": [plain, lineTimed]])
        #expect(oneLanguage.lyricsVariants.map(\.text) == [plain, lineTimed])
        #expect(oneLanguage.lyrics == lineTimed)
    }

    @Test("同名字段写了两遍也算两份；带语言后缀的照旧是译文候选")
    func repeatedFieldsAndTaggedAlternates() {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "LYRICS": [plain, wordTimed],
            "LYRICS:en": ["[00:01.00]Translated"],
        ])
        #expect(metadata.lyrics == wordTimed)
        #expect(metadata.lyricsVariants.count == 2)
        #expect(metadata.languageTaggedLyrics["en"] == "[00:01.00]Translated")
    }
}
