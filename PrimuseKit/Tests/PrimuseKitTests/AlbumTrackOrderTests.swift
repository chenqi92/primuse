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

    @Test("A folder holding files renamed from another release goes by file name")
    func folderWithRenamedFilesFollowsNames() {
        let folder = "/有声书/仙界篇-关彦之/1-500/"
        let songs = [
            song("201", disc: nil, track: 201, title: "第201集 线索（1）", path: folder + "关彦之 - 第201集 线索（1）_HQ.mp3"),
            song("202", disc: nil, track: 202, title: "第202集 线索（2）", path: folder + "关彦之 - 第202集 线索（2）_HQ.mp3"),
            // Copied from the omnibus edition and renamed; its tags still count that edition.
            song("1", disc: nil, track: 4969, title: "第4969集 狐女1 (凡人仙界篇)", path: folder + "关彦之 - 第1集 狐女（1）_HQ.mp3"),
            song("2", disc: nil, track: 4970, title: "第4970集 狐女2 (凡人仙界篇)", path: folder + "关彦之 - 第2集 狐女（2）_HQ.mp3"),
            song("203", disc: nil, track: 203, title: "第203集 天选", path: folder + "关彦之 - 第203集 天选_HQ.mp3"),
        ]
        #expect(LibraryFolderTrackOrder.sorted(songs).map(\.id) == ["1", "2", "201", "202", "203"])
        #expect(LibraryFolderTrackOrder.sortedIDs(at: [4, 0, 3, 2, 1], in: songs) == ["1", "2", "201", "202", "203"])
        #expect(LibraryFolderBrowsePolicy.sortedSongs(songs).map(\.id) == ["1", "2", "201", "202", "203"])

        // Names and tags that agree throughout, or a folder renumbered
        // throughout, keep track order.
        let agreeing = Array(songs.filter { $0.id.count == 3 }.reversed())
        #expect(LibraryFolderTrackOrder.sorted(agreeing).map(\.id) == AlbumTrackOrder.sorted(agreeing).map(\.id))
        let renumbered = [
            song("b", disc: nil, track: 2, title: "第2集", path: "/书/第101集.mp3"),
            song("a", disc: nil, track: 1, title: "第1集", path: "/书/第102集.mp3"),
        ]
        #expect(LibraryFolderTrackOrder.sorted(renumbered).map(\.id) == ["a", "b"])
        #expect(LibraryFolderTrackOrder.sortedIDs(at: [0, 1], in: renumbered) == ["a", "b"])
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

    @Test("Folder pages keep track order unless the user picked a song-list sort")
    func folderSongOrderFollowsTheStoredChoice() throws {
        let songs = [
            song("t2", disc: 1, track: 2, title: "Alpha"),
            song("t3", disc: 1, track: 3, title: "Bravo"),
            song("t1", disc: 1, track: 1, title: "Charlie"),
        ]
        #expect(LibraryFolderBrowsePolicy.sortedSongs(songs, order: .trackOrder).map(\.id) == ["t1", "t2", "t3"])
        #expect(LibraryFolderBrowsePolicy.sortedSongs(songs, order: .sorted(.title)).map(\.id) == ["t2", "t3", "t1"])
        #expect(LibraryFolderBrowsePolicy.sortedSongs(songs, order: .sorted(.titleDescending)).map(\.id) == ["t1", "t3", "t2"])

        #expect(HomeFolderSongOrder(storageValue: "") == .trackOrder)
        #expect(HomeFolderSongOrder(storageValue: "nonsense") == .trackOrder)
        #expect(HomeFolderSongOrder(storageValue: "artistDescending") == .sorted(.artistDescending))
        // Sorts that need play counts or download state are not offered for folders.
        #expect(HomeFolderSongOrder(storageValue: "playCountDescending") == .trackOrder)
        #expect(HomeFolderSongOrder(storageValue: "downloadedFirst") == .trackOrder)
        for order in [HomeFolderSongOrder.trackOrder, .sorted(.album), .sorted(.dateAddedOldest)] {
            #expect(HomeFolderSongOrder(storageValue: order.storageValue) == order)
        }

        let suiteName = "HomeFolderSongOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(HomeFolderSongOrderPreference.load(from: defaults) == .trackOrder)
        defaults.set("format", forKey: HomeFolderSongOrderPreference.storageKey)
        #expect(HomeFolderSongOrderPreference.load(from: defaults) == .sorted(.format))
    }

    @Test("Choosing a folder sort never flips the direction by itself")
    func folderSongOrderSelection() {
        let byTitle = HomeFolderSongOrder.trackOrder.selecting(.title)
        #expect(byTitle == .sorted(.title))
        // Picking the current criterion again keeps it as it is.
        #expect(byTitle.selecting(.title) == .sorted(.title))
        // Newest first is the natural start for dates.
        #expect(byTitle.selecting(.dateAdded) == .sorted(.dateAdded))
        #expect(byTitle.selecting(nil) == .trackOrder)
        #expect(byTitle.criterion == .title)
        #expect(HomeFolderSongOrder.trackOrder.criterion == nil)
        #expect(HomeFolderSongOrder.trackOrder.listOrder == nil)
        #expect(HomeFolderSongOrder.sorted(.albumDescending).listOrder == .albumDescending)

        #expect(byTitle.withAscending(false) == .sorted(.titleDescending))
        #expect(byTitle.withAscending(true) == .sorted(.title))
        #expect(HomeFolderSongOrder.trackOrder.withAscending(false) == .trackOrder)
    }
}
