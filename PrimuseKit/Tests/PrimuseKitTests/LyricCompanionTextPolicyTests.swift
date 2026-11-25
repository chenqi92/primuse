import Foundation
import Testing
@testable import PrimuseKit

struct LyricCompanionTextPolicyTests {
    private func line(
        romanization: String? = nil,
        embedded: [String] = []
    ) -> LyricLine {
        var line = LyricLine(timestamp: 1, text: "夢の中で", isSynchronized: true)
        line.romanization = romanization
        let rows = embedded.map { LyricManualTranslation(text: $0, source: .bilingualLRC) }
        line.manualTranslation = rows.first
        line.alternateManualTranslations = Array(rows.dropFirst())
        return line
    }

    @Test func machineTranslationFollowsTheAuthoredRows() {
        let texts = LyricCompanionTextPolicy.texts(
            for: line(romanization: "yume no naka de", embedded: ["ゆめのなかで"]),
            translatedText: "在梦中"
        )
        #expect(texts == ["yume no naka de", "ゆめのなかで", "在梦中"])
    }

    @Test func authoredTranslationIsNotRepeated() {
        let paired = line(embedded: ["ゆめのなかで", "在梦中"])
        #expect(LyricCompanionTextPolicy.texts(
            for: paired,
            translatedText: "在梦中"
        ) == ["ゆめのなかで", "在梦中"])
        #expect(LyricCompanionTextPolicy.texts(
            for: paired,
            translatedText: " 在梦中 "
        ) == ["ゆめのなかで", "在梦中"])
        #expect(LyricCompanionTextPolicy.texts(
            for: paired,
            translatedText: nil
        ) == ["ゆめのなかで", "在梦中"])
    }

    @Test func translationIdenticalToTheLyricIsDropped() {
        #expect(LyricCompanionTextPolicy.texts(for: line(), translatedText: "夢の中で").isEmpty)
        #expect(LyricCompanionTextPolicy.texts(for: line(), translatedText: "   ").isEmpty)
        #expect(LyricCompanionTextPolicy.texts(for: line(), translatedText: "在梦中") == ["在梦中"])
    }

    @Test func blankAuthoredRowsAreSkipped() {
        let texts = LyricCompanionTextPolicy.texts(
            for: line(romanization: "  ", embedded: [" ", "在梦中 "]),
            translatedText: nil
        )
        #expect(texts == ["在梦中"])
    }

    @Test func itemsPreserveValidatedWordTimingAndProjectIntoLyricLine() throws {
        let romaSyllables = [
            LyricSyllable(text: "yume ", start: 1.0, end: 1.5),
            LyricSyllable(text: "no ", start: 1.5, end: 1.8),
            LyricSyllable(text: "naka", start: 1.8, end: 2.3),
        ]
        let transSyllables = [
            LyricSyllable(text: "在", start: 1.0, end: 1.5),
            LyricSyllable(text: "梦中", start: 1.5, end: 2.3),
        ]
        let source = LyricLine(
            id: "line-1",
            timestamp: 1.0,
            text: "夢の中",
            isSynchronized: true,
            syllables: [
                LyricSyllable(text: "夢", start: 1.0, end: 1.5),
                LyricSyllable(text: "の", start: 1.5, end: 1.8),
                LyricSyllable(text: "中", start: 1.8, end: 2.3),
            ],
            endTimestamp: 2.3,
            voice: .secondary,
            manualTranslation: LyricManualTranslation(
                text: "在梦中",
                languageCode: "zh-Hans",
                source: .embeddedField,
                syllables: transSyllables
            ),
            romanization: "yume no naka",
            romanizationSyllables: romaSyllables
        )

        let items = LyricCompanionTextPolicy.items(for: source, translatedText: "在梦中")
        #expect(items.count == 2)
        #expect(items[0].kind == .romanization)
        #expect(items[0].isWordLevel)
        #expect(items[0].syllables == romaSyllables)
        #expect(items[1].kind == .translation)
        #expect(items[1].isWordLevel)
        #expect(items[1].syllables == transSyllables)

        let projected = items[0].lyricLine(for: source, slot: 0)
        #expect(projected.id == "line-1#companion:0")
        #expect(projected.isWordLevel)
        #expect(projected.voice == .secondary)
        #expect(projected.syllables == romaSyllables)
        #expect(projected.endTimestamp == 2.3)

        // Overriding with a different machine translation drops authored translation syllables.
        let overridden = LyricCompanionTextPolicy.items(for: source, translatedText: "In a dream")
        #expect(overridden.count == 2)
        #expect(overridden[0].isWordLevel)
        #expect(overridden[1].text == "In a dream")
        #expect(!overridden[1].isWordLevel)
    }

    @Test func itemsRejectCorruptedOrMismatchedCompanionSyllables() {
        var mismatched = LyricLine(timestamp: 1, text: "夢", romanization: "yume")
        mismatched.romanizationSyllables = [LyricSyllable(text: "other", start: 1, end: 2)]
        let mismatchedItems = LyricCompanionTextPolicy.items(for: mismatched, translatedText: nil)
        #expect(mismatchedItems.count == 1)
        #expect(mismatchedItems[0].text == "yume")
        #expect(mismatchedItems[0].syllables == nil)

        var nonMonotonic = LyricLine(timestamp: 1, text: "夢", romanization: "yu me")
        nonMonotonic.romanizationSyllables = [
            LyricSyllable(text: "yu ", start: 2.0, end: 2.5),
            LyricSyllable(text: "me", start: 1.5, end: 2.0),
        ]
        #expect(LyricCompanionTextPolicy.items(for: nonMonotonic, translatedText: nil).first?.syllables == nil)

        var inverted = LyricLine(
            timestamp: 1,
            text: "夢",
            manualTranslation: LyricManualTranslation(
                text: "梦",
                source: .embeddedField,
                syllables: [LyricSyllable(text: "梦", start: 2.0, end: 1.0)]
            )
        )
        #expect(LyricCompanionTextPolicy.items(for: inverted, translatedText: nil).first?.syllables == nil)

        inverted.manualTranslation = LyricManualTranslation(
            text: "梦",
            source: .embeddedField,
            syllables: [LyricSyllable(text: "梦", start: .nan, end: 2.0)]
        )
        #expect(LyricCompanionTextPolicy.items(for: inverted, translatedText: nil).first?.syllables == nil)
    }
}
