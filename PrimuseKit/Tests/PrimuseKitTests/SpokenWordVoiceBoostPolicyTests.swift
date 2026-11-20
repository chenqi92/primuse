import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word voice boost")
struct SpokenWordVoiceBoostPolicyTests {
    typealias Policy = SpokenWordVoiceBoostPolicy

    @Test func compressorTargetCompressesAndLiftsWithoutClipping() {
        let target = Policy.compressorTarget
        #expect(target.threshold < 0)
        #expect(target.threshold == Policy.threshold)
        #expect(target.headRoom == Policy.headRoom)
        #expect(target.gain > 0)
        #expect(target.gain <= Policy.requestedGain)
        #expect(target.gain <= CompressorTransitionPolicy.maximumGainDB(threshold: target.threshold, headRoom: target.headRoom))
    }

    @Test func compressorReachesVoiceTargetFromNeutralInSmallSteps() {
        // 开关一开,从「不压」一小步一小步走到语音增强的参数,每一步都不超过不削波的上限。
        var current = CompressorTransitionPolicy.target(enabled: false, threshold: -20, headRoom: 5, gain: 5)
        let target = Policy.compressorTarget
        var steps = 0
        while current != target, steps < 1_000 {
            let next = CompressorTransitionPolicy.step(from: current, toward: target)
            #expect(next.gain <= CompressorTransitionPolicy.maximumGainDB(threshold: next.threshold, headRoom: next.headRoom) + 0.001)
            current = next
            steps += 1
        }
        #expect(current == target)
        // 一秒以内到位(每步 10 ms)。
        #expect(steps <= 100)
    }

    @Test func voiceFiltersShapeTheSpeechBand() {
        let sampleRate = 48_000.0
        let configuration = Policy.equalizerConfiguration(adding: .flat, sampleRate: sampleRate)
        #expect(configuration.filters.count == Policy.filters.count)
        func response(_ frequency: Double) -> Double {
            configuration.filters.reduce(0) { $0 + $1.gainDB(frequency: frequency, sampleRate: sampleRate) }
                + configuration.preampDB
        }
        // 3 kHz 比 1 kHz 亮,低频的轰鸣压下去。
        #expect(response(3_000) > response(1_000) + 2)
        #expect(response(60) < response(1_000) - 3)
        // 整体先压低,叠加后的峰值不超过 0 dB。
        #expect(configuration.preampDB < 0)
        #expect(response(3_000) <= 0.1)
    }

    @Test func voiceFiltersStackOnTopOfTheUserCurve() {
        let sampleRate = 44_100.0
        let user = EQRenderConfiguration(
            filters: [EQBiquad(filter: PEQFilter(kind: .peak, frequency: 100, gain: 6, q: 1), sampleRate: sampleRate)],
            preampDB: -6.5
        )
        let combined = Policy.equalizerConfiguration(adding: user, sampleRate: sampleRate)
        #expect(combined.filters.count == 1 + Policy.filters.count)
        #expect(Array(combined.filters.prefix(1)) == user.filters)
        // 不比用户原来的预衰减更响。
        #expect(combined.preampDB <= user.preampDB)
    }

    @Test func fullUserCurveIsLeftAlone() {
        let sampleRate = 48_000.0
        let filters = (0..<ParametricEQ.maximumFilters).map { index in
            EQBiquad(filter: PEQFilter(kind: .peak, frequency: 100 * Double(index + 1), gain: 1, q: 1), sampleRate: sampleRate)
        }
        let user = EQRenderConfiguration(filters: filters, preampDB: -3)
        #expect(Policy.equalizerConfiguration(adding: user, sampleRate: sampleRate) == user)
    }

    @Test func unusableSampleRateLeavesTheCurveAlone() {
        #expect(Policy.equalizerConfiguration(adding: .flat, sampleRate: 0) == .flat)
        #expect(Policy.equalizerConfiguration(adding: .flat, sampleRate: .nan) == .flat)
    }
}
