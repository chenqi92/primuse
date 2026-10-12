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

    @Test("Bands above Nyquist and broken input are skipped")
    func degenerateInput() {
        // 8 kHz 采样率下 16 kHz 频段高于奈奎斯特频率，整段跳过。
        #expect(preamp([0, 0, 0, 0, 0, 0, 0, 0, 0, 6], sampleRate: 8_000) == 0)
        #expect(preamp([0, 0, 0, 0, 0, 6, 0, 0, 0, 0], sampleRate: 0) == 0)
        #expect(preamp([0, 0, 0, 0, 0, .nan, 0, 0, 0, 0]) == 0)
    }
}
