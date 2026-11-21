import Foundation
import Testing
@testable import PrimuseKit

struct EmbeddedLyricsArchiveTests {
    @Test func ttmlTranslationStaysInOneEmbeddedVersionAfterEditing() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div><p begin="1s" end="3s">Paper sails count stars<span ttm:role="x-translation" xml:lang="zh">纸帆数星光</span></p></div></body>
        </tt>
        """
        let original = movie(box("©lyr", mp4Value(ttml)))
        let before = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "m4a")
        #expect(before.count == 1)
        let entry = try #require(before.first)
        let editedText = ttml.replacingOccurrences(of: "纸帆数星光", with: "纸帆数晚星")
        let edited = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "m4a",
                                                         edits: [entry.id: editedText])
        let after = try EmbeddedLyricsArchive.entries(in: edited, fileExtension: "m4a")
        #expect(after.map(\.text) == [editedText])
        let stored = try #require(after.first)
        let lines = LyricsContentParser.parse(stored.text)
        #expect(lines.map(\.text) == ["Paper sails count stars"])
        #expect(lines.first?.manualTranslation?.text == "纸帆数晚星")
        #expect(lines.first?.timestamp == 1)
    }

    @Test func repeatedM4AValuesKeepTheirIdentityAndOtherMetadata() throws {
        let first = mp4Value("The paper bell waits")
        let second = mp4Value("[00:01.00]A paper bridge wakes")
        let cover = box("covr", box("data", Data(repeating: 13, count: 23)))
        let comment = box("©cmt", mp4Value("harbor"))
        let original = movie(box("©lyr", first + second + first) + cover + comment)
        let rows = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "m4a")
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        let edited = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "m4a",
            edits: [rows[1].id: "A silver hour wakes"])
        #expect(try EmbeddedLyricsArchive.entries(in: edited, fileExtension: "m4a").map(\.text)
            == [rows[0].text, "A silver hour wakes", rows[2].text])
        #expect(edited.range(of: cover + comment) != nil)
        #expect(throws: (any Error).self) {
            try EmbeddedLyricsArchive.replacing(in: edited, fileExtension: "m4a", edits: [rows[1].id: nil])
        }
        let removed = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "m4a",
            edits: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, nil as String?) }))
        #expect(try EmbeddedLyricsArchive.entries(in: removed, fileExtension: "m4a").isEmpty)
        #expect(removed.range(of: cover + comment) != nil)
        let restored = try EmbeddedLyricsArchive.preserving(from: original, in: removed, fileExtension: "m4a")
        #expect(try EmbeddedLyricsArchive.entries(in: restored, fileExtension: "m4a") == rows)
    }

    @Test func languageTaggedVorbisFieldsCanBeRemovedIndividually() throws {
        let values = ["TITLE=Orchard", "LYRICS=Small bells", "LYRICS_ZH=纸舟摇过桥洞", "LYRICS=Small bells"]
        let original = Data("fLaC".utf8) + Data([0, 0, 0, 34]) + Data(repeating: 0, count: 34)
            + vorbisBlock(values) + Data([0xff, 0xf8])
        let rows = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "flac")
        #expect(rows.map(\.languageCode) == [nil, "zh", nil])
        let result = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "flac", edits: [rows[0].id: nil])
        #expect(try EmbeddedLyricsArchive.entries(in: result, fileExtension: "flac").map(\.text)
            == ["纸舟摇过桥洞", "Small bells"])
        #expect(result.suffix(2) == Data([0xff, 0xf8]))
        #expect(result.range(of: Data("TITLE=Orchard".utf8)) != nil)
    }

    @Test func id3EditsPreserveOtherLanguagesAndDescriptions() throws {
        let body = Data([3]) + Data("eng".utf8) + Data([0]) + Data("Under copper clouds".utf8)
        let localized = Data([3]) + Data("zho".utf8) + Data("draft".utf8) + Data([0]) + Data("纸帆点灯".utf8)
        let frames = boxFrame("USLT", body) + boxFrame("USLT", localized)
        let original = Data([73, 68, 51, 4, 0, 0, 0, 0, 0, UInt8(frames.count)]) + frames + Data([0xff, 0xfb])
        let rows = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3")
        #expect(rows.count == 2)
        let result = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [rows[0].id: "Copper skies stir"])
        #expect(result.range(of: boxFrame("USLT", localized)) != nil)
        #expect(try EmbeddedLyricsArchive.entries(in: result, fileExtension: "mp3").map(\.text) == ["Copper skies stir", "纸帆点灯"])
    }

    @Test func editingOneSynchronizedFrameCanStoreUntimedTextWithoutMergingOtherVersions() throws {
        let uslt = boxFrame("USLT", Data([3]) + Data("eng".utf8) + Data([0]) + Data("Plain".utf8))
        let sylt = boxFrame("SYLT", Data([3]) + Data("eng".utf8) + Data([2, 1, 0]) + Data("Timed".utf8) + Data([0, 0, 0, 5, 220]))
        let tags = uslt + sylt + sylt
        let audio = Data([0xff, 0xfb, 0x90, 0x64])
        let original = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, UInt8(tags.count)]) + tags + audio
        let entries = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3")
        let changed = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [entries[1].id: "New plain text"])
        let saved = try EmbeddedLyricsArchive.entries(in: changed, fileExtension: "mp3")
        #expect(saved.map(\.fieldName) == ["USLT", "USLT", "SYLT"])
        #expect(saved.map(\.text) == ["Plain", "New plain text", entries[2].text])
        #expect(changed.suffix(audio.count) == audio)
        let bodies = try #require(ID3LyricsFramePreservation.lyricsFrameBodies(in: changed))
        #expect(bodies.count == 2)
        #expect(EmbeddedLyricsFieldEditor.usltIdentity(bodies[0]) != EmbeddedLyricsFieldEditor.usltIdentity(bodies[1]))
    }

    @Test func coverWriteUpgradingID3KeepsLyricsOrderAndAudio() throws {
        let first = boxFrame("USLT", Data([0]) + Data("eng".utf8) + Data([0]) + Data("Amber rail".utf8))
        let second = boxFrame("TXXX", Data([0]) + Data("LYRICS".utf8) + Data([0]) + Data("Copper bell".utf8))
        let picture = boxFrame("APIC", Data([0]) + Data("image/jpeg".utf8) + Data([0, 3, 0, 0xff, 0xd8, 0xff, 0xd9]))
        let audio = Data([0xff, 0xfb, 0x90, 0x64])
        func file(version: UInt8, frames: Data) -> Data {
            Data("ID3".utf8) + Data([version, 0, 0, 0, 0, 0, UInt8(frames.count)]) + frames + audio
        }
        let original = file(version: 3, frames: first + second)
        let upgraded = file(version: 4, frames: second + picture + first)
        let restored = try EmbeddedLyricsArchive.preserving(from: original, in: upgraded, fileExtension: "mp3")
        #expect(restored[3] == 4)
        #expect(try EmbeddedLyricsArchive.entries(in: restored, fileExtension: "mp3")
            == EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3"))
        #expect(restored.range(of: picture) != nil)
        #expect(restored.suffix(audio.count) == audio)

        let missing = file(version: 4, frames: picture + first)
        #expect(throws: (any Error).self) {
            try EmbeddedLyricsArchive.preserving(from: original, in: missing, fileExtension: "mp3")
        }
    }

    private func vorbisBlock(_ fields: [String]) -> Data {
        func le(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).littleEndian) { Data($0) } }
        var body = le(0) + le(fields.count)
        for field in fields { body += le(field.utf8.count) + Data(field.utf8) }
        return Data([132, 0, 0, UInt8(body.count)]) + body
    }
    private func mp4Value(_ text: String) -> Data { box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(text.utf8)) }
    private func box(_ key: String, _ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count + 8).bigEndian) { Data($0) } + key.data(using: .isoLatin1)! + payload
    }
    private func boxFrame(_ key: String, _ body: Data) -> Data {
        Data(key.utf8) + Data([0, 0, 0, UInt8(body.count), 0, 0]) + body
    }
    private func movie(_ items: Data) -> Data {
        box("ftyp", Data("M4A ".utf8)) + box("mdat", Data([1, 2, 3]))
            + box("moov", box("udta", box("meta", Data(repeating: 0, count: 4)
                + box("hdlr", Data(repeating: 0, count: 8) + Data("mdir".utf8))
                + box("ilst", items))))
    }
}
