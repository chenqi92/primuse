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
