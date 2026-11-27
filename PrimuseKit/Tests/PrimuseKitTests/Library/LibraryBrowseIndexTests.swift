import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library browse collation and album wall layout")
struct LibraryBrowseIndexTests {
    @Test("Latin, Chinese, Japanese and accented names share one A–Z sequence")
    func mixedScriptsInterleaveByReading() {
        #expect(LibraryCollationPolicy.indexLetter(for: "Beyond") == "B")
        #expect(LibraryCollationPolicy.indexLetter(for: "北京") == "B")
        #expect(LibraryCollationPolicy.indexLetter(for: "周杰伦") == "Z")
        #expect(LibraryCollationPolicy.indexLetter(for: "  élan") == "E")
        #expect(LibraryCollationPolicy.indexLetter(for: "Ｍｕｓｅ") == "M")
        #expect(LibraryCollationPolicy.indexLetter(for: "さくら") == "S")
        #expect(LibraryCollationPolicy.indexLetter(for: "Земфира") == "Z")
        #expect(LibraryCollationPolicy.indexLetter(for: "1989") == "#")
        #expect(LibraryCollationPolicy.indexLetter(for: "(Untitled)") == "#")
        #expect(LibraryCollationPolicy.indexLetter(for: "") == "#")

        let names = ["Zebra", "北京", "Beyond", "1989", "Abba", "陈奕迅", "Coldplay"]
        let sorted = names.sorted { LibraryCollationPolicy.key(for: $0) < LibraryCollationPolicy.key(for: $1) }
        #expect(sorted == ["Abba", "北京", "Beyond", "陈奕迅", "Coldplay", "Zebra", "1989"])
    }

    @Test("Artist order groups each artist's albums and orders them by release year")
    func artistOrderGroupsByArtistThenYear() {
        let albums = [
            album("jay-2", title: "叶惠美", artist: "周杰伦", year: 2003),
            album("adele-25", title: "25", artist: "Adele", year: 2015),
            album("jay-1", title: "范特西", artist: "周杰伦", year: 2001),
            album("jay-x", title: "Live", artist: "周杰伦", year: nil),
            album("adele-21", title: "21", artist: "Adele", year: 2011),
            album("unknown", title: "Demo", artist: "Unknown Artist", year: 1999),
            album("blur", title: "Parklife", artist: "Blur", year: 1994),
            album("beijing", title: "北京一夜", artist: "北京乐队", year: 1990),
        ]

        let layout = LibraryAlbumBrowseLayoutBuilder.layout(
            albums: albums,
            order: .artist,
            unknownArtistName: "Unknown Artist"
        )

        #expect(layout.items.map(\.id) == [
            "adele-21", "adele-25", "beijing", "blur", "jay-1", "jay-2", "jay-x", "unknown",
        ])
        #expect(layout.sections == [
            LibraryBrowseSection(bucket: "A", range: 0..<2),
            LibraryBrowseSection(bucket: "B", range: 2..<4),
            LibraryBrowseSection(bucket: "Z", range: 4..<7),
            LibraryBrowseSection(bucket: "#", range: 7..<8),
        ])
        #expect(layout.section(containing: 3)?.bucket == "B")
        #expect(layout.section(containing: 7)?.bucket == "#")
        #expect(layout.section(containing: 8) == nil)
        #expect(layout.section(forBucket: "Z")?.range.lowerBound == 4)
    }

    @Test("The liked wall keeps the order it is given and has no letter index")
    func likedOrderKeepsCallerOrder() {
        let albums = [
            album("b", title: "Zeta", artist: "Z", year: 2001),
            album("a", title: "Alpha", artist: "A", year: 1999),
        ]
        let layout = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .liked)
        #expect(layout.items.map(\.id) == ["b", "a"])
        #expect(layout.sections.isEmpty)
        #expect(!LibraryAlbumBrowseOrder.liked.hasLetterIndex)
    }

    @Test("Homophone artists stay in separate runs")
    func homophoneArtistsDoNotInterleave() {
        let albums = [
            album("a1", title: "One", artist: "陈", year: 2001),
            album("b1", title: "Two", artist: "晨", year: 2000),
            album("a2", title: "Three", artist: "陈", year: 2005),
            album("b2", title: "Four", artist: "晨", year: 2004),
        ]
        let ids = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .artist).items.map(\.id)
        let artistRuns = ids.map { $0.prefix(1) }
        #expect(artistRuns == ["a", "a", "b", "b"] || artistRuns == ["b", "b", "a", "a"])
    }

    @Test("Title, year and recently-added orders")
    func otherOrders() {
        let albums = [
            album("t", title: "The Wall", artist: "Pink Floyd", year: 1979),
            album("h", title: "红豆", artist: "王菲", year: 1998),
            album("n", title: "1999", artist: "Prince", year: nil),
            album("a", title: "Abbey Road", artist: "The Beatles", year: 1969),
        ]

        let title = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .title)
        #expect(title.items.map(\.id) == ["a", "h", "t", "n"])
        #expect(title.sections.map(\.bucket) == ["A", "H", "T", "#"])

        let year = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .year)
        #expect(year.items.map(\.id) == ["h", "t", "a", "n"])
        #expect(year.sections == [
            LibraryBrowseSection(bucket: "decade-1990", range: 0..<1),
            LibraryBrowseSection(bucket: "decade-1970", range: 1..<2),
            LibraryBrowseSection(bucket: "decade-1960", range: 2..<3),
            LibraryBrowseSection(bucket: "unknown", range: 3..<4),
        ])

        let now = Date()
        let songs = [
            song("s1", albumID: "a", added: now.addingTimeInterval(-300)),
            song("s2", albumID: "t", added: now),
            song("s3", albumID: "h", added: now.addingTimeInterval(-60)),
        ]
        let recent = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .recentlyAdded, songs: songs)
        #expect(recent.items.map(\.id) == ["t", "h", "a", "n"])
        #expect(recent.sections.isEmpty)
    }

    @Test("The year wall runs newest first in decade sections; odd years count as unknown")
    func yearWallSections() {
        let albums = [
            album("b", title: "B", artist: "Blur", year: 1994),
            album("a", title: "A", artist: "Adele", year: 1994),
            album("c", title: "C", artist: "Coldplay", year: 2000),
            album("d", title: "D", artist: "Dido", year: 1999),
            album("m", title: "M", artist: "Miles", year: 1959),
            album("x", title: "X", artist: "Xiu", year: nil),
            album("y", title: "Y", artist: "Yes", year: 98),
            album("z", title: "Z", artist: "Zed", year: 20150101),
        ]
        let layout = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .year, currentYear: 2026)
        #expect(layout.items.map(\.id) == ["c", "d", "a", "b", "m", "x", "y", "z"])
        #expect(layout.sections == [
            LibraryBrowseSection(bucket: "decade-2000", range: 0..<1),
            LibraryBrowseSection(bucket: "decade-1990", range: 1..<4),
            LibraryBrowseSection(bucket: "earlier", range: 4..<5),
            LibraryBrowseSection(bucket: "unknown", range: 5..<8),
        ])
        #expect(ReleaseDateBrowseLayout.Era(id: "decade-1990") == .decade(1990))
        #expect(ReleaseDateBrowseLayout.Era(id: "unknown") == .unknown)
        #expect(ReleaseDateBrowseLayout.Era(id: "A") == nil)
    }

    @Test("Artist wall sorts by reading and keeps the unknown artist last")
    func artistWallLayout() {
        let artists = [
            Artist(id: "u", name: "未知艺术家"),
            Artist(id: "z", name: "张学友"),
            Artist(id: "a", name: "Adele"),
            Artist(id: "w", name: "王菲"),
        ]
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: artists, unknownArtistName: "未知艺术家")
        #expect(layout.items.map(\.id) == ["a", "w", "z", "u"])
        #expect(layout.sections.map(\.bucket) == ["A", "W", "Z", "#"])
    }

    @Test("Song list sorts by title reading, then artist, with untitled songs last")
    func songListLayout() {
        let songs = [
            titledSong("blank", title: "  ", artist: "X"),
            titledSong("ye2", title: "夜曲", artist: "周杰伦"),
            titledSong("hey", title: "Hey Jude", artist: "The Beatles"),
            titledSong("ye1", title: "夜曲", artist: "Chopin"),
            titledSong("num", title: "1979", artist: "Smashing Pumpkins"),
            titledSong("hai", title: "海阔天空", artist: "Beyond"),
        ]
        let layout = LibrarySongBrowseLayoutBuilder.layout(songs: songs)
        #expect(layout.items == ["hai", "hey", "ye1", "ye2", "num", "blank"])
        #expect(layout.sections.map(\.bucket) == ["H", "Y", "#"])
        #expect(layout.section(forBucket: "Y")?.range == 2..<4)
        #expect(
            LibrarySongBrowseLayoutBuilder.fingerprint(songs: songs)
                != LibrarySongBrowseLayoutBuilder.fingerprint(songs: Array(songs.dropLast()))
        )
    }

    @Test("Stored order falls back to the TV default")
    func storedOrderFallsBack() {
        #expect(LibraryAlbumBrowseOrder.resolved("title") == .title)
        #expect(LibraryAlbumBrowseOrder.resolved("") == .artist)
        #expect(LibraryAlbumBrowseOrder.resolved("retired") == .artist)
        #expect(LibraryAlbumBrowseOrder.artist.hasLetterIndex)
        #expect(!LibraryAlbumBrowseOrder.year.hasLetterIndex)
    }

    private func album(_ id: String, title: String, artist: String, year: Int?) -> Album {
        Album(id: id, title: title, artistName: artist, year: year)
    }

    private func titledSong(_ id: String, title: String, artist: String) -> Song {
        Song(id: id, title: title, artistName: artist, fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: "source")
    }

    private func song(_ id: String, albumID: String, added: Date) -> Song {
        Song(
            id: id,
            title: id,
            albumID: albumID,
            fileFormat: .mp3,
            filePath: "/\(id).mp3",
            sourceID: "source",
            dateAdded: added
        )
    }
}

@Suite("Library browse window arithmetic")
struct LibraryBrowseWindowTests {
    // A: 0..<10, B: 10..<11, C: 11..<200
    private let sections = [
        LibraryBrowseSection(bucket: "A", range: 0..<10),
        LibraryBrowseSection(bucket: "B", range: 10..<11),
        LibraryBrowseSection(bucket: "C", range: 11..<200),
    ]

    @Test("Window starts stay on whole rows of their own section")
    func rowAlignment() {
        let c = sections[2]
        #expect(LibraryBrowseWindow.rowAligned(11, in: c, columns: 4) == 11)
        #expect(LibraryBrowseWindow.rowAligned(14, in: c, columns: 4) == 11)
        #expect(LibraryBrowseWindow.rowAligned(15, in: c, columns: 4) == 15)
        #expect(LibraryBrowseWindow.rowAligned(5, in: c, columns: 4) == 11)
    }

    @Test("Revealing earlier content lands on the same column of the row just above")
    func earlierWindowTargetsSameColumn() {
        // Window starts at C's row 11+40=51; the user was on the third column of that row.
        let deep = LibraryBrowseWindow.earlierWindow(
            before: 51, sections: sections, columns: 4, pageSize: 60, focusedIndex: 53
        )
        #expect(deep.start == 11)
        #expect(deep.target == 49)

        // Window starts at C itself; the row above is B's single-card row.
        let short = LibraryBrowseWindow.earlierWindow(
            before: 11, sections: sections, columns: 4, pageSize: 60, focusedIndex: 13
        )
        #expect(short.start == 10)
        #expect(short.target == 10)

        // From B back into A: A's last row only holds 8 and 9.
        let partial = LibraryBrowseWindow.earlierWindow(
            before: 10, sections: sections, columns: 4, pageSize: 60, focusedIndex: 10
        )
        #expect(partial.start == 0)
        #expect(partial.target == 8)
        let clamped = LibraryBrowseWindow.earlierWindow(
            before: 10, sections: sections, columns: 4, pageSize: 60, focusedIndex: 14
        )
        #expect(clamped.target == 9)
        let unfocused = LibraryBrowseWindow.earlierWindow(
            before: 10, sections: sections, columns: 4, pageSize: 60, focusedIndex: nil
        )
        #expect(unfocused.target == 8)
    }

    @Test("Large sections reveal one page at a time")
    func earlierWindowPagesWithinSection() {
        let reveal = LibraryBrowseWindow.earlierWindow(
            before: 191, sections: sections, columns: 4, pageSize: 60, focusedIndex: 194
        )
        #expect(reveal.start == 131)
        #expect(reveal.target == 190)
    }

    @Test("Restoring an anchor starts about half a page before it")
    func anchorWindow() {
        let restored = LibraryBrowseWindow.start(revealing: 150, sections: sections, columns: 4, pageSize: 60)
        #expect(restored?.section.bucket == "C")
        #expect(restored?.start == 119)
        let nearTop = LibraryBrowseWindow.start(revealing: 12, sections: sections, columns: 4, pageSize: 60)
        #expect(nearTop?.start == 11)
        #expect(LibraryBrowseWindow.start(revealing: 5, sections: [], columns: 4, pageSize: 60) == nil)
    }
}

@Suite("Library index rail")
struct LibraryIndexRailModelTests {
    @Test("Every letter gets a cell; empty letters jump to the next section and # follows Z")
    func entriesCoverTheWholeAlphabet() {
        let artists = [
            Artist(id: "adele", name: "Adele"),
            Artist(id: "abba", name: "ABBA"),
            Artist(id: "beijing", name: "北京乐队"),
            Artist(id: "beyond", name: "Beyond"),
            Artist(id: "jay", name: "周杰伦"),
            Artist(id: "1989", name: "1989"),
        ]
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: artists)
        let model = LibraryIndexRailModel(sections: layout.sections)

        #expect(model.entries.map(\.label) == LibraryCollationPolicy.letterBuckets + ["#"])
        #expect(model.isUseful)
        let byLabel = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.label, $0) })
        #expect(byLabel["A"] == LibraryIndexRailEntry(label: "A", target: 0, count: 2))
        #expect(byLabel["B"] == LibraryIndexRailEntry(label: "B", target: 2, count: 2))
        #expect(byLabel["C"] == LibraryIndexRailEntry(label: "C", target: 4, count: 0))
        #expect(byLabel["Z"] == LibraryIndexRailEntry(label: "Z", target: 4, count: 1))
        #expect(byLabel["#"] == LibraryIndexRailEntry(label: "#", target: 5, count: 1))
        #expect(layout.items[4].id == "jay")
    }

    @Test("Letters after the last section fall back to it")
    func trailingEmptyLettersJumpBack() {
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: [
            Artist(id: "a", name: "Adele"),
            Artist(id: "m", name: "Muse"),
        ])
        let model = LibraryIndexRailModel(sections: layout.sections)
        #expect(model.entries.count == 26)
        #expect(model.entries.last == LibraryIndexRailEntry(label: "Z", target: 1, count: 0))
    }

    @Test("A list position maps back to its letter")
    func currentLetterFollowsTheTopRow() {
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: [
            Artist(id: "a1", name: "Adele"),
            Artist(id: "a2", name: "Air"),
            Artist(id: "b1", name: "Blur"),
            Artist(id: "d1", name: "Daft Punk"),
            Artist(id: "d2", name: "Doves"),
        ])
        let model = LibraryIndexRailModel(sections: layout.sections)
        #expect(model.label(containing: 0) == "A")
        #expect(model.label(containing: 2) == "B")
        #expect(model.label(containing: 4) == "D")
        #expect(model.label(containing: 3) == "D")
        #expect(model.label(containing: -1) == "A")
    }

    @Test("A single letter or a year layout is not worth a rail")
    func railNeedsTwoLetters() {
        let single = LibraryArtistBrowseLayoutBuilder.layout(artists: [
            Artist(id: "a1", name: "Adele"),
            Artist(id: "a2", name: "Air"),
        ])
        #expect(!LibraryIndexRailModel(sections: single.sections).isUseful)

        let albums = [
            Album(id: "old", title: "Old", artistName: "A", year: 1975),
            Album(id: "new", title: "New", artistName: "B", year: 2021),
        ]
        let byYear = LibraryAlbumBrowseLayoutBuilder.layout(albums: albums, order: .year, currentYear: 2026)
        let model = LibraryIndexRailModel(sections: byYear.sections)
        #expect(model.entries.isEmpty)
        #expect(!model.isUseful)
    }

    @Test("Filtering keeps letters contiguous and drops emptied ones")
    func filteredSectionsFollowKeptRows() {
        let sections = [
            LibraryBrowseSection(bucket: "A", range: 0..<3),
            LibraryBrowseSection(bucket: "B", range: 3..<5),
            LibraryBrowseSection(bucket: "C", range: 5..<8),
        ]
        let kept = LibraryBrowseLayout<String>.sections(sections, keeping: [1, 2, 6, 7])
        #expect(kept == [
            LibraryBrowseSection(bucket: "A", range: 0..<2),
            LibraryBrowseSection(bucket: "C", range: 2..<4),
        ])
        #expect(LibraryBrowseLayout<String>.sections(sections, keeping: []).isEmpty)
        #expect(LibraryBrowseLayout<String>.sections(sections, keeping: [2, 1]).isEmpty)
        #expect(LibraryBrowseLayout<String>.sections(sections, keeping: [9]).isEmpty)
    }

    @Test("Song entries carry counts and dim letters without songs")
    func songEntriesCarryCounts() {
        let snapshot = SongListSnapshotBuilder.build(
            songs: [
                Song(id: "a1", title: "Atlas", fileFormat: .mp3, filePath: "/a1.mp3", sourceID: "s"),
                Song(id: "a2", title: "Aurora", fileFormat: .mp3, filePath: "/a2.mp3", sourceID: "s"),
                Song(id: "d1", title: "Drift", fileFormat: .mp3, filePath: "/d1.mp3", sourceID: "s"),
            ],
            order: .title
        )
        #expect(snapshot.sectionIndexEntries.first { $0.label == "B" }?.isAvailable == false)
        #expect(snapshot.sectionIndexEntries.first { $0.label == "D" }?.isAvailable == true)

        let model = LibraryIndexRailModel(songEntries: snapshot.sectionIndexEntries, rowCount: 3)
        let byLabel = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.label, $0) })
        #expect(byLabel["A"]?.count == 2)
        #expect(byLabel["B"]?.count == 0)
        #expect(byLabel["B"]?.target == 2)
        #expect(byLabel["D"]?.count == 1)
        #expect(model.label(containing: 1) == "A")
        #expect(model.label(containing: 2) == "D")

        let descending = SongListSnapshotBuilder.build(
            songs: [
                Song(id: "a1", title: "Atlas", fileFormat: .mp3, filePath: "/a1.mp3", sourceID: "s"),
                Song(id: "d1", title: "Drift", fileFormat: .mp3, filePath: "/d1.mp3", sourceID: "s"),
            ],
            order: .titleDescending
        )
        let reversed = LibraryIndexRailModel(songEntries: descending.sectionIndexEntries, rowCount: 2)
        #expect(reversed.entries.first?.label == "Z")
        #expect(reversed.label(containing: 0) == "D")
        #expect(reversed.label(containing: 1) == "A")
    }
}
