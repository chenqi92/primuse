import Testing
@testable import PrimuseKit

/// 全屏效果页长时间没人碰之后的休憩与省电。
struct ImmersiveIdlePowerPolicyTests {
    @Test func handheldRestsFirstThenDropsToLowPowerAtFifteenMinutes() {
        #expect(ImmersiveIdlePowerPolicy.nextStage(after: .awake, restsEarly: true) == .resting)
        #expect(ImmersiveIdlePowerPolicy.delayToNextStage(from: .awake, restsEarly: true) == 300.0)
        #expect(ImmersiveIdlePowerPolicy.nextStage(after: .resting, restsEarly: true) == .lowPower)
        // 两段加起来正好 15 分钟。
        #expect(ImmersiveIdlePowerPolicy.delayToNextStage(from: .resting, restsEarly: true) == 600.0)
        #expect(ImmersiveIdlePowerPolicy.nextStage(after: .lowPower, restsEarly: true) == nil)
        #expect(ImmersiveIdlePowerPolicy.delayToNextStage(from: .lowPower, restsEarly: true) == nil)
    }

    @Test func macAndTelevisionGoStraightToLowPowerAtFifteenMinutes() {
        #expect(ImmersiveIdlePowerPolicy.nextStage(after: .awake, restsEarly: false) == .lowPower)
        #expect(ImmersiveIdlePowerPolicy.delayToNextStage(from: .awake, restsEarly: false) == 900.0)
    }

    @Test func lowPowerIsDarkerAndStopsDecorativeMotion() {
        #expect(ImmersiveIdlePowerPolicy.dimOpacity(for: .awake) == 0)
        #expect(ImmersiveIdlePowerPolicy.dimOpacity(for: .resting) == 0.60)
        #expect(ImmersiveIdlePowerPolicy.dimOpacity(for: .lowPower) > ImmersiveIdlePowerPolicy.dimOpacity(for: .resting))
        #expect(ImmersiveIdlePowerPolicy.runsDecorativeMotion(in: .awake))
        #expect(ImmersiveIdlePowerPolicy.runsDecorativeMotion(in: .resting))
        #expect(!ImmersiveIdlePowerPolicy.runsDecorativeMotion(in: .lowPower))
        #expect(ImmersiveIdlePowerPolicy.Stage.awake < .resting && ImmersiveIdlePowerPolicy.Stage.resting < .lowPower)
    }

    @Test func driftWalksTheFourCornersWithoutRepeatingAStep() {
        let steps = (0..<8).map { ImmersiveIdlePowerPolicy.driftOffset(step: $0) }
        for index in 1..<steps.count {
            #expect(steps[index] != steps[index - 1])
        }
        #expect(steps[0] == steps[4])
        #expect(ImmersiveIdlePowerPolicy.driftOffset(step: -1) == ImmersiveIdlePowerPolicy.driftOffset(step: 3))
    }

    /// 电视暂停着又没人碰，就让系统屏保接手；还在播就继续亮着。
    @Test func televisionHandsTheScreenBackOnlyWhenPausedInLowPower() {
        #expect(ImmersiveIdlePowerPolicy.holdsScreenAwake(stage: .awake, isPlaying: false))
        #expect(ImmersiveIdlePowerPolicy.holdsScreenAwake(stage: .lowPower, isPlaying: true))
        #expect(!ImmersiveIdlePowerPolicy.holdsScreenAwake(stage: .lowPower, isPlaying: false))
    }
}
