import Foundation
import Testing
@testable import PrimuseKit

@Suite("Word-timed lyric formats")
struct WordTimedLyricsParserTests {
    private let lysDocument = """
    [0]Lately (358,1336)I've (1694,487)been(2181,673)
    [4]Dreaming (5245,696)about (5941,471)the (6412,306)things(6718,458)
    [8](Could (9245,300)be)(9545,400)
    [5]Take (10000,500)it(10500,400)
    """

    private let qrcDocument = """
    [ti:Demo]
    [190871,1984]For (190871,361)the (191232,172)first (191404,376)time(191780,1075)
    [193459,4198](What's (193459,412)past)(193871,574)
    """

    private let yrcDocument = """
    {"t":0,"c":[{"tx":"作词: 某人"}]}
    [190871,1984](190871,361,0)For (191232,172,0)the (191404,376,0)first (191780,1075,0)time
    [193459,1000](193459,412,0)Again
    """

    @Test("Each word-timed format is recognized from its content")
    func detectsFormats() throws {
        #expect(WordTimedLyricsParser.detect(lysDocument) == .lys)
        #expect(WordTimedLyricsParser.detect(qrcDocument) == .qrc)
        #expect(WordTimedLyricsParser.detect(yrcDocument) == .yrc)
        #expect(LyricsFormat.detect(lysDocument) == .wordLevel)
        #expect(LyricsFormat.detect(qrcDocument) == .wordLevel)
        #expect(LyricsFormat.detect(yrcDocument) == .wordLevel)
    }

    @Test("LRC documents are never taken for a word-timed document")
    func leavesLRCAlone() throws {
        let elrc = "[00:10.00]First line\n[00:12.00]<00:12.00>Second <00:12.50>line"
        #expect(WordTimedLyricsParser.detect(elrc) == nil)
        #expect(WordTimedLyricsParser.detect("[00:01.000]你[00:01.500]好[00:02.000]") == nil)
        #expect(LyricsContentParser.parseText(elrc).count == 2)
    }

    @Test("LYS keeps word timing, the duet voice and the backing group")
    func parsesLYS() throws {
        let lines = LyricsContentParser.parseText(lysDocument)

        #expect(lines.count == 3)
        #expect(lines[0].text == "Lately I've been")
        #expect(lines[0].timestamp == 0.358)
        #expect(lines[0].syllables?.map(\.text) == ["Lately ", "I've ", "been"])
        #expect(lines[0].syllables?.map(\.start) == [0.358, 1.694, 2.181])
        #expect(lines[0].syllables?.map(\.end) == [1.694, 2.181, 2.854])
        #expect(lines[0].syllables?.allSatisfy { $0.endTiming == .explicit } == true)

        // Property 8 is a backing group, which belongs to the line it answers.
        let background = try #require(lines[1].background?.first)
        #expect(background.text == "Could be")
        #expect(background.voice == .secondary)
        #expect(background.timestamp == 9.245)
        #expect(background.syllables?.map(\.text) == ["Could ", "be"])

        // Property 5 is the duet voice and stays a row of its own.
        #expect(lines[2].voice == .secondary)
        #expect(lines[2].text == "Take it")
    }

    @Test("QRC keeps the line window and folds a parenthesized line into it")
    func parsesQRC() throws {
        let lines = LyricsContentParser.parseText(qrcDocument)

        #expect(lines.count == 1)
        #expect(lines[0].text == "For the first time")
        #expect(lines[0].timestamp == 190.871)
        #expect(lines[0].endTimestamp == 192.855)
        #expect(lines[0].syllables?.map(\.text) == ["For ", "the ", "first ", "time"])
        #expect(lines[0].metadataLines == ["[ti:Demo]"])

        let background = try #require(lines[0].background?.first)
        #expect(background.text == "What's past")
        #expect(background.syllables?.map(\.text) == ["What's ", "past"])
    }

    @Test("QRC is also read out of its XML envelope")
    func parsesQRCInsideXML() throws {
        let document = """
        <?xml version="1.0" encoding="utf-8"?><QrcInfos><LyricInfo LyricCount="1">\
        <Lyric_1 LyricType="1" LyricContent="[0,2000]Hello (0,500)world(500,600)&#10;\
        [2000,1000]Second (2000,400)line(2400,600)"/></LyricInfo></QrcInfos>
        """

        let lines = LyricsContentParser.parseText(document)
        #expect(lines.count == 2)
        #expect(lines.map(\.text) == ["Hello world", "Second line"])
        #expect(lines[1].syllables?.map(\.start) == [2, 2.4])
    }

    @Test("YRC reads the marker that precedes each word")
    func parsesYRC() throws {
        let lines = LyricsContentParser.parseText(yrcDocument)

        #expect(lines.count == 2)
        #expect(lines[0].text == "For the first time")
        #expect(lines[0].syllables?.map(\.text) == ["For ", "the ", "first ", "time"])
        #expect(lines[0].syllables?.map(\.start) == [190.871, 191.232, 191.404, 191.78])
        #expect(lines[0].syllables?.last?.end == 192.855)
        // The JSON credit row is document metadata, not a sung line.
        #expect(lines.allSatisfy { !$0.text.hasPrefix("{") })
    }

    @Test("Parentheses inside a line do not become word timing")
    func keepsLiteralParentheses() throws {
        let lines = LyricsContentParser.parseText("[0]Hello (world) (100,200)again(300,400)")
        let syllables = try #require(lines.first?.syllables)

        #expect(syllables.map(\.text) == ["Hello (world) ", "again"])
        #expect(syllables.map(\.start) == [0.1, 0.3])
    }

    @Test("An offset header also applies to a word-timed document")
    func appliesOffsetToWordTimedDocuments() throws {
        let lines = LyricsContentParser.parseText(
            "[offset:+500]\n[190871,1984]For (190871,361)time(191232,172)"
        )
        #expect(lines.first?.timestamp == 190.371)
        #expect(lines.first?.syllables?.first?.start == 190.371)
        #expect(lines.first?.metadataLines == nil)
    }

    @Test("Word-timed sidecars are discovered but never chosen for writeback")
    func separatesReadableAndWritableExtensions() {
        #expect(PrimuseConstants.readableLyricsExtensions.contains("lys"))
        #expect(PrimuseConstants.readableLyricsExtensions.contains("yrc"))
        #expect(PrimuseConstants.readableLyricsExtensions.contains("qrc"))
        #expect(PrimuseConstants.readableLyricsExtensions.contains("elrc"))
        #expect(!PrimuseConstants.supportedLyricsExtensions.contains("lys"))
        // `.lrc` keeps priority so an edited document wins over a source file.
        #expect(PrimuseConstants.readableLyricsExtensions.first == "lrc")
    }
}
