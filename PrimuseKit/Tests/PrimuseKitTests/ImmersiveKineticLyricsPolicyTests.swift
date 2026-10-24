import Foundation
import Testing
@testable import PrimuseKit

@Suite("ImmersiveKineticLyricsPolicy")
struct ImmersiveKineticLyricsPolicyTests {
    typealias Policy = ImmersiveKineticLyricsPolicy

    @Test func splitsIdeographsPerCharacterAndWordsWithTheirSpacing() {
        #expect(Policy.units(in: "晴天的雨，") == ["晴", "天", "的", "雨，"])
        #expect(Policy.units(in: "Shape of you") == ["Shape ", "of ", "you"])
        #expect(Policy.units(in: "アイドル") == ["ア", "イ", "ド", "ル"])
        // 词中间的撇号、连字符不断开；开头的标点并进第一段。
        #expect(Policy.units(in: "don't rock-n-roll") == ["don't ", "rock-n-roll"])
        #expect(Policy.units(in: "「你好」") == ["「你", "好」"])
        #expect(Policy.units(in: "  ").isEmpty)
    }

    @Test func lineTimedLyricsSpreadTheLineByCharacterCount() {
        let tokens = Policy.tokens(text: "ab cdef", syllables: nil, lineStart: 10, lineEnd: 12)
        #expect(tokens.map(\.text) == ["ab ", "cdef"])
        #expect(tokens[0].start == 10)
        // 唱满 85%：2 秒里的 1.7 秒按 2 : 4 分。
        #expect(abs(tokens[0].end - (10 + 1.7 / 3)) < 1e-9)
        #expect(abs(tokens[1].start - tokens[0].end) < 1e-9)
        #expect(abs(tokens[1].end - 11.7) < 1e-9)
    }

    @Test func untimedLyricsHaveNoTokens() {
        #expect(Policy.tokens(text: "静止的歌词", syllables: nil, lineStart: nil, lineEnd: nil).isEmpty)
        #expect(Policy.tokens(text: "静止的歌词", syllables: nil, lineStart: 5, lineEnd: 5).isEmpty)
    }

    @Test func wordTimedLyricsKeepTheirOwnTiming() {
        let syllables = [
            LyricSyllable(text: "晴", start: 1, end: 1.3),
            LyricSyllable(text: "天", start: 1.3, end: 2.4),
        ]
        let tokens = Policy.tokens(text: "晴天", syllables: syllables, lineStart: 0, lineEnd: 9)
        #expect(tokens == [
            Policy.Token(text: "晴", start: 1, end: 1.3),
            Policy.Token(text: "天", start: 1.3, end: 2.4),
        ])
    }

    @Test func tokensEnterOneAfterAnotherBeforeTheFirstIsSung() {
        let tokens = [
            Policy.Token(text: "a", start: 10, end: 10.3),
            Policy.Token(text: "b", start: 10.3, end: 10.6),
            Policy.Token(text: "c", start: 10.6, end: 10.9),
        ]
        let early = Policy.appearances(for: tokens, exitStart: nil, at: 10 - Policy.entranceLead - 0.01, motion: true)
        #expect(early.allSatisfy { $0 == .hidden })

        let entering = Policy.appearances(for: tokens, exitStart: nil, at: 10 - Policy.entranceLead + 0.05, motion: true)
        #expect(entering[0].opacity > entering[1].opacity)
        #expect(entering[0].offset > 0 && entering[0].blur > 0 && entering[0].scale < 1)
        #expect(entering[2] == .hidden || entering[2].opacity < entering[1].opacity)
    }

    @Test func waitingTokensRestDimAndSungTokensLightUpWithAPulse() {
        // 入场从整句第一个字算起，到第二、第三个字时早已停稳。
        let tokens = [
            Policy.Token(text: "x", start: 8, end: 8.3),
            Policy.Token(text: "a", start: 10, end: 10.3),
            Policy.Token(text: "b", start: 11, end: 11.3),
        ]
        let now = Policy.appearances(for: tokens, exitStart: nil, at: 10.06, motion: true)
        // 还没唱到的字候场：半透明、不动、不发光。
        #expect(abs(now[2].opacity - Policy.waitingOpacity) < 0.01)
        #expect(abs(now[2].offset) < 0.01 && now[2].blur < 0.001 && now[2].glow == 0)
        // 正在唱的字点亮：放大、托起、发光。
        #expect(now[1].opacity > Policy.waitingOpacity)
        #expect(now[1].scale > 1 && now[1].offset < 0 && now[1].glow > 0.5)

        let later = Policy.appearances(for: tokens, exitStart: nil, at: 10.9, motion: true)
        #expect(later[1].opacity == 1)
        #expect(later[1].glow < 0.25)
        #expect(later[0].opacity == 1 && later[0].glow < 0.01)
    }

    @Test func longNotesStayHeldUntilTheyEnd() {
        let held = Policy.pulseStrength(sung: 1.2, duration: 1.6)
        let short = Policy.pulseStrength(sung: 1.2, duration: 0.3)
        #expect(abs(held - Policy.holdStrength) < 1e-9)
        #expect(short < 0.1)
        #expect(Policy.pulseStrength(sung: 2.4, duration: 1.6) < held)
        #expect(Policy.pulseStrength(sung: -0.1, duration: 1.6) == 0)
    }

    @Test func exitingLineFloatsUpBlursAndFadesOut() {
        let tokens = [
            Policy.Token(text: "a", start: 10, end: 10.3),
            Policy.Token(text: "b", start: 10.3, end: 10.6),
        ]
        let leaving = Policy.appearances(for: tokens, exitStart: 12, at: 12.2, motion: true)
        #expect(leaving[0].offset < 0 && leaving[0].blur > 0 && leaving[0].opacity < 1)
        #expect(leaving[1].opacity > leaving[0].opacity)
        let gone = Policy.appearances(
            for: tokens,
            exitStart: 12,
            at: 12 + Policy.exitSpan(tokenCount: tokens.count),
            motion: true
        )
        #expect(gone.allSatisfy { $0.opacity < 1e-9 })
    }

    @Test func withoutMotionTokensOnlyFade() {
        let tokens = [Policy.Token(text: "a", start: 10, end: 10.3)]
        for time in stride(from: 9.7, through: 12.6, by: 0.05) {
            let state = Policy.appearances(for: tokens, exitStart: 12, at: time, motion: false)[0]
            #expect(state.scale == 1 && state.offset == 0 && state.blur == 0 && state.glow == 0)
            #expect(state.opacity >= 0 && state.opacity <= 1)
        }
        #expect(Policy.appearances(for: tokens, exitStart: nil, at: 11, motion: false)[0].opacity == 1)
    }

    @Test func springOvershootsSlightlyAndSettles() {
        let samples = stride(from: 0.0, through: 1.2, by: 0.01).map(Policy.spring)
        let peak = samples.max() ?? 0
        #expect(peak > 1 && peak < 1.15)
        #expect(abs(Policy.spring(0.8) - 1) < 0.01)
        #expect(Policy.spring(0) == 0)
    }

    @Test func lineLeavesWithTheNextOneOrEarlyBeforeALongGap() {
        let tokens = [
            Policy.Token(text: "a", start: 10, end: 10.4),
            Policy.Token(text: "b", start: 10.4, end: 11),
        ]
        // 下一句紧接着来：赶在下一句入场前先走，但不早于自己最后一个字唱完。
        #expect(Policy.exitStart(of: tokens, nextLineStart: 12) == 12 - Policy.entranceLead - Policy.exitLead)
        #expect(Policy.exitStart(of: tokens, nextLineStart: 11.2) == 11)
        // 唱到下一句入场那一刻才完：和下一句入场同时走。
        #expect(Policy.exitStart(of: tokens, nextLineStart: 11.02) == 11.02 - Policy.entranceLead)
        // 隔得久：唱完停一会儿先走。
        #expect(Policy.exitStart(of: tokens, nextLineStart: 30) == 11 + Policy.holdAfterLine)
        // 最后一句一直留着。
        #expect(Policy.exitStart(of: tokens, nextLineStart: nil) == nil)
        #expect(Policy.exitStart(of: [], nextLineStart: 12) == nil)
    }

    @Test func interludeDotsShowOnlyInsideTheGap() {
        let exit = 12.6
        #expect(Policy.interludeVisibility(previousExit: nil, nextLineStart: 30, at: 20) == 0)
        #expect(Policy.interludeVisibility(previousExit: exit, nextLineStart: 30, at: exit) == 0)
        #expect(Policy.interludeVisibility(previousExit: exit, nextLineStart: 30, at: 20) == 1)
        #expect(Policy.interludeVisibility(previousExit: exit, nextLineStart: 30, at: 30) == 0)
        #expect(Policy.interludeVisibility(previousExit: exit, nextLineStart: nil, at: 40) == 1)
    }

    @Test func companionsFollowTheLine() {
        #expect(Policy.companionAppearance(lineStart: 10, exitStart: nil, at: 9, motion: true) == .hidden)
        let shown = Policy.companionAppearance(lineStart: 10, exitStart: nil, at: 11, motion: true)
        #expect(shown.opacity == 1 && shown.offset == 0 && shown.blur == 0)
        let leaving = Policy.companionAppearance(lineStart: 10, exitStart: 12, at: 12.2, motion: true)
        #expect(leaving.opacity < 1 && leaving.offset < 0)
    }

    @Test func fontSizeShrinksOnlyWhenTheLineDoesNotFit() {
        #expect(Policy.fontSize(for: "短句", base: 36, minimum: 20, availableWidth: 345, maximumLines: 3) == 36)
        // 十三个汉字：一个字一个字号宽，36 号在 345 宽里一行只放得下九个半，两行就放得下。
        let chinese = "我想就这样牵着你的手不放开"
        #expect(abs(Policy.estimatedWidth(of: chinese) - 13) < 1e-9)
        #expect(Policy.fontSize(for: chinese, base: 36, minimum: 20, availableWidth: 345, maximumLines: 1) < 36)
        #expect(Policy.fontSize(for: chinese, base: 36, minimum: 20, availableWidth: 345, maximumLines: 2) == 36)
        let long = String(repeating: "很长的一句歌词", count: 8)
        let fitted = Policy.fontSize(for: long, base: 36, minimum: 20, availableWidth: 345, maximumLines: 3)
        #expect(fitted == 20)
        // 拉丁字母窄：同样字数的英文不缩。
        #expect(Policy.fontSize(for: "Shape of you", base: 36, minimum: 20, availableWidth: 345, maximumLines: 1) == 36)
    }
}
