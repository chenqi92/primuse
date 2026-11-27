import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke pitch detection")
struct KaraokePitchDetectorTests {
    static func tone(_ frequency: Double, sampleRate: Double = 48_000, count: Int = 2_048, harmonics: Bool = false) -> [Float] {
        (0..<count).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            var value = 0.4 * sin(phase)
            if harmonics {
                value += 0.2 * sin(2 * phase) + 0.1 * sin(3 * phase)
            }
            return Float(value)
        }
    }

    @Test("Finds the pitch of pure and harmonic-rich tones", arguments: [110.0, 220.0, 261.63, 440.0, 880.0])
    func detectsTones(frequency: Double) throws {
        let detector = KaraokePitchDetector(sampleRate: 48_000)
        let pure = try #require(detector.detect(Self.tone(frequency)))
        #expect(abs(pure.midiNote - KaraokePitchDetector.midiNote(forFrequency: frequency)) < 0.1)
        let rich = try #require(detector.detect(Self.tone(frequency, harmonics: true)))
        #expect(abs(rich.midiNote - KaraokePitchDetector.midiNote(forFrequency: frequency)) < 0.1)
        #expect(rich.confidence > 0.8)
    }

    @Test("Silence and noise yield no pitch")
    func rejectsSilenceAndNoise() {
        let detector = KaraokePitchDetector(sampleRate: 48_000)
        #expect(detector.detect([Float](repeating: 0, count: 2_048)) == nil)
        var state: UInt64 = 42
        let noise: [Float] = (0..<2_048).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Int64(bitPattern: state >> 11) % 1_000) / 2_000
        }
        #expect(detector.detect(noise) == nil)
        #expect(detector.detect([Float](repeating: 0.3, count: 100)) == nil)
    }

    @Test("MIDI conversion round-trips")
    func midiConversion() {
        #expect(KaraokePitchDetector.midiNote(forFrequency: 440) == 69)
        #expect(abs(KaraokePitchDetector.frequency(forMIDINote: 60) - 261.6256) < 0.001)
    }
}

@Suite("Karaoke scoring")
struct KaraokeScoringTests {
    static let lines = [
        LyricLine(id: "a", timestamp: 10, text: "first line", endTimestamp: 13),
        LyricLine(id: "b", timestamp: 14, text: "second line", endTimestamp: 17),
    ]

    @Test("Octave errors are forgiven, wrong notes are not")
    func pitchAccuracy() {
        #expect(KaraokeScorer.pitchAccuracy(sung: 60, reference: 60) == 1)
        #expect(KaraokeScorer.pitchAccuracy(sung: 48.2, reference: 60) == 1)
        #expect(KaraokeScorer.pitchAccuracy(sung: 60.4, reference: 60) == 1)
        #expect(KaraokeScorer.pitchAccuracy(sung: 63, reference: 60) == 0)
        #expect(abs(KaraokeScorer.pitchAccuracy(sung: 61.75, reference: 60) - 0.5) < 1e-9)
    }

    @Test("Perfect singing scores 100 and silence scores 0")
    func perfectAndSilent() {
        var scorer = KaraokeScorer(lines: Self.lines)
        var time = 10.0
        while time < 13 {
            scorer.record(time: time, reference: 64, sung: 64)
            time += 0.05
        }
        time = 14
        while time < 17 {
            scorer.record(time: time, reference: 67, sung: nil)
            time += 0.05
        }
        let summary = scorer.summary()
        #expect(summary.lines.map(\.score) == [100, 0])
        #expect(summary.lines.allSatisfy { $0.isPitchJudged })
        #expect(summary.totalScore == 50)
        #expect(summary.bestLine?.lineID == "a")
        #expect(summary.grade == .c)
    }

    @Test("Without a reference melody lines are judged on singing through them")
    func presenceFallback() {
        var scorer = KaraokeScorer(lines: Self.lines)
        var time = 10.0
        var step = 0
        while time < 13 {
            // Singing 60 % of the time counts as the whole line.
            scorer.record(time: time, reference: nil, sung: step % 5 < 3 ? 62 : nil)
            time += 0.05
            step += 1
        }
        let line = scorer.summary().lines.first
        #expect(line?.isPitchJudged == false)
        #expect(line?.score == 100)
    }

    @Test("Samples outside any line are ignored and a short line is not judged")
    func ignoresGaps() {
        var scorer = KaraokeScorer(lines: Self.lines)
        scorer.record(time: 5, reference: 60, sung: 70)
        scorer.record(time: 13.5, reference: 60, sung: 70)
        scorer.record(time: 10.1, reference: 60, sung: 60)
        #expect(scorer.summary().isEmpty)
        #expect(scorer.summary().totalScore == 0)
    }

    @Test("Seeking back re-opens later lines")
    func seekBackForgets() {
        var scorer = KaraokeScorer(lines: Self.lines)
        var time = 14.0
        while time < 17 {
            scorer.record(time: time, reference: 60, sung: nil)
            time += 0.05
        }
        #expect(scorer.summary().lines.count == 1)
        scorer.record(time: 11, reference: 60, sung: 60)
        #expect(scorer.summary().lines.isEmpty)
    }

    @Test("Duet part scores only the user's own lines")
    func duetPartFilter() {
        let lines = [
            LyricLine(id: "a", timestamp: 1, text: "me", endTimestamp: 3, voice: .primary),
            LyricLine(id: "b", timestamp: 3, text: "you", endTimestamp: 5, voice: .secondary),
        ]
        #expect(KaraokeScorer(lines: lines, part: .primary).windows.map(\.lineID) == ["a"])
        #expect(KaraokeScorer(lines: lines, part: .secondary).windows.map(\.lineID) == ["b"])
        #expect(KaraokeScorer(lines: lines, part: .all).windows.count == 2)
    }

    @Test("Pitch track finds the nearest reading and drops history on seek")
    func pitchTrack() {
        var track = KaraokePitchTrack(capacity: 10)
        track.append(time: 1.00, midiNote: 60)
        track.append(time: 1.05, midiNote: 62)
        track.append(time: 1.10, midiNote: nil)
        #expect(track.note(at: 1.04) == 62)
        #expect(track.note(at: 1.01) == 60)
        #expect(track.note(at: 1.11) == nil)
        #expect(track.note(at: 3) == nil)
        track.append(time: 0.2, midiNote: 50)
        #expect(track.readings.count == 1)
        for index in 0..<20 { track.append(time: 1 + Double(index), midiNote: 1) }
        #expect(track.readings.count == 10)
    }

    @Test("Grades follow the score bands")
    func grades() {
        #expect(KaraokeGrade.grade(for: 95) == .s)
        #expect(KaraokeGrade.grade(for: 80) == .a)
        #expect(KaraokeGrade.grade(for: 79) == .b)
        #expect(KaraokeGrade.grade(for: 50) == .c)
        #expect(KaraokeGrade.grade(for: 12) == .d)
    }
}
