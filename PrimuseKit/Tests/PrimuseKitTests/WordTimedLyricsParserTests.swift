import Foundation
import Testing
@testable import PrimuseKit

@Suite("Word-timed lyric formats")
struct WordTimedLyricsParserTests {
    private let lysDocument = """
    [0]Softly (358,1336)we've (1694,487)sailed(2181,673)
    [4]Drifting (5245,696)past (5941,471)the (6412,306)docks(6718,458)
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
        #expect(lines[0].text == "Softly we've sailed")
        #expect(lines[0].timestamp == 0.358)
        #expect(lines[0].syllables?.map(\.text) == ["Softly ", "we've ", "sailed"])
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
        #expect(PrimuseConstants.readableLyricsExtensions.contains("lyl"))
        #expect(!PrimuseConstants.supportedLyricsExtensions.contains("lys"))
        #expect(!PrimuseConstants.supportedLyricsExtensions.contains("lyl"))
        // `.lrc` keeps priority so an edited document wins over a source file.
        #expect(PrimuseConstants.readableLyricsExtensions.first == "lrc")
    }

    // MARK: - Relative word documents

    private let krcDocument = """
    \u{FEFF}[id:$00000000]
    [ar:Someone]
    [ti:Demo]
    [hash:0123abcd]
    [qq:]
    [total:12000]
    [1000,1500]<0,500,0>Light <500,400,0>on <900,600,0>water
    [3000,1000]<0,300,0>(Ooh <300,700,0>yeah)
    [5000,900]<0,300,0>Hold<300,100,0> <400,500,0>on
    """

    @Test("Relative word documents are told apart from the other formats")
    func detectsRelativeWordDocuments() {
        #expect(WordTimedLyricsParser.detect(krcDocument) == .krc)
        #expect(LyricsFormat.detect(krcDocument) == .wordLevel)
        #expect(WordTimedLyricsParser.detect(yrcDocument) == .yrc)
        #expect(WordTimedLyricsParser.detect(qrcDocument) == .qrc)
        #expect(WordTimedLyricsParser.detect(lysDocument) == .lys)
        #expect(WordTimedLyricsParser.detect(
            "[00:01.00]<00:01.00>Light <00:01.50>on"
        ) == nil)
        // A lone relative row inside an LRC document stays with the LRC reader.
        #expect(WordTimedLyricsParser.detect("""
        [00:00.000]Intro
        [00:01.000]First
        [5000,1000]<0,500,0>Hello <500,500,0>world
        """) == nil)
    }

    @Test("Relative word offsets count from the line start")
    func parsesRelativeWordDocument() throws {
        let lines = LyricsContentParser.parseText(krcDocument)

        #expect(lines.map(\.text) == ["Light on water", "Hold on"])
        #expect(lines[0].timestamp == 1)
        #expect(lines[0].syllables?.map(\.text) == ["Light ", "on ", "water"])
        #expect(lines[0].syllables?.map(\.start) == [1, 1.5, 1.9])
        #expect(lines[0].syllables?.map(\.end) == [1.5, 1.9, 2.5])
        #expect(lines[0].syllables?.allSatisfy { $0.endTiming == .explicit } == true)
        #expect(lines[0].endTimestamp == 2.5)
        // The byte-order mark does not hide the first header.
        #expect(lines[0].metadataLines?.first == "[id:$00000000]")
        #expect(lines[0].metadataLines?.contains("[ti:Demo]") == true)

        let background = try #require(lines[0].background?.first)
        #expect(background.text == "Ooh yeah")
        #expect(background.syllables?.map(\.start) == [3, 3.3])

        // A whitespace-only word joins the word before it.
        #expect(lines[1].syllables?.map(\.text) == ["Hold ", "on"])
        #expect(lines[1].syllables?.map(\.start) == [5, 5.4])
    }

    @Test("Rows written out of time order are read in time order")
    func ordersRelativeRowsByTime() {
        let lines = LyricsContentParser.parseText("""
        [ti:Demo]
        [400,600]<0,600,0>Title
        [200,100]<0,100,0>Credit
        [1000,500]<0,500,0>First
        """)
        #expect(lines.map(\.text) == ["Credit", "Title", "First"])
        #expect(lines.first?.metadataLines == ["[ti:Demo]"])
    }

    @Test("A relative line window far past its last word is not trusted")
    func ignoresDamagedRelativeLineWindow() throws {
        let line = try #require(LyricsContentParser.parseText(
            "[10000,1000]<0,500,0>Light\n[20000,250000]<0,400,0>End <400,400,0>line"
        ).last)
        #expect(line.endTimestamp == 20.8)
    }

    @Test("Relative words keep an offset header, empty words and stray markup out")
    func cleansRelativeWords() throws {
        let lines = LyricsContentParser.parseText("""
        [offset:+500]
        [1000,1000]<0,0,0><0,300,0>Light<b> <300,300,0>on</b><600,0,0>
        [3000,500]<0,500,0>I <3 you
        """)
        #expect(lines.first?.text == "Light on")
        #expect(lines.first?.syllables?.map(\.text) == ["Light ", "on"])
        #expect(lines.first?.syllables?.first?.start == 0.5)
        #expect(lines.first?.metadataLines == nil)
        #expect(lines.last?.text == "I <3 you")
    }

    private func languageTag(_ json: String) -> String {
        "[language:\(Data(json.utf8).base64EncodedString())]"
    }

    private let krcBody = """
    [1000,1000]<0,500,0>Light <500,500,0>on
    [3000,1000]<0,500,0>Second <500,500,0>row
    [5000,1000]<0,1000,0>Third
    """

    @Test("The language block adds a translation and a romanization per row")
    func readsLanguageBlock() throws {
        let tag = languageTag(
            #"{"content":[{"language":0,"type":1,"lyricContent":[["第一行"],["//"],["  "]]},"#
                + #"{"language":0,"type":0,"lyricContent":[["rai ","to "],["se ","kon "],["sa  ","do "]]}],"version":1}"#
        )
        let lines = LyricsContentParser.parseText("[ti:Demo]\n\(tag)\n\(krcBody)")

        #expect(lines.count == 3)
        #expect(lines[0].manualTranslation?.text == "第一行")
        #expect(lines[0].manualTranslation?.source == .embeddedField)
        // `//` and blank rows mean no translation.
        #expect(lines[1].manualTranslation == nil)
        #expect(lines[2].manualTranslation == nil)
        #expect(lines.map(\.romanization) == ["rai to", "se kon", "sa do"])
        // The block is read once and does not travel on as a header.
        #expect(lines[0].metadataLines == ["[ti:Demo]"])
    }

    @Test("A translation-only block skips rows that carry no words")
    func linesUpLanguageRowsWithoutEmptyLyricRows() throws {
        let tag = languageTag(#"{"content":[{"type":1,"lyricContent":[["一"],["二"],["三"]]}],"version":1}"#)
        let lines = LyricsContentParser.parseText("""
        \(tag)
        [1000,1000]<0,500,0>Light
        [2000,500]
        [3000,1000]<0,500,0>Second <500,500,0>row
        [5000,1000]<0,1000,0>Third
        """)
        #expect(lines.map(\.text) == ["Light", "Second row", "Third"])
        #expect(lines.map { $0.manualTranslation?.text } == ["一", "二", "三"])
        #expect(lines.allSatisfy { $0.romanization == nil })
    }

    @Test("A language block that cannot be used leaves the lyrics as they are", arguments: [
        #"{"content":[{"type":1,"lyricContent":[["一"],["二"]]}],"version":1}"#,
        #"{"content":"#,
        #"not json"#,
    ])
    func dropsUnusableLanguageBlock(_ json: String) throws {
        let lines = LyricsContentParser.parseText("\(languageTag(json))\n\(krcBody)")
        #expect(lines.map(\.text) == ["Light on", "Second row", "Third"])
        #expect(lines.allSatisfy { $0.manualTranslation == nil && $0.romanization == nil })
        #expect(lines.allSatisfy { $0.isWordLevel })
    }

    @Test("A language tag that is not base64 is ignored")
    func ignoresMalformedLanguageTag() {
        let lines = LyricsContentParser.parseText("[language:@@@ not base64 @@@]\n\(krcBody)")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
    }
}
