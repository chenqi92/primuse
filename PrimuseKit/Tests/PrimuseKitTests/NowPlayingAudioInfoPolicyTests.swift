import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now playing audio info")
struct NowPlayingAudioInfoPolicyTests {
    @Test("Each mode decides which songs get the line")
    func modes() {
        #expect(!NowPlayingAudioInfoMode.off.showsSummary(for: .hiRes))
        #expect(NowPlayingAudioInfoMode.nonStandardOnly.showsSummary(for: .lossless))
        #expect(NowPlayingAudioInfoMode.nonStandardOnly.showsSummary(for: .dsd))
        #expect(!NowPlayingAudioInfoMode.nonStandardOnly.showsSummary(for: .standard))
        #expect(NowPlayingAudioInfoMode.always.showsSummary(for: .standard))
        #expect(NowPlayingAudioInfoMode.resolved(rawValue: nil, fallback: .nonStandardOnly) == .nonStandardOnly)
        #expect(NowPlayingAudioInfoMode.resolved(rawValue: "bogus", fallback: .always) == .always)
        #expect(NowPlayingAudioInfoMode.resolved(rawValue: "off", fallback: .always) == .off)
    }

    @Test("The spec line reads format, resolution and bit rate")
    func specParts() {
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: "FLAC", sampleRate: 96_000, bitDepth: 24, bitRate: 2_304, isDSD: false
        ) == ["FLAC", "24bit/96kHz", "2304kbps"])
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: "MP3", sampleRate: 44_100, bitDepth: nil, bitRate: 320, isDSD: false
        ) == ["MP3", "44.1kHz", "320kbps"])
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: "ALAC", sampleRate: nil, bitDepth: 0, bitRate: nil, isDSD: false
        ) == ["ALAC"])
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: "DSF", sampleRate: 2_822_400, bitDepth: 1, bitRate: 5_645, isDSD: true
        ) == ["DSF", "DSD64", "5645kbps"])
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: "DFF", sampleRate: 11_289_600, bitDepth: 1, bitRate: nil, isDSD: true
        ) == ["DFF", "DSD256"])
        #expect(NowPlayingAudioInfoTextPolicy.specParts(
            formatName: " ", sampleRate: nil, bitDepth: nil, bitRate: nil, isDSD: false
        ).isEmpty)
    }

    @Test("The output line says whether the device resamples")
    func output() {
        let resampled = NowPlayingAudioInfoTextPolicy.output(sourceSampleRate: 96_000, outputSampleRate: 48_000)
        #expect(resampled == .init(rateText: "48kHz", match: .resampled))
        let matched = NowPlayingAudioInfoTextPolicy.output(sourceSampleRate: 44_100, outputSampleRate: 44_100.3)
        #expect(matched == .init(rateText: "44.1kHz", match: .matched))
        let unknown = NowPlayingAudioInfoTextPolicy.output(sourceSampleRate: nil, outputSampleRate: 48_000)
        #expect(unknown == .init(rateText: "48kHz", match: .sourceUnknown))
        #expect(NowPlayingAudioInfoTextPolicy.output(sourceSampleRate: 44_100, outputSampleRate: 0) == nil)
        #expect(NowPlayingAudioInfoTextPolicy.output(sourceSampleRate: 44_100, outputSampleRate: nil) == nil)
    }
}
