import Foundation
import Testing
@testable import PrimuseKit

@Suite("Kinetic lyrics rhythm scenes")
struct ImmersiveKineticRhythmTests {
    private typealias Chart = ImmersiveKineticRhythmChart

    /// 每 `period` 秒一下鼓点，按 60 帧喂给节拍钟，喂到 `until`。
    private func steadyClock(period: TimeInterval = 0.5, until end: TimeInterval = 6, offset: TimeInterval = 0.1) -> ImmersiveBeatClock {
        var clock = ImmersiveBeatClock()
        var nextBeat = offset
        var time = 0.0
        while time <= end {
            var beat = 0.0
            if time >= nextBeat {
                beat = 0.8
                nextBeat += period
            }
            clock.update(beat: beat, beatsPerSecond: time > 2 ? 1 / period : nil, steadiness: time > 2 ? 0.9 : 0, at: time)
            time += 1.0 / 60
        }
        return clock
    }

    // MARK: 节拍钟

    @Test func clockLocksOntoASteadyBeatAndPredictsTheNextOnes() throws {
        let clock = steadyClock()
        #expect(clock.isLocked)
        let predicted = clock.beats(from: 6.0, through: 7.6)
        #expect(predicted.count == 3)
        // 真实的拍子在 6.1、6.6、7.1；60 帧喂进去，晚到不超过一帧。
        for (index, beat) in predicted.enumerated() {
            #expect(abs(beat - (6.1 + 0.5 * Double(index))) < 0.025)
        }
        let position = try #require(clock.position(at: 6.6))
        #expect(abs(position - position.rounded()) < 0.05)
    }

    @Test func seekingForgetsWhereTheBeatIsButKeepsTheTempo() {
        var clock = steadyClock()
        let period = clock.period
        clock.update(beat: 0, beatsPerSecond: nil, steadiness: 0, at: 40)
        #expect(!clock.isLocked)
        #expect(clock.beats(from: 40, through: 42).isEmpty)
        #expect(clock.period == period)
    }

    @Test func clockStopsPredictingAfterTheDrumsStop() {
        var clock = steadyClock()
        var time = 6.0
        while time < 10 {
            clock.update(beat: 0, beatsPerSecond: nil, steadiness: 0, at: time)
            time += 1.0 / 60
        }
        #expect(!clock.isLocked)
    }

    @Test func offBeatHitsDoNotDragTheBeat() throws {
        var clock = steadyClock()
        let before = try #require(clock.beats(from: 6.5, through: 7.0).first)
        // 一下切分音落在两拍正中间。
        clock.update(beat: 0.9, beatsPerSecond: 2, steadiness: 0.9, at: 6.35)
        let after = try #require(clock.beats(from: 6.5, through: 7.0).first)
        #expect(abs(after - before) < 0.005)
        #expect(clock.isLocked)
    }

    // MARK: 谱面

    @Test func notesArriveAheadOfTheBeatAndNeverMoveOnceScheduled() throws {
        var clock = steadyClock()
        var chart = Chart(seed: 4)
        chart.update(clock: clock, cues: [], climax: 0, at: 6.0)
        let first = chart.notes
        #expect(!first.isEmpty)
        #expect(first.allSatisfy { $0.time > 6.0 + 0.3 && $0.time <= 6.0 + Chart.leadTime })
        // 拍子又被一下稍早的鼓点校准了一点：已经放上去的音符不动。
        clock.update(beat: 0.8, beatsPerSecond: 2, steadiness: 0.9, at: 6.08)
        chart.update(clock: clock, cues: [], climax: 0, at: 6.1)
        for note in first {
            #expect(chart.notes.contains { $0.time == note.time && $0.lane == note.lane })
        }
    }

    @Test func lyricCuesBecomeNotesWithoutABeat() {
        var chart = Chart(seed: 2)
        let cues: [TimeInterval] = [10.5, 10.62, 10.9, 11.3]
        chart.update(clock: ImmersiveBeatClock(), cues: cues, climax: 0, at: 10)
        // 10.62 离 10.5 太近，并掉。
        #expect(chart.notes.map(\.time) == [10.5, 10.9, 11.3])
        #expect(chart.notes.allSatisfy { $0.source == .lyric })
    }

    @Test func lateCuesAreSkippedAndPastNotesFadeOut() {
        var chart = Chart(seed: 2)
        chart.update(clock: ImmersiveBeatClock(), cues: [10.1, 11], climax: 0, at: 10)
        #expect(chart.notes.map(\.time) == [11])
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 11.5)
        #expect(chart.notes.count == 1)
        #expect(chart.hitCount == 1)
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 11.8)
        #expect(chart.notes.isEmpty)
    }

    @Test func notesHopBetweenLanesAndEachHandSwingsBackAndForth() {
        var chart = Chart(seed: 9)
        let cues = (0..<60).map { 2 + Double($0) * 0.3 }
        var time = 0.0
        var seen: [Chart.Note] = []
        while time < 20 {
            chart.update(clock: ImmersiveBeatClock(), cues: cues, climax: 0, at: time)
            for note in chart.notes where !seen.contains(note) { seen.append(note) }
            time += 1.0 / 30
        }
        seen.sort { $0.time < $1.time }
        #expect(seen.count == 60)
        for (previous, next) in zip(seen, seen.dropFirst()) {
            #expect(next.lane != previous.lane)
            #expect((0..<Chart.laneCount).contains(next.lane))
            #expect(next.time - previous.time >= Chart.minimumSpacing)
        }
        for hand in 0..<2 {
            let mine = seen.filter { $0.hand == hand }
            #expect(mine.allSatisfy { ($0.lane < Chart.laneCount / 2) == (hand == 0) })
            for (previous, next) in zip(mine, mine.dropFirst()) {
                #expect(previous.cut.vector.y * next.cut.vector.y < 0)
            }
        }
    }

    @Test func chorusAddsOffbeatsAndDoubleHits() {
        let clock = steadyClock()
        var calm = Chart(seed: 3)
        var chorus = Chart(seed: 3)
        var time = 6.0
        var calmTimes = Set<TimeInterval>()
        var chorusNotes: [Chart.Note] = []
        while time < 9 {
            calm.update(clock: clock, cues: [], climax: 0, at: time)
            chorus.update(clock: clock, cues: [], climax: 1, at: time)
            calm.notes.forEach { calmTimes.insert($0.time) }
            for note in chorus.notes where !chorusNotes.contains(note) { chorusNotes.append(note) }
            time += 1.0 / 30
        }
        #expect(Set(chorusNotes.map(\.time)).count > calmTimes.count + 2)
        let byTime = Dictionary(grouping: chorusNotes, by: \.time)
        let chords = byTime.values.filter { $0.count == 2 }
        #expect(!chords.isEmpty)
        #expect(chords.allSatisfy { Set($0.map(\.hand)) == [0, 1] })
    }

    @Test func seekingClearsTheChart() {
        var chart = Chart(seed: 1)
        chart.update(clock: ImmersiveBeatClock(), cues: [5.5, 6], climax: 0, at: 5)
        #expect(!chart.notes.isEmpty)
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 60)
        #expect(chart.notes.isEmpty)
        #expect(chart.hitCount == 0)
    }

    @Test func saberCutsThroughTheCubeCentreAlongItsArrowWithoutJumping() throws {
        var chart = Chart(seed: 5)
        let cues: [TimeInterval] = [3.0, 3.45, 3.9, 4.3, 5.4]
        chart.update(clock: ImmersiveBeatClock(), cues: cues, climax: 0, at: 2)
        var all: [Chart.Note] = chart.notes
        chart.update(clock: ImmersiveBeatClock(), cues: cues, climax: 0, at: 3.5)
        for note in chart.notes where !all.contains(note) { all.append(note) }
        chart.update(clock: ImmersiveBeatClock(), cues: cues, climax: 0, at: 4.2)
        for note in chart.notes where !all.contains(note) { all.append(note) }
        // 一次放全，好在同一份谱面上量整段挥剑。
        var whole = Chart(seed: 5)
        whole.update(clock: ImmersiveBeatClock(), cues: [3.0], climax: 0, at: 2)
        let note = try #require(whole.notes.first)
        let cube = Chart.cubePosition(lane: note.lane, row: note.row)
        let atHit = whole.aim(hand: note.hand, at: note.time)
        #expect(abs(atHit.x - cube.x) < 1e-6 && abs(atHit.y - cube.y) < 1e-6)
        let before = whole.aim(hand: note.hand, at: note.time - 0.05)
        let after = whole.aim(hand: note.hand, at: note.time + 0.05)
        let cut = note.cut.vector
        // 画面上 y 向下，瞄点坐标 y 向上。
        let along = (after.x - before.x) * cut.x - (after.y - before.y) * cut.y
        #expect(along > 0.15)
        // 每一帧挪得不多：一刀最快也只是十来帧挥过去。
        var time = 2.0
        var last = whole.aim(hand: note.hand, at: time)
        while time < 4 {
            time += 1.0 / 60
            let point = whole.aim(hand: note.hand, at: time)
            #expect(hypot(point.x - last.x, point.y - last.y) < 0.12)
            last = point
        }
        // 挥完一阵子垂回两侧，手微微晃着。
        let rest = Chart.restingAim(hand: note.hand)
        let resting = whole.aim(hand: note.hand, at: note.time + 2)
        #expect(hypot(resting.x - rest.x, resting.y - rest.y) < 0.04)
        let later = whole.aim(hand: note.hand, at: note.time + 2.4)
        #expect(hypot(later.x - resting.x, later.y - resting.y) > 0.002)
        #expect(all.count == cues.count)
    }

    @Test func packedChartCarriesNotesRelativeToNow() {
        var chart = Chart(seed: 5)
        chart.update(clock: ImmersiveBeatClock(), cues: [3.0, 3.5], climax: 0.2, at: 2)
        let props = chart.packed(clock: ImmersiveBeatClock(), climax: 0.2, at: 2)
        #expect(props.count == Chart.propsCapacity)
        #expect(props[0].x == -1)
        #expect(props[0].w == 2)
        #expect(abs(props[16].z - 1.0) < 1e-5)
        #expect(abs(props[18].z - 1.5) < 1e-5)
    }

    // MARK: 弹珠落音

    @Test func everyNoteBouncesABallOffABarRightWhereItIs() throws {
        var run = ImmersiveKineticMarbleRun(seed: 8)
        var time = 0.0
        for _ in 0..<40 {
            run.update(hits: [0, 0, 0], followsSpectrum: true, aspect: 0.5, at: time)
            time += 1.0 / 60
        }
        let before = run.balls[0]
        run.update(hits: [0.8, 0, 0], followsSpectrum: true, aspect: 0.5, at: time)
        let bar = try #require(run.bars.last)
        let ball = run.balls[0]
        #expect(bar.voice == 0)
        #expect(abs(hypot(bar.x - ball.x, bar.y - ball.y) - ball.radius * 1.15) < 1e-6)
        // 弹开以后离音条越来越远，而且是往上弹（掉下来撞的）。
        let normal = (x: cos(bar.angle), y: sin(bar.angle))
        #expect(ball.vx * normal.x + ball.vy * normal.y > 0)
        #expect(before.vy > 0 && ball.vy < 0)
        // 别的声部没有音，不弹。
        #expect(run.bars.count == 1)
    }

    @Test func aSteadyRhythmWalksTheBallDownStepByStepAndKeepsItInView() {
        var run = ImmersiveKineticMarbleRun(seed: 3)
        var time = 0.0
        var nextBeat = 0.5
        var heights: [Double] = []
        while time < 12 {
            var hits = [0.0, 0.0, 0.0]
            if time >= nextBeat {
                hits[1] = 0.6
                nextBeat += 0.5
            }
            run.update(hits: hits, followsSpectrum: true, aspect: 0.6, at: time)
            if hits[1] > 0 { heights.append(run.balls[1].y) }
            let ball = run.balls[1]
            if time > 3 {
                #expect(ball.y - run.cameraY > -0.1 && ball.y - run.cameraY < 1.0)
                #expect(ball.x >= 0 && ball.x <= 0.6)
            }
            time += 1.0 / 60
        }
        // 一个音往下一级：每一下都比上一下低，但不会一下掉一大截。
        let steps = zip(heights.dropFirst(5), heights.dropFirst(6)).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 > 0 && $0 < 0.15 })
        // 走过的台阶留在画面里，往上退出画面才收掉。
        let trail = run.bars.filter { $0.voice == 1 }
        #expect(trail.count >= 8)
        #expect(trail.allSatisfy { $0.y - run.cameraY > -0.3 })
    }

    @Test func lyricHitsGoToTheLowestBall() throws {
        var run = ImmersiveKineticMarbleRun(seed: 3)
        run.update(hits: [0, 0, 0], followsSpectrum: false, aspect: 0.5, at: 0)
        run.update(hits: [0, 0, 0], followsSpectrum: false, aspect: 0.5, at: 0.3)
        let lowest = try #require(run.balls.indices.max { run.balls[$0].y < run.balls[$1].y })
        run.update(hits: [0, 0.62, 0], followsSpectrum: false, aspect: 0.5, at: 0.32)
        #expect(run.bars.last?.voice == run.balls[lowest].voice)
    }

    @Test func pausingFreezesTheBallsAndSeekingStartsOver() {
        var run = ImmersiveKineticMarbleRun(seed: 3)
        run.update(hits: [0, 0, 0], followsSpectrum: true, aspect: 0.5, at: 1)
        run.update(hits: [0.9, 0.9, 0.9], followsSpectrum: true, aspect: 0.5, at: 1.2)
        let frozen = run.balls
        run.update(hits: [0, 0, 0], followsSpectrum: true, aspect: 0.5, at: 1.2)
        #expect(run.balls.map(\.y) == frozen.map(\.y))
        #expect(run.bars.count == 3)
        run.update(hits: [0, 0, 0], followsSpectrum: true, aspect: 0.5, at: 80)
        #expect(run.bars.isEmpty)
    }

    @Test func packedMarblesAreInViewCoordinates() {
        var run = ImmersiveKineticMarbleRun(seed: 3)
        var time = 0.0
        while time < 4 {
            run.update(hits: [0.5, 0.5, 0.6], followsSpectrum: true, aspect: 0.5, at: time)
            time += 0.2
        }
        let props = run.packed(at: time)
        #expect(props.count == ImmersiveKineticMarbleRun.propsCapacity)
        #expect(props[0].x == 3)
        #expect(Int(props[0].y) == min(run.bars.count, 52))
        #expect(abs(Double(props[1].y) - (run.balls[0].y - run.cameraY)) < 1e-4)
    }

    // MARK: 曲速跟着鼓点

    @Test func warpSurgesOnEachBeatAndCruisesSlowlyInBetween() {
        var conductor = ImmersiveKineticConductor(seed: 1)
        var time = 0.0
        var playback = 0.0
        var speeds: [(time: TimeInterval, speed: Double)] = []
        for frame in 0..<(60 * 12) {
            // 很响的歌：底子一直 0.7，每半秒一记重拍。
            let beat = frame % 30 == 0
            let levels = Array(repeating: beat ? 1.0 : 0.7, count: 32)
            let drive = conductor.update(levels: levels, lyricOnsets: [], playbackTime: playback, at: time)
            if time > 6 { speeds.append((time, drive.travelSpeed)) }
            time += 1.0 / 60
            playback += 1.0 / 60
        }
        let average = speeds.map(\.speed).reduce(0, +) / Double(speeds.count)
        let peak = speeds.map(\.speed).max() ?? 0
        let floor = speeds.map(\.speed).min() ?? 0
        // 以前很响的歌一直在 2 以上；现在平均慢一大截，拍上蹿、拍间滑行。
        #expect(average < 1.2)
        #expect(peak > floor * 2.2)
    }
}
