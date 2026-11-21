import Foundation
import Testing
@testable import PrimuseKit

@Suite("Local file watch path spellings")
struct LocalFileWatchPathTests {
    private let cloudRoot = "/Users/listener/Library/Mobile Documents/com~apple~CloudDocs/Music"

    @Test func privateAndDataVolumePrefixesNameTheSameFile() {
        #expect(LocalFileWatchPath.key("/private/var/mobile/Music/a.flac") == LocalFileWatchPath.key("/var/mobile/Music/a.flac"))
        #expect(LocalFileWatchPath.key("/private/tmp/a.mp3") == LocalFileWatchPath.key("/tmp/a.mp3"))
        #expect(LocalFileWatchPath.key("/System/Volumes/Data\(cloudRoot)/a.flac") == LocalFileWatchPath.key("\(cloudRoot)/a.flac"))
        #expect(LocalFileWatchPath.key("/System/Volumes/Data/private/var/folders/x/a.mp3")
            == LocalFileWatchPath.key("/var/folders/x/a.mp3"))
        #expect(LocalFileWatchPath.key("/System/Volumes/Data") == "/")
        // Only the real alias components are removed.
        #expect(LocalFileWatchPath.key("/private/Users/a.mp3") == "/private/Users/a.mp3")
        #expect(LocalFileWatchPath.key("/privatevar/a.mp3") == "/privatevar/a.mp3")
        #expect(LocalFileWatchPath.key("/System/Volumes/Preboot/a") == "/System/Volumes/Preboot/a")
        #expect(LocalFileWatchPath.key("relative/private/var") == "/relative/private/var")
    }

    @Test func slashesAndDotComponentsCollapse() {
        #expect(LocalFileWatchPath.key("/Music//Album/./Disc 1/../a.flac") == "/Music/Album/a.flac")
        #expect(LocalFileWatchPath.key("/Music/Album/") == "/Music/Album")
        #expect(LocalFileWatchPath.key("/") == "/")
    }

    @Test func composedAndDecomposedNamesShareOneKey() {
        let composed = "\(cloudRoot)/Caf\u{E9} \u{2013} \u{6668}\u{5149}\u{FF08}\u{73B0}\u{573A}\u{FF09}.flac"
        let decomposed = "\(cloudRoot)/Cafe\u{301} \u{2013} \u{6668}\u{5149}\u{FF08}\u{73B0}\u{573A}\u{FF09}.flac"
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(LocalFileWatchPath.key(composed) == LocalFileWatchPath.key(decomposed))
        #expect(Array(LocalFileWatchPath.key(composed).utf8) == Array(LocalFileWatchPath.key(decomposed).utf8))
        let hangul = "/Music/\u{D55C}\u{AE00}.mp3"
        let jamo = "/Music/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.mp3"
        #expect(Array(LocalFileWatchPath.key(hangul).utf8) == Array(LocalFileWatchPath.key(jamo).utf8))
        let kana = "/Music/\u{304C}.mp3"
        let combining = "/Music/\u{304B}\u{3099}.mp3"
        #expect(LocalFileWatchPath.relativePath(of: combining, under: "/Music") == "\u{304B}\u{3099}.mp3")
        #expect(LocalFileWatchPath.key(kana) == LocalFileWatchPath.key(combining))
    }

    @Test func letterCaseOnlyMatchesThroughTheFoldedKey() {
        #expect(LocalFileWatchPath.key("/Music/Track.MP3") != LocalFileWatchPath.key("/music/track.mp3"))
        #expect(LocalFileWatchPath.caseFoldedKey("/Music/Track.MP3") == LocalFileWatchPath.caseFoldedKey("/music/track.mp3"))
        #expect(LocalFileWatchPath.caseFoldedKey("/private/var/Music/\u{C4}.mp3")
            == LocalFileWatchPath.caseFoldedKey("/var/music/A\u{308}.MP3"))
    }

    @Test func relativePathsUnderAliasedRoots() {
        let root = "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music"
        #expect(LocalFileWatchPath.relativePath(of: "/private\(root)/Album/a.flac", under: root) == "Album/a.flac")
        #expect(LocalFileWatchPath.relativePath(of: "\(root)/Album/a.flac", under: "/private\(root)") == "Album/a.flac")
        #expect(LocalFileWatchPath.relativePath(of: "/System/Volumes/Data\(cloudRoot)/a.flac", under: cloudRoot) == "a.flac")
        #expect(LocalFileWatchPath.relativePath(of: "/private\(root)", under: root) == "")
        // A removed file has nothing on disk to resolve, but still maps.
        #expect(LocalFileWatchPath.relativePath(of: "/private\(root)/Gone/b.mp3", under: root) == "Gone/b.mp3")
    }

    @Test func relativePathsRejectNeighboursAndKeepTheItemSpelling() {
        #expect(LocalFileWatchPath.relativePath(of: "/Music2/a.mp3", under: "/Music") == nil)
        #expect(LocalFileWatchPath.relativePath(of: "/Mus", under: "/Music") == nil)
        #expect(LocalFileWatchPath.relativePath(of: "/music/Album/A.mp3", under: "/Music") == "Album/A.mp3")
        #expect(LocalFileWatchPath.relativePath(of: "/music/Album/A.mp3", under: "/Music", allowsCaseInsensitiveMatch: false) == nil)
        #expect(LocalFileWatchPath.relativePath(of: "/Mu\u{301}sic/a.mp3", under: "/M\u{FA}sic") == "a.mp3")
    }

    @Test func aliasFormNamesThePrefix() {
        #expect(LocalFileWatchPath.aliasForm("/System/Volumes/Data/Users/a") == "data-volume")
        #expect(LocalFileWatchPath.aliasForm("/private/var/a") == "private")
        #expect(LocalFileWatchPath.aliasForm("/Users/Cafe\u{301}") == "decomposed")
        #expect(LocalFileWatchPath.aliasForm("/Users/a") == "plain")
    }
}

@Suite("Local file event classification")
struct LocalFileEventClassifierTests {
    private func classify(_ flags: LocalFileEventFlags, name: String = "Track.flac", exists: Bool) -> LocalFileEventDisposition {
        LocalFileEventClassifier.disposition(for: flags, name: name) { exists }
    }

    @Test func renameOntoAnExistingFileIsAContentChange() {
        #expect(classify([.renamed], exists: true) == .fileContentChanged)
        #expect(classify([.renamed, .created, .modified, .inodeMetadataChanged], exists: true) == .fileContentChanged)
        #expect(classify([.removed, .created], exists: true) == .fileContentChanged)
    }

    @Test func renameOrRemovalWithNothingLeftIsARemoval() {
        #expect(classify([.renamed], exists: false) == .fileRemoved)
        #expect(classify([.removed], exists: false) == .fileRemoved)
        #expect(classify([.created, .removed], exists: false) == .fileRemoved)
    }

    @Test func writesAreContentChangesAndMetadataOnlyIsAComparison() {
        #expect(classify([.created], exists: true) == .fileContentChanged)
        #expect(classify([.modified], exists: true) == .fileContentChanged)
        #expect(classify([.cloned], exists: true) == .fileContentChanged)
        #expect(classify([.inodeMetadataChanged], exists: true) == .fileAttributesChanged)
        #expect(classify([.extendedAttributesChanged], exists: true) == .ignore)
        #expect(classify([], exists: true) == .ignore)
    }

    @Test func existenceIsOnlyCheckedForRenamesAndRemovals() {
        var checks = 0
        _ = LocalFileEventClassifier.disposition(for: [.modified], name: "a.mp3") { checks += 1; return true }
        _ = LocalFileEventClassifier.disposition(for: [.inodeMetadataChanged], name: "a.mp3") { checks += 1; return true }
        #expect(checks == 0)
        _ = LocalFileEventClassifier.disposition(for: [.renamed], name: "a.mp3") { checks += 1; return true }
        #expect(checks == 1)
    }

    @Test func hiddenFilesFoldersAndOverflow() {
        #expect(classify([.renamed], name: ".Track.flac.primuse-writeback-1", exists: false) == .ignore)
        #expect(classify([.modified], name: ".Track.flac.icloud", exists: true) == .ignore)
        #expect(classify([.isDirectory, .renamed], exists: true) == .folderMoved)
        #expect(classify([.isDirectory, .removed], exists: false) == .folderMoved)
        #expect(classify([.isDirectory, .created], exists: true) == .folderContentsChanged)
        #expect(classify([.isDirectory, .extendedAttributesChanged], exists: true) == .ignore)
        #expect(classify([.mustRescan], name: ".hidden", exists: true) == .rescanItem)
        #expect(classify([.eventsDropped, .mustRescan], exists: true) == .rescanAll)
    }
}

@Suite("Local file watch diagnostics")
struct LocalFileWatchLogTests {
    @Test func identityChangeNamesWhatMoved() {
        let date = Date(timeIntervalSinceReferenceDate: 500)
        #expect(LocalFileWatchLog.identityChange(
            beforeSize: 10, beforeModified: date, beforeRevision: "local:10:1|a",
            afterSize: 10, afterModified: date, afterRevision: "local:10:1|b"
        ) == "size=same mtime=same stamp=changed")
        #expect(LocalFileWatchLog.identityChange(
            beforeSize: 10, beforeModified: date, beforeRevision: "local:10:1",
            afterSize: 12, afterModified: date.addingTimeInterval(3), afterRevision: "local:12:4|c"
        ) == "size=10->12 mtime=+3.0s stamp=changed")
        #expect(LocalFileWatchLog.identityChange(
            beforeSize: 1, beforeModified: nil, beforeRevision: nil,
            afterSize: 1, afterModified: nil, afterRevision: nil
        ) == "size=same mtime=none stamp=none")
    }

    @Test func changedFieldsListsVisibleTags() {
        let before = Song(id: "s", title: "Amber", fileFormat: .flac, filePath: "/a.flac", sourceID: "src")
        var after = before
        #expect(LocalFileWatchLog.changedFields(from: before, to: after).isEmpty)
        after.title = "Cedar"
        after.genre = "Folk"
        after.lyricsFileName = "/a.lrc"
        #expect(LocalFileWatchLog.changedFields(from: before, to: after) == ["title", "genre", "lyrics"])
    }
}
