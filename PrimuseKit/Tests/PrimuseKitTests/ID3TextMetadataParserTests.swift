import Foundation
import Testing
@testable import PrimuseKit

@Test func keepsSerializedArtistSuffixOutsideTheID3AlbumValue() {
    let metadata = ID3TextMetadataParser.parse(makeID3v24Tag([
        textFrameV24("TALB", "闆ㄤ竴鐩翠笅\0ARTIST=寮犲"),
        textFrameV24("TPE1", "张宇"),
    ]))
    #expect(metadata?.albumTitle == "雨一直下")
    #expect(metadata?.artist == "张宇")
}

@Test func readsEveryID3v24GenreAndLegacyGenreReferences() throws {
    let v24 = try #require(ID3TextMetadataParser.parse(makeID3v24Tag([
        textFrameV24("TIT2", "Song"),
        textFrameV24("TCON", "Rock\0Pop\0(17)"),
    ])))
    #expect(v24.genre == "Rock; Pop")

    let v23 = try #require(ID3TextMetadataParser.parse(makeID3v23Tag([
        textFrame("TIT2", "Song"),
        textFrame("TCON", "(17)(13)"),
    ])))
    #expect(v23.genre == "Rock; Pop")

    // 斜杠原样留在歌曲里，浏览时再按格式惯例拆，文件和库里存的值都不改。
    let slash = try #require(ID3TextMetadataParser.parse(makeID3v23Tag([textFrame("TCON", "流行/摇滚")])))
    #expect(slash.genre == "流行/摇滚")
}

@Test(arguments: [2, 3, 4], [UInt8(0), 1, 2, 3])
func parsesAlbumArtistSeparatelyFromTrackArtist(version: Int, encoding: UInt8) throws {
    let metadata = try #require(ID3TextMetadataParser.parse(albumArtistTag(
        version: version,
        encoding: encoding,
        fields: [(version == 2 ? "TP1" : "TPE1", "Track Singer"),
                 (version == 2 ? "TP2" : "TPE2", "Album Artist")]
    )))

    #expect(metadata.artist == "Track Singer")
    #expect(metadata.albumArtist == "Album Artist")
    #expect(metadata.albumArtists == ["Album Artist"])
}

@Test(arguments: [UInt8(0), 1, 2, 3])
func preservesNullSeparatedAlbumArtistsAcrossTextEncodings(encoding: UInt8) throws {
    let metadata = try #require(ID3TextMetadataParser.parse(albumArtistTag(
        version: 4,
        encoding: encoding,
        fields: [("TPE1", "Singer One\0Singer Two"), ("TPE2", "Host\0Guest")]
    )))
    #expect(metadata.artists == ["Singer One", "Singer Two"])
    #expect(metadata.artist == "Singer One; Singer Two")
    #expect(metadata.albumArtists == ["Host", "Guest"])
    #expect(metadata.albumArtist == "Host; Guest")
}

@Test(arguments: [2, 3, 4], ["ALBUMARTIST", "Album Artist", "album_artist"])
func parsesCustomAlbumArtistWithoutChangingTrackArtist(version: Int, key: String) throws {
    let metadata = try #require(ID3TextMetadataParser.parse(albumArtistTag(
        version: version,
        encoding: version == 4 ? 3 : 1,
        fields: [(version == 2 ? "TP1" : "TPE1", "歌曲艺人"),
                 (version == 2 ? "TXX" : "TXXX", "\(key)\0专辑艺人")]
    )))

    #expect(metadata.artist == "歌曲艺人")
    #expect(metadata.albumArtist == "专辑艺人")
}

@Test(arguments: [false, true])
func standardAlbumArtistOverridesCustomFieldsRegardlessOfOrder(customFirst: Bool) {
    let standard = textFrame("TPE2", "Standard Artist")
    let custom = textFrame("TXXX", "ALBUMARTIST\0Custom Artist")
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag(
        customFirst ? [custom, standard] : [standard, custom]
    ))

    #expect(metadata?.albumArtist == "Standard Artist")
}

@Test func customAlbumArtistPreservesMultipleValuesAndIgnoresSortFields() {
    let metadata = ID3TextMetadataParser.parse(makeID3v24Tag([
        textFrameV24("TPE2", " \0"),
        textFrameV24("TXXX", "ALBUMARTISTSORT\0Sort Artist"),
        textFrameV24("TXXX", "ALBUMARTIST\0Artist A\0Artist B"),
        textFrameV24("TXXX", "ALBUMARTIST\0Artist B"),
        textFrameV24("TXXX", "ALBUM ARTIST\0Lower Priority Alias"),
    ]))

    #expect(metadata?.albumArtist == "Artist A; Artist B")
    #expect(metadata?.artist == nil)
}

@Test func ignoresEmptyTruncatedAndUnrelatedUserTextAlbumArtistFields() {
    for value in ["ALBUMARTIST", "ALBUMARTIST\0 \0", "ALBUMARTISTSORT\0Sort Artist",
                  "MusicBrainz Album Artist Id\0identifier", "COMMENT\0ALBUMARTIST"] {
        let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([
            textFrame("TPE1", "Track Singer"),
            textFrame("TXXX", value),
        ]))
        #expect(metadata?.albumArtist == nil)
        #expect(metadata?.artist == "Track Singer")
    }
}

@Test func customAlbumArtistInheritsUTF16BigEndianByteOrder() {
    var payload = Data([1, 0xFE, 0xFF])
    payload.append("ALBUMARTIST\0专辑艺人".data(using: .utf16BigEndian)!)
    var frame = Data("TXXX".utf8)
    frame.append(uint32BE(payload.count))
    frame.append(contentsOf: [0, 0])
    frame.append(payload)
    #expect(ID3TextMetadataParser.parse(makeID3v23Tag([frame]))?.albumArtist == "专辑艺人")
}

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

@Test func preservesID3v24NullSeparatedTrackArtists() {
    let metadata = ID3TextMetadataParser.parse(makeID3v24Tag([
        textFrameV24("TPE1", "Artist A\0Artist B"),
    ]))

    #expect(metadata?.artists == ["Artist A", "Artist B"])
    #expect(metadata?.artist == "Artist A; Artist B")
}

@Test func preservesRepeatedTrackArtistFrames() {
    let metadata = ID3TextMetadataParser.parse(makeID3v23Tag([
        textFrame("TPE1", "Artist A"),
        textFrame("TPE1", "Artist B"),
    ]))

    #expect(metadata?.artists == ["Artist A", "Artist B"])
    #expect(metadata?.artist == "Artist A; Artist B")
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

@Test func mergesIndependentHeadAndTailWithoutConcatenatingTheirStorage() {
    let head = makeID3v23Tag([
        textFrame("TIT2", "头部标题"),
        textFrame("TALB", "头部专辑"),
    ]) + Data(repeating: 0xAA, count: 4 * 1024 * 1024)
    let tail = Data(repeating: 0xBB, count: 256 * 1024 - 128) + makeID3v1Tag(
        title: Array("尾部旧标题".utf8),
        artist: Array("尾部艺术家".utf8),
        year: Array("2008".utf8),
        track: 9
    )

    let metadata = ID3TextMetadataParser.parse(head: head, tail: tail)

    #expect(metadata?.title == "头部标题")
    #expect(metadata?.albumTitle == "头部专辑")
    #expect(metadata?.artist == "尾部艺术家")
    #expect(metadata?.year == 2008)
    #expect(metadata?.trackNumber == 9)
}

@Test func damagedIndependentTailDoesNotReplaceHeadMetadata() {
    let head = makeID3v23Tag([
        textFrame("TIT2", "保留标题"),
        textFrame("TPE1", "保留艺术家"),
    ])

    let metadata = ID3TextMetadataParser.parse(
        head: head,
        tail: Data(repeating: 0xFF, count: 256 * 1024)
    )

    #expect(metadata?.title == "保留标题")
    #expect(metadata?.artist == "保留艺术家")
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

private func albumArtistTag(
    version: Int,
    encoding: UInt8,
    fields: [(String, String)]
) -> Data {
    let stringEncoding: String.Encoding = switch encoding {
    case 0: .isoLatin1
    case 1: .utf16
    case 2: .utf16BigEndian
    default: .utf8
    }
    let frames = fields.map { id, value in
        let payload = Data([encoding]) + value.data(using: stringEncoding)!
        var frame = Data(id.utf8)
        if version == 2 {
            frame.append(uint32BE(payload.count).suffix(3))
        } else {
            frame.append(version == 4 ? syncSafe(payload.count) : uint32BE(payload.count))
            frame.append(contentsOf: [0, 0])
        }
        frame.append(payload)
        return frame
    }
    if version == 4 { return makeID3v24Tag(frames) }
    if version == 3 { return makeID3v23Tag(frames) }
    let body = frames.reduce(into: Data()) { $0.append($1) }
    return Data([0x49, 0x44, 0x33, 2, 0, 0]) + syncSafe(body.count) + body
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
