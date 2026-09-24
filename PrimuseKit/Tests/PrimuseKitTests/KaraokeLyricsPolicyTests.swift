import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke lyric policies")
struct KaraokeLyricsPolicyTests {
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
}
