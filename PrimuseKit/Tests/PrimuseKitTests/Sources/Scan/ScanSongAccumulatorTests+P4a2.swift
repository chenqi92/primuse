import Foundation
import Testing
@testable import PrimuseKit

@Suite("Scan song accumulator")
struct ScanSongAccumulatorTests {
    private static func song(_ id: String, title: String = "t") -> Song {
        Song(id: id, title: title, fileFormat: .flac, filePath: "/music/\(id).flac", sourceID: "src")
    }

    @Test("Random edits match a plain array plus an id index, including prune and duplicate ids")
    func matchesArraySemantics() {
        var rng = CatalogTestRandom(seed: 5_201)
        for round in 0..<300 {
            let initial: [Song] = (0..<rng.int(0...40)).map { _ in Self.song("s\(rng.int(0...30))", title: "base\(round)") }
            var reference = initial
            var referenceIndex: [String: Int] = [:]
            for (offset, song) in reference.enumerated() { referenceIndex[song.id] = offset }
            var accumulator = ScanSongAccumulator(initial)
            var pruned = false
            for step in 0..<rng.int(0...60) {
                switch rng.int(0...3) {
                case 0:
                    let song = Self.song("n\(rng.int(0...50))", title: "new\(step)")
                    reference.append(song)
                    referenceIndex[song.id] = reference.count - 1
                    accumulator.append(song)
                case 1, 2:
                    guard !reference.isEmpty else { continue }
                    let position = rng.int(0...(reference.count - 1))
                    var song = reference[position]
                    song.title = "edit\(step)"
                    reference[position] = song
                    accumulator[position] = song
                default:
                    guard rng.chance(20) else { continue }
                    let keep = Set(reference.map { (song: Song) in song.id }.filter { _ in rng.chance(70) })
                    reference.removeAll { !keep.contains($0.id) }
                    accumulator.removeAll { !keep.contains($0.id) }
                    pruned = true
                }
                #expect(accumulator.count == reference.count)
                #expect(accumulator.indices.map { accumulator[$0] } == reference)
                if !pruned {
                    for (id, offset) in referenceIndex { #expect(accumulator.index(ofID: id) == offset) }
                }
            }
            #expect(accumulator.songs == reference)
        }
    }

    @Test("An unchanged scan hands back the existing array itself")
    func unchangedSnapshotIsTheBase() {
        let songs = (0..<1_000).map { Self.song("s\($0)") }
        let accumulator = ScanSongAccumulator(songs)
        let snapshot = accumulator.songs
        #expect(snapshot == songs)
        #expect(accumulator.overlayCount == 0)
        snapshot.withUnsafeBufferPointer { left in
            songs.withUnsafeBufferPointer { right in #expect(left.baseAddress == right.baseAddress) }
        }
        print("scanAccumulator.songStride=\(MemoryLayout<Song>.stride)B")
    }

    @Test("A prune keeps order and leaves no stale id lookups")
    func pruneKeepsOrder() {
        var accumulator = ScanSongAccumulator((0..<10).map { Self.song("s\($0)") })
        accumulator[3] = Self.song("s3", title: "edited")
        accumulator.append(Self.song("n0"))
        accumulator.removeAll { ["s1", "s4", "n0"].contains($0.id) }
        #expect(accumulator.songs.map(\.id) == ["s0", "s2", "s3", "s5", "s6", "s7", "s8", "s9"])
        #expect(accumulator[2].title == "edited")
        #expect(accumulator.index(ofID: "s0") == nil)
    }
}
