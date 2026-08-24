import Foundation
import Testing
@testable import PrimuseKit

@Suite("ISO Base Media metadata slices")
struct ISOBaseMediaMetadataSliceBuilderTests {
    @Test("Extracts ftyp and a complete trailing moov from bounded ranges")
    func buildsMetadataOnlyFile() {
        let ftyp = atom("ftyp", payload: Data("M4A ".utf8))
        let mvhd = atom("mvhd", payload: Data(repeating: 0, count: 24))
        let moov = atom("moov", payload: mvhd + atom("udta", payload: Data()))
        let head = ftyp + atom("mdat", payload: Data(repeating: 0x11, count: 32))
        let tail = Data(repeating: 0x22, count: 31) + moov

        #expect(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(head: head, tail: tail) == ftyp + moov)
    }

    @Test("Extracts a complete fast-start moov from the head range")
    func buildsMetadataOnlyFileFromHead() {
        let ftyp = atom("ftyp", payload: Data("M4A ".utf8))
        let moov = atom(
            "moov",
            payload: atom("mvhd", payload: Data(repeating: 0, count: 24))
        )
        let head = ftyp + moov + atom("mdat", payload: Data(repeating: 0x11, count: 16))

        #expect(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
            head: head,
            tail: Data()
        ) == ftyp + moov)
    }

    @Test("Rejects an incomplete moov and a false signature in payload bytes")
    func rejectsIncompleteOrFalseMoov() {
        let ftyp = atom("ftyp", payload: Data("M4A ".utf8))
        let falseSignature = Data([0, 0, 0, 32]) + Data("moov".utf8) + Data(repeating: 0, count: 4)
        #expect(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(head: ftyp, tail: falseSignature) == nil)

        let complete = atom("moov", payload: atom("mvhd", payload: Data(repeating: 0, count: 24)))
        #expect(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(
            head: ftyp,
            tail: Data(complete.dropLast())
        ) == nil)
    }

    @Test("Supports extended-size moov atoms")
    func supportsExtendedSize() {
        let ftyp = atom("ftyp", payload: Data("M4A ".utf8))
        let mvhd = atom("mvhd", payload: Data(repeating: 0, count: 24))
        let moov = extendedAtom("moov", payload: mvhd)
        #expect(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(head: ftyp, tail: moov) == ftyp + moov)
    }

    private func atom(_ type: String, payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        return bigEndian(size) + Data(type.utf8) + payload
    }

    private func extendedAtom(_ type: String, payload: Data) -> Data {
        bigEndian(UInt32(1)) + Data(type.utf8) + bigEndian(UInt64(payload.count + 16)) + payload
    }

    private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
