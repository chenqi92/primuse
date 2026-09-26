import Foundation
import Testing
@testable import PrimuseKit

@Suite("Trailing array JSON encoding")
struct TrailingArrayJSONEncodingTests {
    private struct Item: Codable, Equatable {
        var id: String
        var title: String
        var note: String?
        var addedAt: Date
    }

    /// 与曲库快照同形: 排序后 `songs` 是最后一个键, 前面有嵌套对象和同名的内层键。
    private struct Envelope: Codable, Equatable {
        var songs: [Item]
        var playlists: [[String: [String]]]
        var recent: [String]?
        var smart: [String: String]?
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func items(_ count: Int) -> [Item] {
        (0..<count).map { index in
            Item(
                id: String(format: "%064x", index),
                title: "歌曲 \(index) \"quoted\" / slash \\ back",
                note: index.isMultiple(of: 3) ? nil : "songs\":[]}",
                addedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
            )
        }
    }

    private func spliced(_ envelope: Envelope, chunkSize: Int) throws -> Data? {
        let encoder = makeEncoder()
        var head = envelope
        head.songs = []
        return try TrailingArrayJSONEncoding.encode(
            emptyArrayObject: encoder.encode(head),
            trailingKey: "songs",
            elements: envelope.songs,
            encoder: encoder,
            chunkSize: chunkSize
        )
    }

    @Test("Spliced output is byte-identical to encoding the whole value", arguments: [0, 1, 7, 1000, 2503])
    func byteIdentical(count: Int) throws {
        let envelope = Envelope(
            songs: items(count),
            playlists: [["songs": ["a", "b"]], [:]],
            recent: ["x"],
            smart: ["songs": "[]"]
        )
        let whole = try makeEncoder().encode(envelope)
        for chunkSize in [1, 3, 1000, 5000] {
            let data = try #require(try spliced(envelope, chunkSize: chunkSize))
            #expect(data == whole)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Envelope.self, from: whole) == envelope)
    }

    @Test("Refuses to splice when the array is not the last member")
    func refusesWhenKeyIsNotLast() throws {
        struct Later: Codable { var songs: [Item]; var zeta: Int }
        let encoder = makeEncoder()
        let data = try TrailingArrayJSONEncoding.encode(
            emptyArrayObject: encoder.encode(Later(songs: [], zeta: 1)),
            trailingKey: "songs",
            elements: items(3),
            encoder: encoder
        )
        #expect(data == nil)
    }

    @Test("Refuses a suffix that is only the tail of a string value")
    func refusesStringTail() throws {
        let encoder = makeEncoder()
        let data = try TrailingArrayJSONEncoding.encode(
            emptyArrayObject: Data(#"{"a":"x\"songs":[]}"#.utf8),
            trailingKey: "songs",
            elements: items(1),
            encoder: encoder
        )
        #expect(data == nil)
    }

    @Test("Refuses pretty-printed output")
    func refusesPrettyPrinted() throws {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try TrailingArrayJSONEncoding.encode(
            emptyArrayObject: Data(#"{"songs":[]}"#.utf8),
            trailingKey: "songs",
            elements: items(1),
            encoder: encoder
        )
        #expect(data == nil)
    }
}
