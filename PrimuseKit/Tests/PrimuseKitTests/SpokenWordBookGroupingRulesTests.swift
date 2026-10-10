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

    // MARK: Two recordings of one book

    @Test("Two recordings in their own folders, tagged alike, are two books")
    func versionsInFoldersSplit() {
        let books = SpokenWordBookGrouping.books(from: [
            item("a1", title: "第1集", album: "三体", albumArtist: "刘慈欣", track: 1, path: "三体 张三版/01.mp3"),
            item("a2", title: "第2集", album: "三体", albumArtist: "刘慈欣", track: 2, path: "三体 张三版/02.mp3"),
            item("a3", title: "第3集", album: "三体", albumArtist: "刘慈欣", track: 3, path: "三体 张三版/03.mp3"),
            item("b1", title: "第1集", album: "三体", albumArtist: "刘慈欣", track: 1, path: "李四演播/01.mp3"),
            item("b2", title: "第2集", album: "三体", albumArtist: "刘慈欣", track: 2, path: "李四演播/02.mp3"),
        ])
        #expect(books.count == 2)
        let larger = books.first { $0.items.count == 3 }
        let smaller = books.first { $0.items.count == 2 }
        #expect(larger?.items.map(\.id) == ["a1", "a2", "a3"])
        #expect(smaller?.items.map(\.id) == ["b1", "b2"])
        // The part with the larger folder keeps the id the whole book had.
        #expect(larger?.id == "book:三体\u{1F}刘慈欣")
        #expect(larger?.title == "三体 张三版")
        #expect(smaller?.title == "三体 \u{00B7} 李四演播")
    }

    @Test("Recordings without track numbers clash on their episode titles")
    func versionsWithoutTracksSplit() {
        let books = SpokenWordBookGrouping.books(from: [
            item("a1", title: "第一回", album: "红楼梦", path: "A/1.mp3"),
            item("a2", title: "第二回", album: "红楼梦", path: "A/2.mp3"),
            item("b1", title: "第一回", album: "红楼梦", path: "B/1.mp3"),
            item("b2", title: "第二回", album: "红楼梦", path: "B/2.mp3"),
        ])
        #expect(books.count == 2)
    }

    @Test("Folders that continue the numbering stay one book")
    func continuingFoldersStay() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "三体", track: 1, path: "三体/001-002/1.mp3"),
            item("2", album: "三体", track: 2, path: "三体/001-002/2.mp3"),
            item("3", album: "三体", track: 3, path: "三体/003-004/3.mp3"),
            item("4", album: "三体", track: 4, path: "三体/003-004/4.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].items.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test("Volumes told apart by disc number stay one book")
    func discTaggedVolumesStay() {
        let books = SpokenWordBookGrouping.books(from: [
            item("v1c1", title: "第一章", album: "Dune", disc: 1, track: 1, path: "Dune/Vol 1/1.mp3"),
            item("v1c2", title: "第二章", album: "Dune", disc: 1, track: 2, path: "Dune/Vol 1/2.mp3"),
            item("v2c1", title: "第一章", album: "Dune", disc: 2, track: 1, path: "Dune/Vol 2/1.mp3"),
            item("v2c2", title: "第二章", album: "Dune", disc: 2, track: 2, path: "Dune/Vol 2/2.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books[0].items.map(\.id) == ["v1c1", "v1c2", "v2c1", "v2c2"])
    }

    @Test("A single stray copy elsewhere does not split the book")
    func strayCopyStays() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", album: "Dune", track: 1, path: "Dune/1.mp3"),
            item("2", album: "Dune", track: 2, path: "Dune/2.mp3"),
            item("3", album: "Dune", track: 3, path: "Dune/3.mp3"),
            item("copy", album: "Dune", track: 1, path: "Downloads/1.mp3"),
        ])
        #expect(books.count == 1)
    }

    @Test("Bare-number titles are no place: range folders restarting 01 stay whole")
    func bareNumberTitlesStay() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "01", album: "鬼吹灯", path: "鬼吹灯/1-2/01.mp3"),
            item("2", title: "02", album: "鬼吹灯", path: "鬼吹灯/1-2/02.mp3"),
            item("3", title: "01", album: "鬼吹灯", path: "鬼吹灯/3-4/01.mp3"),
            item("4", title: "02", album: "鬼吹灯", path: "鬼吹灯/3-4/02.mp3"),
        ])
        #expect(books.count == 1)
    }

    @Test("Untagged episodes of each recording follow their own folder")
    func looseEpisodesFollowTheirFolder() {
        let books = SpokenWordBookGrouping.books(from: [
            item("a1", title: "第1集", album: "三体", track: 1, path: "A/01.mp3"),
            item("a2", title: "第2集", album: "三体", track: 2, path: "A/02.mp3"),
            item("a3", title: "第3集", path: "A/03.mp3"),
            item("b1", title: "第1集", album: "三体", track: 1, path: "B/01.mp3"),
            item("b2", title: "第2集", album: "三体", track: 2, path: "B/02.mp3"),
            item("b3", title: "第3集", path: "B/03.mp3"),
        ])
        #expect(books.count == 2)
        #expect(Set(books.map { Set($0.items.map(\.id)) }) == [["a1", "a2", "a3"], ["b1", "b2", "b3"]])
    }

    @Test("bookIDs agrees with split books")
    func splitBookIDsMatchBooks() {
        let items = [
            item("a1", title: "第1集", album: "三体", track: 1, path: "A/01.mp3"),
            item("a2", title: "第2集", album: "三体", track: 2, path: "A/02.mp3"),
            item("b1", title: "第1集", album: "三体", track: 1, path: "B/01.mp3"),
            item("b2", title: "第2集", album: "三体", track: 2, path: "B/02.mp3"),
        ]
        let ids = SpokenWordBookGrouping.bookIDs(for: items)
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(Set(books.map(\.id)).count == 2)
        for book in books {
            for member in book.items { #expect(ids[member.id] == book.id) }
        }
    }

    // MARK: Server catalogues

    @Test("A server catalogue's made-up paths are no folder")
    func catalogPathsNameNoFolder() {
        let items = [
            item("1", album: "三体", albumArtist: "张三", track: 1, path: "/songs/aa1.mp3", source: "navidrome"),
            item("2", album: "三体", albumArtist: "李四", track: 1, path: "/songs/bb2.mp3", source: "navidrome"),
            item("3", title: "访谈", path: "/songs/cc3.mp3", source: "navidrome"),
            item("4", title: "花絮", path: "/songs/dd4.mp3", source: "navidrome"),
        ]
        // Taken as a folder, the made-up `/songs` joins the two recordings and
        // every untagged item.
        let asFolder = SpokenWordBookGroupingRules.assign(items, catalogSourceIDs: [])
        #expect(asFolder.bookIDs["1"] == asFolder.bookIDs["2"])
        #expect(asFolder.bookIDs["3"] == asFolder.bookIDs["4"])

        let asCatalogue = SpokenWordBookGroupingRules.assign(items, catalogSourceIDs: ["navidrome"])
        #expect(asCatalogue.bookIDs["1"] != asCatalogue.bookIDs["2"])
        #expect(asCatalogue.bookIDs["3"] != asCatalogue.bookIDs["4"])
        #expect(asCatalogue.bookIDs["1"] == "book:三体\u{1F}张三")
    }

    @Test("A server catalogue's chapters go by title, not by item id")
    func catalogueChaptersFollowTitles() {
        let items = [
            item("1", title: "10 终章", album: "三体", path: "/songs/0f3a.mp3", source: "navidrome"),
            item("2", title: "02 疯狂年代", album: "三体", path: "/songs/9c1d.mp3", source: "navidrome"),
            item("3", title: "01 科学边界", album: "三体", path: "/songs/d27e.mp3", source: "navidrome"),
        ]
        let catalogue = SpokenWordBookGrouping.books(from: items, catalogSourceIDs: ["navidrome"])
        #expect(catalogue.count == 1)
        #expect(catalogue.first?.items.map(\.id) == ["3", "2", "1"])

        // A real path still decides first.
        let nas = [
            item("a", title: "第二章", album: "球状闪电", path: "/书/01.mp3"),
            item("b", title: "第一章", album: "球状闪电", path: "/书/02.mp3"),
        ]
        let byPath = SpokenWordBookGrouping.books(from: nas, catalogSourceIDs: ["navidrome"])
        #expect(byPath.first?.items.map(\.id) == ["a", "b"])
    }

    @Test("A server catalogue's untracked chapter sorts by its numbered title, not last")
    func catalogueUntrackedChapterFollowsTitles() {
        let items = [
            item("15", title: "1-5", album: "长夜", track: 1, path: "/songs/77.mp3", source: "navidrome"),
            item("36", title: "3-6", album: "长夜", track: 3, path: "/songs/12.mp3", source: "navidrome"),
            item("01", title: "0-1", album: "长夜", path: "/songs/9a.mp3", source: "navidrome"),
            item("21", title: "2-1", album: "长夜", track: 2, path: "/songs/c4.mp3", source: "navidrome"),
        ]
        let books = SpokenWordBookGrouping.books(from: items, catalogSourceIDs: ["navidrome"])
        #expect(books.count == 1)
        #expect(books.first?.items.map(\.id) == ["01", "15", "21", "36"])
    }

    @Test("Range and disc folders still order a book that goes by its names")
    func foldersOrderBeforeNames() {
        let books = SpokenWordBookGrouping.books(from: [
            item("b1", album: "鬼吹灯", path: "鬼吹灯/Disc 2/第1集.mp3"),
            item("a2", album: "鬼吹灯", track: 2, path: "鬼吹灯/CD 1/第2集.mp3"),
            item("a1", album: "鬼吹灯", path: "鬼吹灯/CD 1/第1集.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books.first?.items.map(\.id) == ["a1", "a2", "b1"])
    }

    @Test("Only catalogue sources lose their folders")
    func catalogueSetIsPerSource() {
        let items = [
            item("1", title: "访谈", path: "/songs/a.mp3", source: "nas"),
            item("2", title: "花絮", path: "/songs/b.mp3", source: "nas"),
        ]
        let grouped = SpokenWordBookGroupingRules.assign(items, catalogSourceIDs: ["navidrome"])
        #expect(grouped.bookIDs["1"] == grouped.bookIDs["2"])
    }

    @Test("Which source types make their paths up")
    func catalogueSourceTypes() {
        #expect(!MusicSourceType.navidrome.itemPathsNameFolders)
        #expect(!MusicSourceType.jellyfin.itemPathsNameFolders)
        #expect(!MusicSourceType.synologyAudioStation.itemPathsNameFolders)
        #expect(MusicSourceType.audiobookshelf.itemPathsNameFolders)
        #expect(MusicSourceType.tingReader.itemPathsNameFolders)
        #expect(MusicSourceType.webdav.itemPathsNameFolders)
        #expect(MusicSourceType.smb.itemPathsNameFolders)
    }

    // MARK: Files renamed after tagging

    @Test("A file renamed after tagging is told by its name and its numbered title disagreeing")
    func renamedFileDetection() {
        func chapter(_ title: String, _ path: String) -> Int? {
            SpokenWordBookGroupingRules.renamedChapter(of: item("x", title: title, path: path))
        }
        #expect(chapter("第4969集 狐女1 (凡人仙界篇)", "书/关彦之 - 第1集 狐女（1）_HQ.mp3") == 1)
        #expect(chapter("第４９６９集", "书/第１集.mp3") == 1)
        #expect(chapter("第201集 线索（1）", "书/关彦之 - 第201集 线索（1）_HQ.mp3") == nil)
        #expect(chapter("第3集", "书/第003集.mp3") == nil)
        // Different counters, or a number on one side only, say nothing.
        #expect(chapter("第1章 开端", "书/第12集.mp3") == nil)
        #expect(chapter("狐女", "书/第1集 狐女.mp3") == nil)
        #expect(chapter("第1集", "书/01.mp3") == nil)
    }

    @Test("Files renamed from another release join their folder's book, in file order")
    func renamedFilesJoinTheirFolder() {
        let single = "凡人修仙传之仙界篇|关彦之", omnibus = "凡人修仙传|精编版|关彦之"
        var items: [SpokenWordBookItem] = []
        for number in 1...6 {
            // The single edition; chapters 1, 2, 5 and 6 are files copied from
            // the omnibus and renamed, their tags left as they were.
            let renamed = number != 3 && number != 4
            let folder = number <= 4 ? "1-4" : "5-8"
            items.append(item(
                "s\(number)",
                title: renamed ? "第\(4968 + number)集 (凡人仙界篇)" : "第\(number)集",
                album: renamed ? omnibus : single, artist: "关彦之",
                track: renamed ? 4968 + number : number,
                path: "有声书/仙界篇-关彦之/\(folder)/关彦之 - 第\(number)集_HQ.mp3"
            ))
        }
        for number in 4969...4974 {
            items.append(item(
                "o\(number)", title: "第\(number)集 (凡人仙界篇)", album: omnibus, artist: "关彦之", track: number,
                path: "有声书/凡人修仙传-关彦之/4501-5000/第\(number)集 (凡人仙界篇).mp3"
            ))
        }
        // A theme song beside the range folders is an album of its own and
        // draws none of the renamed chapters.
        items.append(item("theme", title: "主题曲《归仙》", album: "归仙", path: "有声书/仙界篇-关彦之/主题曲.mp3"))
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(books.count == 3)
        #expect(books.first { $0.items.contains { $0.id == "theme" } }?.items.count == 1)
        let singleBook = books.first { $0.items.contains { $0.id == "s3" } }
        #expect(singleBook?.items.map(\.id) == ["s1", "s2", "s3", "s4", "s5", "s6"])
        #expect(singleBook?.title == "凡人修仙传之仙界篇|关彦之")
        let omnibusBook = books.first { $0.items.contains { $0.id == "o4969" } }
        #expect(omnibusBook?.items.map(\.id) == ["o4969", "o4970", "o4971", "o4972", "o4973", "o4974"])
        #expect(omnibusBook?.title == omnibus)
        #expect(SpokenWordBookGrouping.bookIDs(for: items)["s1"] == singleBook?.id)
    }

    @Test("Renamed files follow only an album whose chapters their folder confirms")
    func renamedFilesNeedConfirmedChapters() {
        let books = SpokenWordBookGrouping.books(from: [
            item("theme", title: "主题曲", album: "归仙", path: "书/主题曲.mp3"),
            item("1", title: "第4969集", album: "合集", track: 4969, path: "书/第1集.mp3"),
            item("2", title: "第4970集", album: "合集", track: 4970, path: "书/第2集.mp3"),
        ])
        #expect(books.count == 2)
        #expect(books.first { $0.items.contains { $0.id == "1" } }?.items.map(\.id) == ["1", "2"])
    }

    @Test("A shorter album tag and untagged files still join the folder's book")
    func decoratedTitlesAndUntaggedFilesJoin() {
        let longAlbum = "凡人修仙传之仙界篇|关彦之领衔|再塑经典|精品有声剧"
        let omnibus = "凡人修仙传|精编版|关彦之"
        let root = "有声书/凡人修仙传之仙界篇-关彦之"
        var items: [SpokenWordBookItem] = []
        for number in 1...12 {
            let path = "\(root)/1-500/关彦之 - 第\(number)集 标题\(number)_HQ.mp3"
            switch number {
            case 3:
                // Same book, its album tag without the decoration.
                items.append(item("s3", title: "第3集 相依", album: "凡人修仙传之仙界篇", artist: "关彦之", path: path))
            case 1, 2:
                items.append(item("s\(number)", title: "第\(4968 + number)集 (凡人仙界篇)", album: omnibus,
                                  artist: "关彦之", track: 4968 + number, path: path))
            case 4...8:
                items.append(item("s\(number)", title: "第\(number)集 标题\(number)", album: longAlbum,
                                  artist: "关彦之", track: number, path: path))
            default:
                // No usable album tag.
                items.append(item("s\(number)", title: "第\(number)集 标题\(number)", artist: "qb2", path: path))
            }
        }
        for number in 4969...4972 {
            items.append(item("o\(number)", title: "第\(number)集", album: omnibus, artist: "关彦之", track: number,
                              path: "有声书/凡人修仙传-关彦之/4501-5000/第\(number)集.mp3"))
        }
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(books.count == 2)
        let single = books.first { $0.items.contains { $0.id == "s9" } }
        #expect(single?.items.map(\.id) == (1...12).map { "s\($0)" })
        #expect(single?.title == longAlbum)
        // Renamed files are listed by the chapter their file name gives them.
        #expect(single?.items.first?.title == "第1集 标题1")
        #expect(books.first { $0.items.contains { $0.id == "o4969" } }?.items.count == 4)
    }

    @Test("Untagged files join a book nearly every tagged file shares, not one of two")
    func untaggedFilesJoinOnlyADominantBook() {
        var items = (1...20).map { (number: Int) in item("a\(number)", album: "三体", track: number, path: "书/a\(number).mp3") }
        items.append(item("theme", title: "主题曲", album: "主题曲合集", path: "书/主题曲.mp3"))
        items.append(item("loose", title: "番外", path: "书/番外.mp3"))
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(books.first { $0.items.contains { $0.id == "a1" } }?.items.contains { $0.id == "loose" } == true)
        #expect(books.first { $0.items.contains { $0.id == "theme" } }?.items.count == 1)

        let mixed = [
            item("x1", album: "三体", track: 1, path: "下载/x1.mp3"),
            item("x2", album: "三体", track: 2, path: "下载/x2.mp3"),
            item("y1", album: "球状闪电", track: 1, path: "下载/y1.mp3"),
            item("y2", album: "球状闪电", track: 2, path: "下载/y2.mp3"),
            item("z", title: "访谈", path: "下载/z.mp3"),
        ]
        let apart = SpokenWordBookGrouping.books(from: mixed)
        #expect(apart.count == 3)
        #expect(apart.first { $0.items.contains { $0.id == "z" } }?.items.count == 1)
    }

    @Test("Decoration after a separator is the same book; a volume is not")
    func decoratedTitleDetection() {
        #expect(SpokenWordBookGroupingRules.isDecoratedTitle("凡人修仙传之仙界篇|关彦之领衔", of: "凡人修仙传之仙界篇"))
        #expect(SpokenWordBookGroupingRules.isDecoratedTitle("dune - read by scott brick", of: "dune"))
        #expect(!SpokenWordBookGroupingRules.isDecoratedTitle("三体 - 第二部", of: "三体"))
        #expect(!SpokenWordBookGroupingRules.isDecoratedTitle("dune (2)", of: "dune"))
        #expect(!SpokenWordBookGroupingRules.isDecoratedTitle("三体2", of: "三体"))
        #expect(!SpokenWordBookGroupingRules.isDecoratedTitle("三体全集", of: "三体"))
        #expect(SpokenWordBookGroupingRules.fileChapterTitle("书/关彦之 - 第1集 狐女（1）_HQ.mp3") == "第1集 狐女（1）")
        #expect(SpokenWordBookGroupingRules.fileChapterTitle("书/第12回 [MQ].m4a") == "第12回")
        #expect(SpokenWordBookGroupingRules.fileChapterTitle("书/01 Intro.mp3") == nil)
    }

    @Test("A folder renamed throughout is renumbered on purpose and keeps its tags")
    func renumberedFolderKeepsTags() {
        let books = SpokenWordBookGrouping.books(from: [
            item("1", title: "第1集", album: "三体", track: 1, path: "三体/第101集.mp3"),
            item("2", title: "第2集", album: "三体", track: 2, path: "三体/第102集.mp3"),
            item("3", title: "第3集", album: "三体", track: 3, path: "三体/第103集.mp3"),
        ])
        #expect(books.map(\.id) == ["book:三体\u{1F}"])
        #expect(books.first?.items.map(\.id) == ["1", "2", "3"])
    }

    @Test("Range folders count as their parent and keep their order when tracks restart")
    func rangeFoldersOrderByRange() {
        let books = SpokenWordBookGrouping.books(from: [
            item("b1", album: "鬼吹灯", track: 1, path: "鬼吹灯/101-200/101.mp3"),
            item("b2", album: "鬼吹灯", track: 2, path: "鬼吹灯/101-200/102.mp3"),
            item("a1", album: "鬼吹灯", track: 1, path: "鬼吹灯/1-100/001.mp3"),
            item("a2", album: "鬼吹灯", track: 2, path: "鬼吹灯/1-100/002.mp3"),
        ])
        #expect(books.count == 1)
        #expect(books.first?.items.map(\.id) == ["a1", "a2", "b1", "b2"])
        #expect(books.first?.title == "鬼吹灯")
    }

    // MARK: - Item-id cloud drives

    /// 有声书/仙界篇/1-500/{f1,f2}, 有声书/合集/4501-5000/{c1,c2}; the root has no row.
    private let driveFolders = SpokenWordBookItemFolders(
        fileParents: ["f1": "d-range", "f2": "d-range", "c1": "d-all-range", "c2": "d-all-range"],
        directoryParents: [
            "d-books": "root", "d-xianjie": "d-books", "d-range": "d-xianjie",
            "d-all": "d-books", "d-all-range": "d-all",
        ],
        names: [
            "d-books": "有声书", "d-xianjie": "仙界篇-关彦之", "d-range": "1-500",
            "d-all": "合集", "d-all-range": "4501-5000",
            "f1": "关彦之 - 第1集 狐女（1）.mp3", "f2": "关彦之 - 第2集 狐女（2）.mp3",
            "c1": "第4969集 狐女1.mp3", "c2": "第4970集 狐女2.mp3",
        ]
    )

    @Test("An item-id drive's file is read as the path of names its scan saw")
    func itemIDDrivePath() {
        var cache: [String: String] = [:]
        #expect(driveFolders.path(ofFile: "f2", directoryPaths: &cache) == "有声书/仙界篇-关彦之/1-500/关彦之 - 第2集 狐女（2）.mp3")
        #expect(driveFolders.path(ofFile: "c1", directoryPaths: &cache) == "有声书/合集/4501-5000/第4969集 狐女1.mp3")
        #expect(cache["d-range"] == "有声书/仙界篇-关彦之/1-500")
        #expect(driveFolders.path(ofFile: "unscanned", directoryPaths: &cache) == nil)

        // A nameless folder below the root keeps its id; a "/" in a name stays one component.
        let odd = SpokenWordBookItemFolders(
            fileParents: ["f": "d2"],
            directoryParents: ["d1": "root", "d2": "d1"],
            names: ["d1": "AC/DC 有声", "f": "01.mp3"]
        )
        var oddCache: [String: String] = [:]
        #expect(odd.path(ofFile: "f", directoryPaths: &oddCache) == "AC\u{2215}DC 有声/d2/01.mp3")

        // A provider listing a folder as its own ancestor still ends.
        let loop = SpokenWordBookItemFolders(
            fileParents: ["f": "a"], directoryParents: ["a": "b", "b": "a"], names: ["a": "A", "b": "B", "f": "f.mp3"]
        )
        var loopCache: [String: String] = [:]
        #expect(loop.path(ofFile: "f", directoryPaths: &loopCache)?.hasSuffix("A/f.mp3") == true)
    }

    @Test("Two recordings on an item-id drive split by folder as on a NAS")
    func itemIDDriveVersionsSplit() {
        var cache: [String: String] = [:]
        func driveItem(_ id: String, title: String, track: Int) -> SpokenWordBookItem {
            item(id, title: title, album: "凡人修仙传", artist: "关彦之", track: track,
                 path: driveFolders.path(ofFile: id, directoryPaths: &cache) ?? id, source: "drive")
        }
        let items = [
            driveItem("f1", title: "第1集", track: 1), driveItem("f2", title: "第2集", track: 2),
            driveItem("c1", title: "第1集", track: 1), driveItem("c2", title: "第2集", track: 2),
        ]
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(books.count == 2)
        #expect(Set(books.map { $0.items.map(\.id) }) == [["f1", "f2"], ["c1", "c2"]])
        // "1-500" counts as the folder above it, which names the part.
        #expect(Set(books.map(\.title)) == ["凡人修仙传 · 仙界篇-关彦之", "凡人修仙传 · 合集"])

        // Without the scanned folders the file ids name none, and the two interleave.
        let unplaced = items.map { item -> SpokenWordBookItem in
            var copy = item
            copy.fileName = item.id
            return copy
        }
        #expect(SpokenWordBookGrouping.books(from: unplaced).count == 1)
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
