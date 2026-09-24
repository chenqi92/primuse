import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke pitch shifter")
struct KaraokePitchShifterTests {
    static let rate = 44_100.0

    static func tone(_ f: Double, count: Int, harmonics: Bool = false) -> [Float] {
        (0..<count).map { i in
            let p = 2 * Double.pi * f * Double(i) / rate
            return Float(0.3 * sin(p) + (harmonics ? 0.15 * sin(2 * p) + 0.08 * sin(3 * p) : 0))
        }
    }

    /// Runs the shifter over stereo signals in 512-sample blocks.
    static func shift(_ left: [Float], _ right: [Float], semitones: Double) -> ([Float], [Float]) {
        let shifter = KaraokePitchShifter(sampleRate: rate)
        var l = left, r = right
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { pointers.deallocate() }
        l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
            var offset = 0
            while offset < lb.count {
                let n = min(512, lb.count - offset)
                pointers[0] = lb.baseAddress! + offset
                pointers[1] = rb.baseAddress! + offset
                shifter.process(UnsafeMutableBufferPointer(start: pointers, count: 2), frameCount: n, semitones: semitones)
                offset += n
            }
        } }
        return (l, r)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    @Test("Shifted tones land on the target pitch at the same level", arguments: [3.0, 7.0, -5.0, 0.0])
    func pitchAndLevel(semitones: Double) throws {
        let count = 44_100
        let input = Self.tone(440, count: count)
        let (out, _) = Self.shift(input, input, semitones: semitones)
        let tail = Array(out[20_000..<(20_000 + 4_096)])
        let estimate = try #require(KaraokePitchDetector(sampleRate: Self.rate, windowSize: 2_048).detect(tail))
        let expected = 440 * pow(2, semitones / 12)
        #expect(abs(estimate.frequency / expected - 1) < 0.01, "got \(estimate.frequency) want \(expected)")
        let ratio = Self.rms(out[20_000..<40_000]) / Self.rms(input[20_000..<40_000])
        #expect(abs(ratio - 1) < 0.1, "level ratio \(ratio)")
    }

    @Test("Harmonic sounds keep their harmonics in proportion")
    func harmonics() throws {
        let input = Self.tone(220, count: 44_100, harmonics: true)
        let (out, _) = Self.shift(input, input, semitones: 4)
        let tail = Array(out[20_000..<24_096])
        let estimate = try #require(KaraokePitchDetector(sampleRate: Self.rate, windowSize: 2_048).detect(tail))
        #expect(abs(estimate.frequency / (220 * pow(2, 4.0 / 12)) - 1) < 0.01)
        #expect(estimate.confidence > 0.8)
    }

    @Test("Left and right are shifted independently")
    func stereoIndependence() throws {
        let left = Self.tone(440, count: 44_100)
        let right = Self.tone(660, count: 44_100)
        let (l, r) = Self.shift(left, right, semitones: 2)
        let detector = KaraokePitchDetector(sampleRate: Self.rate, windowSize: 2_048)
        let fl = try #require(detector.detect(Array(l[20_000..<24_096]))).frequency
        let fr = try #require(detector.detect(Array(r[20_000..<24_096]))).frequency
        #expect(abs(fl / (440 * pow(2, 2.0 / 12)) - 1) < 0.01)
        #expect(abs(fr / (660 * pow(2, 2.0 / 12)) - 1) < 0.01)
    }
}
