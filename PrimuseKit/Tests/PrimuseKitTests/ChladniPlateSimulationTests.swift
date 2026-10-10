import Foundation
import Testing
@testable import PrimuseKit

/// 全屏「克拉尼沙画」：鼓点与拍速检测、花纹挑选、沙子落到节线上。
struct ChladniPlateSimulationTests {
    /// 每 0.5 秒一记低频重拍（每秒 2 拍），其余时间是平稳的中频。
    private func drumLevels(at time: TimeInterval, period: TimeInterval = 0.5, bands: Int = 32) -> [Double] {
        let phase = time.truncatingRemainder(dividingBy: period)
        let hit = phase < 0.06 ? 1.0 : max(0, 1 - phase / 0.25) * 0.4
        return (0..<bands).map { index in
            index < bands / 6 ? 0.25 + 0.7 * hit : 0.3
        }
    }

    @Test func steadyKickDrumYieldsBeatsAndTempo() {
        var tracker = ImmersiveBeatTracker()
        var beats = 0
        var last = ImmersiveAudioFeatures()
        let frame = 1.0 / 30
        for step in 0..<(30 * 8) {
            let time = Double(step) * frame
            last = tracker.update(levels: drumLevels(at: time), at: time)
            if last.beat > 0 { beats += 1 }
        }
        // 8 秒、每秒 2 拍：开头要先积累一点底噪统计，允许少数几拍没认出来。
        #expect(beats >= 12 && beats <= 17)
        #expect(last.beatsPerSecond.map { abs($0 - 2) < 0.15 } == true)
        #expect(last.steadiness > 0.6)
    }

    @Test func silenceHasNoBeatsAndForgetsTempo() {
        var tracker = ImmersiveBeatTracker()
        let frame = 1.0 / 30
        for step in 0..<(30 * 4) {
            let time = Double(step) * frame
            _ = tracker.update(levels: drumLevels(at: time), at: time)
        }
        var beats = 0
        var last = ImmersiveAudioFeatures()
        for step in (30 * 4)..<(30 * 10) {
            let time = Double(step) * frame
            last = tracker.update(levels: Array(repeating: 0, count: 32), at: time)
            if last.beat > 0 { beats += 1 }
        }
        #expect(beats == 0)
        #expect(last.beatsPerSecond == nil)
        #expect(last.pulse < 0.01)
    }

    @Test func centroidFollowsWhereTheEnergySits() {
        var low = ImmersiveBeatTracker()
        var high = ImmersiveBeatTracker()
        var lowFeatures = ImmersiveAudioFeatures()
        var highFeatures = ImmersiveAudioFeatures()
        for step in 0..<90 {
            let time = Double(step) / 30
            lowFeatures = low.update(levels: (0..<32).map { $0 < 8 ? 0.8 : 0.05 }, at: time)
            highFeatures = high.update(levels: (0..<32).map { $0 > 22 ? 0.8 : 0.05 }, at: time)
        }
        #expect(lowFeatures.centroid < 0.3)
        #expect(highFeatures.centroid > 0.6)
    }

    @Test func tempoFoldsHalfAndDoubleTimeIntoOneOctave() {
        let onsets = stride(from: 0.0, to: 4.0, by: 0.25).map { $0 }
        let tempo = ImmersiveBeatTracker.tempo(onsets: onsets)
        // 每秒 4 拍折成每秒 2 拍。
        #expect(tempo.map { abs(1 / $0.interval - 2) < 0.01 } == true)
        #expect(ImmersiveBeatTracker.tempo(onsets: [0, 0.5, 1]) == nil)
    }

    @Test func randomIsDeterministicAndBounded() {
        var first = ImmersiveRandom(seed: 42)
        var second = ImmersiveRandom(seed: 42)
        for _ in 0..<200 {
            let value = first.unit()
            #expect(value == second.unit())
            #expect(value >= 0 && value < 1)
        }
        #expect(ImmersiveRandom.seed(for: "晴天") == ImmersiveRandom.seed(for: "晴天"))
        #expect(ImmersiveRandom.seed(for: "晴天") != ImmersiveRandom.seed(for: "七里香"))
    }

    @Test func modeTableRunsFromSimpleToBusy() {
        let modes = ChladniPlate.modes
        #expect(modes.count > 30)
        #expect(Set(modes).count == modes.count)
        for index in 1..<modes.count {
            let previous = modes[index - 1]
            let current = modes[index]
            #expect(previous.m * previous.m + previous.n * previous.n <= current.m * current.m + current.n * current.n)
        }
        #expect(ChladniPlate.modeIndex(centroid: 0, energy: 0, songOffset: 0) == 0)
        #expect(ChladniPlate.modeIndex(centroid: 0.36, energy: 0.4, songOffset: 0) < ChladniPlate.modeIndex(centroid: 0.48, energy: 0.4, songOffset: 0))
        #expect(ChladniPlate.modeIndex(centroid: 0.42, energy: 0.3, songOffset: 0) < ChladniPlate.modeIndex(centroid: 0.42, energy: 0.7, songOffset: 0))
        // 最繁的几种只留给特别亮的歌加上偏移，正常范围里用不到。
        #expect(ChladniPlate.modeIndex(centroid: 1, energy: 1, songOffset: 8) < modes.count)
        #expect(ChladniPlate.modeIndex(centroid: 1, energy: 1, songOffset: 8) > ChladniPlate.modeIndex(centroid: 0.42, energy: 0.5, songOffset: 8))
    }

    @Test func fieldGradientMatchesFiniteDifference() {
        let mode = ChladniMode(m: 2, n: 5, sign: -1)
        let h = 1e-6
        for (x, y) in [(0.13, 0.71), (0.5, 0.5), (0.92, 0.04)] {
            let field = mode.field(x: x, y: y)
            let dx = (mode.field(x: x + h, y: y).value - mode.field(x: x - h, y: y).value) / (2 * h)
            let dy = (mode.field(x: x, y: y + h).value - mode.field(x: x, y: y - h).value) / (2 * h)
            #expect(abs(field.dx - dx) < 1e-4)
            #expect(abs(field.dy - dy) < 1e-4)
        }
    }

    private func meanAmplitude(_ simulation: ChladniSandSimulation, mode: ChladniMode) -> Double {
        var total = 0.0
        for index in simulation.xs.indices {
            total += abs(mode.field(x: simulation.xs[index], y: simulation.ys[index]).value)
        }
        return total / Double(max(simulation.xs.count, 1))
    }

    @Test func sandStartsOnTheNodalLinesAndStaysOnThePlate() {
        var simulation = ChladniSandSimulation(count: 1500, seed: 7, songSeed: 3)
        let mode = simulation.mode
        // 均匀撒在板上时 |f| 的均值约 0.8；起始就排好的沙应远低于它。
        #expect(meanAmplitude(simulation, mode: mode) < 0.2)
        for _ in 0..<120 {
            simulation.step(dt: 1.0 / 30, centroid: ImmersiveBeatTracker.restingCentroid, drive: 0.4, kick: 0)
        }
        #expect(simulation.mode == mode)
        #expect(meanAmplitude(simulation, mode: mode) < 0.25)
        #expect(simulation.xs.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(simulation.ys.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func sandFlowsToTheNewPatternAfterTheSongBrightens() {
        var simulation = ChladniSandSimulation(count: 1500, seed: 11, songSeed: 0, centroid: 0.34, energy: 0.3)
        let first = simulation.mode
        // 歌一直又亮又响：平均响度先爬上去，再等 dwell、过渡，然后沙子收拢。
        for _ in 0..<(30 * 10) {
            simulation.step(dt: 1.0 / 30, centroid: 0.52, drive: 0.6, kick: 0)
        }
        let second = simulation.mode
        #expect(second != first)
        #expect(simulation.transition == 1)
        #expect(meanAmplitude(simulation, mode: second) < 0.3)
    }

    @Test func briefWobbleOfTheCentroidKeepsThePattern() {
        var simulation = ChladniSandSimulation(count: 200, seed: 5, songSeed: 0, centroid: 0.36, energy: 0.4)
        let first = simulation.mode
        for step in 0..<(30 * 6) {
            // 每 0.5 秒在两档之间来回：等不满 dwell，不该换。
            let centroid = (step / 15).isMultiple(of: 2) ? 0.36 : 0.52
            simulation.step(dt: 1.0 / 30, centroid: centroid, drive: 0.4, kick: 0)
        }
        #expect(simulation.mode == first)
    }

    @Test func changingSongMorphsWithoutResettingSand() {
        var simulation = ChladniSandSimulation(count: 300, seed: 9, songSeed: 1)
        let before = simulation.xs
        var seed: UInt64 = 2
        while ChladniPlate.songOffset(seed: seed) == ChladniPlate.songOffset(seed: 1) { seed += 1 }
        simulation.changeSong(seed: seed, centroid: ImmersiveBeatTracker.restingCentroid)
        #expect(simulation.transition == 0)
        #expect(simulation.xs == before)
    }
}
