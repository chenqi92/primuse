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

    @Test("Folder podcast tags survive extraction and override file inference in both classification paths")
    func podcastFolderClassification() {
        let tags = SpokenWordFolderTag.folderTags(in: [
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Podcasts"): .podcast,
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Music"): .music,
            "episode": .spokenWord,
        ])
        #expect(tags == ["nas": ["/Podcasts": .podcast, "/Music": .music]])
        let inputs = SpokenWordClassificationInputs(
            overrides: ["corrected": .music],
            folderRules: SpokenWordFolderRules(folderTags: tags, sources: [descriptor("nas", .webdav)])
        )
        var verdicts: [String: ListeningContentKind] = [:]
        for path in ["/Podcasts/show/01.mp3", "/Podcasts/episode.m4b"] {
            #expect(inputs.kind(songID: "episode", sourceID: "nas", filePath: path, genre: "Audiobook") == .podcast)
            #expect(inputs.kind(songID: "episode", sourceID: "nas", filePath: path, genre: "Audiobook", genreVerdicts: &verdicts) == .podcast)
            #expect(inputs.kind(songID: "corrected", sourceID: "nas", filePath: path, genre: nil) == .music)
        }
        #expect(inputs.inferredKind(sourceID: "nas", filePath: "/Podcasts2/song.mp3", genre: nil) == .music)
        #expect(inputs.inferredKind(sourceID: "other", filePath: "/Podcasts/song.mp3", genre: nil) == .music)
    }

    @Test("The closest folder tag wins in either direction without changing siblings")
    func nestedPodcastFolders() {
        for (parent, child) in [(ListeningContentKind.spokenWord, ListeningContentKind.podcast), (.podcast, .spokenWord)] {
            let rules = SpokenWordFolderRules(
                folderTags: ["nas": ["/Audio/": parent, "/Audio/Show": child]],
                sources: [descriptor("nas", .smb)]
            )
            #expect(rules.kind(sourceID: "nas", filePath: "/Audio/Show/Season/01.mp3") == child)
            #expect(rules.kind(sourceID: "nas", filePath: "/Audio/Show2/01.mp3") == parent)
            #expect(rules.kind(sourceID: "nas", filePath: "/Elsewhere/01.mp3") == nil)
        }
    }

    @Test("A subfolder tagged music under a spoken-word folder goes back to what its files say")
    func musicSubfolderStopsTheParentTag() {
        let tags = SpokenWordFolderTag.folderTags(in: [
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Books"): .spokenWord,
            SpokenWordFolderTag.overrideKey(sourceID: "nas", path: "/Books/Soundtrack"): .music,
        ])
        let rules = SpokenWordFolderRules(folderTags: tags, sources: [descriptor("nas", .smb)])
        #expect(rules.kind(sourceID: "nas", filePath: "/Books/01.mp3") == .spokenWord)
        #expect(rules.kind(sourceID: "nas", filePath: "/Books/Three Body/Disc 1/01.mp3") == .spokenWord)
        #expect(rules.kind(sourceID: "nas", filePath: "/Books/Soundtrack/01.mp3") == nil)
        #expect(rules.kind(sourceID: "nas", filePath: "/Books/Soundtrack/Deluxe/02.flac") == nil)
        #expect(rules.kind(sourceID: "nas", filePath: "/Books/Soundtrack2/01.mp3") == .spokenWord)

        let inputs = SpokenWordClassificationInputs(folderRules: rules)
        var verdicts: [String: ListeningContentKind] = [:]
        for (path, genre, expected) in [
            ("/Books/Soundtrack/01.mp3", nil, ListeningContentKind.music),
            ("/Books/Soundtrack/01.mp3", "Audiobook", .spokenWord),
            ("/Books/Soundtrack/02.m4b", nil, .spokenWord),
            ("/Books/Other/01.mp3", nil, .spokenWord),
        ] as [(String, String?, ListeningContentKind)] {
            #expect(inputs.kind(songID: path, sourceID: "nas", filePath: path, genre: genre) == expected)
            #expect(inputs.kind(songID: path, sourceID: "nas", filePath: path, genre: genre, genreVerdicts: &verdicts) == expected)
        }

        // 只有音乐标签的源没有要改的,不算有规则。
        let musicOnly = SpokenWordFolderRules(folderTags: ["nas": ["/Music": .music]], sources: [descriptor("nas", .smb)])
        #expect(musicOnly.isEmpty)
    }

    @Test("Library and whole-source music choices stay out of the folder table")
    func reservedMusicTagsAreNotFolders() {
        let tags = SpokenWordFolderTag.folderTags(in: [
            SpokenWordFolderTag.overrideKey(sourceID: "abs", path: SpokenWordFolderTag.libraryPath(libraryID: "songs")): .music,
            SpokenWordFolderTag.overrideKey(sourceID: "nd", path: SpokenWordFolderTag.wholeSourcePath): .music,
            SpokenWordFolderTag.overrideKey(sourceID: "abs", path: SpokenWordFolderTag.libraryPath(libraryID: "books")): .spokenWord,
            SpokenWordFolderTag.overrideKey(sourceID: "gd", path: "ost"): .music,
        ])
        #expect(tags == [
            "abs": [SpokenWordFolderTag.libraryPath(libraryID: "books"): .spokenWord],
            "gd": ["ost": .music],
        ])
        // Audiobookshelf 的音乐库仍按来源默认(有声)处理,和改动之前一样。
        let rules = SpokenWordFolderRules(
            folderTags: tags, sources: [descriptor("abs", .audiobookshelf)], declaredSpokenWordSourceIDs: ["abs"]
        )
        #expect(rules.kind(sourceID: "abs", filePath: "x", serverLibraryID: "songs") == .spokenWord)
    }

    @Test("On an item-id cloud drive a music subfolder stops the parent tag at every depth below it")
    func cloudMusicSubfolder() {
        let topology = SpokenWordFolderTopology(
            fileParents: ["ch1": "santi", "intro": "books", "ost1": "ost", "ost2": "bonus"],
            directoryParents: ["santi": "books", "ost": "books", "bonus": "ost", "books": "root"]
        )
        let kinds = topology.fileKinds(in: ["books": .spokenWord, "ost": .music])
        #expect(kinds == ["ch1": .spokenWord, "intro": .spokenWord])
        #expect(topology.fileKinds(in: ["ost": .music]).isEmpty)
    }

    @Test("A folder without its own tag shows the nearest tagged parent, by path or by the folders passed")
    func tagStateFollowsNearestParent() {
        let tags: [String: ListeningContentKind] = ["/Books/": .spokenWord, "/Books/OST": .music]
        let child = SpokenWordFolderTagState.resolve(path: "/Books/Three Body", ancestors: [], sourceType: .smb, tags: tags)
        #expect(child == SpokenWordFolderTagState(own: nil, inherited: .spokenWord, inheritedFrom: "/Books/"))
        #expect(child.kind == .spokenWord)
        #expect(child.followsParent)
        // 和上级一致就不存,改回音乐要存成显式的音乐,改成播客照存。
        #expect(child.storedTag(choosing: .spokenWord) == nil)
        #expect(child.storedTag(choosing: .music) == .music)
        #expect(child.storedTag(choosing: .podcast) == .podcast)

        let own = SpokenWordFolderTagState.resolve(path: "/Books", ancestors: [], sourceType: .smb, tags: tags)
        #expect(own == SpokenWordFolderTagState(own: .spokenWord))
        #expect(!own.followsParent)
        #expect(own.storedTag(choosing: .music) == nil)

        // 最近一级是音乐:看起来和没标签一样,不算「跟随」。
        let underMusic = SpokenWordFolderTagState.resolve(path: "/Books/OST/Disc 1", ancestors: [], sourceType: .smb, tags: tags)
        #expect(underMusic.kind == .music)
        #expect(underMusic.inheritedFrom == "/Books/OST")
        #expect(!underMusic.followsParent)
        #expect(underMusic.storedTag(choosing: .music) == nil)
        #expect(underMusic.storedTag(choosing: .spokenWord) == .spokenWord)

        let lookAlike = SpokenWordFolderTagState.resolve(path: "/Books2/A", ancestors: [], sourceType: .smb, tags: tags)
        #expect(lookAlike == SpokenWordFolderTagState(own: nil))

        // ID 寻址的网盘只能靠浏览经过的各级认上级;按库标的不算目录。
        let cloudTags: [String: ListeningContentKind] = [
            "books-id": .spokenWord, SpokenWordFolderTag.libraryPath(libraryID: "books-id"): .podcast,
        ]
        let cloudChild = SpokenWordFolderTagState.resolve(
            path: "santi-id", ancestors: ["/", "books-id"], sourceType: .googleDrive, tags: cloudTags
        )
        #expect(cloudChild.inheritedFrom == "books-id")
        #expect(cloudChild.kind == .spokenWord)
        #expect(SpokenWordFolderTagState.resolve(
            path: "santi-id", ancestors: ["/", "music-id"], sourceType: .googleDrive, tags: cloudTags
        ) == SpokenWordFolderTagState(own: nil))
        // 整个源标成有声(根)覆盖一切,但比任何目录都远。
        let wholeSource = SpokenWordFolderTagState.resolve(
            path: "santi-id", ancestors: ["/", "books-id"], sourceType: .googleDrive,
            tags: ["/": .podcast, "books-id": .spokenWord]
        )
        #expect(wholeSource.inheritedFrom == "books-id")
        #expect(SpokenWordFolderTagState.resolve(
            path: "santi-id", ancestors: [], sourceType: .googleDrive, tags: ["/": .podcast]
        ).inheritedFrom == "/")
    }

    @Test("The nearest enclosing folder is found by prefix on folder paths and by the chain elsewhere")
    func nearestEnclosingFolder() {
        let candidates = ["/", "/A", "/A/B", "/A/BC", "/X"]
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(of: "/A/B/C", among: candidates, for: .smb) == "/A/B")
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(of: "/A/B", among: candidates, for: .smb) == "/A")
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(of: "/A", among: candidates, for: .smb) == "/")
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(of: "/A", among: ["/A/"], for: .smb) == nil)
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(of: "/Q", among: ["/A"], for: .smb) == nil)
        // 按 ID 寻址:路径看不出上下级,链里越靠后越近,不在链里的不算。
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(
            of: "c", among: ["a", "b", "x"], ancestors: ["/", "a", "b"], for: .googleDrive
        ) == "b")
        #expect(SourceDirectorySelectionPolicy.nearestEnclosing(
            of: "c", among: ["x"], ancestors: ["/", "a", "b"], for: .googleDrive
        ) == nil)
    }

    @Test("Opaque cloud folders retain podcast kinds through nested tags, moves and cycles")
    func cloudPodcastFolders() {
        let topology = SpokenWordFolderTopology(
            fileParents: ["episode": "season", "chapter": "books", "song": "music", "cycle": "a"],
            directoryParents: ["season": "show", "show": "books", "a": "b", "b": "a"]
        )
        let tags: [String: ListeningContentKind] = ["books": .spokenWord, "show": .podcast]
        #expect(topology.fileKinds(in: tags) == ["episode": .podcast, "chapter": .spokenWord])
        let rules = SpokenWordFolderRules(
            folderTags: ["gd": tags], sources: [descriptor("gd", .googleDrive)],
            taggedFileKinds: ["gd": topology.fileKinds(in: tags)]
        )
        #expect(rules.kind(sourceID: "gd", filePath: "episode") == .podcast)
        #expect(rules.kind(sourceID: "gd", filePath: "chapter") == .spokenWord)
        #expect(rules.kind(sourceID: "gd", filePath: "song") == nil)
        #expect(topology.fileKinds(in: ["books": .podcast, "show": .spokenWord])["episode"] == .spokenWord)
        #expect(topology.fileKinds(in: [:]).isEmpty)
    }

    @Test("A tagged podcast library takes priority over its audiobook source default")
    func podcastLibraryOverridesSource() {
        let rules = SpokenWordFolderRules(
            folderTags: ["abs": [SpokenWordFolderTag.libraryPath(libraryID: "shows"): .podcast]],
            sources: [descriptor("abs", .audiobookshelf)], declaredSpokenWordSourceIDs: ["abs"]
        )
        #expect(rules.kind(sourceID: "abs", filePath: "episode", serverLibraryID: "shows") == .podcast)
        #expect(rules.kind(sourceID: "abs", filePath: "chapter", serverLibraryID: "books") == .spokenWord)
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

    @Test("An id-addressed source can be tagged as a whole; the reserved root path means every song")
    func wholeSourceTag() {
        let rules = SpokenWordFolderRules(
            folders: ["nd": [SpokenWordFolderTag.wholeSourcePath], "gd": ["folder-id"]],
            sources: [descriptor("nd", .navidrome), descriptor("gd", .googleDrive)]
        )
        #expect(!rules.isEmpty)
        #expect(rules.containsSong(sourceID: "nd", filePath: "/songs/abc.flac"))
        #expect(rules.containsSong(sourceID: "nd", filePath: "/songs/xyz.mp3", serverLibraryID: nil))
        #expect(!rules.containsSong(sourceID: "gd", filePath: "/file-id.mp3"))
        #expect(SpokenWordFolderTag.supportsWholeSourceTag(descriptor("nd", .navidrome)))
        #expect(!SpokenWordFolderTag.supportsWholeSourceTag(descriptor("nas", .smb)))
    }

    @Test("Item-id cloud drives tag folders; whole-catalogue servers and media servers do not")
    func folderTagSupportByType() {
        #expect(SpokenWordFolderTag.supportsFolderTags(for: .googleDrive))
        #expect(SpokenWordFolderTag.supportsFolderTags(for: .pan123))
        #expect(SpokenWordFolderTag.supportsFolderTags(for: .smb))
        #expect(SpokenWordFolderTag.supportsFolderTags(for: .baiduPan))
        #expect(!SpokenWordFolderTag.supportsFolderTags(for: .navidrome))
        #expect(!SpokenWordFolderTag.supportsFolderTags(for: .songloft))
        #expect(!SpokenWordFolderTag.supportsFolderTags(for: .jellyfin))
        #expect(SpokenWordFolderTag.isReservedPath(SpokenWordFolderTag.wholeSourcePath))
        #expect(SpokenWordFolderTag.isReservedPath(SpokenWordFolderTag.libraryPath(libraryID: "b")))
        #expect(!SpokenWordFolderTag.isReservedPath("1AbCdEfG"))
    }

    private func item(_ path: String, parent: String?, directory: Bool) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(
            stableKey: path, path: path, parentPath: parent, isDirectory: directory,
            size: 0, modifiedDate: nil, revision: nil
        )
    }

    @Test("Files under a tagged cloud folder match through every level of subfolder; siblings do not")
    func cloudFolderTopology() {
        // root(扫描目录) ─┬─ books ─┬─ 三体 ── ch1.mp3, ch2.mp3
        //                 │         └─ intro.mp3
        //                 └─ music ── song.flac, loose.mp3 直接在 root 下
        let index = [
            item("books", parent: "root", directory: true),
            item("santi", parent: "books", directory: true),
            item("music", parent: "root", directory: true),
            item("ch1", parent: "santi", directory: false),
            item("ch2", parent: "santi", directory: false),
            item("intro", parent: "books", directory: false),
            item("song", parent: "music", directory: false),
            item("loose", parent: "root", directory: false),
        ].reduce(into: [String: SourceSyncIndexedItem]()) { $0[$1.stableKey] = $1 }
        let topology = SpokenWordFolderTopology(syncIndex: index)
        #expect(topology.directoryParents == ["books": "root", "santi": "books", "music": "root"])
        #expect(topology.files(inside: ["books"]) == ["ch1", "ch2", "intro"])
        #expect(topology.files(inside: ["santi"]) == ["ch1", "ch2"])
        #expect(topology.files(inside: ["root"]) == ["ch1", "ch2", "intro", "song", "loose"])
        #expect(topology.files(inside: ["santi", "music"]) == ["ch1", "ch2", "song"])
        #expect(topology.files(inside: []).isEmpty)
        #expect(topology.files(inside: ["unknown-folder"]).isEmpty)

        let rules = SpokenWordFolderRules(
            folders: ["gd": ["books"]],
            sources: [descriptor("gd", .googleDrive)],
            taggedFolderFiles: ["gd": topology.files(inside: ["books"])]
        )
        #expect(!rules.isEmpty)
        #expect(rules.containsSong(sourceID: "gd", filePath: "ch1"))
        #expect(rules.containsSong(sourceID: "gd", filePath: "intro"))
        #expect(!rules.containsSong(sourceID: "gd", filePath: "song"))
        #expect(!rules.containsSong(sourceID: "other", filePath: "ch1"))
        // 没有算出来的文件(扫描索引还没装载)时不算有规则。
        let empty = SpokenWordFolderRules(
            folders: ["gd": ["books"]], sources: [descriptor("gd", .googleDrive)], taggedFolderFiles: ["gd": []]
        )
        #expect(empty.isEmpty)
    }

    @Test("A folder listed as its own ancestor does not hang the walk")
    func cloudFolderCycle() {
        let topology = SpokenWordFolderTopology(
            fileParents: ["f1": "a", "f2": "c"],
            directoryParents: ["a": "b", "b": "a", "c": "books"]
        )
        #expect(topology.files(inside: ["books"]) == ["f2"])
        #expect(topology.files(inside: ["b"]) == ["f1"])
    }

    @Test("A server library tag matches by the library id stamped on the song, never by path")
    func libraryTag() {
        let path = SpokenWordFolderTag.libraryPath(libraryID: "lib-books")
        #expect(SpokenWordFolderTag.libraryID(fromTagPath: path) == "lib-books")
        #expect(SpokenWordFolderTag.libraryID(fromTagPath: "/libraries/") == nil)
        #expect(SpokenWordFolderTag.libraryID(fromTagPath: "/libraries/a/b") == nil)
        #expect(SpokenWordFolderTag.libraryID(fromTagPath: "/Books") == nil)
        let rules = SpokenWordFolderRules(
            folders: ["jf": [path]],
            sources: [descriptor("jf", .jellyfin)]
        )
        #expect(rules.containsSong(sourceID: "jf", filePath: "/items/1.m4a", serverLibraryID: "lib-books"))
        #expect(!rules.containsSong(sourceID: "jf", filePath: "/items/2.m4a", serverLibraryID: "lib-music"))
        #expect(!rules.containsSong(sourceID: "jf", filePath: "/libraries/lib-books/items/3.m4a"))
        #expect(!rules.containsSong(sourceID: "other", filePath: "/items/1.m4a", serverLibraryID: "lib-books"))
    }

    @Test("A source type that declares spoken word needs no tag, and a per-song correction still wins")
    func declaredSource() {
        let rules = SpokenWordFolderRules(
            folders: [:],
            sources: [descriptor("abs", .audiobookshelf)],
            declaredSpokenWordSourceIDs: ["abs"]
        )
        #expect(!rules.isEmpty)
        #expect(rules.containsSong(sourceID: "abs", filePath: "/items/x/files/1.mp3"))
        let inputs = SpokenWordClassificationInputs(overrides: ["music-in-abs": .music], folderRules: rules)
        #expect(inputs.kind(songID: "music-in-abs", sourceID: "abs", filePath: "/items/x/files/1.mp3", genre: nil) == .music)
        #expect(inputs.kind(songID: "other", sourceID: "abs", filePath: "/items/x/files/2.mp3", genre: "Rock") == .spokenWord)
        #expect(inputs.inferredKind(sourceID: "abs", filePath: "/items/x/files/1.mp3", genre: nil) == .spokenWord)
        var verdicts: [String: ListeningContentKind] = [:]
        #expect(inputs.kind(songID: "other", sourceID: "abs", filePath: "/items/x/files/2.mp3", genre: "Rock", genreVerdicts: &verdicts) == .spokenWord)
    }

    @Test("The library id reaches both classification entry points")
    func libraryIDThroughInputs() {
        let rules = SpokenWordFolderRules(
            folders: ["jf": [SpokenWordFolderTag.libraryPath(libraryID: "books")]],
            sources: [descriptor("jf", .jellyfin)]
        )
        let inputs = SpokenWordClassificationInputs(folderRules: rules)
        var verdicts: [String: ListeningContentKind] = [:]
        #expect(inputs.kind(songID: "a", sourceID: "jf", filePath: "/items/1.mp3", genre: "Pop", serverLibraryID: "books") == .spokenWord)
        #expect(inputs.kind(songID: "a", sourceID: "jf", filePath: "/items/1.mp3", genre: "Pop", serverLibraryID: "music") == .music)
        #expect(inputs.kind(songID: "a", sourceID: "jf", filePath: "/items/1.mp3", genre: "Pop", serverLibraryID: "books", genreVerdicts: &verdicts) == .spokenWord)
        #expect(inputs.kind(songID: "a", sourceID: "jf", filePath: "/items/1.mp3", genre: "Pop", serverLibraryID: nil, genreVerdicts: &verdicts) == .music)
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

    @Test("Inference inside a tagged folder is spoken word, so marking music there needs an explicit correction")
    func inferredKindCountsFolderTags() {
        let rules = SpokenWordFolderRules(folders: ["nas": ["/Books"]], sources: [descriptor("nas", .smb)])
        let inputs = SpokenWordClassificationInputs(folderRules: rules)
        #expect(inputs.inferredKind(sourceID: "nas", filePath: "/Books/a.mp3", genre: nil) == .spokenWord)
        #expect(inputs.inferredKind(sourceID: "nas", filePath: "/Music/a.mp3", genre: nil) == .music)
        // The row's menu stores `next == inferred ? nil : next`: inside the folder
        // that must come out as a stored .music, not a cleared entry.
        let next = ListeningContentKind.music
        let inferred = inputs.inferredKind(sourceID: "nas", filePath: "/Books/a.mp3", genre: nil)
        let stored: ListeningContentKind? = next == inferred ? nil : next
        #expect(stored == .music)
        let corrected = SpokenWordClassificationInputs(overrides: ["s": .music], folderRules: rules)
        #expect(corrected.kind(songID: "s", sourceID: "nas", filePath: "/Books/a.mp3", genre: nil) == .music)
    }

    @Test("The memoized whole-library pass classifies exactly like the per-song call")
    func memoizedPassMatches() {
        let rules = SpokenWordFolderRules(folders: ["nas": ["/Books"]], sources: [descriptor("nas", .smb)])
        let inputs = SpokenWordClassificationInputs(
            overrides: ["forced-music": .music, "forced-book": .spokenWord, "forced-podcast": .podcast],
            folderRules: rules
        )
        let paths = [
            "/Books/a.mp3", "/Music/a.m4b", "/Music/a.M4B", "/Music/a.m4b/", "/Music/m4b/a.mp3",
            "/Music/a.m4bx", "/Music/a.xm4b", "/Music/M4B", "/Music/a.m4a", "/Music/有声.mp3", "",
        ]
        let genres: [String?] = [nil, "", "Pop", "Audio Book", "audio-book", "有声书", "Rock", "Pop", "相声 集锦", "Podcast", "播客"]
        var verdicts: [String: ListeningContentKind] = [:]
        for songID in ["plain", "forced-music", "forced-book", "forced-podcast"] {
            for sourceID in ["nas", "cloud"] {
                for path in paths {
                    for genre in genres {
                        let expected = inputs.kind(songID: songID, sourceID: sourceID, filePath: path, genre: genre)
                        let actual = inputs.kind(
                            songID: songID, sourceID: sourceID, filePath: path, genre: genre,
                            genreVerdicts: &verdicts
                        )
                        #expect(actual == expected, "\(songID) \(sourceID) \(path) \(genre ?? "nil")")
                    }
                }
            }
        }
    }

    @Test("Playlist-only songs are part of the inputs the library compares")
    func collectionOnlySongsChangeTheInputs() {
        let base = SpokenWordClassificationInputs(overrides: ["s": .music])
        var withPlaylistOnly = base
        withPlaylistOnly.collectionOnlySongIDs = ["a"]
        // The library re-splits only when the inputs differ, so a sync that
        // changes nothing but this set must still be seen as a change.
        #expect(base != withPlaylistOnly)
        #expect(SpokenWordClassificationInputs.empty.collectionOnlySongIDs.isEmpty)
        // Being listed only in a playlist says nothing about the kind itself.
        #expect(withPlaylistOnly.kind(songID: "a", sourceID: "x", filePath: "a.mp3", genre: nil) == .music)
    }

    @Test("The byte prefilter agrees with the path-extension check")
    func audiobookExtensionPrefilter() {
        let paths = [
            "a.m4b", "a.M4b", "a.m4B", "/x/y.m4b", "/x/y.m4b/", "/x/y.m4b//", "m4b", ".m4b", "a.m4b.mp3",
            "/m4b/a.mp3", "a.m4", "a.4b", "a.mb", "/书/第一章.m4b", "/书/第一章.ｍ4b", "a.m4b ", "",
        ]
        for path in paths {
            let expected = (path as NSString).pathExtension.lowercased() == SpokenWordContentPolicy.audiobookFileExtension
            #expect(SpokenWordContentPolicy.pathHasAudiobookExtension(path) == expected, "\(path)")
        }
    }
}
