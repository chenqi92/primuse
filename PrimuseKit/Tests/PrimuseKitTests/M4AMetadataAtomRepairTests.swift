import Foundation
import Testing
@testable import PrimuseKit

struct M4AMetadataAtomRepairTests {
    private func atom(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        data.append(type.data(using: .isoLatin1)!)
        data.append(payload)
        return data
    }

    private func item(_ type: String, _ value: String?) -> Data {
        guard let value else { return atom(type, Data()) }
        var payload = Data([0, 0, 0, 1, 0, 0, 0, 0])
        payload.append(Data(value.utf8))
        return atom(type, atom("data", payload))
    }

    private func file(items: [Data], underUserData: Bool = true) -> Data {
        let ilst = atom("ilst", items.reduce(Data(), +))
        let hdlr = atom("hdlr", Data(repeating: 0, count: 8) + Data("mdir".utf8) + Data(repeating: 0, count: 13))
        let meta = atom("meta", Data([0, 0, 0, 0]) + hdlr + ilst + atom("free", Data(repeating: 0, count: 32)))
        let moovPayload = underUserData ? atom("udta", meta) : meta
        return atom("ftyp", Data("M4A ".utf8) + Data(repeating: 0, count: 4))
            + atom("moov", atom("mvhd", Data(repeating: 0, count: 12)) + moovPayload)
            + atom("mdat", Data(repeating: 7, count: 20))
    }

    private func types(in data: Data) -> [String] {
        // ilst children, in order
        guard let range = data.range(of: Data("ilst".utf8)) else { return [] }
        let start = range.lowerBound - 4
        let size = data[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        var cursor = start + 8
        var result: [String] = []
        while cursor + 8 <= start + size {
            let itemSize = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            result.append(String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .isoLatin1) ?? "?")
            cursor += itemSize
        }
        return result
    }

    /// meta 里紧跟在 ilst 后面的那个 free 的大小。
    private func paddingAfterItemList(in data: Data) -> Int? {
        guard let range = data.range(of: Data("ilst".utf8)) else { return nil }
        let start = range.lowerBound - 4
        let size = data[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let next = start + size
        guard next + 8 <= data.count,
              String(data: data[(next + 4)..<(next + 8)], encoding: .isoLatin1) == "free" else { return nil }
        return data[next..<(next + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }

    @Test func sfbAlbumIsRenamedAndEmptyItemsLeaveTheList() throws {
        let input = file(items: [
            item("----", "iTunSMPB"),
            item("covr", nil),
            item("©alb", "Old"),
            item("©ALB", "New"),
            atom("©cmt", atom("data", Data([0, 0, 0, 1, 0, 0, 0, 0]))),
            item("©nam", "Song"),
        ])
        let result = try #require(M4AMetadataAtomRepair.repaired(input))
        #expect(result.data.count == input.count)
        #expect(types(in: result.data) == ["----", "©alb", "©nam"])
        #expect(result.renamedAlbumItems == 1)
        #expect(result.removedItems == 3)
        // 被删的空封面 8、旧专辑 27、空注释 24 字节,并进原来 40 字节的填充。
        #expect(paddingAfterItemList(in: result.data) == 40 + 8 + 27 + 24)
        #expect(result.data.range(of: Data("New".utf8)) != nil)
        #expect(result.data.range(of: Data("Old".utf8)) == nil)
        #expect(result.rewrites.count == 1)
        var patched = input
        for rewrite in result.rewrites {
            patched.replaceSubrange(rewrite.offset..<(rewrite.offset + rewrite.bytes.count), with: rewrite.bytes)
        }
        #expect(patched == result.data)
    }

    @Test func clearedAlbumRemovesBothSpellings() throws {
        let input = file(items: [item("©alb", "Old"), item("©ALB", nil), item("©nam", "Song")])
        let result = try #require(M4AMetadataAtomRepair.repaired(input))
        #expect(types(in: result.data) == ["©nam"])
        #expect(result.renamedAlbumItems == 0)
        #expect(result.data.count == input.count)
    }

    @Test func freeItemsInsideTheListAreRemovedToo() throws {
        let input = file(items: [item("©nam", "Song"), atom("free", Data(repeating: 0, count: 16)), item("©ART", "A")])
        let result = try #require(M4AMetadataAtomRepair.repaired(input))
        #expect(types(in: result.data) == ["©nam", "©ART"])
        #expect(paddingAfterItemList(in: result.data) == 40 + 24)
    }

    @Test func untouchedAlbumStaysWhenSFBDidNotWriteOne() throws {
        let input = file(items: [item("©alb", "Kept"), item("©nam", "Song")], underUserData: false)
        let result = try #require(M4AMetadataAtomRepair.repaired(input))
        #expect(types(in: result.data) == ["©alb", "©nam"])
        #expect(!result.changed)
        #expect(result.data == input)
    }

    @Test func nonMP4DataIsLeftAlone() {
        #expect(M4AMetadataAtomRepair.repaired(Data("not an mp4 file at all".utf8)) == nil)
        #expect(M4AMetadataAtomRepair.repaired(Data()) == nil)
    }
}
