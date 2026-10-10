import Foundation
import Testing
@testable import PrimuseKit

/// 全屏「萤火同步」：三层各跟一段声音，起音把充好能的一批带着闪；越热闹醒着的越多。
struct FireflySwarmSimulationTests {
    /// 每 0.5 秒一记低频重拍，其余时间是平稳的中频。
    private func drumLevels(at time: TimeInterval) -> [Double] {
        let phase = time.truncatingRemainder(dividingBy: 0.5)
        let hit = phase < 0.06 ? 1.0 : max(0, 1 - phase / 0.25) * 0.4
        return (0..<32).map { $0 < 5 ? 0.25 + 0.7 * hit : 0.3 }
    }

    /// 喂一段频谱；每帧回调一次（模拟时刻、这一帧闪了的萤火编号）。
    private func run(
        _ swarm: inout FireflySwarmSimulation,
        tracker: inout ImmersiveBeatTracker,
        from start: Double,
        seconds: Double,
        levels: (TimeInterval) -> [Double],
        onFrame: (TimeInterval, [Int]) -> Void = { _, _ in }
    ) {
        let frame = 1.0 / 30
        var time = start
        while time < start + seconds {
            let features = tracker.update(levels: levels(time), at: time)
            let before = swarm.fireflies.map(\.lastFlash)
            swarm.step(dt: frame, features: features)
            var flashed: [Int] = []
            for index in swarm.fireflies.indices where swarm.fireflies[index].lastFlash != before[index] {
                flashed.append(index)
            }
            onFrame(time, flashed)
            time += frame
        }
    }

    @Test func registersAreLayeredFromTheGrassUp() {
        let swarm = FireflySwarmSimulation(count: 300, seed: 3)
        func meanHeight(_ register: ImmersiveAudioRegister) -> Double {
            let members = swarm.fireflies.filter { $0.register == register }
            return members.map(\.homeY).reduce(0, +) / Double(max(members.count, 1))
        }
        #expect(meanHeight(.low) > meanHeight(.mid))
        #expect(meanHeight(.mid) > meanHeight(.high))
        #expect(swarm.fireflies.allSatisfy { $0.homeY >= 0 && $0.homeY <= 1 })
        #expect(swarm.fireflies.filter { $0.register == .high }.count > 40)
    }

    @Test func kickDrumLightsTheLowLayerOnTheBeatInChangingBatches() {
        var swarm = FireflySwarmSimulation(count: 240, seed: 5)
        var tracker = ImmersiveBeatTracker()
        run(&swarm, tracker: &tracker, from: 0, seconds: 10, levels: drumLevels)
        var onBeat = 0
        var offBeat = 0
        var batches: [Set<Int>] = []
        var current = Set<Int>()
        var lastBeat = -1
        let lowLayer = Set(swarm.fireflies.indices.filter { swarm.fireflies[$0].register == .low })
        run(&swarm, tracker: &tracker, from: 10, seconds: 12, levels: drumLevels) { time, flashed in
            let low = flashed.filter { lowLayer.contains($0) }
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            let beat = Int(time / 0.5)
            if beat != lastBeat {
                if !current.isEmpty { batches.append(current) }
                current = []
                lastBeat = beat
            }
            if min(phase, 0.5 - phase) < 0.12 {
                onBeat += low.count
                current.formUnion(low)
            } else {
                offBeat += low.count
            }
        }
        // 贴着草的那层大多在鼓点上闪（鼓点检测本身有一两帧的延迟）。
        #expect(onBeat > offBeat * 3)
        let lowCount = lowLayer.count
        // 一记鼓点亮的是一批，不是整层；相邻两拍亮的也不是固定的两拨轮流。
        #expect(batches.allSatisfy { $0.count < lowCount * 9 / 10 })
        var repeats = 0
        for index in 2..<batches.count where batches[index] == batches[index - 2] { repeats += 1 }
        #expect(repeats == 0)
    }

    @Test func busierMusicWakesMoreFirefliesAndSilenceLetsThemSleep() {
        var swarm = FireflySwarmSimulation(count: 240, seed: 4)
        var tracker = ImmersiveBeatTracker()
        // 前奏：只有平稳的中频，没有鼓。
        run(&swarm, tracker: &tracker, from: 0, seconds: 12) { _ in Array(repeating: 0.3, count: 32) }
        let introLow = swarm.population[ImmersiveAudioRegister.low.rawValue]
        // 鼓进来，而且整体更响。
        run(&swarm, tracker: &tracker, from: 12, seconds: 12) { time in drumLevels(at: time).map { $0 + 0.12 } }
        let groove = swarm.population[ImmersiveAudioRegister.low.rawValue]
        #expect(groove > introLow + 0.25)
        let awakeInGroove = swarm.fireflies.filter { $0.awake > 0.5 }.count
        run(&swarm, tracker: &tracker, from: 24, seconds: 12) { _ in Array(repeating: 0, count: 32) }
        let awakeInSilence = swarm.fireflies.filter { $0.awake > 0.5 }.count
        #expect(swarm.population.allSatisfy { $0 < 0.15 })
        #expect(awakeInSilence * 3 < awakeInGroove)
        #expect(abs(swarm.baseRate - FireflySwarmSimulation.restingRate) < 0.05)
    }

    @Test func flashRisesQuicklyAndFades() {
        var swarm = FireflySwarmSimulation(count: 40, seed: 6)
        let features = ImmersiveAudioFeatures()
        var flashed = false
        var peak = 0.0
        for _ in 0..<(30 * 4) {
            let before = swarm.fireflies.map(\.lastFlash)
            swarm.step(dt: 1.0 / 30, features: features)
            if swarm.fireflies.map(\.lastFlash) != before { flashed = true }
            for index in swarm.fireflies.indices { peak = max(peak, swarm.brightness(of: index)) }
        }
        #expect(flashed)
        #expect(peak > 0.2 && peak <= 1)
        #expect(swarm.brightness(of: 500) == 0)
    }

    @Test func fireflyStaysNearItsHomeWithoutRepeatingAPath() {
        var swarm = FireflySwarmSimulation(count: 50, seed: 8)
        var features = ImmersiveAudioFeatures()
        features.energy = 0.5
        features.intensity = 1
        var path: [(Double, Double)] = []
        for _ in 0..<(30 * 20) {
            swarm.step(dt: 1.0 / 30, features: features)
            for index in swarm.fireflies.indices {
                let position = swarm.position(of: index)
                let firefly = swarm.fireflies[index]
                #expect(abs(position.x - firefly.homeX) <= FireflySwarmSimulation.maximumDrift + 1e-9)
                #expect(abs(position.y - firefly.homeY) <= FireflySwarmSimulation.maximumDrift + 1e-9)
            }
            path.append(swarm.position(of: 0))
        }
        // 真的在动，而且五秒后不会回到五秒前的同一处、照原路再走一遍。
        let moved = path.indices.dropFirst().map { abs(path[$0].0 - path[$0 - 1].0) + abs(path[$0].1 - path[$0 - 1].1) }.reduce(0, +)
        #expect(moved > 0.05)
        let lagged = (150..<path.count).map { abs(path[$0].0 - path[$0 - 150].0) + abs(path[$0].1 - path[$0 - 150].1) }
        #expect(lagged.reduce(0, +) / Double(lagged.count) > 0.004)
    }

    @Test func sameSeedSameSwarm() {
        let first = FireflySwarmSimulation(count: 30, seed: 9)
        let second = FireflySwarmSimulation(count: 30, seed: 9)
        #expect(first.fireflies == second.fireflies)
    }
}
