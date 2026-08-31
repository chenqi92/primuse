import Foundation
import Testing
@testable import PrimuseKit

@Suite("Embedded container tag parsing")
struct EmbeddedTagMetadataParserTests {
    @Test func parsesAPEv2TextReplayGainAndFrontCoverBeforeID3v1() {
        let image = pngFixture
        let tag = makeAPEv2Tag([
            apeTextItem("Title", "APEv2 标题"),
            apeTextItem("Artist", "歌手甲\0歌手乙"),
            apeTextItem("Album", "无损专辑"),
            apeTextItem("Album Artist", "专辑歌手"),
            apeTextItem("Track", "7/12"),
            apeTextItem("Disc", "2/3"),
            apeTextItem("Year", "2024-01-02"),
            apeTextItem("Genre", "Rock"),
            apeTextItem("Lyrics", "第一行\n第二行"),
            apeTextItem("REPLAYGAIN_TRACK_GAIN", "-7.25 dB"),
            apeBinaryItem("Cover Art (Front)", Data("cover.png\0".utf8) + image),
        ])
        let tail = Data(repeating: 0xA5, count: 64) + tag + makeID3v1Padding()

        let metadata = EmbeddedTagMetadataParser.parse(
            head: Data(),
            tail: tail,
            fileExtension: "ape"
        )

        #expect(metadata?.title == "APEv2 标题")
        #expect(metadata?.artists == ["歌手甲", "歌手乙"])
        #expect(metadata?.artist == "歌手甲; 歌手乙")
        #expect(metadata?.albumTitle == "无损专辑")
        #expect(metadata?.albumArtist == "专辑歌手")
        #expect(metadata?.trackNumber == 7)
        #expect(metadata?.discNumber == 2)
        #expect(metadata?.year == 2024)
        #expect(metadata?.genre == "Rock")
        #expect(metadata?.lyrics == "第一行\n第二行")
        #expect(metadata?.replayGainTrackGain == -7.25)
        #expect(metadata?.coverArtData == image)
    }

    @Test func parsesAPEv2AtExactTTAEnd() {
        let tail = Data(repeating: 0x5A, count: 96) + makeAPEv2Tag([
            apeTextItem("title", "TTA 标签标题"),
            apeTextItem("artist", "TTA 标签歌手"),
            apeTextItem("album_artist", "TTA 专辑歌手"),
            apeTextItem("track", "7/10"),
        ])

        let metadata = EmbeddedTagMetadataParser.parse(
            head: Data("TTA1".utf8),
            tail: tail,
            fileExtension: "tta"
        )

        #expect(metadata?.title == "TTA 标签标题")
        #expect(metadata?.artist == "TTA 标签歌手")
        #expect(metadata?.albumArtist == "TTA 专辑歌手")
        #expect(metadata?.trackNumber == 7)
    }

    @Test func keepsExplicitTranslatedLyricsSeparateFromOriginalLyrics() {
        let tail = makeAPEv2Tag([
            apeTextItem("Lyrics", "[00:01.00]متن اصلی"),
            apeTextItem("Lyrics_Language", "fa"),
            apeTextItem("TranslatedLyrics:zh-Hans", "[00:01.00]人工译文"),
        ])

        let metadata = EmbeddedTagMetadataParser.parse(
            head: Data(),
            tail: tail,
            fileExtension: "ape"
        )

        #expect(metadata?.lyrics == "[00:01.00]متن اصلی")
        #expect(metadata?.lyricsLanguageCode == "fa")
        #expect(metadata?.translatedLyrics == "[00:01.00]人工译文")
        #expect(metadata?.translatedLyricsLanguageCode == "zh-Hans")
        #expect(metadata?.languageTaggedTranslations["zh-Hans"] == "[00:01.00]人工译文")
    }

    @Test func preservesLanguageTaggedLyricsAndPairsOnlyAnUnambiguousAlternate() {
        let identification = Data("OpusHead".utf8) + Data(repeating: 0, count: 24)
        let comment = Data("OpusTags".utf8) + makeVorbisComments([
            "LYRICS_LANGUAGE=per",
            "LYRICS:fas=[00:01.00]متن اصلی",
            "LYRICS:en=[00:01.00]Manual translation",
        ])
        let data = makeOggPage(packets: [identification], sequence: 0)
            + makeOggPage(packets: [comment], sequence: 1)

        let metadata = EmbeddedTagMetadataParser.parse(head: data, fileExtension: "opus")

        #expect(metadata?.lyrics == "[00:01.00]متن اصلی")
        #expect(metadata?.lyricsLanguageCode == "fa")
        #expect(metadata?.translatedLyrics == "[00:01.00]Manual translation")
        #expect(metadata?.translatedLyricsLanguageCode == "en")
        #expect(metadata?.languageTaggedLyrics.count == 2)
    }

    @Test func genericTrackLanguageDoesNotDeclareTheLyricsLanguage() {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "LANGUAGE": ["fa"],
            "LYRICS": ["An English lyric body"],
        ])

        #expect(metadata.lyrics == "An English lyric body")
        #expect(metadata.lyricsLanguageCode == nil)
    }

    @Test func parsesStructurallyValidAPEv2OnTAKAndRawDTS() {
        let tail = Data(repeating: 0x5A, count: 96) + makeAPEv2Tag([
            apeTextItem("title", "通用尾部标签"),
            apeTextItem("artist", "尾部歌手"),
        ])

        for fileExtension in ["tak", "dts"] {
            let metadata = EmbeddedTagMetadataParser.parse(
                head: fileExtension == "tak"
                    ? Data("tBaK".utf8)
                    : Data([0x7F, 0xFE, 0x80, 0x01]),
                tail: tail,
                fileExtension: fileExtension
            )
            #expect(metadata?.title == "通用尾部标签")
            #expect(metadata?.artist == "尾部歌手")
        }
    }

    @Test func acceptsOnlyPositionallyValidGenericID3() {
        let id3 = makeID3v23Title("DTS 尾部标题")
        let dtsHead = Data([0x7F, 0xFE, 0x80, 0x01])
        let validTail = Data(repeating: 0x5A, count: 64) + id3
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(
            head: dtsHead,
            tail: validTail,
            fileExtension: "dts"
        ) == id3)

        let payloadHit = validTail + Data(repeating: 0x5A, count: 64)
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(
            head: dtsHead,
            tail: payloadHit,
            fileExtension: "dts"
        ) == nil)
    }

    @Test func plansExactAPEv2TailExpansionAndRejectsPayloadSignatures() {
        var footer = Data("APETAGEX".utf8)
        appendUInt32LE(2_000, to: &footer)
        appendUInt32LE(400_000, to: &footer)
        appendUInt32LE(1, to: &footer)
        appendUInt32LE(0, to: &footer)
        footer.append(Data(repeating: 0, count: 8))
        let tail = Data(repeating: 0, count: 256 * 1024 - 32) + footer

        #expect(EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: 2_000_000,
            currentData: tail,
            fileExtension: "wv"
        ) == 400_128)

        let falsePositive = Data(repeating: 0, count: 64)
            + footer
            + Data(repeating: 0, count: 64)
        #expect(EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: 2_000_000,
            currentData: falsePositive,
            fileExtension: "ape"
        ) == nil)

        let fakeBeforeNonID3Tail = Data(repeating: 0, count: 96)
            + footer
            + Data(repeating: 0, count: 128)
        #expect(EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: 2_000_000,
            currentData: fakeBeforeNonID3Tail,
            fileExtension: "dts"
        ) == nil)
    }

    @Test func parsesOggVorbisCommentsAcrossPagesWithPicture() {
        let picture = makeFLACPicture(pngFixture).base64EncodedString()
        let comments = makeVorbisComments([
            "TITLE=Ogg 标题",
            "ARTIST=歌手 A",
            "ARTIST=歌手 B",
            "ALBUM=Ogg 专辑",
            "ALBUMARTIST=合辑歌手",
            "TRACKNUMBER=5/10",
            "DISCNUMBER=1/2",
            "DATE=2023-05-20",
            "GENRE=Alternative",
            "LYRICS=歌词正文",
            "REPLAYGAIN_ALBUM_GAIN=-6.5 dB",
            "METADATA_BLOCK_PICTURE=\(picture)",
        ])
        let identification = Data([0x01]) + Data("vorbis".utf8) + Data(repeating: 0, count: 24)
        let comment = Data([0x03]) + Data("vorbis".utf8) + comments
        let data = makeOggPage(packets: [identification], sequence: 0)
            + makeOggPage(packets: [comment], sequence: 1)

        let metadata = EmbeddedTagMetadataParser.parse(
            head: data,
            fileExtension: "oga"
        )

        #expect(metadata?.title == "Ogg 标题")
        #expect(metadata?.artists == ["歌手 A", "歌手 B"])
        #expect(metadata?.albumTitle == "Ogg 专辑")
        #expect(metadata?.albumArtist == "合辑歌手")
        #expect(metadata?.trackNumber == 5)
        #expect(metadata?.discNumber == 1)
        #expect(metadata?.year == 2023)
        #expect(metadata?.lyrics == "歌词正文")
        #expect(metadata?.replayGainAlbumGain == -6.5)
        #expect(metadata?.coverArtData == pngFixture)
    }

    @Test func parsesSmallOpusCommentPacket() {
        let identification = Data("OpusHead".utf8) + Data(repeating: 0, count: 24)
        let comment = Data("OpusTags".utf8) + makeVorbisComments(["TITLE=短标签"])
        let data = makeOggPage(packets: [identification], sequence: 0)
            + makeOggPage(packets: [comment], sequence: 1)

        #expect(EmbeddedTagMetadataParser.parse(
            head: data,
            fileExtension: "opus"
        )?.title == "短标签")
    }

    @Test func expandsTruncatedOggCommentButStopsAfterCompletePacket() {
        let identification = Data("OpusHead".utf8) + Data(repeating: 0, count: 24)
        let comment = Data("OpusTags".utf8) + makeVorbisComments(["TITLE=Opus 标题"])
        let complete = makeOggPage(packets: [identification], sequence: 0)
            + makeOggPage(packets: [comment], sequence: 1)
        let truncated = Data(complete.dropLast(5))

        let expanded = EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: 2_000_000,
            currentData: truncated,
            fileExtension: "opus"
        )
        #expect(expanded != nil)
        #expect(expanded! > truncated.count)
        #expect(EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: 2_000_000,
            currentData: complete,
            fileExtension: "opus"
        ) == nil)
    }

    @Test func parsesASFDescriptionsAttributesAndPicture() {
        let picture = makeASFPicture(pngFixture)
        let content = makeASFContentDescription(title: "WMA 标题", author: "WMA 歌手")
        let extended = makeASFExtendedContent([
            asfStringAttribute("WM/AlbumTitle", "WMA 专辑"),
            asfStringAttribute("WM/AlbumArtist", "专辑歌手"),
            asfStringAttribute("WM/TrackNumber", "11"),
            asfStringAttribute("WM/Year", "2022"),
            asfStringAttribute("WM/Genre", "Pop"),
            asfStringAttribute("WM/Lyrics", "WMA 歌词"),
            asfBinaryAttribute("WM/Picture", picture),
        ])
        let asf = makeASFHeader(objects: [content, extended])

        let metadata = EmbeddedTagMetadataParser.parse(head: asf, fileExtension: "asf")

        #expect(metadata?.title == "WMA 标题")
        #expect(metadata?.artist == "WMA 歌手")
        #expect(metadata?.albumTitle == "WMA 专辑")
        #expect(metadata?.albumArtist == "专辑歌手")
        #expect(metadata?.trackNumber == 11)
        #expect(metadata?.year == 2022)
        #expect(metadata?.genre == "Pop")
        #expect(metadata?.lyrics == "WMA 歌词")
        #expect(metadata?.coverArtData == pngFixture)

        let prefix = Data(asf.prefix(30))
        #expect(EmbeddedTagMetadataParser.expandedHeadReadSize(
            fileSize: 5_000_000,
            currentData: prefix,
            fileExtension: "wma"
        ) == asf.count)
    }

    @Test func locatesDSFMetadataByAbsoluteOffsetAndExtractsID3() {
        let id3 = makeID3v23Title("DSF 标题")
        var header = Data("DSD ".utf8)
        appendUInt64LE(28, to: &header)
        appendUInt64LE(1_000_000, to: &header)
        appendUInt64LE(900_000, to: &header)

        #expect(EmbeddedTagMetadataParser.dsfMetadataOffset(in: header) == 900_000)
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(
            head: header,
            tail: id3,
            fileExtension: "dsf"
        ) == id3)
        #expect(ID3TextMetadataParser.parse(id3)?.title == "DSF 标题")
    }

    @Test func parsesRIFFInfoAndExtractsItsID3Chunk() {
        let info = makeRIFFInfo([
            ("INAM", "INFO 标题"),
            ("IART", "INFO 歌手"),
            ("IPRD", "INFO 专辑"),
            ("IPRT", "4/9"),
            ("ICRD", "2021-12-01"),
            ("IGNR", "Jazz"),
        ])
        let id3 = makeID3v23Title("ID3 优先标题")
        let wave = makeRIFFWave(chunks: [info, makeRIFFChunk("id3 ", id3)])

        let metadata = EmbeddedTagMetadataParser.parse(head: wave, fileExtension: "wave")
        let extracted = EmbeddedTagMetadataParser.embeddedID3Data(
            head: wave,
            fileExtension: "wav"
        )

        #expect(metadata?.title == "INFO 标题")
        #expect(metadata?.artist == "INFO 歌手")
        #expect(metadata?.albumTitle == "INFO 专辑")
        #expect(metadata?.trackNumber == 4)
        #expect(metadata?.year == 2021)
        #expect(metadata?.genre == "Jazz")
        #expect(extracted == id3)
    }

    @Test func normalizesAdditionalScannerAliases() {
        #expect(AudioFormat.from(fileExtension: "OGA") == .ogg)
        #expect(AudioFormat.from(fileExtension: "WAVE") == .wav)
        #expect(PrimuseConstants.supportedAudioExtensions.contains("oga"))
        #expect(PrimuseConstants.supportedAudioExtensions.contains("wave"))
    }

    private var pngFixture: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private func apeTextItem(_ key: String, _ value: String) -> Data {
        makeAPEItem(key: key, value: Data(value.utf8), flags: 0)
    }

    private func apeBinaryItem(_ key: String, _ value: Data) -> Data {
        makeAPEItem(key: key, value: value, flags: 2)
    }

    private func makeAPEItem(key: String, value: Data, flags: UInt32) -> Data {
        var data = Data()
        appendUInt32LE(value.count, to: &data)
        appendUInt32LE(Int(flags), to: &data)
        data.append(Data(key.utf8))
        data.append(0)
        data.append(value)
        return data
    }

    private func makeAPEv2Tag(_ items: [Data]) -> Data {
        let body = items.reduce(into: Data()) { $0.append($1) }
        var footer = Data("APETAGEX".utf8)
        appendUInt32LE(2_000, to: &footer)
        appendUInt32LE(body.count + 32, to: &footer)
        appendUInt32LE(items.count, to: &footer)
        appendUInt32LE(0, to: &footer)
        footer.append(Data(repeating: 0, count: 8))
        return body + footer
    }

    private func makeID3v1Padding() -> Data {
        Data("TAG".utf8) + Data(repeating: 0, count: 125)
    }

    private func makeVorbisComments(_ comments: [String]) -> Data {
        let vendor = Data("Primuse Tests".utf8)
        var data = Data()
        appendUInt32LE(vendor.count, to: &data)
        data.append(vendor)
        appendUInt32LE(comments.count, to: &data)
        for comment in comments {
            let bytes = Data(comment.utf8)
            appendUInt32LE(bytes.count, to: &data)
            data.append(bytes)
        }
        data.append(1)
        return data
    }

    private func makeOggPage(packets: [Data], sequence: UInt32) -> Data {
        var lacing: [UInt8] = []
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                lacing.append(255)
                remaining -= 255
            }
            lacing.append(UInt8(remaining))
        }
        precondition(lacing.count <= 255)
        var data = Data("OggS".utf8)
        data.append(contentsOf: [0, sequence == 0 ? 2 : 0])
        data.append(Data(repeating: 0, count: 8))
        appendUInt32LE(1, to: &data)
        appendUInt32LE(Int(sequence), to: &data)
        appendUInt32LE(0, to: &data)
        data.append(UInt8(lacing.count))
        data.append(contentsOf: lacing)
        for packet in packets { data.append(packet) }
        return data
    }

    private func makeFLACPicture(_ image: Data) -> Data {
        let mime = Data("image/png".utf8)
        var data = Data()
        appendUInt32BE(3, to: &data)
        appendUInt32BE(mime.count, to: &data)
        data.append(mime)
        appendUInt32BE(0, to: &data)
        appendUInt32BE(1, to: &data)
        appendUInt32BE(1, to: &data)
        appendUInt32BE(24, to: &data)
        appendUInt32BE(0, to: &data)
        appendUInt32BE(image.count, to: &data)
        data.append(image)
        return data
    }

    private var asfHeaderGUID: Data {
        Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
              0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
    }

    private var asfContentGUID: Data {
        Data([0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
              0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])
    }

    private var asfExtendedGUID: Data {
        Data([0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11,
              0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50])
    }

    private func utf16LE(_ value: String) -> Data {
        (value + "\0").data(using: .utf16LittleEndian)!
    }

    private func makeASFObject(guid: Data, payload: Data) -> Data {
        var data = guid
        appendUInt64LE(payload.count + 24, to: &data)
        data.append(payload)
        return data
    }

    private func makeASFContentDescription(title: String, author: String) -> Data {
        let fields = [utf16LE(title), utf16LE(author), Data(), Data(), Data()]
        var payload = Data()
        for field in fields { appendUInt16LE(field.count, to: &payload) }
        for field in fields { payload.append(field) }
        return makeASFObject(guid: asfContentGUID, payload: payload)
    }

    private func asfStringAttribute(_ name: String, _ value: String) -> Data {
        makeASFAttribute(name: name, type: 0, value: utf16LE(value))
    }

    private func asfBinaryAttribute(_ name: String, _ value: Data) -> Data {
        makeASFAttribute(name: name, type: 1, value: value)
    }

    private func makeASFAttribute(name: String, type: UInt16, value: Data) -> Data {
        let nameData = utf16LE(name)
        var data = Data()
        appendUInt16LE(nameData.count, to: &data)
        data.append(nameData)
        appendUInt16LE(Int(type), to: &data)
        appendUInt16LE(value.count, to: &data)
        data.append(value)
        return data
    }

    private func makeASFExtendedContent(_ attributes: [Data]) -> Data {
        var payload = Data()
        appendUInt16LE(attributes.count, to: &payload)
        for attribute in attributes { payload.append(attribute) }
        return makeASFObject(guid: asfExtendedGUID, payload: payload)
    }

    private func makeASFHeader(objects: [Data]) -> Data {
        let body = objects.reduce(into: Data()) { $0.append($1) }
        var data = asfHeaderGUID
        appendUInt64LE(body.count + 30, to: &data)
        appendUInt32LE(objects.count, to: &data)
        data.append(contentsOf: [1, 2])
        data.append(body)
        return data
    }

    private func makeASFPicture(_ image: Data) -> Data {
        var data = Data([3])
        appendUInt32LE(image.count, to: &data)
        data.append(utf16LE("image/png"))
        data.append(utf16LE("front"))
        data.append(image)
        return data
    }

    private func makeID3v23Title(_ title: String) -> Data {
        var payload = Data([3])
        payload.append(Data(title.utf8))
        var frame = Data("TIT2".utf8)
        appendUInt32BE(payload.count, to: &frame)
        frame.append(contentsOf: [0, 0])
        frame.append(payload)
        var tag = Data([0x49, 0x44, 0x33, 0x03, 0, 0])
        tag.append(syncSafe(frame.count))
        tag.append(frame)
        return tag
    }

    private func syncSafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
        ])
    }

    private func makeRIFFInfo(_ fields: [(String, String)]) -> Data {
        var body = Data("INFO".utf8)
        for (key, value) in fields {
            body.append(makeRIFFChunk(key, Data(value.utf8) + Data([0])))
        }
        return makeRIFFChunk("LIST", body)
    }

    private func makeRIFFChunk(_ identifier: String, _ body: Data) -> Data {
        var data = Data(identifier.utf8)
        appendUInt32LE(body.count, to: &data)
        data.append(body)
        if !body.count.isMultiple(of: 2) { data.append(0) }
        return data
    }

    private func makeRIFFWave(chunks: [Data]) -> Data {
        let body = chunks.reduce(into: Data()) { $0.append($1) }
        var data = Data("RIFF".utf8)
        appendUInt32LE(body.count + 4, to: &data)
        data.append(Data("WAVE".utf8))
        data.append(body)
        return data
    }

    private func appendUInt16LE(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func appendUInt32BE(_ value: Int, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt64LE(_ value: Int, to data: inout Data) {
        for index in 0..<8 { data.append(UInt8((value >> (index * 8)) & 0xFF)) }
    }
}
