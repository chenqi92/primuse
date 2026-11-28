import Foundation
import Testing
@testable import PrimuseKit

/// 启动与删除之后的一次性检查在目录上答(P3 步骤 6c 单元 3):手改标记、专辑还有没有歌,
/// 都按整库(含停用源、所有类别)算,与读整库数组的旧写法同口径。
@Suite("Stored-level checks on the catalog")
struct LibraryCatalogStoredLevelQueriesTests {
    private func song(_ id: String, album: String?, edited: Bool = false, source: String = "source-a") -> Song {
        var song = Song(id: id, title: "Song \(id)", albumTitle: "Album", artistName: "Artist",
                        fileFormat: .flac, filePath: "/Music/\(id).flac", sourceID: source, genre: "Pop")
        song.albumID = album
        if edited { song.userMetadataEditedAt = Date(timeIntervalSince1970: 1_700_000_000) }
        return song
    }

    @Test("Lists the songs that carry the user-edit marker")
    func listsUserEditedSongs() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        #expect(try catalog.userEditedSongIDs().isEmpty)
        try catalog.apply(upserts: [
            song("one", album: "a", edited: true),
            song("two", album: "a"),
            song("three", album: "b", edited: true, source: "source-b"),
        ])
        #expect(try catalog.userEditedSongIDs() == ["one", "three"])
        var cleared = song("one", album: "a")
        cleared.userMetadataEditedAt = nil
        try catalog.apply(upserts: [cleared], deletingIDs: ["three"])
        #expect(try catalog.userEditedSongIDs().isEmpty)
    }

    @Test("Tells whether a source has songs without a duration")
    func tellsWhetherASourceHasSongsWithoutADuration() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        func timed(_ id: String, _ duration: TimeInterval, source: String) -> Song {
            var song = song(id, album: nil, source: source)
            song.duration = duration
            return song
        }
        try catalog.apply(upserts: [
            timed("one", 180, source: "source-a"),
            timed("two", 0, source: "source-b"),
            timed("three", 200, source: "source-b"),
        ])
        #expect(try catalog.hasSongsWithoutDuration(sourceID: "source-a") == false)
        #expect(try catalog.hasSongsWithoutDuration(sourceID: "source-b"))
        #expect(try catalog.hasSongsWithoutDuration(sourceID: "source-c") == false)
        try catalog.apply(upserts: [timed("two", 95, source: "source-b")])
        #expect(try catalog.hasSongsWithoutDuration(sourceID: "source-b") == false)
    }

    @Test("Lists the music-video candidates in library order")
    func listsMusicVideoCandidatesInLibraryOrder() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        func video(_ id: String, mv: String?, added: TimeInterval) -> Song {
            var song = song(id, album: nil)
            song.mvPath = mv
            song.dateAdded = Date(timeIntervalSinceReferenceDate: added)
            return song
        }
        try catalog.apply(upserts: [
            video("one", mv: "/Videos/one.mp4", added: 100),
            video("two", mv: nil, added: 200),
            video("three", mv: "/Videos/three.mp4", added: 300),
        ])
        let candidates = try catalog.musicVideoCandidates()
        #expect(candidates.map(\.id) == ["one", "three"])
        #expect(candidates.map(\.dateAdded) == [Date(timeIntervalSinceReferenceDate: 100), Date(timeIntervalSinceReferenceDate: 300)])
    }

    @Test("Lists the music-video rows in library order")
    func listsMusicVideoRowsInLibraryOrder() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        func video(_ id: String, mv: String?) -> Song {
            var song = song(id, album: nil)
            song.mvPath = mv
            return song
        }
        #expect(try catalog.musicVideoRowList().isEmpty)
        try catalog.apply(upserts: [
            video("one", mv: "/Videos/one.mp4"),
            video("two", mv: nil),
            video("three", mv: "/Videos/three.mp4"),
            video("four", mv: "/Videos/four.mp4"),
        ])
        let rows = try catalog.musicVideoRowList()
        #expect(try catalog.songs(rowids: rows.rowids).map(\.id) == ["one", "three", "four"])
        #expect(rows.count == (try catalog.musicVideoSongCount()))
        #expect(rows.count == (try catalog.musicVideoCandidates().count))
        try catalog.apply(upserts: [video("three", mv: nil)], deletingIDs: ["one"])
        #expect(try catalog.songs(rowids: catalog.musicVideoRowList().rowids).map(\.id) == ["four"])
    }

    @Test("Tells which albums still have a song")
    func tellsWhichAlbumsStillHaveASong() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: [
            song("one", album: "a"),
            song("two", album: "a"),
            song("three", album: "b", source: "source-b"),
            song("four", album: nil),
        ])
        #expect(try catalog.albumIDsWithSongs(among: ["a", "b", "c"]) == ["a", "b"])
        #expect(try catalog.albumIDsWithSongs(among: [String]()).isEmpty)
        try catalog.apply(upserts: [], deletingIDs: ["one", "three"])
        #expect(try catalog.albumIDsWithSongs(among: ["a", "b"]) == ["a"])
        try catalog.apply(upserts: [], deletingIDs: ["two"])
        #expect(try catalog.albumIDsWithSongs(among: ["a", "b"]).isEmpty)
    }
}
