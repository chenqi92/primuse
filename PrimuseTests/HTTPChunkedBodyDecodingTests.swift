import Foundation
import XCTest
@testable import Primuse

/// 1.12.0(108)–1.12.1(111) 的分块下载闪退：读下一行块大小时把 Data 的绝对下标
/// 当成个数传给 removeFirst，第一块之后的任何一行都会多删甚至越界陷阱。
final class HTTPChunkedBodyDecodingTests: XCTestCase {
    func testChunkedDownloadDecodesSmallChunkAfterLargeOne() throws {
        let payload = Data(repeating: 0x41, count: 100) + Data("abc".utf8)
        XCTAssertEqual(try decodeFile(Self.chunked(payload, sizes: [100, 3])), payload)
    }

    func testChunkedDownloadDecodesChunksAcrossReadBoundaries() throws {
        let payload = Self.randomPayload(count: 300_000)
        let body = Self.chunked(payload, sizes: [8_192, 1, 70_000, 4_093, 65_536], extensions: true)
        XCTAssertEqual(try decodeFile(body), payload)
    }

    func testChunkedDownloadRejectsTruncatedBody() throws {
        var body = Self.chunked(Data("hello world".utf8), sizes: [5, 6])
        body.removeLast(9)
        XCTAssertThrowsError(try decodeFile(body))
    }

    func testRadioChunkedStreamDecodesAcrossArbitrarySplits() throws {
        let payload = Self.randomPayload(count: 150_000)
        let body = Self.chunked(payload, sizes: [100, 3, 16_384, 1, 70_000], extensions: true)
        for split in [1, 7, 4_096, body.count] {
            var decoder = RadioHTTPChunkedBodyDecoder()
            var decoded = Data()
            var offset = 0
            while offset < body.count {
                let end = min(offset + split, body.count)
                try decoder.append(body[offset..<end]) { decoded.append($0) }
                offset = end
            }
            XCTAssertEqual(decoded, payload, "split=\(split)")
        }
    }

    func testRadioChunkedStreamStopsAtLastChunk() throws {
        var decoder = RadioHTTPChunkedBodyDecoder()
        var decoded = Data()
        let body = Self.chunked(Data("hello world".utf8), sizes: [5, 6]) + Data("3\r\nxyz\r\n".utf8)
        try decoder.append(body) { decoded.append($0) }
        try decoder.append(Data("3\r\nxyz\r\n".utf8)) { decoded.append($0) }
        XCTAssertEqual(decoded, Data("hello world".utf8))
    }

    private func decodeFile(_ body: Data) throws -> Data {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPChunkedBodyDecodingTests-\(UUID().uuidString)")
        try body.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = try PlainHTTPClient.decodeChunkedFile(input)
        defer { try? FileManager.default.removeItem(at: output) }
        return try Data(contentsOf: output)
    }

    private static func chunked(_ payload: Data, sizes: [Int], extensions: Bool = false) -> Data {
        var body = Data()
        var offset = 0
        var index = 0
        while offset < payload.count {
            let count = min(sizes[index % sizes.count], payload.count - offset)
            let extensionText = extensions && index % 2 == 1 ? ";name=value" : ""
            body.append(Data((String(count, radix: 16) + extensionText + "\r\n").utf8))
            body.append(payload[offset..<(offset + count)])
            body.append(Data("\r\n".utf8))
            offset += count
            index += 1
        }
        body.append(Data("0\r\n\r\n".utf8))
        return body
    }

    private static func randomPayload(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
