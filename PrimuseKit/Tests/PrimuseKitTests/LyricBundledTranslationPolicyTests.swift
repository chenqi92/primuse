import Foundation
import Testing
@testable import PrimuseKit

struct LyricBundledTranslationPolicyTests {
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
    private static let englishSources = [
        "Legends never die", "When the world is calling you", "Can you hear them screaming out your name",
        "They become a part of you", "Every time you bleed for reaching greatness", "Relentless you survive",
    ]
    private static let englishChinese = [
        "传奇永不湮灭", "这个世界需要你", "你能听见世人皆唤你名吗",
        "镌刻传奇于己", "每次你为伟大而流血", "坚韧不拔 你终将幸存",
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

    @Test func shownTranslationsLeaveTheDocumentAlone() {
        let lines = Self.document(Self.englishSources, Self.englishChinese)
        let presentation = LyricBundledTranslationPolicy.presentation(
            of: lines,
            showsBundledTranslations: true
        )
        #expect(presentation.hasBundledTranslations)
        #expect(presentation.lines == lines)
    }

    @Test func hiddenTranslationsLeaveOnlyTheSungLines() {
        let lines = Self.document(Self.englishSources, Self.englishChinese)
        #expect(lines.allSatisfy { $0.manualTranslation != nil })
        let presentation = LyricBundledTranslationPolicy.presentation(
            of: lines,
            showsBundledTranslations: false
        )
        #expect(presentation.hasBundledTranslations)
        #expect(presentation.lines.map(\.text) == Self.englishSources)
        #expect(presentation.lines.map(\.id) == lines.map(\.id))
        #expect(presentation.lines.allSatisfy { $0.allManualTranslations.isEmpty })
        #expect(presentation.lines.allSatisfy {
            LyricCompanionTextPolicy.texts(for: $0, translatedText: nil).isEmpty
        })
    }

    @Test func singleTranslationSkipsReadingsAndPrefersTheTranslationResult() {
        let lines = Self.document(Self.japaneseSources, Self.romaji, Self.chinese)
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(in: lines)
        // 文件里同一时间戳的罗马音行是读音,不当译文;取后面那行中文。
        #expect(lines.map {
            LyricCompanionTextPolicy.translation(for: $0, translatedText: nil, readingIDs: readingIDs)
        } == Self.chinese)
        // 翻译结果里有的用翻译结果;和原文一样、只有空白的不算。
        #expect(LyricCompanionTextPolicy.translation(
            for: lines[0], translatedText: "I can hear your voice", readingIDs: readingIDs
        ) == "I can hear your voice")
        #expect(LyricCompanionTextPolicy.translation(
            for: lines[0], translatedText: "  ", readingIDs: readingIDs
        ) == Self.chinese[0])
        let romanized = LyricLine(timestamp: 1, text: "君の声", romanization: "kimi no koe")
        #expect(LyricCompanionTextPolicy.translation(for: romanized, translatedText: nil) == nil)
        #expect(LyricCompanionTextPolicy.translation(for: romanized, translatedText: "君の声") == nil)
    }

    @Test func readingRowsStayWhenTranslationsAreHidden() {
        let lines = Self.document(Self.japaneseSources, Self.romaji, Self.chinese)
        let presentation = LyricBundledTranslationPolicy.presentation(
            of: lines,
            showsBundledTranslations: false
        )
        #expect(presentation.hasBundledTranslations)
        let companions = presentation.lines.map {
            LyricCompanionTextPolicy.texts(for: $0, translatedText: nil)
        }
        #expect(companions == Self.romaji.map { [$0] })
        // 机翻准备拿到这份歌词时，读音行仍被认作读音，不会被当成已有的中文译文。
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(in: presentation.lines)
        #expect(!presentation.lines.contains {
            LyricManualTranslationPolicy.preferredTranslation(
                for: $0,
                targetLanguageCode: "zh-Hans",
                readingIDs: readingIDs
            ) != nil
        })
    }

    @Test func readingsAloneAreNotBundledTranslations() {
        let lines = Self.document(Self.japaneseSources, Self.romaji)
        let presentation = LyricBundledTranslationPolicy.presentation(
            of: lines,
            showsBundledTranslations: false
        )
        #expect(!presentation.hasBundledTranslations)
        #expect(presentation.lines == lines)
    }

    @Test func translationFieldsAndBackgroundRowsAreHiddenToo() {
        var lead = LyricLine(timestamp: 1, text: "Hold on", isSynchronized: true)
        lead.manualTranslation = LyricManualTranslation(
            text: "坚持住", languageCode: "zh-Hans", source: .embeddedField
        )
        lead.alternateManualTranslations = [
            LyricManualTranslation(text: "がんばって", languageCode: "ja", source: .embeddedField),
        ]
        var backing = LyricLine(timestamp: 1.5, text: "hold on", isSynchronized: true)
        backing.manualTranslation = LyricManualTranslation(text: "坚持", source: .localEditor)
        lead.background = [backing]
        let plain = LyricLine(timestamp: 4, text: "Never let go", isSynchronized: true)

        let presentation = LyricBundledTranslationPolicy.presentation(
            of: [lead, plain],
            showsBundledTranslations: false
        )
        #expect(presentation.hasBundledTranslations)
        #expect(presentation.lines[0].allManualTranslations.isEmpty)
        #expect(presentation.lines[0].background?.first?.allManualTranslations.isEmpty == true)
        #expect(presentation.lines[0].background?.first?.text == "hold on")
        #expect(presentation.lines[1] == plain)
    }

    @Test func lyricsWithoutTranslationsAreUntouched() {
        let lines = Self.document(Self.englishSources)
        for shows in [true, false] {
            let presentation = LyricBundledTranslationPolicy.presentation(
                of: lines,
                showsBundledTranslations: shows
            )
            #expect(!presentation.hasBundledTranslations)
            #expect(presentation.lines == lines)
        }
    }
}
