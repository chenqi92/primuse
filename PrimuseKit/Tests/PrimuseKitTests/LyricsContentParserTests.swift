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
}
