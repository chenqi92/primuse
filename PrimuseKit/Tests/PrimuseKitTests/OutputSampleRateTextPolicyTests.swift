import Foundation
import Testing
@testable import PrimuseKit

@Suite("Output sample rate text")
struct OutputSampleRateTextPolicyTests {
    @Test("A resampled output shows both rates")
    func resampled() {
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 44_100, outputSampleRate: 48_000) == "44.1 → 48 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 96_000, outputSampleRate: 48_000) == "96 → 48 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 192_000, outputSampleRate: 44_100) == "192 → 44.1 kHz")
    }

    @Test("A matching or unknown output shows the source rate only")
    func matchingOrUnknown() {
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 96_000, outputSampleRate: 96_000) == "96 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 44_100, outputSampleRate: 44_100.4) == "44.1 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 88_200, outputSampleRate: nil) == "88.2 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 48_000, outputSampleRate: 0) == "48 kHz")
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: nil, outputSampleRate: 48_000) == nil)
        #expect(OutputSampleRateTextPolicy.text(sourceSampleRate: 0, outputSampleRate: 48_000) == nil)
    }
}

@Suite("Output sample rate request")
struct OutputSampleRateRequestPolicyTests {
    @Test("A PCM song asks for its own rate when matching is on")
    func requestsSongRate() {
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: 96_000, isVideo: false
        ) == 96_000)
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: 44_100, isVideo: false
        ) == 44_100)
    }

    @Test("Nothing is requested when matching is off or for music videos")
    func offOrVideo() {
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: false, sourceSampleRate: 96_000, isVideo: false
        ) == nil)
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: 48_000, isVideo: true
        ) == nil)
    }

    @Test("Unknown rates and DSD bit rates are not requested")
    func unknownOrDSD() {
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: nil, isVideo: false
        ) == nil)
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: 0, isVideo: false
        ) == nil)
        #expect(OutputSampleRateRequestPolicy.requestedSampleRate(
            enabled: true, sourceSampleRate: 2_822_400, isVideo: false
        ) == nil)
    }
}
