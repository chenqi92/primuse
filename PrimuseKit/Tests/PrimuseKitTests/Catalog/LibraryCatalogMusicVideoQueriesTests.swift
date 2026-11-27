import Foundation
import Testing
@testable import PrimuseKit

/// 资料库入口的 MV 计数在目录上数(P3 步骤 6c 单元 3):只数带 MV 路径的音乐。
@Suite("Music-video counts on the catalog")
struct LibraryCatalogMusicVideoQueriesTests {
    @Test("Counts the music that carries a music video")
    func countsMusicWithAMusicVideo() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        func song(_ id: String, musicVideo: String?) -> Song {
            var song = Song(id: id, title: "Song \(id)", albumTitle: "Album", artistName: "Artist",
                            fileFormat: .flac, filePath: "/Music/\(id).flac", sourceID: "source-a", genre: "Pop")
            song.mvPath = musicVideo
            return song
        }
        #expect(try catalog.musicVideoSongCount() == 0)
        try catalog.apply(upserts: [
            song("one", musicVideo: "/Videos/one.mp4"),
            song("two", musicVideo: "/Videos/two.mp4"),
            song("three", musicVideo: nil),
            song("four", musicVideo: ""),
        ])
        #expect(try catalog.musicVideoSongCount() == 2)
        try catalog.apply(upserts: [], deletingIDs: ["two"])
        #expect(try catalog.musicVideoSongCount() == 1)
    }
}
