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
            in: variants([plain, lineTimed, wordTimed]), priority: .finestTiming) == 2)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, lineTimed]), priority: .finestTiming) == 1)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([wordTimed, plain]), priority: .finestTiming) == 0)
    }

    @Test("一样细的取文件里排在前面的")
    func tiesKeepTheEarlierCopy() {
        let other = "[00:02.00]Another\n[00:04.00]Copy"
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([lineTimed, other]), priority: .finestTiming) == 0)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, "Plain again"]), priority: .finestTiming) == 0)
    }

    @Test("按文件里的先后：不看时间轴")
    func firstInFileIgnoresTiming() {
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(
            in: variants([plain, wordTimed]), priority: .firstInFile) == 0)
        #expect(EmbeddedLyricsVariantPolicy.preferredIndex(in: [], priority: .finestTiming) == nil)
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
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .finestTiming)
        defaults.set(EmbeddedLyricsVariantPriority.firstInFile.rawValue, forKey: EmbeddedLyricsVariantPriority.storageKey)
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .firstInFile)
        defaults.set("somethingElse", forKey: EmbeddedLyricsVariantPriority.storageKey)
        #expect(EmbeddedLyricsVariantPriority.current(defaults) == .finestTiming)
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
