import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics editor document")
struct LyricsEditorDocumentTests {

    // MARK: - 解析

    @Test("Keeps unstamped lines that the playback parser drops")
    func keepsUnstampedLines() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        我还站在原地等候
        [00:24.100]云层散去以后
        """)

        #expect(document.lines.count == 3)
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[1].timestamp == nil)
        #expect(document.lines[1].text == "我还站在原地等候")
        #expect(document.lines[2].timestamp == 24.1)
        #expect(document.unstampedCount == 1)
    }

    @Test("Preserves leading metadata headers")
    func preservesMetadata() {
        let document = LyricsEditorDocument(parsing: """
        [ti:那年夏天]
        [ar:某人]
        [00:12.300]晚风吹过温柔的午后
        """)

        #expect(document.metadataLines == ["[ti:那年夏天]", "[ar:某人]"])
        #expect(document.lines.count == 1)
        #expect(document.serialized().hasPrefix("[ti:那年夏天]\n[ar:某人]\n[00:12.300]"))
    }

    @Test("Malformed timestamps survive as editable text")
    func keepsMalformedTimestampText() {
        // 秒数字段写成字母 O 而不是 0 —— 丢掉这行会让用户以为歌词被吃了。
        let document = LyricsEditorDocument(parsing: "[00:6O.100]云层散去以后")

        #expect(document.lines.count == 1)
        #expect(document.lines[0].timestamp == nil)
        #expect(document.lines[0].text == "[00:6O.100]云层散去以后")
    }

    @Test("A line carrying several heads expands into separate lines")
    func expandsRepeatedHeads() {
        let document = LyricsEditorDocument(parsing: "[00:12.300][01:40.100]副歌")

        #expect(document.lines.count == 2)
        #expect(document.lines.map(\.text) == ["副歌", "副歌"])
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[1].timestamp == 100.1)
    }

    @Test("Text round-trips through serialization")
    func roundTripsText() {
        let source = """
        [ti:那年夏天]
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """

        #expect(LyricsEditorDocument(parsing: source).serialized() == source)
    }

    @Test("Session identities do not count as lyric content changes")
    func ignoresSessionIdentitiesWhenComparingContent() {
        let first = LyricsEditorDocument(parsing: "[00:12.300]Same line")
        let second = LyricsEditorDocument(parsing: "[00:12.300]Same line")

        #expect(first.lines[0].id != second.lines[0].id)
        #expect(first.hasSameContent(as: second))
    }

    @Test("An unchanged edit preserves the original timestamp precision")
    func unchangedCommitPreservesOriginalText() {
        let source = "[00:12.30]Same line"
        let original = LyricsEditorDocument(parsing: source)
        let reopened = LyricsEditorDocument(parsing: source)

        #expect(reopened.serialized() == "[00:12.300]Same line")
        #expect(reopened.committedText(preserving: source, comparedTo: original) == source)
    }

    @Test("Word-level syllables round-trip")
    func roundTripsWordLevel() {
        let document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")

        #expect(document.lines.count == 1)
        #expect(document.lines[0].isWordLevel)
        #expect(document.lines[0].syllables?.count == 2)
        #expect(document.serialized() == "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
    }

    @Test("Serialized output stays parseable by the playback validator")
    func serializationFeedsPlaybackValidator() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        [00:24.100]云层散去以后
        """)
        document.shift(by: 1.5)

        let validation = LyricsContentParser.validateEditableText(document.serialized())
        #expect(validation.isValid)
        #expect(validation.issues.isEmpty)
        #expect(validation.lines.map(\.timestamp) == [13.8, 25.6])
    }

    // MARK: - 整体偏移

    @Test("Shifting moves every stamped line and leaves the rest alone")
    func shiftsStampedLinesOnly() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """)

        #expect(document.shift(by: 2) == 2)
        #expect(document.lines[0].timestamp == 14.3)
        #expect(document.lines[1].timestamp == nil)
        #expect(document.lines[2].timestamp == 26.1)
    }

    @Test("Backward shift clamps the whole document, never collapsing lines together")
    func backwardShiftPreservesSpacing() {
        var document = LyricsEditorDocument(parsing: """
        [00:00.500]第一句
        [00:01.000]第二句
        [00:02.000]第三句
        """)

        // 逐行 clamp 会得到 [0, 0, 1.0] —— 前两句挤在一起。整份 clamp 只把最早
        // 那句顶到 0,行距原样保留。
        #expect(document.shift(by: -1) == -0.5)
        #expect(document.lines.map(\.timestamp) == [0, 0.5, 1.5])
    }

    @Test("A clamped shift is fully reversible from the baseline")
    func clampedShiftIsReversibleFromBaseline() {
        let baseline = LyricsEditorDocument(parsing: """
        [00:00.500]第一句
        [00:01.000]第二句
        """)

        // UI 保留基线、每次从基线重算,所以拖到头再拖回来不会丢原始时间。
        let pushedToFloor = baseline.shifted(by: -30)
        #expect(pushedToFloor.lines.map(\.timestamp) == [0, 0.5])
        #expect(baseline.shifted(by: 0).lines.map(\.timestamp) == [0.5, 1.0])
    }

    @Test("Word-level syllables shift with their line")
    func shiftMovesSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.shift(by: 1)

        #expect(document.lines[0].timestamp == 13.3)
        #expect(document.lines[0].syllables?.map(\.start) == [13.3, 14.1])
        #expect(document.lines[0].syllables?.last?.end == 15.0)
    }

    @Test("Backward shift limit accounts for syllables ahead of their line head")
    func backwardLimitConsidersSyllables() {
        // 坏数据:首个音节比行头还早。下限必须按音节算,否则偏移后音节会变负。
        let document = LyricsEditorDocument(
            metadataLines: [],
            lines: [
                EditableLyricLine(
                    timestamp: 5,
                    text: "晚风",
                    syllables: [LyricSyllable(text: "晚风", start: 3, end: 6)]
                )
            ]
        )

        #expect(document.maximumBackwardShift == 3)
        #expect(document.shifted(by: -10).lines[0].syllables?.first?.start == 0)
    }

    // MARK: - 打轴

    @Test("Stamping records a time and keeps intra-line rhythm")
    func stampingShiftsSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.stamp(at: 0, time: 20)

        #expect(document.lines[0].timestamp == 20)
        // 音节按 delta 平移,浮点上取不到精确的 20.8,比到毫秒即可。
        let starts = document.lines[0].syllables?.map(\.start) ?? []
        #expect(starts.count == 2)
        #expect(abs(starts[0] - 20) < 0.001)
        #expect(abs(starts[1] - 20.8) < 0.001)
    }

    @Test("Stamping an unstamped line and clearing it again")
    func stampAndClear() {
        var document = LyricsEditorDocument(parsing: "还没打轴的一句")

        document.stamp(at: 0, time: 9.25)
        #expect(document.lines[0].timestamp == 9.25)
        #expect(document.nextUnstampedIndex == nil)

        document.clearStamp(at: 0)
        #expect(document.lines[0].timestamp == nil)
        #expect(document.nextUnstampedIndex == 0)
    }

    @Test("Editing text drops stale syllable data")
    func editingTextDropsSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.updateText("晚风吹过温柔的午后", at: 0)

        #expect(document.lines[0].syllables == nil)
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.serialized() == "[00:12.300]晚风吹过温柔的午后")
    }

    // MARK: - 顺序

    @Test("Out-of-order stamps are detected and can be sorted")
    func detectsAndFixesOutOfOrder() {
        var document = LyricsEditorDocument(parsing: """
        [00:24.100]云层散去以后
        [00:12.300]晚风吹过温柔的午后
        """)

        #expect(!document.isMonotonic)
        document.sortByTimestamp()
        #expect(document.isMonotonic)
        #expect(document.lines.map(\.text) == ["晚风吹过温柔的午后", "云层散去以后"])
    }

    @Test("Sorting keeps unstamped lines in their slots")
    func sortingKeepsUnstampedSlots() {
        var document = LyricsEditorDocument(parsing: """
        [00:24.100]云层散去以后
        还没打轴的一句
        [00:12.300]晚风吹过温柔的午后
        """)
        document.sortByTimestamp()

        // 未打轴的行没有可比的时间,留在原位;已打轴的行在自己的槽位里重排。
        #expect(document.lines.map(\.text) == [
            "晚风吹过温柔的午后",
            "还没打轴的一句",
            "云层散去以后",
        ])
        #expect(document.lines[1].timestamp == nil)
    }

    // MARK: - 高亮

    @Test("Active line tracks playback time")
    func tracksActiveLine() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """)

        #expect(document.activeLineIndex(at: 0) == nil)
        #expect(document.activeLineIndex(at: 12.3) == 0)
        #expect(document.activeLineIndex(at: 20) == 0)
        #expect(document.activeLineIndex(at: 30) == 2)
    }

    @Test("Active line follows time rather than document order")
    func tracksActiveLineInOutOfOrderDocument() {
        let document = LyricsEditorDocument(parsing: """
        [00:44.690]Future line placed first
        [00:25.920]Current line placed later
        [00:32.260]Next line
        """)

        #expect(document.activeLineIndex(at: 30) == 1)
        #expect(document.activeLineIndex(at: 40) == 2)
        #expect(document.activeLineIndex(at: 50) == 0)
    }

    @Test("Insertion and removal keep stable identities")
    func insertAndRemove() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]晚风吹过温柔的午后")
        let originalID = document.lines[0].id

        let newID = document.insertLine(at: 1, text: "新的一句")
        #expect(document.lines.count == 2)
        #expect(document.lines[1].id == newID)
        #expect(document.lines[0].id == originalID)

        document.removeLines(at: IndexSet(integer: 0))
        #expect(document.lines.map(\.id) == [newID])
    }

    @Test("Removing several lines at once drops exactly those lines")
    func removesMultipleLines() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        第四句
        """)
        document.removeLines(at: IndexSet([0, 2]))

        #expect(document.lines.map(\.text) == ["第二句", "第四句"])
    }

    @Test("Moving down uses pre-removal destination indices, like SwiftUI")
    func movesLineDown() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        """)
        // SwiftUI 的 onMove 语义:destination 用移除之前的下标表达。
        // 把第 0 行拖到下标 2 => 它落在原第二句之后。
        document.moveLines(from: IndexSet(integer: 0), to: 2)

        #expect(document.lines.map(\.text) == ["第二句", "第一句", "第三句"])
    }

    @Test("Moving up places the line before the destination")
    func movesLineUp() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        """)
        document.moveLines(from: IndexSet(integer: 2), to: 0)

        #expect(document.lines.map(\.text) == ["第三句", "第一句", "第二句"])
    }
}
