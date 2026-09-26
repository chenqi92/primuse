import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken-word books from badly tagged files")
struct SpokenWordBookGroupingRulesTests {
    private func item(
        _ id: String,
        title: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        artist: String? = nil,
        disc: Int? = nil,
        track: Int? = nil,
        path: String,
        source: String = "nas"
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: id,
            title: title ?? id,
            albumTitle: album,
            albumArtist: albumArtist,
            artist: artist,
            discNumber: disc,
            trackNumber: track,
            duration: 600,
            fileName: path,
            sourceID: source
        )
    }

    @Test("A different narrator per episode does not split the book")
    func trackArtistDoesNotSplit() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "三体", artist: "主播甲", track: 1, path: "a/1.mp3"),
            item("2", album: "三体", artist: "主播甲&主播乙", track: 2, path: "b/2.mp3"),
            item("3", album: "三体", artist: "主播乙", track: 3, path: "3.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].items.map(\.id) == ["1", "2", "3"])
        #expect(books[0].author == "主播甲")
    }

    @Test("Chapter numbering on the album is stripped")
    func numberedAlbums() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "三体 第01集", path: "x/1.mp3"),
            item("2", album: "三体 第02集", path: "y/2.mp3"),
            item("3", album: "三体-第十二集", path: "z/3.mp3"),
            item("4", album: "Dune 01", path: "p/4.mp3"),
            item("5", album: "Dune - Part 2", path: "q/5.mp3"),
            item("6", album: "Dune (3)", path: "r/6.mp3"),
            item("7", album: "Dune Chapter 4", path: "s/7.mp3"),
        ])
        #expect(books.count == 2)
        #expect(Set(books.map(\.title)) == ["三体", "Dune"])
    }

    @Test("Volume numbers are kept: they are separate books")
    func volumesStayApart() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "三体 第一部", path: "a/1.mp3"),
            item("2", album: "三体 第二部", path: "b/2.mp3"),
            item("3", album: "Book 2", path: "c/3.mp3"),
            item("4", album: "Room 101", path: "d/4.mp3"),
        ])
        #expect(books.count == 4)
        #expect(books.contains { $0.title == "Room 101" })
        #expect(books.contains { $0.title == "Book 2" })
    }

    @Test("Untagged files in one folder are one book named after the folder")
    func untaggedFolder() {
        let books = SpokenWordBookGrouping.books(from: [
            item("2", title: "002", path: "有声书/明朝那些事儿/002.mp3"),
            item("1", title: "001", path: "有声书/明朝那些事儿/001.mp3"),
            item("3", title: "003", path: "有声书/明朝那些事儿/003.mp3"),
            item("x", title: "001", path: "有声书/鬼吹灯/001.mp3"),
        ])
        #expect(books.count == 2)
        let ming = books.first { $0.title == "明朝那些事儿" }
        #expect(ming?.items.map(\.id) == ["1", "2", "3"])
    }

    @Test("A chapter title copied into the album counts as no album")
    func albumCopiesChapterTitle() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "第1章 科学边界", album: "第1章 科学边界", path: "三体/1.mp3"),
            item("2", title: "第2章 台球", album: "第2章 台球", path: "三体/2.mp3"),
            item("3", title: "03 射手和农场主", album: "03 射手和农场主", path: "三体/3.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].title == "三体")
    }

    @Test("An unnumbered single-file book whose album repeats its title stays itself")
    func singleFileBooks() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "Dune", album: "Dune", path: "Books/Dune.m4b"),
            item("2", title: "Emma", album: "Emma", path: "Books/Emma.m4b"),
        ])
        #expect(books.count == 2)
    }

    @Test("Untagged files join the one album their folder holds")
    func looseFilesJoinFolderAlbum() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "鬼吹灯", track: 1, path: "鬼吹灯/01.mp3"),
            item("2", album: "鬼吹灯", track: 2, path: "鬼吹灯/02.mp3"),
            item("3", title: "03", path: "鬼吹灯/03.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].title == "鬼吹灯")
        #expect(books[0].items.map(\.id) == ["1", "2", "3"])
    }

    @Test("A folder of several tagged books keeps them apart")
    func flatFolderOfBooks() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "Dune", track: 1, path: "Books/d1.mp3"),
            item("2", album: "Dune", track: 2, path: "Books/d2.mp3"),
            item("3", album: "Emma", track: 1, path: "Books/e1.mp3"),
            item("4", title: "loose", path: "Books/loose.mp3"),
        ])
        #expect(books.count == 3)
        #expect(books.first { $0.title == "Dune" }?.items.count == 2)
    }

    @Test("Album artists that differ inside one folder are still one book")
    func albumArtistVariantsInFolder() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "Dune", albumArtist: "Frank Herbert", track: 1, path: "Dune/1.mp3"),
            item("2", album: "Dune", albumArtist: "Frank Herbert; Scott Brick", track: 2, path: "Dune/2.mp3"),
            item("3", album: "Dune", track: 3, path: "Dune/3.mp3"),
        ])
        #expect(books.count == 1)
    }

    @Test("Items without an album artist take the only one their album has")
    func missingAlbumArtist() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "Dune", albumArtist: "Frank Herbert", path: "a/1.mp3"),
            item("2", album: "Dune", path: "b/2.mp3"),
        ])
        #expect(books.count == 1)
    }

    @Test("Disc folders count as their parent and order before tracks")
    func discFolders() {
        let books = SpokenWordBookGrouping.books(from: [
            item("d2t1", album: "Dune", track: 1, path: "Dune/CD2/01.mp3"),
            item("d1t2", album: "Dune", track: 2, path: "Dune/CD1/02.mp3"),
            item("d1t1", album: "Dune", track: 1, path: "Dune/CD1/01.mp3"),
            item("d2t2", title: "02", path: "Dune/Disc 2/02.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].items.map(\.id) == ["d1t1", "d1t2", "d2t1", "d2t2"])
    }

    @Test("The same folder path on two sources is two books")
    func sourcesSeparateFolders() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "001", path: "Book/001.mp3", source: "a"),
            item("2", title: "001", path: "Book/001.mp3", source: "b"),
        ])
        #expect(books.count == 2)
    }

    @Test("Files at a source's root with no album stand alone")
    func rootFilesStandAlone() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "001", path: "001.mp3"),
            item("2", title: "002", path: "002.mp3"),
        ])
        #expect(books.count == 2)
    }

    @Test("bookIDs agrees with the books")
    func bookIDsMatchBooks() {
        let items = [
            item("1", album: "鬼吹灯", path: "鬼吹灯/01.mp3"),
            item("2", title: "02", path: "鬼吹灯/02.mp3"),
            item("3", title: "x", path: "x.mp3"),
        ]
        let ids = SpokenWordBookGrouping.bookIDs(for: items)
        for book in SpokenWordBookGrouping.books(from: items) {
            for member in book.items { #expect(ids[member.id] == book.id) }
        }
    }

    @Test("A book tagged the plain way keeps the id it had before")
    func stableIDs() {
        let items = [
            item("1", album: "Dune", albumArtist: "Frank Herbert", path: "Dune/1.mp3"),
            item("2", album: "Dune", albumArtist: "Frank Herbert", path: "Dune/2.mp3"),
        ]
        #expect(SpokenWordBookGrouping.books(from: items).map(\.id) == ["book:dune\u{1F}frank herbert"])
    }
}
