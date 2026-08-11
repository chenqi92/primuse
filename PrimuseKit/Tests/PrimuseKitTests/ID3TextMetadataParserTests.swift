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

@Test func recoversUTF8TextWhenV24FrameSizeUsesCharacterCount() {
    let title = malformedV24TextFrame("TIT2", "对面的女孩看过来")
    let artist = textFrameV24("TPE1", "任贤齐")
    let metadata = ID3TextMetadataParser.parse(makeID3v24Tag([title, artist]))

    #expect(metadata?.title == "对面的女孩看过来")
    #expect(metadata?.artist == "任贤齐")
    #expect(!MediaMetadataTextRepair.isSuspicious(metadata?.title))
}

@Test func parsesLegacyID3TextFromGB18030Big5AndLatin1Bytes() throws {
    let gb18030 = legacyTextFrame("TIT2", bytes: [0xD6, 0xD0, 0xCE, 0xC4])
    let big5 = legacyTextFrame(
        "TPE1",
        bytes: [0xA7, 0x69, 0xA5, 0xD5, 0xAE, 0xF0, 0xB2, 0x79]
    )
    let latin1 = legacyTextFrame("TALB", bytes: [0x42, 0x6A, 0xF6, 0x72, 0x6B])
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([gb18030, big5, latin1]))

    #expect(metadata?.title == "中文")
    #expect(metadata?.artist == "告白氣球")
    #expect(metadata?.albumTitle == "Björk")
}

@Test func parsesFourByteGB18030ScalarWithoutGuessingValidUTF8() {
    let title = legacyTextFrame("TIT2", bytes: [0x94, 0x39, 0xFC, 0x36])
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([title]))

    #expect(metadata?.title == "😀")
}

@Test func preservesReplacementEvidenceForFilenameFallback() {
    let title = textFrame("TIT2", "\u{FFFD}倀勬彿淇")
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([title]))

    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: metadata?.title ?? ""))
    #expect(MediaMetadataTextRepair.isSuspicious(metadata?.title))
}

@Test func parsesLegacyID3v1TailFromIndependentRawBytes() {
    let tag = makeID3v1Tag(
        title: [0xD6, 0xD0, 0xCE, 0xC4],
        artist: [0xA7, 0x69, 0xA5, 0xD5, 0xAE, 0xF0, 0xB2, 0x79],
        album: [0x42, 0x6A, 0xF6, 0x72, 0x6B],
        year: Array("1998".utf8),
        track: 7
    )
    let metadata = ID3TextMetadataParser.parse(Data(repeating: 0xAA, count: 256) + tag)

    #expect(metadata?.title == "中文")
    #expect(metadata?.artist == "告白氣球")
    #expect(metadata?.albumTitle == "Björk")
    #expect(metadata?.year == 1998)
    #expect(metadata?.trackNumber == 7)
}

@Test func prefersID3v2AndUsesID3v1OnlyForMissingFields() {
    let title = textFrame("TIT2", "合法 UTF-8 标题")
    let tail = makeID3v1Tag(
        title: Array("旧标题".utf8),
        artist: Array("尾部艺术家".utf8)
    )
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([title]) + tail)

    #expect(metadata?.title == "合法 UTF-8 标题")
    #expect(metadata?.artist == "尾部艺术家")
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

private func legacyTextFrame(_ id: String, bytes: [UInt8]) -> Data {
    var payload = Data([0x00])
    payload.append(contentsOf: bytes)

    var frame = Data(id.utf8)
    frame.append(uint32BE(payload.count))
    frame.append(contentsOf: [0x00, 0x00])
    frame.append(payload)
    return frame
}

private func makeID3v1Tag(
    title: [UInt8] = [],
    artist: [UInt8] = [],
    album: [UInt8] = [],
    year: [UInt8] = [],
    track: UInt8? = nil
) -> Data {
    func padded(_ bytes: [UInt8], count: Int) -> [UInt8] {
        Array(bytes.prefix(count)) + Array(repeating: 0, count: max(0, count - bytes.count))
    }

    var tag = Data("TAG".utf8)
    tag.append(contentsOf: padded(title, count: 30))
    tag.append(contentsOf: padded(artist, count: 30))
    tag.append(contentsOf: padded(album, count: 30))
    tag.append(contentsOf: padded(year, count: 4))
    if let track {
        tag.append(contentsOf: Array(repeating: 0, count: 28))
        tag.append(0)
        tag.append(track)
    } else {
        tag.append(contentsOf: Array(repeating: 0, count: 30))
    }
    tag.append(0)
    return tag
}

private func makeID3v23Tag(_ frames: [Data]) -> Data {
    let body = frames.reduce(into: Data()) { $0.append($1) }
    var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
    tag.append(syncSafe(body.count))
    tag.append(body)
    return tag
}

private func textFrameV24(_ id: String, _ value: String) -> Data {
    var payload = Data([0x03])
    payload.append(Data(value.utf8))
    var frame = Data(id.utf8)
    frame.append(syncSafe(payload.count))
    frame.append(contentsOf: [0x00, 0x00])
    frame.append(payload)
    return frame
}

private func malformedV24TextFrame(_ id: String, _ value: String) -> Data {
    var payload = Data([0x03])
    payload.append(Data(value.utf8))
    var frame = Data(id.utf8)
    frame.append(syncSafe(value.count + 1))
    frame.append(contentsOf: [0x00, 0x00])
    frame.append(payload)
    return frame
}

private func makeID3v24Tag(_ frames: [Data]) -> Data {
    let body = frames.reduce(into: Data()) { $0.append($1) }
    var tag = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
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
