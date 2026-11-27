import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio effects transition policy")
struct AudioEffectsTransitionPolicyTests {
    typealias Compressor = CompressorTransitionPolicy
    typealias Parameters = CompressorTransitionPolicy.Parameters

    // 内置的轻 / 中 / 重。
    private let light = Parameters(threshold: -15, headRoom: 10, gain: 2)
    private let medium = Parameters(threshold: -20, headRoom: 5, gain: 5)
    private let heavy = Parameters(threshold: -30, headRoom: 2, gain: 10)

    private func target(_ p: Parameters, enabled: Bool = true) -> Parameters {
        Compressor.target(enabled: enabled, threshold: p.threshold, headRoom: p.headRoom, gain: p.gain)
    }

    /// 一路走到目标,返回途经的每一步。
    private func walk(from start: Parameters, to end: Parameters) -> [Parameters] {
        var path = [start]
        var current = start
        for _ in 0..<2_000 {
            let next = Compressor.step(from: current, toward: end)
            if next == current { return path }
            path.append(next)
            current = next
        }
        Issue.record("did not converge")
        return path
    }

    @Test("Built-in presets keep their gain")
    func presetsAreNotCapped() {
        for preset in [light, medium, heavy] {
            #expect(target(preset) == preset)
        }
    }

    @Test("Gain is capped when the threshold no longer compresses loud songs")
    func gainCap() {
        // 重度的阈值拖到 -10:按实测上限只能加约 2.8 dB。
        let raised = target(Parameters(threshold: -10, headRoom: 2, gain: 10))
        #expect(abs(raised.gain - 2.8) < 0.05)
        // 阈值到 0 就不压了,不能再加增益;负增益照用户的。
        #expect(target(Parameters(threshold: 0, headRoom: 5, gain: 6)).gain == 0)
        #expect(target(Parameters(threshold: 0, headRoom: 5, gain: -6)).gain == -6)
    }

    @Test("Off means a transparent threshold and unity gain")
    func offTarget() {
        let off = target(heavy, enabled: false)
        #expect(off.threshold == Compressor.neutralThreshold)
        #expect(off.gain == 0)
    }

    @Test("Every step stays within the clipping-safe gain of both shapes it spans")
    func pathsNeverClip() {
        let presets = [light, medium, heavy, Parameters(threshold: -10, headRoom: 20, gain: 3)]
        var states = presets.map { target($0) }
        states += presets.map { target($0, enabled: false) }
        for a in states {
            for b in states where a != b {
                let path = walk(from: a, to: b)
                #expect(path.last == b)
                for (before, after) in zip(path, path.dropFirst()) {
                    let cap = min(
                        Compressor.maximumGainDB(threshold: before.threshold, headRoom: before.headRoom),
                        Compressor.maximumGainDB(threshold: after.threshold, headRoom: after.headRoom)
                    )
                    // 起点都是不削波的,之后每一步要么在两边形状的上限以内,要么正在降增益。
                    #expect(after.gain <= cap + 0.0001 || after.gain < before.gain)
                    #expect(abs(after.gain - before.gain) <= Compressor.gainStepDB + 0.0001)
                    #expect(abs(after.headRoom - before.headRoom) <= Compressor.shapeStepDB + 0.0001)
                    // 0 dBFS 以上都等于不压,按封顶到 0 之后的距离算。
                    let moved = abs(min(after.threshold, 0) - min(before.threshold, 0))
                    #expect(moved <= Compressor.shapeStepDB + 0.0001)
                }
            }
        }
    }

    @Test("Turning on lowers the threshold from 0 dBFS before adding gain")
    func turnOnOrder() {
        let path = walk(from: target(heavy, enabled: false), to: heavy)
        #expect(path[1].threshold == -1)
        let firstGain = path.firstIndex { $0.gain > 0 }!
        #expect(path[firstGain - 1].threshold == heavy.threshold)
        #expect(path[firstGain - 1].headRoom == heavy.headRoom)
    }

    @Test("Turning off drops the gain before releasing the threshold")
    func turnOffOrder() {
        let path = walk(from: heavy, to: target(heavy, enabled: false))
        let firstShapeChange = path.firstIndex { $0.threshold != heavy.threshold }!
        #expect(path[firstShapeChange - 1].gain == 0)
        #expect(path.last!.threshold == Compressor.neutralThreshold)
    }

    @Test("Reverb mix gains follow AVAudioUnitReverb's wet/dry law")
    func mixGains() {
        let thirty = ReverbTransitionPolicy.mixGains(wetPercent: 30)
        #expect(abs(thirty.dry - 0.8367) < 0.0001)
        #expect(abs(thirty.wet - 0.5477) < 0.0001)
        let dry = ReverbTransitionPolicy.mixGains(wetPercent: 0)
        #expect(dry.dry == 1 && dry.wet == 0)
        let wet = ReverbTransitionPolicy.mixGains(wetPercent: 140)
        #expect(wet.dry == 0 && wet.wet == 1)
    }

    @Test("Reverb headroom interpolates the measured table")
    func reverbHeadroom() {
        // 中厅(3)湿 20%:实测 3.07 dB 加 0.5 余量;湿 22.5% 在 20 与 25 之间。
        #expect(abs(ReverbTransitionPolicy.headroomDB(presetRawValue: 3, wetPercent: 20) - 3.57) < 0.001)
        #expect(abs(ReverbTransitionPolicy.headroomDB(presetRawValue: 3, wetPercent: 22.5) - 3.685) < 0.001)
        #expect(ReverbTransitionPolicy.headroomDB(presetRawValue: 3, wetPercent: 0) == 0)
        #expect(ReverbTransitionPolicy.headroomDB(presetRawValue: 3, wetPercent: -5) == 0)
        // 没测过的预设按最坏的算:湿 100% 时是中房间的 6.19。
        #expect(abs(ReverbTransitionPolicy.headroomDB(presetRawValue: 12, wetPercent: 100) - 6.69) < 0.001)
    }
}
