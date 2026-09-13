import Testing
@testable import PrimuseKit

@Suite("Lyrics timing session")
struct LyricsTimingSessionTests {
    @Test("An existing timeline aligns as one undoable operation and keeps its anchor selected")
    func timelineAlignmentIsUndoable() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 0, text: "作词：作者"),
            EditableLyricLine(timestamp: 10, text: "First"),
            EditableLyricLine(timestamp: 20, text: "Second"),
            EditableLyricLine(timestamp: 35, text: "Third")
        ])
        let original = document
        var session = LyricsTimingSession(document: document, preferredIndex: 2)
        session.stamp(document: &document, time: 18, linkedLineIndices: [1, 2, 3])
        session.nudge(document: &document, by: 0.5, linkedLineIndices: [1, 2, 3])
        #expect(document.lines.map(\.timestamp) == [0, 8.5, 18.5, 33.5])
        #expect(session.cursorIndex == 2)
        let aligned = document
        session.undo(document: &document)
        #expect(document == original)
        #expect(!session.canUndo)
        session.redo(document: &document)
        #expect(document == aligned)
        #expect(session.cursorIndex == 2)
    }

    @Test("Word alignment preserves full syllable, background, translation and line-end timing")
    func wordTimelineAlignmentPreservesStructure() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(
                timestamp: 10, text: "One two",
                syllables: [
                    LyricSyllable(text: "One", start: 10, end: 11),
                    LyricSyllable(text: " two", start: 11, end: 12)
                ], endTimestamp: 13,
                background: [LyricLine(timestamp: 10.5, text: "Echo")],
                manualTranslation: LyricManualTranslation(text: "一 二", source: .localEditor)
            ),
            EditableLyricLine(timestamp: 20, text: "Next", endTimestamp: 23)
        ])
        let original = document
        var session = LyricsTimingSession(document: document, preferredIndex: 0)
        session.stampSyllable(document: &document, lineIndex: 0, syllableIndex: 1,
                              time: 15, linkedLineIndices: [0, 1])
        session.nudgeSyllable(document: &document, lineIndex: 0, syllableIndex: 1,
                              by: 0.5, linkedLineIndices: [0, 1])
        #expect(document.lines.map(\.timestamp) == [14.5, 24.5])
        #expect(document.lines[0].syllables?.map(\.start) == [14.5, 15.5])
        #expect(document.lines[0].syllables?.map(\.end) == [15.5, 16.5])
        #expect(document.lines.map(\.endTimestamp) == [17.5, 27.5])
        #expect(document.lines[0].background?.first?.timestamp == 15)
        #expect(document.lines[0].manualTranslation == original.lines[0].manualTranslation)
        let aligned = document
        session.undo(document: &document)
        #expect(document == original)
        session.redo(document: &document)
        #expect(document == aligned)
        #expect(session.affectedSyllableIndex == 1)
    }

    @Test("Clamped alignment restores exact snapshots and no-op nudges preserve redo")
    func clampedTimelineUndoRedo() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 10, text: "First"),
            EditableLyricLine(timestamp: 20, text: "Second")
        ])
        let original = document
        var session = LyricsTimingSession(document: document, preferredIndex: 1)
        session.stamp(document: &document, time: 2, linkedLineIndices: [0, 1])
        #expect(document.lines.map(\.timestamp) == [0, 10])
        session.undo(document: &document)
        #expect(document == original)
        session.nudge(document: &document, by: 0, linkedLineIndices: [0, 1])
        #expect(session.canRedo)
        session.redo(document: &document)
        #expect(document.lines.map(\.timestamp) == [0, 10])
    }

    @Test("The final stamp in an untimed pass keeps subsequent fine tuning local")
    func finalUntimedStampKeepsLocalNudge() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(text: "First"), EditableLyricLine(text: "Second")
        ])
        var session = LyricsTimingSession(document: document)
        session.stamp(document: &document, time: 10)
        session.stamp(document: &document, time: 20)
        session.nudge(document: &document, by: 0.5)
        #expect(document.lines.map(\.timestamp) == [10, 20.5])
        session.undo(document: &document)
        #expect(document.lines.map(\.timestamp) == [10, nil])
    }

    @Test("Starts at the first untimed line and advances after a stamp")
    func startsAtFirstUntimedLine() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 1, text: "First"),
            EditableLyricLine(timestamp: nil, text: "Second"),
            EditableLyricLine(timestamp: nil, text: "Third")
        ])
        var session = LyricsTimingSession(document: document)

        #expect(session.cursorIndex == 1)
        #expect(session.adjustmentIndex == 0)

        let stamped = session.stamp(document: &document, time: 4.25)

        #expect(stamped == 1)
        #expect(document.lines[1].timestamp == 4.25)
        #expect(session.cursorIndex == 2)
        #expect(session.adjustmentIndex == 1)
    }

    @Test("The last line finishes the pass instead of wrapping to the start")
    func finishesAfterLastLine() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: nil, text: "Only")
        ])
        var session = LyricsTimingSession(document: document)

        session.stamp(document: &document, time: 2)

        #expect(session.cursorIndex == nil)
        #expect(document.stampedCount == 1)
    }

    @Test("Undo and redo restore the complete previous line")
    func undoAndRedoRestoreLine() {
        let syllables = [
            LyricSyllable(text: "One", start: 2, end: 2.4),
            LyricSyllable(text: " two", start: 2.4, end: 3)
        ]
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 2, text: "One two", syllables: syllables),
            EditableLyricLine(timestamp: nil, text: "Next")
        ])
        var session = LyricsTimingSession(document: document, preferredIndex: 0)

        session.stamp(document: &document, time: 6)
        #expect(document.lines[0].timestamp == 6)
        #expect(document.lines[0].syllables?.first?.start == 6)

        session.undo(document: &document)
        #expect(document.lines[0].timestamp == 2)
        #expect(document.lines[0].syllables == syllables)
        #expect(session.cursorIndex == 0)
        #expect(session.canRedo)

        session.redo(document: &document)
        #expect(document.lines[0].timestamp == 6)
        #expect(document.lines[0].syllables?.first?.start == 6)
        #expect(session.cursorIndex == 1)
    }

    @Test("Nudging targets the latest timed line and is undoable")
    func nudgesLatestTimedLine() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 0.05, text: "First"),
            EditableLyricLine(timestamp: nil, text: "Second")
        ])
        var session = LyricsTimingSession(document: document)

        #expect(session.canNudge(in: document))
        session.nudge(document: &document, by: -0.1)
        #expect(document.lines[0].timestamp == 0)

        session.undo(document: &document)
        #expect(document.lines[0].timestamp == 0.05)
    }

    @Test("Fine tuning stays part of the same line-level undo")
    func fineTuningCoalescesWithStamp() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: nil, text: "First"),
            EditableLyricLine(timestamp: nil, text: "Second")
        ])
        var session = LyricsTimingSession(document: document)

        session.stamp(document: &document, time: 3)
        session.nudge(document: &document, by: 0.1)
        session.nudge(document: &document, by: 0.1)
        #expect(abs((document.lines[0].timestamp ?? 0) - 3.2) < 0.000_001)

        session.undo(document: &document)
        #expect(document.lines[0].timestamp == nil)
        #expect(session.cursorIndex == 0)

        session.redo(document: &document)
        #expect(abs((document.lines[0].timestamp ?? 0) - 3.2) < 0.000_001)
    }

    @Test("Reset picks a requested row and clears stale history")
    func resetClearsHistory() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: nil, text: "First"),
            EditableLyricLine(timestamp: nil, text: "Second")
        ])
        var session = LyricsTimingSession(document: document)
        session.stamp(document: &document, time: 1)

        session.reset(document: document, preferredIndex: 1)

        #expect(session.cursorIndex == 1)
        #expect(!session.canUndo)
        #expect(!session.canRedo)
    }

    @Test("Manual selection keeps timing history")
    func selectionKeepsHistory() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: nil, text: "First"),
            EditableLyricLine(timestamp: nil, text: "Second"),
            EditableLyricLine(timestamp: nil, text: "Third")
        ])
        var session = LyricsTimingSession(document: document)

        session.stamp(document: &document, time: 1)
        let didSelectThird = session.select(index: 2, document: document)
        #expect(didSelectThird)
        #expect(session.cursorIndex == 2)
        #expect(session.canUndo)

        session.undo(document: &document)
        #expect(document.lines[0].timestamp == nil)
        #expect(session.cursorIndex == 0)
    }

    @Test("Selecting a timed line makes it the fine-tuning target")
    func selectionChangesNudgeTarget() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(timestamp: 1, text: "First"),
            EditableLyricLine(timestamp: 2, text: "Second")
        ])
        var session = LyricsTimingSession(document: document, preferredIndex: 0)

        let didSelectSecond = session.select(index: 1, document: document)
        #expect(didSelectSecond)
        session.nudge(document: &document, by: 0.1)

        #expect(document.lines[0].timestamp == 1)
        #expect(document.lines[1].timestamp == 2.1)
    }

    @Test("Word-level stamping advances independently and restores complete lines")
    func wordLevelStampingIsUndoablePerSyllable() {
        let original = LyricsEditorDocument(
            parsing: "[00:01.000]<00:01.000>晚<00:02.000>风<00:03.000>"
        )
        var document = original
        var session = LyricsTimingSession(document: document, preferredIndex: 0)

        session.stampSyllable(
            document: &document,
            lineIndex: 0,
            syllableIndex: 0,
            time: 4
        )
        session.stampSyllable(
            document: &document,
            lineIndex: 0,
            syllableIndex: 1,
            time: 5.25
        )
        #expect(document.lines[0].syllables?.map(\.start) == [4, 5.25])

        #expect(session.undo(document: &document) == 0)
        #expect(session.affectedSyllableIndex == 1)
        #expect(document.lines[0].syllables?.map(\.start) == [4, 5])

        #expect(session.undo(document: &document) == 0)
        #expect(session.affectedSyllableIndex == 0)
        #expect(document.lines[0].syllables == original.lines[0].syllables)
    }

    @Test("Word-level fine tuning coalesces with its matching stamp")
    func wordLevelFineTuningCoalesces() {
        let original = LyricsEditorDocument(
            parsing: "[00:01.000]<00:01.000>晚<00:02.000>风<00:03.000>"
        )
        var document = original
        var session = LyricsTimingSession(document: document, preferredIndex: 0)

        session.stampSyllable(
            document: &document,
            lineIndex: 0,
            syllableIndex: 1,
            time: 2.2
        )
        session.nudgeSyllable(
            document: &document,
            lineIndex: 0,
            syllableIndex: 1,
            by: 0.1
        )
        #expect(abs((document.lines[0].syllables?[1].start ?? 0) - 2.3) < 0.000_001)

        session.undo(document: &document)
        #expect(document.lines[0].syllables == original.lines[0].syllables)
    }
}
