import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric syllable emphasis")
struct LyricSyllableEmphasisPolicyTests {
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
        #expect(singing > 0.9)
        let fading = LyricSyllableEmphasisPolicy.glow(for: word, at: 12.2)
        #expect(fading > 0)
        #expect(fading < singing)
        #expect(LyricSyllableEmphasisPolicy.glow(for: word, at: 12.5) == 0)
    }

    @Test("Short words glow faintly, held notes glow fully")
    func glowScalesWithWordLength() {
        let short = LyricSyllable(text: "a", start: 0, end: 0.2)
        let held = LyricSyllable(text: "ooh", start: 0, end: 1.5)
        let shortPeak = LyricSyllableEmphasisPolicy.glow(for: short, at: 0.15)
        let heldPeak = LyricSyllableEmphasisPolicy.glow(for: held, at: 0.8)
        #expect(shortPeak > 0)
        #expect(shortPeak < 0.5)
        #expect(heldPeak > 0.99)
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
