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

@Suite("Source folder relocation")
struct SourceFolderRelocationPolicyTests {
    @Test("Only whole folder components are relocated")
    func relocatedPaths() {
        let old = "/音乐/华语"
        let new = "/音乐/华语流行"
        #expect(SourceFolderRelocationPolicy.relocatedPath("/音乐/华语", from: old, to: new) == "/音乐/华语流行")
        #expect(SourceFolderRelocationPolicy.relocatedPath("/音乐/华语/", from: old, to: new) == "/音乐/华语流行")
        #expect(SourceFolderRelocationPolicy.relocatedPath("/音乐/华语/周杰伦/稻香.flac", from: old, to: new)
            == "/音乐/华语流行/周杰伦/稻香.flac")
        #expect(SourceFolderRelocationPolicy.relocatedPath("/音乐/华语经典/a.flac", from: old, to: new) == nil)
        #expect(SourceFolderRelocationPolicy.relocatedPath("/音乐/a.flac", from: old, to: new) == nil)
        #expect(SourceFolderRelocationPolicy.relocatedPath("Music/Jazz/a.flac", from: "Music/Jazz/", to: "Music/Swing")
            == "Music/Swing/a.flac")
    }

    @Test("Folder names are trimmed and must stay in the same folder")
    func folderNames() {
        #expect(SourceFolderRelocationPolicy.validatedFolderName("  周杰伦 ") == "周杰伦")
        #expect(SourceFolderRelocationPolicy.validatedFolderName("") == nil)
        #expect(SourceFolderRelocationPolicy.validatedFolderName("..") == nil)
        #expect(SourceFolderRelocationPolicy.validatedFolderName("a/b") == nil)
        #expect(SourceFolderRelocationPolicy.validatedFolderName(String(repeating: "a", count: 256)) == nil)
        #expect(SourceFolderRelocationPolicy.siblingPath(of: "/音乐/华语/", named: "流行") == "/音乐/流行")
        #expect(SourceFolderRelocationPolicy.siblingPath(of: "Music/Jazz", named: "Swing") == "Music/Swing")
        #expect(SourceFolderRelocationPolicy.siblingPath(of: "Jazz", named: "Swing") == "Swing")
    }

    @Test("A folder that is or contains a scan root cannot be renamed in place")
    func scanRoots() {
        #expect(SourceFolderRelocationPolicy.touchesScanRoots("/音乐", selections: ["/音乐/华语"], sourceType: .smb))
        #expect(SourceFolderRelocationPolicy.touchesScanRoots("/音乐/华语", selections: ["/音乐/华语"], sourceType: .smb))
        #expect(!SourceFolderRelocationPolicy.touchesScanRoots("/音乐/华语/周杰伦", selections: ["/音乐/华语"], sourceType: .smb))
    }

    @Test("The scan index follows the renamed folder and keeps song IDs")
    func indexRelocation() {
        func item(_ path: String, parent: String?, directory: Bool, songs: [String] = []) -> SourceSyncIndexedItem {
            SourceSyncIndexedItem(
                stableKey: "path:\(path.lowercased())", path: path,
                displayName: (path as NSString).lastPathComponent, parentPath: parent,
                isDirectory: directory, songIDs: songs, size: 1, modifiedDate: nil, revision: nil,
                sidecarFingerprint: directory ? nil : "fp"
            )
        }
        var state = SourceSyncState(sourceID: "s", scopeFingerprint: "f")
        let entries = [
            item("/音乐/华语", parent: "/音乐", directory: true),
            item("/音乐/华语/稻香.flac", parent: "/音乐/华语", directory: false, songs: ["song-1"]),
            item("/音乐/华语经典/晴天.flac", parent: "/音乐/华语经典", directory: false, songs: ["song-2"]),
        ]
        for entry in entries { state.index[entry.stableKey] = entry }
        state.missingStableKeys["path:/音乐/华语/稻香.flac"] = 1
        state.pendingDirectories = ["/音乐/华语"]

        let moved = SourceFolderRelocationPolicy.relocate(&state, from: "/音乐/华语", to: "/音乐/流行")

        #expect(moved == 2)
        #expect(state.index["path:/音乐/华语/稻香.flac"] == nil)
        let song = state.index["path:/音乐/流行/稻香.flac"]
        #expect(song?.songIDs == ["song-1"])
        #expect(song?.parentPath == "/音乐/流行")
        #expect(song?.sidecarFingerprint == nil)
        #expect(state.index["path:/音乐/流行"]?.displayName == "流行")
        #expect(state.index["path:/音乐/华语经典/晴天.flac"]?.songIDs == ["song-2"])
        #expect(state.identityAliases["path:/音乐/华语/稻香.flac"] == "path:/音乐/流行/稻香.flac")
        #expect(state.missingStableKeys.isEmpty)
        #expect(state.pendingDirectories == ["/音乐/流行"])
    }
}

@Suite("Source file move")
struct SourceFileMovePlanTests {
    private func file(_ name: String, in folder: String = "/音乐/华语") -> SourceFileBrowserPolicy.Entry {
        .init(name: name, path: folder + "/" + name, isDirectory: false, size: 1, modifiedDate: nil)
    }

    @Test("Same-name lyrics and covers move with the song")
    func sidecarsFollow() throws {
        let moves = try SourceFileMovePlan.moves(
            audioPath: "/音乐/华语/稻香.flac",
            sourceEntries: [file("稻香.flac"), file("稻香.lrc"), file("稻香-cover.jpg"),
                            file("晴天.flac"), file("cover.jpg"), file("稻香.txt")],
            destinationDirectory: "/音乐/周杰伦",
            destinationNames: ["晴天.flac"]
        )
        #expect(moves == [
            .init(from: "/音乐/华语/稻香.flac", to: "/音乐/周杰伦/稻香.flac"),
            .init(from: "/音乐/华语/稻香.lrc", to: "/音乐/周杰伦/稻香.lrc"),
            .init(from: "/音乐/华语/稻香-cover.jpg", to: "/音乐/周杰伦/稻香-cover.jpg"),
        ])
    }

    @Test("A name already in the destination stops the whole move")
    func collision() {
        #expect(throws: SourceFileMovePlan.Failure.collision("稻香.lrc")) {
            try SourceFileMovePlan.moves(
                audioPath: "/音乐/华语/稻香.flac",
                sourceEntries: [file("稻香.flac"), file("稻香.lrc")],
                destinationDirectory: "/音乐/周杰伦/",
                destinationNames: ["稻香.LRC"]
            )
        }
        #expect(throws: SourceFileMovePlan.Failure.cue) {
            try SourceFileMovePlan.moves(
                audioPath: "/音乐/华语/稻香.flac",
                sourceEntries: [file("稻香.flac"), file("album.cue")],
                destinationDirectory: "/音乐", destinationNames: []
            )
        }
    }

    @Test("Folders can't move into themselves or back where they are")
    func folderTargets() {
        #expect(SourceFileMovePlan.canMoveFolder("/音乐/华语", into: "/音乐/流行"))
        #expect(SourceFileMovePlan.canMoveFolder("/音乐/华语", into: "/"))
        #expect(!SourceFileMovePlan.canMoveFolder("/音乐/华语", into: "/音乐"))
        #expect(!SourceFileMovePlan.canMoveFolder("/音乐/华语", into: "/音乐/华语/周杰伦"))
        #expect(!SourceFileMovePlan.canMoveFolder("/音乐/华语", into: "/音乐/华语"))
    }
}

