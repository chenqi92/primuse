import Foundation
import Testing
@testable import PrimuseKit

@Suite("Book folders: paths two folders share, UPnP containers, the copy kept across launches")
struct SpokenWordBookFolderPlacementTests {
    private func item(
        _ id: String,
        title: String? = nil,
        album: String? = nil,
        track: Int? = nil,
        path: String,
        source: String
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: id,
            title: title ?? id,
            albumTitle: album,
            albumArtist: nil,
            artist: nil,
            discNumber: nil,
            trackNumber: track,
            duration: 600,
            fileName: path,
            sourceID: source
        )
    }

    /// Books of `ids`, each item's path read through `folders` the way
    /// `SpokenWordBookSourcePaths` reads it for the app.
    private func books(
        _ ids: [String],
        folders: SpokenWordBookItemFolders,
        source: String = "drive",
        reportedCatalogSourceIDs: Set<String> = [],
        titles: [String: String] = [:],
        albums: [String: String] = [:],
        tracks: [String: Int] = [:]
    ) -> [SpokenWordBook] {
        var cache: [String: String] = [:]
        let items = ids.map { id in
            item(
                id, title: titles[id], album: albums[id], track: tracks[id],
                path: SpokenWordBookSourcePaths.groupingPath(
                    filePath: id,
                    folders: folders,
                    pathNamesFolders: !reportedCatalogSourceIDs.contains(source),
                    directoryPaths: &cache
                ),
                source: source
            )
        }
        let catalogSourceIDs = SpokenWordBookSourcePaths.catalogSourceIDs(
            reported: reportedCatalogSourceIDs, itemFolders: [source: folders]
        )
        return SpokenWordBookGrouping.books(from: items, catalogSourceIDs: catalogSourceIDs)
    }

    // MARK: - Two folders reading the same path

    @Test("Two picked folders that each hold a 第一部 are two books")
    func sameSubfolderInTwoScanRoots() {
        // Picked: 三体 and 鬼吹灯, neither with a row in the scan index.
        let folders = SpokenWordBookItemFolders(
            fileParents: ["a1": "d-a1", "a2": "d-a1", "b1": "d-b1", "b2": "d-b1", "c1": "d-b2"],
            directoryParents: ["d-a1": "r-santi", "d-b1": "r-gui", "d-b2": "r-gui"],
            names: [
                "d-a1": "第一部", "d-b1": "第一部", "d-b2": "第二部",
                "a1": "01.mp3", "a2": "02.mp3", "b1": "01.mp3", "b2": "02.mp3", "c1": "01.mp3",
            ],
            rootNames: ["r-santi": "三体", "r-gui": "鬼吹灯"]
        )
        var cache: [String: String] = [:]
        #expect(folders.path(ofFile: "a1", directoryPaths: &cache) == "d-a1/第一部/01.mp3")
        #expect(folders.path(ofFile: "b2", directoryPaths: &cache) == "d-b1/第一部/02.mp3")
        // A folder no other reads like keeps its path, and its book its id.
        #expect(folders.path(ofFile: "c1", directoryPaths: &cache) == "第二部/01.mp3")

        let result = books(["a1", "b1", "a2", "b2", "c1"], folders: folders)
        #expect(result.count == 3)
        #expect(Set(result.map { $0.items.map(\.id) }) == [["a1", "a2"], ["b1", "b2"], ["c1"]])
        #expect(result.filter { $0.title == "第一部" }.count == 2)
        #expect(Set(result.map(\.id)) == [
            "folder:drive\u{1F}d-a1/第一部", "folder:drive\u{1F}d-b1/第一部", "folder:drive\u{1F}第二部",
        ])
    }

    @Test("A book's disc folders stay one book when its name is shared")
    func sharedNameKeepsDiscsTogether() {
        // 三体/第一部/{CD1, CD2} and 鬼吹灯/第一部/CD1: the CD1 folders read alike, and so do
        // both 第一部, while 三体's CD2 reads like nothing else.
        let folders = SpokenWordBookItemFolders(
            fileParents: ["a1": "d-a-cd1", "a2": "d-a-cd2", "b1": "d-b-cd1"],
            directoryParents: [
                "d-a": "r-santi", "d-a-cd1": "d-a", "d-a-cd2": "d-a",
                "d-b": "r-gui", "d-b-cd1": "d-b",
            ],
            names: [
                "d-a": "第一部", "d-a-cd1": "CD1", "d-a-cd2": "CD2",
                "d-b": "第一部", "d-b-cd1": "CD1",
                "a1": "01.mp3", "a2": "01.mp3", "b1": "01.mp3",
            ],
            rootNames: ["r-santi": "三体", "r-gui": "鬼吹灯"]
        )
        var cache: [String: String] = [:]
        #expect(folders.path(ofFile: "a2", directoryPaths: &cache) == "d-a/第一部/CD2/01.mp3")
        #expect(folders.path(ofFile: "b1", directoryPaths: &cache) == "d-b/第一部/CD1/01.mp3")

        let result = books(["b1", "a2", "a1"], folders: folders, tracks: ["a1": 1, "a2": 1, "b1": 1])
        #expect(result.count == 2)
        #expect(Set(result.map { $0.items.map(\.id) }) == [["a1", "a2"], ["b1"]])
    }

    @Test("Picked folders of one name, and a picked folder named like another's subfolder, stay apart")
    func sameNamedScanRoots() {
        // r-1 and r-2 are both called 三体 and hold the files themselves; r-books holds a
        // 三体 of its own, and two folders called 合集 sit side by side in it.
        let folders = SpokenWordBookItemFolders(
            fileParents: ["a1": "r-1", "a2": "r-1", "b1": "r-2", "c1": "d-santi", "x1": "d-x", "y1": "d-y"],
            directoryParents: ["d-santi": "r-books", "d-x": "r-books", "d-y": "r-books"],
            names: [
                "d-santi": "三体", "d-x": "合集", "d-y": "合集",
                "a1": "01.mp3", "a2": "02.mp3", "b1": "01.mp3", "c1": "01.mp3", "x1": "01.mp3", "y1": "01.mp3",
            ],
            rootNames: ["r-1": "三体", "r-2": "三体", "r-books": "有声书"]
        )
        var cache: [String: String] = [:]
        #expect(folders.path(ofFile: "a1", directoryPaths: &cache) == "r-1/三体/01.mp3")
        #expect(folders.path(ofFile: "b1", directoryPaths: &cache) == "r-2/三体/01.mp3")
        #expect(folders.path(ofFile: "c1", directoryPaths: &cache) == "d-santi/三体/01.mp3")
        #expect(folders.path(ofFile: "y1", directoryPaths: &cache) == "d-y/合集/01.mp3")

        let result = books(["a1", "a2", "b1", "c1", "x1", "y1"], folders: folders)
        #expect(Set(result.map { $0.items.map(\.id) }) == [["a1", "a2"], ["b1"], ["c1"], ["x1"], ["y1"]])
        #expect(result.filter { $0.title == "三体" }.count == 3)
    }

    // MARK: - UPnP / DLNA

    private static let mediaItems = "http://192.168.1.2:8200/MediaItems/"

    /// A UPnP scan index as `ConnectorLibraryFolderHierarchy` records it: the
    /// picked container, the containers below it, and each item under the
    /// container it was listed in, by its resource URL and title.
    private func upnpIndex(namingItems: Bool = true) -> [String: SourceSyncIndexedItem] {
        func folder(_ path: String, _ name: String, parent: String?) -> SourceSyncIndexedItem {
            SourceSyncIndexedItem(
                stableKey: "hierarchy-folder:" + path, path: path, displayName: name,
                parentPath: parent, isDirectory: true, size: 0, modifiedDate: nil, revision: nil
            )
        }
        func song(_ number: Int, in folder: String, title: String) -> SourceSyncIndexedItem {
            SourceSyncIndexedItem(
                stableKey: "hierarchy-song:s\(number)", path: Self.mediaItems + "\(number).mp3",
                displayName: namingItems ? title : nil, parentPath: folder, isDirectory: false,
                songIDs: ["s\(number)"], size: 1, modifiedDate: nil, revision: nil
            )
        }
        let rows = [
            folder("server-root:music", "Music", parent: nil),
            folder("server-folder:books", "有声书", parent: "server-root:music"),
            folder("server-folder:santi", "三体", parent: "server-folder:books"),
            folder("server-folder:gui", "鬼吹灯", parent: "server-folder:books"),
            song(1, in: "server-folder:santi", title: "第1集"),
            song(2, in: "server-folder:santi", title: "第2集"),
            song(3, in: "server-folder:gui", title: "第1集"),
            song(4, in: "server-folder:gui", title: "第2集"),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.stableKey, $0) })
    }

    private var upnpItemIDs: [String] { (1...4).map { Self.mediaItems + "\($0).mp3" } }

    private var upnpTitles: [String: String] {
        [
            Self.mediaItems + "1.mp3": "第1集", Self.mediaItems + "2.mp3": "第2集",
            Self.mediaItems + "3.mp3": "第1集", Self.mediaItems + "4.mp3": "第2集",
        ]
    }

    @Test("UPnP paths are resource URLs, and books go by the containers the scan saw")
    func upnpSourceType() {
        #expect(!MusicSourceType.upnp.itemPathsNameFolders)
        #expect(MusicSourceType.upnp.groupsBooksByScannedFolders)
        #expect(MusicSourceType.pan123.groupsBooksByScannedFolders)
        #expect(MusicSourceType.pan123.itemPathsNameFolders)
        #expect(!MusicSourceType.smb.groupsBooksByScannedFolders)
        #expect(!MusicSourceType.navidrome.groupsBooksByScannedFolders)
    }

    @Test("UPnP items group by the container they were listed in")
    func upnpGroupsByContainer() {
        let folders = SpokenWordFolderTopology(syncIndex: upnpIndex()).bookItemFolders
        var cache: [String: String] = [:]
        #expect(folders.path(ofFile: Self.mediaItems + "3.mp3", directoryPaths: &cache) == "Music/有声书/鬼吹灯/第1集")

        let result = books(
            upnpItemIDs, folders: folders, source: "upnp", reportedCatalogSourceIDs: ["upnp"], titles: upnpTitles
        )
        #expect(result.count == 2)
        #expect(Set(result.map(\.title)) == ["三体", "鬼吹灯"])
        #expect(Set(result.map { $0.items.map(\.id) }) == [
            [Self.mediaItems + "1.mp3", Self.mediaItems + "2.mp3"],
            [Self.mediaItems + "3.mp3", Self.mediaItems + "4.mp3"],
        ])

        // An item the server gave no title is still one name in its container.
        let untitled = SpokenWordFolderTopology(syncIndex: upnpIndex(namingItems: false)).bookItemFolders
        var untitledCache: [String: String] = [:]
        let path = untitled.path(ofFile: Self.mediaItems + "1.mp3", directoryPaths: &untitledCache)
        #expect(path?.hasPrefix("Music/有声书/三体/") == true)
        #expect(path?.split(separator: "/").count == 4)
    }

    @Test("Without its containers a UPnP server is never one book named after its URL")
    func upnpWithoutContainers() {
        let items = upnpItemIDs.map { id in
            item(id, title: upnpTitles[id], path: id, source: "upnp")
        }
        // Read as folders, every URL sits in "MediaItems": the whole server one book.
        let asFolders = SpokenWordBookGrouping.books(from: items, catalogSourceIDs: [])
        #expect(asFolders.count == 1)
        #expect(asFolders.first?.title == "MediaItems")

        // As a source whose paths name no folder: untagged items stand alone…
        #expect(SpokenWordBookGrouping.books(from: items, catalogSourceIDs: ["upnp"]).count == 4)
        // …and tagged ones go by their album.
        let tagged = upnpItemIDs.enumerated().map { offset, id in
            item(id, title: upnpTitles[id], album: offset < 2 ? "三体" : "鬼吹灯", path: id, source: "upnp")
        }
        let byAlbum = SpokenWordBookGrouping.books(from: tagged, catalogSourceIDs: ["upnp"])
        #expect(Set(byAlbum.map(\.title)) == ["三体", "鬼吹灯"])
    }

    @Test("A UPnP file its scan never placed names no folder, while a drive's keeps its id")
    func unplacedFiles() {
        let folders = SpokenWordFolderTopology(syncIndex: upnpIndex()).bookItemFolders
        var cache: [String: String] = [:]
        let stray = Self.mediaItems + "99.mp3"
        let upnpPath = SpokenWordBookSourcePaths.groupingPath(
            filePath: stray, folders: folders, pathNamesFolders: false, directoryPaths: &cache
        )
        #expect(!upnpPath.contains("/"))
        #expect(SpokenWordBookSourcePaths.groupingPath(
            filePath: "file-id", folders: folders, pathNamesFolders: true, directoryPaths: &cache
        ) == "file-id")

        let result = books(
            upnpItemIDs + [stray], folders: folders, source: "upnp", reportedCatalogSourceIDs: ["upnp"],
            titles: upnpTitles
        )
        #expect(result.count == 3)
        #expect(result.contains { $0.items.map(\.id) == [stray] })
    }

    @Test("A catalogue source is judged by its folders while they are known")
    func catalogueSourcesWithFolders() {
        let folders = SpokenWordFolderTopology(syncIndex: upnpIndex()).bookItemFolders
        #expect(SpokenWordBookSourcePaths.catalogSourceIDs(
            reported: ["upnp", "navidrome"], itemFolders: ["upnp": folders, "drive": folders]
        ) == ["navidrome"])
        #expect(SpokenWordBookSourcePaths.catalogSourceIDs(reported: ["upnp"], itemFolders: [:]) == ["upnp"])
    }

    // MARK: - The copy kept across launches

    @Test("The book folders read back exactly as they were written")
    func archiveRoundTrip() {
        let drive = SpokenWordBookItemFolders(
            fileParents: ["f\t1": "d-a", "f2": "d-a", "f3": "d-b", "shared": "d-a"],
            directoryParents: ["d-a": "root", "d-b": "d-a", "shared": "root"],
            names: [
                "d-a": "有声书\\备份", "d-b": "第一部\n续\r", "root": "我的网盘",
                "f\t1": "01.mp3", "f2": "", "shared": "既是目录也是文件.mp3", "lone": "孤儿.mp3",
            ],
            rootNames: ["root": "", "other-root": "鬼吹灯"]
        )
        var upnpFiles: [String: String] = [:]
        var upnpNames: [String: String] = ["server-root:music": "Music", "server-folder:a": "三体", "server-folder:b": "鬼吹灯"]
        for number in 1...40 {
            let id = Self.mediaItems + "\(number).mp3"
            upnpFiles[id] = number <= 20 ? "server-folder:a" : "server-folder:b"
            upnpNames[id] = "第\(number)集"
        }
        let upnp = SpokenWordBookItemFolders(
            fileParents: upnpFiles,
            directoryParents: ["server-folder:a": "server-root:music", "server-folder:b": "server-root:music"],
            names: upnpNames
        )
        let sources = [
            "drive": drive,
            "upnp": upnp,
            "empty\tsource": SpokenWordBookItemFolders(fileParents: [:], directoryParents: [:], names: [:]),
        ]
        let data = SpokenWordBookItemFoldersArchive.encode(sources)
        #expect(SpokenWordBookItemFoldersArchive.decode(data) == sources)
        #expect(SpokenWordBookItemFoldersArchive.encode(sources) == data)

        // Each folder written once, and the start the URLs share once.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "MediaItems").count == 2)
        #expect(text.components(separatedBy: "server-folder:a").count == 2)

        #expect(SpokenWordBookItemFoldersArchive.decode(SpokenWordBookItemFoldersArchive.encode([:])) == [:])
    }

    @Test("The file format, and what is not one")
    func archiveFormat() {
        func decode(_ text: String) -> [String: SpokenWordBookItemFolders]? {
            SpokenWordBookItemFoldersArchive.decode(Data(text.utf8))
        }
        let written = decode(
            "primuse-book-folders 1\nS\tdrive\nD\td-a\t\t三体\nR\t0\t三体\nF\t0\tf1\t0\t01.mp3\nF\t1\t2\t0\n"
        )
        #expect(written == ["drive": SpokenWordBookItemFolders(
            fileParents: ["f1": "d-a", "f2": "d-a"],
            directoryParents: [:],
            names: ["d-a": "三体", "f1": "01.mp3"],
            rootNames: ["d-a": "三体"]
        )])

        #expect(SpokenWordBookItemFoldersArchive.decode(Data()) == nil)
        #expect(decode("primuse-book-folders 2\nS\tdrive\n") == nil)
        // A record before any source, a folder index past the folders, a shared prefix
        // longer than the id before it, an unknown record.
        #expect(decode("primuse-book-folders 1\nD\td-a\t\n") == nil)
        #expect(decode("primuse-book-folders 1\nS\tdrive\nD\td-a\t\nF\t0\tf1\t1\n") == nil)
        #expect(decode("primuse-book-folders 1\nS\tdrive\nD\td-a\t\nF\t3\tf1\t0\n") == nil)
        #expect(decode("primuse-book-folders 1\nS\tdrive\nX\tsomething\n") == nil)
    }
}
