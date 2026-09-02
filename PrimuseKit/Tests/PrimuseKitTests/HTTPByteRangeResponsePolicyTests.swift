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

@Suite("Whole-resource metadata range policy")
struct WholeResourceMetadataRangePolicyTests {
    @Test("Unsupported suffix capability is cached for requested and final endpoints")
    func cachesUnsupportedSuffixEndpoints() {
        var cache = MetadataSuffixRangeCapabilityCache()
        cache.recordUnsupported(
            requestedEndpointKey: "https://dav.example:443",
            finalEndpointKey: "https://cdn.example:443"
        )

        #expect(cache.isUnsupported(endpointKey: "https://dav.example:443"))
        #expect(cache.isUnsupported(endpointKey: "https://cdn.example:443"))
        #expect(!cache.isUnsupported(endpointKey: "https://other.example:443"))
        #expect(!cache.isUnsupported(endpointKey: nil))
    }

    @Test("Bulk suffix probes reject a whole response without consuming its body")
    func rejectsBulkSuffixWithoutConsuming() {
        #expect(WholeResourceMetadataRangePolicy.responseDisposition(
            requestedOffset: -256,
            intent: .bulkBounded
        ) == .rejectSuffixWithoutConsuming)
        #expect(WholeResourceMetadataRangePolicy.wholeResponsePrefixLimit(
            requestedOffset: -256,
            requestedLength: 256
        ) == 0)
    }

    @Test("Explicit single-file suffix reads may use one complete fallback")
    func allowsExplicitCompleteFallback() {
        #expect(WholeResourceMetadataRangePolicy.responseDisposition(
            requestedOffset: -256,
            intent: .explicitSingleFileCompleteFallback
        ) == .useCompleteFileFallback)
        #expect(WholeResourceMetadataRangePolicy.responseDisposition(
            requestedOffset: 0,
            intent: .explicitSingleFileCompleteFallback
        ) == .consumeBoundedPrefix)
        #expect(WholeResourceMetadataRangePolicy.wholeResponsePrefixLimit(
            requestedOffset: 1024,
            requestedLength: 2048
        ) == 3072)
    }

    @Test("Head and suffix metadata windows are sliced from a complete response")
    func slicesMetadataWindows() {
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 4096,
            requestedOffset: 0,
            requestedLength: 1024
        ) == 0..<1024)
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 4096,
            requestedOffset: -256,
            requestedLength: 256
        ) == 3840..<4096)
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 512,
            requestedOffset: 0,
            requestedLength: 1024
        ) == 0..<512)
    }

    @Test("Invalid and out-of-bounds metadata windows are rejected")
    func rejectsInvalidWindows() {
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 4096,
            requestedOffset: 4096,
            requestedLength: 1
        ) == nil)
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 4096,
            requestedOffset: Int64.min,
            requestedLength: 1
        ) == nil)
        #expect(WholeResourceMetadataRangePolicy.sliceRange(
            bodyLength: 4096,
            requestedOffset: 0,
            requestedLength: 0
        ) == nil)
    }
}
