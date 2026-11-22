import Foundation
import Testing
@testable import PrimuseKit

@Suite("Watercolor theater keywords")
struct ImmersiveTheaterKeywordTests {
    @Test func lyricsPickTheMatchingScene() {
        #expect(ImmersiveTheaterKeywords.template(in: "今夜的月亮") == .night)
        #expect(ImmersiveTheaterKeywords.template(in: "雨一直下") == .rain)
        #expect(ImmersiveTheaterKeywords.template(in: "春天的花开了") == .flower)
        #expect(ImmersiveTheaterKeywords.template(in: "Under the MOONLIGHT") == .night)
        #expect(ImmersiveTheaterKeywords.template(in: "tears in my eyes") == .rain)
        #expect(ImmersiveTheaterKeywords.template(in: "Let's start again") == nil)
        #expect(ImmersiveTheaterKeywords.template(in: "") == nil)
    }

    @Test func lyricsPickTheImagery() {
        #expect(ImmersiveTheaterKeywords.imagery(in: "I love you") == .love)
        #expect(ImmersiveTheaterKeywords.imagery(in: "我喜欢你") == .love)
        #expect(ImmersiveTheaterKeywords.imagery(in: "擦干眼泪") == .tears)
        #expect(ImmersiveTheaterKeywords.imagery(in: "雨夜") == .rain)
        #expect(ImmersiveTheaterKeywords.imagery(in: "满天星") == .moon)
        #expect(ImmersiveTheaterKeywords.imagery(in: "a crystal glass") == nil)
        #expect(ImmersiveTheaterKeywords.imagery(in: "the stars tonight") == .moon)
    }

    @Test func englishWordsMatchWholeWordsOnly() {
        #expect(ImmersiveTheaterKeywords.contains("stars above", word: "star"))
        #expect(!ImmersiveTheaterKeywords.contains("start over", word: "star"))
        #expect(!ImmersiveTheaterKeywords.contains("a train", word: "rain"))
        #expect(ImmersiveTheaterKeywords.contains("rainbow", word: "rain"))
        #expect(ImmersiveTheaterKeywords.contains("下雨", word: "雨"))
    }
}

@Suite("Watercolor theater cast")
struct ImmersiveTheaterCastTests {
    @Test func leadSingerIsAlwaysInTheMiddle() {
        for seed in UInt64(1)...UInt64(64) {
            let cast = ImmersiveTheaterCast.plan(seed: seed &* 0x9E37_79B9)
            #expect(cast.contains { $0.character == .yuanyin && $0.slot == .lead })
            #expect((2...4).contains(cast.count))
            #expect(Set(cast.map(\.slot)).count == cast.count)
            #expect(Set(cast.map(\.character)).count == cast.count)
            // 由后往前画。
            let depths = cast.map(\.slot.depth)
            #expect(depths == depths.sorted())
        }
    }

    @Test func castIsStablePerSongAndVariesAcrossSongs() {
        let first = ImmersiveTheaterCast.plan(seed: ImmersiveRandom.seed(for: "Song A"))
        #expect(first == ImmersiveTheaterCast.plan(seed: ImmersiveRandom.seed(for: "Song A")))
        var sizes = Set<Int>()
        for index in 0..<200 {
            sizes.insert(ImmersiveTheaterCast.plan(seed: ImmersiveRandom.seed(for: "song \(index)")).count)
        }
        #expect(sizes == [2, 3, 4])
    }
}

@Suite("Watercolor theater judgement")
struct ImmersiveTheaterJudgementTests {
    @Test func moodFollowsTempoBrightnessAndLoudness() {
        #expect(ImmersiveTheaterConductor.classifyMood(beatsPerMinute: 120, brightness: 0.6, intensity: 0.5) == .happy)
        #expect(ImmersiveTheaterConductor.classifyMood(beatsPerMinute: 80, brightness: 0.3, intensity: 0.5) == .sad)
        #expect(ImmersiveTheaterConductor.classifyMood(beatsPerMinute: 90, brightness: 0.5, intensity: 0.4) == .tender)
        #expect(ImmersiveTheaterConductor.classifyMood(beatsPerMinute: 115, brightness: 0.3, intensity: 0.5) == .neutral)
    }

    @Test func grooveBandsHaveHysteresis() {
        func groove(_ current: ImmersiveTheaterGroove, _ bpm: Double, stability: Double = 0.8) -> ImmersiveTheaterGroove {
            ImmersiveTheaterConductor.groove(
                current: current, beatsPerMinute: bpm, stability: stability,
                onsetRate: 3, intensity: 0.6, isLocked: true
            )
        }
        #expect(groove(.mid, 86) == .slow)
        #expect(groove(.mid, 90) == .mid)
        #expect(groove(.slow, 90) == .slow)
        #expect(groove(.mid, 130) == .fast)
        #expect(groove(.mid, 123) == .mid)
        #expect(groove(.fast, 123) == .fast)
        #expect(groove(.mid, 110, stability: 0.3) == .unsteady)
        #expect(ImmersiveTheaterConductor.groove(
            current: .mid, beatsPerMinute: 110, stability: 0.1, onsetRate: 0.5, intensity: 0.6, isLocked: false
        ) == .float)
        #expect(ImmersiveTheaterConductor.groove(
            current: .mid, beatsPerMinute: 110, stability: 0.9, onsetRate: 3, intensity: 0.2, isLocked: false
        ) == .float)
    }

    @Test func decibelProxyInvertsTheSpectrumScale() {
        #expect(abs(ImmersiveTheaterConductor.decibels(fromLevel: 0) + 72) < 1e-9)
        #expect(abs(ImmersiveTheaterConductor.decibels(fromLevel: 1) + 8) < 1e-9)
        let middle = ImmersiveTheaterConductor.decibels(fromLevel: pow(0.5, 0.72))
        #expect(abs(middle + 40) < 1e-6)
    }
}

@Suite("Watercolor theater conductor")
struct ImmersiveTheaterConductorTests {
    private static let frame = 1.0 / 30

    private func features(energy: Double, intensity: Double) -> ImmersiveAudioFeatures {
        var value = ImmersiveAudioFeatures()
        value.energy = energy
        value.intensity = intensity
        value.registerIntensity = [0.6, 0.6, 0.6]
        value.registerLevels = [energy * 0.9, energy * 0.8, energy * 0.6]
        return value
    }

    /// 能量换成频谱条的电平（`decibels(fromLevel:)` 的反函数）。
    private func level(decibels: Double) -> Double {
        pow(min(max((decibels + 72) / 64, 0), 1), 0.72)
    }

    @Test func pausingLooksAtTheCameraThenSnores() {
        var conductor = ImmersiveTheaterConductor()
        let look = conductor.update(ImmersiveTheaterInput(time: 0, playbackTime: 40, isPlaying: false, features: nil))
        #expect(look.playback == .look)
        let stillLooking = conductor.update(ImmersiveTheaterInput(time: 3, playbackTime: 40, isPlaying: false, features: nil))
        #expect(stillLooking.playback == .look)
        #expect(abs(stillLooking.pausedFor - 3) < 1e-9)
        let snore = conductor.update(ImmersiveTheaterInput(time: 7, playbackTime: 40, isPlaying: false, features: nil))
        #expect(snore.playback == .snore)
        #expect(!snore.roles.drum)
        let resumed = conductor.update(ImmersiveTheaterInput(time: 7.1, playbackTime: 40, isPlaying: true, features: nil))
        #expect(resumed.playback == .playing)
    }

    @Test func withoutSpectrumTheLeadSingsAlongWithTheLyrics() {
        var conductor = ImmersiveTheaterConductor()
        let cue = ImmersiveTheaterLyricCue(id: 3, text: "雨下个不停", start: 0, end: 10)
        var beats = 0
        var state = ImmersiveTheaterState()
        var mouths: [Double] = []
        for step in 0..<90 {
            let time = Double(step) * Self.frame
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: time, isPlaying: true, features: nil,
                lyric: cue, hasLyrics: true, firstLyricStart: 0
            ))
            if state.events.beat { beats += 1 }
            mouths.append(state.mouth)
        }
        #expect(state.timbre == .vocal)
        #expect(state.groove == .mid)
        #expect(state.imagery == .rain)
        #expect(!state.hasSpectrum)
        #expect((4...5).contains(state.beatIndex))
        #expect((3...5).contains(beats))
        #expect(mouths.allSatisfy { (0...1).contains($0) })
        #expect((mouths.max() ?? 0) - (mouths.min() ?? 0) > 0.3)
    }

    @Test func withoutSpectrumTheIntroLastsUntilTheFirstLine() {
        var conductor = ImmersiveTheaterConductor()
        var state = ImmersiveTheaterState()
        for step in 0..<60 {
            let time = Double(step) * Self.frame
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: time, isPlaying: true, features: nil, hasLyrics: true, firstLyricStart: 10
            ))
        }
        #expect(state.arc == .intro)
        var time = 2.0
        while time < 11 {
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: time, isPlaying: true, features: nil, hasLyrics: true, firstLyricStart: 10
            ))
            time += Self.frame
        }
        #expect(state.arc == .normal)
    }

    @Test func aLoudSectionBecomesTheClimaxThenCoolsDown() {
        var conductor = ImmersiveTheaterConductor()
        var state = ImmersiveTheaterState()
        var entered = 0
        var time = 0.0
        while time < 6 {
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: 30 + time, isPlaying: true,
                features: features(energy: 0.8, intensity: 0.95)
            ))
            if state.arcEnter, state.arc == .climax { entered += 1 }
            time += Self.frame
        }
        #expect(state.arc == .climax)
        #expect(entered == 1)
        #expect(state.roles.drum)
        #expect(state.roles.cast)
        var sawCooldown = false
        while time < 16 {
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: 30 + time, isPlaying: true,
                features: features(energy: 0.8, intensity: 0.3)
            ))
            if state.arc == .cooldown { sawCooldown = true }
            time += Self.frame
        }
        #expect(sawCooldown)
        #expect(state.arc == .normal)
    }

    @Test func aSuddenDropFreezesOnceThenRecovers() {
        var conductor = ImmersiveTheaterConductor()
        var state = ImmersiveTheaterState()
        var time = 0.0
        while time < 5 {
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: 30 + time, isPlaying: true,
                features: features(energy: 0.85, intensity: 0.6)
            ))
            time += Self.frame
        }
        #expect(state.arc == .normal)
        var quietFrames = 0
        var enteredQuiet = 0
        let dropStart = time
        while time < dropStart + 8 {
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: 30 + time, isPlaying: true,
                features: features(energy: 0.2, intensity: 0.6)
            ))
            if state.arc == .quiet { quietFrames += 1 }
            if state.arcEnter, state.arc == .quiet { enteredQuiet += 1 }
            time += Self.frame
        }
        #expect(enteredQuiet == 1)
        #expect(quietFrames > 30)
        #expect(state.arc == .normal)
    }

    @Test func aSteadyCrescendoBuildsUp() {
        var conductor = ImmersiveTheaterConductor()
        var state = ImmersiveTheaterState()
        var sawBuild = false
        var progress = 0.0
        var time = 0.0
        while time < 9 {
            let decibels = -45 + 1.5 * time
            state = conductor.update(ImmersiveTheaterInput(
                time: time, playbackTime: 30 + time, isPlaying: true,
                features: features(energy: level(decibels: decibels), intensity: 0.6)
            ))
            if state.arc == .build {
                sawBuild = true
                progress = max(progress, state.buildProgress)
            }
            time += Self.frame
        }
        #expect(sawBuild)
        #expect(progress > 0.2)
    }
}

@Suite("Watercolor theater shots")
struct ImmersiveTheaterShotTests {
    @Test func plannerIsDeterministicAndStartsWide() {
        let planner = ImmersiveTheaterShotPlanner(seed: 42)
        #expect(planner.shot(index: 0, lyricText: nil, previous: nil).framing == .wide)
        #expect(planner.shot(index: 5, lyricText: "x", previous: nil) == planner.shot(index: 5, lyricText: "x", previous: nil))
        #expect(Set(planner.rotation) == Set(ImmersiveTheaterTemplate.allCases))
    }

    @Test func keywordsChooseTheSceneAndRepeatsChangeTheVariant() {
        let planner = ImmersiveTheaterShotPlanner(seed: 7)
        let first = planner.shot(index: 3, lyricText: "雨一直下", previous: nil)
        #expect(first.template == .rain)
        #expect(first.chosenByLyric)
        let second = planner.shot(index: 4, lyricText: "听雨的声音", previous: first)
        #expect(second.template == .rain)
        #expect(second.variant != first.variant)
    }

    @Test func rotationAvoidsRepeatingTheSameScene() {
        let planner = ImmersiveTheaterShotPlanner(seed: 99)
        for index in 0..<12 {
            let previous = ImmersiveTheaterShot(
                index: index - 1,
                template: planner.rotation[index % 3],
                variant: 0,
                framing: .wide,
                transition: .brush,
                chosenByLyric: false
            )
            let shot = planner.shot(index: index, lyricText: "la la la", previous: previous)
            #expect(shot.template != previous.template)
            #expect(!shot.chosenByLyric)
        }
    }

    @Test func eachLyricLineCutsUnlessItCameTooSoon() throws {
        var director = ImmersiveTheaterShotDirector(seed: 11)
        func cut(at time: TimeInterval, line id: Int, start: TimeInterval) -> ImmersiveTheaterCut? {
            let cue = ImmersiveTheaterLyricCue(id: id, text: "line \(id)", start: start)
            return director.update(playbackTime: time, lyric: cue, hasLyrics: true, beatIndex: 0, isBeat: false, isStable: false)
        }
        let firstCut = cut(at: 0, line: 0, start: 0)
        let first = try #require(firstCut)
        #expect(first.immediate)
        #expect(first.shot.index == 0)
        let tooSoon = cut(at: 1, line: 1, start: 1)
        #expect(tooSoon == nil)
        let secondCut = cut(at: 4, line: 2, start: 4)
        let second = try #require(secondCut)
        #expect(!second.immediate)
        #expect(second.shot.index == 1)
        let sameLine = cut(at: 5, line: 2, start: 4)
        #expect(sameLine == nil)
        let merged = cut(at: 6, line: 3, start: 6)
        #expect(merged == nil)
        let thirdCut = cut(at: 8, line: 4, start: 8)
        let third = try #require(thirdCut)
        #expect(third.shot.index == 2)
        let seekCut = cut(at: 60, line: 20, start: 59)
        let seek = try #require(seekCut)
        #expect(seek.immediate)
    }

    @Test func withoutLyricsEveryThirtyTwoBeatsOrSixteenSeconds() {
        var steady = ImmersiveTheaterShotDirector(seed: 3)
        _ = steady.update(playbackTime: 0, lyric: nil, hasLyrics: false, beatIndex: 0, isBeat: true, isStable: true)
        var cutAt: Int?
        for beat in 1...40 {
            if steady.update(
                playbackTime: Double(beat) * 0.5, lyric: nil, hasLyrics: false,
                beatIndex: beat, isBeat: true, isStable: true
            ) != nil, cutAt == nil {
                cutAt = beat
            }
        }
        #expect(cutAt == 32)

        var loose = ImmersiveTheaterShotDirector(seed: 3)
        _ = loose.update(playbackTime: 0, lyric: nil, hasLyrics: false, beatIndex: 0, isBeat: false, isStable: false)
        var cutTime: Double?
        for second in 1...20 {
            if loose.update(
                playbackTime: Double(second), lyric: nil, hasLyrics: false,
                beatIndex: 0, isBeat: false, isStable: false
            ) != nil, cutTime == nil {
                cutTime = Double(second)
            }
        }
        #expect(cutTime == 17)
    }
}

@Suite("Watercolor theater performer")
struct ImmersiveTheaterPerformerTests {
    private func member(_ character: ImmersiveTheaterCharacter, _ slot: ImmersiveTheaterSlot) -> ImmersiveTheaterCast.Member {
        ImmersiveTheaterCast.Member(character: character, slot: slot, personality: .lively, phase: 0.25)
    }

    @Test func firstTapGreetsAndASecondTapSoonAfterIsShy() {
        var performer = ImmersiveTheaterPerformer(member: member(.xiaohei, .left), seed: 1)
        let firstTap = performer.receivePoke(at: 0)
        let secondTap = performer.receivePoke(at: 1)
        let laterTap = performer.receivePoke(at: 10)
        #expect(firstTap == .greet)
        #expect(secondTap == .shy)
        #expect(laterTap == .greet)
    }

    @Test func climaxJumpCrouchesFliesAndLands() {
        var performer = ImmersiveTheaterPerformer(member: member(.yuanyin, .lead), seed: 1)
        var state = ImmersiveTheaterState()
        state.arc = .climax
        state.groove = .mid
        var highest = 0.0
        var lowestSquash = 1.0
        var landedDust = false
        var time = 0.5
        for step in 0..<45 {
            state.arcEnter = step == 0
            state.arcTime = Double(step) / 30
            let spawns = performer.perform(state, time: time, dt: 1.0 / 30, moonOnLeft: nil)
            if spawns.contains(.dust(count: 3)) { landedDust = true }
            highest = max(highest, performer.pose.airborne)
            if step < 6 { lowestSquash = min(lowestSquash, performer.pose.bones["root"]?.stretchB ?? 1) }
            time += 1.0 / 30
        }
        #expect(highest > 0.3)
        #expect(lowestSquash < 0.97)
        #expect(landedDust)
        #expect(performer.pose.airborne < 0.05)
    }

    @Test func pausedLeadTakesOffTheGlassesAndSnoresLater() {
        var performer = ImmersiveTheaterPerformer(member: member(.yuanyin, .lead), seed: 1)
        var state = ImmersiveTheaterState()
        state.playback = .look
        var time = 0.2
        for step in 0..<60 {
            state.pausedFor = 2 + Double(step) / 30
            _ = performer.perform(state, time: time, dt: 1.0 / 30, moonOnLeft: nil)
            time += 1.0 / 30
        }
        #expect((performer.pose.bones["glasses"]?.ty ?? 0) < -100)
        #expect((performer.pose.bones["phones"]?.tx ?? 0) > 100)
        state.playback = .snore
        state.pausedFor = 8
        let spawns = performer.perform(state, time: time, dt: 1.0 / 30, moonOnLeft: nil)
        #expect(spawns.contains(.snore(size: 1.2)))
        #expect(performer.pose.expression.eyes == .closed)
        #expect(performer.pose.props.bubble != nil)
    }

    @Test func rolesBringOutTheirProps() {
        var drummer = ImmersiveTheaterPerformer(member: member(.xiaohei, .left), seed: 2)
        var donkey = ImmersiveTheaterPerformer(member: member(.xiaohuolv, .right), seed: 2)
        var state = ImmersiveTheaterState()
        state.roles = ImmersiveTheaterRoles(drum: true, cast: false, donkey: .lie)
        var time = 0.2
        for _ in 0..<60 {
            _ = drummer.perform(state, time: time, dt: 1.0 / 30, moonOnLeft: nil)
            _ = donkey.perform(state, time: time, dt: 1.0 / 30, moonOnLeft: nil)
            time += 1.0 / 30
        }
        #expect(drummer.pose.props.drums)
        #expect(donkey.pose.props.carrot)
        #expect(donkey.pose.lie > 0.5)
    }

    @Test func springOvershootsWhenUnderdamped() {
        var spring = ImmersiveTheaterSpring(value: 0, stiffness: 120, damping: 6)
        spring.target = 1
        var peak = 0.0
        for _ in 0..<60 {
            spring.step(1.0 / 30)
            peak = max(peak, spring.value)
        }
        #expect(peak > 1.05)
        #expect(abs(spring.value - 1) < 0.2)
    }
}
