import Testing
@testable import PrimuseKit

@Suite("HTTP range probe policy")
struct HTTPRangeProbePolicyTests {
    @Test("Probe requests two bytes to avoid zero-end server bugs")
    func probeHeaderUsesTwoBytes() {
        #expect(HTTPRangeProbePolicy.requestHeaderValue == "bytes=0-1")
    }

    @Test("Exact range response exposes the full file length")
    func acceptsExactRange() {
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-1/12831499",
            contentLength: 2
        ) == 12_831_499)
    }

    @Test("One-byte resources may clip the requested end at EOF")
    func acceptsEOFClippedRange() {
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-0/1",
            contentLength: 1
        ) == 1)
    }

    @Test("A 206 response that expands the probe to the whole file is rejected")
    func rejectsExpandedRange() {
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-12831498/12831499",
            contentLength: 12_831_499
        ) == nil)
    }

    @Test("Mismatched content length and malformed ranges are rejected")
    func rejectsInconsistentResponses() {
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-1/100",
            contentLength: 100
        ) == nil)
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-1/100",
            contentLength: 0
        ) == nil)
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-1/100",
            contentLength: -1
        ) == nil)
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 1-2/100",
            contentLength: 2
        ) == nil)
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: "bytes 0-1/*",
            contentLength: 2
        ) == nil)
        #expect(HTTPRangeProbePolicy.validatedTotalLength(
            contentRange: nil,
            contentLength: 2
        ) == nil)
    }
}
