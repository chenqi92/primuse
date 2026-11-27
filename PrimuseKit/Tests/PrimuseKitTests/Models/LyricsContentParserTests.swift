import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics content parser")
struct LyricsContentParserTests {
    @Test("Square word timestamps preserve text and explicit endings", arguments: [
        "[00:01.000]你[00:01.500]好[00:02.000]",
        "[00:01.00]你[00:01.50]好[00:02.00]",
        "[00:01:000]你[00:01:500]好[00:02:000]",
        "[00:01]你[00:01.5]好[00:02]",
        "\u{FEFF} [00:01.000]你[00:01.500]好[00:02.000]  ",
    ])
    func parsesSquareWordTimestamps(_ content: String) throws {
        let lines = LyricsContentParser.parseText(content)
        let line = try #require(lines.first)
        let words = try #require(line.syllables)

        #expect(lines.count == 1)
        #expect(LyricsFormat.detect(content) == .wordLevel)
        #expect(line.isSynchronized)
        #expect(line.timestamp == 1)
        #expect(line.text == "你好")
        #expect(words.map(\.text) == ["你", "好"])
        #expect(words.map(\.start) == [1, 1.5])
        #expect(words.map(\.end) == [1.5, 2])
        #expect(words.map(\.endTiming) == [.inferred, .explicit])
        #expect(LyricsContentParser.validateEditableText(content).isValid)
    }

    @Test("Square words without a terminal timestamp keep the final word")
    func parsesSquareWordsWithoutEnd() throws {
        let content = "[00:01.000]Hello [00:01.500]world!"
        let lines = LyricsContentParser.parse(content)
        let words = try #require(lines.first?.syllables)

        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello world!")
        #expect(words.map(\.text) == ["Hello ", "world!"])
        #expect(words.last?.start == 1.5)
        #expect(words.last?.end == 1.9)
        #expect(words.last?.endTiming == .inferred)
    }

    @Test("Repeated LRC heads remain separate line timings", arguments: [
        "[00:01.000][00:03.000]你好",
        "[00:01.000] [00:03.000]你好",
    ])
    func preservesRepeatedLRCHeads(_ content: String) {
        let lines = LyricsContentParser.parse(content)
        #expect(LyricsFormat.detect(content) == .lineLevel)
        #expect(lines.map(\.timestamp) == [1, 3])
        #expect(lines.map(\.text) == ["你好", "你好"])
        #expect(lines.allSatisfy { $0.isSynchronized && !$0.isWordLevel })
    }

    @Test("Mixed LRC, square words, ELRC and relative words retain every row")
    func parsesMixedWordTimestampFormats() throws {
        let content = """
        [ar:Artist]
        [00:00.000]说明
        [00:01.000]你[00:01.500]好[00:02.000]
        [00:03.000]<00:03.000>再<00:03.500>见<00:04.000>
        [5000,1000]<0,500,0>Hello <500,500,0>world
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let lines = LyricsContentParser.parse(content)

        #expect(lines.map(\.text) == ["说明", "你好", "再见", "Hello world"])
        #expect(lines.map(\.timestamp) == [0, 1, 3, 5])
        #expect(lines.map(\.isWordLevel) == [false, true, true, true])
        #expect(lines.first?.metadataLines?.filter { !$0.isEmpty } == ["[ar:Artist]"])
    }

    @Test("Square lyrics save as ELRC without losing text, rows or end timings")
    func roundTripsSquareWordTimestamps() {
        let content = """
        [ar:Artist]
        [00:01.000]你[00:01.500]好[00:02.000]
        [00:03.000]再[00:03.500]见[00:04.000]
        """
        let canonical = LyricsContentParser.serialize(LyricsContentParser.parse(content))
        #expect(LyricsContentParser.areContentsSemanticallyEquivalent(content, canonical))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            content, canonical.replacingOccurrences(of: "你", with: "他")
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            content, canonical.replacingOccurrences(of: "<00:02.000>", with: "<00:02.100>")
        ))
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            content, canonical.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        ))
    }

    @Test("Square timing preserves delayed starts, single tokens and literal brackets")
    func preservesSquareTimingBoundaries() throws {
        let delayed = try #require(LyricsContentParser.parse(
            "[00:00.000][00:01.000]你[00:01.500]好[00:02.000]"
        ).first)
        #expect(delayed.timestamp == 0)
        #expect(delayed.syllables?.map(\.start) == [1, 1.5])

        let single = try #require(LyricsContentParser.parse(
            "[00:01.000]Hello [chorus]![00:02.000]"
        ).first)
        #expect(single.text == "Hello [chorus]!")
        #expect(single.syllables?.count == 1)
        #expect(single.syllables?.last?.end == 2)
        #expect(single.syllables?.last?.endTiming == .explicit)
    }

    @Test("Square timing rejects invalid words and decreasing terminal timestamps", arguments: [
        "[00:01.000]你[00:99.000]好[00:02.000]",
        "[00:02.000]你[00:01.500]好[00:03.000]",
        "[00:01.000]你[00:02.000]好[00:01.500]",
    ])
    func validatesSquareTimingFailures(_ content: String) {
        let validation = LyricsContentParser.validateEditableText(content)
        #expect(!validation.isValid)
        #expect(validation.issues.allSatisfy { $0.lineNumber == 1 })
        #expect(!LyricsContentParser.areContentsSemanticallyEquivalent(
            content, LyricsContentParser.serialize(LyricsContentParser.parse(content))
        ))
    }

    @Test("Square timing retains the existing centisecond carry compatibility")
    func parsesSquareCentisecondCarry() throws {
        let line = try #require(LyricsContentParser.parse(
            "[00:01.90]你[00:01.92]好[00:01.100]"
        ).first)
        #expect(line.syllables?.map(\.start) == [1.9, 1.92])
        #expect(line.syllables?.last?.end == 2)
    }

    @Test("Cached square source text recovers timing without losing authored fields")
    func recoversLegacySquareWordCache() throws {
        let original = LyricLine(
            id: "cached-row",
            timestamp: 0,
            text: "[00:01.000]你[00:01.500]好[00:02.000]",
            isSynchronized: false,
            voice: .secondary,
            metadataLines: ["[ar:Artist]"],
            languageCode: "zh-Hans",
            documentIsLocalOverride: true,
            manualTranslation: .init(text: "Hello", languageCode: "en", source: .localEditor),
            alternateManualTranslations: [
                .init(text: "Bonjour", languageCode: "fr", source: .embeddedField),
            ]
        )
        let recovered = try JSONDecoder().decode(
            LyricLine.self, from: JSONEncoder().encode(original)
        )
        #expect(recovered.id == original.id)
        #expect(recovered.timestamp == 1)
        #expect(recovered.text == "你好")
        #expect(recovered.isSynchronized && recovered.isWordLevel)
        #expect(recovered.syllables?.last?.end == 2)
        #expect(recovered.voice == original.voice)
        #expect(recovered.metadataLines == original.metadataLines)
        #expect(recovered.languageCode == original.languageCode)
        #expect(recovered.documentIsLocalOverride == original.documentIsLocalOverride)
        #expect(recovered.manualTranslation == original.manualTranslation)
        #expect(recovered.alternateManualTranslations == original.alternateManualTranslations)
        let reread = try JSONDecoder().decode(
            LyricLine.self, from: JSONEncoder().encode(recovered)
        )
        #expect(reread == recovered)
    }

    @Test("Ordinary and damaged cached lyrics remain unchanged")
    func preservesUnrelatedCachedLyrics() throws {
        let originals = [
            LyricLine(timestamp: 0, text: "普通歌词", isSynchronized: false),
            LyricLine(timestamp: 0, text: "[00:01.000][00:03.000]重复", isSynchronized: false),
            LyricLine(timestamp: 0, text: "[00:02.000]你[00:01.000]好", isSynchronized: false),
            LyricLine(timestamp: 1, text: "[00:01.000]你[00:02.000]好", isSynchronized: true),
        ] + LyricsContentParser.parse("[00:01.000]<00:01.000>你好<00:02.000>")
        let recovered = try JSONDecoder().decode(
            [LyricLine].self, from: JSONEncoder().encode(originals)
        )
        #expect(recovered == originals)
    }

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

    @Test("Ruby readings stay separate from the sung words and keep their own timing")
    func keepsTimedRubyReadingsOnEachVoice() throws {
        let body = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <head><styling><style xml:id="base" tts:ruby="base"/><style xml:id="reading" tts:ruby="text"/></styling></head>
          <body><div><p begin="1" end="4"><span><span tts:ruby="container"><span style="base">灯</span><span tts:ruby="delimiter">(</span><span tts:ruby="textContainer"><span style="reading" begin="1" end="1.2">dēng</span></span><span tts:ruby="delimiter">)</span></span></span> <span begin="2" end="3" tts:ruby="container"><span tts:ruby="base">影</span><span tts:ruby="text">yǐng</span></span>!<span ttm:role="lyrics x-bg"><span tts:ruby="container"><span tts:ruby="base">波</span><span tts:ruby="text" begin="3" end="3.5">bō</span></span></span></p></div></body>
        </tt>
        """
        let line = try #require(LyricsContentParser.parseText(body).first)
        #expect(line.text == "灯 影!")
        #expect(line.syllables?.map(\.start) == [1, 2])
        #expect(line.romanization == "dēng yǐng!")
        #expect(line.romanizationSyllables?.map(\.start) == [1, 2])
        #expect(line.romanizationSyllables?.map(\.end) == [1.2, 3])
        #expect(line.background?.first?.text == "波")
        #expect(line.background?.first?.romanization == "bō")
        #expect(line.background?.first?.romanizationSyllables?.first?.end == 3.5)
        #expect(LyricsContentParser.areSemanticallyEquivalent([line], LyricsContentParser.parse(LyricsContentParser.serializeTTML([line]))))
    }

    @Test("A prefixed TTML document read from a UTF-16 tag keeps CDATA and omits paragraph metadata")
    func readsTranscodedTTMLAndCharacterData() throws {
        let content = "\u{FEFF}" + """
        <?xml version="1.0" encoding='UTF-16'?>
        <!-- source document -->
        <t:tt xmlns:t="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
          <t:body><t:div><t:p begin="2s"><t:metadata><m:desc>纸页注释</m:desc></t:metadata><t:span begin="2s"><![CDATA[风 & 雨]]></t:span><m:title>段落标题</m:title><t:span m:role="lyrics x-translation" xml:lang="en"><![CDATA[Rain & wind]]></t:span></t:p></t:div></t:body>
        </t:tt>
        """
        #expect(LyricsContentParser.isTTML(content))
        let line = try #require(LyricsContentParser.parseText(content).first)
        #expect(line.text == "风 & 雨")
        #expect(line.syllables?.map(\.text) == ["风 & 雨"])
        #expect(line.manualTranslation?.text == "Rain & wind")
        let literal = "[00:02.00]Fold <tt> into the margin"
        #expect(!LyricsContentParser.isTTML(literal))
        #expect(LyricsContentParser.parseText(literal).first?.text == "Fold <tt> into the margin")
    }

    @Test("TTML frame and tick clocks retain row and word timing")
    func readsTTMLFrameAndTickClocks() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
            ttp:frameRate="25" ttp:subFrameRate="2" ttp:tickRate="100">
          <body><div><p begin="100t" end="75f"><span begin="00:00:01:12.1" dur="25t">楼顶</span></p></div></body>
        </tt>
        """
        let line = try #require(LyricsContentParser.parse(content).first)
        #expect(line.timestamp == 1 && line.endTimestamp == 3)
        #expect(line.syllables?.first?.start == 1.5)
        #expect(line.syllables?.first?.end == 1.75)
        #expect(LyricsFormat.detect(content) == .wordLevel)
    }

    @Test("Sequential TTML containers and timed sections locate all their child lyrics")
    func followsTTMLTimeContainers() {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body dur="60s">
          <div begin="10s" timeContainer="seq">
            <p dur="2s"><span begin="0.5s" dur="1s">起航</span></p>
            <p begin="1s" dur="2s">过桥</p>
          </div>
          <div begin="20s" end="24s"><p>远灯</p></div>
          <div><p>尾注</p></div>
        </body></tt>
        """
        let lines = LyricsContentParser.parse(content)
        #expect(lines.map(\.text) == ["尾注", "起航", "过桥", "远灯"])
        #expect(lines.map(\.timestamp) == [0, 10, 13, 20])
        #expect(lines.map(\.endTimestamp) == [nil, 12, 15, 24])
        #expect(lines.first?.isSynchronized == false)
        #expect(lines.first(where: { $0.text == "起航" })?.syllables?.first?.start == 10.5)
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, LyricsContentParser.parse(LyricsContentParser.serializeTTML(lines))))
    }

    @Test("An embedded byte-order mark and late LRC headers retain lyric metadata")
    func readsBOMAndTrailingLRCMetadata() throws {
        let text = "\u{FEFF}[la:en]\n[00:05.00]A kite at the pier\n[offset:500]\n[by:Harbor Choir]"
        let line = try #require(LyricsContentParser.parseText(text).first)
        #expect(line.timestamp == 4.5)
        #expect(line.metadataLines == ["[la:en]", "[by:Harbor Choir]"])
        #expect(LyricsContentParser.parseText("\u{FEFF}Glass by the pier").first?.text == "Glass by the pier")
    }

    @Test("QRC accepts XML attribute quoting, literal newlines and numeric line breaks after metadata")
    func readsMultilineEmbeddedQRC() {
        let headers = Array(repeating: "[by:Harbor Choir]", count: 80).joined(separator: "\n")
        let content = """
        <QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent = '\(headers)
        [1000,500]潮(1000,500)&#xA;[2000,600]落(2000,600)'/></LyricInfo></QrcInfos>
        """
        #expect(WordTimedLyricsParser.detect(content) == .qrc)
        let lines = LyricsContentParser.parseText(content)
        #expect(lines.map(\.text) == ["潮", "落"])
        #expect(lines.compactMap { $0.syllables?.first?.start } == [1, 2])
    }

    @Test("Subtitle metadata on its own is never a lyric")
    func ignoresSubtitleMetadataWithoutCues() {
        let source = "\u{FEFF}WEBVTT\n\nNOTE\nPage credits"
        #expect(LyricsContentParser.parseText(source).isEmpty)
        #expect(!LyricsContentParser.validateEditableText(source).isValid)
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

    /// Apple Music word-timed documents mark backing vocals and authored
    /// translations with `ttm:role`. Both used to be appended to the sung line.
    @Test("A TTML romanization is kept beside its line, never as lyric text")
    func keepsTTMLRomanization() throws {
        let line = try #require(LyricsContentParser.parse(issue125TTML).first)

        #expect(line.romanization == "'Cause my heart")
        #expect(line.text == "'Cause my heart")
        #expect(line.syllables?.count == 3)
        // A romanization matches no target language, so it must never be
        // selectable as a translation.
        #expect(line.allManualTranslations.allSatisfy { $0.text != "'Cause my heart" })
        #expect(LyricManualTranslationPolicy.preferredTranslation(
            for: line,
            targetLanguageCode: "en"
        ) == nil)

        let serialized = LyricsContentParser.serializeTTML([line])
        #expect(serialized.contains("ttm:role=\"x-roman\""))
        let roundTrip = try #require(LyricsContentParser.parse(serialized).first)
        #expect(roundTrip.romanization == "'Cause my heart")
    }

    private let keyedAppleTTML = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:a="http://music.apple.com/lyric-ttml-internal"
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ko">
      <head><metadata><a:iTunesMetadata>
        <a:translations>
          <a:translation type="subtitle" xml:lang="zh-Hans">
            <a:text for="B">第二行</a:text><a:text for="orphan">未匹配</a:text>
            <a:text for="A"><span begin="2" end="2.4">第</span><span begin="2.4" end="3">一行</span><span ttm:role="x-bg">和声</span></a:text>
          </a:translation>
          <a:translation type="replacement" xml:lang="en"><a:text for="A">First line</a:text></a:translation>
        </a:translations>
        <a:transliterations><a:transliteration xml:lang="ko-Latn">
          <a:text for="B">dul</a:text>
          <a:text for="A">
            <span begin="2.1" end="2.3">ha</span>
            <span begin="2.3" end="2.9">na</span><span ttm:role="x-bg"><span begin="2.5" end="2.8">ho</span></span>
          </a:text>
        </a:transliteration></a:transliterations>
      </a:iTunesMetadata></metadata></head>
      <body><div>
        <p a:key="A" begin="2" end="3"><span begin="2" end="3">하나</span><span ttm:role="x-bg" begin="2.5" end="2.8">호</span></p>
        <p a:key="B" begin="4" end="5">둘<span ttm:role="x-roman">dul</span></p>
        <p begin="6" end="7">끝</p>
      </div></body>
    </tt>
    """

    @Test("Apple head translations and readings follow line keys and backing vocals")
    func matchesAppleTTMLHeadAnnotations() throws {
        let lines = LyricsContentParser.parseText(keyedAppleTTML)
        #expect(lines.map(\.text) == ["하나", "둘", "끝"])
        let line = try #require(lines.first)
        #expect(line.syllables?.map(\.text) == ["하나"])
        #expect(line.manualTranslation?.languageCode == "zh-Hans")
        #expect(line.manualTranslation?.syllables?.map(\.start) == [2, 2.4])
        #expect(line.alternateManualTranslations.map(\.text) == ["First line"])
        let translation = LyricManualTranslationPolicy.preferredTranslation(for: line, targetLanguageCode: "zh-Hans")
        let row = LyricRomanizationDisplayPolicy.row(
            for: line, generatedRomanization: nil, mode: .belowOriginal, translatedText: translation?.text
        )
        #expect(row.companions == ["ha na", "第一行"])
        let reading = LyricRomanizationDisplayPolicy.row(for: line, generatedRomanization: nil, mode: .romanizationOnly)
        #expect(reading.text == "ha na")
        #expect(reading.line.syllables?.map(\.start) == [2.1, 2.3])
        #expect(reading.line.syllables?.map(\.end) == [2.3, 2.9])
        let backing = try #require(line.background?.first)
        #expect(backing.text == "호")
        #expect(backing.manualTranslation?.text == "和声")
        #expect(backing.romanization == "ho")
        #expect(backing.romanizationSyllables?.first?.start == 2.5)
        let hidden = LyricBundledTranslationPolicy.presentation(of: lines, showsBundledTranslations: false)
        #expect(hidden.hasBundledTranslations)
        #expect(hidden.lines[0].allManualTranslations.isEmpty)
        #expect(hidden.lines[0].romanization == "ha na")
        #expect(lines[1].manualTranslation?.text == "第二行")
        #expect(lines[1].romanization == "dul")
        #expect(lines[1].romanizationSyllables == nil)
        #expect(lines[2].manualTranslation == nil && lines[2].romanization == nil)
    }

    @Test("Authored annotation timing survives cache, editing and TTML writeback")
    func preservesAppleTTMLHeadTiming() throws {
        let lines = LyricsContentParser.parseText(keyedAppleTTML)
        let cached = try JSONDecoder().decode([LyricLine].self, from: JSONEncoder().encode(lines))
        #expect(cached == lines)
        var editor = LyricsEditorDocument(lyricLines: cached)
        let saved = LyricsContentParser.parseText(LyricsContentParser.serializeTTML(editor.lyricLines()))
        #expect(LyricsContentParser.areSemanticallyEquivalent(saved, lines))
        let shifted = try #require(editor.shifted(by: 1).lyricLines().first)
        #expect(shifted.manualTranslation?.syllables?.map(\.start) == [3, 3.4])
        #expect(shifted.romanizationSyllables?.map(\.start) == [3.1, 3.3])
        #expect(shifted.background?.first?.romanizationSyllables?.first?.start == 3.5)
        let playbackOffset = try #require(LyricDocumentOffsetPolicy.applying(offset: 1, to: lines).first)
        #expect(playbackOffset.romanizationSyllables?.map(\.start) == [1.1, 1.3])
        #expect(playbackOffset.manualTranslation?.syllables?.map(\.start) == [1, 1.4])
        var retimed = lines
        retimed[0].romanizationSyllables?[0].start = 2.01
        #expect(LyricsDocumentFingerprint(lines: retimed) != LyricsDocumentFingerprint(lines: lines))
        #expect(!LyricsContentParser.areSemanticallyEquivalent(retimed, lines))
        editor.updateRomanization("hana", at: 0)
        editor.updateManualTranslation("改译", at: 0)
        let edited = try #require(editor.lyricLines().first)
        #expect(edited.romanizationSyllables == nil && edited.manualTranslation?.syllables == nil)
        #expect(edited.syllables == lines[0].syllables)
    }

    @Test("A romanization survives the cache encoding")
    func keepsRomanizationAcrossCacheEncoding() throws {
        let line = LyricLine(
            timestamp: 1,
            text: "君と歩く",
            romanization: "kimi to aruku"
        )
        let data = try JSONEncoder().encode([line])
        let decoded = try JSONDecoder().decode([LyricLine].self, from: data)

        #expect(decoded.first?.romanization == "kimi to aruku")
        // Caches written before the field existed keep decoding.
        let legacy = Data(#"[{"timestamp":1,"text":"君と歩く","isSynchronized":true}]"#.utf8)
        #expect(try JSONDecoder().decode([LyricLine].self, from: legacy).first?.romanization == nil)
    }

    @Test("An LRC offset header moves the timeline and is applied only once")
    func appliesLRCOffsetHeader() throws {
        let content = """
        [ti:Demo]
        [offset:+500]
        [00:10.00]First line
        [00:12.00]<00:12.00>Second <00:12.50>line
        """

        let parsed = LyricsContentParser.parseText(content)
        #expect(parsed.count == 2)
        #expect(parsed[0].timestamp == 9.5)
        #expect(parsed[1].syllables?.map(\.start) == [11.5, 12])
        // The tag is consumed, so re-reading a saved document cannot shift twice.
        #expect(parsed[0].metadataLines == ["[ti:Demo]"])
        let roundTrip = LyricsContentParser.parseText(LyricsContentParser.serialize(parsed))
        #expect(roundTrip.first?.timestamp == 9.5)
    }

    @Test("A negative LRC offset delays the timeline")
    func appliesNegativeLRCOffsetHeader() throws {
        let parsed = LyricsContentParser.parseText("[offset:-1200]\n[00:10.00]First line")
        #expect(parsed.first?.timestamp == 11.2)
        #expect(parsed.first?.metadataLines == nil)
    }

    @Test("An LRC offset never moves a line before the start of the track")
    func clampsLRCOffsetAtZero() throws {
        let parsed = LyricsContentParser.parseText("[offset:+20000]\n[00:10.00]First\n[00:30.00]Second")
        #expect(parsed.map(\.timestamp) == [0, 10])
    }

    @Test("Unusable LRC offset headers leave the document untouched", arguments: [
        "[offset:0]", "[offset:abc]", "[offset:99999999]", "[offset:]",
    ])
    func ignoresUnusableLRCOffsetHeaders(_ header: String) throws {
        let parsed = LyricsContentParser.parseText("\(header)\n[00:10.00]First line")
        #expect(parsed.first?.timestamp == 10)
        #expect(parsed.first?.metadataLines == [header])
    }

    private let issue125TTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml"
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
        itunes:timing="Word" xml:lang="en">
      <body>
        <div>
          <p begin="00:00:46.000" end="00:00:49.000" ttm:agent="v1">
            <span begin="00:00:46.000" end="00:00:46.400">'Cause</span>
            <span begin="00:00:46.400" end="00:00:46.800"> my</span>
            <span begin="00:00:46.800" end="00:00:47.400"> heart</span>
            <span ttm:role="x-bg" begin="00:00:44.000" end="00:00:45.200">
              <span begin="00:00:44.000" end="00:00:44.600">belongs</span>
              <span begin="00:00:44.600" end="00:00:45.200"> to you</span>
              <span ttm:role="x-translation" xml:lang="fa">به تو</span>
            </span>
            <span ttm:role="x-translation" xml:lang="fa">قلب من</span>
            <span ttm:role="x-roman">'Cause my heart</span>
          </p>
        </div>
      </body>
    </tt>
    """

    @Test("Issue 125 keeps backing vocals and translations off the sung line")
    func parsesRoleTaggedTTMLSpans() throws {
        let line = try #require(LyricsContentParser.parse(issue125TTML).first)

        #expect(line.text == "'Cause my heart")
        #expect(line.syllables?.map(\.text) == ["'Cause", " my", " heart"])
        #expect(line.syllables?.map(\.start) == [46, 46.4, 46.8])
        #expect(line.manualTranslation?.text == "قلب من")
        #expect(line.manualTranslation?.languageCode == "fa")

        let background = try #require(line.background?.first)
        #expect(background.voice == .secondary)
        #expect(background.text == "belongs to you")
        #expect(background.timestamp == 44)
        #expect(background.endTimestamp == 45.2)
        #expect(background.syllables?.map(\.start) == [44, 44.6])
        #expect(background.manualTranslation?.text == "به تو")
    }

    @Test("Issue 125 word highlighting never runs backwards inside one row")
    func keepsRoleTaggedRowsMonotonic() throws {
        let line = try #require(LyricsContentParser.parse(issue125TTML).first)
        let syllables = try #require(line.syllables)

        // Every rendered syllable of a row must finish in reading order;
        // an inlined backing group used to light up the tail of the row first.
        let ends = syllables.map {
            LyricSyllablePlaybackTimingPolicy.effectiveEnd(for: $0)
        }
        #expect(ends == ends.sorted())
        #expect(syllables.allSatisfy { !$0.text.contains("belongs") })
        #expect(syllables.allSatisfy { !$0.text.contains("قلب") })
    }

    @Test("Issue 125 roles survive a TTML round-trip")
    func preservesRoleTaggedSpansAcrossSerialization() throws {
        let parsed = LyricsContentParser.parse(issue125TTML)
        let serialized = LyricsContentParser.serializeTTML(parsed)
        #expect(serialized.contains("ttm:role=\"x-bg\""))
        #expect(serialized.contains("ttm:role=\"x-translation\""))

        let roundTrip = try #require(LyricsContentParser.parse(serialized).first)
        #expect(roundTrip.text == "'Cause my heart")
        #expect(roundTrip.syllables?.map(\.text) == ["'Cause", " my", " heart"])
        #expect(roundTrip.manualTranslation?.text == "قلب من")
        #expect(roundTrip.background?.first?.text == "belongs to you")
        #expect(roundTrip.background?.first?.syllables?.map(\.start) == [44, 44.6])
        #expect(roundTrip.background?.first?.manualTranslation?.text == "به تو")
    }

    @Test("A backing-only TTML paragraph keeps its words")
    func keepsBackingOnlyParagraphs() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="1s" end="3s"><span begin="1s" end="3s">Lead line</span></p>
            <p begin="4s" end="5s"><span ttm:role="x-bg" begin="4s" end="5s">(Ooh)</span></p>
          </div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        #expect(parsed.count == 2)
        #expect(parsed[1].text == "(Ooh)")
        #expect(parsed[1].voice == .secondary)
        #expect(parsed[1].timestamp == 4)
        #expect(LyricsContentParser.parseText(LyricsContentParser.serializeTTML(parsed)).last?.isBackingVocal == true)
    }

    @Test("A line-level TTML paragraph keeps its text next to a translation")
    func keepsLineLevelTextWithTranslation() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="1s" end="3s">Hello world<span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span></p>
          </div></body>
        </tt>
        """

        let parsed = LyricsContentParser.parse(content)
        let line = try #require(parsed.first)
        #expect(line.text == "Hello world")
        #expect(!line.isWordLevel)
        #expect(line.manualTranslation?.text == "你好世界")

        let roundTrip = try #require(
            LyricsContentParser.parse(LyricsContentParser.serializeTTML(parsed)).first
        )
        #expect(roundTrip.text == "Hello world")
        #expect(roundTrip.manualTranslation?.text == "你好世界")
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

    @Test("Overlapping TTML agents stay on their own rows and keep independent word timelines")
    func keepsStructuredOverlappingVoicesApart() throws {
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
              <span begin="11.5s" end="12.2s">Partner </span>
              <span begin="12.2s" end="13.5s">voice</span>
            </p>
            <p begin="14s" end="16s" ttm:agent="v1">Next line</p>
          </div></body>
        </tt>
        """

        let lines = LyricsContentParser.parse(content)

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.background == nil })
        #expect(lines.map(\.voice) == [.primary, .secondary, .primary])
        #expect(lines[1].timestamp == 11.5)
        #expect(lines[1].endTimestamp == 13.5)
        #expect(lines[1].syllables?.map(\.start) == [11.5, 12.2])
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lines, at: 12.5)?.rows == [0, 1])
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lines, at: 12.5)?.anchor == 0)
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lines, at: 14.5)?.rows == [2])

        let roundTrip = LyricsContentParser.parse(LyricsContentParser.serializeTTML(lines))
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, roundTrip))
    }

    @Test("TTML x-bg backing vocals still nest under their lead line")
    func keepsBackingVocalsNested() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <head><metadata>
            <ttm:agent xml:id="v1" type="person"/>
            <ttm:agent xml:id="v2" type="person"/>
          </metadata></head>
          <body><div>
            <p begin="10s" end="14s" ttm:agent="v1">
              <span begin="10s" end="12s">Lead</span>
              <span ttm:role="x-bg" begin="12s" end="15s">
                <span begin="12s" end="15s">(echo)</span>
              </span>
            </p>
            <p begin="20s" end="22s" ttm:agent="v2">Partner</p>
          </div></body>
        </tt>
        """

        let lines = LyricsContentParser.parse(content)
        let backing = try #require(lines.first?.background?.first)

        #expect(lines.count == 2)
        #expect(backing.voice == .secondary)
        #expect(backing.isBackingVocal)
        #expect(LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: lines) == lines)

        let cached = try JSONDecoder().decode([LyricLine].self, from: JSONEncoder().encode(lines))
        #expect(cached == lines)
        #expect(LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: cached) == cached)
    }

    @Test("Legacy line-level voice caches stay sequential rows")
    func keepsLegacyLineLevelVoiceCacheSequential() throws {
        let cached = [
            LyricLine(timestamp: 10, text: "Lead", voice: .primary),
            LyricLine(timestamp: 11, text: "Partner", voice: .secondary),
            LyricLine(timestamp: 14, text: "Next", voice: .primary),
        ]

        #expect(LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: cached) == cached)
        // Without written line ends nobody is known to still be singing.
        #expect(LyricConcurrentVoicePolicy.activeRows(in: cached, at: 12)?.rows == [1])
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

    @Test("Escaped entities in LRC rows are decoded once")
    func decodesEscapedEntitiesInLRC() {
        let lines = LyricsContentParser.parseText("""
        [00:01.00]You gotta fold&apos;em on the table
        [00:02.00]Rock &amp; Roll &#39;n&#x27; &quot;soul&quot;
        [00:03.00]Literal &amp;apos; stays &unknown; &
        """)

        #expect(lines.map(\.text) == [
            "You gotta fold'em on the table",
            "Rock & Roll 'n' \"soul\"",
            "Literal &apos; stays &unknown; &",
        ])
    }

    @Test("Plain text lyrics decode escaped apostrophes")
    func decodesEscapedEntitiesInPlainText() {
        let lines = LyricsContentParser.parseText("There&apos;s a picture\nIn her pocket")
        #expect(lines.map(\.text) == ["There's a picture", "In her pocket"])
    }

    @Test("Cached lines decode word and translation text")
    func decodesEntitiesInStoredLine() {
        let line = LyricLine(
            timestamp: 1,
            text: "It&apos;s",
            syllables: [LyricSyllable(text: "It&apos;s", start: 1, end: 2)],
            manualTranslation: LyricManualTranslation(text: "&quot;是&quot;", source: .embeddedField)
        )
        let decoded = LyricTextEntityPolicy.decoded(line)
        #expect(decoded.text == "It's")
        #expect(decoded.syllables?.first?.text == "It's")
        #expect(decoded.manualTranslation?.text == "\"是\"")
    }

    @Test("LyricsFileConverter detects every supported source format")
    func detectsAllSupportedSourceFormats() {
        let qrcEnvelope = #"<QrcInfos><LyricInfo><Lyric_1 LyricType="1" LyricContent="[1000,1000]Hello(1000,500) world(1500,500)"/></LyricInfo></QrcInfos>"#
        let krc = "[1000,1000]<0,500,0>Hi <500,500,0>there"
        let yrc = "[1000,1000](1000,500,0)Hi (1500,500,0)there"
        let lys = "[0]Hi (1000,500)there(1500,500)"
        let lyl = "[type:LyricifyLines]\n[1000,2000]Hello world"
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello"
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nHello"
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello"

        #expect(LyricsFileConverter.detectFormat("   \n") == .empty)
        #expect(LyricsFileConverter.detectFormat("[00:01.00]Hello") == .lrc)
        #expect(LyricsFileConverter.detectFormat("[00:01.00]<00:01.00>Hello <00:01.50>world") == .elrc)
        #expect(LyricsFileConverter.detectFormat(keyedAppleTTML) == .ttml)
        #expect(LyricsFileConverter.detectFormat(lys) == .lys)
        #expect(LyricsFileConverter.detectFormat(yrc) == .yrc)
        #expect(LyricsFileConverter.detectFormat("[1000,1000]Hi(1000,500) there(1500,500)") == .qrc)
        #expect(LyricsFileConverter.detectFormat(qrcEnvelope) == .qrc)
        #expect(LyricsFileConverter.detectFormat(krc) == .krc)
        #expect(LyricsFileConverter.detectFormat(lyl) == .lyl)
        #expect(LyricsFileConverter.detectFormat(vtt) == .webVTT)
        #expect(LyricsFileConverter.detectFormat(srt) == .subRip)
        #expect(LyricsFileConverter.detectFormat(ass) == .substationAlpha)
        #expect(LyricsFileConverter.detectFormat("Plain line one\nPlain line two") == .plain)
        #expect(LyricsFileConverter.detectFormat("<tt><body><p begin=\"1s\">Broken</body></tt>") == .invalid)
        #expect(LyricsFileConverter.detectFormat("<QrcInfos><Lyric_1 LyricContent=\"\"/></QrcInfos>") == .invalid)

        #expect(LyricsFormat.detect(lyl) == .lineLevel)
    }

    @Test("LyricsFileConverter converts KRC, YRC, QRC, LYS, LYL and subtitles cleanly")
    func convertsAllSupportedFormatsAcrossTargets() throws {
        let languageJSON = #"{"content":[{"language":0,"type":1,"lyricContent":[["你好世界"]]},{"language":0,"type":0,"lyricContent":[["ni ","hao "]]}],"version":1}"#
        let krc = "[language:\(Data(languageJSON.utf8).base64EncodedString())]\n[1000,1000]<0,400,0>你<400,600,0>好"

        let krcToTTML = try LyricsFileConverter.convert(krc, to: .ttml)
        #expect(krcToTTML.detectedFormat == .krc)
        #expect(!krcToTTML.flattensVoices)
        #expect(!krcToTTML.dropsCompanionWordTiming)
        #expect(krcToTTML.output.contains("ttm:role=\"x-roman\""))
        #expect(krcToTTML.output.contains("ttm:role=\"x-translation\""))
        #expect(krcToTTML.output.contains("end=\"00:00:02.000\""))
        let reparsedKRC = try #require(LyricsContentParser.parseText(krcToTTML.output).first)
        #expect(reparsedKRC.romanization == "ni hao")
        #expect(reparsedKRC.romanizationSyllables?.map(\.text) == ["ni ", "hao"])
        #expect(reparsedKRC.romanizationSyllables?.map(\.start) == [1.0, 1.4])
        #expect(reparsedKRC.manualTranslation?.text == "你好世界")

        let krcToLRC = try LyricsFileConverter.convert(krc, to: .lrc)
        #expect(krcToLRC.dropsCompanionWordTiming)
        #expect(krcToLRC.output.contains("[00:01.000]ni hao"))
        #expect(krcToLRC.output.contains("[00:01.000]你好世界"))

        let krcToSRT = try LyricsFileConverter.convert(krc, to: .srt)
        #expect(krcToSRT.output.contains("00:00:01,000 --> 00:00:02,000\n你好\nni hao\n你好世界"))

        let qrcXML = #"<QrcInfos><LyricInfo><Lyric_1 LyricType="1" LyricContent="[1000,1000]It&apos;s(1000,500) fine(1500,500)"/></LyricInfo></QrcInfos>"#
        let qrcToTTML = try LyricsFileConverter.convert(qrcXML, to: .ttml)
        #expect(qrcToTTML.detectedFormat == .qrc)
        #expect(LyricsContentParser.parseText(qrcToTTML.output).first?.text == "It's fine")

        let yrc = "[1000,1000](1000,500,0)Hello (1500,500,0)world"
        let yrcToSRT = try LyricsFileConverter.convert(yrc, to: .srt)
        #expect(yrcToSRT.detectedFormat == .yrc)
        #expect(yrcToSRT.output.contains("00:00:01,000 --> 00:00:02,000\nHello world"))

        let elrc = "[00:01.00]<00:01.00>Hello <00:01.50>world<00:02.00>"
        let elrcToTTML = try LyricsFileConverter.convert(elrc, to: .ttml)
        #expect(elrcToTTML.detectedFormat == .elrc)
        #expect(elrcToTTML.output.contains("end=\"00:00:02.000\""))

        let lys = "[1]Lead(1000,1000)\n[7](echo)(1200,800)"
        let lysToTTML = try LyricsFileConverter.convert(lys, to: .ttml)
        #expect(lysToTTML.detectedFormat == .lys)
        #expect(!lysToTTML.flattensVoices)
        #expect(lysToTTML.output.contains("ttm:role=\"x-bg\""))
        let lysToLRC = try LyricsFileConverter.convert(lys, to: .lrc)
        #expect(lysToLRC.flattensVoices)

        let lyl = "[type:LyricifyLines]\n[1000,3000]First line\n[4000,6000]Second line"
        let lylToSRT = try LyricsFileConverter.convert(lyl, to: .srt)
        #expect(lylToSRT.detectedFormat == .lyl)
        #expect(lylToSRT.output.contains("00:00:01,000 --> 00:00:04,000\nFirst line"))

        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nSubtitle line"
        let vttToTTML = try LyricsFileConverter.convert(vtt, to: .ttml)
        #expect(vttToTTML.detectedFormat == .webVTT)
        #expect(vttToTTML.output.contains("begin=\"00:00:01.000\" end=\"00:00:02.500\""))
    }

    @Test("TTML to TTML preserves nested backing vocals and companion word timing")
    func ttmlToTTMLPreservesStructureAndCompanionTiming() throws {
        let converted = try LyricsFileConverter.convert(keyedAppleTTML, to: .ttml)
        #expect(converted.detectedFormat == .ttml)
        #expect(!converted.flattensVoices)
        #expect(!converted.dropsCompanionWordTiming)
        #expect(converted.output.contains("ttm:role=\"x-bg\""))

        let reparsed = LyricsContentParser.parseText(converted.output)
        let first = try #require(reparsed.first)
        #expect(first.background?.first?.text == "호")
        #expect(first.romanizationSyllables?.map(\.start) == [2.1, 2.3])
        #expect(first.manualTranslation?.syllables?.map(\.start) == [2.0, 2.4])
        #expect(first.alternateManualTranslations.map(\.text) == ["First line"])

        let toLRC = try LyricsFileConverter.convert(keyedAppleTTML, to: .lrc)
        #expect(toLRC.flattensVoices)
        #expect(toLRC.dropsCompanionWordTiming)
        #expect(toLRC.output.contains("ha na"))
        #expect(toLRC.output.contains("第一行"))
        #expect(toLRC.output.contains("First line"))
    }

    @Test("Bilingual LRC reading rows are promoted to x-roman when exporting to TTML")
    func promotesBilingualLRCReadingRowsInTTML() throws {
        let content = """
        [00:01.00]夢の中で
        [00:01.00]yume no naka de
        [00:01.00]在梦境之中
        [00:05.00]君の声
        [00:05.00]kimi no koe
        [00:05.00]你的声音
        [00:09.00]星が降る
        [00:09.00]hoshi ga furu
        [00:09.00]繁星飘落
        [00:13.00]風が吹く
        [00:13.00]kaze ga fuku
        [00:13.00]微风轻拂
        [00:17.00]空を見る
        [00:17.00]sora wo miru
        [00:17.00]仰望天空
        [00:21.00]夜が明ける
        [00:21.00]yoru ga akeru
        [00:21.00]天色破晓
        """
        let converted = try LyricsFileConverter.convert(content, to: .ttml)
        #expect(converted.output.contains("ttm:role=\"x-roman\">yume no naka de</span>"))
        #expect(converted.output.contains("ttm:role=\"x-translation\">在梦境之中</span>"))
        let reparsed = LyricsContentParser.parseText(converted.output)
        #expect(reparsed.prefix(3).map(\.romanization) == ["yume no naka de", "kimi no koe", "hoshi ga furu"])
        #expect(reparsed.prefix(3).map { $0.manualTranslation?.text } == ["在梦境之中", "你的声音", "繁星飘落"])
    }

    @Test("Converter rejects untimed SRT, malformed QRC XML, encrypted KRC, and binary files")
    func handlesConverterEdgeCasesAndDecodeErrors() throws {
        #expect(throws: LyricsFileConversionError.requiresTiming) {
            try LyricsFileConverter.convert("Line one\nLine two", to: .srt)
        }
        let untimedTTML = try LyricsFileConverter.convert("Line one\nLine two", to: .ttml)
        #expect(untimedTTML.detectedFormat == .plain)
        #expect(untimedTTML.output.contains(">Line one</p>"))
        #expect(!untimedTTML.output.contains("begin="))

        #expect(throws: LyricsFileConversionError.invalidContent) {
            try LyricsFileConverter.convert("<QrcInfos><Lyric_1 LyricContent=\"\"/></QrcInfos>", to: .lrc)
        }

        // UTF-8 BOM
        let bomUTF8 = Data([0xEF, 0xBB, 0xBF]) + Data("[00:01.00]你好".utf8)
        #expect(try LyricsFileConverter.decodeText(from: bomUTF8) == "[00:01.00]你好")

        // UTF-16LE with BOM
        let utf16LE = try #require("[00:01.00]Hello".data(using: .utf16LittleEndian))
        #expect(try LyricsFileConverter.decodeText(from: Data([0xFF, 0xFE]) + utf16LE) == "[00:01.00]Hello")

        // GB18030
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let gbData = try #require("[00:01.00]粤语测试".data(using: gbEncoding))
        #expect(try LyricsFileConverter.decodeText(from: gbData) == "[00:01.00]粤语测试")

        // Encrypted KRC
        let encryptedKRC = Data([0x6B, 0x72, 0x63, 0x31, 0x40, 0x47, 0x61, 0x77])
        #expect(throws: LyricsFileDecodeError.encryptedKRC) {
            try LyricsFileConverter.decodeText(from: encryptedKRC)
        }

        // Binary PNG header & raw NUL payload
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
        #expect(throws: LyricsFileDecodeError.binaryOrUnreadable) {
            try LyricsFileConverter.decodeText(from: pngData)
        }

        // Empty & oversized
        #expect(throws: LyricsFileDecodeError.emptyFile) {
            try LyricsFileConverter.decodeText(from: Data())
        }
        #expect(throws: LyricsFileDecodeError.tooLarge) {
            try LyricsFileConverter.decodeText(from: Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1))
        }
    }
}
