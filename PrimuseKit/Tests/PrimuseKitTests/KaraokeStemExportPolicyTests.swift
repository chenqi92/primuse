import Foundation
import Testing
@testable import PrimuseKit

@Suite("Karaoke stem export")
struct KaraokeStemExportPolicyTests {
    @Test("The instrumental is the original minus the vocal, sample for sample")
    func subtractsVocals() {
        var mix: [Float] = [0.5, -0.25, 0.75, 0]
        KaraokeStemExportPolicy.subtractVocals([0.25, -0.25, 0.5, 0.5], from: &mix)
        #expect(mix == [0.25, 0, 0.25, -0.5])
    }

    @Test("A length mismatch is cut to the shorter of the two")
    func trimsToShorter() {
        var mix: [Float] = [0.5, 0.5, 0.5]
        KaraokeStemExportPolicy.subtractVocals([0.25, 0.25], from: &mix)
        #expect(mix == [0.25, 0.25])
        var short: [Float] = [0.5]
        KaraokeStemExportPolicy.subtractVocals([0.25, 0.25, 0.25], from: &short)
        #expect(short == [0.25])
    }

    @Test("Peaks past full scale are clipped rather than wrapped")
    func clipsPeaks() {
        var mix: [Float] = [0.9, -0.9]
        KaraokeStemExportPolicy.subtractVocals([-0.5, 0.5], from: &mix)
        #expect(mix == [1, -1])
    }

    @Test("The file is named after the song with the part in brackets")
    func fileNames() {
        #expect(
            KaraokeStemExportPolicy.fileName(title: "Song", artist: "Band", partLabel: "Instrumental", format: .wav)
                == "Song (Instrumental) - Band.wav"
        )
        #expect(
            KaraokeStemExportPolicy.fileName(title: " ", artist: nil, partLabel: "伴奏", format: .m4a) == "伴奏.m4a"
        )
    }

    @Test("Stereo AAC starts at the highest bit rate")
    func bitRates() {
        #expect(KaraokeStemExportPolicy.bitRateCandidates().first == 256_000)
    }
}
