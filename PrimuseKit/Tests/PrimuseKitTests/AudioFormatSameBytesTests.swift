import Testing
@testable import PrimuseKit

struct AudioFormatSameBytesTests {
    @Test func identicalFormatsDescribeSameBytes() {
        for format in AudioFormat.allCases {
            #expect(AudioFormat.describeSameBytes(format, format))
        }
    }

    /// 回填用签名把 .wav 容器里的 DTS 流修正成 .dts。此后扫描永远给 .wav,
    /// 库里永远是 .dts —— 这一对必须被认成同一份字节, 否则每次扫描都会把
    /// 已经补好的元数据和封面当成"文件被换过"清掉。
    @Test func waveContainerAndItsDTSRefinementAreSameBytes() {
        #expect(AudioFormat.describeSameBytes(.wav, .dts))
        #expect(AudioFormat.describeSameBytes(.dts, .wav))
    }

    @Test func genuinelyDifferentFormatsAreNotSameBytes() {
        #expect(!AudioFormat.describeSameBytes(.mp3, .flac))
        #expect(!AudioFormat.describeSameBytes(.wav, .aiff))
        #expect(!AudioFormat.describeSameBytes(.dts, .ac3))
        #expect(!AudioFormat.describeSameBytes(.m4a, .mp3))
    }

    /// 放宽只针对已知的签名修正对, 不能变成"任何格式都算同一份字节"。
    @Test func relaxationStaysNarrow() {
        var relaxedPairs = 0
        for lhs in AudioFormat.allCases {
            for rhs in AudioFormat.allCases where lhs != rhs {
                if AudioFormat.describeSameBytes(lhs, rhs) { relaxedPairs += 1 }
            }
        }
        // 只有 (.wav,.dts) 和 (.dts,.wav) 两个有序对。
        #expect(relaxedPairs == 2)
    }

    /// 扫描侧对 .wav 扩展名的解析结果必须仍是 .wav —— 这是分歧的来源前提。
    @Test func scannerStillResolvesWaveExtensionToWave() {
        #expect(AudioFormat.from(fileExtension: "wav") == .wav)
        #expect(AudioFormat.from(fileExtension: "wave") == .wav)
        #expect(AudioFormat.from(fileExtension: "dtswav") == .dts)
    }
}
