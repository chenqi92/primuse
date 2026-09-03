import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics content parser")
struct LyricsContentParserTests {
    private var screenshotStyle41LineLRC: String {
        let visibleLines = [
            "[00:00.00]作词：彭锋",
            "[00:01.00]作曲：徐鸣涧",
            "[00:05.17]发行：北京自在天浩文化传媒有限公司",
            "[00:29.67]青春大概如你所说",
            "[00:33.97]在花开的季节经过",
            "[00:37.89]转身以后才懂得",
        ]
        let remainingLines = (7...41).map { index in
            let totalCentiseconds = 3_789 + (index - 6) * 387
            let minutes = totalCentiseconds / 6_000
            let seconds = (totalCentiseconds % 6_000) / 100
            let fraction = totalCentiseconds % 100
            return String(
                format: "[%02d:%02d.%02d]回归测试歌词第%02d行",
                minutes,
                seconds,
                fraction,
                index
            )
        }
        return (["[ti:青春大概]", "[ar:青春主题曲]"] + visibleLines + remainingLines)
            .joined(separator: "\n")
    }

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
        let serialized = LyricsContentParser.serializeTTML(lines)
        #expect(serialized.contains("<ttm:agent xml:id=\"v1\""))
        #expect(serialized.contains("<ttm:agent xml:id=\"v2\""))
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

    @Test("Start-only TTML remains inferred after serialization")
    func startOnlyTTMLDoesNotInventExplicitEnds() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span begin="1s">A</span><span begin="5s">B</span>
          </p></div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        let first = try #require(parsed.first?.syllables?.first)
        #expect(first.endTiming == .inferred)

        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(!serialized.contains("<span begin=\"00:00:01.000\" end="))
        #expect(!serialized.contains("<p begin=\"00:00:01.000\" end="))
        let roundTripFirst = try #require(
            LyricsContentParser.parse(serialized).first?.syllables?.first
        )
        #expect(roundTripFirst.endTiming == .inferred)
    }

    @Test("TTML span duration inherits its paragraph start")
    func preservesTTMLDurationWithInheritedBegin() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s"><span dur="1s">A</span></p></div></body>
        </tt>
        """

        let syllable = try #require(
            LyricsContentParser.parse(content).first?.syllables?.first
        )
        #expect(syllable.start == 1)
        #expect(syllable.end == 2)
        #expect(syllable.endTiming == .explicit)
    }

    @Test("TTML mixed content remains attached to timed words")
    func preservesTTMLMixedContent() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span begin="1s">Hello</span> <span begin="2s">world</span>!
          </p></div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        let line = try #require(parsed.first)
        #expect(line.text == "Hello world!")
        #expect(line.syllables?.map(\.text) == ["Hello ", "world!"])

        let roundTrip = LyricsContentParser.parse(
            LyricsContentParser.serializeTTML(parsed)
        )
        #expect(LyricsContentParser.areSemanticallyEquivalent(parsed, roundTrip))
    }

    @Test("Nested TTML style wrappers preserve inner word timing")
    func preservesNestedTTMLWordTiming() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span style="outer"><span begin="1s">Hi</span><span begin="2s"> there</span></span>
          </p></div></body>
        </tt>
        """

        let line = try #require(LyricsContentParser.parse(content).first)
        let syllables = try #require(line.syllables)
        #expect(line.text == "Hi there")
        #expect(syllables.map(\.text) == ["Hi", " there"])
        #expect(syllables.map(\.start) == [1, 2])
    }

    @Test("Nested TTML keeps outer timing for leading direct text")
    func preservesNestedTTMLOuterTextTiming() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span begin="1s" end="3s">A <span begin="2s" end="3s">B</span></span>
          </p></div></body>
        </tt>
        """

        let syllables = try #require(
            LyricsContentParser.parse(content).first?.syllables
        )
        #expect(syllables.map(\.text) == ["A ", "B"])
        #expect(syllables.map(\.start) == [1, 2])
    }

    @Test("Nested TTML keeps trailing outer text separate from the child cue")
    func preservesNestedTTMLTrailingTextTiming() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span begin="1s" end="3s">A <span begin="2s" end="2.5s">B</span> C</span>
          </p></div></body>
        </tt>
        """

        let syllables = try #require(
            LyricsContentParser.parse(content).first?.syllables
        )
        #expect(syllables.map(\.text) == ["A ", "B", " C"])
        #expect(syllables.map(\.start) == [1, 2, 2.5])
        #expect(syllables.last?.end == 3)
    }

    @Test("Serializer voice IDs stay stable when the secondary cue starts first")
    func preservesVoiceRolesWhenSecondaryStartsFirst() {
        let lines = [
            LyricLine(
                timestamp: 2,
                text: "Primary",
                isSynchronized: true,
                endTimestamp: 4,
                voice: .primary
            ),
            LyricLine(
                timestamp: 1,
                text: "Secondary",
                isSynchronized: true,
                endTimestamp: 1.5,
                voice: .secondary
            ),
        ]
        let reparsed = LyricsContentParser.parse(
            LyricsContentParser.serializeTTML(lines)
        )
        #expect(reparsed.first(where: { $0.text == "Primary" })?.voice == .primary)
        #expect(reparsed.first(where: { $0.text == "Secondary" })?.voice == .secondary)
    }

    @Test("TTML explicit line breaks survive structured serialization")
    func preservesTTMLLineBreaks() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s">
            <span begin="1s">Hi</span>
            <br/>
            <span begin="2s">there</span>
          </p></div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        #expect(parsed.first?.text == "Hi\nthere")
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("Hi<br/>"))
        let roundTrip = try #require(LyricsContentParser.parse(serialized).first)
        #expect(roundTrip.text == "Hi\nthere")
        #expect(roundTrip.syllables?.map(\.text).joined() == "Hi\nthere")
    }

    @Test("TTML zero-duration line windows survive serialization")
    func preservesZeroDurationLineWindows() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s" end="1s">Beat</p></div></body>
        </tt>
        """
        let parsed = LyricsContentParser.parse(content)
        #expect(parsed.first?.endTimestamp == 1)
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("end=\"00:00:01.000\""))
        #expect(LyricsContentParser.parse(serialized).first?.endTimestamp == 1)
    }

    @Test("TTML document language survives parsing and serialization")
    func preservesTTMLDocumentLanguage() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="fa-Arab">
          <body><div><p begin="1s">سلام دنیا</p></div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        let metadata = try #require(parsed.first?.metadataLines)
        #expect(LyricManualTranslationPolicy.declaredLanguageCode(in: metadata) == "fa-Arab")
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("xml:lang=\"fa-Arab\""))
        #expect(LyricsContentParser.areSemanticallyEquivalent(
            parsed,
            LyricsContentParser.parse(serialized)
        ))
    }

    @Test("TTML paragraph language is inherited and available to routing")
    func preservesTTMLParagraphLanguage() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s" xml:lang="fa">سلام دنیا</p></div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        #expect(parsed.first?.languageCode == "fa")
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("xml:lang=\"fa\""))
    }

    @Test("Mixed TTML paragraph languages survive round-trip")
    func preservesMixedTTMLParagraphLanguages() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="1s" xml:lang="fa">سلام</p>
            <p begin="2s" xml:lang="en">Hello</p>
          </div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        #expect(parsed.count == 2)
        #expect(parsed[0].languageCode == "fa")
        #expect(parsed[1].languageCode == "en")
        let roundTrip = LyricsContentParser.parse(
            LyricsContentParser.serializeTTML(parsed)
        )
        #expect(LyricsContentParser.areSemanticallyEquivalent(parsed, roundTrip))
    }

    @Test("TTML root language stays distinct from a paragraph override")
    func preservesTTMLRootLanguageWithParagraphOverride() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body><div>
            <p begin="1s" xml:lang="fa">سلام</p>
            <p begin="2s">Hello</p>
          </div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        #expect(LyricManualTranslationPolicy.declaredLanguageCode(
            in: parsed[0].metadataLines ?? []
        ) == "en")
        #expect(parsed[0].languageCode == "fa")
        #expect(parsed[1].languageCode == nil)
        let roundTrip = LyricsContentParser.parse(
            LyricsContentParser.serializeTTML(parsed)
        )
        #expect(LyricsContentParser.areSemanticallyEquivalent(parsed, roundTrip))
    }

    @Test("TTML timed span language overrides survive round-trip")
    func preservesTTMLSpanLanguageOverrides() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body><div>
            <p begin="1s" end="3s">
              <span begin="1s" end="2s">Hello </span>
              <span begin="2s" end="3s" xml:lang="fa">دنیا</span>
            </p>
          </div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        let syllables = try #require(parsed.first?.syllables)
        #expect(syllables.map(\.languageCode) == [nil, "fa"])
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("<span begin=\"00:00:02.000\" end=\"00:00:03.000\" xml:lang=\"fa\">"))
        #expect(LyricsContentParser.areSemanticallyEquivalent(
            parsed,
            LyricsContentParser.parse(serialized)
        ))
    }

    @Test("Semantic metadata comparison ignores blank separator rows")
    func ignoresMetadataSeparatorRows() {
        let left = [LyricLine(
            timestamp: 1,
            text: "Line",
            isSynchronized: true,
            metadataLines: ["[ar:Artist]"]
        )]
        let right = [LyricLine(
            timestamp: 1,
            text: "Line",
            isSynchronized: true,
            metadataLines: ["[ar:Artist]", "  "]
        )]
        #expect(LyricsContentParser.areSemanticallyEquivalent(left, right))
    }

    @Test("Explicit zero-duration final words keep their provenance")
    func preservesExplicitZeroDurationWords() throws {
        let line = LyricLine(
            timestamp: 1,
            text: "Beat",
            isSynchronized: true,
            syllables: [
                .init(text: "Beat", start: 1, end: 1, endTiming: .explicit),
            ]
        )

        let lrcRoundTrip = try #require(
            LyricsContentParser.parse(LyricsContentParser.serialize([line])).first
        )
        #expect(lrcRoundTrip.syllables?.first?.end == 1)
        #expect(lrcRoundTrip.syllables?.first?.endTiming == .explicit)

        let ttmlRoundTrip = try #require(
            LyricsContentParser.parse(LyricsContentParser.serializeTTML([line])).first
        )
        #expect(ttmlRoundTrip.syllables?.first?.end == 1)
        #expect(ttmlRoundTrip.syllables?.first?.endTiming == .explicit)
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

        var changedProvenance = roundTrip
        changedProvenance[0].syllables?[0].endTiming = .explicit
        #expect(!LyricsContentParser.areSemanticallyEquivalent(expected, changedProvenance))

        var changedMetadata = roundTrip
        changedMetadata[0].metadataLines = ["[la:fa]"]
        #expect(!LyricsContentParser.areSemanticallyEquivalent(expected, changedMetadata))
    }

    @Test("Forty-one-line save readback accepts only transport and precision changes")
    func comparesFortyOneLineSaveReadback() throws {
        let sourceLines = LyricsContentParser.parse(screenshotStyle41LineLRC)
        #expect(sourceLines.count == 41)

        let canonical = LyricsContentParser.serialize(sourceLines)
        let readback = "\u{FEFF}" + canonical
            .replacingOccurrences(
                of: "[ar:青春主题曲]\n",
                with: "[ar:青春主题曲]\n\n"
            )
            .replacingOccurrences(of: "\n", with: "\r\n")
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            readback
        ))

        let missingLine = canonical.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            missingLine
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            canonical.replacingOccurrences(of: "第20行", with: "错误歌曲内容")
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            canonical.replacingOccurrences(of: "[ar:青春主题曲]", with: "[ar:错误歌手]")
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            canonical.replacingOccurrences(of: "[00:29.670]", with: "[00:29.680]")
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            screenshotStyle41LineLRC,
            canonical + "\n未带时间戳的残留行"
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            "前缀会被解析器忽略[00:01.00]正文",
            "[00:01.00]正文"
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            "[00:01.00]遗漏正文<00:01.00>保留正文",
            "[00:01.00]<00:01.00>保留正文"
        ))
    }

    @Test("TTML writeback comparison accepts transport normalization but no lossy rewrite")
    func comparesCompleteTTMLDocuments() {
        let transportNormalized = "\u{FEFF}"
            + issue27TTML.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(
            issue27TTML,
            transportNormalized
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            issue27TTML,
            issue27TTML.replacingOccurrences(of: "SECOND &amp; LINE", with: "SECOND LINE")
        ))
    }

    @Test("Semantic content comparison preserves same-time order and translations")
    func comparesSameTimeOrderAndTranslations() {
        let bilingual = """
        [la:en]
        [00:01.00]Stay with me
        [00:01.00]Reste avec moi
        [00:03.00]Through the night
        [00:03.00]Toute la nuit
        """
        let canonical = LyricsContentParser.serialize(LyricsContentParser.parse(bilingual))
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(bilingual, canonical))

        let reordered = """
        [la:en]
        [00:01.000]Reste avec moi
        [00:01.000]Stay with me
        [00:03.000]Through the night
        [00:03.000]Toute la nuit
        """
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(bilingual, reordered))
    }

    @Test("Semantic content comparison covers ELRC, plain text, and RTL lyrics")
    func comparesEditableFormatsAndRTLText() {
        let serializedELRC = LyricsContentParser.serialize(
            LyricsContentParser.parse(issue15ELRC)
        )
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(
            issue15ELRC,
            "\u{FEFF}" + serializedELRC.replacingOccurrences(of: "\n", with: "\r\n")
        ))

        let rtl = "شب آرام است\nدل من بیدار است\nراه ادامه دارد"
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(
            rtl,
            "\u{FEFF}شب آرام است\r\n\r\nدل من بیدار است\r\nراه ادامه دارد"
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            rtl,
            "شب آرام است\nراه ادامه دارد"
        ))
    }

    @Test("Overlapping TTML agents share one row but keep independent word timelines")
    func groupsStructuredOverlappingVoices() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="10s" end="14s" ttm:agent="v1">
              <span begin="10s" end="11s">Lead </span>
              <span begin="11s" end="14s">voice</span>
            </p>
            <p begin="11.5s" end="13.5s" ttm:agent="v2">
              <span begin="11.5s" end="12.2s">Backing </span>
              <span begin="12.2s" end="13.5s">voice</span>
            </p>
            <p begin="14s" end="16s" ttm:agent="v1">Next line</p>
          </div></body>
        </tt>
        """

        let lines = LyricsContentParser.parse(content)
        let background = try #require(lines.first?.background?.first)

        #expect(lines.count == 2)
        #expect(lines[0].voice == .primary)
        #expect(background.voice == .secondary)
        #expect(background.timestamp == 11.5)
        #expect(background.endTimestamp == 13.5)
        #expect(background.syllables?.map(\.start) == [11.5, 12.2])
        #expect(LyricVoiceTimelinePolicy.isActive(background, at: 12.5))
        #expect(!LyricVoiceTimelinePolicy.isActive(background, at: 13.5))
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(in: lines, at: 12.5) == 0)

        let roundTrip = LyricsContentParser.parse(LyricsContentParser.serializeTTML(lines))
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, roundTrip))
    }

    @Test("Legacy line-level voice caches infer overlap without treating parentheses as voices")
    func groupsLegacyStructuredVoiceCache() throws {
        let cached = [
            LyricLine(timestamp: 10, text: "Lead", voice: .primary),
            LyricLine(timestamp: 11, text: "Backing", voice: .secondary),
            LyricLine(timestamp: 14, text: "Next", voice: .primary),
        ]

        let grouped = LyricVoiceTimelinePolicy.groupingOverlappingSecondaryLines(in: cached)
        let background = try #require(grouped.first?.background?.first)

        #expect(grouped.count == 2)
        #expect(background.text == "Backing")
        #expect(background.endTimestamp == 14)
    }

    @Test("Adjacent same-timestamp bilingual LRC keeps authored translations")
    func recognizesBilingualLRCWithDocumentEvidence() throws {
        let content = """
        [00:01.00]想看你微笑
        [00:01.00]I want to see you smile
        [00:05.00]陪你走回家
        [00:05.00]Walk home together
        [00:09.00]今夜别离开
        [00:09.00]Please stay tonight
        """

        let lines = LyricsContentParser.parse(content)
        #expect(lines.map(\.text) == ["想看你微笑", "陪你走回家", "今夜别离开"])
        #expect(lines.map { $0.manualTranslation?.text } == [
            "I want to see you smile",
            "Walk home together",
            "Please stay tonight",
        ])
        #expect(lines.allSatisfy { $0.manualTranslation?.source == .bilingualLRC })

        let serialized = LyricsContentParser.serialize(lines)
        let reparsed = LyricsContentParser.parse(serialized)
        #expect(serialized.contains("[00:05.000]Walk home together"))
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, reparsed))

        let literalLines = LyricsContentParser.parse(content, options: .literal)
        #expect(literalLines.count == 6)
        #expect(literalLines.allSatisfy { $0.manualTranslation == nil })
    }

    @Test("Same-language and mixed-orientation rows are not inferred as translations")
    func leavesAmbiguousLanguagePatternsUnpaired() {
        let sameLanguage = """
        [00:01.00]第一声部
        [00:01.00]第二声部
        [00:05.00]领唱继续
        [00:05.00]合唱继续
        """
        let sameLanguageLines = LyricsContentParser.parse(sameLanguage)
        #expect(sameLanguageLines.count == 4)
        #expect(sameLanguageLines.allSatisfy { $0.manualTranslation == nil })

        let mixedOrientations = """
        [00:01.00]第一句歌词
        [00:01.00]First lyric line
        [00:05.00]Second singer
        [00:05.00]第二位歌手
        [00:09.00]第三句歌词
        [00:09.00]Third lyric line
        [00:13.00]Fourth singer
        [00:13.00]第四位歌手
        """
        let mixedLines = LyricsContentParser.parse(mixedOrientations)
        #expect(mixedLines.count == 8)
        #expect(mixedLines.allSatisfy { $0.manualTranslation == nil })
    }

    @Test("Repeated chorus and multi-voice timestamps remain separate")
    func avoidsChorusAndDuetFalsePairs() {
        let repeatedChorus = """
        [00:01.00]永远爱你
        [00:01.00]Love you forever
        [00:05.00]永远爱你
        [00:05.00]Love you forever
        """
        let chorusLines = LyricsContentParser.parse(repeatedChorus)
        #expect(chorusLines.count == 4)
        #expect(chorusLines.allSatisfy { $0.manualTranslation == nil })

        let threeVoices = """
        [00:01.00]主唱歌词
        [00:01.00]Backing voice
        [00:01.00]合唱歌词
        [00:05.00]下一句主唱
        [00:05.00]Next backing voice
        [00:05.00]下一句合唱
        """
        let voiceLines = LyricsContentParser.parse(threeVoices)
        #expect(voiceLines.count == 6)
        #expect(voiceLines.allSatisfy { $0.manualTranslation == nil })

        let labelledDuet = """
        [00:01.00]男：今夜别走
        [00:01.00]B: I have to leave
        [00:05.00]男：请再等我
        [00:05.00]B: I cannot stay
        """
        let duetLines = LyricsContentParser.parse(labelledDuet)
        #expect(duetLines.count == 4)
        #expect(duetLines.allSatisfy { $0.manualTranslation == nil })
    }

    @Test("Manual translations remain backward-compatible Codable data")
    func preservesManualTranslationCodableFields() throws {
        let line = LyricLine(
            id: "source",
            timestamp: 1,
            text: "原文",
            isSynchronized: true,
            manualTranslation: LyricManualTranslation(
                id: "english",
                text: "Original",
                languageCode: "en",
                source: .embeddedField
            ),
            alternateManualTranslations: [
                LyricManualTranslation(
                    id: "french",
                    text: "Texte original",
                    languageCode: "fr",
                    source: .embeddedField
                ),
            ]
        )
        let decoded = try JSONDecoder().decode(
            LyricLine.self,
            from: JSONEncoder().encode(line)
        )
        #expect(decoded.manualTranslation == line.manualTranslation)
        #expect(decoded.alternateManualTranslations == line.alternateManualTranslations)
        #expect(decoded.allManualTranslations.map(\.languageCode) == ["en", "fr"])

        let legacyData = Data(
            #"{"id":"legacy","timestamp":1,"text":"Legacy"}"#.utf8
        )
        let legacy = try JSONDecoder().decode(LyricLine.self, from: legacyData)
        #expect(legacy.manualTranslation == nil)
        #expect(legacy.alternateManualTranslations.isEmpty)
    }
}
