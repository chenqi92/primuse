import Foundation
import Testing
@testable import PrimuseKit

@Suite("LRC word-timing companion rows")
struct LRCWordTimingCompanionTests {
    /// The shape such files come in: headers, a blank line after every row,
    /// a `[tt]` row under each lyric and a last lyric without one.
    private let document = """
    [by:Someone]
    [offset:0]
    [ti:Demo]
    [length:12.0]
    [ar:Someone]

    [00:00.000]Demo - Someone (Live)

    [00:00.000][tt]<0,0><100,1><200,2><300,3><400,4><500,5><600,6><700,7><800,8><900,9><1000,10><1100,11><1200,12><1300,13><1400,14><1500,15><1600,16><1700,17><1800,18><1900,19><2000,20><2100,21><2100>

    [00:02.000]今天天气很好

    [00:02.000][tt]<0,0><240,1><490,2><970,3><1270,4><1470,5><1710,6><1710>

    [00:04.000]Light on the water

    [00:04.000][tt]<0,0><300,6><500,9><800,13><1200,18><1200>

    [00:06.000]最后一句
    """

    @Test("Each companion row times the line above it and never shows as a lyric")
    func timesLinesFromCompanionRows() throws {
        let lines = LyricsContentParser.parseText(document)

        #expect(lines.map(\.text) == [
            "Demo - Someone (Live)", "今天天气很好", "Light on the water", "最后一句",
        ])
        #expect(!lines.contains { $0.text.contains("[tt]") })
        #expect(lines.allSatisfy { $0.manualTranslation == nil })
        #expect(LyricsFormat.detect(document) == .wordLevel)

        // Every character of the credit row is its own piece, spaces included.
        #expect(lines[0].syllables?.count == 21)
        #expect(lines[0].syllables?.map(\.text).joined() == lines[0].text)

        let words = try #require(lines[1].syllables)
        #expect(words.map(\.text) == ["今", "天", "天", "气", "很", "好"])
        #expect(words.map(\.start) == [2, 2.24, 2.49, 2.97, 3.27, 3.47])
        #expect(words.map(\.end) == [2.24, 2.49, 2.97, 3.27, 3.47, 3.71])
        // Only the closing marker states an end, exactly as in ELRC.
        #expect(words.dropLast().allSatisfy { $0.endTiming == .inferred })
        #expect(words.last?.endTiming == .explicit)

        #expect(lines[2].syllables?.map(\.text) == ["Light ", "on ", "the ", "water"])
        #expect(lines[2].syllables?.map(\.start) == [4, 4.3, 4.5, 4.8])
        #expect(lines[2].syllables?.last?.end == 5.2)

        // The last lyric has no companion row and stays a line-level row.
        #expect(lines[3].isSynchronized)
        #expect(!lines[3].isWordLevel)
        #expect(lines[0].metadataLines?.contains("[length:12.0]") == true)
    }

    @Test("Timed lines save as ELRC that reads back the same")
    func roundTripsThroughELRC() {
        let lines = LyricsContentParser.parseText(document)
        let saved = LyricsContentParser.serialize(lines)

        #expect(!saved.contains("[tt]"))
        #expect(LyricsContentParser.areSemanticallyEquivalent(
            lines,
            LyricsContentParser.parseText(saved)
        ))
        #expect(!LyricsStructuredPersistencePolicy.requiresTTML(lines))
        #expect(LyricsContentParser.validateEditableText(document).issues.isEmpty)
    }

    @Test("The editor and the raw file check see timed words, never `[tt]` rows")
    func opensInEditorWithoutCompanionRows() throws {
        let editor = LyricsEditorDocument(parsing: document)
        #expect(!editor.lines.contains { $0.text.contains("[tt]") })
        #expect(editor.lines.map(\.text).contains("今天天气很好"))
        #expect(editor.lines.first { $0.text == "今天天气很好" }?.isWordLevel == true)
        #expect(!editor.serialized().contains("[tt]"))

        let pasted = LyricsEditorDocument().replacingOriginalSource(with: document)
        #expect(pasted.lines.count == 4)

        let validation = LyricsRawDocumentPolicy.validate(document, fileName: "song.lrc")
        #expect(validation.outcome.isValid)
        #expect(validation.unreadableLineNumbers.isEmpty)
    }

    @Test("A translation row at the same time is still paired with the lyric")
    func keepsTranslationPairing() {
        let rows = [
            ("00:01.000", "Light on the water", "<0,0><300,6><500,9><800,13><1200,18><1200>", "水面上的光"),
            ("00:03.000", "Wind in the trees", "<0,0><300,5><500,8><800,12><1200,17><1200>", "树林里的风"),
            ("00:05.000", "Rain on the roof", "<0,0><300,5><500,8><800,12><1200,16><1200>", "屋顶上的雨"),
        ]
        let content = rows.map { time, text, marks, translation in
            "[\(time)]\(text)\n[\(time)][tt]\(marks)\n[\(time)]\(translation)"
        }.joined(separator: "\n")
        let lines = LyricsContentParser.parseText(content)

        #expect(lines.map(\.text) == rows.map { $0.1 })
        #expect(lines.map { $0.manualTranslation?.text } == rows.map { $0.3 })
        #expect(lines.allSatisfy { $0.isWordLevel })
    }

    @Test("A row whose markers do not fit leaves its line untimed", arguments: [
        // Past the end of the text.
        "<0,0><100,2><200,9><200>",
        // Indices out of order.
        "<0,0><100,3><200,2><300,4><300>",
        // Times running backwards.
        "<0,0><300,1><200,2><300,4><300>",
        // Not opening the line.
        "<0,1><100,2><200,4><200>",
        // Not markers at all.
        "<abc><1,2,3>",
    ])
    func fallsBackWhenMarkersDoNotFit(_ marks: String) throws {
        let lines = LyricsContentParser.parseText("[00:01.000]今天很好\n[00:01.000][tt]\(marks)\n[00:03.000]第二句")
        #expect(lines.map(\.text) == ["今天很好", "第二句"])
        #expect(lines.allSatisfy { !$0.isWordLevel && $0.manualTranslation == nil })
        #expect(LyricsContentParser.validateEditableText(
            "[00:01.000]今天很好\n[00:01.000][tt]\(marks)"
        ).issues.isEmpty)
    }

    @Test("Repeated time tags, a row written first and an offset header all apply")
    func handlesTimeTagVariants() throws {
        let repeated = LyricsContentParser.parseText(
            "[00:01.000][00:09.000]很好\n[00:01.000][00:09.000][tt]<0,0><200,1><400,2><400>"
        )
        #expect(repeated.map(\.timestamp) == [1, 9])
        #expect(repeated.map { $0.syllables?.map(\.start) } == [[1, 1.2], [9, 9.2]])

        let companionFirst = LyricsContentParser.parseText(
            "[00:01.000][tt]<0,0><200,1><400,2><400>\n[00:01.000]很好"
        )
        #expect(companionFirst.first?.syllables?.map(\.text) == ["很", "好"])

        let shifted = LyricsContentParser.parseText(
            "[offset:+500]\n[00:01.000]很好\n[00:01.000][tt]<0,0><200,1><400,2><400>"
        )
        #expect(shifted.first?.syllables?.map(\.start) == [0.5, 0.7])
        #expect(shifted.first?.metadataLines == nil)
    }

    @Test("Marker indices may count UTF-16 units, never splitting a character")
    func readsUTF16Indices() throws {
        // `A`, a thumbs-up with a skin tone (two scalars, four UTF-16 units), `B`.
        let text = "A\u{1F44D}\u{1F3FD}B"
        let fitted = LyricsContentParser.parseText(
            "[00:01.000]\(text)\n[00:01.000][tt]<0,0><100,1><200,5><300,6><300>"
        )
        #expect(fitted.first?.syllables?.map(\.text) == ["A", "\u{1F44D}\u{1F3FD}", "B"])

        // Unit 3 sits between the two scalars of one character.
        let split = LyricsContentParser.parseText(
            "[00:01.000]\(text)\n[00:01.000][tt]<0,0><100,1><200,3><300,6><300>"
        )
        #expect(split.first?.text == text)
        #expect(split.first?.isWordLevel == false)
    }

    @Test("Only a time-tagged `[tt]` row is a companion row")
    func recognizesCompanionRows() {
        #expect(LRCWordTimingCompanion.row("[00:01.00][tt]<0,0><100,1><100>") != nil)
        #expect(LRCWordTimingCompanion.row("  [00:01.000] [TT]<0,0>") != nil)
        #expect(LRCWordTimingCompanion.row("[tt]<0,0><100,1>") == nil)
        #expect(LRCWordTimingCompanion.row("[00:01.000]The [tt] tag") == nil)
        #expect(LRCWordTimingCompanion.row("[00:01.000]Plain line") == nil)
        #expect(!LRCWordTimingCompanion.containsCompanionRows("[00:01.000]Plain line"))
        #expect(LRCWordTimingCompanion.containsCompanionRows(document))
    }
}
