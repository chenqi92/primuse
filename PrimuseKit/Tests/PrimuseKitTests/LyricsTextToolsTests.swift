import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics text tools")
struct LyricsTextToolsTests {

    // MARK: - 分行

    @Test("Existing line breaks are respected verbatim")
    func respectsExistingLineBreaks() {
        let result = LyricsTextTools.splitIntoLines("""
        第一句
        第二句
        第三句
        """)

        #expect(result.lines == ["第一句", "第二句", "第三句"])
        #expect(result.removedBlankRuns == 0)
    }

    @Test("Consecutive blank lines collapse and are counted")
    func collapsesBlankRuns() {
        let result = LyricsTextTools.splitIntoLines("""
        第一句


        第二句

        第三句
        """)

        #expect(result.lines.count == 3)
        #expect(result.removedBlankRuns == 2)
    }

    @Test("A single long run-on line is split on punctuation")
    func splitsRunOnLine() {
        // 整首歌被网页复制成一坨的典型形态：一行远超阈值且只有标点可依。
        let result = LyricsTextTools.splitIntoLines(
            "发过誓要将你赶出心头，谁料到恨你多年又碰头，坏情人眼里尽是害我犯戒的温柔，"
                + "太多愁想说却哽在寂寞未泪先流，缠绵到手又溜走。"
        )

        #expect(result.lines.count == 5)
        #expect(result.lines[0] == "发过誓要将你赶出心头，")
    }

    @Test("A line under the threshold keeps its original shape")
    func keepsShortRunOnLineIntact() {
        let line = "发过誓要将你赶出心头，谁料到恨你多年又碰头。"
        let result = LyricsTextTools.splitIntoLines(line)
        #expect(result.lines == [line])
    }

    @Test("Short lines are never split even if they carry punctuation")
    func keepsShortLinesIntact() {
        let result = LyricsTextTools.splitIntoLines("哦，我的爱")
        #expect(result.lines == ["哦，我的爱"])
    }

    // MARK: - 制作信息

    @Test("Credit lines are dropped and reported")
    func dropsCreditLines() {
        let result = LyricsTextTools.splitIntoLines("""
        作词：某某
        作曲：某某
        第一句歌词
        第二句歌词
        """)

        #expect(result.lines == ["第一句歌词", "第二句歌词"])
        #expect(result.droppedCreditLines.count == 2)
    }

    @Test("A colon deep inside a lyric line is not a credit")
    func keepsLyricsWithInlineColon() {
        #expect(!LyricsTextTools.isCreditLine("我轻声对你说：我一直都在等你回头"))
    }

    @Test("A lyric that merely starts with a credit character is kept")
    func keepsLyricStartingWithCreditCharacter() {
        #expect(!LyricsTextTools.isCreditLine("曲终人散：我还在原地"))
        #expect(LyricsTextTools.isCreditLine("曲：某某"))
    }

    @Test("English credit prefixes are recognised too")
    func recognisesEnglishCredits() {
        #expect(LyricsTextTools.isCreditLine("Lyrics by: Someone"))
        #expect(LyricsTextTools.isCreditLine("Produced by: Someone"))
    }

    @Test("A text made entirely of credits is kept rather than emptied")
    func neverReturnsEmptyResult() {
        let result = LyricsTextTools.splitIntoLines("""
        作词：某某
        作曲：某某
        """)

        #expect(result.lines.count == 2)
        #expect(result.droppedCreditLines.isEmpty)
    }

    // MARK: - 时间戳

    @Test("Timestamped text keeps its lines and skips punctuation splitting")
    func preservesTimestampedText() {
        let result = LyricsTextTools.splitIntoLines("""
        [00:12.30]发过誓要将你赶出心头，谁料到恨你多年又碰头，坏情人眼里尽是温柔
        [00:24.10]第二句
        """)

        #expect(result.lines.count == 2)
        #expect(result.lines[0].hasPrefix("[00:12.30]"))
    }

    @Test("Recognises the LRC timestamp head")
    func detectsTimestamps() {
        #expect(LyricsTextTools.hasTimestamp("[00:12.30]歌词"))
        #expect(LyricsTextTools.hasTimestamp("[01:02]歌词"))
        #expect(!LyricsTextTools.hasTimestamp("[ti:标题]"))
        #expect(!LyricsTextTools.hasTimestamp("普通一行"))
    }

    // MARK: - 去空行

    @Test("Removing blank lines reports nil when there is nothing to remove")
    func removingBlankLinesNoop() {
        #expect(LyricsTextTools.removingBlankLines("A\nB") == nil)
        #expect(LyricsTextTools.removingBlankLines("A\n\nB") == "A\nB")
    }
}
