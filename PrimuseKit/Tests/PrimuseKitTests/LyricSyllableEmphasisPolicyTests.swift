import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric syllable emphasis")
struct LyricSyllableEmphasisPolicyTests {
    @Test("Only a held word gets extra emphasis within an otherwise ordinary line")
    func heldWordEmphasis() {
        let words = [
            LyricSyllable(text: "Paper ", start: 0, end: 0.4),
            LyricSyllable(text: "lanterns ", start: 0.4, end: 0.9),
            LyricSyllable(text: "glow", start: 0.9, end: 3.1),
        ]
        let emphasis = LyricSyllableEmphasisPolicy.sustainedEmphasis(in: words)
        #expect(emphasis == [0, 0, 1])
        let equallySlow = words.map { LyricSyllable(text: $0.text, start: $0.start, end: $0.start + 2) }
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: equallySlow) == [0, 0, 0])
    }

    @Test("Duet lyrics never get held-word emphasis, solo lyrics keep it")
    func duetLyricsSkipHeldWordEmphasis() {
        let words = [
            LyricSyllable(text: "Paper ", start: 0, end: 0.4),
            LyricSyllable(text: "lanterns ", start: 0.4, end: 0.9),
            LyricSyllable(text: "glow", start: 0.9, end: 3.1),
        ]
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: words, isDuet: true) == [0, 0, 0])
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: words, isDuet: false) == [0, 0, 1])
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: [], isDuet: true) == [])
    }

    @Test("Inferred silent gaps and malformed timing never imply a held note")
    func inferredTimingDoesNotStretch() {
        let words = [
            LyricSyllable(text: "Paper ", start: 0, end: 0.4),
            LyricSyllable(text: "lanterns ", start: 0.4, end: 4, endTiming: .inferred),
            LyricSyllable(text: "glow", start: 4, end: 8, endTiming: .legacy),
            LyricSyllable(text: " ", start: 8, end: 12),
            LyricSyllable(text: "invalid", start: 12, end: .infinity),
        ]
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: words) == [0, 0, 0, 0, 0])
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: []) == [])
    }

    @Test("A phrase with one shared timestamp does not invent held-word emphasis")
    func phraseTimingDoesNotStretch() {
        let phrase = LyricSyllable(text: "Paper lanterns glow", start: 0, end: 5)
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: [phrase]) == [0])
    }

    @Test("A standalone sustained word is emphasized without splitting its letters")
    func standaloneHeldWord() {
        let short = LyricSyllable(text: "Glow", start: 0, end: 0.4)
        let held = LyricSyllable(text: "Glow", start: 0, end: 2)
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: [short]) == [0])
        #expect(LyricSyllableEmphasisPolicy.sustainedEmphasis(in: [held]) == [1])
    }

    private let line = [
        LyricSyllable(text: "Hel", start: 10.0, end: 10.4),
        LyricSyllable(text: "lo ", start: 10.4, end: 10.8),
        LyricSyllable(text: "world", start: 10.8, end: 12.0),
    ]

    @Test("A sung word keeps its full size while the next word is sung")
    func sungWordStaysRaised() {
        let first = line[0]
        #expect(LyricSyllableEmphasisPolicy.rise(for: first, nextSyllableStart: 10.4, at: 9.9) == 0)
        let midway = LyricSyllableEmphasisPolicy.rise(for: first, nextSyllableStart: 10.4, at: 10.2)
        #expect(midway > 0.5)
        #expect(midway < 1)
        #expect(LyricSyllableEmphasisPolicy.rise(for: first, nextSyllableStart: 10.4, at: 10.6) == 1)
        #expect(LyricSyllableEmphasisPolicy.rise(for: first, nextSyllableStart: 10.4, at: 11.5) == 1)
    }

    @Test("The whole line holds until shortly after its last word, then settles")
    func lineSettlesAfterLastWord() {
        let holdingEnd = LyricSyllableEmphasisPolicy.lineHold(syllables: line, deactivationTime: nil, at: 12.1)
        #expect(holdingEnd == 1)
        let settling = LyricSyllableEmphasisPolicy.lineHold(syllables: line, deactivationTime: nil, at: 12.35)
        #expect(settling > 0)
        #expect(settling < 1)
        let settled = LyricSyllableEmphasisPolicy.lineHold(syllables: line, deactivationTime: nil, at: 12.6)
        #expect(settled == 0)
    }

    @Test("A line that hands over early finishes settling before the next line takes over")
    func lineSettlesBeforeHandover() {
        let beforeHandover = LyricSyllableEmphasisPolicy.lineHold(syllables: line, deactivationTime: 12.05, at: 11.70)
        #expect(beforeHandover == 1)
        let atHandover = LyricSyllableEmphasisPolicy.lineHold(syllables: line, deactivationTime: 12.05, at: 12.05)
        #expect(atHandover < 0.001)
    }

    @Test("Glow brightens on the sung word and fades after it")
    func glowFollowsTheSungWord() {
        let word = line[2]
        #expect(LyricSyllableEmphasisPolicy.glow(for: word, at: 10.7) == 0)
        let singing = LyricSyllableEmphasisPolicy.glow(for: word, at: 11.5)
        #expect(abs(singing - LyricSyllableEmphasisPolicy.glowStrength) < 1e-9)
        let fading = LyricSyllableEmphasisPolicy.glow(for: word, at: 12.2)
        #expect(fading > 0)
        #expect(fading < singing)
        #expect(LyricSyllableEmphasisPolicy.glow(for: word, at: 12.5) == 0)
    }

    @Test("Glow strength does not depend on how long the word is sung")
    func glowIgnoresWordLength() {
        let short = LyricSyllable(text: "a", start: 0, end: 0.2)
        let held = LyricSyllable(text: "ooh", start: 0, end: 1.5)
        let shortPeak = LyricSyllableEmphasisPolicy.glow(for: short, at: 0.15)
        let heldPeak = LyricSyllableEmphasisPolicy.glow(for: held, at: 0.8)
        #expect(abs(shortPeak - LyricSyllableEmphasisPolicy.glowStrength) < 1e-9)
        #expect(abs(heldPeak - LyricSyllableEmphasisPolicy.glowStrength) < 1e-9)
    }

    @Test("Sung end uses each word's effective end even when out of order")
    func sungEndTakesTheLatestWord() {
        let unordered = [
            LyricSyllable(text: "b", start: 2, end: 3),
            LyricSyllable(text: "a", start: 1, end: 1.5),
        ]
        #expect(LyricSyllableEmphasisPolicy.sungEnd(of: unordered) == 3)
        #expect(LyricSyllableEmphasisPolicy.sungEnd(of: []) == nil)
        #expect(LyricSyllableEmphasisPolicy.lineHold(syllables: [], deactivationTime: nil, at: 5) == 1)
    }
}

@Suite("Lyric duet layout")
struct LyricDuetLayoutPolicyTests {
    @Test("Solo lyrics keep the chosen alignment")
    func soloKeepsPreference() {
        for preferred in [LyricDuetLayoutPolicy.Side.leading, .center, .trailing] {
            #expect(LyricDuetLayoutPolicy.side(for: .secondary, preferred: preferred, isDuet: false) == preferred)
        }
    }

    @Test("Duets put the two singers on opposite sides")
    func duetSplitsSides() {
        #expect(LyricDuetLayoutPolicy.side(for: .primary, preferred: .leading, isDuet: true) == .leading)
        #expect(LyricDuetLayoutPolicy.side(for: .secondary, preferred: .leading, isDuet: true) == .trailing)
        #expect(LyricDuetLayoutPolicy.side(for: .primary, preferred: .trailing, isDuet: true) == .trailing)
        #expect(LyricDuetLayoutPolicy.side(for: .secondary, preferred: .trailing, isDuet: true) == .leading)
        #expect(LyricDuetLayoutPolicy.side(for: .primary, preferred: .center, isDuet: true) == .leading)
        #expect(LyricDuetLayoutPolicy.side(for: .secondary, preferred: .center, isDuet: true) == .trailing)
    }
}
