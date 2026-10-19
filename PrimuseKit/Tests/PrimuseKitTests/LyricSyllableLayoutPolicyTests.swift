import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric syllable layout units")
struct LyricSyllableLayoutPolicyTests {
    @Test("A line timed as one block is split into characters that can wrap")
    func wholeLineBlockSplitsIntoCharacters() {
        let line = [LyricSyllable(text: "我两眼合上失去什么", start: 11, end: 15.5)]
        let units = LyricSyllableLayoutPolicy.layoutSyllables(line)

        #expect(units.map(\.text) == ["我", "两", "眼", "合", "上", "失", "去", "什", "么"])
        #expect(units.first?.start == 11)
        #expect(units.last?.end == 15.5)
        for index in units.indices.dropLast() {
            #expect(units[index].end == units[index + 1].start)
        }
        for unit in units {
            #expect(abs((unit.end - unit.start) - 0.5) < 0.000_1)
            #expect(unit.endTiming == .explicit)
        }
    }

    @Test("Syllables that are already single units are returned unchanged")
    func singleUnitsStayUnchanged() {
        let line = [
            LyricSyllable(text: "再", start: 1, end: 1.4, endTiming: .inferred),
            LyricSyllable(text: "见", start: 1.4, end: 1.9, endTiming: .legacy),
            LyricSyllable(text: "beau", start: 2, end: 2.3),
            LyricSyllable(text: "ti", start: 2.3, end: 2.5),
            LyricSyllable(text: "ful ", start: 2.5, end: 3),
            LyricSyllable(text: " world", start: 3, end: 3.6),
        ]
        #expect(LyricSyllableLayoutPolicy.layoutSyllables(line) == line)
    }

    @Test("Phrases in spaced scripts split into words with their trailing spaces")
    func phrasesSplitIntoWords() {
        #expect(LyricSyllableLayoutPolicy.units(of: "I'm in love ") == ["I'm ", "in ", "love "])
        #expect(LyricSyllableLayoutPolicy.units(of: "사랑해 너를") == ["사랑해 ", "너를"])
        #expect(LyricSyllableLayoutPolicy.units(of: "Love你") == ["Love", "你"])
    }

    @Test("Punctuation and small kana never start a line, opening marks never end one")
    func lineBreakingRules() {
        #expect(LyricSyllableLayoutPolicy.units(of: "我爱你，你爱我") == ["我", "爱", "你，", "你", "爱", "我"])
        #expect(LyricSyllableLayoutPolicy.units(of: "「你好」") == ["「你", "好」"])
        #expect(LyricSyllableLayoutPolicy.units(of: "ちょっと") == ["ちょっ", "と"])
        #expect(LyricSyllableLayoutPolicy.units(of: "ラーメン……") == ["ラー", "メ", "ン……"])
        #expect(LyricSyllableLayoutPolicy.units(of: "都为你澎湃!") == ["都", "为", "你", "澎", "湃!"])
    }

    @Test("Punctuation takes no singing time when a block is split")
    func punctuationTakesNoTime() {
        let line = [LyricSyllable(text: "你好，世界", start: 0, end: 2)]
        let units = LyricSyllableLayoutPolicy.layoutSyllables(line)

        #expect(units.map(\.text) == ["你", "好，", "世", "界"])
        for unit in units {
            #expect(abs((unit.end - unit.start) - 0.5) < 0.000_1)
        }
    }

    @Test("A split block keeps the capped duration the original block would have used")
    func splitKeepsEffectiveDuration() {
        let block = LyricSyllable(text: "别固执到问一切为何", start: 20, end: 40, endTiming: .inferred)
        let next = LyricSyllable(text: "是", start: 40, end: 40.4)
        let units = LyricSyllableLayoutPolicy.layoutSyllables([block, next])

        let expectedEnd = LyricSyllablePlaybackTimingPolicy.effectiveEnd(for: block, nextSyllableStart: 40)
        #expect(expectedEnd < 40)
        #expect(units.count == 10)
        #expect(units[8].end == expectedEnd)
        #expect(units[9] == next)
    }

    @Test("Split units keep the block's language and the surrounding syllables")
    func splitKeepsLanguageAndNeighbours() {
        let line = [
            LyricSyllable(text: "雨", start: 0, end: 0.5, languageCode: "ja"),
            LyricSyllable(text: "が降る", start: 0.5, end: 1.4, languageCode: "ja"),
            LyricSyllable(text: "夜", start: 1.4, end: 2, languageCode: "ja"),
        ]
        let units = LyricSyllableLayoutPolicy.layoutSyllables(line)

        #expect(units.map(\.text) == ["雨", "が", "降", "る", "夜"])
        #expect(units.allSatisfy { $0.languageCode == "ja" })
        #expect(units.first == line.first)
        #expect(units.last == line.last)
    }
}
