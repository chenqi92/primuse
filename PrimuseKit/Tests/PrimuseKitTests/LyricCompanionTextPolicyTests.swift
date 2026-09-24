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
}
