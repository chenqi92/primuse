import Testing
@testable import PrimuseKit

@Suite("HTTP byte range response policy")
struct HTTPByteRangeResponsePolicyTests {
    @Test("Exact positive and suffix responses are accepted")
    func acceptsExactRanges() {
        #expect(HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: "bytes 1048576-2097151/5000000",
            contentLength: 1_048_576,
            bodyLength: 1_048_576,
            requestedOffset: 1_048_576,
            requestedLength: 1_048_576
        ) == 5_000_000)
        #expect(HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: "bytes 4999872-4999999/5000000",
            contentLength: 128,
            bodyLength: 128,
            requestedOffset: -128,
            requestedLength: 128
        ) == 5_000_000)
    }

    @Test("Wrong offsets, expanded windows and short bodies are rejected")
    func rejectsMalformedPartialResponses() {
        #expect(HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: "bytes 0-1048575/5000000",
            contentLength: 1_048_576,
            bodyLength: 1_048_576,
            requestedOffset: 1_048_576,
            requestedLength: 1_048_576
        ) == nil)
        #expect(HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: "bytes 1048576-4999999/5000000",
            contentLength: 3_951_424,
            bodyLength: 3_951_424,
            requestedOffset: 1_048_576,
            requestedLength: 1_048_576
        ) == nil)
        #expect(HTTPByteRangeResponsePolicy.validatedTotalLength(
            contentRange: "bytes 1048576-2097151/5000000",
            contentLength: 1_048_576,
            bodyLength: 512,
            requestedOffset: 1_048_576,
            requestedLength: 1_048_576
        ) == nil)
    }

    @Test("A whole response is safe only when it fits a requested head or suffix")
    func limitsWholeResourceFallback() {
        #expect(HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
            bodyLength: 512,
            requestedOffset: 0,
            requestedLength: 1024
        ))
        #expect(HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
            bodyLength: 128,
            requestedOffset: -256,
            requestedLength: 256
        ))
        #expect(!HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
            bodyLength: 4096,
            requestedOffset: 0,
            requestedLength: 1024
        ))
        #expect(!HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
            bodyLength: 1024,
            requestedOffset: 1024,
            requestedLength: 1024
        ))
    }
}
