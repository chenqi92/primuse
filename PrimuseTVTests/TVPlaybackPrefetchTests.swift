#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVPlaybackPrefetchTests: XCTestCase {
    private func makeSeed() -> TVPlaybackSeed {
        TVPlaybackSeed(
            head: Data((0..<100).map { UInt8($0) }),
            tail: Data((0..<20).map { UInt8(200 + $0) }),
            totalLength: 1_000,
            contentTypeIdentifier: nil
        )
    }

    func testSeedServesHeadAndTailSlicesAndNothingInBetween() {
        let seed = makeSeed()
        XCTAssertEqual(seed.bytes(offset: 0, maximumLength: 10), Data((0..<10).map { UInt8($0) }))
        // A read crossing the end of the head stops there.
        XCTAssertEqual(seed.bytes(offset: 95, maximumLength: 50)?.count, 5)
        XCTAssertNil(seed.bytes(offset: 100, maximumLength: 10))
        XCTAssertNil(seed.bytes(offset: 500, maximumLength: 10))
        XCTAssertEqual(seed.bytes(offset: 980, maximumLength: 5), Data([200, 201, 202, 203, 204]))
        XCTAssertEqual(seed.bytes(offset: 995, maximumLength: 50)?.count, 5)
        XCTAssertNil(seed.bytes(offset: 1_000, maximumLength: 1))
        XCTAssertNil(seed.bytes(offset: -1, maximumLength: 1))
    }

    func testSeededReaderShortReadsAtTheSeedBoundaryThenUsesTheInnerReader() async throws {
        let payload = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let seed = TVPlaybackSeed(
            head: payload.prefix(100),
            // A slice keeps its parent's indices; the seed must still read it from zero.
            tail: payload.suffix(20),
            totalLength: Int64(payload.count),
            contentTypeIdentifier: nil
        )
        let inner = RecordingByteRangeReader(payload: payload)
        let reader = TVSeededByteRangeReader(inner: inner, seed: seed)

        let length = try await reader.contentLength()
        XCTAssertEqual(length, 1_000)
        let first = try await reader.read(offset: 0, length: 400)
        XCTAssertEqual(first, payload.prefix(100))
        let middle = try await reader.read(offset: 100, length: 300)
        XCTAssertEqual(middle, payload.subdata(in: 100..<400))
        let tail = try await reader.read(offset: 990, length: 10)
        XCTAssertEqual(tail, payload.suffix(10))
        let reads = await inner.reads
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.offset, 100)
    }

    func testChangedFileNeverMatchesAnOldSeed() {
        var song = Song(
            id: "song",
            title: "Song",
            fileFormat: .flac,
            filePath: "/music/song.flac",
            sourceID: "source",
            fileSize: 1_000
        )
        let original = TVPlaybackPrefetchStore.key(for: song)
        song.fileSize = 1_001
        XCTAssertNotEqual(TVPlaybackPrefetchStore.key(for: song), original)
    }
}

private actor RecordingByteRangeReader: ByteRangeReader {
    let payload: Data
    private(set) var reads: [(offset: Int64, length: Int64)] = []

    init(payload: Data) {
        self.payload = payload
    }

    func contentLength() async throws -> Int64 { Int64(payload.count) }

    func read(offset: Int64, length: Int64) async throws -> Data {
        reads.append((offset, length))
        let end = min(Int64(payload.count), offset + length)
        return payload.subdata(in: Int(offset)..<Int(end))
    }
}
#endif
