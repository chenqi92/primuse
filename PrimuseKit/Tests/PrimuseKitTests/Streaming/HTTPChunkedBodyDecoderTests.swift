import Foundation
import Testing
@testable import PrimuseKit

@Suite("Incremental HTTP chunked body decoding")
struct HTTPChunkedBodyDecoderTests {
    @Test("Decodes the same body whatever the network splits are", arguments: [1, 2, 3, 7, 4_096, Int.max])
    func arbitrarySplits(split: Int) throws {
        let payload = Self.payload(count: 150_000)
        let body = Self.chunked(payload, sizes: [100, 3, 16_384, 1, 70_000], extensions: true)
        var decoder = HTTPChunkedBodyDecoder()
        var decoded = Data()
        var offset = 0
        while offset < body.count {
            let end = offset + min(split, body.count - offset)
            try decoder.append(body[offset..<end]) { decoded.append($0) }
            offset = end
        }
        #expect(decoded == payload)
        #expect(decoder.isComplete)
    }

    @Test("A small chunk after a large one is read from the right place")
    func smallChunkAfterLargeOne() throws {
        let payload = Data(repeating: 0x41, count: 100) + Data("abc".utf8)
        var decoder = HTTPChunkedBodyDecoder()
        var decoded = Data()
        try decoder.append(Self.chunked(payload, sizes: [100, 3])) { decoded.append($0) }
        #expect(decoded == payload)
        #expect(decoder.isComplete)
    }

    @Test("Part of a chunk is handed out before the rest arrives")
    func partialChunk() throws {
        var decoder = HTTPChunkedBodyDecoder()
        var decoded: [Data] = []
        try decoder.append(Data("a\r\n01234".utf8)) { decoded.append($0) }
        #expect(decoded == [Data("01234".utf8)])
        #expect(!decoder.isComplete)
        try decoder.append(Data("56789\r".utf8)) { decoded.append($0) }
        try decoder.append(Data("\n0\r\n".utf8)) { decoded.append($0) }
        #expect(decoded == [Data("01234".utf8), Data("56789".utf8)])
        #expect(decoder.isComplete)
    }

    @Test("Emitted pieces start at index zero")
    func zeroBasedPieces() throws {
        var decoder = HTTPChunkedBodyDecoder()
        let body = Data("xx3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8).dropFirst(2)
        try decoder.append(body) { #expect($0.startIndex == 0) }
    }

    @Test("Bytes after the last chunk are ignored")
    func stopsAtLastChunk() throws {
        var decoder = HTTPChunkedBodyDecoder()
        var decoded = Data()
        try decoder.append(Data("5\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n3\r\nxyz\r\n".utf8)) { decoded.append($0) }
        try decoder.append(Data("3\r\nxyz\r\n".utf8)) { decoded.append($0) }
        #expect(decoded == Data("hello".utf8))
        #expect(decoder.isComplete)
    }

    @Test("Malformed framing is rejected", arguments: ["zz\r\n", "-1\r\n", "\r\n", "3\r\nabcXY"])
    func malformed(body: String) {
        var decoder = HTTPChunkedBodyDecoder()
        #expect(throws: URLError.self) {
            try decoder.append(Data(body.utf8)) { _ in }
        }
    }

    @Test("A size line that never ends is rejected")
    func endlessSizeLine() throws {
        var decoder = HTTPChunkedBodyDecoder(maximumSizeLineBytes: 16)
        try decoder.append(Data(repeating: 0x30, count: 16)) { _ in }
        #expect(throws: URLError.self) {
            try decoder.append(Data([0x30])) { _ in }
        }
    }

    static func chunked(_ payload: Data, sizes: [Int], extensions: Bool = false) -> Data {
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

    static func payload(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
