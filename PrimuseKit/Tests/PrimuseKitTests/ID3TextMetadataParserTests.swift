import Foundation
import Testing
@testable import PrimuseKit

@Test func parsesID3v23TextFramesWithoutAudioPayload() {
    let tag = makeID3v23Tag([
        textFrame("TIT2", "夜空中最亮的星"),
        textFrame("TPE1", "逃跑计划"),
        textFrame("TALB", "世界"),
        textFrame("TRCK", "3/12"),
        textFrame("TYER", "2011"),
    ])

    let metadata = ID3TextMetadataParser.parse(tag)
    #expect(metadata?.title == "夜空中最亮的星")
    #expect(metadata?.artist == "逃跑计划")
    #expect(metadata?.albumTitle == "世界")
    #expect(metadata?.trackNumber == 3)
    #expect(metadata?.year == 2011)
}

@Test func keepsTextBeforeAnIncompleteLargeArtworkFrame() {
    let title = textFrame("TIT2", "ID3 标题")
    var incompleteArtworkHeader = Data("APIC".utf8)
    incompleteArtworkHeader.append(contentsOf: [0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
    let tag = makeID3v23Tag([title, incompleteArtworkHeader])

    let metadata = ID3TextMetadataParser.parse(tag)
    #expect(metadata?.title == "ID3 标题")
}

private func textFrame(_ id: String, _ value: String) -> Data {
    var payload = Data([0x03]) // UTF-8
    payload.append(Data(value.utf8))

    var frame = Data(id.utf8)
    frame.append(uint32BE(payload.count))
    frame.append(contentsOf: [0x00, 0x00])
    frame.append(payload)
    return frame
}

private func makeID3v23Tag(_ frames: [Data]) -> Data {
    let body = frames.reduce(into: Data()) { $0.append($1) }
    var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
    tag.append(syncSafe(body.count))
    tag.append(body)
    return tag
}

private func uint32BE(_ value: Int) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

private func syncSafe(_ value: Int) -> Data {
    Data([
        UInt8((value >> 21) & 0x7F),
        UInt8((value >> 14) & 0x7F),
        UInt8((value >> 7) & 0x7F),
        UInt8(value & 0x7F),
    ])
}
