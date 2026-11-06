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

    @Test("Incremental stem files are byte-identical across arbitrary chunk boundaries")
    func incrementalStemFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kvst")
        defer { try? FileManager.default.removeItem(at: url) }
        let left = Self.noise(count: 25_003, seed: 31).map { $0 * 1.5 }
        let right = left.map { -$0 * 0.75 }
        let writer = try KaraokeStemFile.Writer(url: url, sampleRate: 44_100, frames: left.count)
        for range in [0..<1, 1..<8_191, 8_191..<8_192, 8_192..<25_003] {
            try writer.append(left: Array(left[range]), right: Array(right[range]))
        }
        try writer.finish()
        let data = try Data(contentsOf: url)
        #expect(data == KaraokeStemFile.encode(left: left, right: right, sampleRate: 44_100))
        #expect(writer.writtenFrames == left.count)
        #expect(KaraokeStemFile.header(of: data) == .init(sampleRate: 44_100, frames: left.count))
        #expect(throws: KaraokeStemFile.Writer.Failure.alreadyFinished) {
            try writer.append(left: [], right: [])
        }
    }

    @Test("An incomplete stem cannot finish or pass the cache header check")
    func incompleteIncrementalStem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kvst")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try KaraokeStemFile.Writer(url: url, sampleRate: 48_000, frames: 3)
        try writer.append(left: [0.1], right: [-0.1])
        #expect(throws: KaraokeStemFile.Writer.Failure.invalidFrameCount) { try writer.finish() }
        #expect(KaraokeStemFile.header(of: try Data(contentsOf: url)) == nil)
        #expect(throws: KaraokeStemFile.Writer.Failure.invalidFrameCount) {
            try writer.append(left: [0.2, 0.3], right: [0.2])
        }
        #expect(throws: KaraokeStemFile.Writer.Failure.invalidFrameCount) {
            try writer.append(left: [0.2, 0.3, 0.4], right: [-0.2, -0.3, -0.4])
        }
        #expect(writer.writtenFrames == 1)
        try writer.append(left: [0.2, 0.3], right: [-0.2, -0.3])
        try writer.finish()
        #expect(try Data(contentsOf: url) == KaraokeStemFile.encode(
            left: [0.1, 0.2, 0.3], right: [-0.1, -0.2, -0.3], sampleRate: 48_000
        ))
    }

    @Test("A stem writer refuses to overwrite an existing file")
    func incrementalStemPreservesExistingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kvst")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("existing stem".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) {
            _ = try KaraokeStemFile.Writer(url: url, sampleRate: 44_100, frames: 3)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Mono stem decoding matches stereo averaging without retaining both channels")
    func monoStemFile() throws {
        let left = Self.noise(count: 5_013, seed: 23)
        let right = Self.noise(count: 5_013, seed: 47)
        let data = KaraokeStemFile.encode(left: left, right: right, sampleRate: 44_100)
        let stereo = try #require(KaraokeStemFile.decode(data))
        let mono = try #require(KaraokeStemFile.decodeMono(data))
        #expect(mono.header == stereo.header)
        #expect(mono.samples == zip(stereo.left, stereo.right).map { ($0 + $1) * 0.5 })
        #expect(KaraokeStemFile.decodeMono(Data(data.dropLast())) == nil)
        var foreign = data
        foreign[0] ^= 0xff
        #expect(KaraokeStemFile.decodeMono(foreign) == nil)
    }

    @Test("Chunked stem decoding matches complete decoding across frame boundaries")
    func stemFrameChunks() throws {
        let left = Self.noise(count: 20_003, seed: 71)
        let right = Self.noise(count: 20_003, seed: 17)
        let data = KaraokeStemFile.encode(left: left, right: right, sampleRate: 44_100)
        let complete = try #require(KaraokeStemFile.decode(data))
        var decodedLeft: [Float] = [], decodedRight: [Float] = []
        for range in [0..<17, 17..<8_192, 8_192..<8_193, 8_193..<20_003] {
            let chunk = try #require(KaraokeStemFile.decodeFrames(data, range: range))
            #expect(chunk.left.count == range.count)
            #expect(chunk.right.count == range.count)
            decodedLeft += chunk.left
            decodedRight += chunk.right
        }
        #expect(decodedLeft == complete.left)
        #expect(decodedRight == complete.right)
    }

    @Test("Stem frame reads validate ranges and allow empty reads within the file")
    func stemFrameRanges() throws {
        let data = KaraokeStemFile.encode(left: [0.1, 0.2, 0.3], right: [-0.1, -0.2, -0.3], sampleRate: 48_000)
        for range in [0..<0, 1..<1, 3..<3] {
            let chunk = try #require(KaraokeStemFile.decodeFrames(data, range: range))
            #expect(chunk.left.isEmpty && chunk.right.isEmpty)
        }
        for range in [-1..<0, -1..<1, 0..<4, 4..<4] {
            #expect(KaraokeStemFile.decodeFrames(data, range: range) == nil)
        }
        #expect(KaraokeStemFile.decodeFrames(Data(data.dropLast()), range: 0..<1) == nil)
        #expect(KaraokeStemFile.decodeFrames(Data("foreign".utf8), range: 0..<0) == nil)
    }

    @Test("A writer rejects invalid headers before creating a file")
    func incrementalStemInvalidHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kvst")
        defer { try? FileManager.default.removeItem(at: url) }
        for rate in [Double.nan, .infinity, 0, -1, Double(UInt32.max) + 1] {
            #expect(throws: KaraokeStemFile.Writer.Failure.invalidHeader) {
                _ = try KaraokeStemFile.Writer(url: url, sampleRate: rate, frames: 1)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(throws: KaraokeStemFile.Writer.Failure.invalidHeader) {
            _ = try KaraokeStemFile.Writer(url: url, sampleRate: 44_100, frames: -1)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
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
