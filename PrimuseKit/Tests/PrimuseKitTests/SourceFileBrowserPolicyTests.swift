import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source file browser")
struct SourceFileBrowserPolicyTests {
    private func file(_ name: String, in folder: String = "/音乐", size: Int64 = 1) -> SourceFileBrowserPolicy.Entry {
        .init(name: name, path: folder + "/" + name, isDirectory: false, size: size, modifiedDate: nil)
    }

    private func folder(_ name: String, in parent: String = "/音乐") -> SourceFileBrowserPolicy.Entry {
        .init(name: name, path: parent + "/" + name, isDirectory: true, size: 0, modifiedDate: nil)
    }

    @Test("File sources open the file page; servers and Apple Music do not")
    func browsableTypes() {
        #expect(SourceFileBrowserPolicy.browsesFiles(.synology))
        #expect(SourceFileBrowserPolicy.browsesFiles(.smb))
        #expect(SourceFileBrowserPolicy.browsesFiles(.upnp))
        #expect(SourceFileBrowserPolicy.browsesFiles(.baiduPan))
        #expect(SourceFileBrowserPolicy.browsesFiles(.local))
        #expect(!SourceFileBrowserPolicy.browsesFiles(.navidrome))
        #expect(!SourceFileBrowserPolicy.browsesFiles(.synologyAudioStation))
        #expect(!SourceFileBrowserPolicy.browsesFiles(.appleMusic))
        #expect(!SourceFileBrowserPolicy.browsesFiles(.appleMusicLibrary))
    }

    @Test("Folders and songs sort naturally; system folders and dot files stay hidden")
    func groupingAndOrder() {
        let listing = SourceFileBrowserPolicy.listing(of: [
            file("10 晴天.flac"), file("2 七里香.mp3"), folder("周杰伦"), folder("@eaDir"),
            folder("#recycle"), file(".DS_Store"), folder("五月天"), file("notes.txt"),
        ])
        #expect(listing.folders.map(\.name) == ["五月天", "周杰伦"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(listing.audioFiles.map(\.entry.name) == ["2 七里香.mp3", "10 晴天.flac"])
        #expect(listing.audioFiles.map(\.format) == [.mp3, .flac])
        #expect(listing.otherFileCount == 1)
    }

    @Test("Lyrics and covers attach to the song with the same name")
    func sidecarsAttach() throws {
        let listing = SourceFileBrowserPolicy.listing(of: [
            file("稻香.flac"), file("稻香.lrc"), file("稻香.TTML"), file("稻香-cover.jpg"),
            file("晴天.m4a"), file("cover.jpg"), file("晴天.txt"),
        ])
        let daoxiang = try #require(listing.audioFiles.first { $0.entry.name == "稻香.flac" })
        #expect(daoxiang.lyrics.map(\.name) == ["稻香.lrc", "稻香.TTML"])
        #expect(daoxiang.cover?.name == "稻香-cover.jpg")
        let qingtian = try #require(listing.audioFiles.first { $0.entry.name == "晴天.m4a" })
        #expect(qingtian.lyrics.isEmpty)
        #expect(qingtian.cover == nil)
        // cover.jpg 是文件夹封面、晴天.txt 不是歌词扩展名:都算其他文件。
        #expect(listing.otherFileCount == 2)
    }

    @Test("Same-name songs in two formats both show the shared lyrics")
    func sharedLyrics() {
        let listing = SourceFileBrowserPolicy.listing(of: [
            file("稻香.flac"), file("稻香.mp3"), file("稻香.lrc"),
        ])
        #expect(listing.audioFiles.allSatisfy { $0.lyrics.map(\.name) == ["稻香.lrc"] })
        #expect(listing.otherFileCount == 0)
    }

    @Test("Library index counts songs under every enclosing folder")
    func libraryIndexCounts() {
        let index = SourceFileBrowserPolicy.LibraryIndex(songPaths: [
            "/音乐/华语/周杰伦/稻香.flac",
            "/音乐/华语/周杰伦/晴天.flac",
            "/音乐/华语/五月天/倔强.mp3",
            "/音乐/古典/cd.ape", "/音乐/古典/cd.ape",
        ], countsFolders: true)
        #expect(index.songCount(inFolder: "/音乐/华语/周杰伦") == 2)
        #expect(index.songCount(inFolder: "/音乐/华语/") == 3)
        #expect(index.songCount(inFolder: "/音乐") == 5)
        #expect(index.songCount(inFolder: "/") == 5)
        #expect(index.songCount(inFolder: "/音乐/摇滚") == 0)
        #expect(index.songCount(forFile: "/音乐/古典/cd.ape") == 2)
        #expect(index.songCount(forFile: "/音乐/古典/other.ape") == 0)
    }

    @Test("Bucket-relative paths count toward their folders and the root")
    func libraryIndexWithoutLeadingSlash() {
        let index = SourceFileBrowserPolicy.LibraryIndex(songPaths: ["Music/Jazz/a.flac", "b.flac"], countsFolders: true)
        #expect(index.songCount(inFolder: "Music/Jazz") == 1)
        #expect(index.songCount(inFolder: "Music") == 1)
        #expect(index.songCount(inFolder: "") == 2)
    }

    @Test("ID-addressed sources only match whole file identifiers")
    func opaqueIndex() {
        let index = SourceFileBrowserPolicy.LibraryIndex(songPaths: ["fid-123", "fid-456"], countsFolders: false)
        #expect(index.songCount(forFile: "fid-123") == 1)
        #expect(index.songCount(inFolder: "/") == 0)
    }
}
