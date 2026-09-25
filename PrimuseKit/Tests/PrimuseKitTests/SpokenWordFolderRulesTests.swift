import Foundation
import Testing
@testable import PrimuseKit

@Suite("Folder tags for spoken word")
struct SpokenWordFolderRulesTests {
    private func descriptor(_ id: String, _ type: MusicSourceType) -> LibraryFolderSourceDescriptor {
        LibraryFolderSourceDescriptor(source: MusicSource(id: id, name: id, type: type))
    }

    @Test("Keys round-trip and can never be mistaken for a song id")
    func keys() {
        let key = SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Books/三体")
        #expect(SpokenWordFolderTag.isFolderKey(key))
        #expect(SpokenWordFolderTag.parse(overrideKey: key)?.sourceID == "nas")
        #expect(SpokenWordFolderTag.parse(overrideKey: key)?.path == "/Books/三体")
        #expect(SpokenWordFolderTag.parse(overrideKey: "a1b2c3") == nil)
        #expect(!SpokenWordFolderTag.isFolderKey("a1b2c3"))
        #expect(SpokenWordFolderTag.parse(overrideKey: SpokenWordFolderTag.overrideKey(sourceID: "", path: "/x")) == nil)
    }

    @Test("Only spoken-word folder entries are read from the correction table")
    func folders() {
        let overrides: [String: ListeningContentKind] = [
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/B"): .spokenWord,
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/A"): .spokenWord,
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/M"): .music,
            "song-1": .spokenWord,
        ]
        #expect(SpokenWordFolderTag.spokenWordFolders(in: overrides) == ["nas": ["/A", "/B"]])
    }

    @Test("Songs under a tagged folder match; siblings and look-alike names do not")
    func matching() {
        let rules = SpokenWordFolderRules(folders: ["nas": ["/Books"]], sources: [descriptor("nas", .smb)])
        #expect(rules.containsSong(sourceID: "nas", filePath: "/Books/Three Body/01.mp3"))
        #expect(rules.containsSong(sourceID: "nas", filePath: "/Books/intro.mp3"))
        #expect(!rules.containsSong(sourceID: "nas", filePath: "/Music/song.flac"))
        #expect(!rules.containsSong(sourceID: "nas", filePath: "/Books2/x.mp3"))
        #expect(!rules.containsSong(sourceID: "other", filePath: "/Books/x.mp3"))
    }

    @Test("Sources without real folder paths get no rule")
    func opaqueSources() {
        let rules = SpokenWordFolderRules(
            folders: ["jf": ["/Books"], "gd": ["folder-id"]],
            sources: [descriptor("jf", .jellyfin), descriptor("gd", .googleDrive)]
        )
        #expect(rules.isEmpty)
        #expect(!SpokenWordFolderTag.supportsTags(descriptor("jf", .jellyfin)))
        #expect(SpokenWordFolderTag.supportsTags(descriptor("nas", .webdav)))
    }

    @Test("A per-song correction outranks the folder, the folder outranks the file")
    func precedence() {
        let rules = SpokenWordFolderRules(folders: ["nas": ["/Books"]], sources: [descriptor("nas", .smb)])
        let inputs = SpokenWordClassificationInputs(overrides: ["song-in-books": .music], folderRules: rules)
        #expect(inputs.kind(songID: "song-in-books", sourceID: "nas", filePath: "/Books/a.mp3", genre: nil) == .music)
        #expect(inputs.kind(songID: "other", sourceID: "nas", filePath: "/Books/a.mp3", genre: "Pop") == .spokenWord)
        // Untagged folders keep the usual inference.
        #expect(inputs.kind(songID: "x", sourceID: "nas", filePath: "/Music/a.m4b", genre: nil) == .spokenWord)
        #expect(inputs.kind(songID: "y", sourceID: "nas", filePath: "/Music/a.mp3", genre: "Rock") == .music)
        #expect(SpokenWordClassificationInputs.empty.kind(songID: "z", sourceID: "nas", filePath: "/Books/a.mp3", genre: nil) == .music)
    }
}
