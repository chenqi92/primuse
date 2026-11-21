import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ordered embedded artwork")
struct EmbeddedPictureArchiveTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let first = Data([1, 2, 3])
    private let back = Data([4, 5, 6, 7])

    private func be(_ value: Int, _ count: Int = 4) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    private func box(_ name: String, _ data: Data) -> Data {
        be(data.count + 8) + name.data(using: .isoLatin1)! + data
    }

    private func movie(_ pictures: [Data]) -> Data {
        let values = pictures.map { box("data", be(13) + be(0) + $0) }.reduce(Data(), +)
        let list = box("ilst", box("covr", values) + box("©nam", box("data", be(1) + be(0) + Data("Track".utf8))))
        return box("moov", box("udta", box("meta", be(0) + list)))
    }

    @Test func changesOnlyTheSecondOccurrenceOfAnIdenticalM4APicture() throws {
        let audio = box("mdat", Data(repeating: 33, count: 80))
        let header = box("ftyp", Data("M4A ".utf8))
        let oldMovie = movie([first, first, back])
        let file = header + oldMovie + audio
        let original = try EmbeddedPictureArchive.pictures(in: file, format: .m4a)
        #expect(original.count == 3)
        #expect(original[0].id != original[1].id)
        let updated = try EmbeddedPictureArchive.replacing(in: file, format: .m4a, edits: [original[1].id: png])
        #expect(try EmbeddedPictureArchive.pictures(in: updated, format: .m4a).map(\.data) == [first, png, back])
        #expect(updated.subdata(in: (header.count + oldMovie.count)..<file.count) == audio)
        let untouched = try OrderedTagContainer.items(in: updated, format: .m4a).filter { $0.key == "©nam" }
        #expect(untouched.first?.payload == box("data", be(1) + be(0) + Data("Track".utf8)))
        #expect(throws: OrderedTagContainer.Failure.self) {
            try EmbeddedPictureArchive.replacing(in: updated, format: .m4a, edits: [original[1].id: back])
        }
    }

    @Test func restoresOrderAndDuplicatesAfterATextEdit() throws {
        let original = movie([first, first, back])
        let rewritten = movie([back, first])
        let restored = try EmbeddedPictureArchive.preserving(from: original, in: rewritten, format: .m4a)
        #expect(try EmbeddedPictureArchive.pictures(in: restored, format: .m4a).map(\.data) == [first, first, back])
    }

    @Test func keepsID3PictureDescriptionsAndMultipleFronts() throws {
        func frame(role: UInt8, description: String, data: Data) -> Data {
            let body = Data([0]) + Data("image/jpeg".utf8) + Data([0, role])
                + Data(description.utf8) + Data([0]) + data
            return Data("APIC".utf8) + be(body.count) + Data([0, 0]) + body
        }
        let a = frame(role: 3, description: "first", data: first)
        let b = frame(role: 3, description: "alternate", data: first)
        let c = frame(role: 4, description: "rear", data: back)
        let frames = a + b + c
        let length = Data([21, 14, 7, 0].map { UInt8((frames.count >> $0) & 127) })
        let audio = Data(repeating: 0xff, count: 16)
        let file = Data([73, 68, 51, 3, 0, 0]) + length + frames + audio
        let originals = try EmbeddedPictureArchive.pictures(in: file, format: .mp3)
        let updated = try EmbeddedPictureArchive.replacing(in: file, format: .mp3, edits: [originals[1].id: png])
        let after = try EmbeddedPictureArchive.pictures(in: updated, format: .mp3)
        #expect(after.map(\.role) == [3, 3, 4])
        #expect(after.map(\.data) == [first, png, back])
        #expect(updated.range(of: Data("alternate".utf8)) != nil)
        #expect(updated.range(of: a) != nil)
        #expect(updated.range(of: c) != nil)
        #expect(updated.suffix(audio.count) == audio)
    }

    @Test func keepsFLACPictureRolesDescriptionsAndAudio() throws {
        func picture(role: Int, name: String, bytes: Data, last: Bool) -> Data {
            let mime = Data("image/jpeg".utf8)
            let desc = Data(name.utf8)
            var body = be(role) + be(mime.count) + mime + be(desc.count) + desc
            body += be(1) + be(1) + be(24) + be(0) + be(bytes.count) + bytes
            return Data([last ? 0x86 : 6]) + be(body.count, 3) + body
        }
        let a = picture(role: 3, name: "front", bytes: first, last: false)
        let b = picture(role: 4, name: "rear", bytes: back, last: true)
        let audio = Data([0xff, 0xf8, 0x01])
        let file = Data("fLaC".utf8) + Data([0, 0, 0, 34]) + Data(count: 34) + a + b + audio
        let originals = try EmbeddedPictureArchive.pictures(in: file, format: .flac)
        let updated = try EmbeddedPictureArchive.replacing(in: file, format: .flac, edits: [originals[1].id: png])
        let after = try EmbeddedPictureArchive.pictures(in: updated, format: .flac)
        #expect(after.map(\.role) == [3, 4])
        #expect(after.map(\.data) == [first, png])
        #expect(updated.range(of: Data("rear".utf8)) != nil)
        #expect(updated.range(of: a) != nil)
        #expect(updated.suffix(audio.count) == audio)
    }
}
