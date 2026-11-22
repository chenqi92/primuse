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

    @Test(arguments: [2, 3, 4]) func commentsAttachmentsAndCustomFieldsUseTheSameScanAndArchiveRules(version: Int) throws {
        func named(_ long: String, _ short: String) -> String { version == 2 ? short : long }
        func text(_ label: String, _ value: String, language: String? = nil) -> Data {
            Data([0]) + Data((language ?? "").utf8) + Data(label.utf8) + Data([0]) + Data(value.utf8)
        }
        let ttml = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"1s\">A tin orchard opens</p></div></body></tt>"
        let object = Data([0]) + Data("application/ttml+xml\0orchard.ttml\0\0".utf8) + Data(ttml.utf8)
        let artwork = Data([0]) + Data("image/png\0card.png\0lyrics\0".utf8) + Data([0x89, 80, 78, 71, 13, 10, 26, 10])
        let original = id3File(version, [
            (named("COMM", "COM"), text("notes", "[00:01.20]Three silver hooks", language: "eng"), 0),
            (named("COMM", "COM"), text("notes", "Take four, close microphone", language: "eng"), 0),
            (named("GEOB", "GEO"), object, 0),
            (named("GEOB", "GEO"), artwork, 0),
            (named("USLT", "ULT"), text("pinyin", "zhi zhou", language: "zho"), 0),
            (named("TXXX", "TXX"), text("TRANSLATION:de", "Kupferglas"), 0),
            (named("TEXT", "TXT"), Data([0]) + Data("A. Beacon".utf8), 0),
        ])
        let scanned = ID3EmbeddedLyrics.fields(in: original)
        let entries = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3")
        #expect(entries.map(\.text) == ["[00:01.20]Three silver hooks", ttml, "zhi zhou", "Kupferglas"])
        #expect(entries.map(\.text) == scanned.map(\.text))
        #expect(entries.map(\.role) == [.original, .original, .romanization, .translation])
        #expect(entries.map(\.languageCode) == ["en", nil, "zh", "de"])
        let allWritable = entries.allSatisfy(\.isWritable)
        #expect(allWritable)
        let revised = ttml.replacingOccurrences(of: "tin orchard", with: "brass orchard")
        let edited = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [entries[1].id: revised])
        #expect(edited.range(of: Data("application/ttml+xml\0orchard.ttml\0\0".utf8)) != nil)
        #expect(edited.range(of: artwork) != nil)
        #expect(ID3EmbeddedLyrics.fields(in: edited).map(\.text) == [entries[0].text, revised, entries[2].text, entries[3].text])
    }

    @Test func repeatedUTF16ValuesKeepIndependentRowsAndSiblingBytes() throws {
        let encoding = String.Encoding.utf16LittleEndian
        let label = Data([1, 0xff, 0xfe]) + "LYRICS".data(using: encoding)! + Data([0, 0])
        let first = Data([0xff, 0xfe]) + "Paper well".data(using: encoding)!
        let second = "Tin leaf".data(using: encoding)!
        let third = "Paper well".data(using: encoding)!
        let unrelated = ("TXXX", Data([3]) + Data("studio\0west room".utf8), UInt16(0))
        let original = id3File(4, [("TXXX", label + first + Data([0, 0]) + second + Data([0, 0]) + third, 0), unrelated])
        let entries = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3")
        #expect(entries.map(\.text) == ["Paper well", "Tin leaf", "Paper well"])
        #expect(Set(entries.map(\.id)).count == 3)
        let edited = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3",
                                                         edits: [entries[1].id: nil, entries[2].id: "Folded glass"])
        #expect(ID3EmbeddedLyrics.fields(in: edited).map(\.text) == ["Paper well", "Folded glass"])
        #expect(edited.range(of: label + first) != nil)
        #expect(edited.range(of: unrelated.1) != nil)
    }

    @Test func oneUnreadableFrameDoesNotHideCompressedGroupedOrFollowingLyrics() throws {
        let compressed = Data([120, 156, 99, 78, 205, 75, 103, 112, 84, 40, 203, 204, 207, 73, 45,
                               81, 72, 42, 205, 175, 84, 40, 41, 45, 202, 43, 6, 0, 95, 98, 8, 109])
        let opaque = ("USLT", Data([5, 0xfe, 0x85]), UInt16(0x04))
        let grouped = ("USLT", Data([11]) + Data([3]) + Data("eng\0Orchard glass".utf8), UInt16(0x40))
        let last = ("USLT", Data([3]) + Data("eng\0Tin sunset".utf8), UInt16(0))
        let frames: [(String, Data, UInt16)] = [
            ("USLT", Data([3]) + Data("engmissing delimiter".utf8), 0),
            ("USLT", Data([0, 0, 0, 24]) + compressed, 0x09), opaque, grouped, last,
        ]
        let original = id3File(4, frames)
        let rows = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3")
        #expect(rows.map(\.text) == ["A violet buoy turns", "Orchard glass", "Tin sunset"])
        #expect(rows.map(\.isWritable) == [false, false, true])
        #expect(ID3EmbeddedLyrics.fields(in: original).map(\.text) == rows.map(\.text))
        #expect(throws: (any Error).self) { try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [rows[0].id: nil]) }
        let changed = try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [rows[2].id: "Tin sunrise"])
        #expect(changed.range(of: compressed) != nil)
        #expect(changed.range(of: opaque.1) != nil)
        #expect(throws: (any Error).self) {
            try EmbeddedLyricsArchive.preserving(from: original, in: id3File(4, [grouped, last]), fileExtension: "mp3")
        }
    }

    @Test func extendedHeaderExposesCompleteFramesWithoutOfferingSourceWrites() throws {
        let body = Data([3]) + Data("eng\0Past the lantern pier".utf8)
        let file = id3File(4, [("USLT", body, 0)], tagFlags: 0x40, extended: Data([0, 0, 0, 6, 1, 0]))
        let rows = try EmbeddedLyricsArchive.entries(in: file, fileExtension: "mp3")
        #expect(rows.map(\.text) == ["Past the lantern pier"])
        #expect(rows.map(\.isWritable) == [false])
        #expect(ID3EmbeddedLyrics.fields(in: file).map(\.text) == rows.map(\.text))
    }

    @Test func lengthWrittenInPlainBytesDoesNotHideTheNextFrameInAV24Tag() throws {
        let first = String(repeating: "tin ", count: 45) + "bell"
        let body = Data([3]) + Data("eng\0".utf8) + Data(first.utf8)
        var file = id3File(4, [("USLT", body, 0), ("USLT", Data([3]) + Data("eng\0Folded lamps".utf8), 0)])
        file.replaceSubrange(14..<18, with: [0, 0, 0, UInt8(body.count)])
        let rows = try EmbeddedLyricsArchive.entries(in: file, fileExtension: "mp3")
        #expect(rows.map(\.text) == [first, "Folded lamps"])
        #expect(rows.map(\.isWritable) == [false, false])
        #expect(ID3EmbeddedLyrics.fields(in: file).map(\.text) == rows.map(\.text))
    }

    @Test func replacingThenClearingOriginalsKeepsPronunciationAndTranslationFrames() throws {
        let primary = ("COMM", Data([3]) + Data("eng\0[00:01.00]A glass buoy spins".utf8), UInt16(0))
        let reading = ("USLT", Data([3]) + Data("engpinyin\0bo li fu biao".utf8), UInt16(0))
        let translated = ("TXXX", Data([3]) + Data("TRANSLATION:zh\0玻璃浮标旋转".utf8), UInt16(0))
        let audio = Data([0xff, 0xfb, 0x94, 0])
        let original = id3File(4, [reading, translated, primary]) + audio
        let text = "[00:02.00]A painted buoy turns"
        let changed = try #require(EmbeddedLyricsFieldEditor.editID3(original, .replace(text: text, anchor: "[00:01.00]A glass buoy spins")))
        #expect(changed.data.suffix(audio.count) == audio)
        #expect(ID3EmbeddedLyrics.fields(in: changed.data).map(\.text) == ["bo li fu biao", "玻璃浮标旋转", text])
        let cleared = try #require(EmbeddedLyricsFieldEditor.editID3(changed.data, .removeAllOriginals))
        #expect(ID3EmbeddedLyrics.fields(in: cleared.data).map(\.role) == [.romanization, .translation])
        #expect(cleared.data.range(of: reading.1) != nil)
        #expect(cleared.data.range(of: translated.1) != nil)
    }

    @Test func mpegFrameClocksUseTheBitstreamAndKeepWordsWhenOnlyTheTagIsAvailable() throws {
        var cues = Data([3]) + Data("eng".utf8) + Data([1, 1, 0])
        cues += Data("First lantern\0".utf8) + Data([0, 0, 0, 1])
        cues += Data("\nSecond lantern\0".utf8) + Data([0, 0, 0, 100])
        let tag = id3File(4, [("SYLT", cues, 0)])
        let frame = Data([0xff, 0xfb, 0x94, 0x00]) + Data(count: 380) // MPEG-1 Layer III, 48 kHz, 1,152 samples
        let timed = try EmbeddedLyricsArchive.entries(in: tag + frame + frame, fileExtension: "mp3")
        #expect(timed.map(\.text) == ["[00:00.024]First lantern\n[00:02.400]Second lantern"])
        let layerI = Data([0xff, 0xff, 0x54, 0x00]) + Data(count: 156)
        #expect(ID3EmbeddedLyrics.fields(in: tag + layerI + layerI).map(\.text)
            == ["[00:00.008]First lantern\n[00:00.800]Second lantern"])
        #expect(ID3EmbeddedLyrics.fields(in: tag).map(\.text) == ["First lantern\nSecond lantern"])
        #expect(try EmbeddedLyricsArchive.entries(in: tag, fileExtension: "mp3").map(\.id) == timed.map(\.id))
    }

    @Test func structuredValuesInAudioCommentsAndPrivateAttachmentsRetainTheirIdentity() throws {
        let lyrics = "[00:01.00]A glass fin folds"
        let owner = Data("net.example.lyrics".utf8) + Data([0])
        let original = id3File(4, [("PRIV", owner + Data(lyrics.utf8), 0),
                                    ("PRIV", Data("vendor.clock\0".utf8) + Data([0, 1, 0, 2]), 0)])
        #expect(try EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3").map(\.text) == [lyrics])
        let mixed = movie(box("©cmt", mp4Value("Recording note") + mp4Value(lyrics) + box("data", Data([0, 0, 0, 13, 0, 0, 0, 0, 0xff]))))
        let rows = try EmbeddedLyricsArchive.entries(in: mixed, fileExtension: "m4a")
        #expect(rows.map(\.text) == [lyrics])
        let removed = try EmbeddedLyricsArchive.replacing(in: mixed, fileExtension: "m4a", edits: [rows[0].id: nil])
        #expect(removed.range(of: mp4Value("Recording note")) != nil)
        #expect(removed.range(of: Data([0, 0, 0, 13, 0, 0, 0, 0, 0xff])) != nil)
        let newNote = movie(box("©cmt", mp4Value("Updated recording note")))
        let restored = try EmbeddedLyricsArchive.preserving(from: mixed, in: newNote, fileExtension: "m4a")
        #expect(try EmbeddedLyricsArchive.entries(in: restored, fileExtension: "m4a").map(\.text) == [lyrics])
        #expect(restored.range(of: mp4Value("Updated recording note")) != nil)
        #expect(restored.range(of: mp4Value("Recording note")) == nil)
        let mixedValues = id3File(4, [("TXXX", Data([3]) + Data(("take notes\0Mic gain two\0" + lyrics).utf8), 0)])
        let lostLyrics = id3File(4, [("TXXX", Data([3]) + Data("take notes\0Updated gain".utf8), 0)])
        #expect(try EmbeddedLyricsArchive.entries(in: mixedValues, fileExtension: "mp3").map(\.text) == [lyrics])
        #expect(throws: (any Error).self) {
            try EmbeddedLyricsArchive.preserving(from: mixedValues, in: lostLyrics, fileExtension: "mp3")
        }
    }

    @Test func adobePrivatePacketKeepsItsOtherMetadataWhenALyricIsRead() throws {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
          xmpDM:lyrics="Reeds count the rain" xmpDM:artist="Weather notebook"/>
        </rdf:RDF></x:xmpmeta>
        """
        let packet = Data("XMP\0".utf8) + Data(xmp.utf8)
        let original = id3File(4, [("PRIV", packet, 0)])
        let entry = try #require(EmbeddedLyricsArchive.entries(in: original, fileExtension: "mp3").first)
        #expect(entry.text == "Reeds count the rain")
        #expect(!entry.isWritable)
        #expect(throws: (any Error).self) {
            try EmbeddedLyricsArchive.replacing(in: original, fileExtension: "mp3", edits: [entry.id: "Different"])
        }
    }

    private func id3File(_ version: Int, _ entries: [(String, Data, UInt16)], tagFlags: UInt8 = 0, extended: Data = Data()) -> Data {
        func size(_ n: Int, count: Int, bits: Int) -> Data {
            Data((0..<count).reversed().map { UInt8(n >> ($0 * bits) & ((1 << bits) - 1)) })
        }
        var body = extended
        for (name, value, flags) in entries {
            body += Data(name.utf8) + size(value.count, count: version == 2 ? 3 : 4, bits: version == 4 ? 7 : 8)
            if version > 2 { body += size(Int(flags), count: 2, bits: 8) }
            body += value
        }
        return Data("ID3".utf8) + Data([UInt8(version), 0, tagFlags]) + size(body.count, count: 4, bits: 7) + body
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
