import Foundation
import XCTest
@testable import Primuse

/// 公网明文 http 下载的分块响应：1.12.0(108)–1.12.1(111) 在第一块之后读块大小越界闪退；
/// 只要前缀的请求(电台探测、主页取台标)遇到分块也得整段收完，电台流因此一直收到超时。
final class HTTPChunkedBodyDecodingTests: XCTestCase {
    private let url = URL(string: "http://example.com/stream")!

    func testChunkedDownloadFinishesAtLastChunkWithoutWaitingForClose() throws {
        let payload = Data(repeating: 0x41, count: 100) + Self.randomPayload(count: 300_000)
        let response = Self.header("200 OK")
            + Self.chunked(payload, sizes: [100, 3, 70_000, 1, 65_536], extensions: true)
        let box = try PlainHTTPClient.DownloadStateBox()
        defer { box.cleanup() }
        XCTAssertEqual(try feed(response, to: box, split: 4_096), response.count)
        XCTAssertEqual(try finalizedBody(box), payload)
    }

    func testChunkedPrefixDownloadStopsOnceThePrefixIsDecoded() throws {
        let payload = Self.randomPayload(count: 500_000)
        var body = Self.chunked(payload, sizes: [16_384, 7, 8_000])
        body.removeLast(5)
        let response = Self.header("200 OK") + body
        let box = try PlainHTTPClient.DownloadStateBox(wholeResponsePrefixLimit: 65_536)
        defer { box.cleanup() }
        let consumed = try XCTUnwrap(feed(response, to: box, split: 4_096))
        XCTAssertLessThan(consumed, 80_000)
        XCTAssertEqual(try finalizedBody(box), payload.prefix(65_536))
    }

    func testChunkedDownloadWithoutLastChunkIsTruncated() throws {
        var body = Self.chunked(Data("hello world".utf8), sizes: [5, 6])
        body.removeLast(5)
        let box = try PlainHTTPClient.DownloadStateBox()
        defer { box.cleanup() }
        XCTAssertNil(try feed(Self.header("200 OK") + body, to: box, split: 3))
        XCTAssertThrowsError(try box.finalize())
    }

    func testChunkedRangeResponseLimitCountsDecodedBytes() throws {
        let payload = Self.randomPayload(count: 1_024)
        let response = Self.header("206 Partial Content") + Self.chunked(payload, sizes: [512])
        let box = try PlainHTTPClient.DownloadStateBox(maximumRangedBodyBytes: 1_024)
        defer { box.cleanup() }
        XCTAssertEqual(try feed(response, to: box, split: 4_096), response.count)
        XCTAssertEqual(try finalizedBody(box), payload)

        let oversized = Self.header("206 Partial Content")
            + Self.chunked(Self.randomPayload(count: 2_000), sizes: [512])
        let limited = try PlainHTTPClient.DownloadStateBox(maximumRangedBodyBytes: 1_024)
        defer { limited.cleanup() }
        XCTAssertThrowsError(try feed(oversized, to: limited, split: 4_096))
    }

    /// 按 split 分段喂给下载状态机，返回它说「收够了」时已经喂了多少字节。
    private func feed(_ response: Data, to box: PlainHTTPClient.DownloadStateBox, split: Int) throws -> Int? {
        var offset = 0
        while offset < response.count {
            let end = min(offset + split, response.count)
            if try box.consume(response[offset..<end], responseURL: url) { return end }
            offset = end
        }
        return nil
    }

    private func finalizedBody(_ box: PlainHTTPClient.DownloadStateBox) throws -> Data {
        let (file, _) = try box.finalize()
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    private static func header(_ status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nTransfer-Encoding: chunked\r\nContent-Type: audio/mpeg\r\n\r\n".utf8)
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
