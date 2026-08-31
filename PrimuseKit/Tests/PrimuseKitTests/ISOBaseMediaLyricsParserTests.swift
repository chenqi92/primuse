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
