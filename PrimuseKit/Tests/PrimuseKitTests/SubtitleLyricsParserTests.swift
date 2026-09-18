import Foundation
import Testing
@testable import PrimuseKit

@Suite("Subtitle lyric documents")
struct SubtitleLyricsParserTests {
    /// Real YouTube auto-captions: a lone space opens or closes nearly every
    /// cue, and each cue repeats the line that is scrolling off screen.
    private let rollingCaptions = [
        "WEBVTT",
        "Kind: captions",
        "Language: en",
        "",
        "00:00:00.480 --> 00:00:02.869 align:start position:0%",
        " ",
        "never<00:00:00.880><c> gonna</c><00:00:01.199><c> give</c>"
            + "<00:00:01.439><c> you</c><00:00:01.760><c> up</c>",
        "",
        "00:00:02.869 --> 00:00:02.879 align:start position:0%",
        "never gonna give you up",
        " ",
        "",
        "00:00:02.879 --> 00:00:05.030 align:start position:0%",
        "never gonna give you up",
        "never<00:00:03.200><c> gonna</c><00:00:03.520><c> let</c>"
            + "<00:00:03.840><c> you</c><00:00:04.160><c> down</c>",
        "",
        "00:00:05.030 --> 00:00:05.040 align:start position:0%",
        "never gonna let you down",
        " ",
        "",
        "00:00:05.040 --> 00:00:07.500 align:start position:0%",
        "never gonna let you down",
        "[Music]",
    ].joined(separator: "\n")

    /// The machine-translated companion of that same video: same cue
    /// structure, same fillers, and no word timing anywhere.
    private let translatedRollingCaptions = [
        "WEBVTT",
        "Kind: captions",
        "Language: zh-Hans",
        "",
        "00:00:00.480 --> 00:00:02.869 align:start position:0%",
        " ",
        "永远不会放弃你",
        "",
        "00:00:02.869 --> 00:00:02.879 align:start position:0%",
        "永远不会放弃你",
        " ",
        "",
        "00:00:02.879 --> 00:00:05.030 align:start position:0%",
        "永远不会放弃你",
        "永远不会让你失望",
        "",
        "00:00:05.030 --> 00:00:05.040 align:start position:0%",
        "永远不会让你失望",
        " ",
        "",
        "00:00:05.040 --> 00:00:07.500 align:start position:0%",
        "永远不会让你失望",
        "永远不会到处乱跑",
    ].joined(separator: "\n")

    @Test("A byte-order mark and CRLF line endings do not hide the header")
    func readsWebVTTHeader() throws {
        let document = "\u{FEFF}WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.500\r\nHello\r\n"
        #expect(SubtitleLyricsParser.detect(document) == .webVTT)

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "Hello")
        #expect(lines.first?.timestamp == 1)
        #expect(lines.first?.endTimestamp == 2.5)

        // A missing blank line after the header must not swallow the first cue.
        let unseparated = "WEBVTT\n00:00:01.000 --> 00:00:02.500\nHello"
        #expect(SubtitleLyricsParser.parse(unseparated).first?.text == "Hello")
    }

    @Test("Cue identifiers and cue settings are not lyrics")
    func ignoresCueIdentifiersAndSettings() throws {
        let document = """
        WEBVTT

        intro
        00:00.500 --> 00:02.000 align:start position:0% line:90%
        Hello
        """

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "Hello")
        #expect(lines.first?.timestamp == 0.5)
        #expect(lines.first?.endTimestamp == 2)
    }

    @Test("An hour field shifts the whole cue")
    func readsHourTimestamps() throws {
        let document = """
        WEBVTT

        01:02:03.400 --> 01:02:05.000
        Late in the set
        """

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.first?.timestamp == 3_723.4)
        #expect(lines.first?.endTimestamp == 3_725)
    }

    @Test("Header, comment and styling blocks are skipped")
    func skipsNonCueBlocks() throws {
        let document = """
        WEBVTT

        NOTE this comment
        runs over two lines

        STYLE
        ::cue { color: yellow }

        REGION
        id:fred width:40%

        00:00:01.000 --> 00:00:02.000
        Only line
        """

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "Only line")
    }

    @Test("Markup is removed, entities decoded and ruby annotations dropped")
    func cleansPayloadMarkup() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        <c.loud><i>A</i> &amp; B &lt;3 &#65;&#x42;</c>

        00:00:02.000 --> 00:00:03.000
        <ruby>漢<rt>かん</rt></ruby>字

        00:00:03.000 --> 00:00:04.000
        <lang en>Keep</lang>&nbsp;&lrm;this
        """

        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expected = ["A & B <3 AB", "漢字", "Keep this"]
        #expect(texts == expected)
    }

    @Test("SubRip counters, comma decimals and override blocks are handled")
    func parsesSubRip() throws {
        let document = """
        1
        00:00:01,000 --> 00:00:03,500
        {\\an8}<i>First line</i>

        2
        00:00:03,500 --> 00:00:06,000
        Second line
        """

        #expect(SubtitleLyricsParser.detect(document) == .subRip)
        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expectedTexts = ["First line", "Second line"]
        let timestamps = lines.map(\.timestamp)
        let expectedTimestamps: [TimeInterval] = [1, 3.5]
        #expect(texts == expectedTexts)
        #expect(timestamps == expectedTimestamps)
        #expect(lines.last?.endTimestamp == 6)
    }

    @Test("Inline markers become syllables that close on the cue end")
    func buildsSyllablesFromInlineMarkers() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never<00:00:01.500><c> gonna</c><00:00:02.000><c> give</c>
        """

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "never gonna give")

        let syllables = try #require(lines.first?.syllables)
        let texts = syllables.map(\.text)
        let expectedTexts = ["never", " gonna", " give"]
        let starts = syllables.map(\.start)
        let expectedStarts: [TimeInterval] = [1, 1.5, 2]
        let ends = syllables.map(\.end)
        let expectedEnds: [TimeInterval] = [1.5, 2, 3]
        #expect(texts == expectedTexts)
        #expect(starts == expectedStarts)
        #expect(ends == expectedEnds)
        #expect(syllables.last?.endTiming == .explicit)
    }

    @Test("Unusable inline markers fall back to a line-level row")
    func rejectsInvalidInlineMarkers() throws {
        let backwards = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never<00:00:02.500> gonna<00:00:01.500> give
        """
        let outsideWindow = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never<00:00:05.000> gonna
        """

        let backwardsLines = SubtitleLyricsParser.parse(backwards)
        #expect(backwardsLines.first?.syllables == nil)
        #expect(backwardsLines.first?.text == "never gonna give")

        let outsideLines = SubtitleLyricsParser.parse(outsideWindow)
        #expect(outsideLines.first?.syllables == nil)
        #expect(outsideLines.first?.text == "never gonna")
    }

    @Test("The second singer in a document gets the duet alignment")
    func mapsVoicesByFirstAppearance() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        <v Alice>First line</v>

        00:00:02.000 --> 00:00:03.000
        <v Bob>Second line</v>

        00:00:03.000 --> 00:00:04.000
        <v Carol>Third line</v>

        00:00:04.000 --> 00:00:05.000
        <v.loud Alice>Fourth line</v>
        """

        let lines = SubtitleLyricsParser.parse(document)
        let voices = lines.map(\.voice)
        let expected: [LyricVoice] = [.primary, .secondary, .primary, .primary]
        #expect(lines.map(\.text).count == 4)
        #expect(voices == expected)
    }

    @Test("A bilingual cue keeps its translation attached to the source line")
    func pairsBilingualCues() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Hello my friend
        你好我的朋友

        00:00:03.000 --> 00:00:05.000
        The night is young
        夜还很长

        00:00:05.000 --> 00:00:07.000
        Sing with me now
        现在和我一起唱
        """

        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expected = ["Hello my friend", "The night is young", "Sing with me now"]
        #expect(texts == expected)
        #expect(lines.first?.manualTranslation?.text == "你好我的朋友")
        #expect(lines.first?.manualTranslation?.source == .bilingualLRC)
        #expect(lines.last?.manualTranslation?.text == "现在和我一起唱")
    }

    @Test("A wrapped same-language cue becomes one line")
    func joinsWrappedCueLines() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        I remember every single
        word you said to me

        00:00:03.000 --> 00:00:05.000
        And I will never forget
        the way you smiled
        """

        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expected = [
            "I remember every single word you said to me",
            "And I will never forget the way you smiled",
        ]
        #expect(texts == expected)
    }

    @Test("Rolling captions lose their fillers and repeated lines")
    func collapsesRollingCaptions() throws {
        let lines = SubtitleLyricsParser.parse(rollingCaptions)
        #expect(lines.count == 2)

        let texts = lines.map(\.text)
        let expectedTexts = ["never gonna give you up", "never gonna let you down"]
        #expect(texts == expectedTexts)
        #expect(lines[0].timestamp == 0.48)
        #expect(lines[0].endTimestamp == 2.869)
        #expect(lines[1].timestamp == 2.879)
        #expect(lines[1].endTimestamp == 5.03)

        let firstStarts = lines[0].syllables?.map(\.start)
        let expectedFirstStarts: [TimeInterval] = [0.48, 0.88, 1.199, 1.439, 1.76]
        let secondStarts = lines[1].syllables?.map(\.start)
        let expectedSecondStarts: [TimeInterval] = [2.879, 3.2, 3.52, 3.84, 4.16]
        #expect(firstStarts == expectedFirstStarts)
        #expect(secondStarts == expectedSecondStarts)
    }

    @Test("A translated caption track rolls the same way without word timing")
    func collapsesRollingCaptionsWithoutWordTiming() throws {
        // Word timing is the original track's alone; the repeated line inside
        // a sub-frame cue is what says the document rolls.
        let lines = SubtitleLyricsParser.parse(translatedRollingCaptions)
        #expect(lines.count == 3)

        let texts = lines.map(\.text)
        let expectedTexts = ["永远不会放弃你", "永远不会让你失望", "永远不会到处乱跑"]
        #expect(texts == expectedTexts)

        let starts = lines.map(\.timestamp)
        let expectedStarts: [TimeInterval] = [0.48, 2.879, 5.04]
        #expect(starts == expectedStarts)

        let wordLevelCount = lines.filter(\.isWordLevel).count
        #expect(wordLevelCount == 0)
        let translationCount = lines.compactMap(\.manualTranslation).count
        #expect(translationCount == 0)
    }

    @Test("A whitespace-only payload line does not end the cue")
    func keepsCuePayloadAfterBlankLookingLine() throws {
        let document = [
            "WEBVTT",
            "",
            "00:00:01.000 --> 00:00:03.000",
            " ",
            "Still the same cue",
            "\t",
        ].joined(separator: "\n")

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "Still the same cue")
    }

    @Test("A repeated chorus line in ordinary lyrics stays two lines")
    func keepsRepeatedChorusLines() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Never gonna give you up

        00:00:03.000 --> 00:00:05.000
        Never gonna give you up
        """

        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expected = ["Never gonna give you up", "Never gonna give you up"]
        #expect(texts == expected)
    }

    @Test("Note symbols are stripped and noise tokens dropped")
    func stripsDecorationAndNoise() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        ♪ Sing with me ♪

        00:00:02.000 --> 00:00:03.000
        [Music]

        00:00:03.000 --> 00:00:04.000
        (Yeah)
        """

        let lines = SubtitleLyricsParser.parse(document)
        let texts = lines.map(\.text)
        let expected = ["Sing with me", "(Yeah)"]
        #expect(texts == expected)
    }

    @Test("A cue starting at zero is still synchronized")
    func keepsZeroStartSynchronized() throws {
        let document = """
        WEBVTT

        00:00.000 --> 00:02.000
        First
        """

        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.first?.timestamp == 0)
        #expect(lines.first?.isSynchronized == true)
    }

    @Test("Other lyric formats are never taken for a subtitle document")
    func leavesOtherFormatsAlone() throws {
        let lrc = "[00:10.00]First line\n[00:12.00]Second line"
        let elrc = "[00:12.00]<00:12.00>Second <00:12.50>line"
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
        <p begin="00:00:01.000" end="00:00:02.000">Hi</p></div></body></tt>
        """
        let lys = "[0]Lately (358,1336)I've (1694,487)been(2181,673)"
        let yrc = "[190871,1984](190871,361,0)For (191232,172,0)the"
        let qrc = "[190871,1984]For (190871,361)the (191232,172)first(191404,376)"

        #expect(SubtitleLyricsParser.detect(lrc) == nil)
        #expect(SubtitleLyricsParser.detect(elrc) == nil)
        #expect(SubtitleLyricsParser.detect(ttml) == nil)
        #expect(SubtitleLyricsParser.detect(lys) == nil)
        #expect(SubtitleLyricsParser.detect(yrc) == nil)
        #expect(SubtitleLyricsParser.detect(qrc) == nil)
        #expect(SubtitleLyricsParser.detect("Just a plain lyric line\nand another") == nil)
        #expect(LyricsContentParser.parseText(elrc).count == 1)
    }

    @Test("Shared parsing routes subtitle documents through the cue reader")
    func routesThroughSharedParser() throws {
        let document = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never<00:00:01.500> gonna

        00:00:03.000 --> 00:00:05.000
        give you up
        """

        #expect(LyricsContentParser.isSubtitleDocument(document))
        #expect(LyricsContentParser.parse(document).count == 2)
        #expect(LyricsContentParser.parseText(document).count == 2)
        #expect(LyricsContentParser.parseText(document).first?.isWordLevel == true)
        #expect(LyricsContentParser.validateEditableText(document).isValid)
    }

    @Test("Subtitle documents report the level of timing they carry")
    func classifiesSubtitleFormat() throws {
        let wordTimed = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never<00:00:01.500> gonna
        """
        let lineTimed = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        never gonna
        """

        #expect(LyricsFormat.detect(wordTimed) == .wordLevel)
        #expect(LyricsFormat.detect(lineTimed) == .lineLevel)
    }

    @Test("Subtitle sidecars are discovered but never chosen for writeback")
    func separatesReadableAndWritableExtensions() {
        #expect(PrimuseConstants.readableLyricsExtensions.contains("vtt"))
        #expect(PrimuseConstants.readableLyricsExtensions.contains("srt"))
        #expect(!PrimuseConstants.supportedLyricsExtensions.contains("vtt"))
        #expect(!PrimuseConstants.supportedLyricsExtensions.contains("srt"))
        // `.lrc` keeps priority so an edited document wins over a source file.
        #expect(PrimuseConstants.readableLyricsExtensions.first == "lrc")
    }
}
