import Foundation
import Testing
@testable import PrimuseKit

@Suite("Kinetic lyrics rhythm scenes")
struct ImmersiveKineticRhythmTests {
    private typealias Chart = ImmersiveKineticRhythmChart

    private func cues(_ starts: [TimeInterval]) -> [Chart.Cue] { starts.map { Chart.Cue(start: $0) } }

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
        chart.update(clock: ImmersiveBeatClock(), cues: cues([10.5, 10.62, 10.9, 11.3]), climax: 0, at: 10)
        // 10.62 离 10.5 太近，并掉。
        #expect(chart.notes.map(\.time) == [10.5, 10.9, 11.3])
        #expect(chart.notes.allSatisfy { $0.source == .lyric })
    }

    @Test func lateCuesAreSkippedAndPastNotesFadeOut() {
        var chart = Chart(seed: 2)
        chart.update(clock: ImmersiveBeatClock(), cues: cues([10.1, 11]), climax: 0, at: 10)
        #expect(chart.notes.map(\.time) == [11])
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 11.5)
        #expect(chart.notes.count == 1)
        #expect(chart.hitCount == 1)
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 11.8)
        #expect(chart.notes.isEmpty)
    }

    @Test func notesHopBetweenLanesAndEachHandSwingsBackAndForth() {
        var chart = Chart(seed: 9)
        let starts = cues((0..<60).map { 2 + Double($0) * 0.3 })
        var time = 0.0
        var seen: [Chart.Note] = []
        while time < 20 {
            chart.update(clock: ImmersiveBeatClock(), cues: starts, climax: 0, at: time)
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
        chart.update(clock: ImmersiveBeatClock(), cues: cues([5.5, 6]), climax: 0, at: 5)
        #expect(!chart.notes.isEmpty)
        chart.update(clock: ImmersiveBeatClock(), cues: [], climax: 0, at: 60)
        #expect(chart.notes.isEmpty)
        #expect(chart.hitCount == 0)
    }

    @Test func saberCutsThroughTheCubeCentreAlongItsArrowWithoutJumping() throws {
        var chart = Chart(seed: 5)
        let starts = cues([3.0, 3.45, 3.9, 4.3, 5.4])
        chart.update(clock: ImmersiveBeatClock(), cues: starts, climax: 0, at: 2)
        var all: [Chart.Note] = chart.notes
        chart.update(clock: ImmersiveBeatClock(), cues: starts, climax: 0, at: 3.5)
        for note in chart.notes where !all.contains(note) { all.append(note) }
        chart.update(clock: ImmersiveBeatClock(), cues: starts, climax: 0, at: 4.2)
        for note in chart.notes where !all.contains(note) { all.append(note) }
        // 一次放全，好在同一份谱面上量整段挥剑。
        var whole = Chart(seed: 5)
        whole.update(clock: ImmersiveBeatClock(), cues: cues([3.0]), climax: 0, at: 2)
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
        #expect(all.count == starts.count)
    }

    @Test func packedChartCarriesNotesRelativeToNow() {
        var chart = Chart(seed: 5)
        chart.update(clock: ImmersiveBeatClock(), cues: [Chart.Cue(start: 3.0), Chart.Cue(start: 3.5, duration: 0.9)], climax: 0.2, at: 2)
        let props = chart.packed(clock: ImmersiveBeatClock(), climax: 0.2, at: 2)
        #expect(props.count == Chart.propsCapacity)
        #expect(props[0].x == -1)
        #expect(props[0].w == 2)
        // 每个音符三组：第二个音符从 19 起，长短在第三组。
        #expect(abs(props[16].z - 1.0) < 1e-5)
        #expect(props[18].x == 0)
        #expect(abs(props[19].z - 1.5) < 1e-5)
        #expect(abs(props[21].x - 0.9) < 1e-5)
    }

    // MARK: 长音

    @Test func longWordsBecomeHoldsThatKeepTheirHandBusy() throws {
        var chart = Chart(seed: 11)
        let lyric = [Chart.Cue(start: 10.5, duration: 1.2), Chart.Cue(start: 10.7), Chart.Cue(start: 10.9), Chart.Cue(start: 11.3)]
        var time = 9.0
        var seen: [Chart.Note] = []
        while time < 12 {
            chart.update(clock: ImmersiveBeatClock(), cues: lyric, climax: 0, at: time)
            for note in chart.notes where !seen.contains(where: { $0.time == note.time && $0.lane == note.lane }) { seen.append(note) }
            time += 1.0 / 30
        }
        let hold = try #require(seen.first { $0.time == 10.5 })
        #expect(abs(hold.duration - 1.2) < 1e-9)
        // 按着长音的那只手在放开以前不再来音符；别的音符都去了另一只手。
        let sameHand = seen.filter { $0.hand == hold.hand && $0.time > hold.time }
        #expect(sameHand.allSatisfy { $0.time >= hold.end + Chart.holdRelease - 1e-9 })
        #expect(seen.contains { $0.hand != hold.hand && $0.time > hold.time && $0.time < hold.end })
        // 短的字不算长音。
        #expect(seen.filter { $0.time != 10.5 }.allSatisfy { !$0.isHold })
    }

    @Test func aHoldIsShortenedToEndBeforeTheNextNoteOfItsHand() {
        var chart = Chart(seed: 2)
        // 先放好的两个音符把两只手在 11 秒前后都占着，再来一个想拖两秒的长音。
        chart.update(clock: ImmersiveBeatClock(), cues: [Chart.Cue(start: 11.0), Chart.Cue(start: 11.2)], climax: 0, at: 9.6)
        chart.update(clock: ImmersiveBeatClock(), cues: [Chart.Cue(start: 11.0), Chart.Cue(start: 11.2), Chart.Cue(start: 10.0, duration: 2)], climax: 0, at: 9.62)
        if let hold = chart.notes.first(where: { $0.time == 10.0 }), hold.isHold {
            let next = chart.notes.filter { $0.hand == hold.hand && $0.time > hold.time }.map(\.time).min() ?? .infinity
            #expect(hold.end + Chart.holdRelease <= next + 1e-9)
        }
    }

    @Test func sparsePassagesHoldTheDownbeat() {
        let clock = steadyClock()
        var chart = Chart(seed: 3)
        var time = 6.0
        var seen: [Chart.Note] = []
        while time < 10 {
            chart.update(clock: clock, cues: [], climax: 0, sparse: true, at: time)
            for note in chart.notes where !seen.contains(where: { $0.time == note.time && $0.lane == note.lane }) { seen.append(note) }
            time += 1.0 / 30
        }
        let holds = seen.filter(\.isHold)
        #expect(!holds.isEmpty)
        #expect(holds.allSatisfy { abs($0.duration - clock.period * 2) < 1e-6 && $0.strength == 1 })
    }

    @Test func theSaberRestsOnAHoldThenFlicksAway() throws {
        var chart = Chart(seed: 5)
        chart.update(clock: ImmersiveBeatClock(), cues: [Chart.Cue(start: 3, duration: 1)], climax: 0, at: 1.8)
        let note = try #require(chart.notes.first)
        #expect(note.isHold)
        let cube = Chart.cubePosition(lane: note.lane, row: note.row)
        let atHead = chart.aim(hand: note.hand, at: 3)
        #expect(hypot(atHead.x - cube.x, atHead.y - cube.y) < 1e-6)
        // 按着时剑尖一直贴在方块那儿（绕一个小圈）。
        for step in 1..<10 {
            let point = chart.aim(hand: note.hand, at: 3 + Double(step) * 0.1)
            #expect(hypot(point.x - cube.x, point.y - cube.y) < 0.05)
        }
        // 放开以后顺着箭头甩出去。
        let flicked = chart.aim(hand: note.hand, at: 4 + 0.11)
        #expect(hypot(flicked.x - cube.x, flicked.y - cube.y) > 0.2)
        // 每一帧都挪得不多。
        var time = 2.6
        var last = chart.aim(hand: note.hand, at: time)
        while time < 4.6 {
            time += 1.0 / 60
            let point = chart.aim(hand: note.hand, at: time)
            #expect(hypot(point.x - last.x, point.y - last.y) < 0.12)
            last = point
        }
    }

    // MARK: 弹珠落音

    private func note(_ time: TimeInterval, lane: Int = 0, duration: TimeInterval = 0) -> Chart.Note {
        Chart.Note(time: time, lane: lane, row: 0, hand: lane < 2 ? 0 : 1, cut: .down, strength: 0.8, source: .beat, placed: time - 1.5, duration: duration)
    }

    /// 按 60 帧跑一段，`notes` 按谱面的样子提前 1.5 秒才给出来。
    private func run(
        _ marble: inout ImmersiveKineticMarbleRun,
        notes all: [Chart.Note],
        from start: TimeInterval,
        to end: TimeInterval,
        each: (inout ImmersiveKineticMarbleRun, TimeInterval) -> Void = { _, _ in }
    ) {
        var time = start
        while time <= end {
            let visible = all.filter { $0.time <= time + Chart.leadTime && $0.end >= time - Chart.afterglow }
            marble.update(notes: visible, hits: [0, 0, 0], aspect: 0.5, at: time)
            each(&marble, time)
            time += 1.0 / 60
        }
    }

    @Test func oneBallLandsOnEachNoteOnABarThatWasWaitingForIt() {
        var marble = ImmersiveKineticMarbleRun(seed: 4)
        let notes = (0..<30).map { note(2 + Double($0) * 0.5, lane: $0 % 4) }
        var firstSeen: [Int: TimeInterval] = [:]
        var contacts: Set<Int> = []
        var lastPosition: SIMD2<Double>?
        run(&marble, notes: notes, from: 0, to: 17) { marble, time in
            for pad in marble.pads where pad.kind == .bounce {
                let key = Int((pad.contact * 1000).rounded())
                if firstSeen[key] == nil { firstSeen[key] = time }
            }
            contacts.insert(Int((marble.ball.lastContact * 1000).rounded()))
            // 从头到尾就这一颗球：每帧挪一点点，不会凭空跳到别处；一直在画面里。
            let position = SIMD2(marble.ball.x, marble.ball.y)
            if let lastPosition { #expect(hypot(position.x - lastPosition.x, position.y - lastPosition.y) < 0.06) }
            lastPosition = position
            #expect(marble.ball.y - marble.cameraY > 0.05 && marble.ball.y - marble.cameraY < 0.9)
            #expect(marble.ball.x - marble.cameraX > 0 && marble.ball.x - marble.cameraX < 0.5)
        }
        for note in notes {
            let key = Int((note.time * 1000).rounded())
            // 每个音都碰到了，音条提前大半秒就在那儿等着。
            #expect(contacts.contains(key))
            #expect((firstSeen[key].map { note.time - $0 } ?? 0) > 0.6)
        }
        // 音条按轨道分颜色。
        #expect(Set(marble.pads.filter { $0.kind == .bounce }.map(\.lane)).count == 4)
    }

    @Test func aBallTouchesTheBarExactlyWhenTheNoteSounds() throws {
        var marble = ImmersiveKineticMarbleRun(seed: 9)
        let notes = [note(1.0), note(1.43), note(2.0)]
        run(&marble, notes: notes, from: 0, to: 1.0 - 1.0 / 60)
        let pad = try #require(marble.pads.first { abs($0.contact - 1.0) < 1e-9 })
        // 走到恰好那一刻：球心离音条正好一个半径多一点，而且是朝着音条的那一面。
        marble.update(notes: notes, hits: [0, 0, 0], aspect: 0.5, at: 1.0)
        let normal = SIMD2(cos(pad.angle), sin(pad.angle))
        let offset = SIMD2(marble.ball.x - pad.x, marble.ball.y - pad.y)
        #expect(abs(hypot(offset.x, offset.y) - marble.ball.radius * 1.15) < 1e-6)
        #expect(offset.x * normal.x + offset.y * normal.y > 0)
    }

    @Test func aLongNoteRollsTheBallDownARampForItsLength() throws {
        var marble = ImmersiveKineticMarbleRun(seed: 5)
        let notes = [note(1.0), note(1.5, duration: 1.2), note(3.2)]
        var onRamp: [Double] = []
        run(&marble, notes: notes, from: 0, to: 3.5) { marble, time in
            guard time > 1.55, time < 2.65,
                  let ramp = marble.pads.first(where: { $0.kind == .ramp }) else { return }
            // 滚的时候球心一直在坡面上方一个半径。
            let direction = SIMD2(cos(ramp.angle), sin(ramp.angle))
            let rel = SIMD2(marble.ball.x - ramp.x, marble.ball.y - ramp.y)
            onRamp.append(abs(rel.x * direction.y - rel.y * direction.x))
        }
        let ramp = try #require(marble.pads.first { $0.kind == .ramp })
        #expect(abs(ramp.contact - 1.5) < 1e-9 && abs(ramp.duration - 1.2) < 1e-9)
        #expect(!onRamp.isEmpty)
        #expect(onRamp.allSatisfy { abs($0 - marble.ball.radius) < 1e-6 })
        // 坡后面那个音照样接住。
        #expect(abs(marble.ball.lastContact - 3.2) < 1e-9)
    }

    @Test func aLongSilenceLaysGlidesSoTheBallNeverJustPlummets() {
        var marble = ImmersiveKineticMarbleRun(seed: 6)
        let notes = [note(1.0), note(6.0)]
        var flying = 0.0
        var longestFlight = 0.0
        var lastContact = 0.0
        run(&marble, notes: notes, from: 0.5, to: 6.5) { marble, time in
            if marble.ball.lastContact != lastContact {
                lastContact = marble.ball.lastContact
                flying = 0
            }
            let rolling = marble.pads.contains { $0.kind != .bounce && time >= $0.contact && time <= $0.contact + $0.duration }
            flying = rolling ? 0 : flying + 1.0 / 60
            if time > 1.2 { longestFlight = max(longestFlight, flying) }
        }
        #expect(marble.pads.contains { $0.kind == .glide })
        #expect(longestFlight < 1.0)
        #expect(abs(marble.ball.lastContact - 6.0) < 1e-9)
    }

    @Test func withoutAChartHeardOnsetsBounceTheBallOnTheSpot() {
        var marble = ImmersiveKineticMarbleRun(seed: 3)
        marble.update(notes: [], hits: [0, 0, 0], aspect: 0.5, at: 0)
        marble.update(notes: [], hits: [0, 0, 0], aspect: 0.5, at: 0.3)
        marble.update(notes: [], hits: [0.8, 0, 0], aspect: 0.5, at: 0.32)
        #expect(marble.pads.contains { $0.kind == .bounce && abs($0.contact - 0.32) < 1e-9 })
        #expect(marble.ball.vy < 0)
    }

    @Test func pausingFreezesTheBallAndSeekingStartsOver() {
        var marble = ImmersiveKineticMarbleRun(seed: 3)
        let notes = [note(1.0), note(1.5)]
        run(&marble, notes: notes, from: 0, to: 1.2)
        let frozen = marble.ball
        marble.update(notes: notes, hits: [0, 0, 0], aspect: 0.5, at: 1.2 - 1.0 / 60 + 1.0 / 60)
        #expect(abs(marble.ball.y - frozen.y) < 0.02)
        marble.update(notes: [], hits: [0, 0, 0], aspect: 0.5, at: 80)
        // 从头来：之前的音条都没了（没有音时只会垫缓坡）。
        #expect(marble.pads.allSatisfy { $0.kind == .glide })
        #expect(marble.pads.allSatisfy { $0.contact > 80 })
    }

    @Test func packedMarbleIsInViewCoordinates() {
        var marble = ImmersiveKineticMarbleRun(seed: 3)
        let notes = (0..<8).map { note(1 + Double($0) * 0.5, lane: $0 % 4, duration: $0 == 4 ? 0.8 : 0) }
        run(&marble, notes: notes, from: 0, to: 4)
        let props = marble.packed(at: 4)
        #expect(props.count == ImmersiveKineticMarbleRun.propsCapacity)
        #expect(Int(props[0].x) == min(marble.pads.count, 60))
        #expect(abs(Double(props[1].x) - (marble.ball.x - marble.cameraX)) < 1e-4)
        #expect(abs(Double(props[1].y) - (marble.ball.y - marble.cameraY)) < 1e-4)
        // 种类和轨道拼在一个数里：轨道 + 1 + 8 × 种类。
        let codes = (0..<Int(props[0].x)).map { Int(props[9 + $0 * 2].y) }
        #expect(codes.contains { $0 / 8 == 1 })
        #expect(codes.allSatisfy { $0 % 8 <= 4 })
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
