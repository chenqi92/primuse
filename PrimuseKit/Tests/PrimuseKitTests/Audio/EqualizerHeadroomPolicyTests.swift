import Foundation
import Testing
@testable import PrimuseKit

@Suite("Equalizer headroom policy")
struct EqualizerHeadroomPolicyTests {
    private let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private func preamp(_ bands: [Float], sampleRate: Double = 48_000) -> Float {
        EqualizerHeadroomPolicy.preampDB(
            bandGainsDB: bands,
            frequencies: frequencies,
            bandwidthOctaves: 1,
            sampleRate: sampleRate
        )
    }

    @Test("A flat or cut-only curve keeps full volume")
    func flatAndCutsNeedNoHeadroom() {
        #expect(preamp(Array(repeating: 0, count: 10)) == 0)
        #expect(preamp([-6, -3, 0, 0, -2, 0, 0, -4, 0, -1]) == 0)
        #expect(preamp([]) == 0)
    }

    @Test("A single band is pulled down by exactly its boost")
    func singleBand() {
        #expect(abs(preamp([0, 0, 0, 0, 0, 6, 0, 0, 0, 0]) + 6) < 0.01)
        #expect(abs(preamp([0, 0, 0, 0, 0, 0, 0, 0, 0, 12]) + 12) < 0.01)
    }

    // 期望值是编译机 macOS 27 上用 AVAudioUnitEQ 逐个正弦实测的曲线最高点。
    @Test("Overlapping boosts add up beyond the largest band")
    func overlappingBands() {
        #expect(abs(preamp([6, 5, 4, 3, 1, 0, 0, 0, 0, 0]) + 7.14) < 0.02)   // 低音
        #expect(abs(preamp([0, 0, 0, 0, 0, 1, 3, 4, 5, 6]) + 7.80) < 0.02)   // 高音
        #expect(abs(preamp([-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]) + 5.39) < 0.02) // 人声
        #expect(abs(preamp(Array(repeating: 12, count: 10)) + 19.17) < 0.02)
    }

    @Test("A boost that barely clears zero is ignored")
    func negligibleBoost() {
        #expect(preamp([0, 0, 0, 0, 0, 0.04, 0, 0, 0, 0]) == 0)
    }

    @Test("The transition ceiling keeps the larger gain of each band")
    func ceiling() {
        #expect(EqualizerHeadroomPolicy.ceiling([6, 0, -3], [0, 4, -6]) == [6, 4, -3])
        // 长度不一时缺的段按 0 算。
        #expect(EqualizerHeadroomPolicy.ceiling([-2], [1, -1]) == [1, 0])
        #expect(EqualizerHeadroomPolicy.ceiling([], []) == [])
    }

    @Test("The transition holds the ceiling's preamp plus the margin")
    func transitionPreamp() {
        let flatToBass = EqualizerHeadroomPolicy.transitionPreampDB(
            ceilingBandGainsDB: EqualizerHeadroomPolicy.ceiling(
                Array(repeating: 0, count: 10), [6, 5, 4, 3, 1, 0, 0, 0, 0, 0]
            ),
            frequencies: frequencies,
            bandwidthOctaves: 1,
            sampleRate: 48_000
        )
        #expect(abs(flatToBass + 7.14 + 2) < 0.02)
        // 全是衰减的曲线切回平直也要多压一点：频段平滑过去时会过冲。
        let cutToFlat = EqualizerHeadroomPolicy.transitionPreampDB(
            ceilingBandGainsDB: Array(repeating: 0, count: 10),
            frequencies: frequencies,
            bandwidthOctaves: 1,
            sampleRate: 48_000
        )
        #expect(cutToFlat == -2)
    }

    @Test("The wait after lowering follows the output buffer")
    func lowerSettleDelay() {
        // 512 帧 / 48 kHz：两个周期也不到 60 ms，按 60 ms。
        #expect(EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: 512.0 / 48_000) == 0.06)
        // 锁屏常见的 4096 帧 / 44.1 kHz：约 201 ms。
        let locked = EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: 4_096.0 / 44_100)
        #expect(abs(locked - 0.2008) < 0.001)
        // 读不到、读出怪值时按最坏情况估；离谱的大值封顶。
        #expect(EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: nil) == locked)
        #expect(EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: .nan) == locked)
        #expect(EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: 0) == locked)
        #expect(EqualizerHeadroomPolicy.lowerSettleDelay(ioBufferDuration: 10) == 1.015)
    }

    @Test("Bands above Nyquist and broken input are skipped")
    func degenerateInput() {
        // 8 kHz 采样率下 16 kHz 频段高于奈奎斯特频率，整段跳过。
        #expect(preamp([0, 0, 0, 0, 0, 0, 0, 0, 0, 6], sampleRate: 8_000) == 0)
        #expect(preamp([0, 0, 0, 0, 0, 6, 0, 0, 0, 0], sampleRate: 0) == 0)
        #expect(preamp([0, 0, 0, 0, 0, .nan, 0, 0, 0, 0]) == 0)
    }
}
