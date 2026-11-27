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

    /// 一段平稳的电平：每个频段在 `level` 上下抖一点。
    private func steadyLevels(_ level: Double, step: Int) -> [Double] {
        (0..<32).map { index in level + 0.01 * sin(Double(step * 7 + index) * 0.37) }
    }

    @Test func intensityRanksTheLouderSectionAboveTheQuieterOne() {
        var tracker = ImmersiveBeatTracker()
        let frame = 1.0 / 30
        var step = 0
        func run(_ level: Double, seconds: Double) -> [Double] {
            var values: [Double] = []
            for _ in 0..<Int(seconds * 30) {
                values.append(tracker.update(levels: steadyLevels(level, step: step), at: Double(step) * frame).intensity)
                step += 1
            }
            return values
        }
        let verse = run(0.48, seconds: 24)
        let chorus = run(0.58, seconds: 12)
        let bridge = run(0.40, seconds: 8)
        // 一直一样响时落在中间，不会因为整体电平高就顶满。
        #expect(verse.suffix(60).allSatisfy { $0 > 0.25 && $0 < 0.75 })
        // 副歌比刚才的主歌响：排在前面；之后的间奏排到最后。
        #expect(chorus[30 * 2] > 0.85)
        #expect(bridge[30 * 2] < 0.15)
    }

    @Test func pauseBetweenSongsDoesNotInflateTheNextOne() {
        var tracker = ImmersiveBeatTracker()
        let frame = 1.0 / 30
        var step = 0
        var last = ImmersiveAudioFeatures()
        for _ in 0..<(30 * 20) {
            last = tracker.update(levels: steadyLevels(0.5, step: step), at: Double(step) * frame)
            step += 1
        }
        for _ in 0..<(30 * 3) {
            last = tracker.update(levels: Array(repeating: 0, count: 32), at: Double(step) * frame)
            step += 1
        }
        #expect(last.intensity == 0)
        for _ in 0..<(30 * 3) {
            last = tracker.update(levels: steadyLevels(0.5, step: step), at: Double(step) * frame)
            step += 1
        }
        #expect(last.intensity > 0.25 && last.intensity < 0.75)
    }

    @Test func registerOnsetsTellTheKickFromTheHats() {
        let frame = 1.0 / 30
        func count(_ levels: (TimeInterval) -> [Double]) -> [Int] {
            var tracker = ImmersiveBeatTracker()
            var counts = [0, 0, 0]
            for step in 0..<(30 * 8) {
                let time = Double(step) * frame
                let features = tracker.update(levels: levels(time), at: time)
                for register in 0..<3 where features.onsets[register] > 0 { counts[register] += 1 }
            }
            return counts
        }
        let hatsOnly = count { time in
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            let hit = phase < 0.05 ? 1.0 : max(0, 1 - phase / 0.2) * 0.3
            return (0..<32).map { $0 >= 20 ? 0.2 + 0.6 * hit : 0.3 }
        }
        #expect(hatsOnly[0] == 0)
        #expect(hatsOnly[2] >= 10)
        let kickOnly = count { drumLevels(at: $0) }
        #expect(kickOnly[0] >= 12)
        #expect(kickOnly[2] == 0)
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
        // 只差 1 的几种是斜条纹，只留最简单的那一种。
        #expect(modes.filter { $0.n - $0.m == 1 } == [ChladniMode(m: 1, n: 2, sign: -1)])
        #expect(ChladniPlate.modeIndex(level: 0, songOffset: 0) == 0)
        for offset in 0...ChladniPlate.levelStride {
            for level in 1..<ChladniPlate.levelCount {
                #expect(ChladniPlate.modeIndex(level: level - 1, songOffset: offset) < ChladniPlate.modeIndex(level: level, songOffset: offset))
            }
            #expect(ChladniPlate.modeIndex(level: ChladniPlate.levelCount - 1, songOffset: offset) < modes.count)
        }
        for register in ImmersiveAudioRegister.allCases {
            for index in modes.indices {
                let transient = ChladniPlate.transientIndex(for: register, around: index)
                #expect(modes.indices.contains(transient))
                #expect(modes[transient].m != modes[index].m || modes[transient].n != modes[index].n)
            }
        }
    }

    @Test func fieldGradientMatchesFiniteDifference() {
        let mode = ChladniMode(m: 2, n: 5, sign: -1)
        let h = 1e-6
        for mix in [1.0, 0.4] {
            for (x, y) in [(0.13, 0.71), (0.5, 0.5), (0.92, 0.04)] {
                let field = mode.field(x: x, y: y, mix: mix)
                let dx = (mode.field(x: x + h, y: y, mix: mix).value - mode.field(x: x - h, y: y, mix: mix).value) / (2 * h)
                let dy = (mode.field(x: x, y: y + h, mix: mix).value - mode.field(x: x, y: y - h, mix: mix).value) / (2 * h)
                #expect(abs(field.dx - dx) < 1e-4)
                #expect(abs(field.dy - dy) < 1e-4)
                #expect(abs(mode.value(x: x, y: y, mix: mix) - field.value) < 1e-12)
            }
        }
    }

    @Test func recurrenceBasisMatchesTheDirectField() {
        let size = ChladniSandSimulation.basisSize
        #expect(ChladniPlate.modes.allSatisfy { $0.n < size && $0.m < size })
        let table = UnsafeMutablePointer<Double>.allocate(capacity: 4 * size)
        defer { table.deallocate() }
        for (x, y) in [(0.0, 1.0), (0.13, 0.71), (0.5, 0.5), (0.92, 0.04), (0.333, 0.999)] {
            ChladniSandSimulation.fillBasis(x, cosines: table, sines: table + size)
            ChladniSandSimulation.fillBasis(y, cosines: table + 2 * size, sines: table + 3 * size)
            for mode in ChladniPlate.modes {
                for mix in [1.0, 0.3] {
                    let direct = mode.field(x: x, y: y, mix: mix)
                    let fast = ChladniSandSimulation.field(mode, mix: mix, table, table + size, table + 2 * size, table + 3 * size)
                    #expect(abs(direct.value - fast.value) < 1e-9)
                    #expect(abs(direct.dx - fast.dx) < 1e-8)
                    #expect(abs(direct.dy - fast.dy) < 1e-8)
                }
            }
        }
    }

    private func meanAmplitude(_ simulation: ChladniSandSimulation, mode: ChladniMode) -> Double {
        var total = 0.0
        for index in simulation.xs.indices {
            total += abs(mode.field(x: simulation.xs[index], y: simulation.ys[index], mix: simulation.mix).value)
        }
        return total / Double(max(simulation.xs.count, 1))
    }

    /// 有声音、但没有起音的一帧。
    private func calm(intensity: Double, brightness: Double = 0) -> ImmersiveAudioFeatures {
        var features = ImmersiveAudioFeatures()
        features.energy = 0.45
        features.intensity = intensity
        features.registerIntensity = [intensity, 0.5 + brightness / 2, intensity]
        features.brightnessShift = brightness
        return features
    }

    @Test func sandStartsOnTheNodalLinesAndStaysOnThePlate() {
        var simulation = ChladniSandSimulation(count: 1500, seed: 7, songSeed: 3, level: 1)
        let mode = simulation.mode
        // 均匀撒在板上时 |f| 的均值约 0.8；起始就排好的沙应远低于它。
        #expect(meanAmplitude(simulation, mode: mode) < 0.2)
        for _ in 0..<120 {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.4))
        }
        #expect(simulation.mode == mode)
        #expect(meanAmplitude(simulation, mode: mode) < 0.25)
        #expect(simulation.xs.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(simulation.ys.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func louderSectionBuildsABusierPatternAndTheBridgeSimplifiesIt() {
        var simulation = ChladniSandSimulation(count: 1200, seed: 11, songSeed: 0, level: 1)
        let verse = simulation.modeIndex
        for _ in 0..<(30 * 8) {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.97))
        }
        #expect(simulation.level == ChladniPlate.levelCount - 1)
        #expect(simulation.modeIndex > verse)
        #expect(simulation.transition == 1)
        #expect(meanAmplitude(simulation, mode: simulation.mode) < 0.3)
        let chorus = simulation.mode
        for _ in 0..<(30 * 8) {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.03))
        }
        #expect(simulation.level == 0)
        #expect(simulation.modeIndex < verse)
        // 副歌回来时回到同一个花纹。
        for _ in 0..<(30 * 8) {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.97))
        }
        #expect(simulation.mode == chorus)
    }

    @Test func briefSwingsOfIntensityKeepThePattern() {
        var simulation = ChladniSandSimulation(count: 200, seed: 5, songSeed: 0, level: 2)
        let first = simulation.mode
        for step in 0..<(30 * 8) {
            // 每 0.5 秒在两档之间来回（主歌里一句唱完、下一句又起）：平均下来还在原来那一档。
            let intensity = (step / 15).isMultiple(of: 2) ? 0.48 : 0.78
            simulation.step(dt: 1.0 / 30, features: calm(intensity: intensity))
        }
        #expect(simulation.mode == first)
    }

    @Test func kickScattersTheSandAndItSettlesBeforeTheNextBeat() {
        var simulation = ChladniSandSimulation(count: 1500, seed: 21, songSeed: 4, level: 2)
        for _ in 0..<60 {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.8))
        }
        let settled = meanAmplitude(simulation, mode: simulation.mode)
        var kick = calm(intensity: 0.8)
        kick.beat = 1
        kick.onsets = [1, 0, 0]
        simulation.step(dt: 1.0 / 30, features: kick)
        let scattered = meanAmplitude(simulation, mode: simulation.mode)
        #expect(scattered > settled * 1.6)
        for _ in 0..<12 {
            simulation.step(dt: 1.0 / 30, features: calm(intensity: 0.8))
        }
        // 0.4 秒后大半已经落回线上。
        let recovered = meanAmplitude(simulation, mode: simulation.mode)
        #expect(recovered - settled < (scattered - settled) * 0.4)
    }

    @Test func brighterTimbreBendsThePatternTowardTheClassicFigure() {
        var bright = ChladniSandSimulation(count: 100, seed: 3, songSeed: 1, level: 1)
        var dark = ChladniSandSimulation(count: 100, seed: 3, songSeed: 1, level: 1)
        for _ in 0..<(30 * 5) {
            bright.step(dt: 1.0 / 30, features: calm(intensity: 0.4, brightness: 1))
            dark.step(dt: 1.0 / 30, features: calm(intensity: 0.4, brightness: -1))
        }
        #expect(bright.mode == dark.mode)
        #expect(bright.mix > 0.9)
        #expect(dark.mix < 0.35)
    }

    @Test func changingSongMorphsWithoutResettingSand() {
        var simulation = ChladniSandSimulation(count: 300, seed: 9, songSeed: 1)
        let before = simulation.xs
        var seed: UInt64 = 2
        while ChladniPlate.songOffset(seed: seed) == ChladniPlate.songOffset(seed: 1) { seed += 1 }
        simulation.changeSong(seed: seed)
        #expect(simulation.transition == 0)
        #expect(simulation.xs == before)
    }
}
