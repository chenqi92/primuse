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

    @Test func pulseIsTheSameForLongAndShortWords() {
        // 点亮那一下只看开唱后过了多久，长音不额外撑着。
        #expect(abs(Policy.pulseStrength(sung: Policy.pulseAttack) - 1) < 1e-9)
        #expect(Policy.pulseStrength(sung: 1.2) < 0.1)
        #expect(Policy.pulseStrength(sung: 2.4) < Policy.pulseStrength(sung: 1.2))
        #expect(Policy.pulseStrength(sung: -0.1) == 0)
        let long = [Policy.Token(text: "ooh", start: 10, end: 12)]
        let short = [Policy.Token(text: "a", start: 10, end: 10.2)]
        let longNow = Policy.appearances(for: long, exitStart: nil, at: 11.2, motion: true)[0]
        let shortNow = Policy.appearances(for: short, exitStart: nil, at: 11.2, motion: true)[0]
        #expect(longNow.glow == shortNow.glow)
        #expect(longNow.scale == shortNow.scale)
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
        // 两句之间只隔一下：不出那三个点。
        #expect(Policy.interludeVisibility(previousExit: 4.3, nextLineStart: 5.0, at: 4.7) == 0)
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

    private func line(_ text: String, start: Double = 10, step: Double = 0.3) -> [Policy.Token] {
        Policy.units(in: text).enumerated().map { index, unit in
            Policy.Token(text: unit, start: start + Double(index) * step, end: start + Double(index + 1) * step)
        }
    }

    @Test func charactersInALineStrikeDifferentlyWithHeroesAtTheEndAndTheBreak() {
        let tokens = line("让声音拥有自己，的光与形状")
        for seed: UInt64 in [1, 7, 42, 2026] {
            let strikes = Policy.strikes(for: tokens, accent: .glow, seed: seed)
            #expect(strikes.count == tokens.count)
            #expect(strikes.last == .hero)
            // 「己，」后面那个字是断句处，也是重点字；重点字不超过两个。
            #expect(strikes[7] == .hero)
            #expect(strikes.filter { $0 == .hero }.count == 2)
            // 不是每个字都一样：至少两种动作。
            #expect(Set(strikes.filter { $0 != .hero }.map { "\($0)" }).count >= 2)
            // 同一句同一个种子每次都一样。
            #expect(Policy.strikes(for: tokens, accent: .glow, seed: seed) == strikes)
        }
        // 只有一两个字的短句：最后一个字是重点字。
        #expect(Policy.strikes(for: line("爱"), accent: .glow, seed: 3) == [.hero])
        // 冲击字的歌只配上下的动作。
        let slam = Policy.strikes(for: line("我想就这样牵着你的手"), accent: .slam, seed: 9)
        #expect(slam.allSatisfy { [.drop, .rise, .hero].contains($0) })
    }

    @Test func strikesAndTheirMotionIgnoreHowLongACharacterIsSung() {
        // 同样的字，唱得长短不同（US12592007B2）：动作和唱到后同一时刻的样子都一样。
        let short = line("我想就这样牵着你的手", step: 0.2)
        let long = short.map { Policy.Token(text: $0.text, start: $0.start, end: $0.start + 2.5) }
        let strikes = Policy.strikes(for: short, accent: .glow, seed: 5)
        #expect(Policy.strikes(for: long, accent: .glow, seed: 5) == strikes)
        for offset in [-0.2, 0, 0.05, 0.15, 0.4, 1.2] {
            let time = short[3].start + offset
            let a = Policy.appearances(for: short, exitStart: nil, at: time, motion: true, choreography: .cascade, accent: .glow, strikes: strikes)
            let b = Policy.appearances(for: long, exitStart: nil, at: time, motion: true, choreography: .cascade, accent: .glow, strikes: strikes)
            #expect(a[3] == b[3])
        }
    }

    @Test func charactersWaitInTheirPoseAndSnapHomeWithoutJumping() {
        let tokens = line("让声音拥有自己的光与形状")
        for strike in [Policy.Strike.pop, .drop, .rise, .spin, .zoom, .hero] {
            let strikes = Array(repeating: strike, count: tokens.count)
            func look(_ time: Double) -> Policy.Appearance {
                Policy.appearances(for: tokens, exitStart: nil, at: time, motion: true, choreography: .wholeLine, accent: .glow, strikes: strikes)[4]
            }
            let start = tokens[4].start
            // 唱到那一刻前后两帧几乎一样：从候场姿势弹回去，不是一下跳过去。
            let before = look(start - 0.0005), after = look(start + 0.0005)
            #expect(abs(before.offset - after.offset) < 0.02)
            #expect(abs(before.rotation - after.rotation) < 1)
            #expect(abs(before.scale - after.scale) < 0.03)
            // 候场时不在原位（pop、hero 是小一圈）。
            #expect(abs(before.offset) > 0.1 || abs(before.rotation) > 5 || abs(before.scale - 1) > 0.1)
            // 唱过两秒停回原位。
            let rest = look(start + 2)
            #expect(abs(rest.offset) < 0.01 && abs(rest.rotation) < 0.3 && abs(rest.scale - 1) < 0.01 && rest.blur < 0.001)
            // 重点字唱过以后一直带着光。
            if strike == .hero { #expect(rest.glow >= Policy.heroSteadyGlow - 1e-9) }
        }
        // 竖排：上下的候场姿势改成左右。
        let dropped = Policy.appearances(
            for: tokens, exitStart: nil, at: tokens[4].start - 0.5, motion: true, choreography: .wholeLine,
            accent: .glow, strikes: Array(repeating: .drop, count: tokens.count), vertical: true
        )[4]
        #expect(abs(dropped.offsetX) > 0.1 && abs(dropped.offset) < 1e-9)
        // 动效关掉时不摆姿势。
        let still = Policy.appearances(
            for: tokens, exitStart: nil, at: tokens[4].start - 0.5, motion: false, choreography: .wholeLine,
            accent: .glow, strikes: Array(repeating: .spin, count: tokens.count)
        )[4]
        #expect(still.rotation == 0 && still.offset == 0 && still.scale == 1)
    }

    @Test func onlyHeroesShakeTheLineUnlessEveryCharacterSlams() {
        let tokens = line("我想就这样牵着你")
        let strikes = Policy.strikes(for: tokens, accent: .glow, seed: 11)
        let plain = tokens.indices.first { strikes[$0] != .hero }!
        let quiet = Policy.shake(for: tokens, strikes: strikes, at: tokens[plain].start + 0.05, motion: true)
        #expect(quiet.x == 0 && quiet.y == 0)
        let hit = Policy.shake(for: tokens, strikes: strikes, at: tokens[tokens.count - 1].start + 0.05, motion: true)
        #expect(hit.x != 0 || hit.y != 0)
        let slam = Policy.shake(for: tokens, at: tokens[plain].start + 0.05, motion: true)
        #expect(slam.x != 0 || slam.y != 0)
    }
}
