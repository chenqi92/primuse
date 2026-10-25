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
        var stagings = Set<ImmersiveKineticStaging>()
        var extruded = 0
        for index in 0..<300 {
            let direction = Policy.direction(title: "Song \(index)", artist: "A", album: "B", genre: "")
            scenes.insert(direction.scene)
            transitions.insert(direction.transition)
            transitions.insert(direction.alternateTransition)
            stagings.insert(direction.staging)
            if direction.extruded { extruded += 1 }
            #expect(direction.climaxTransition != direction.transition)
            #expect(direction.climaxTransition != direction.alternateTransition)
            #expect(direction.alternateTransition != direction.transition)
        }
        #expect(scenes == Set(ImmersiveKineticScene.allCases))
        #expect(transitions == Set(ImmersiveKineticTransition.allCases))
        // 每首歌都有立体的机位，平视只留给动效关掉的时候。
        #expect(!stagings.contains(.flat))
        #expect(stagings == [.orbit, .tilted, .vertical, .dutch])
        #expect(extruded > 60 && extruded < 240)
    }

    @Test func twoUsualMovesTakeTurnsLineByLine() {
        let direction = Policy.direction(title: "交替", artist: "A", album: "B", genre: "")
        #expect(direction.usualTransition(forLine: 4) == direction.transition)
        #expect(direction.usualTransition(forLine: 5) == direction.alternateTransition)
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
        let lively: Set<ImmersiveKineticTransition> = [.whipPan, .crashZoom, .cubeFlip, .flyThrough, .spiral, .shatter]
        let calm: Set<ImmersiveKineticTransition> = [.cascade, .rackFocus, .iris, .stepPrint, .cubeFlip, .flyThrough]
        for index in 0..<300 {
            let direction = Policy.direction(title: "S\(index)", artist: "x", album: "y", genre: "")
            if direction.scene == .ripplePond { #expect(direction.accent == .ripple) }
            let pool = direction.scene.isEnergetic ? lively : calm
            #expect(pool.contains(direction.transition))
            #expect(pool.contains(direction.alternateTransition))
        }
    }

    // MARK: 镜头

    @Test func everyTransitionEndsInPlaceAndStartsOutOfSight() {
        for transition in ImmersiveKineticTransition.allCases where transition.choreography == .wholeLine {
            let settled = Policy.entering(transition, progress: 1)
            #expect(abs(settled.offsetX) < 1e-9)
            #expect(abs(settled.offsetY) < 1e-9)
            #expect(abs(settled.scale - 1) < 1e-3)
            #expect(settled.blur < 1e-3)
            #expect(settled.opacity == 1)
            #expect((settled.iris ?? 1) == 1)
            #expect(abs(settled.rotationX) < 1e-6 && abs(settled.rotationY) < 1e-6 && abs(settled.rotationZ) < 1e-6)

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

    @Test func verticalLinesUseTallColumnsAndSplitOnlyWhenNeeded() {
        // 放得下就一列，不缩字。
        let short = Policy.verticalLayout(tokenCount: 6, availableHeight: 600, preferredFontSize: 60, minimumFontSize: 30)
        #expect(short.columns == [0..<6])
        #expect(short.fontSize == 60)
        // 横屏矮：一列要缩到一半多，不如分两列。
        let tight = Policy.verticalLayout(tokenCount: 12, availableHeight: 300, preferredFontSize: 35, minimumFontSize: 18)
        #expect(tight.columns == [0..<6, 6..<12])
        #expect(tight.fontSize > 35 * 0.8 - 1e-9)
        // 一列每个字至少放得下：不会切成一列只有几个字。
        #expect(tight.columns.allSatisfy { $0.count >= 4 })
        // 很长的一句最多三列，字号不低于下限。
        let long = Policy.verticalLayout(tokenCount: 40, availableHeight: 300, preferredFontSize: 35, minimumFontSize: 18)
        #expect(long.columns.count == 3)
        #expect(long.fontSize >= 18)
        #expect(long.columns.flatMap { Array($0) } == Array(0..<40))
    }

    @Test func verticalSongsRollLikeAScroll() {
        // 当前句（第 5 句）十秒开唱，下一句十四秒：十三秒多开始往下一句卷，十四秒卷到。
        func position(_ time: Double) -> Double {
            Policy.scrollPosition(activeID: 5, activeFirst: 10, upcomingFirst: 14, at: time)
        }
        #expect(position(12) == 5)
        #expect(position(13.5) > 5 && position(13.5) < 6)
        #expect(position(14.1) == 6)
        // 下一句成了当前句以后接着同一个位置，不跳。
        let handedOver = Policy.scrollPosition(activeID: 6, activeFirst: 14, upcomingFirst: 18, at: 13.8)
        #expect(abs(handedOver - position(13.8)) < 1e-9)
        // 正中最亮，唱过的那句停在右边变淡，再往前的淡没；新的一句从左边淡进来。
        #expect(Policy.scrollOpacity(distance: 0) == 1)
        #expect(abs(Policy.scrollOpacity(distance: 1) - Policy.scrollRestingOpacity) < 1e-9)
        #expect(Policy.scrollRestingOpacity < ImmersiveKineticLyricsPolicy.waitingOpacity - 0.1)
        #expect(Policy.scrollOpacity(distance: 1.8) == 0)
        #expect(Policy.scrollOpacity(distance: -1) == 0)
        #expect(Policy.scrollOpacity(distance: -0.5) > 0.3)
    }

    @Test func stepPrintMovesInVisibleSteps() {
        let a = Policy.entering(.stepPrint, progress: 0.30)
        let b = Policy.entering(.stepPrint, progress: 0.33)
        let c = Policy.entering(.stepPrint, progress: 0.50)
        #expect(a == b)
        #expect(a != c)
        #expect(a.smear > 0)
    }

    @Test func chorusPushesTheBackgroundInSlowlyAndHoldsIt() throws {
        #expect(Policy.backgroundZoom(climaxPush: 0) == 1)
        #expect(abs(Policy.backgroundZoom(climaxPush: 1) - (1 + Policy.climaxZoom)) < 1e-9)
        #expect(Policy.warmGlow(climaxPush: 0) == 0)
        #expect(Policy.warmGlow(climaxPush: 1) > 0.3)
        // 进副歌后背景是慢慢推上去的：起步那一秒推得很少，之后一直推着，不弹回来。
        var conductor = ImmersiveKineticConductor(seed: 2)
        var time = 0.0
        var zooms: [Double] = []
        var enteredAt: Int?
        for frame in 0..<1200 {
            let loud = frame >= 300
            let drive = conductor.update(
                levels: Array(repeating: loud ? 0.85 : 0.1, count: 32), lyricOnsets: [], playbackTime: nil, at: time
            )
            if drive.isClimax, enteredAt == nil { enteredAt = frame }
            zooms.append(Policy.backgroundZoom(climaxPush: drive.climaxPush))
            time += 1.0 / 30
        }
        let start = try #require(enteredAt)
        #expect(zooms[start + 15] - 1 < Policy.climaxZoom * 0.2)
        #expect(zooms.last! > 1 + Policy.climaxZoom * 0.95)
        for (earlier, later) in zip(zooms, zooms.dropFirst()) {
            #expect(later >= earlier - 1e-12)
            #expect(later - earlier < 0.002)
        }
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

    @Test func cubeFlipTurnsBothFacesTogetherAroundAnAxisBehindTheWords() {
        // 新句从下面那一面翻上来、旧句往上翻走，两句同时转：旧句的出场正好在新句进场那一刻开始。
        #expect(Policy.entering(.cubeFlip, progress: 0).rotationX == -90)
        #expect(Policy.exiting(.cubeFlip, progress: 1).rotationX == 90)
        #expect(Policy.entering(.cubeFlip, progress: 0.5).depth > 0)
        let exit = Policy.exitStart(lastTokenEnd: 5, nextEnterStart: 8, transition: .cubeFlip)
        #expect(exit == 8)
    }

    @Test func threeDimensionalMovesComeFromDepthOrTheSide() {
        let far = Policy.entering(.flyThrough, progress: 0)
        #expect(far.scale < 0.2)
        #expect(far.rotationX > 30)
        #expect(Policy.exiting(.flyThrough, progress: 0.9).scale > 3)
        let spiral = Policy.entering(.spiral, progress: 0.2, side: 1)
        #expect(spiral.rotationZ < -10 && spiral.rotationY > 10 && spiral.scale < 1)
        // 碎裂时整句不动，交给每个字。
        #expect(Policy.entering(.shatter, progress: 0.3) == .identity)
        #expect(ImmersiveKineticTransition.shatter.choreography == .scatter)
    }

    @Test func eachLineGetsItsOwnCameraAngleAndTheCameraKeepsMovingSmoothly() {
        func pose(_ line: Int, _ time: Double, swell: Double = 0) -> ImmersiveKineticCameraPose {
            Policy.camera(
                staging: .orbit, lineIndex: line, seed: 0.3, time: time,
                swell: swell, climax: 0, sungFraction: 0, amplitude: 1, motion: true
            )
        }
        #expect(abs(pose(3, 10).yaw - pose(4, 10).yaw) > 10)
        // 一帧之间角度只挪一点点。
        #expect(abs(pose(3, 10).yaw - pose(3, 10 + 1.0 / 60).yaw) < 0.2)
        #expect(pose(3, 10, swell: 1).scale > pose(3, 10).scale + 0.03)
        let still = Policy.camera(
            staging: .orbit, lineIndex: 3, seed: 0.3, time: 10,
            swell: 1, climax: 1, sungFraction: 1, amplitude: 1, motion: false
        )
        #expect(still == .level)
        let flat = Policy.camera(
            staging: .flat, lineIndex: 3, seed: 0.3, time: 10,
            swell: 0, climax: 0, sungFraction: 0, amplitude: 1, motion: true
        )
        #expect(flat.yaw == 0 && flat.roll == 0 && flat.pitch == 0)
        let dutchA = Policy.camera(
            staging: .dutch, lineIndex: 2, seed: 0.3, time: 10,
            swell: 0, climax: 0, sungFraction: 0, amplitude: 1, motion: true
        )
        let dutchB = Policy.camera(
            staging: .dutch, lineIndex: 3, seed: 0.3, time: 10,
            swell: 0, climax: 0, sungFraction: 0, amplitude: 1, motion: true
        )
        #expect(dutchA.roll * dutchB.roll < 0)
    }

    @Test func extrudedWordsShowTheirSideTowardTheNearEdge() {
        let level = Policy.extrusion(for: .level)
        #expect(abs((level.dx * level.dx + level.dy * level.dy).squareRoot() - Policy.extrusionDepth) < 1e-9)
        #expect(level.dy > 0)
        let turned = Policy.extrusion(for: ImmersiveKineticCameraPose(yaw: 20))
        #expect(turned.dx < level.dx)
        let tilted = Policy.extrusion(for: ImmersiveKineticCameraPose(yaw: -20, pitch: 20))
        #expect(tilted.dx > level.dx)
    }

    @Test func crashZoomStartsHugeAndRackFocusStartsBlurred() {
        #expect(Policy.entering(.crashZoom, progress: 0).scale > 2)
        #expect(Policy.exiting(.crashZoom, progress: 1).scale > 2)
        #expect(Policy.entering(.rackFocus, progress: 0).blur > 0.4)
        #expect(Policy.exiting(.rackFocus, progress: 1).blur > 0.4)
    }

    @Test func linesEnterSoTheFirstWordIsSungAsTheMoveFinishes() {
        // 碎裂时字飞回来的时间由字自己算，这里只看整句的镜头。
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
        // 两三帧冲上去，不是一帧跳满。
        #expect(peakPulse > 0.75)
    }

    @Test func seekingDoesNotCountSkippedOnsets() {
        var conductor = ImmersiveKineticConductor(seed: 7)
        _ = conductor.update(levels: [], lyricOnsets: [5, 6, 7], playbackTime: 1, at: 0)
        let drive = conductor.update(levels: [], lyricOnsets: [5, 6, 7], playbackTime: 8, at: 0.033)
        #expect(drive.events.isEmpty)
    }

    @Test func lightningWaitsForThePreviousBoltToFade() {
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
        // 十秒：每道闪电之间至少 0.7 秒，下一道劈下来时上一道已经熄了。
        #expect(flashes <= 15)
        #expect(flashes >= 10)
        #expect(ImmersiveKineticConductor.flashEnvelope(age: ImmersiveKineticConductor.minimumFlashInterval) < 0.03)
    }

    @Test func swellAndClimaxChangeGraduallySoNothingJumps() {
        var conductor = ImmersiveKineticConductor(seed: 4)
        var time = 0.0
        var previous = ImmersiveKineticDrive()
        var first = true
        // 先安静十秒，再很响、每半秒一记重拍。
        for frame in 0..<1200 {
            let loud = frame >= 300
            let kick = loud && frame % 15 == 0
            let level = loud ? (kick ? 0.95 : 0.7) : 0.1
            let drive = conductor.update(
                levels: Array(repeating: level, count: 32), lyricOnsets: [], playbackTime: nil, at: time
            )
            if !first {
                #expect(abs(drive.swell - previous.swell) < 0.5)
                #expect(abs(drive.climaxLevel - previous.climaxLevel) < 0.1)
                #expect(drive.flow > previous.flow)
                #expect(drive.flow - previous.flow < 0.1)
            }
            first = false
            previous = drive
            time += 1.0 / 30
        }
        #expect(previous.isClimax)
        #expect(previous.climaxLevel > 0.9)
    }

    @Test func briefSilenceDoesNotFlipBetweenSpectrumAndLyrics() {
        var conductor = ImmersiveKineticConductor(seed: 5)
        var time = 0.0
        var drive = ImmersiveKineticDrive()
        for _ in 0..<60 {
            drive = conductor.update(levels: Array(repeating: 0.5, count: 32), lyricOnsets: [], playbackTime: nil, at: time)
            time += 1.0 / 30
        }
        #expect(drive.hasSpectrum)
        // 半秒没声音：还算有频谱。
        for _ in 0..<15 {
            drive = conductor.update(levels: [], lyricOnsets: [], playbackTime: nil, at: time)
            time += 1.0 / 30
        }
        #expect(drive.hasSpectrum)
        // 两秒没声音：改跟歌词。
        for _ in 0..<60 {
            drive = conductor.update(levels: [], lyricOnsets: [], playbackTime: nil, at: time)
            time += 1.0 / 30
        }
        #expect(!drive.hasSpectrum)
    }

    @Test func eventsAreSpacedSoNoneIsPushedOutWhileVisible() {
        var conductor = ImmersiveKineticConductor(seed: 8)
        var playback = 0.0
        var time = 0.0
        var drive = ImmersiveKineticDrive()
        for _ in 0..<200 {
            drive = conductor.update(levels: [], lyricOnsets: [playback + 0.01], playbackTime: playback + 0.02, at: time)
            playback += 0.05
            time += 0.05
        }
        let times = drive.events.map(\.time)
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier >= ImmersiveKineticConductor.minimumEventInterval - 1e-9)
        }
        #expect(drive.events.count <= ImmersiveKineticConductor.eventCapacity)
    }

    @Test func onsetsAreReportedOnlyWhileFollowingTheSpectrum() {
        var conductor = ImmersiveKineticConductor(seed: 3)
        var time = 0.0
        var heard = 0
        for frame in 0..<300 {
            let level = frame % 15 == 0 ? 0.95 : 0.3
            let drive = conductor.update(levels: Array(repeating: level, count: 32), lyricOnsets: [], playbackTime: nil, at: time)
            if drive.onset > 0 { heard += 1 }
            time += 1.0 / 30
        }
        #expect(heard >= 10)
        var lyricOnly = ImmersiveKineticConductor(seed: 3)
        var playback = 0.0
        for _ in 0..<60 {
            let drive = lyricOnly.update(levels: [], lyricOnsets: [playback + 0.01], playbackTime: playback + 0.02, at: playback)
            #expect(drive.onset == 0)
            playback += 0.1
        }
    }

    @Test func aNewSongCarriesOnFromWhereTheSceneWas() {
        var conductor = ImmersiveKineticConductor(seed: 6)
        var time = 0.0
        var drive = ImmersiveKineticDrive()
        for _ in 0..<90 {
            drive = conductor.update(levels: Array(repeating: 0.6, count: 32), lyricOnsets: [], playbackTime: nil, at: time)
            time += 1.0 / 30
        }
        var next = ImmersiveKineticConductor(seed: 99, continuing: drive, at: time)
        let carried = next.update(levels: [], lyricOnsets: [], playbackTime: nil, at: time + 1.0 / 30)
        #expect(carried.travel >= drive.travel)
        #expect(carried.travel - drive.travel < 0.2)
        #expect(carried.flow >= drive.flow)
        #expect(carried.events == drive.events)
        // 上一首读得到频谱，这一首一开始就算读得到。
        #expect(carried.hasSpectrum == drive.hasSpectrum)
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

    @Test func lineTimedWordsFollowTheHeardOnsets() {
        // 逐行歌词按字数摊开：十个字、每 0.3 秒一个，句尾 13 秒。
        let even = Lyrics.tokens(text: "一二三四五六七八九十", syllables: nil, lineStart: 10, lineEnd: 10 + 3.0 / 0.85)
        #expect(even.count == 10)
        let end = even.map(\.end).max()!
        // 先唱得快（0.15 秒一个），后面拖长：字跟着起音的快慢走。
        let onsets: [TimeInterval] = [10.15, 10.3, 10.45, 10.6, 11.5, 12.4]
        let timed = Lyrics.rhythmTokens(even, onsets: onsets)
        #expect(timed[0].start == 10)
        #expect(abs(timed[1].start - 10.15) < 1e-9)
        #expect(abs(timed[2].start - 10.3) < 1e-9)
        // 不比按字数摊开的时刻早一个字以上：第四个字的起音（10.45）太早，等到第三个字的时刻。
        #expect(abs(timed[3].start - even[2].start) < 1e-9)
        // 起音隔得久时字照样往下走（最晚拖一个半字），整句仍在句尾前唱完。
        for index in timed.indices.dropFirst() {
            #expect(timed[index].start >= timed[index - 1].start + Lyrics.rhythmMinimumGap - 1e-9)
            #expect(timed[index].start >= even[index - 1].start - 1e-9)
            #expect(timed[index].start <= max(even[index].start + 0.3 * Lyrics.rhythmLag, timed[index - 1].start + Lyrics.rhythmMinimumGap) + 1e-9)
        }
        #expect(timed.last!.start <= end - Lyrics.rhythmMinimumGap + 1e-9)
        // 退场时刻不变（最后一个字的句尾）。
        #expect(timed.map(\.end).max() == end)
        // 已经亮了的字不会因为后来听到的起音再变。
        let later = Lyrics.rhythmTokens(even, onsets: onsets + [12.6, 12.7])
        for index in timed.indices where timed[index].start <= 12.4 {
            #expect(later[index].start == timed[index].start)
        }
        // 没有起音时退回按字数摊开、最多晚一个半字。
        let silent = Lyrics.rhythmTokens(even, onsets: [])
        #expect(silent.last!.start <= end - Lyrics.rhythmMinimumGap + 1e-9)
    }

    @Test func withoutSpectrumALineTimedLineLightsAsOne() {
        let even = Lyrics.tokens(text: "一二三四五六七八九十", syllables: nil, lineStart: 10, lineEnd: 14)
        let whole = Lyrics.wholeLineTokens(even)
        #expect(whole.first!.start == 10)
        #expect(whole.last!.start <= 10.35 + 1e-9)
        #expect(whole.allSatisfy { $0.end == even.map(\.end).max() })
    }

    @Test func shatteredWordsFlyHomeThenBurstApart() {
        let line = [
            Lyrics.Token(text: "碎", start: 10, end: 10.3),
            Lyrics.Token(text: "成", start: 10.3, end: 10.6),
            Lyrics.Token(text: "光", start: 10.6, end: 11.0),
        ]
        func look(_ time: Double, exit: Double? = 11.2) -> [Lyrics.Appearance] {
            Lyrics.appearances(for: line, exitStart: exit, at: time, motion: true, choreography: .scatter, accent: .glow)
        }
        // 飞回来的路上：离原位还远、带着转、迎面放大。
        let flying = look(9.55)
        #expect(flying.contains { abs($0.offsetX) + abs($0.offset) > 0.5 })
        #expect(flying.contains { abs($0.rotation) > 20 })
        #expect(flying.allSatisfy { $0.scale >= 1 || $0.opacity == 0 })
        // 唱的时候都回到原位。
        let home = look(10.65)
        #expect(home.allSatisfy { abs($0.offsetX) < 0.02 && abs($0.offset) < 0.2 && abs($0.rotation) < 2 })
        // 炸开：往四面飞，各不相同。
        let burst = look(11.45)
        #expect(burst.allSatisfy { abs($0.offsetX) + abs($0.offset) > 0.8 })
        #expect(Set(burst.map { ($0.offsetX * 100).rounded() }).count == 3)
        let gone = look(11.2 + Lyrics.scatterBurst + Lyrics.scatterJitter + 0.01)
        #expect(gone.allSatisfy { $0.opacity < 1e-6 })
        // 动效关掉时只淡入淡出，不飞。
        let still = Lyrics.appearances(for: line, exitStart: 11.2, at: 9.6, motion: false, choreography: .scatter, accent: .glow)
        #expect(still.allSatisfy { $0.offsetX == 0 && $0.rotation == 0 })
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
