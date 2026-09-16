import Foundation
import Testing
@testable import PrimuseKit

@Suite("ID3 synchronized lyrics frame")
struct ID3SynchronizedLyricsParserTests {
    /// Stands in for the platform text repair so the binary layout is what is
    /// under test.
    private func decode(_ payload: Data, encoding: UInt8) -> String? {
        switch encoding {
        case 1, 2:
            return String(data: payload, encoding: encoding == 1 ? .utf16 : .utf16BigEndian)
        case 3:
            return String(data: payload, encoding: .utf8)
        default:
            return String(data: payload, encoding: .isoLatin1)
        }
    }

    private func frame(
        encoding: UInt8 = 0,
        language: String = "eng",
        timestampFormat: UInt8 = 2,
        contentType: UInt8 = 1,
        descriptor: String = "",
        cues: [(String, Int)]
    ) -> Data {
        var bytes: [UInt8] = [encoding]
        bytes += Array(language.utf8)
        bytes += [timestampFormat, contentType]

        func encoded(_ text: String) -> [UInt8] {
            switch encoding {
            case 1:
                return Array(text.data(using: .utf16)!) + [0, 0]
            case 2:
                return Array(text.data(using: .utf16BigEndian)!) + [0, 0]
            case 3:
                return Array(text.utf8) + [0]
            default:
                return Array(text.data(using: .isoLatin1)!) + [0]
            }
        }

        bytes += encoded(descriptor)
        for (text, milliseconds) in cues {
            bytes += encoded(text)
            bytes += [
                UInt8((milliseconds >> 24) & 0xFF),
                UInt8((milliseconds >> 16) & 0xFF),
                UInt8((milliseconds >> 8) & 0xFF),
                UInt8(milliseconds & 0xFF),
            ]
        }
        return Data(bytes)
    }

    @Test("Line cues become LRC lines that the lyric parser can read back")
    func parsesLineCues() throws {
        let payload = frame(cues: [
            ("First line", 1_000),
            ("\nSecond line", 62_500),
        ])

        let parsed = try #require(ID3SynchronizedLyricsParser.parse(payload, decodeText: decode))
        #expect(parsed.text == "[00:01.000]First line\n[01:02.500]Second line")
        #expect(parsed.languageCode == "en")

        let lines = LyricsContentParser.parseText(parsed.text)
        #expect(lines.map(\.timestamp) == [1, 62.5])
        #expect(lines.allSatisfy { $0.isSynchronized })
        #expect(lines.allSatisfy { !$0.isWordLevel })
    }

    @Test("Cues inside one line become word timing")
    func parsesWordCues() throws {
        let payload = frame(cues: [
            ("\nHold", 1_000),
            (" on", 1_400),
            (" tight", 1_900),
            ("\nLet go", 3_000),
        ])

        let parsed = try #require(ID3SynchronizedLyricsParser.parse(payload, decodeText: decode))
        #expect(parsed.text == """
        [00:01.000]<00:01.000>Hold<00:01.400> on<00:01.900> tight
        [00:03.000]Let go
        """)

        let lines = LyricsContentParser.parseText(parsed.text)
        #expect(lines.count == 2)
        #expect(lines[0].syllables?.map(\.text) == ["Hold", " on", " tight"])
        #expect(lines[0].syllables?.map(\.start) == [1, 1.4, 1.9])
    }

    @Test("UTF-16 cues are read with their two-byte terminator")
    func parsesUTF16Cues() throws {
        let payload = frame(encoding: 1, language: "jpn", descriptor: "Lyrics", cues: [
            ("君と", 500),
            ("\n歩く", 2_000),
        ])

        let parsed = try #require(ID3SynchronizedLyricsParser.parse(payload, decodeText: decode))
        #expect(parsed.text == "[00:00.500]君と\n[00:02.000]歩く")
        #expect(parsed.descriptor == "Lyrics")
        #expect(parsed.languageCode == "ja")
    }

    @Test("Out-of-order cues are placed on the timeline in time order")
    func sortsCues() throws {
        let payload = frame(cues: [
            ("\nSecond", 4_000),
            ("\nFirst", 2_000),
        ])

        let parsed = try #require(ID3SynchronizedLyricsParser.parse(payload, decodeText: decode))
        #expect(parsed.text == "[00:02.000]First\n[00:04.000]Second")
    }

    @Test("Frames that cannot describe sung words are rejected")
    func rejectsUnusableFrames() {
        // Timestamp format $01 counts MPEG frames, which cannot be converted
        // without decoding the audio.
        #expect(ID3SynchronizedLyricsParser.parse(
            frame(timestampFormat: 1, cues: [("First", 1_000)]),
            decodeText: decode
        ) == nil)
        // Content type $04 is an event list, not lyrics.
        #expect(ID3SynchronizedLyricsParser.parse(
            frame(contentType: 4, cues: [("First", 1_000)]),
            decodeText: decode
        ) == nil)
        #expect(ID3SynchronizedLyricsParser.parse(
            frame(cues: []),
            decodeText: decode
        ) == nil)
        #expect(ID3SynchronizedLyricsParser.parse(Data([0, 1, 2]), decodeText: decode) == nil)
    }

    @Test("An unusable language tag stays unset")
    func ignoresPlaceholderLanguages() throws {
        let parsed = try #require(ID3SynchronizedLyricsParser.parse(
            frame(language: "xxx", cues: [("First", 1_000)]),
            decodeText: decode
        ))
        #expect(parsed.languageCode == nil)
    }

    @Test("A truncated cue does not take the whole frame down")
    func toleratesTruncatedTail() throws {
        var payload = frame(cues: [("First", 1_000), ("\nSecond", 2_000)])
        payload = payload.dropLast(2)

        let parsed = try #require(ID3SynchronizedLyricsParser.parse(payload, decodeText: decode))
        #expect(parsed.text == "[00:01.000]First")
    }
}
