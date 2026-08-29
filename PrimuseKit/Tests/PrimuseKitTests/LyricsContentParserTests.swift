import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics content parser")
struct LyricsContentParserTests {
    private let issue15ELRC = """
    [ti:I See Her]
    [ar:]
    [la:en]
    [by:Converted to ELRC]
    [00:14.98]<00:14.98>THINGS <00:15.60>FALL <00:16.25>APART
    [00:18.08]<00:18.08>AND <00:18.55>TIME <00:19.15>BREAKS <00:19.90>YOUR <00:20.40>HEART
    [00:21.51]<00:21.51>I <00:21.85>WASN'T <00:22.50>THERE, <00:23.15>BUT <00:23.55>I <00:23.85>KNOW
    [00:27.91]<00:27.91>SHE <00:28.35>WAS <00:28.70>YOUR <00:29.15>GIRL
    [00:31.02]<00:31.02>YOU <00:31.40>SHOWED <00:32.00>HER <00:32.35>THE <00:32.70>WORLD
    [00:34.31]<00:34.31>BUT <00:34.70>FELL <00:35.20>OUT <00:35.55>OF <00:35.85>LOVE <00:36.40>AND <00:36.80>YOU <00:37.15>BOTH <00:37.60>LET <00:38.00>GO
    [00:40.51]<00:40.51>SHE <00:40.90>WAS <00:41.25>CRYIN' <00:41.90>ON <00:42.20>MY <00:42.50>SHOULDER
    [00:44.06]<00:44.06>ALL <00:44.40>I <00:44.65>COULD <00:45.10>DO <00:45.40>WAS <00:45.75>HOLD <00:46.20>HER
    [00:47.51]<00:47.51>ONLY <00:48.00>MADE <00:48.45>US <00:48.80>CLOSER <00:49.50>UNTIL <00:50.05>JULY
    [00:53.76]<00:53.76>NOW <00:54.15>I <00:54.40>KNOW <00:54.80>THAT <00:55.15>YOU <00:55.50>LOVE <00:55.95>ME
    """

    private let issue27TTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml"
        xmlns:itunes="http://music.apple.com/lyrics"
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body>
        <div itunes:song-part="Verse">
          <p begin="00:00:09.420" end="00:00:12.000" ttm:agent="v1">
            <span begin="00:00:09.420" end="00:00:10.000">HEL</span>
            <span begin="00:00:10.000" end="00:00:10.500">LO </span>
            <span begin="00:00:10.500" end="00:00:12.000">WORLD</span>
          </p>
          <p begin="12.500s" dur="1.5s" ttm:agent="v2">SECOND &amp; LINE</p>
        </div>
      </body>
    </tt>
    """

    @Test("Issue 15 ELRC fixture keeps every line and word timestamp")
    func parsesIssue15Fixture() throws {
        let lines = LyricsContentParser.parse(issue15ELRC)

        #expect(lines.count == 10)
        #expect(lines.allSatisfy { $0.isSynchronized && $0.isWordLevel })
        #expect(lines[0].text == "THINGS FALL APART")
        #expect(lines[0].syllables?.count == 3)
        #expect(lines[5].syllables?.count == 10)
        #expect(lines[9].timestamp == 53.76)
        #expect(lines[9].syllables?.last?.start == 55.95)
    }

    @Test("ELRC keeps a delayed first word after an earlier line timestamp")
    func preservesDelayedFirstWordTimestamp() throws {
        let line = try #require(
            LyricsContentParser.parse("[00:00.00]<00:03.10>First<00:03.60> word").first
        )
        let syllables = try #require(line.syllables)

        #expect(line.timestamp == 0)
        #expect(syllables.map(\.text) == ["First", " word"])
        #expect(syllables[0].start == 3.1)
        #expect(syllables[0].end == 3.6)
    }

    @Test("Issue 27 Apple Music TTML keeps line, word, and voice timing")
    func parsesIssue27TTMLFixture() throws {
        let lines = LyricsContentParser.parse(issue27TTML)

        #expect(lines.count == 2)
        #expect(LyricsFormat.detect(issue27TTML) == .wordLevel)
        #expect(lines[0].timestamp == 9.42)
        #expect(lines[0].text == "HELLO WORLD")
        #expect(lines[0].voice == .primary)
        #expect(lines[0].syllables?.map(\.text) == ["HEL", "LO ", "WORLD"])
        #expect(lines[0].syllables?.map(\.start) == [9.42, 10, 10.5])
        #expect(lines[0].syllables?.map(\.end) == [10, 10.5, 12])
        #expect(lines[1].timestamp == 12.5)
        #expect(lines[1].text == "SECOND & LINE")
        #expect(lines[1].voice == .secondary)
        #expect(lines[1].isSynchronized)
        #expect(!lines[1].isWordLevel)

        let roundTrip = LyricsContentParser.parse(LyricsContentParser.serializeTTML(lines))
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, roundTrip))
        #expect(roundTrip.map(\.voice) == lines.map(\.voice))
    }

    @Test("TTML without word spans is detected as line-level lyrics")
    func detectsLineLevelTTML() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="00:00:00.000" end="00:00:02.000">Opening</p></div></body>
        </tt>
        """

        let line = try #require(LyricsContentParser.parseText(content).first)
        #expect(LyricsFormat.detect(content) == .lineLevel)
        #expect(line.timestamp == 0)
        #expect(line.isSynchronized)
        #expect(line.text == "Opening")
    }

    @Test("Malformed TTML is not exposed as raw XML lyric lines")
    func rejectsMalformedTTML() {
        let malformed = "<tt><body><p begin=\"1s\">Opening</body></tt>"
        #expect(LyricsContentParser.parseText(malformed).isEmpty)
        #expect(!LyricsContentParser.validateEditableText(malformed).isValid)
    }

    @Test("TTML is a supported sidecar extension")
    func supportsTTMLSidecars() {
        #expect(PrimuseConstants.supportedLyricsExtensions.contains("ttml"))
    }

    @Test("Lyrics file converter supports TTML, enhanced LRC, and plain text")
    func convertsBetweenSupportedLyricsFiles() throws {
        let lrc = try LyricsFileConverter.convert(issue27TTML, to: .lrc)
        #expect(lrc.sourceFormat == .wordLevel)
        #expect(lrc.output.contains("[00:09.420]<00:09.420>HEL"))
        #expect(lrc.output.contains("[00:12.500]SECOND & LINE"))

        let ttml = try LyricsFileConverter.convert(lrc.output, to: .ttml)
        #expect(ttml.output.contains("<tt xmlns="))
        #expect(ttml.output.contains("<span begin=\"00:00:09.420\""))
        #expect(LyricsContentParser.parse(ttml.output).map(\.text) == lrc.lines.map(\.text))

        let plain = try LyricsFileConverter.convert(issue27TTML, to: .plainText)
        #expect(plain.output == "HELLO WORLD\nSECOND & LINE")
        #expect(!plain.output.contains("00:00"))
    }

    @Test("Lyrics file converter rejects empty and malformed documents")
    func rejectsInvalidConversionInput() {
        #expect(throws: LyricsFileConversionError.emptyInput) {
            try LyricsFileConverter.convert("  \n", to: .lrc)
        }
        #expect(throws: LyricsFileConversionError.invalidContent) {
            try LyricsFileConverter.convert("<tt><body><p begin=\"1s\">Broken</body></tt>", to: .ttml)
        }
    }

    @Test("Line-level LRC beginning at zero remains synchronized")
    func zeroTimeLRCIsSynchronized() throws {
        let line = try #require(LyricsContentParser.parse("[00:00.00]Opening").first)
        #expect(line.isSynchronized)
        #expect(!line.isWordLevel)
    }

    @Test("Plain text remains unsynchronized")
    func plainTextRemainsUnsynchronized() {
        let lines = LyricsContentParser.parseText("First\nSecond")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.isSynchronized })
    }

    @Test("Plain-text sidecar survives serialize and rescan")
    func plainTextSidecarRoundTrip() {
        let firstScan = LyricsContentParser.parseText("First line\nSecond line\nThird line")
        let written = LyricsContentParser.serialize(firstScan)
        let rescanned = LyricsContentParser.parseText(written)

        #expect(rescanned.map(\.text) == ["First line", "Second line", "Third line"])
        #expect(rescanned.allSatisfy { !$0.isSynchronized })
    }

    @Test("Plain, LRC and ELRC serialization keeps their synchronization level")
    func serializesEveryEditableFormat() throws {
        let plain = LyricsContentParser.parseText("First\nSecond")
        #expect(LyricsContentParser.serialize(plain) == "First\nSecond")

        let lrc = LyricsContentParser.parseText("[00:00.000]Opening\n[01:02.345]Verse")
        let lrcText = LyricsContentParser.serialize(lrc)
        #expect(lrcText == "[00:00.000]Opening\n[01:02.345]Verse")
        let reparsedLRC = LyricsContentParser.parse(lrcText)
        #expect(reparsedLRC.map(\.timestamp) == lrc.map(\.timestamp))
        #expect(reparsedLRC.map(\.text) == lrc.map(\.text))

        let elrc = LyricsContentParser.parse(issue15ELRC)
        let elrcText = LyricsContentParser.serialize(elrc)
        let reparsed = LyricsContentParser.parse(elrcText)
        #expect(LyricsFormat.detect(elrcText) == .wordLevel)
        #expect(reparsed.map(\.timestamp) == elrc.map(\.timestamp))
        #expect(reparsed.map(\.text) == elrc.map(\.text))
        #expect(reparsed.map { $0.syllables?.map(\.start) } == elrc.map { $0.syllables?.map(\.start) })
    }

    @Test("ELRC metadata survives parse, cache encoding and serialization")
    func preservesDocumentMetadata() throws {
        let parsed = LyricsContentParser.parse(issue15ELRC)
        #expect(parsed.first?.metadataLines == [
            "[ti:I See Her]",
            "[ar:]",
            "[la:en]",
            "[by:Converted to ELRC]",
        ])

        let encoded = try JSONEncoder().encode(parsed)
        let decoded = try JSONDecoder().decode([LyricLine].self, from: encoded)
        let serialized = LyricsContentParser.serialize(decoded)
        #expect(serialized.hasPrefix("[ti:I See Her]\n[ar:]\n[la:en]\n[by:Converted to ELRC]\n"))
        #expect(LyricsContentParser.parse(serialized).first?.metadataLines == parsed.first?.metadataLines)
    }

    @Test("Editable validation reports malformed and decreasing timestamps")
    func validatesStructuredLyrics() {
        let valid = LyricsContentParser.validateEditableText(issue15ELRC)
        #expect(valid.isValid)
        #expect(valid.format == .wordLevel)
        #expect(valid.issues.isEmpty)

        let malformed = LyricsContentParser.validateEditableText("""
        [00:10.00]First
        [00:09.00]Second
        [00:12.00]<00:bad>Third
        """)
        #expect(!malformed.isValid)
        #expect(malformed.issues.contains {
            $0.lineNumber == 2 && $0.kind == .nonMonotonicTimestamp
        })
        #expect(malformed.issues.contains {
            $0.lineNumber == 3 && $0.kind == .invalidWordTimestamp
        })
    }

    @Test("Plain lyrics may contain angle brackets without becoming invalid ELRC")
    func validatesPlainAngleBrackets() {
        let validation = LyricsContentParser.validateEditableText("I <3 this song\nSecond line")
        #expect(validation.isValid)
        #expect(validation.format == .plain)
    }

    @Test("Semantic readback comparison covers line and word timestamps")
    func comparesWritebackReadback() {
        let expected = LyricsContentParser.parse(issue15ELRC)
        let roundTrip = LyricsContentParser.parse(LyricsContentParser.serialize(expected))
        #expect(LyricsContentParser.areSemanticallyEquivalent(expected, roundTrip))

        var changed = roundTrip
        changed[0].syllables?[0].start += 0.1
        #expect(!LyricsContentParser.areSemanticallyEquivalent(expected, changed))
    }
}
