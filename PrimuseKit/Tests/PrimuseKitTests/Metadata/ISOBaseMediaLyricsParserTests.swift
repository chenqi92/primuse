import Foundation
import Testing
@testable import PrimuseKit

@Suite("ISO Base Media embedded lyrics")
struct ISOBaseMediaLyricsParserTests {
    @Test("Reads the traditional iTunes lyrics item")
    func standardITunesLyrics() {
        let expected = "[00:00.00]第一行歌词\n[00:01.00]Second line"
        let item = atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(Data(expected.utf8))
        )

        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(items: item)) == expected)
    }

    @Test("Maps mdta keys to numeric ilst item indexes")
    func metadataKeyLyrics() {
        let expected = "[00:00.00]内嵌歌词测试"
        let metadata = metadataAtom(
            keys: ["title", "artist", "lyrics", "encoder"],
            items: atom(type: bigEndian(UInt32(3)), payload: dataAtom(Data(expected.utf8)))
        )

        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(metadata: metadata)) == expected)
    }

    @Test("Repairs legacy bytes even when the data atom declares UTF-8")
    func repairsIncorrectEncodingDeclaration() throws {
        let expected = "[00:00.00]十年"
        let bytes = try #require(expected.data(using: TextEncodingRepair.gb18030))
        let item = atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(bytes, declaredType: 1)
        )

        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(items: item)) == expected)
    }

    @Test("Reads UTF-16 lyrics data atoms")
    func utf16Lyrics() throws {
        let expected = "[00:00.00]春天"
        let bytes = try #require(expected.data(using: .utf16))
        let item = atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(bytes, declaredType: 2)
        )

        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(items: item)) == expected)
    }

    @Test("Reads iTunes freeform lyrics")
    func freeformLyrics() {
        let expected = "Freeform lyrics"
        let item = atom(
            "----",
            payload: fullBoxTextAtom("mean", value: "com.apple.iTunes")
                + fullBoxTextAtom("name", value: "LYRICS")
                + dataAtom(Data(expected.utf8))
        )

        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(items: item)) == expected)
    }

    @Test("File order spans freeform, standard and keyed originals without including translations")
    func interleavedFormats() {
        func freeform(_ name: String, _ text: String) -> Data {
            atom("----", payload: fullBoxTextAtom("name", value: name) + dataAtom(Data(text.utf8)))
        }
        let items = freeform("LYRICS:fr", "Reflet de cuivre")
            + freeform("SYNCEDLYRICS", "[00:01.00]Copper tide")
            + atom(type: Data([0xA9, 0x6C, 0x79, 0x72]), payload: dataAtom(Data("Paper ferry".utf8)) + dataAtom(Data("Tin sail".utf8)))
            + atom(type: bigEndian(UInt32(1)), payload: dataAtom(Data("Glass shore".utf8)))
        let metadata = metadataAtom(keys: ["LYRICS"], items: items)
        let payload = ISOBaseMediaLyricsParser.payload(in: mediaFile(metadata: metadata))
        #expect(payload?.lyricsVariants.map(\.text) == ["[00:01.00]Copper tide", "Paper ferry", "Tin sail", "Glass shore"])
        #expect(payload?.languageTaggedLyrics["fr"] == "Reflet de cuivre")
    }

    @Test("Keeps translated and language-tagged lyrics separate")
    func translatedFreeformLyrics() {
        let original = "[00:01.00]متن اصلی"
        let translation = "[00:01.00]Manual translation"
        let items = atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(Data(original.utf8))
        ) + atom(
            "----",
            payload: fullBoxTextAtom("mean", value: "com.apple.iTunes")
                + fullBoxTextAtom("name", value: "TRANSLATEDLYRICS:en")
                + dataAtom(Data(translation.utf8))
        )

        let payload = ISOBaseMediaLyricsParser.payload(in: mediaFile(items: items))

        #expect(payload?.lyrics == original)
        #expect(payload?.translatedLyrics == translation)
        #expect(payload?.translatedLyricsLanguageCode == "en")
    }

    @Test("Preserves every language-qualified lyrics item")
    func multipleLanguageQualifiedLyrics() {
        let metadata = metadataAtom(
            keys: ["LYRICS:fas", "LYRICS:en", "TRANSLATION:zh-Hans"],
            items: atom(
                type: bigEndian(UInt32(1)),
                payload: dataAtom(Data("متن اصلی".utf8))
            ) + atom(
                type: bigEndian(UInt32(2)),
                payload: dataAtom(Data("English alternate".utf8))
            ) + atom(
                type: bigEndian(UInt32(3)),
                payload: dataAtom(Data("中文译文".utf8))
            )
        )

        let payload = ISOBaseMediaLyricsParser.payload(in: mediaFile(metadata: metadata))

        #expect(payload?.lyrics == "متن اصلی")
        #expect(payload?.lyricsLanguageCode == "fa")
        #expect(payload?.translatedLyrics == "中文译文")
        #expect(payload?.translatedLyricsLanguageCode == "zh-Hans")
        #expect(payload?.languageTaggedLyrics == [
            "fa": "متن اصلی",
            "en": "English alternate",
        ])
        #expect(payload?.languageTaggedTranslations == ["zh-Hans": "中文译文"])
    }

    @Test("Reads the grouping item separately from the lyrics item")
    func storedGroupingAndLyrics() {
        let lyrics = "[00:00.00]First line"
        let items = atom(
            type: Data([0xA9, 0x67, 0x72, 0x70]),
            payload: dataAtom(Data("Symphony No. 5".utf8))
        ) + atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(Data(lyrics.utf8))
        )

        let stored = ISOBaseMediaLyricsParser.storedITunesTextItems(in: mediaFile(items: items))
        #expect(stored.lyrics == lyrics)
        #expect(stored.grouping == "Symphony No. 5")
        #expect(!stored.hasUndecodableLyrics)
    }

    @Test("A grouping item alone is never reported as lyrics")
    func storedGroupingWithoutLyrics() {
        let item = atom(
            type: Data([0xA9, 0x67, 0x72, 0x70]),
            payload: dataAtom(Data("Live".utf8))
        )
        let file = mediaFile(items: item)

        let stored = ISOBaseMediaLyricsParser.storedITunesTextItems(in: file)
        #expect(stored.lyrics == nil)
        #expect(stored.grouping == "Live")
        #expect(!stored.hasUndecodableLyrics)
        #expect(ISOBaseMediaLyricsParser.lyrics(in: file) == nil)
    }

    @Test("Freeform lyrics do not stand in for the iTunes lyrics item")
    func storedItemsIgnoreFreeformLyrics() {
        let items = atom(
            "----",
            payload: fullBoxTextAtom("mean", value: "com.apple.iTunes")
                + fullBoxTextAtom("name", value: "LYRICS")
                + dataAtom(Data("Freeform lyrics".utf8))
        )

        let stored = ISOBaseMediaLyricsParser.storedITunesTextItems(in: mediaFile(items: items))
        #expect(stored == ISOBaseMediaLyricsParser.StoredITunesTextItems())
    }

    @Test("Flags a lyrics item whose data cannot be decoded")
    func storedItemsFlagUndecodableLyrics() {
        let items = atom(
            type: Data([0xA9, 0x67, 0x72, 0x70]),
            payload: dataAtom(Data("Live".utf8))
        ) + atom(
            type: Data([0xA9, 0x6C, 0x79, 0x72]),
            payload: dataAtom(Data([0x01, 0x02, 0x03]), declaredType: 21)
        )

        let stored = ISOBaseMediaLyricsParser.storedITunesTextItems(in: mediaFile(items: items))
        #expect(stored.lyrics == nil)
        #expect(stored.grouping == "Live")
        #expect(stored.hasUndecodableLyrics)
    }

    @Test("Files without iTunes metadata report nothing stored")
    func storedItemsInEmptyFile() {
        #expect(
            ISOBaseMediaLyricsParser.storedITunesTextItems(in: Data())
                == ISOBaseMediaLyricsParser.StoredITunesTextItems()
        )
        #expect(
            ISOBaseMediaLyricsParser.storedITunesTextItems(in: Data([0, 0, 0, 1, 0x6D]))
                == ISOBaseMediaLyricsParser.StoredITunesTextItems()
        )
    }

    @Test("Reads ReplayGain from iTunes freeform items")
    func freeformReplayGain() {
        let items = replayGainItem("replaygain_track_gain", value: "-10.20 dB")
            + replayGainItem("replaygain_track_peak", value: "1.000000")
            + replayGainItem("replaygain_album_gain", value: "-10.40 dB")
            + replayGainItem("replaygain_album_peak", value: "0.988525")

        let tags = ISOBaseMediaLyricsParser.replayGainTags(in: mediaFile(items: items))

        #expect(tags == ISOBaseMediaLyricsParser.ReplayGainTags(
            trackGain: -10.2,
            trackPeak: 1,
            albumGain: -10.4,
            albumPeak: 0.988525
        ))
    }

    @Test("ReplayGain item names match regardless of case and sign")
    func uppercaseReplayGainNames() {
        let items = replayGainItem("REPLAYGAIN_TRACK_GAIN", value: "+3.21 dB")
            + replayGainItem("ReplayGain_Track_Peak", value: " 0.5 ")

        let tags = ISOBaseMediaLyricsParser.replayGainTags(in: mediaFile(items: items))

        #expect(tags?.trackGain == 3.21)
        #expect(tags?.trackPeak == 0.5)
        #expect(tags?.albumGain == nil)
    }

    @Test("Reads ReplayGain from mdta keys")
    func metadataKeyReplayGain() {
        let metadata = metadataAtom(
            keys: ["title", "com.apple.quicktime.replaygain_track_gain"],
            items: atom(type: bigEndian(UInt32(1)), payload: dataAtom(Data("Song".utf8)))
                + atom(type: bigEndian(UInt32(2)), payload: dataAtom(Data("-6.5 dB".utf8)))
        )

        let tags = ISOBaseMediaLyricsParser.replayGainTags(in: mediaFile(metadata: metadata))

        #expect(tags == ISOBaseMediaLyricsParser.ReplayGainTags(trackGain: -6.5))
    }

    @Test("Unreadable or unrelated items are no ReplayGain")
    func rejectsUnusableReplayGain() {
        let items = replayGainItem("replaygain_track_gain", value: "loud")
            + replayGainItem("replaygain_album_gain", value: "nan dB")
            + replayGainItem("replaygain_track_gain_extra", value: "-3 dB")
            + replayGainItem("iTunNORM", value: "000001F4 000001F4")

        #expect(ISOBaseMediaLyricsParser.replayGainTags(in: mediaFile(items: items)) == nil)
        #expect(ISOBaseMediaLyricsParser.replayGainTags(in: Data()) == nil)
    }

    @Test("Ignores unrelated and malformed metadata items")
    func rejectsInvalidMetadata() {
        let unrelated = metadataAtom(
            keys: ["title"],
            items: atom(type: bigEndian(UInt32(1)), payload: dataAtom(Data("Song".utf8)))
        )
        #expect(ISOBaseMediaLyricsParser.lyrics(in: mediaFile(metadata: unrelated)) == nil)

        let truncated = bigEndian(UInt32(100)) + Data("moov".utf8) + Data(repeating: 0, count: 8)
        #expect(ISOBaseMediaLyricsParser.lyrics(in: truncated) == nil)
    }

    @Test("Reads iTunes advisory and original copyright from complete movie metadata", arguments: [1, 2, 4])
    func contentTags(_ rating: UInt8) throws {
        let notice = "℗ 2026 Label\n© 2026 Artist"
        let items = atom("rtng", payload: dataAtom(Data([rating]), declaredType: 21))
            + atom("cprt", payload: dataAtom(Data(notice.utf8)))
        let result = try #require(ISOBaseMediaLyricsParser.contentMetadata(in: mediaFile(items: items)))
        #expect(result.iTunesAdvisory == Int(rating))
        #expect(result.copyright == notice)
        #expect(result.isFileInspectionComplete)
        #expect(result.isExplicit == (rating != 2))
    }

    @Test("A truncated moov must remain uninspected, while a complete tagless moov is complete")
    func contentInspectionCompletion() throws {
        let file = mediaFile(items: Data())
        #expect(ISOBaseMediaLyricsParser.contentMetadata(in: file.dropLast()) == nil)
        let complete = try #require(ISOBaseMediaLyricsParser.contentMetadata(in: file))
        #expect(complete.isFileInspectionComplete)
        #expect(!complete.hasValues)
        #expect(ISOBaseMediaLyricsParser.contentMetadata(in: Data()) == nil)
    }

    @Test("A complete inspection also records how many chapters the movie carries")
    func contentInspectionCountsChapters() throws {
        let complete = try #require(ISOBaseMediaLyricsParser.contentMetadata(in: mediaFile(items: Data())))
        #expect(complete.embeddedChapterCount == 0)
    }

    @Test("Malformed advisory is ignored without dropping valid copyright")
    func malformedContentTag() throws {
        let items = atom("rtng", payload: dataAtom(Data([4]), declaredType: 1))
            + atom("cprt", payload: dataAtom(Data("© Artist".utf8)))
        let result = try #require(ISOBaseMediaLyricsParser.contentMetadata(in: mediaFile(items: items)))
        #expect(result.iTunesAdvisory == nil)
        #expect(result.copyright == "© Artist")
    }

    @Test("Replacing, removing and clearing mixed lyrics preserves other languages, custom fields and media offsets")
    func editMixedOriginalFields() throws {
        let first = "First original"
        let second = "[00:01.00]Second original"
        let custom = "[00:02.00]Freeform original"
        let changed = "[00:02.00]New text with a longer line"
        let foreign = replayGainItem("LYRICS:fr", value: "Paroles en français")
        let translation = replayGainItem("TRANSLATEDLYRICS:de", value: "Deutsche Übersetzung")
        let other = replayGainItem("replaygain_track_gain", value: "-1.1 dB")
        let standard = atom(type: Data([0xa9, 0x6c, 0x79, 0x72]),
                            payload: dataAtom(Data(first.utf8)) + dataAtom(Data(second.utf8)))
        let originals = replayGainItem("SYNCEDLYRICS", value: custom) + standard
        let preserved = foreign + translation + other
        let movie = mediaFile(items: preserved + originals)
        let audio = atom("mdat", payload: Data(repeating: 0x71, count: 327))
        let file = movie + audio

        let updated = try #require(ISOBaseMediaLyricsParser.editingOriginals(in: file, .replace(text: changed, anchor: custom)))
        #expect(updated.result == .replacedField)
        #expect(ISOBaseMediaLyricsParser.payload(in: updated.data)?.lyricsVariants.map(\.text) == [changed, first, second])
        let removed = try #require(ISOBaseMediaLyricsParser.editingOriginals(in: updated.data, .removeOne(first)))
        #expect(ISOBaseMediaLyricsParser.payload(in: removed.data)?.lyricsVariants.map(\.text) == [changed, second])
        let cleared = try #require(ISOBaseMediaLyricsParser.editingOriginals(in: removed.data, .removeAllOriginals))
        #expect(cleared.result == .removedOriginals(2))
        #expect(ISOBaseMediaLyricsParser.payload(in: cleared.data)?.lyrics == "Paroles en français")
        for bytes in [updated.data, removed.data, cleared.data] {
            #expect(bytes.range(of: preserved) != nil)
            #expect(bytes.subdata(in: movie.count..<file.count) == audio)
        }
        #expect(ISOBaseMediaLyricsParser.editingOriginals(in: file, .removeOne("Other original")) == nil)
        #expect(ISOBaseMediaLyricsParser.editingOriginals(in: file, .replace(text: changed, anchor: nil)) == nil)
    }

    @Test("Reads only the Adobe XMP packet beyond the media, alongside an independent iTunes lyric")
    func topLevelXMPWithAudioAndAnotherUUID() async throws {
        let original = "[00:01]Copper kites"
        let packet = Data("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dm="http://ns.adobe.com/xmp/1.0/DynamicMedia/">
        <rdf:Description dm:lyrics="[00:02]Glass reeds"/>
        </rdf:RDF>
        """.utf8)
        let guid = Data([0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac])
        let head = mediaFile(items: atom(type: Data([0xa9, 0x6c, 0x79, 0x72]), payload: dataAtom(Data(original.utf8))))
        let audio = atom("mdat", payload: Data(repeating: 93, count: 600_000))
        let file = head + audio + atom("uuid", payload: Data(count: 16) + packet) + atom("uuid", payload: guid + packet)
        var bytesRead = 0
        let fields = try await ISOBaseMediaLyricsParser.topLevelXMP(head: head, fileSize: Int64(file.count)) { at, length in
            let count = min(23, Int(length))
            bytesRead += count
            return file.subdata(in: Int(at)..<(Int(at) + count))
        }
        #expect(bytesRead < 1024)
        #expect(fields.map(\.text) == ["[00:02]Glass reeds"])
        #expect(ISOBaseMediaLyricsParser.payload(in: file)?.fields.map(\.text) == [original, "[00:02]Glass reeds"])
    }

    @Test("Editing a timed lyric in a comment preserves its ordinary sibling")
    func editsOnlyLyricValueInMixedComment() throws {
        let original = "[00:01]Cloud ferry"
        let note = dataAtom(Data("Room tone take seven".utf8))
        let file = mediaFile(items: atom(type: Data([0xa9,0x63,0x6d,0x74]), payload: note + dataAtom(Data(original.utf8))))
        let result = try #require(ISOBaseMediaLyricsParser.editingOriginals(in: file, .removeOne(original)))
        #expect(result.data.range(of: note) != nil)
        #expect(ISOBaseMediaLyricsParser.payload(in: result.data) == nil)
    }

    private func mediaFile(items: Data) -> Data {
        mediaFile(metadata: metadataAtom(keys: [], items: items))
    }

    private func mediaFile(metadata: Data) -> Data {
        let ftyp = atom("ftyp", payload: Data("M4A ".utf8))
        let mvhd = atom("mvhd", payload: Data(repeating: 0, count: 24))
        let moov = atom("moov", payload: mvhd + atom("udta", payload: metadata))
        return ftyp + moov
    }

    private func metadataAtom(keys: [String], items: Data) -> Data {
        let handler = atom("hdlr", payload: Data(repeating: 0, count: 24))
        let keyTable: Data
        if keys.isEmpty {
            keyTable = Data()
        } else {
            let entries = keys.reduce(into: Data()) { result, key in
                let value = Data(key.utf8)
                result += bigEndian(UInt32(value.count + 8)) + Data("mdta".utf8) + value
            }
            keyTable = atom(
                "keys",
                payload: Data(repeating: 0, count: 4)
                    + bigEndian(UInt32(keys.count))
                    + entries
            )
        }
        return atom(
            "meta",
            payload: Data(repeating: 0, count: 4)
                + handler
                + keyTable
                + atom("ilst", payload: items)
        )
    }

    private func replayGainItem(_ name: String, value: String) -> Data {
        atom(
            "----",
            payload: fullBoxTextAtom("mean", value: "com.apple.iTunes")
                + fullBoxTextAtom("name", value: name)
                + dataAtom(Data(value.utf8))
        )
    }

    private func dataAtom(_ value: Data, declaredType: UInt32 = 1) -> Data {
        atom(
            "data",
            payload: bigEndian(declaredType) + bigEndian(UInt32(0)) + value
        )
    }

    private func fullBoxTextAtom(_ type: String, value: String) -> Data {
        atom(type, payload: Data(repeating: 0, count: 4) + Data(value.utf8))
    }

    private func atom(_ type: String, payload: Data) -> Data {
        atom(type: Data(type.utf8), payload: payload)
    }

    private func atom(type: Data, payload: Data) -> Data {
        precondition(type.count == 4)
        return bigEndian(UInt32(payload.count + 8)) + type + payload
    }

    private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
