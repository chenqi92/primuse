import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata range window")
struct MetadataRangeWindowPolicyTests {
    @Test func suffixBecomesAnAbsoluteRangeOnceTheSizeIsKnown() throws {
        let window = try #require(MetadataRangeWindowPolicy.resolvedWindow(
            offset: -131_072, length: 131_072, knownFileSize: 35_000_000
        ))
        #expect(window.offset == 34_868_928)
        #expect(window.length == 131_072)
    }

    @Test func suffixLongerThanTheFileStartsAtZero() throws {
        let window = try #require(MetadataRangeWindowPolicy.resolvedWindow(
            offset: -262_144, length: 262_144, knownFileSize: 100_000
        ))
        #expect(window.offset == 0)
        #expect(window.length == 100_000)
    }

    @Test func unknownSizeAndForwardReadsAreUnchanged() throws {
        let suffix = try #require(MetadataRangeWindowPolicy.resolvedWindow(
            offset: -4_096, length: 4_096, knownFileSize: nil
        ))
        #expect(suffix.offset == -4_096)
        #expect(suffix.length == 4_096)
        let head = try #require(MetadataRangeWindowPolicy.resolvedWindow(
            offset: 262_144, length: 1_000, knownFileSize: 35_000_000
        ))
        #expect(head.offset == 262_144)
        #expect(head.length == 1_000)
    }

    @Test func emptyRequestsNeedNoRead() {
        #expect(MetadataRangeWindowPolicy.resolvedWindow(offset: 0, length: 0, knownFileSize: 10)?.length == nil)
        #expect(MetadataRangeWindowPolicy.resolvedWindow(offset: Int64.min, length: 10, knownFileSize: nil)?.length == nil)
        // 尾部比文件起点还早又被裁成空: 文件大小未知时不会走到这里, 已知时至少剩一个字节。
        #expect(MetadataRangeWindowPolicy.resolvedWindow(offset: -10, length: 10, knownFileSize: 5)?.length == 5)
    }

    @Test func wholeResponseCoveringTheRequestedHeadIsNotRangeEvidence() {
        // 文件只有 100 KB, 要了开头 256 KB: 服务器回 200 整个文件是正常的。
        #expect(!MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
            requestedOffset: 0, requestedLength: 262_144, contentLength: 100_000
        ))
        #expect(MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
            requestedOffset: 0, requestedLength: 262_144, contentLength: 35_000_000
        ))
        // 不知道多长、不是从头读、尾部读取: 都算不认 Range。
        #expect(MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
            requestedOffset: 0, requestedLength: 262_144, contentLength: nil
        ))
        #expect(MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
            requestedOffset: 262_144, requestedLength: 1_000, contentLength: 300_000
        ))
        #expect(MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
            requestedOffset: -4_096, requestedLength: 4_096, contentLength: 300_000
        ))
    }
}
