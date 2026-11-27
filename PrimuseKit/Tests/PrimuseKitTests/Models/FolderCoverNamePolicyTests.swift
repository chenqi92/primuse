import Foundation
import Testing
@testable import PrimuseKit

/// A picture named after its folder or after the album / book title stands
/// for the whole folder, after the fixed names (cover, folder…).
@Suite("Folder cover names")
struct FolderCoverNamePolicyTests {
    @Test("Names compare without case, full-width forms or extra spaces")
    func comparableNames() {
        #expect(FolderCoverNamePolicy.comparableName("  三体　 全集 ") == "三体 全集")
        #expect(FolderCoverNamePolicy.comparableName("ＡＢＣ Book") == "abc book")
        #expect(FolderCoverNamePolicy.comparableName("A／B：C") == "a/b:c")
    }

    @Test("The folder comes before the title, and fixed or generic names are left out")
    func namedStems() {
        #expect(FolderCoverNamePolicy.namedStems(folderName: "三体", albumTitle: "三体 第一部")
            == ["三体", "三体 第一部"])
        // Same name twice counts once.
        #expect(FolderCoverNamePolicy.namedStems(folderName: "Dune", albumTitle: "dune") == ["dune"])
        // A broad library root is nobody's cover; nor is a fixed name, already tried before.
        #expect(FolderCoverNamePolicy.namedStems(folderName: "Music", albumTitle: nil).isEmpty)
        #expect(FolderCoverNamePolicy.namedStems(folderName: "音乐", albumTitle: nil).isEmpty)
        #expect(FolderCoverNamePolicy.namedStems(folderName: "Cover", albumTitle: nil).isEmpty)
        #expect(FolderCoverNamePolicy.namedStems(folderName: nil, albumTitle: "  ").isEmpty)
        // A path that came percent-encoded is tried decoded too.
        #expect(FolderCoverNamePolicy.namedStems(folderName: "%E4%B8%89%E4%BD%93", albumTitle: nil)
            == ["%e4%b8%89%e4%bd%93", "三体"])
        #expect(FolderCoverNamePolicy.namedStems(folderName: "100% Hits", albumTitle: nil) == ["100% hits"])
    }

    @Test("A title with characters a file name can't hold is tried with them swapped or dropped")
    func illegalCharacters() {
        #expect(FolderCoverNamePolicy.probeStems(folderName: nil, albumTitle: "Re:Zero / Book 1")
            == ["Re_Zero _ Book 1", "ReZero  Book 1"])
        #expect(FolderCoverNamePolicy.namedStems(folderName: nil, albumTitle: "Re:Zero / Book 1")
            == ["re_zero _ book 1", "rezero book 1"])
    }

    @Test("Picks the folder's picture over the title's, and the usual extension order")
    func namedCoverAmongFiles() {
        let files = ["01.mp3", "三体 第一部.jpg", "三体.png", "三体.JPG", "notes.txt", "三体.txt"]
        #expect(FolderCoverNamePolicy.namedCover(among: files, folderName: "三体", albumTitle: "三体 第一部")
            == "三体.JPG")
        #expect(FolderCoverNamePolicy.namedCover(among: files, folderName: "别的", albumTitle: "三体 第一部")
            == "三体 第一部.jpg")
        #expect(FolderCoverNamePolicy.namedCover(among: files, folderName: "别的", albumTitle: nil) == nil)
        // Full-width spaces and case in the file name still match.
        #expect(FolderCoverNamePolicy.namedCover(among: ["ＤＵＮＥ　Messiah.webp"], folderName: "Dune Messiah")
            == "ＤＵＮＥ　Messiah.webp")
    }

    @Test("A directory's picture named after it stands for the folder after the fixed names")
    func directoryIndex() {
        func item(_ path: String) -> TestItem { TestItem(sidecarPath: path) }

        let named = SidecarDirectoryIndex([
            item("/Books/三体/01.mp3"), item("/Books/三体/三体.jpg"), item("/Books/三体/back.jpg"),
        ])
        #expect(named.folderCover()?.sidecarName == "三体.jpg")

        let fixedFirst = SidecarDirectoryIndex([
            item("/Books/三体/01.mp3"), item("/Books/三体/三体.jpg"), item("/Books/三体/folder.png"),
        ])
        #expect(fixedFirst.folderCover()?.sidecarName == "folder.png")

        // Opaque item IDs carry no folder name: nothing to match.
        let opaque = SidecarDirectoryIndex([item("fileID1"), TestItem(sidecarPath: "fileID2", name: "三体.jpg")])
        #expect(opaque.folderCover() == nil)

        // The album or book title, when the caller knows it.
        let titled = SidecarDirectoryIndex([item("/Books/Audio Set/01.mp3"), item("/Books/Audio Set/Dune.jpg")])
        #expect(titled.folderCover() == nil)
        #expect(titled.namedFolderCover(albumTitle: "Dune")?.sidecarName == "Dune.jpg")
    }
}

private struct TestItem: SidecarDirectoryItem {
    var sidecarName: String
    var sidecarPath: String
    var sidecarIsDirectory = false
    var sidecarSize: Int64 = 0
    var sidecarModifiedDate: Date?
    var sidecarRevision: String?
    var sidecarProviderID: String?

    init(sidecarPath: String, name: String? = nil) {
        self.sidecarPath = sidecarPath
        sidecarName = name ?? (sidecarPath as NSString).lastPathComponent
    }
}
