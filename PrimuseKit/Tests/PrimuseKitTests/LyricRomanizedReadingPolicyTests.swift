import Foundation
import Testing
@testable import PrimuseKit

struct LyricRomanizedReadingPolicyTests {
    private static let japaneseSources = [
        "君の声が聞こえる", "夜の果てで", "遠くに消える", "ずっと一緒にいて",
        "心の中の光", "夢を見ていた", "信じて歩いていこう", "ありがとう さようなら",
    ]
    private static let romaji = [
        "kimi no koe ga kikoeru", "yoru no hate de", "tooku ni kieru", "zutto issho ni ite",
        "kokoro no naka no hikari", "yume wo miteita", "shinjite aruite ikou", "arigatou sayounara",
    ]
    private static let chinese = [
        "听见你的声音", "在夜的尽头", "消失在远方", "一直陪在我身边",
        "心中的光", "曾做着梦", "相信着走下去吧", "谢谢 再见",
    ]
    private static let english = [
        "I can hear your voice", "At the end of the night", "Fading far away", "Stay with me forever",
        "The light inside my heart", "I was dreaming", "Believe and keep walking", "Thank you and goodbye",
    ]

    private static func document(_ columns: [String]...) -> [LyricLine] {
        var text = ""
        for index in columns[0].indices {
            let stamp = String(format: "[00:%02d.00]", index * 3 + 1)
            for column in columns {
                text += stamp + column[index] + "\n"
            }
        }
        return LyricsContentParser.parse(text)
    }

    private static func companionIDs(
        in lines: [LyricLine],
        matching texts: [String]
    ) -> Set<String> {
        Set(lines.flatMap(\.allManualTranslations).filter { texts.contains($0.text) }.map(\.id))
    }

    @Test func romajiColumnIsARomanizationNotATranslation() {
        let lines = Self.document(Self.japaneseSources, Self.romaji, Self.chinese)
        #expect(lines.count == 8)
        let ids = LyricRomanizedReadingPolicy.readingIDs(in: lines)
        #expect(ids == Self.companionIDs(in: lines, matching: Self.romaji))

        // 英文用户：罗马音不是译文，中文行也不是，这一行需要翻译。
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: lines[0],
            targetLanguageCode: "en",
            readingIDs: ids
        ) == nil)
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(
            in: lines,
            targetLanguageCode: "en"
        ))
        // 中文用户照旧拿到中文行。
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: lines[0],
            targetLanguageCode: "zh-Hans",
            readingIDs: ids
        )?.text == "听见你的声音")
        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(
            in: lines,
            targetLanguageCode: "zh-Hans"
        ))
    }

    @Test func englishColumnStaysATranslation() {
        let lines = Self.document(Self.japaneseSources, Self.english)
        #expect(lines.count == 8)
        #expect(LyricRomanizedReadingPolicy.readingIDs(in: lines).isEmpty)
        #expect(LyricManualTranslationPolicy.hasCompleteCoverage(
            in: lines,
            targetLanguageCode: "en"
        ))
    }

    @Test func fourRowFilesKeepTheEnglishColumnAndDropTheRomaji() {
        let lines = Self.document(Self.japaneseSources, Self.romaji, Self.chinese, Self.english)
        #expect(lines.count == 8)
        let ids = LyricRomanizedReadingPolicy.readingIDs(in: lines)
        #expect(ids == Self.companionIDs(in: lines, matching: Self.romaji))
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: lines[0],
            targetLanguageCode: "en",
            readingIDs: ids
        )?.text == "I can hear your voice")
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: lines[0],
            targetLanguageCode: "zh-Hans",
            readingIDs: ids
        )?.text == "听见你的声音")
    }

    @Test func loanwordsInAFewRowsDoNotBreakTheRomajiColumn() {
        var romaji = Self.romaji
        romaji[3] = "Baby nakanaide love song"
        let lines = Self.document(Self.japaneseSources, romaji, Self.chinese)
        let ids = LyricRomanizedReadingPolicy.readingIDs(in: lines)
        #expect(ids == Self.companionIDs(in: lines, matching: romaji))
    }

    @Test func pinyinColumnIsARomanization() {
        let sources = [
            "我们的爱情", "像一场梦", "你是我的眼", "带我领略四季的变换",
            "月亮代表我的心", "天空很蓝", "永远在一起", "再见我的爱",
        ]
        let pinyin = [
            "wo men de ai qing", "xiang yi chang meng", "ni shi wo de yan", "dai wo ling lve si ji de bian huan",
            "yue liang dai biao wo de xin", "tian kong hen lan", "yong yuan zai yi qi", "zai jian wo de ai",
        ]
        let lines = Self.document(sources, pinyin)
        #expect(lines.count == 8)
        let ids = LyricRomanizedReadingPolicy.readingIDs(in: lines)
        #expect(ids == Self.companionIDs(in: lines, matching: pinyin))
        #expect(!LyricManualTranslationPolicy.hasCompleteCoverage(
            in: lines,
            targetLanguageCode: "en"
        ))
    }

    @Test func revisedRomanizationColumnIsARomanization() {
        let sources = [
            "사랑해 그대여", "너를 향한 내 마음", "우리 함께 걸어가요", "밤하늘의 별처럼",
            "영원히 기억할게", "오직 너만을 위해", "행복한 시간들", "다시 만나요",
        ]
        let romanized = [
            "saranghae geudaeyeo", "neoreul hyanghan nae maeum", "uri hamkke georeogayo", "bamhaneurui byeolcheoreom",
            "yeongwonhi gieokhalge", "ojik neomaneul wihae", "haengbokhan sigandeul", "dasi mannayo",
        ]
        let lines = Self.document(sources, romanized)
        #expect(lines.count == 8)
        #expect(LyricRomanizedReadingPolicy.readingIDs(in: lines)
            == Self.companionIDs(in: lines, matching: romanized))
    }

    @Test func tooFewRowsGiveNoVerdict() {
        let lines = Self.document(
            Array(Self.japaneseSources.prefix(4)),
            Array(Self.romaji.prefix(4)),
            Array(Self.chinese.prefix(4))
        )
        #expect(lines.count == 4)
        #expect(LyricRomanizedReadingPolicy.readingIDs(in: lines).isEmpty)
    }

    @Test func syllableEvidenceSeparatesReadingsFromProse() {
        func ratio(_ text: String, _ script: LyricRomanizedReadingPolicy.SourceScript) -> Double? {
            LyricRomanizedReadingPolicy.syllableEvidence(of: text, script: script)?.ratio
        }
        #expect(ratio("kimi no koe ga kikoeru", .japanese) == 1)
        #expect(ratio("Kyō no yume wo shinjite", .japanese) == 1)
        #expect(ratio("wo men de ai qing", .chinese) == 1)
        #expect(ratio("saranghae geudaeyeo", .korean) == 1)
        #expect((ratio("I want to hold your hand tonight", .japanese) ?? 1) < 0.5)
        #expect((ratio("Thank you and goodbye", .korean) ?? 1) < 0.5)
        #expect((ratio("the world is beautiful", .chinese) ?? 1) < 0.5)
        // 夹着原文文字的行不是读音行。
        #expect(ratio("Baby 泣かないで", .japanese) == nil)
        #expect(ratio("♪", .japanese) == nil)
    }
}
