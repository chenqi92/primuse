import Foundation
import Testing
@testable import PrimuseKit

@Suite("Embedded lyrics variants")
struct EmbeddedLyricsVariantPolicyTests {
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
