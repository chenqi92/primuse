import Foundation
import Testing
@testable import PrimuseKit

@Suite("Embedded container tag parsing")
struct EmbeddedTagMetadataParserTests {
    @Test(arguments: ["GENRE", "WM/GENRE", "IGNR"])
    func preservesAllGenreValues(key: String) {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            key: [" J-Pop ", "Vocaloid", "", "VOCALOID", "Ｒ＆Ｂ/Soul", "Rock, Live"],
        ])

        #expect(metadata.genre == "J-Pop; Vocaloid; Ｒ＆Ｂ/Soul; Rock, Live")
    }

    @Test func preservesRepeatedVorbisGenresAndAPEv2GenreValues() {
        let opus = makeOggPage(
            packets: [Data("OpusTags".utf8) + makeVorbisComments([
                "GENRE=J-Pop", "GENRE=Vocaloid",
            ])],
            sequence: 0
        )
        let ape = makeAPEv2Tag([apeTextItem("Genre", "J-Pop\0Vocaloid")])

        #expect(EmbeddedTagMetadataParser.parse(head: opus, fileExtension: "opus")?.genre
            == "J-Pop; Vocaloid")
        #expect(EmbeddedTagMetadataParser.parse(head: Data(), tail: ape, fileExtension: "ape")?.genre
            == "J-Pop; Vocaloid")
    }

    @Test func vorbisAndAPEKeepOriginalLyricsInPhysicalOrder() {
        let fields = [("SYNCEDLYRICS", "[00:01.00]Copper tide"), ("LYRICS", "Paper ferry"),
                      ("TRANSLATEDLYRICS", "铜色潮汐"), ("SYNCEDLYRICS", "[00:02.00]Glass shore")]
        let opus = makeOggPage(packets: [Data("OpusTags".utf8) + makeVorbisComments(
            fields.map { $0.0 + "=" + $0.1 }
        )], sequence: 0)
        let ape = makeAPEv2Tag(fields.map { apeTextItem($0.0, $0.1) })
        for metadata in [EmbeddedTagMetadataParser.parse(head: opus, fileExtension: "opus"),
                         EmbeddedTagMetadataParser.parse(head: Data(), tail: ape, fileExtension: "ape")] {
            #expect(metadata?.lyricsVariants.map(\.text) == [fields[0].1, fields[1].1, fields[3].1])
            #expect(metadata?.translatedLyrics == fields[2].1)
        }
    }

    @Test(arguments: ["ALBUMARTIST", "Album Artist", "album_artist", "WM/AlbumArtist"])
    func resolvesAlbumArtistAliasesIndependentlyFromTrackArtist(key: String) {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "ARTIST": ["Track Singer"],
            key: [" ", "Album Artist", "Guest", "Album Artist"],
            "ALBUMARTISTSORT": ["Sort Name"],
        ])

        #expect(metadata.artist == "Track Singer")
        #expect(metadata.albumArtist == "Album Artist; Guest")
    }

    @Test func prefersCanonicalAlbumArtistOverConflictingAlias() {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "ALBUM_ARTIST": ["Custom Artist"],
            "ALBUM ARTIST": ["Legacy Artist"],
            "ALBUMARTIST": ["Standard Artist"],
        ])
        #expect(metadata.albumArtist == "Standard Artist")
    }

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

    @Test func extractsLyrics3VersionsAndStackedAPEInPhysicalOrder() {
        let plain = "Copper leaves settle on the pier"
        let timed = "[00:12][01:04]Paper boats return"
        let v1 = Data(("LYRICSBEGIN" + plain + "LYRICSEND").utf8)
        let v2 = makeLyrics3v2([("AUT", "An author"), ("LYR", timed), ("LYR", plain), ("LYR", plain)])
        let apeText = "[00:24.500]The signal bends"
        let ape = makeAPEv2Tag([apeTextItem("Lyrics", apeText)])
        let audio = Data(repeating: 0xAE, count: 27)

        for id3v1 in [Data(), makeID3v1Padding()] {
            let v1Result = EmbeddedTagMetadataParser.parse(head: Data(), tail: audio + v1 + id3v1, fileExtension: "mp3")
            #expect(v1Result?.lyricFields.map(\.text) == [plain])
            let results = [(v2 + ape, [timed, plain, plain, apeText]), (ape + v2, [apeText, timed, plain, plain])]
            for (tags, expected) in results {
                let file = audio + tags + id3v1
                let parsed = EmbeddedTagMetadataParser.parse(head: file, tail: file, fileExtension: "mp3")
                #expect(parsed?.lyricFields.map(\.text) == expected)
                #expect(EmbeddedTagMetadataParser.parse(head: file, fileExtension: "mp3")?.lyricFields == parsed?.lyricFields)
            }
        }
    }

    @Test func verifiesLyrics3BoundariesAndExpandsOnlyTheDeclaredSuffix() {
        let tag = makeLyrics3v2([("LYR", "[00:01]The wire hums")])
        let footer = Data(tag.suffix(15)) + makeID3v1Padding()
        #expect(EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: 9_000, currentData: footer, fileExtension: "mp3"
        ) == tag.count + 128)
        let broken = Data("LYRICSBEGINLYR99999x000020LYRICS200".utf8)
        for bytes in [broken, tag + Data([0x9a]), Data("LYRICSBEGINa\0bLYRICSEND".utf8)] {
            #expect(EmbeddedTagMetadataParser.parse(head: bytes, fileExtension: "mp3") == nil)
        }
        #expect(EmbeddedTagMetadataParser.parse(head: tag, fileExtension: "flac") == nil)
    }

    @Test func readsLeadingAPEItemsWithAndWithoutFooterAndTextualBinaryAttachments() {
        let original = "Lanterns carry the morning"
        let timed = "[00:04.120]Swallows lift the fog"
        let attachment = Data("performance.lrc\0".utf8) + Data([0xff, 0xfe]) + (timed.data(using: .utf16LittleEndian) ?? Data())
        let items = [apeTextItem("Lyrics", original), apeBinaryItem("Score", attachment),
                     apeBinaryItem("Unrelated", Data([7, 0, 48, 0xFF])), makeAPEItem(key: "Lyrics URL", value: Data("external.lrc".utf8), flags: 4)]
        let footerTag = makeAPEv2Tag(items)
        let body = Data(footerTag.dropLast(32))
        let audio = Data(repeating: 0xA5, count: 37)
        for hasFooter in [true, false] {
            var header = Data("APETAGEX".utf8)
            appendUInt32LE(2_000, to: &header)
            appendUInt32LE(body.count + (hasFooter ? 32 : 0), to: &header)
            appendUInt32LE(items.count, to: &header)
            appendUInt32LE(hasFooter ? 0xa0000000 : 0xe0000000, to: &header)
            header.append(Data(repeating: 0, count: 8))
            let tag = header + (hasFooter ? footerTag : body)
            #expect(EmbeddedTagMetadataParser.expandedHeadReadSize(
                fileSize: 1_000_000, currentData: header, fileExtension: "mp3"
            ) == tag.count)
            let fromOnlyTag = EmbeddedTagMetadataParser.parse(head: tag, tail: tag, fileExtension: "mp3")?.lyricFields
            #expect(fromOnlyTag?.map(\.name) == ["Lyrics", "performance.lrc"])
            #expect(fromOnlyTag?.map(\.text) == [original, timed])
            let duplicate = makeAPEv2Tag([apeTextItem("Lyrics", original)])
            let file = tag + audio + duplicate
            let fields = EmbeddedTagMetadataParser.parse(head: file, fileExtension: "mp3")?.lyricFields
            #expect(fields?.map(\.text) == [original, timed, original])
        }
    }

    @Test func readsIndependentLeadingAndTrailingID3BetweenOtherTags() {
        let opening = id3Lyrics("Silver rails under rain")
        let closing = id3Lyrics("Copper bells at dawn")
        let ape = makeAPEv2Tag([apeTextItem("Lyrics", "Paper wings")])
        let legacy = makeLyrics3v2([("LYR", "Tide charts")])
        let audio = Data(repeating: 0xa5, count: 40)
        var footerTag = closing
        footerTag[5] |= 0x10
        let footer = Data("3DI".utf8) + footerTag[3..<10]
        footerTag.append(footer)
        let expected = ["Silver rails under rain", "Paper wings", "Copper bells at dawn", "Tide charts"]
        for tag in [footerTag, closing] {
            let tail = ape + tag + legacy + makeID3v1Padding()
            let file = opening + audio + tail
            #expect(EmbeddedTagMetadataParser.parse(head: file, fileExtension: "mp3")?.lyricFields.map(\.text) == expected)
            #expect(EmbeddedTagMetadataParser.parse(head: opening + audio, tail: tail, fileExtension: "mp3")?.lyricFields.map(\.text) == expected)
        }
        #expect(EmbeddedTagMetadataParser.expandedTailReadSize(
            fileSize: 1_000_000, currentData: footer + legacy, fileExtension: "mp3"
        ) == footerTag.count + legacy.count)
        #expect(EmbeddedTagMetadataParser.parse(head: footerTag, tail: footerTag, fileExtension: "mp3")?.lyricFields.count == 1)
    }

    @Test(arguments: ["opus", "ogg"])
    func readsLyricsAfterLargeOggArtworkUsingOnlyPageHeadersAndText(codec: String) async throws {
        let identification = codec == "opus" ? Data("OpusHead".utf8) : Data([1]) + Data("vorbis".utf8)
        let prefix = codec == "opus" ? Data("OpusTags".utf8) : Data([3]) + Data("vorbis".utf8)
        let art = Data("METADATA_BLOCK_PICTURE=".utf8) + makeFLACPicture(largeBMPArtwork, mimeType: "image/bmp").base64EncodedData()
        let packet = prefix + makeVorbisComments(raw: [
            Data("LYRICS=Lanterns on the hill".utf8), art, Data("Translation:en=Light over reeds".utf8),
            Data("Performance=[00:07.200]The morning rings".utf8),
        ])
        let file = makeOggPage(packets: [identification], sequence: 0) + makeOggPacketPages(packet, firstSequence: 1)
        #expect(file.count > 4 * 1024 * 1024)
        var transferred = 0
        let fields = try await EmbeddedTagMetadataParser.rangedCommentLyrics(
            head: file.prefix(256), tail: nil, fileSize: Int64(file.count), fileExtension: codec
        ) { offset, length in
            #expect(length <= 282)
            let count = min(97, Int(length))
            transferred += count
            return file.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        #expect(transferred < 64 * 1024)
        #expect(fields.map(\.text) == ["Lanterns on the hill", "Light over reeds", "[00:07.200]The morning rings"])
        #expect(fields.map(\.role) == [.original, .translation, .original])
        #expect(EmbeddedTagMetadataParser.parse(head: file, fileExtension: codec)?.lyricFields == fields)
    }

    @Test func readsAPELyricsBeyondLargeArtFromEitherEndOfTheAudio() async throws {
        let image = largeBMPArtwork
        let items = [apeTextItem("Lyrics", "Silver mist"), apeBinaryItem("Cover Art (Front)", Data("cover.bmp\0".utf8) + image),
                     apeTextItem("Translation:en", "A thread of silver"), apeTextItem("Lyrics", "Silver mist")]
        let tag = makeAPEv2Tag(items)
        var header = Data(tag.suffix(32))
        header[23] = 0xa0
        let audio = Data(repeating: 0x98, count: 500)
        let stacked = makeLyrics3v2([("LYR", "The water wakes")]) + makeID3v1Padding()
        let files = [header + tag + audio, audio + tag + stacked]
        for file in files {
            let tail = Data(file.suffix(160))
            var transferred = 0
            let fields = try await EmbeddedTagMetadataParser.rangedCommentLyrics(
                head: file.prefix(64), tail: tail, fileSize: Int64(file.count), fileExtension: "mp3"
            ) { offset, length in
                #expect(length <= 264)
                let count = min(Int(length), 51)
                transferred += count
                return file.subdata(in: Int(offset)..<(Int(offset) + count))
            }
            #expect(transferred < 2048)
            #expect(fields.map(\.text) == ["Silver mist", "A thread of silver", "Silver mist"])
            #expect(fields.map(\.role) == [.original, .translation, .original])
            #expect(EmbeddedTagMetadataParser.parse(head: file, fileExtension: "mp3")?.lyricFields.filter { $0.name != "LYRICS3" } == fields)
        }
    }

    private func makeLyrics3v2(_ fields: [(String, String)]) -> Data {
        var body = Data("LYRICSBEGIN".utf8)
        for (name, value) in fields {
            let bytes = Data(value.utf8)
            body.append(contentsOf: name.utf8)
            body.append(contentsOf: String(format: "%05d", bytes.count).utf8)
            body.append(bytes)
        }
        return body + Data(String(format: "%06dLYRICS200", body.count).utf8)
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

    @Test func combinesMultipleFLACBlocksAndOggFLACWithAnotherLogicalStream() {
        let first = "[00:02]Copper window"
        let second = "[00:05]Harbour glass"
        func comment(_ value: String, last: Bool) -> Data {
            let body = Data(makeVorbisComments(["LYRICS=" + value]).dropLast())
            return Data([last ? 0x84 : 0x04, 0, 0, UInt8(body.count)]) + body
        }
        let flac = makeID3v23Title("Window") + Data("fLaC".utf8)
            + comment(first, last: false) + comment(second, last: true)
        #expect(EmbeddedTagMetadataParser.parse(head: flac, fileExtension: "flac")?.lyricFields.map(\.text) == [first, second])

        let flacID = Data([0x7F]) + Data("FLAC".utf8) + Data([1, 0, 0, 1]) + Data("fLaC".utf8)
            + Data([0, 0, 0, 34]) + Data(repeating: 0, count: 34)
        let pages = makeOggPage(packets: [Data("OpusHead".utf8)], sequence: 0)
            + makeOggPage(packets: [flacID], sequence: 0, serial: 9)
            + makeOggPage(packets: [comment(first, last: true)], sequence: 1, serial: 9)
        let truncated = Data(pages.dropLast(3))
        #expect(EmbeddedTagMetadataParser.expandedHeadReadSize(fileSize: 2_000, currentData: truncated, fileExtension: "oga") != nil)
        let both = pages + makeOggPage(packets: [Data("OpusTags".utf8) + makeVorbisComments(["LYRICS=" + second])], sequence: 1)
        #expect(EmbeddedTagMetadataParser.parse(head: both, fileExtension: "oga")?.lyricFields.map(\.text) == [first, second])
        #expect(EmbeddedTagMetadataParser.expandedHeadReadSize(fileSize: 2_000, currentData: both, fileExtension: "oga") == nil)
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

    @Test func decodesGBKOggCommentsAndAPEItemsWrittenByLegacyTaggers() throws {
        // 千千静听这一代工具往 Vorbis 注释、APE 标签里直接写 GBK; 以前整条丢掉, 表现为没有歌词。
        let gbk = TextEncodingRepair.gb18030
        let lyrics = "[00:01.00]晚风吹过旧街口\n[00:05.00]路灯照亮你回头"
        let title = try #require("晚风".data(using: gbk))
        let lyricBytes = try #require(lyrics.data(using: gbk))

        let identification = Data("OpusHead".utf8) + Data(repeating: 0, count: 24)
        let comment = Data("OpusTags".utf8) + makeVorbisComments(raw: [
            Data("TITLE=".utf8) + title,
            Data("ARTIST=Band".utf8),
            Data("LYRICS=".utf8) + lyricBytes,
        ])
        let ogg = EmbeddedTagMetadataParser.parse(
            head: makeOggPage(packets: [identification], sequence: 0)
                + makeOggPage(packets: [comment], sequence: 1),
            fileExtension: "opus"
        )
        #expect(ogg?.title == "晚风")
        #expect(ogg?.artist == "Band")
        #expect(ogg?.lyrics == lyrics)

        let tail = makeAPEv2Tag([
            makeAPEItem(key: "Title", value: title, flags: 0),
            apeTextItem("Artist", "Band"),
            makeAPEItem(key: "Lyrics", value: lyricBytes, flags: 0),
        ]) + makeID3v1Padding()
        let ape = EmbeddedTagMetadataParser.parse(head: Data(), tail: tail, fileExtension: "ape")
        #expect(ape?.title == "晚风")
        #expect(ape?.lyrics == lyrics)
    }

    @Test func legacyTagValuesShareOneEncodingAcrossTheBlock() throws {
        // 两个字的歌名单独判, GBK 和 Big5 都「解得通」; 和同一块里的长歌词一起判才定得下来。
        let gbk = TextEncodingRepair.gb18030
        let values = [
            Data("Band".utf8),
            try #require("晚风".data(using: gbk)),
            try #require("[00:01.00]晚风吹过旧街口\n[00:05.00]路灯照亮你回头".data(using: gbk)),
            Data([0x42, 0x6A, 0xF6, 0x72, 0x6B]),
        ]
        let decoded = TextEncodingRepair.decodeTagValues(values)
        #expect(decoded[0] == "Band")
        #expect(decoded[1] == "晚风")
        #expect(decoded[2]?.hasPrefix("[00:01.00]晚风吹过") == true)
        #expect(TextEncodingRepair.decodeTagValues([values[3]]) == ["Björk"])
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

    @Test func readsASFMetadataLibraryLanguagesAndSynchronizedWordTimes() throws {
        let libraryGUID = Data([0x94,0x1c,0x23,0x44,0x98,0x94,0xd1,0x49,0xa1,0x41,0x1d,0x13,0x4e,0x45,0x70,0x54])
        let languageGUID = Data([0xa9,0x46,0x43,0x7c,0xe0,0xef,0xfc,0x4b,0xb2,0x29,0x39,0x3e,0xde,0x41,0x5c,0x85])
        let extensionGUID = Data([0xb5,0x03,0xbf,0x5f,0x2e,0xa9,0xcf,0x11,0x8e,0xe3,0x00,0xc0,0x0c,0x20,0x53,0x65])
        let entries: [(String, Int, Int, Data)] = [
            ("WM/Lyrics_Synchronised", 1, 0, asfSyncLyrics([("Slate", 800), (" bells", 1_150), ("\nWake", 3_404)])),
            ("WM/Lyrics", 0, 0, utf16LE("A long " + String(repeating: "evening ", count: 5_000))),
            ("WM/Text", 1, 1, utf16LE("TRANSLATION") + utf16LE("[00:00.80]铜铃响")),
            ("ID3", 1, 1, id3Lyrics("singular lantern")),
            ("WM/Lyrics_Synchronised", 1, 1, Data(asfSyncLyrics([("Broken", 4)]).dropLast())),
        ]
        var library = Data()
        appendUInt16LE(entries.count, to: &library)
        for (name, type, language, value) in entries {
            let encodedName = utf16LE(name)
            appendUInt16LE(language, to: &library)
            appendUInt16LE(0, to: &library)
            appendUInt16LE(encodedName.count, to: &library)
            appendUInt16LE(type, to: &library)
            appendUInt32LE(value.count, to: &library)
            library += encodedName + value
        }
        var languages = Data([2, 0])
        for language in ["en", "zh-Hans"] {
            let bytes = utf16LE(language)
            languages.append(UInt8(bytes.count))
            languages.append(bytes)
        }
        let children = makeASFObject(guid: libraryGUID, payload: library)
            + makeASFObject(guid: languageGUID, payload: languages)
        var body = Data([0x11,0xd2,0xd3,0xab,0xba,0xa9,0xcf,0x11,0x8e,0xe6,0x00,0xc0,0x0c,0x20,0x53,0x65,6,0])
        appendUInt32LE(children.count, to: &body)
        body.append(children)
        let bytes = makeASFHeader(objects: [makeASFObject(guid: extensionGUID, payload: body)])
        let metadata = try #require(EmbeddedTagMetadataParser.parse(head: bytes, fileExtension: "wma"))
        #expect(metadata.lyricFields.map(\.name) == ["WM/Lyrics_Synchronised", "WM/Lyrics", "TRANSLATION", "USLT"])
        #expect(metadata.lyricFields.map(\.languageCode) == ["en", "en", "zh-Hans", "en"])
        #expect(metadata.lyricFields[1].text.hasPrefix("A long evening"))
        #expect(metadata.lyricFields[2].role == .translation)
        #expect(metadata.lyricFields[3].text == "singular lantern")
        let lines = LyricsContentParser.parseText(metadata.lyricFields[0].text)
        #expect(lines.map(\.text) == ["Slate bells", "Wake"])
        #expect(lines[0].syllables?.map(\.start) == [0.8, 1.15])
        #expect(lines[1].timestamp == 3.404)
    }

    @Test func preservesTextForASFSynchronizedFrameCountersAndIgnoresOtherContentTypes() {
        var frames = asfSyncLyrics([("North", 30), (" quay\n", 39), ("Open gates", 70)])
        frames[0] = 1
        var chords = asfSyncLyrics([("Dm", 500)])
        chords[1] = 5
        let file = makeASFHeader(objects: [makeASFExtendedContent([
            asfBinaryAttribute("WM/Lyrics_Synchronised", frames),
            asfBinaryAttribute("WM/Lyrics_Synchronised", chords),
            asfStringAttribute("WM/Lyrics", "Second pier"),
        ])])
        let lyrics = EmbeddedTagMetadataParser.parse(head: file, fileExtension: "asf")?.lyricFields
        #expect(lyrics?.map(\.text) == ["North quay\nOpen gates", "Second pier"])
    }

    private func asfSyncLyrics(_ entries: [(String, Int)]) -> Data {
        var cues = Data()
        for (text, time) in entries {
            cues.append(utf16LE(text))
            appendUInt32LE(time, to: &cues)
        }
        var result = Data([2, 1])
        appendUInt32LE(cues.count, to: &result)
        return result + utf16LE("Performance") + cues
    }

    private func id3Lyrics(_ text: String) -> Data {
        let payload = Data([3]) + Data("eng\0".utf8) + Data(text.utf8)
        let frame = Data("USLT".utf8) + syncSafe(payload.count) + Data([0, 0]) + payload
        return Data("ID3".utf8) + Data([4, 0, 0]) + syncSafe(frame.count) + frame
    }

    @Test func readsEveryID3ChunkAndTimedCommentInWaveAndAIFF() {
        let first = "Copper oars"
        let middle = "[00:04.00]We fold the daylight"
        let last = "Tin sails"
        let wave = makeRIFFWave(chunks: [makeRIFFChunk("id3 ", id3Lyrics(first)), makeRIFFInfo([("ICMT", middle)]),
                                         makeRIFFChunk("ID3 ", id3Lyrics(last))])
        let fields = EmbeddedTagMetadataParser.parse(head: wave, fileExtension: "wav")?.lyricFields
        #expect(fields?.map(\.text) == [first, middle, last])

        let line = Data(middle.utf8)
        let comment = Data([0, 1, 0, 0, 0, 0, 0, 0, 0, UInt8(line.count)]) + line + Data(repeating: 0, count: line.count % 2)
        let payload = Data("AIFF".utf8) + makeIFFChunk("ID3 ", id3Lyrics(first))
            + makeIFFChunk("COMT", comment) + makeIFFChunk("ID3 ", id3Lyrics(last))
        let aiff = makeIFFChunk("FORM", payload)
        #expect(EmbeddedTagMetadataParser.parse(head: aiff, fileExtension: "aif")?.lyricFields.map(\.text) == [first, middle, last])
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(head: aiff, fileExtension: "aif") == id3Lyrics(first))
    }

    private var dynamicMediaPacket: Data {
        Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:custom="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
                xmlns:other="urn:primuse:other" other:lyrics="Unrelated property">
                <custom:lyrics>Copper wings&#xA;Unfold</custom:lyrics>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
    }

    @Test func readsDynamicMediaXMPFromWaveAndSparseAIFF() async throws {
        let packet = dynamicMediaPacket
        let text = "Copper wings\nUnfold"
        let wave = makeRIFFWave(chunks: [makeRIFFChunk("_PMX", packet)])
        #expect(EmbeddedTagMetadataParser.parse(head: wave, fileExtension: "wav")?.lyricFields.map(\.text) == [text])
        let sound = makeIFFChunk("SSND", Data(repeating: 0, count: 300_001))
        let xmp = makeIFFChunk("APPL", Data("XMP ".utf8) + packet)
        let performance = makeIFFChunk("ID3 ", id3Lyrics("Lanterns cross the bay"))
        let aiff = makeIFFChunk("FORM", Data("AIFC".utf8) + sound + xmp + performance)
        let reconstructed = try await EmbeddedTagMetadataParser.waveMetadataFile(head: aiff.prefix(64), fileSize: Int64(aiff.count)) {
            offset, length in
            #expect(offset >= 12 + sound.count)
            #expect(length <= packet.count)
            return aiff.subdata(in: Int(offset)..<Int(offset + min(length, 37)))
        }
        let result = try #require(reconstructed)
        let fields = EmbeddedTagMetadataParser.parse(head: result, fileExtension: "aifc")?.lyricFields
        #expect(fields?.map(\.text) == [text, "Lanterns cross the bay"])
        #expect(fields == EmbeddedTagMetadataParser.parse(head: aiff, fileExtension: "aifc")?.lyricFields)
    }

    @Test func walksASFDataObjectToTopLevelXMPWithoutReadingAudio() async throws {
        let header = makeASFHeader(objects: [makeASFExtendedContent([asfStringAttribute("WM/Lyrics", "Moonlit water")])])
        let dataGUID = Data([0x36, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62, 0xce, 0x6c])
        let xmpGUID = Data([0xcb, 0xcf, 0x7a, 0xbe, 0xa9, 0x97, 0xe8, 0x42, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac])
        let object = makeASFObject(guid: dataGUID, payload: Data(repeating: 0xa5, count: 800_000))
        let audio = header + object
        let file = audio + makeASFObject(guid: xmpGUID, payload: dynamicMediaPacket)
        let fields = try await EmbeddedTagMetadataParser.topLevelASFXMP(head: file.prefix(header.count + 24), fileSize: Int64(file.count)) { offset, length in
            #expect(offset >= audio.count)
            return file.subdata(in: Int(offset)..<Int(offset + min(length, 31)))
        }
        #expect(fields.map(\.text) == ["Copper wings\nUnfold"])
        #expect(EmbeddedTagMetadataParser.parse(head: file, fileExtension: "wma")?.lyricFields.map(\.text)
            == ["Moonlit water", "Copper wings\nUnfold"])
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

    @Test func readsNestedAndTrailingDSDIFFTagsAcrossA64BitAudioChunk() async throws {
        func header(_ name: String, _ size: Int64) -> Data {
            var length = UInt64(size).bigEndian
            return Data(name.utf8) + withUnsafeBytes(of: &length) { Data($0) }
        }
        func chunk(_ name: String, _ body: Data) -> Data {
            header(name, Int64(body.count)) + body + Data(repeating: 0, count: body.count % 2)
        }
        let first = id3Lyrics("Oars catch the daylight")
        let nested = chunk("PROP", Data("SND ".utf8) + chunk("ID3 ", first))
        let last = chunk("ID3 ", id3Lyrics("Stars over the jetty"))
        let pcmSize: Int64 = 4_300_000_002
        let tailOffset = Int64(16 + nested.count + 12) + pcmSize
        let fileSize = tailOffset + Int64(last.count)
        let prefix = header("FRM8", fileSize - 12) + Data("DSD ".utf8) + nested + header("DSD ", pcmSize) + Data(repeating: 0, count: 4)
        let synthetic = try await EmbeddedTagMetadataParser.waveMetadataFile(head: prefix, fileSize: fileSize) { offset, length in
            #expect(offset >= tailOffset)
            return last.subdata(in: Int(offset - tailOffset)..<Int(offset - tailOffset + min(length, 9)))
        }
        let tail = try #require(synthetic)
        let fields = EmbeddedTagMetadataParser.parse(head: prefix, tail: tail, fileExtension: "dff")?.lyricFields
        #expect(fields?.map(\.text) == ["Oars catch the daylight", "Stars over the jetty"])
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(head: prefix, fileExtension: "dff") == first)
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

    @Test(arguments: ["ID3 ", "id3 "])
    func locatesWaveInfoAndID3WithoutReadingPCM(id: String) async throws {
        let pcm = Data(repeating: 0xa5, count: 900_001)
        let tag = makeID3v23Title("月台回声")
        let info = makeRIFFInfo([("IART", "潮汐乐团"), ("IPRD", "渡口")])
        let wave = makeRIFFWave(chunks: [
            makeRIFFChunk("data", pcm), info, makeRIFFChunk(id, tag), makeRIFFChunk("JUNK", pcm)
        ])
        let tags = try await EmbeddedTagMetadataParser.waveMetadataFile(
            head: wave.prefix(256 * 1024), fileSize: Int64(wave.count)
        ) { offset, length in
            #expect(offset >= 20 + pcm.count)
            #expect(length < 256)
            return wave.subdata(in: Int(offset)..<Int(offset + min(length, 7)))
        }
        let file = try #require(tags)
        let metadata = EmbeddedTagMetadataParser.parse(head: file, fileExtension: "wav")
        #expect(metadata?.artist == "潮汐乐团")
        #expect(metadata?.albumTitle == "渡口")
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(head: file, fileExtension: "wav") == tag)
    }

    @Test func decodesLegacyRIFFInfoFieldsTogether() throws {
        var info = Data("INFO".utf8)
        for (id, value) in [("INAM", "告白气球"), ("IART", "周杰伦"),
                            ("IPRD", "CARNIVAL(2024来日纪念)CD1")] {
            let bytes = try #require(value.data(using: TextEncodingRepair.gb18030))
            info.append(makeRIFFChunk(id, bytes + Data([0])))
        }
        let wave = makeRIFFWave(chunks: [makeRIFFChunk("LIST", info)])
        let parsed = EmbeddedTagMetadataParser.parse(head: wave, fileExtension: "wav")
        #expect(parsed?.title == "告白气球")
        #expect(parsed?.artist == "周杰伦")
        #expect(parsed?.albumTitle == "CARNIVAL(2024来日纪念)CD1")
    }

    @Test func skipsOversizedWaveChunkAndRejectsOutOfBoundsLengths() async throws {
        let tag = makeID3v23Title("Valid tag")
        let oversized = 40 * 1024 * 1024
        let end = makeRIFFChunk("id3 ", tag)
        // A sparse fixture: the first tag's body must never be requested.
        var head = Data("RIFF".utf8)
        appendUInt32LE(12 + oversized + end.count, to: &head)
        head.append(contentsOf: "WAVEID3 ".utf8)
        appendUInt32LE(oversized, to: &head)
        let endOffset = head.count + oversized
        head.append(contentsOf: [0x49, 0x44, 0x33, 3])
        let size = Int64(endOffset + end.count)
        let result = try await EmbeddedTagMetadataParser.waveMetadataFile(head: head, fileSize: size) { offset, length in
            try #require(offset >= Int64(endOffset) && offset + length <= size)
            let start = Int(offset) - endOffset
            return end.subdata(in: start..<(start + Int(length)))
        }
        let located = try #require(result)
        #expect(EmbeddedTagMetadataParser.embeddedID3Data(head: located, fileExtension: "wav") == tag)
        let invalid = try await EmbeddedTagMetadataParser.waveMetadataFile(head: head, fileSize: size - 1) { _, _ in
            Issue.record("truncated RIFF must not request an out-of-file chunk")
            return Data()
        }
        #expect(invalid == nil)
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

    private func makeVorbisComments(raw comments: [Data]) -> Data {
        let vendor = Data("Primuse Tests".utf8)
        var data = Data()
        appendUInt32LE(vendor.count, to: &data)
        data.append(vendor)
        appendUInt32LE(comments.count, to: &data)
        for comment in comments {
            appendUInt32LE(comment.count, to: &data)
            data.append(comment)
        }
        data.append(1)
        return data
    }

    private func makeOggPage(packets: [Data], sequence: UInt32, serial: Int = 1) -> Data {
        var lacing: [UInt8] = []
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                lacing.append(255)
                remaining -= 255
            }
            lacing.append(UInt8(remaining))
        }
        return makeOggPage(lacing: lacing, bytes: packets.reduce(into: Data()) { $0.append($1) },
                           sequence: sequence, serial: serial, flags: sequence == 0 ? 2 : 0)
    }

    private func makeOggPacketPages(_ packet: Data, firstSequence: UInt32) -> Data {
        var pages = Data()
        var offset = 0
        var sequence = firstSequence
        while true {
            let size = min(255 * 255, packet.count - offset)
            var lacing = [UInt8](repeating: 255, count: size / 255)
            let final = lacing.count < 255
            if final { lacing.append(UInt8(size % 255)) }
            let bytes = packet.subdata(in: offset..<(offset + size))
            pages.append(makeOggPage(lacing: lacing, bytes: bytes, sequence: sequence, serial: 1, flags: offset == 0 ? 0 : 1))
            if final { return pages }
            sequence += 1
            offset += size
        }
    }

    private func makeOggPage(lacing: [UInt8], bytes: Data, sequence: UInt32, serial: Int, flags: UInt8) -> Data {
        precondition(lacing.count <= 255)
        var data = Data("OggS".utf8)
        data.append(contentsOf: [0, flags])
        data.append(Data(repeating: 0, count: 8))
        appendUInt32LE(serial, to: &data)
        appendUInt32LE(Int(sequence), to: &data)
        appendUInt32LE(0, to: &data)
        data.append(UInt8(lacing.count))
        data.append(contentsOf: lacing)
        data.append(bytes)
        return data
    }

    private var largeBMPArtwork: Data {
        let pixelBytes = 1360 * 1050 * 3
        var image = Data("BM".utf8)
        appendUInt32LE(54 + pixelBytes, to: &image)
        for value in [0, 54, 40, 1360, 1050] { appendUInt32LE(value, to: &image) }
        appendUInt16LE(1, to: &image)
        appendUInt16LE(24, to: &image)
        for value in [0, pixelBytes, 0, 0, 0, 0] { appendUInt32LE(value, to: &image) }
        return image + Data(repeating: 0x70, count: pixelBytes)
    }

    private func makeFLACPicture(_ image: Data, mimeType: String = "image/png") -> Data {
        let mime = Data(mimeType.utf8)
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

    private func makeIFFChunk(_ name: String, _ body: Data) -> Data {
        var bytes = Data(name.utf8)
        appendUInt32BE(body.count, to: &bytes)
        return bytes + body + Data(repeating: 0, count: body.count % 2)
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
