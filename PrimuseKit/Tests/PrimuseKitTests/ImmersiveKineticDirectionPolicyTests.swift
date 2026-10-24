import Foundation
import Testing
@testable import PrimuseKit

@Suite("Kinetic lyrics direction")
struct ImmersiveKineticDirectionPolicyTests {
    private typealias Policy = ImmersiveKineticDirectionPolicy

    // MARK: 选编排

    @Test func theSameSongAlwaysGetsTheSameDirection() {
        let first = Policy.direction(title: "夜航", artist: "柳川", album: "夜航", genre: "Pop")
        let again = Policy.direction(title: "夜航", artist: "柳川", album: "夜航", genre: "Pop")
        #expect(first == again)
    }

    @Test func differentSongsSpreadOverEveryScene() {
        var scenes = Set<ImmersiveKineticScene>()
        var transitions = Set<ImmersiveKineticTransition>()
        for index in 0..<200 {
            let direction = Policy.direction(title: "Song \(index)", artist: "A", album: "B", genre: "")
            scenes.insert(direction.scene)
            transitions.insert(direction.transition)
            #expect(direction.climaxTransition != direction.transition)
        }
        #expect(scenes == Set(ImmersiveKineticScene.allCases))
        #expect(transitions == Set(ImmersiveKineticTransition.allCases))
    }

    @Test func genreLeansTheSceneCalmOrLively() {
        func energeticShare(_ genre: String) -> Double {
            let count = (0..<300).filter { index in
                Policy.direction(title: "T\(index)", artist: "A", album: "B", genre: genre).scene.isEnergetic
            }.count
            return Double(count) / 300
        }
        #expect(energeticShare("Classical Piano") < 0.25)
        #expect(energeticShare("Hard Rock") > 0.65)
        #expect(Policy.temperament(of: "抒情摇滚") == .unknown)
        #expect(Policy.temperament(of: "古风") == .calm)
        #expect(Policy.temperament(of: "") == .unknown)
    }

    @Test func pondsAlwaysRippleAndLivelyScenesNeverUseTheCalmTransitions() {
        for index in 0..<300 {
            let direction = Policy.direction(title: "S\(index)", artist: "x", album: "y", genre: "")
            if direction.scene == .ripplePond { #expect(direction.accent == .ripple) }
            if direction.scene.isEnergetic {
                #expect([.whipPan, .crashZoom, .cascade].contains(direction.transition))
            } else {
                #expect([.cascade, .rackFocus, .iris, .stepPrint].contains(direction.transition))
            }
        }
    }

    // MARK: 镜头

    @Test func everyTransitionEndsInPlaceAndStartsOutOfSight() {
        for transition in ImmersiveKineticTransition.allCases where transition.movesWholeLine {
            let settled = Policy.entering(transition, progress: 1)
            #expect(abs(settled.offsetX) < 1e-9)
            #expect(abs(settled.scale - 1) < 1e-3)
            #expect(settled.blur < 1e-3)
            #expect(settled.opacity == 1)
            #expect((settled.iris ?? 1) == 1)

            let start = Policy.entering(transition, progress: 0)
            #expect(start.opacity == 0 || start.iris == 0)

            let gone = Policy.exiting(transition, progress: 1)
            #expect(gone.opacity < 1e-6 || gone.iris == 0)
            let staying = Policy.exiting(transition, progress: 0)
            #expect(staying.opacity == 1)
        }
    }

    @Test func whipPanFliesOutOneSideAndInFromTheOther() {
        let leaving = Policy.exiting(.whipPan, progress: 0.6, side: 1)
        let arriving = Policy.entering(.whipPan, progress: 0.3, side: 1)
        #expect(leaving.offsetX < 0)
        #expect(arriving.offsetX > 0)
        #expect(leaving.smear > 0.5)
        #expect(Policy.entering(.whipPan, progress: 0.3, side: -1).offsetX < 0)
    }

    @Test func onlyIdeographicLinesStandVertically() {
        #expect(Policy.suitsVerticalLayout("风起于青萍之末"))
        #expect(Policy.suitsVerticalLayout("夜に駆ける、2024"))
        #expect(!Policy.suitsVerticalLayout("我爱 you"))
        #expect(!Policy.suitsVerticalLayout("Hello"))
        #expect(!Policy.suitsVerticalLayout("好"))
    }

    @Test func verticalColumnsAreEvenAndRightSized() {
        #expect(Policy.verticalColumns(tokenCount: 0, perColumn: 6).isEmpty)
        #expect(Policy.verticalColumns(tokenCount: 5, perColumn: 6) == [0..<5])
        #expect(Policy.verticalColumns(tokenCount: 13, perColumn: 6) == [0..<5, 5..<10, 10..<13])
        #expect(Policy.verticalColumns(tokenCount: 8, perColumn: 2) == [0..<4, 4..<8])
    }

    @Test func stepPrintMovesInVisibleSteps() {
        let a = Policy.entering(.stepPrint, progress: 0.30)
        let b = Policy.entering(.stepPrint, progress: 0.33)
        let c = Policy.entering(.stepPrint, progress: 0.50)
        #expect(a == b)
        #expect(a != c)
        #expect(a.smear > 0)
    }

    @Test func climaxPushesTheBackgroundInAndBackWithALightLeak() {
        #expect(Policy.dollyZoom(sinceClimax: nil) == 1)
        #expect(Policy.dollyZoom(sinceClimax: Policy.dollyZoomSpan * 0.25) > 1.15)
        #expect(Policy.dollyZoom(sinceClimax: Policy.dollyZoomSpan) == 1)
        #expect(Policy.lightLeak(sinceClimax: nil).amount == 0)
        let middle = Policy.lightLeak(sinceClimax: Policy.lightLeakSpan / 2)
        #expect(middle.amount > 0.8)
        #expect(Policy.lightLeak(sinceClimax: Policy.lightLeakSpan + 1).amount == 0)
    }

    @Test func climaxIsMarkedWhenTheSongStaysLoud() {
        var conductor = ImmersiveKineticConductor(seed: 2)
        var time = 0.0
        var drive = ImmersiveKineticDrive()
        // 先安静十秒，再一直很响：排位升上去之后要撑过 1.5 秒才算进副歌。
        for frame in 0..<900 {
            let loud = frame >= 300
            let levels = Array(repeating: loud ? 0.85 : 0.1, count: 32)
            drive = conductor.update(levels: levels, lyricOnsets: [], playbackTime: nil, at: time)
            time += 1.0 / 30
        }
        #expect(drive.isClimax)
        #expect(drive.climaxStart != nil)
    }

    @Test func crashZoomStartsHugeAndRackFocusStartsBlurred() {
        #expect(Policy.entering(.crashZoom, progress: 0).scale > 2)
        #expect(Policy.exiting(.crashZoom, progress: 1).scale > 2)
        #expect(Policy.entering(.rackFocus, progress: 0).blur > 0.4)
        #expect(Policy.exiting(.rackFocus, progress: 1).blur > 0.4)
    }

    @Test func linesEnterSoTheFirstWordIsSungAsTheMoveFinishes() {
        for transition in ImmersiveKineticTransition.allCases where transition.movesWholeLine {
            let start = Policy.enterStart(firstTokenStart: 10, transition: transition)
            #expect(start < 10)
            #expect(start + Policy.enterDuration(transition) >= 10)
        }
    }

    @Test func irisAndCrashZoomWaitForTheOldLineWhilePansOverlap() {
        let iris = Policy.exitStart(lastTokenEnd: 5, nextEnterStart: 8, transition: .iris)
        #expect(iris == 8 - Policy.exitDuration(.iris))
        let pan = Policy.exitStart(lastTokenEnd: 5, nextEnterStart: 8, transition: .whipPan)
        #expect(pan == 8 - Policy.exitDuration(.whipPan) * 0.5)
        // 下一句紧接着来：最后一个字唱完才走，但不晚于下一句进场。
        let tight = Policy.exitStart(lastTokenEnd: 7.95, nextEnterStart: 8, transition: .iris)
        #expect(tight == 7.95)
        let overlapping = Policy.exitStart(lastTokenEnd: 8.4, nextEnterStart: 8, transition: .iris)
        #expect(overlapping == 8)
        // 隔得久：唱完停一会儿先走；最后一句不走。
        let gap = Policy.exitStart(lastTokenEnd: 5, nextEnterStart: 20, transition: .rackFocus)
        #expect(gap == 5 + ImmersiveKineticLyricsPolicy.holdAfterLine)
        #expect(Policy.exitStart(lastTokenEnd: 5, nextEnterStart: nil, transition: .iris) == nil)
    }

    // MARK: 指挥

    @Test func lyricOnsetsDriveTheSceneWithoutSpectrum() {
        var conductor = ImmersiveKineticConductor(seed: 7)
        let onsets: [TimeInterval] = [1.0, 1.4]
        var playback = 0.8
        var time = 100.0
        var sawEvent = false
        var peakPulse = 0.0
        for _ in 0..<40 {
            let drive = conductor.update(levels: [], lyricOnsets: onsets, playbackTime: playback, at: time)
            #expect(!drive.hasSpectrum)
            sawEvent = sawEvent || !drive.events.isEmpty
            peakPulse = max(peakPulse, drive.pulse)
            playback += 1.0 / 30
            time += 1.0 / 30
        }
        #expect(sawEvent)
        #expect(peakPulse > 0.9)
    }

    @Test func seekingDoesNotCountSkippedOnsets() {
        var conductor = ImmersiveKineticConductor(seed: 7)
        _ = conductor.update(levels: [], lyricOnsets: [5, 6, 7], playbackTime: 1, at: 0)
        let drive = conductor.update(levels: [], lyricOnsets: [5, 6, 7], playbackTime: 8, at: 0.033)
        #expect(drive.events.isEmpty)
    }

    @Test func lightningNeverFlashesMoreThanThreeTimesASecond() {
        var conductor = ImmersiveKineticConductor(seed: 3)
        var flashes = 0
        var previous = 0.0
        var time = 0.0
        var playback = 0.0
        // 每帧都越过一个字头：鼓点密得不像话。
        for frame in 0..<300 {
            let onset = playback + 0.01
            let drive = conductor.update(levels: [], lyricOnsets: [onset], playbackTime: playback + 0.02, at: time)
            if drive.flash == 1, previous < 1 { flashes += 1 }
            previous = drive.flash
            playback += 1.0 / 30
            time += 1.0 / 30
            _ = frame
        }
        // 十秒。
        #expect(flashes <= 23)
        #expect(flashes >= 10)
    }

    @Test func flashBlinksTwiceThenFades() {
        #expect(ImmersiveKineticConductor.flashEnvelope(age: 0.02) == 1)
        #expect(ImmersiveKineticConductor.flashEnvelope(age: 0.09) < 0.5)
        #expect(ImmersiveKineticConductor.flashEnvelope(age: 0.15) > 0.7)
        #expect(ImmersiveKineticConductor.flashEnvelope(age: 1) < 0.01)
        #expect(ImmersiveKineticConductor.flashEnvelope(age: -1) == 0)
    }

    @Test func travelKeepsGoingForwardWhateverTheEnergy() {
        var conductor = ImmersiveKineticConductor(seed: 1)
        var last = -1.0
        var time = 0.0
        for frame in 0..<90 {
            let level = frame % 15 == 0 ? 0.9 : 0.2
            let drive = conductor.update(
                levels: Array(repeating: level, count: 32),
                lyricOnsets: [],
                playbackTime: nil,
                at: time
            )
            #expect(drive.travel >= last)
            last = drive.travel
            time += 1.0 / 30
        }
        #expect(last > 0)
    }

    @Test func eventsAreCappedAndExpire() {
        var conductor = ImmersiveKineticConductor(seed: 9)
        var playback = 0.0
        var time = 0.0
        var drive = ImmersiveKineticDrive()
        for _ in 0..<60 {
            drive = conductor.update(levels: [], lyricOnsets: [playback + 0.01], playbackTime: playback + 0.02, at: time)
            playback += 0.1
            time += 0.1
        }
        #expect(drive.events.count <= ImmersiveKineticConductor.eventCapacity)
        for event in drive.events {
            #expect(event.x >= 0.12 && event.x <= 0.88)
            #expect(event.y >= 0.18 && event.y <= 0.84)
        }
        // 安静 5 秒后都散了。
        for _ in 0..<50 {
            drive = conductor.update(levels: [], lyricOnsets: [], playbackTime: playback, at: time)
            playback += 0.1
            time += 0.1
        }
        #expect(drive.events.isEmpty)
    }
}

@Suite("Kinetic lyrics accents")
struct ImmersiveKineticAccentTests {
    private typealias Lyrics = ImmersiveKineticLyricsPolicy
    private let tokens = [
        Lyrics.Token(text: "风", start: 10, end: 10.3),
        Lyrics.Token(text: "起", start: 10.3, end: 10.6),
    ]

    @Test func wholeLineTokensArriveTogetherAndStayUntilTheLineLeaves() {
        let arriving = Lyrics.appearances(
            for: tokens, exitStart: 10.7, at: 10.0, motion: true, choreography: .wholeLine, accent: .glow
        )
        #expect(arriving.allSatisfy { $0.offset <= 0 && $0.blur == 0 })
        let late = Lyrics.appearances(
            for: tokens, exitStart: 10.7, at: 12, motion: true, choreography: .wholeLine, accent: .glow
        )
        #expect(late.allSatisfy { $0.opacity == 1 })
    }

    @Test func rippleRingsSpreadOnceAfterEachWord() {
        let sung = Lyrics.appearances(
            for: tokens, exitStart: nil, at: 10.4, motion: true, choreography: .cascade, accent: .ripple
        )
        #expect(sung[0].ripple > 0 && sung[0].ripple < 1)
        #expect(sung[1].ripple > 0)
        let later = Lyrics.appearances(
            for: tokens, exitStart: nil, at: 12, motion: true, choreography: .cascade, accent: .ripple
        )
        #expect(later.allSatisfy { $0.ripple == 0 })
        let still = Lyrics.appearances(
            for: tokens, exitStart: nil, at: 10.4, motion: false, choreography: .cascade, accent: .ripple
        )
        #expect(still.allSatisfy { $0.ripple == 0 })
    }

    @Test func neonFlickersOnThenStaysLitAndGlitchFades() {
        let flicker = Lyrics.appearances(for: tokens, exitStart: nil, at: 10.07, motion: true, choreography: .cascade, accent: .neon)
        #expect(flicker[0].opacity < 0.5)
        let steady = Lyrics.appearances(for: tokens, exitStart: nil, at: 11.5, motion: true, choreography: .cascade, accent: .neon)
        #expect(steady.allSatisfy { $0.glow == Lyrics.neonSteadyGlow && $0.opacity == 1 })
        let glitching = Lyrics.appearances(for: tokens, exitStart: nil, at: 10.05, motion: true, choreography: .cascade, accent: .glitch)
        #expect(glitching[0].glitch > 0.5)
        let settled = Lyrics.appearances(for: tokens, exitStart: nil, at: 11, motion: true, choreography: .cascade, accent: .glitch)
        #expect(settled.allSatisfy { $0.glitch == 0 })
    }

    @Test func slamDropsFromLargeAndShakesTheLineBriefly() {
        #expect(Lyrics.slamScale(sung: -0.1) == 1)
        #expect(abs(Lyrics.slamScale(sung: 0) - Lyrics.slamInitialScale) < 1e-9)
        #expect(Lyrics.slamScale(sung: Lyrics.slamDrop) < 1)
        #expect(Lyrics.slamScale(sung: 1) == 1)
        let shaking = Lyrics.shake(for: tokens, at: 10.05, motion: true)
        #expect(abs(shaking.x) + abs(shaking.y) > 0)
        let calm = Lyrics.shake(for: tokens, at: 11.5, motion: true)
        #expect(calm.x == 0 && calm.y == 0)
        #expect(Lyrics.shake(for: tokens, at: 10.05, motion: false).x == 0)
    }

    @Test func accentsAreTheSameForLongAndShortWords() {
        let short = [Lyrics.Token(text: "a", start: 1, end: 1.1)]
        let long = [Lyrics.Token(text: "a", start: 1, end: 4)]
        for accent in ImmersiveKineticAccent.allCases {
            for time in stride(from: 1.0, through: 3.5, by: 0.25) {
                let a = Lyrics.appearances(for: short, exitStart: nil, at: time, motion: true, choreography: .cascade, accent: accent)
                let b = Lyrics.appearances(for: long, exitStart: nil, at: time, motion: true, choreography: .cascade, accent: accent)
                #expect(a == b)
            }
        }
    }
}
