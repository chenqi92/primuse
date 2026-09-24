import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke word timing")
struct KaraokeWordTimingTests {
    static let rate = 44_100.0
    /// Irregular note starts, as in real phrasing.
    static let noteStarts: [TimeInterval] = [0.10, 0.35, 0.52, 0.95, 1.30, 1.42]
    static let lineEnd: TimeInterval = 1.8

    /// Sung-like notes: each a harmonic tone with a fast attack and decay,
    /// at a different pitch, over light noise.
    static func vocal(starts: [TimeInterval], legatoAfter: Int? = nil) -> [Float] {
        let count = Int(2.2 * rate)
        var out = [Float](repeating: 0, count: count)
        var state: UInt64 = 9
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1
            out[i] = Float(Int64(bitPattern: state >> 11) % 1_000) / 200_000
        }
        let pitches: [Double] = [220, 247, 262, 294, 330, 349]
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : lineEnd
            for i in Int(start * rate)..<min(count, Int(end * rate)) {
                let t = Double(i) / rate - start
                // A legato note continues the previous one without a new attack.
                let attack = (legatoAfter == index) ? 1 : min(1, t / 0.012)
                let decay = exp(-t * 1.5)
                let phase = 2 * Double.pi * pitches[index % pitches.count] * Double(i) / rate
                out[i] += Float(0.3 * attack * decay * (sin(phase) + 0.4 * sin(2 * phase)))
            }
        }
        return out
    }

    static let window = KaraokeLineWindow(lineIndex: 0, lineID: "a", voice: .primary, start: 0.10, end: lineEnd)

    @Test("Onsets land on the note starts")
    func onsetDetection() {
        let onsets = KaraokeOnsetDetector.onsets(in: Self.vocal(starts: Self.noteStarts), sampleRate: Self.rate)
        for start in Self.noteStarts {
            #expect(onsets.contains { abs($0.time - start) < 0.03 }, "no onset near \(start): \(onsets.map(\.time))")
        }
        #expect(onsets.count <= Self.noteStarts.count + 2)
    }

    @Test("A line-timed row gets word starts on the sung notes")
    func alignsWords() throws {
        let onsets = KaraokeOnsetDetector.onsets(in: Self.vocal(starts: Self.noteStarts), sampleRate: Self.rate)
        let line = LyricLine(id: "a", timestamp: 0.10, text: "春眠不觉晓处")
        let timed = try #require(KaraokeWordTimingPolicy.timedLine(line, window: Self.window, onsets: onsets))
        let starts = try #require(timed.syllables).map(\.start)
        #expect(starts.count == 6)
        for (start, truth) in zip(starts, Self.noteStarts) {
            #expect(abs(start - truth) < 0.03, "\(starts)")
        }
        // Much closer than spreading the characters evenly.
        let even = try #require(KaraokeSweepPolicy.sweepLine(line, window: Self.window).syllables).map(\.start)
        let evenError = zip(even, Self.noteStarts).map { abs($0 - $1) }.max() ?? 0
        #expect(evenError > 0.1)
    }

    @Test("A note without an attack falls back without breaking the order")
    func legatoFallback() throws {
        let onsets = KaraokeOnsetDetector.onsets(
            in: Self.vocal(starts: Self.noteStarts, legatoAfter: 3),
            sampleRate: Self.rate
        )
        let line = LyricLine(id: "a", timestamp: 0.10, text: "春眠不觉晓处")
        let starts = try #require(KaraokeWordTimingPolicy.timedLine(line, window: Self.window, onsets: onsets)?.syllables).map(\.start)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })
        for index in [0, 1, 2, 4, 5] {
            #expect(abs(starts[index] - Self.noteStarts[index]) < 0.03, "\(starts)")
        }
    }

    @Test("Word-timed rows are left alone and empty input spreads evenly")
    func passThrough() throws {
        let timed = LyricLine(id: "a", timestamp: 0, text: "x", syllables: [LyricSyllable(text: "x", start: 0, end: 1)])
        #expect(KaraokeWordTimingPolicy.timedLine(timed, window: Self.window, onsets: []) == nil)
        let line = LyricLine(id: "b", timestamp: 0.10, text: "one two three")
        let spread = try #require(KaraokeWordTimingPolicy.timedLine(line, window: Self.window, onsets: [])?.syllables)
        let even = try #require(KaraokeSweepPolicy.sweepLine(line, window: Self.window).syllables)
        #expect(zip(spread, even).allSatisfy { abs($0.start - $1.start) < 1e-9 })
        #expect(spread.map(\.text).joined() == "one two three")
    }
}
