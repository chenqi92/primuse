import Testing
@testable import PrimuseKit

@Suite("Lyrics timing session")
struct LyricsTimingSessionTests {
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
}
