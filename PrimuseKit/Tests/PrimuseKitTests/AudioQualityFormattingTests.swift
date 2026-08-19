import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio quality formatting")
struct AudioQualityFormattingTests {
    @Test("Formats sample rate and bit depth")
    func qualitySpec() {
        let song = makeSong(sampleRate: 44_100, bitDepth: 24)

        #expect(song.formattedSampleRate == "44.1 kHz")
        #expect(song.formattedBitDepth == "24 bit")
        #expect(song.qualitySpecText == "44.1 kHz / 24 bit")
    }

    @Test("Formats integer sample rates without a decimal")
    func integerSampleRate() {
        #expect(makeSong(sampleRate: 96_000).formattedSampleRate == "96 kHz")
    }

    @Test("Treats song bitrate as kbps")
    func bitRateUnit() {
        #expect(makeSong(bitRate: 320).formattedBitRate == "320 kbps")

        let highBitRate = makeSong(bitRate: 9_216).formattedBitRate ?? ""
        #expect(highBitRate.filter(\.isNumber) == "9216")
        #expect(highBitRate.hasSuffix(" kbps"))
    }

    @Test("Hides missing or invalid audio values")
    func invalidValues() {
        let song = makeSong(bitRate: 0, sampleRate: -1, bitDepth: 0)

        #expect(song.formattedBitRate == nil)
        #expect(song.formattedSampleRate == nil)
        #expect(song.formattedBitDepth == nil)
        #expect(song.qualitySpecText == nil)
    }

    private func makeSong(
        bitRate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) -> Song {
        Song(
            id: "test-song",
            title: "Test",
            fileFormat: .flac,
            filePath: "test.flac",
            sourceID: "test-source",
            bitRate: bitRate,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
    }
}
