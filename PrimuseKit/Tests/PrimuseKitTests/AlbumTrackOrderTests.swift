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

    @Test("Songs without a track tag follow the number their file names start with")
    func untaggedTracksUseFileNameNumbers() {
        let input = [
            song("b", disc: nil, track: nil, title: "Blue", path: "/Album/02 Blue.flac"),
            song("c", disc: nil, track: 3, title: "Always"),
            song("a", disc: nil, track: nil, title: "Zebra", path: "/Album/01. Zebra.flac"),
            song("d", disc: nil, track: nil, title: "Bonus", path: "/Album/Bonus.flac"),
            song("e", disc: nil, track: nil, title: "Coda", path: "/Album/1-10 Coda.flac"),
        ]
        #expect(AlbumTrackOrder.sorted(input).map(\.id) == ["a", "b", "c", "e", "d"])
        #expect(input.sorted(by: AlbumTrackOrder.isOrderedBefore).map(\.id) == ["a", "b", "c", "e", "d"])
    }

    @Test("File name track numbers", arguments: [
        ("03 Title.flac", 3), ("03. Title.flac", 3), ("03-Title.flac", 3), ("3_Title.flac", 3),
        ("1-03 Title.flac", 3), ("2.11 Title.flac", 11), ("07.flac", 7), ("/A/12 B/05 C.mp3", 5),
        ("(01) Title.flac", nil), ("1999 Title.flac", nil), ("4ever.flac", nil), ("00 Intro.flac", nil),
        ("Title 03.flac", nil), ("", nil),
    ] as [(String, Int?)])
    func fileNameTrackNumbers(_ path: String, _ expected: Int?) {
        #expect(AlbumTrackOrder.fileNameTrackNumber(path) == expected)
    }

    private func song(
        _ id: String, disc: Int?, track: Int?, title: String? = nil,
        format: AudioFormat = .flac, path: String? = nil
    ) -> Song {
        Song(id: id, title: title ?? id, albumID: "album", trackNumber: track,
             discNumber: disc, fileFormat: format, filePath: path ?? "\(id).\(format.rawValue)",
             sourceID: "source")
    }

    @Test("Ordering a folder by offsets gives the same IDs as ordering its songs")
    func sortedIDsMatchSortedSongs() {
        let titles = ["b", "A", "a", "c", "10 x", "2 x"]
        let library = (0..<120).map { index in
            Song(
                id: String(format: "id-%03d", 119 - index),
                title: titles[index % titles.count],
                trackNumber: index % 5 == 0 ? nil : (index % 7) - 1,
                discNumber: index % 9 == 0 ? 2 : (index % 4 == 0 ? nil : 1),
                fileFormat: .flac,
                filePath: index % 3 == 0 ? "/m/\(index % 11) Song.flac" : "/m/Song \(index).flac",
                sourceID: "s"
            )
        }
        for offsets in [Array(0..<120), Array((0..<120).reversed()), stride(from: 3, to: 120, by: 7).map { $0 }, [5], []] {
            #expect(
                AlbumTrackOrder.sortedIDs(at: offsets, in: library)
                    == AlbumTrackOrder.sorted(offsets.map { library[$0] }).map(\.id)
            )
        }
    }
}
