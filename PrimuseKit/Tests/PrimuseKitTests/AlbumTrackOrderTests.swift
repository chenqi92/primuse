import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album track order")
struct AlbumTrackOrderTests {
    @Test("Finish each disc before starting the next, including mixed formats")
    func repeatedTrackNumbersAcrossFiveDiscs() {
        let expected: [Song] = (1...5).flatMap { disc -> [Song] in
            (1...3).map { (track: Int) in
                song("\(disc)-\(track)", disc: disc, track: track,
                     format: disc == 5 ? .mp3 : .flac)
            }
        }
        let interleaved: [Song] = (1...3).flatMap { track in
            Array(expected.filter { $0.trackNumber == track }.reversed())
        }

        #expect(AlbumTrackOrder.sorted(interleaved).map(\.id) == expected.map(\.id))
        #expect(AlbumTrackOrder.sorted(Array(expected.reversed())).map(\.id) == expected.map(\.id))
    }

    @Test("Untagged and invalid disc numbers belong to disc one")
    func missingDiscNumbersDoNotSplitTheFirstDisc() {
        let input = [
            song("2-1", disc: 2, track: 1),
            song("1-4", disc: -1, track: 4),
            song("1-3", disc: 1, track: 3),
            song("1-2", disc: 0, track: 2),
            song("1-1", disc: nil, track: 1),
        ]

        #expect(AlbumTrackOrder.sorted(input).map(\.id) == ["1-1", "1-2", "1-3", "1-4", "2-1"])
        #expect(AlbumTrackOrder.sorted(input).map(AlbumTrackOrder.discNumber(for:)) == [1, 1, 1, 1, 2])
    }

    @Test("Missing or invalid track numbers follow numbered tracks within their disc")
    func unknownTrackNumbersStayOnTheirDisc() {
        let input = [
            song("missing", disc: 1, track: nil, title: "C"),
            song("2-1", disc: 2, track: 1),
            song("zero", disc: 1, track: 0, title: "A"),
            song("negative", disc: 1, track: -1, title: "B"),
            song("1-3", disc: 1, track: 3),
        ]

        #expect(AlbumTrackOrder.sorted(input).map(\.id) == ["1-3", "zero", "negative", "missing", "2-1"])
    }

    @Test("Duplicate tags have a stable natural-title and identity tie-breaker")
    func duplicateTagsDoNotDependOnScanOrder() {
        let input = [
            song("z", disc: 1, track: 1, title: "Take 10"),
            song("b", disc: 1, track: 1, title: "Take 2"),
            song("a", disc: 1, track: 1, title: "Take 2"),
        ]

        #expect(AlbumTrackOrder.sorted(input).map(\.id) == ["a", "b", "z"])
        #expect(AlbumTrackOrder.sorted(Array(input.reversed())).map(\.id) == ["a", "b", "z"])
    }

    @Test("A single disc keeps numeric order and sparse disc tags are preserved")
    func singleAndSparseDiscs() {
        let single = [10, 2, 1].map { (track: Int) in song("\(track)", disc: nil, track: track) }
        #expect(AlbumTrackOrder.sorted(single).map(\.id) == ["1", "2", "10"])
        let sparse = [song("4", disc: 4, track: 1), song("2", disc: 2, track: 1)]
        #expect(AlbumTrackOrder.sorted(sparse).map(\.discNumber) == [2, 4])
        #expect(AlbumTrackOrder.sorted([]).isEmpty)
    }

    private func song(
        _ id: String, disc: Int?, track: Int?, title: String? = nil,
        format: AudioFormat = .flac
    ) -> Song {
        Song(id: id, title: title ?? id, albumID: "album", trackNumber: track,
             discNumber: disc, fileFormat: format, filePath: "\(id).\(format.rawValue)",
             sourceID: "source")
    }
}
