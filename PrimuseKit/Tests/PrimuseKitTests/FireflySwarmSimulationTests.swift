import Foundation
import Testing
@testable import PrimuseKit

/// 全屏「萤火同步」：节拍稳时整群渐渐一齐闪，安静时又散开。
struct FireflySwarmSimulationTests {
    /// 每 0.5 秒一记低频重拍，其余时间是平稳的中频。
    private func drumLevels(at time: TimeInterval) -> [Double] {
        let phase = time.truncatingRemainder(dividingBy: 0.5)
        let hit = phase < 0.06 ? 1.0 : max(0, 1 - phase / 0.25) * 0.4
        return (0..<32).map { $0 < 5 ? 0.25 + 0.7 * hit : 0.3 }
    }

    private func run(
        _ swarm: inout FireflySwarmSimulation,
        tracker: inout ImmersiveBeatTracker,
        from start: Double,
        seconds: Double,
        levels: (TimeInterval) -> [Double]
    ) {
        let frame = 1.0 / 30
        var time = start
        while time < start + seconds {
            let features = tracker.update(levels: levels(time), at: time)
            swarm.step(dt: frame, features: features)
            time += frame
        }
    }

    @Test func steadyBeatPullsTheSwarmIntoUnison() {
        var swarm = FireflySwarmSimulation(count: 240, seed: 3)
        var tracker = ImmersiveBeatTracker()
        #expect(swarm.coherence < 0.3)
        run(&swarm, tracker: &tracker, from: 0, seconds: 25, levels: drumLevels)
        #expect(swarm.coherence > 0.8)
        // 每秒两拍按半速闪：大约每秒一次。
        #expect(abs(swarm.baseRate - 1) < 0.1)
    }

    @Test func silenceLetsTheSwarmDriftApart() {
        var swarm = FireflySwarmSimulation(count: 240, seed: 4)
        var tracker = ImmersiveBeatTracker()
        run(&swarm, tracker: &tracker, from: 0, seconds: 25, levels: drumLevels)
        let synchronized = swarm.coherence
        run(&swarm, tracker: &tracker, from: 25, seconds: 60) { _ in Array(repeating: 0, count: 32) }
        #expect(synchronized > 0.8)
        #expect(swarm.coherence < 0.5)
        #expect(abs(swarm.baseRate - FireflySwarmSimulation.restingRate) < 0.05)
    }

    @Test func synchronizedFlashesLandOnTheBeat() {
        var swarm = FireflySwarmSimulation(count: 200, seed: 5)
        var tracker = ImmersiveBeatTracker()
        run(&swarm, tracker: &tracker, from: 0, seconds: 30, levels: drumLevels)
        // 同步后每只最近一次闪的时刻，离最近的一拍不该超过 0.12 秒（鼓点检测本身有一两帧的延迟）。
        let offsets = swarm.fireflies.map { firefly -> Double in
            let phase = firefly.lastFlash.truncatingRemainder(dividingBy: 0.5)
            return min(phase, 0.5 - phase)
        }
        let onBeat = offsets.filter { $0 < 0.12 }.count
        #expect(Double(onBeat) / Double(offsets.count) > 0.8)
    }

    @Test func flashRisesQuicklyAndFades() {
        var swarm = FireflySwarmSimulation(count: 1, seed: 6)
        var features = ImmersiveAudioFeatures()
        features.energy = 0
        var flashed = false
        var peak = 0.0
        for _ in 0..<(30 * 4) {
            let before = swarm.fireflies[0].lastFlash
            swarm.step(dt: 1.0 / 30, features: features)
            if swarm.fireflies[0].lastFlash != before { flashed = true }
            peak = max(peak, swarm.brightness(of: 0))
        }
        #expect(flashed)
        #expect(peak > 0.6 && peak <= 1)
        #expect(swarm.brightness(of: 5) == 0)
    }

    @Test func fireflyStaysNearItsHome() {
        var swarm = FireflySwarmSimulation(count: 50, seed: 8)
        let features = ImmersiveAudioFeatures()
        for _ in 0..<(30 * 20) {
            swarm.step(dt: 1.0 / 30, features: features)
            for index in swarm.fireflies.indices {
                let position = swarm.position(of: index)
                let firefly = swarm.fireflies[index]
                #expect(abs(position.x - firefly.homeX) < 0.06)
                #expect(abs(position.y - firefly.homeY) < 0.06)
            }
        }
        #expect(swarm.fireflies.allSatisfy { $0.homeY >= 0.12 && $0.homeY <= 0.95 })
    }

    @Test func sameSeedSameSwarm() {
        let first = FireflySwarmSimulation(count: 30, seed: 9)
        let second = FireflySwarmSimulation(count: 30, seed: 9)
        #expect(first.fireflies == second.fireflies)
    }
}
