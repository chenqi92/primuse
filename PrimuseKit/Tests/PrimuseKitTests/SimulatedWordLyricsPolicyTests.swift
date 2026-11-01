import Foundation
import Testing
@testable import PrimuseKit

@Suite("Simulated word lyrics")
struct SimulatedWordLyricsPolicyTests {
    private let lines = [
        LyricLine(id: "first", timestamp: 0, text: "清晨的微风", isSynchronized: true),
        LyricLine(id: "second", timestamp: 5, text: "A quiet morning", isSynchronized: true)
    ]

    @Test func disabledByDefaultAndRestoresOriginal() {
        let original = SimulatedWordLyricsPolicy.presentation(of: lines)
        #expect(original.lines == lines)
        #expect(!original.isSimulated)
        #expect(SimulatedWordLyricsPolicy.presentation(of: lines, enabled: true).isSimulated)
        #expect(SimulatedWordLyricsPolicy.presentation(of: lines, enabled: false) == original)
        #expect(lines.allSatisfy { $0.syllables == nil })
    }

    @Test func simulatesWordsWithoutChangingTextOrIdentity() throws {
        let result = SimulatedWordLyricsPolicy.presentation(of: lines, enabled: true)
        #expect(result.isSimulated)
        #expect(result.lines.map(\.id) == lines.map(\.id))
        #expect(result.lines.map(\.timestamp) == lines.map(\.timestamp))
        for (source, display) in zip(lines, result.lines) {
            let words = try #require(display.syllables)
            #expect(words.map(\.text).joined() == source.text)
            #expect(words.allSatisfy { $0.end > $0.start && $0.endTiming == .inferred })
            #expect(words.first?.start == source.timestamp)
        }
        #expect(result.lines[0].syllables?.count == 5)
        #expect(result.lines[1].syllables?.count == 3)
        #expect(try #require(result.lines[0].syllables?.last?.end) < lines[1].timestamp)
    }

    @Test func nativeTimingWinsForTheWholeDocument() {
        var source = lines
        source[1].syllables = [LyricSyllable(text: source[1].text, start: 5.4, end: 9.8)]
        let result = SimulatedWordLyricsPolicy.presentation(of: source, enabled: true)
        #expect(result.lines == source)
        #expect(!result.isSimulated)
    }

    @Test func nativeBackgroundTimingAlsoWins() {
        var source = lines
        source[0].background = [LyricLine(timestamp: 1, text: "Ah", syllables: [LyricSyllable(text: "Ah", start: 1, end: 2)])]
        let result = SimulatedWordLyricsPolicy.presentation(of: source, enabled: true)
        #expect(result.lines == source)
        #expect(!result.isSimulated)
    }

    @Test func plainTextEmptyAndSpokenWordStayUnchanged() {
        let plain = [LyricLine(timestamp: 0, text: "No timestamps", isSynchronized: false)]
        for source in [plain, [], [LyricLine(timestamp: 2, text: "  ")]] {
            let result = SimulatedWordLyricsPolicy.presentation(of: source, enabled: true)
            #expect(result.lines == source)
            #expect(!result.isSimulated)
        }
        let spoken = SimulatedWordLyricsPolicy.presentation(of: lines, enabled: true, isSpokenWord: true)
        #expect(spoken.lines == lines)
        #expect(!spoken.isSimulated)
    }

    @Test func retainsAuthoredMetadataAndSkipsCredits() {
        var source = lines
        source[0].romanization = "qing chen de wei feng"
        source[0].metadataLines = ["[ar:Artist]"]
        source[0].voice = .secondary
        let credit = LyricLine(id: "credit", timestamp: 0, text: "Singer", isSynchronized: false)
        source.insert(credit, at: 0)
        let result = SimulatedWordLyricsPolicy.presentation(of: source, enabled: true)
        #expect(result.lines[0] == credit)
        var restored = result.lines[1]
        restored.syllables = nil
        #expect(restored == source[1])
    }

    @Test func explicitEndsAndLongInstrumentalGapsBoundTheSweep() throws {
        var source = lines
        source[0].endTimestamp = 2
        source[1].timestamp = 30
        let result = SimulatedWordLyricsPolicy.presentation(of: source, enabled: true)
        #expect(try #require(result.lines[0].syllables?.last?.end) <= 2)
        #expect(try #require(result.lines[1].syllables?.last?.end) <= 38)
    }

    @Test func laterNativeLyricsReplaceTheSimulatedPresentation() {
        #expect(SimulatedWordLyricsPolicy.presentation(of: lines, enabled: true).isSimulated)
        let native = [LyricLine(id: "first", timestamp: 0, text: "清晨", syllables: [
            LyricSyllable(text: "清", start: 0, end: 1.2), LyricSyllable(text: "晨", start: 1.2, end: 2)
        ])]
        let result = SimulatedWordLyricsPolicy.presentation(of: native, enabled: true)
        #expect(result.lines == native)
        #expect(!result.isSimulated)
    }
}
