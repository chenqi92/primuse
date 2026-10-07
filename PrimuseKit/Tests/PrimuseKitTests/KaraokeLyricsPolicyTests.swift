import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke lyric policies")
struct KaraokeLyricsPolicyTests {
    @Test("Empty stage snapshots have no focused row or valid indices")
    func emptyStageSnapshot() {
        let snapshot = KaraokeLyricsSnapshot()
        #expect(snapshot.focusedWindowIndex(at: 0) == nil)
        #expect(snapshot.focusedWindowIndex(at: 50) == nil)
        for index in [Int.min, -1, 0, 1, Int.max] {
            #expect(snapshot.row(at: index) == nil)
        }
    }

    @Test("Stage rows keep original indices when blank and unsynchronized lines are skipped")
    func stageSnapshotRowMapping() throws {
        let lines = [
            LyricLine(id: "credit", timestamp: 0, text: "Singer", isSynchronized: false),
            LyricLine(id: "blank", timestamp: 1, text: "  "),
            LyricLine(id: "first", timestamp: 5, text: "First voice"),
            LyricLine(id: "translation", timestamp: 5, text: "Translation", isSynchronized: false),
            LyricLine(id: "second", timestamp: 20, text: "Second voice", voice: .secondary),
        ]
        let snapshot = KaraokeLyricsSnapshot(lines: lines)
        #expect(snapshot.windows.map(\.lineIndex) == [2, 4])
        #expect(snapshot.hasDuetParts)
        #expect(snapshot.focusedWindowIndex(at: 0) == 0)
        #expect(snapshot.focusedWindowIndex(at: 15) == 1)
        #expect(snapshot.focusedWindowIndex(at: 50) == 1)
        for index in snapshot.windows.indices {
            let row = try #require(snapshot.row(at: index))
            #expect(row.line.id == row.window.lineID)
            #expect(row.line.text == lines[row.window.lineIndex].text)
        }
        #expect(snapshot.row(at: 2) == nil)
    }

    @Test("Deferred stage rows remain valid after lyrics clear and a shorter song loads")
    func deferredStageSnapshot() throws {
        var live = KaraokeLyricsSnapshot(lines: [
            LyricLine(id: "old-first", timestamp: 1, text: "First"),
            LyricLine(id: "old-last", timestamp: 10, text: "Last", voice: .secondary),
        ])
        let captured = live
        let focused = try #require(captured.focusedWindowIndex(at: 11))
        live = KaraokeLyricsSnapshot()
        #expect(live.row(at: focused) == nil)
        #expect(captured.row(at: focused)?.line.id == "old-last")
        live = KaraokeLyricsSnapshot(lines: [LyricLine(id: "new", timestamp: 1, text: "New")])
        #expect(live.row(at: focused) == nil)
        #expect(live.row(at: 0)?.line.id == "new")
        #expect(captured.row(at: focused)?.window.voice == .secondary)
        #expect(captured.hasDuetParts)
        #expect(!live.hasDuetParts)
    }

    @Test("AI timing replaces line-level stage rows without changing authored windows or words")
    func stageSnapshotWordTiming() throws {
        let authored = LyricLine(id: "authored", timestamp: 1, text: "Kept", syllables: [
            LyricSyllable(text: "Kept", start: 1, end: 2),
        ])
        let lines = [authored, LyricLine(id: "inferred", timestamp: 10, text: "你好世界")]
        let even = KaraokeLyricsSnapshot(lines: lines)
        let timed = KaraokeLyricsSnapshot(lines: lines, onsets: [
            KaraokeOnset(time: 10.1, strength: 1),
            KaraokeOnset(time: 11.5, strength: 1),
        ])
        #expect(!even.usesInferredWordTiming)
        #expect(timed.usesInferredWordTiming)
        #expect(timed.windows == even.windows)
        #expect(timed.row(at: 0)?.line == authored)
        let inferred = try #require(timed.row(at: 1)?.line.syllables)
        #expect(inferred.map(\.text).joined() == "你好世界")
        #expect(inferred.allSatisfy { $0.endTiming == .inferred })
        #expect(even.row(at: 1)?.line.syllables != inferred)
    }

    @Test("Windows use explicit ends, word ends, or the next line with a cap")
    func windows() {
        let lines = [
            LyricLine(id: "meta", timestamp: 0, text: "", isSynchronized: true),
            LyricLine(id: "a", timestamp: 5, text: "explicit", endTimestamp: 7),
            LyricLine(id: "b", timestamp: 8, text: "words", syllables: [
                LyricSyllable(text: "wo", start: 8, end: 8.4),
                LyricSyllable(text: "rds", start: 8.4, end: 9.1),
            ]),
            LyricLine(id: "c", timestamp: 10, text: "until next"),
            LyricLine(id: "d", timestamp: 12, text: "long gap after"),
            LyricLine(id: "e", timestamp: 40, text: "last"),
        ]
        let windows = KaraokeLineWindowPolicy.windows(in: lines)
        #expect(windows.map(\.lineID) == ["a", "b", "c", "d", "e"])
        #expect(windows.map(\.end) == [7, 9.1, 12, 20, 48])
        #expect(KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: 8.5) == 1)
        #expect(KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: 7.5) == nil)
        #expect(KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: 25) == nil)
        #expect(KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: 2) == nil)
    }

    @Test("Unsynchronized lyrics produce no windows")
    func plainLyrics() {
        let lines = [LyricLine(id: "a", timestamp: 0, text: "plain", isSynchronized: false)]
        #expect(KaraokeLineWindowPolicy.windows(in: lines).isEmpty)
    }

    @Test("Countdown only before an entry that follows a long gap")
    func leadIn() {
        let windows = [
            KaraokeLineWindow(lineIndex: 0, lineID: "a", voice: .primary, start: 12, end: 15),
            KaraokeLineWindow(lineIndex: 1, lineID: "b", voice: .primary, start: 16, end: 19),
            KaraokeLineWindow(lineIndex: 2, lineID: "c", voice: .primary, start: 40, end: 43),
        ]
        #expect(KaraokeLeadInPolicy.leadIn(windows: windows, at: 5) == nil)
        #expect(KaraokeLeadInPolicy.leadIn(windows: windows, at: 9.5)?.remainingBeats == 3)
        #expect(KaraokeLeadInPolicy.leadIn(windows: windows, at: 11.2)?.remainingBeats == 1)
        // Short gap between a and b: no countdown.
        #expect(KaraokeLeadInPolicy.leadIn(windows: windows, at: 15.5) == nil)
        let interlude = KaraokeLeadInPolicy.leadIn(windows: windows, at: 38.5)
        #expect(interlude?.remainingBeats == 2)
        #expect(interlude?.nextLineIndex == 2)
        #expect(KaraokeLeadInPolicy.leadIn(windows: windows, at: 44) == nil)
    }

    @Test("Line-level rows get an even sweep that restores the text")
    func sweep() throws {
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "a", voice: .primary, start: 10, end: 20)
        let latin = KaraokeSweepPolicy.sweepLine(
            LyricLine(id: "a", timestamp: 10, text: "hello big world"),
            window: window
        )
        let syllables = try #require(latin.syllables)
        #expect(syllables.map(\.text) == ["hello ", "big ", "world"])
        #expect(syllables.map(\.text).joined() == "hello big world")
        #expect(syllables.first?.start == 10)
        #expect(abs((syllables.last?.end ?? 0) - 19.2) < 1e-9)
        #expect(syllables.allSatisfy { $0.endTiming == .inferred })

        let cjk = KaraokeSweepPolicy.sweepLine(
            LyricLine(id: "b", timestamp: 10, text: "你好 世界"),
            window: window
        )
        #expect(cjk.syllables?.map(\.text) == ["你", "好 ", "世", "界"])

        let timed = LyricLine(id: "c", timestamp: 10, text: "x", syllables: [
            LyricSyllable(text: "x", start: 10, end: 11),
        ])
        #expect(KaraokeSweepPolicy.sweepLine(timed, window: window) == timed)
    }

    @Test("Duet gate keeps the partner's vocal and removes the user's")
    func duetGate() {
        let windows = [
            KaraokeLineWindow(lineIndex: 0, lineID: "a", voice: .primary, start: 10, end: 14),
            KaraokeLineWindow(lineIndex: 1, lineID: "b", voice: .secondary, start: 15, end: 19),
            KaraokeLineWindow(lineIndex: 2, lineID: "c", voice: .primary, start: 18, end: 22),
        ]
        func factor(_ part: KaraokePart, _ time: TimeInterval) -> Float {
            KaraokeDuetGatePolicy.reductionFactor(windows: windows, part: part, at: time)
        }
        #expect(factor(.all, 16) == 1)
        #expect(factor(.primary, 12) == 1)
        #expect(factor(.primary, 16) == 0)
        // Pre-roll opens the partner slightly early.
        #expect(factor(.primary, 14.9) == 0)
        #expect(factor(.primary, 14.5) == 1)
        // Overlap: the user's own row wins.
        #expect(factor(.primary, 18.5) == 1)
        #expect(factor(.secondary, 12) == 0)
        #expect(factor(.secondary, 16) == 1)
        #expect(factor(.primary, 30) == 1)
    }

    @Test("Duet parts need both voices")
    func duetDetection() {
        let solo = [LyricLine(id: "a", timestamp: 1, text: "a")]
        let duet = solo + [LyricLine(id: "b", timestamp: 2, text: "b", voice: .secondary)]
        #expect(!KaraokeDuetGatePolicy.hasDuetParts(solo))
        #expect(KaraokeDuetGatePolicy.hasDuetParts(duet))
    }

    @Test("Key shift is clamped to half an octave")
    func keyShift() {
        #expect(KaraokeKeyShiftPolicy.cents(forSemitones: 2) == 200)
        #expect(KaraokeKeyShiftPolicy.cents(forSemitones: -9) == -600)
        #expect(KaraokeKeyShiftPolicy.clamped(7) == 6)
    }

    @Test("Availability reports the first blocking reason")
    func availability() {
        #expect(KaraokeAvailability.resolve(hasSong: false, isAppleMusic: true, isCasting: true, isHighFidelityOutput: true) == .noSong)
        #expect(KaraokeAvailability.resolve(hasSong: true, isAppleMusic: true, isCasting: false, isHighFidelityOutput: false) == .appleMusic)
        #expect(KaraokeAvailability.resolve(hasSong: true, isAppleMusic: false, isCasting: true, isHighFidelityOutput: true) == .casting)
        #expect(KaraokeAvailability.resolve(hasSong: true, isAppleMusic: false, isCasting: false, isHighFidelityOutput: true) == .highFidelityOutput)
        #expect(KaraokeAvailability.resolve(hasSong: true, isAppleMusic: false, isCasting: false, isHighFidelityOutput: false) == .available)
    }

    @Test("Recording alignment drops the microphone's head start")
    func recordingAlignment() {
        // Accompaniment first rendered at t=100.000 s and heard 20 ms later;
        // the voice sung then reaches the tap 10 ms after that.
        let frames = KaraokeRecordingAlignment.microphoneLeadFrames(
            accompanimentFirstHostSeconds: 100,
            microphoneFirstHostSeconds: 99.9,
            outputLatency: 0.02,
            inputLatency: 0.01,
            sampleRate: 48_000
        )
        #expect(frames == 6_240)
        let late = KaraokeRecordingAlignment.microphoneLeadFrames(
            accompanimentFirstHostSeconds: 100,
            microphoneFirstHostSeconds: 100.5,
            outputLatency: 0,
            inputLatency: 0,
            sampleRate: 1_000
        )
        #expect(late == -500)
    }

    @Test("Long rows shrink until they fit two lines; short rows keep the base size")
    func lineFit() {
        // 10 ideographs at 34 pt on a 350 pt stage: one row.
        #expect(KaraokeLineFitPolicy.fontSize(for: "十个汉字刚好一行整", base: 34, availableWidth: 350) == 34)
        // 18 ideographs: two rows at 34 pt, still allowed.
        let eighteen = String(repeating: "歌", count: 18)
        #expect(KaraokeLineFitPolicy.fontSize(for: eighteen, base: 34, availableWidth: 350) == 34)
        // 24 ideographs: three rows at 34 pt and at 29.9 pt, two at 25.8 pt.
        let twentyFour = String(repeating: "歌", count: 24)
        #expect(KaraokeLineFitPolicy.fontSize(for: twentyFour, base: 34, availableWidth: 350) == 34 * 0.76)
        // Latin text advances about half an em per glyph, so the same
        // character count fits far more easily.
        let latin = String(repeating: "a", count: 24)
        #expect(KaraokeLineFitPolicy.fontSize(for: latin, base: 34, availableWidth: 350) == 34)
        // 30 ideographs on a phone stage: three rows down to 25.8 pt, two at 22.4 pt.
        let thirty = String(repeating: "歌", count: 30)
        #expect(KaraokeLineFitPolicy.fontSize(for: thirty, base: 34, availableWidth: 362) == 34 * 0.66)
        // 12 ideographs spill one character onto a second row at 34 pt and
        // fit a single row one step down: no orphan.
        let twelve = String(repeating: "歌", count: 12)
        #expect(KaraokeLineFitPolicy.fontSize(for: twelve, base: 34, availableWidth: 362) == 34 * 0.88)
        // 16 ideographs are two comfortable rows at full size and stay there.
        let sixteen = String(repeating: "歌", count: 16)
        #expect(KaraokeLineFitPolicy.fontSize(for: sixteen, base: 34, availableWidth: 362) == 34)
        // Nothing to fit on: the base size stands.
        #expect(KaraokeLineFitPolicy.fontSize(for: twentyFour, base: 34, availableWidth: 0) == 34)
        // Even the smallest step may not fit; it is still the floor.
        let endless = String(repeating: "歌", count: 80)
        #expect(KaraokeLineFitPolicy.fontSize(for: endless, base: 34, availableWidth: 350) == 34 * 0.66)
    }
}
