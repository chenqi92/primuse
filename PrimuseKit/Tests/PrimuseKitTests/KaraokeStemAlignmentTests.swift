import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke stem alignment")
struct KaraokeStemAlignmentTests {
    static let rate = 44_100.0

    /// A sung-like line: harmonic tone with vibrato, phrases with rests.
    static func vocal(count: Int) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / rate
            let phrase = sin(2 * Double.pi * 0.4 * t) > -0.2 ? 1.0 : 0.0
            let f0 = 220 * (1 + 0.3 * sin(2 * Double.pi * 0.15 * t)) + 4 * sin(2 * Double.pi * 5.5 * t)
            let phase = 2 * Double.pi * f0 * t
            return Float(phrase * (0.3 * sin(phase) + 0.12 * sin(2 * phase) + 0.05 * sin(3 * phase)))
        }
    }

    static func noise(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
        }
    }

    @Test("Locks onto the exact sample under louder accompaniment")
    func exactLock() throws {
        let count = 44_100 * 6
        let stem = Self.vocal(count: count)
        let accompaniment = Self.noise(count: count, seed: 3).map { $0 * 0.4 }
        let mix = zip(stem, accompaniment).map(+)
        // Inside sung phrases (0.25 s, 2.65 s, 5.1 s).
        for truth in [11_025, 116_865, 224_910] {
            let live = Array(mix[truth..<(truth + 8_192)])
            let match = try #require(KaraokeStemAligner.match(
                live: live, in: stem, predictedIndex: truth + 3_000, radius: 13_000
            ))
            #expect(match.stemIndex == truth)
            #expect(match.confidence > KaraokeStemAligner.lockConfidence)
        }
    }

    @Test("A rest between phrases is not trusted")
    func restIsRejected() {
        let count = 44_100 * 6
        let stem = Self.vocal(count: count)
        let mix = zip(stem, Self.noise(count: count, seed: 7).map { $0 * 0.4 }).map(+)
        // 2.04 s falls in a rest of the synthetic line.
        let live = Array(mix[90_000..<98_192])
        let match = KaraokeStemAligner.match(live: live, in: stem, predictedIndex: 90_000, radius: 13_000)
        #expect((match?.confidence ?? 0) < KaraokeStemAligner.lockConfidence)
    }

    @Test("A wrong prediction window finds nothing trustworthy")
    func outsideRadius() {
        let count = 44_100 * 6
        let stem = Self.vocal(count: count)
        let mix = zip(stem, Self.noise(count: count, seed: 5).map { $0 * 0.4 }).map(+)
        let live = Array(mix[150_000..<158_192])
        let match = KaraokeStemAligner.match(live: live, in: stem, predictedIndex: 20_000, radius: 4_000)
        #expect((match?.confidence ?? 0) < KaraokeStemAligner.lockConfidence)
    }

    @Test("Silence in the live signal or the stem is rejected")
    func silence() {
        let stem = Self.vocal(count: 44_100 * 2)
        #expect(KaraokeStemAligner.match(
            live: [Float](repeating: 0, count: 4_096), in: stem, predictedIndex: 1_000, radius: 1_000
        ) == nil)
        let quiet = [Float](repeating: 0, count: 44_100 * 2)
        #expect(KaraokeStemAligner.match(
            live: Self.noise(count: 4_096, seed: 1), in: quiet, predictedIndex: 1_000, radius: 1_000
        ) == nil)
    }

    @Test("Stem files round-trip within 16-bit precision")
    func stemFile() throws {
        let left = Self.vocal(count: 5_000)
        let right = left.map { -$0 * 0.5 }
        let data = KaraokeStemFile.encode(left: left, right: right, sampleRate: 48_000)
        let decoded = try #require(KaraokeStemFile.decode(data))
        #expect(decoded.header == KaraokeStemFile.Header(sampleRate: 48_000, frames: 5_000))
        #expect(zip(decoded.left, left).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(zip(decoded.right, right).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(KaraokeStemFile.decode(Data(data.prefix(100))) == nil)
        #expect(KaraokeStemFile.decode(Data("nope".utf8)) == nil)
    }
}

@Suite("Karaoke stem lock policy")
struct KaraokeStemLockPolicyTests {
    @Test("Locks only after two agreeing matches")
    func locking() {
        var policy = KaraokeStemLockPolicy()
        #expect(policy.record(delta: 100) == nil)
        #expect(policy.lockedDelta == nil)
        #expect(policy.record(delta: 100) == 100)
        #expect(policy.lockedDelta == 100)
        #expect(policy.record(delta: 100) == nil)
    }

    @Test("A single stray match does not move the lock")
    func strayMatch() {
        var policy = KaraokeStemLockPolicy()
        _ = policy.record(delta: 100); _ = policy.record(delta: 100)
        #expect(policy.record(delta: 381) == nil)
        #expect(policy.record(delta: 100) == nil)
        #expect(policy.record(delta: 381) == nil)
        #expect(policy.lockedDelta == 100)
        // Two in a row do move it.
        #expect(policy.record(delta: 381) == 381)
    }

    @Test("Disagreeing matches never lock")
    func noAgreement() {
        var policy = KaraokeStemLockPolicy()
        for delta in [1, 2, 3, 4] { #expect(policy.record(delta: delta) == nil) }
        #expect(policy.lockedDelta == nil)
        policy.reset()
        #expect(policy.lockedDelta == nil)
    }
}
