import Foundation
import Testing
@testable import PrimuseKit

@Suite("ImmersiveSyllableCrestPolicy")
struct ImmersiveSyllableCrestPolicyTests {
    typealias Policy = ImmersiveSyllableCrestPolicy

    @Test func farAheadIsResting() {
        let state = Policy.appearance(start: 10, end: 10.4, at: 9)
        #expect(state == .resting)
        #expect(state.lift == 0)
        #expect(state.scale == 1)
        #expect(state.glow == 0)
        #expect(state.restingOpacity == Policy.restingOpacity)
    }

    @Test func nextSyllableBrightensBeforeItStarts() {
        let early = Policy.appearance(start: 10, end: 10.4, at: 10 - Policy.anticipationLead * 0.75)
        let late = Policy.appearance(start: 10, end: 10.4, at: 10 - Policy.anticipationLead * 0.25)
        #expect(abs(early.anticipation - 0.25) < 1e-9)
        #expect(abs(late.anticipation - 0.75) < 1e-9)
        #expect(late.restingOpacity > early.restingOpacity)
        #expect(early.fill == 0 && late.fill == 0 && late.crest == 0)
    }

    @Test func fillRisesAcrossTheSyllableAndEndsLit() {
        var previous = -1.0
        for step in 0...10 {
            let fill = Policy.appearance(start: 10, end: 11, at: 10 + Double(step) / 10).fill
            #expect(fill >= previous)
            previous = fill
        }
        #expect(Policy.appearance(start: 10, end: 11, at: 10).fill == 0)
        #expect(Policy.appearance(start: 10, end: 11, at: 11).fill == 1)
        #expect(Policy.appearance(start: 10, end: 11, at: 30).fill == 1)
        // 先快后慢：唱到一半时已经亮了一大半。
        #expect(Policy.appearance(start: 10, end: 11, at: 10.5).fill == 0.75)
    }

    @Test func crestPeaksQuicklyAndShortSyllablesPeakLower() {
        let held = Policy.appearance(start: 10, end: 11, at: 10 + Policy.crestAttack)
        #expect(abs(held.crest - 1) < 1e-9)
        let quick = Policy.appearance(start: 10, end: 10 + Policy.crestAttack / 2, at: 10 + Policy.crestAttack / 2)
        #expect(quick.crest > 0.8 && quick.crest < 0.9)
    }

    @Test func crestSettlesAfterTheSyllableEnds() {
        var previous = 2.0
        for step in 0...10 {
            let crest = Policy.appearance(start: 10, end: 10.5, at: 10.5 + Policy.crestRelease * Double(step) / 10).crest
            #expect(crest <= previous)
            previous = crest
        }
        #expect(previous == 0)
        let settled = Policy.appearance(start: 10, end: 10.5, at: 20)
        #expect(settled.crest == 0 && settled.lift == 0 && settled.scale == 1 && settled.fill == 1)
    }

    @Test func longNotesRiseHigherThanShortOnes() {
        let short = Policy.appearance(start: 10, end: 10.4, at: 10.3)
        #expect(short.hold == 0)
        let midway = Policy.appearance(start: 10, end: 13, at: 10 + (Policy.holdOnset + Policy.holdFull) / 2)
        #expect(abs(midway.hold - 0.5) < 1e-9)
        let full = Policy.appearance(start: 10, end: 13, at: 10 + Policy.holdFull)
        #expect(full.hold == 1)
        #expect(full.lift > short.lift)
        #expect(full.scale > short.scale)
        #expect(full.glow > short.glow)
        #expect(abs(full.lift - (Policy.liftRatio + Policy.holdLiftRatio)) < 1e-9)
        // 长音唱完落回时保留加成，浪尖照常散去。
        let releasing = Policy.appearance(start: 10, end: 13, at: 13 + Policy.crestRelease / 2)
        #expect(releasing.hold == 1)
        #expect(releasing.crest > 0 && releasing.crest < 1)
    }

    @Test func onlySyllablesNearTheVoiceAreRaised() {
        let syllables = (0..<10).map { index in
            LyricSyllable(text: "w\(index) ", start: Double(index) * 0.3, end: Double(index + 1) * 0.3)
        }
        let states = Policy.appearances(for: syllables, at: 1.65)
        #expect(states.count == 10)
        // 第 6 个字（下标 5）正在唱。
        #expect(states[5].crest > 0.99)
        #expect(states[5].fill > 0 && states[5].fill < 1)
        // 半秒以前就唱完的字已经落回，亮色留着。
        for index in 0...2 {
            #expect(states[index].crest == 0)
            #expect(states[index].fill == 1)
        }
        // 刚唱完的还在往下落。
        #expect(states[4].crest > 0 && states[4].crest < 1)
        // 下一个字在预备，再往后的还暗着。
        #expect(states[6].anticipation > 0)
        #expect(states[8] == .resting)
    }

    @Test func zeroLengthOrInvalidTimesNeverAnimate() {
        let instant = Policy.appearance(start: 10, end: 10, at: 10)
        #expect(instant.fill == 1 && instant.crest == 0)
        #expect(Policy.appearance(start: .nan, end: 11, at: 10) == .resting)
        #expect(Policy.appearance(start: 10, end: 11, at: .infinity) == .resting)
        #expect(Policy.maximumOverhangRatio > Policy.liftRatio)
    }
}
