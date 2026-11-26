import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// P1 双写:`MusicLibrary` 每条写进 `library-songs.sqlite` 的变更都跟进目录,
/// 每一步之后用影子校验的深模式拿目录与内存模型逐项比对(专辑、艺人、分类、书、
/// 库内顺序、按源计数、流派)。另有老用户启动迁移、旧版本造成的漂移、读接口与
/// 内存答案的对照。
@MainActor
final class LibraryCatalogDualWriteTests: XCTestCase {
    private var directory: URL!
    private var libraries: [MusicLibrary] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCatalogDualWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for library in libraries { await library.stopCatalogMirror() }
        libraries = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary(
        catalog: LibraryCatalogMirroring = .enabled(startDelay: .zero),
        disabledSourceIDs: Set<String> = [],
        maintenanceAllowed: @escaping @MainActor () -> Bool = { true }
    ) -> MusicLibrary {
        let library = MusicLibrary(
            disabledSourceIDs: disabledSourceIDs,
            storageDirectory: directory,
            artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: maintenanceAllowed,
            catalogMirroring: catalog
        )
        library.catalogShadowModeOverride = .deep
        libraries.append(library)
        return library
    }

    static let sourceA = "dual-write-a"
    static let sourceB = "dual-write-b"

    /// 两个源;合唱、专辑艺人推断用的无标签目录、跨源同名专辑、有声书(m4b)、播客、
    /// 环境音、CUE 分轨(同一个文件)、多流派写法。
    static func fixture(prefix: String = UUID().uuidString.prefix(6).lowercased()) -> [Song] {
        var songs: [Song] = []
        func add(_ id: String, _ title: String, album: String?, artist: String?, albumArtist: String? = nil,
                 track: Int? = nil, disc: Int? = 1, path: String, source: String = sourceA,
                 genre: String? = "Pop", format: AudioFormat = .flac, cover: String? = nil, year: Int? = 2001,
                 added: TimeInterval = 0) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: albumArtist,
                trackNumber: track, discNumber: disc, duration: 180 + Double(songs.count), fileFormat: format,
                filePath: path, sourceID: source, genre: genre, year: year, coverArtFileName: cover
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000 + added + Double(songs.count))
            songs.append(song)
        }
        for track in 1...4 {
            add("blue-\(track)", "Blue \(track)", album: "Blue Room", artist: track == 2 ? "Ada、Ben" : "Ada",
                albumArtist: "Ada", track: track, path: "/Music/Ada/Blue Room/\(track).flac", cover: track == 1 ? "blue.jpg" : nil)
        }
        for track in 1...3 {
            add("comp-\(track)", "Comp \(track)", album: "Mixtape", artist: "Artist \(track)", track: track,
                path: "/Music/Mixtape/\(track).flac", genre: "Rock/Pop")
        }
        // 跨源同名专辑。
        for track in 1...2 {
            add("blueb-\(track)", "Blue B\(track)", album: "Blue Room", artist: "Ada", albumArtist: "Ada", track: track,
                path: "/Share/Ada/Blue Room/\(track).flac", source: sourceB)
        }
        add("loose", "Loose Track", album: nil, artist: nil, path: "/Music/Loose/loose.mp3", genre: nil, format: .mp3)
        for chapter in 1...3 {
            add("book-\(chapter)", "Chapter \(chapter)", album: "Long Story", artist: "Narrator", track: chapter,
                path: "/Books/Long Story/\(chapter).m4b", genre: "Audiobook", format: .m4a)
        }
        for episode in 1...2 {
            add("pod-\(episode)", "Episode \(episode)", album: "Weekly Show", artist: "Host", track: episode,
                path: "/Podcasts/Weekly/\(episode).mp3", source: sourceB, genre: "Podcast", format: .mp3)
        }
        add("rain", "Rain", album: "Sleep", artist: "Nature", path: "/Ambient/rain.flac", genre: "White Noise")
        for track in 1...2 {
            add("cue-\(track)", "Cue \(track)", album: "Live Set", artist: "DJ", track: track,
                path: "/Music/Live/set.flac", genre: "Electronic", cover: "set.jpg", added: 50)
        }
        return songs
    }

    private func assertShadowMatches(
        _ library: MusicLibrary,
        _ step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await library.waitForCatalogMirror()
        let report = await library.verifyCatalogShadow(reason: step, mode: .deep)
        XCTAssertEqual(report?.outcome, .matched, "\(step): \(report?.logLine ?? "no report (skipped)")", file: file, line: line)
    }

    // MARK: - Dual-write per entry point

    func testAddReplaceAndAssetEditsAreMirrored() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")
        XCTAssertNotNil(library.catalogHost?.mirror.readableCatalog)

        songs[0].title = "Blue One (Remaster)"
        library.replaceSong(songs[0])
        await assertShadowMatches(library, "replaceSong")

        songs[5].albumTitle = "Mixtape Deluxe"
        songs[6].albumTitle = "Mixtape Deluxe"
        library.replaceSongs([songs[5], songs[6]])
        await assertShadowMatches(library, "replaceSongs")

        library.updateLyricsText([songs[1].id: "la la la"])
        library.updateAssetReferences(songID: songs[2].id, coverRef: "blue-alt.jpg")
        library.updateMusicVideoReference(songID: songs[3].id, mvPath: "/Videos/blue.mp4")
        await assertShadowMatches(library, "lyrics/asset/MV references")
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        XCTAssertEqual(try catalog.song(id: songs[1].id)?.lyricsText, "la la la")
        XCTAssertEqual(try catalog.song(id: songs[2].id)?.coverArtFileName, "blue-alt.jpg")
    }

    /// 迁移做完后,整库维护那道门关着(App 在后台、温度高)时,突变照样很快写进目录:
    /// 读目录的地方不会读到旧值。
    func testMutationsReachTheCatalogWhileBackgroundMaintenanceIsHeld() async throws {
        let held = InteractionFlag()
        let library = makeLibrary(maintenanceAllowed: { !held.isSet })
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")

        held.set()
        // 让镜像的巡检读到关上的门(每 250 ms 问一次)。
        try await Task.sleep(for: .milliseconds(600))
        songs[0].title = "Edited While Held"
        library.replaceSong(songs[0])
        let fresh = Song(id: "held-fresh", title: "Added While Held", albumTitle: "Held", artistName: "Held Artist",
                         fileFormat: .flac, filePath: "/Music/Held/01 Added.flac", sourceID: Self.sourceA)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA], notifyRemovals: false, pruneMissingSongs: false)
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var caughtUp = false
        while ContinuousClock.now < deadline {
            if try catalog.song(id: songs[0].id)?.title == "Edited While Held", try catalog.song(id: fresh.id) != nil {
                caughtUp = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(caughtUp, "incremental writes must not wait for the background-maintenance gate")
        held.set(false)
        await assertShadowMatches(library, "after the held writes")
    }

    /// 专辑页的目录路径(按艺术家、标题、年份;页内搜索、隐藏单曲专辑)给出的专辑与先后,
    /// 和内存路径(`LibraryAlbumBrowseLayoutBuilder` + 同一个筛选条件)一样,分段也一样。
    func testAlbumGridCatalogMatchesTheInMemoryOrderAndFilters() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        let unknown = String(localized: "unknown_artist")
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertGreaterThan(library.visibleAlbums.count, 3)
        for order in [LibraryAlbumBrowseOrder.artist, .title, .year] {
            for (query, hidesSingles) in [("", false), ("", true), ("o", false), ("zzz-no-match", false)] {
                let predicate = AlbumGridAlbumPredicate(
                    query: query, likedOnly: false, hidesSingleSongAlbums: hidesSingles,
                    favorites: LibraryFavoriteLedger(), unknownArtistName: unknown
                )
                let layout = LibraryAlbumBrowseLayoutBuilder.layout(
                    albums: library.visibleAlbums, order: order, unknownArtistName: unknown, currentYear: year
                )
                var kept: [Int] = []
                for (offset, album) in layout.items.enumerated() where predicate.matches(album) { kept.append(offset) }
                let expected = kept.map { layout.items[$0].id }
                let model = LibraryListModel(
                    query: LibraryAlbumBrowseQuery(
                        order: order, unknownArtistName: unknown, currentYear: year,
                        predicate: predicate.isEmpty ? nil : predicate
                    ),
                    reader: host.reader, revisions: host.revisions
                )
                await model.reload()
                var actual: [String] = []
                for index in 0..<model.count {
                    if let album = await model.waitForItem(at: index) { actual.append(album.id) }
                }
                let context = "order=\(order) query=\(query) hidesSingles=\(hidesSingles)"
                XCTAssertEqual(actual, expected, context)
                XCTAssertEqual(model.browseSections, LibraryBrowseLayout<Album>.sections(layout.sections, keeping: kept), context)
            }
        }
    }

    /// 艺人页(iOS「全部艺术家」)的目录路径:读音顺序、首字母分段与页内搜索,和内存路径一样。
    func testArtistBrowseCatalogMatchesTheInMemoryOrderAndSearch() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        let unknown = String(localized: "unknown_artist")
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: library.visibleArtists, unknownArtistName: unknown)
        XCTAssertGreaterThan(layout.items.count, 2)
        for search in ["", "a", "zzz-no-match"] {
            var kept: [Int] = []
            for (offset, artist) in layout.items.enumerated()
            where search.isEmpty || artist.name.localizedCaseInsensitiveContains(search) { kept.append(offset) }
            let model = LibraryListModel(
                query: LibraryArtistBrowseQuery(unknownArtistName: unknown, search: search),
                reader: host.reader, revisions: host.revisions
            )
            await model.reload()
            var actual: [String] = []
            for index in 0..<model.count {
                if let artist = await model.waitForItem(at: index) { actual.append(artist.id) }
            }
            XCTAssertEqual(actual, kept.map { layout.items[$0].id }, "search=\(search)")
            XCTAssertEqual(model.browseSections, LibraryBrowseLayout<Artist>.sections(layout.sections, keeping: kept), "search=\(search)")
        }
    }

    /// 流派页的目录路径:流派、计数与卡片的代表歌曲都和内存里的 `visibleGenres` 一样。
    func testGenrePageCatalogMatchesTheInMemoryGenres() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let list = GenreCatalogList()
        list.activate(host: try XCTUnwrap(library.catalogHost))
        for _ in 0..<200 where list.readableGenres == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(library.visibleGenres.isEmpty)
        XCTAssertEqual(list.readableGenres, library.visibleGenres)
        list.deactivate()
    }

    func testDeletesLocalRemovalsAndRestoresAreMirrored() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")

        _ = library.deleteSongs([songs[4]])
        await assertShadowMatches(library, "deleteSongs")

        let removed = try library.removeSongsFromThisDevice([songs[7], songs[8]])
        XCTAssertFalse(removed.isEmpty)
        await assertShadowMatches(library, "removeSongsFromThisDevice")

        _ = try library.restoreSongsRemovedFromThisDevice([songs[7].id])
        await assertShadowMatches(library, "restoreSongsRemovedFromThisDevice")

        library.restoreDeletedSong(songs[4])
        await assertShadowMatches(library, "restoreDeletedSong")
    }

    func testRemapAndSourceRemovalAreMirrored() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")

        library.remapSongIDs([songs[0].id: songs[0].id + "-v2", songs[9].id: songs[9].id + "-v2"])
        await assertShadowMatches(library, "remapSongIDs")
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        XCTAssertNil(try catalog.song(id: songs[0].id))
        XCTAssertNotNil(try catalog.song(id: songs[0].id + "-v2"))

        await library.removeSongsForSource(Self.sourceB)
        await assertShadowMatches(library, "removeSongsForSource")
        XCTAssertEqual(try XCTUnwrap(library.catalogHost?.mirror.readableCatalog).songCountsBySource(.everything)[Self.sourceB], nil)
    }

    func testConfigurationChangesReachTheCatalog() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")

        library.updateDisabledSourceIDs([Self.sourceB])
        await assertShadowMatches(library, "disable source")
        library.updateDisabledSourceIDs([])
        await assertShadowMatches(library, "enable source")

        var configuration = ArtistNameConfiguration.defaultValue
        configuration.separators = configuration.separators.filter { $0 != "、" }
        configuration.mergesCollaborativeAlbums.toggle()
        library.updateArtistNameConfiguration(configuration)
        await assertShadowMatches(library, "artist-name configuration")

        let separatorsKey = GenreSplitPreference.storageKey
        let previousSeparators = UserDefaults.standard.object(forKey: separatorsKey)
        defer {
            if let previousSeparators {
                UserDefaults.standard.set(previousSeparators, forKey: separatorsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: separatorsKey)
            }
            GenreSplitPreference.refresh()
        }
        UserDefaults.standard.set(GenreSeparatorOptions([.slash, .comma]).rawValue, forKey: separatorsKey)
        GenreSplitPreference.refresh()
        library.genreSeparatorsDidChange()
        await assertShadowMatches(library, "genre separators")

        // 分类:把一首歌改成有声,再还原(歌曲 id 带随机前缀,不影响别的用例)。
        SpokenWordStore.shared.setKind(.spokenWord, forSongIDs: [songs[5].id])
        defer { SpokenWordStore.shared.setKind(nil, forSongIDs: [songs[5].id]) }
        library.refreshContentClassification()
        await assertShadowMatches(library, "classification change")
    }

    // MARK: - Migration and drift

    func testLaunchMigratesAnExistingLibraryInTheBackground() async throws {
        do {
            let old = makeLibrary(catalog: .disabled)
            old.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
            await old.waitForPendingIndex()
            guard case .success = await old.persistNowAndWait() else { return XCTFail("fixture did not persist") }
            XCTAssertNil(old.catalogHost)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-catalog.sqlite").path))

        let startedAt = ProcessInfo.processInfo.systemUptime
        let library = makeLibrary()
        let launchMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        XCTAssertTrue(library.isReady, "the in-memory path stays the launch path")
        print("📚 catalog test launch-with-catalog ms=\(Int(launchMilliseconds))")
        await assertShadowMatches(library, "migration")
        XCTAssertEqual(library.catalogHost?.mirror.statistics.importsCompleted, 1)
    }

    func testDriftFromACatalogLessLaunchIsRepairedWithoutReimport() async throws {
        let songs = Self.fixture()
        do {
            let first = makeLibrary()
            first.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
            await assertShadowMatches(first, "first launch")
            await first.stopCatalogMirror()
        }
        do {
            // 「旧版本」:只写旧库。
            let older = makeLibrary(catalog: .disabled)
            var edited = songs[2]
            edited.title = "Edited by an older build"
            older.replaceSong(edited)
            _ = older.deleteSongs([songs[10]])
            await older.waitForPendingIndex()
            _ = await older.persistIncrementalNowAndWait()
        }
        let library = makeLibrary()
        await assertShadowMatches(library, "after drift")
        let statistics = try XCTUnwrap(library.catalogHost?.mirror.statistics)
        XCTAssertEqual(statistics.resyncs, 1)
        XCTAssertEqual(statistics.importRuns, 0)
    }

    // MARK: - Reader façade vs in-memory answers

    func testReaderAnswersMatchTheInMemoryLibrary() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let reader = try XCTUnwrap(library.catalogHost?.reader)

        // 1. 按 id
        let ids = [songs[3].id, songs[0].id, "missing"]
        let byID = try await reader.songs(ids: ids)
        XCTAssertEqual(byID.map(\.id), ids.compactMap { library.song(id: $0)?.id })
        // 2. 类别
        let chapterKind = try await reader.contentKind(songID: songs[10].id)
        XCTAssertEqual(chapterKind, .spokenWord)
        let ambientRows = try await reader.rowList(kinds: [.ambient])
        XCTAssertEqual(ambientRows.count, library.ambientSongs.count)
        // 3. 计数
        let counts = try await reader.counts()
        XCTAssertEqual(counts.visibleSongs, library.visibleSongs.count)
        XCTAssertEqual(counts.music, library.musicSongs.count)
        XCTAssertEqual(counts.spokenWord, library.spokenWordSongIDs.count)
        XCTAssertEqual(counts.podcast, library.localPodcastSongs.count)
        XCTAssertEqual(counts.albums, library.visibleAlbums.count)
        XCTAssertEqual(counts.artists, library.visibleArtists.count)
        XCTAssertEqual(counts.genres, library.visibleGenres.count)
        XCTAssertTrue(counts.hasPlayableMusic)
        let mvRows = try await reader.musicVideoRowList()
        XCTAssertEqual(mvRows.count, library.musicVideoSongs.count)
        // 4. 某源
        let sourceRows = try await reader.rowList(sourceID: Self.sourceB)
        let sourceSongs = try await reader.songs(rowids: Array(sourceRows.rowids)).compactMap { $0 }
        XCTAssertEqual(sourceSongs.map(\.id), library.visibleSongs(forSourceID: Self.sourceB).map(\.id))
        let hasSongs = try await reader.containsSongs(sourceID: Self.sourceB)
        XCTAssertTrue(hasSongs)
        let excluded = try await reader.songs(sourceID: Self.sourceA, excluding: [songs[0].id], limit: 3)
        XCTAssertEqual(excluded.map(\.id), Array(library.visibleSongs(forSourceID: Self.sourceA).map(\.id).filter { $0 != songs[0].id }.prefix(3)))
        let byPath = try await reader.songIDs(sourceID: Self.sourceA, keys: [songs[1].filePath]) { $0.filePath }
        XCTAssertEqual(byPath[songs[1].filePath], songs[1].id)
        // 5. 路径
        let exact = try await reader.songID(sourceID: Self.sourceA, filePath: songs[2].filePath)
        XCTAssertEqual(exact, songs[2].id)
        let cueRows = try await reader.rowList(sourceID: Self.sourceA, filePath: "/Music/Live/set.flac")
        XCTAssertEqual(cueRows.count, 2)
        let folderRows = try await reader.rowList(sourceID: Self.sourceA, directory: "/Music/Ada/Blue Room", recursive: false)
        XCTAssertEqual(folderRows.count, 4)
        let recursiveRows = try await reader.rowList(sourceID: Self.sourceA, directory: "/Music", recursive: true)
        XCTAssertEqual(recursiveRows.count, songs.filter { $0.sourceID == Self.sourceA && $0.filePath.hasPrefix("/Music/") }.count)
        let stems = try await reader.fileStems(sourceID: Self.sourceA, directory: "/Music/Mixtape")
        XCTAssertEqual(stems, ["1", "2", "3"])
        // 6. 专辑
        let album = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Mixtape" })
        let albumSongs = try await reader.albumSongs(albumID: album.id)
        XCTAssertEqual(albumSongs.map(\.id), library.songs(forAlbum: album.id).map(\.id))
        let grouped = try await reader.albumSongIDs(albumIDs: [album.id])
        XCTAssertEqual(grouped[album.id], library.songs(forAlbum: album.id).map(\.id))
        let albumHasSongs = try await reader.albumHasSongs(albumID: album.id)
        XCTAssertTrue(albumHasSongs)
        // 7. 艺人
        let artist = try XCTUnwrap(library.visibleArtists.first { $0.name == "Ada" })
        let artistRows = try await reader.artistSongRowList(artistID: artist.id)
        let artistSongs = try await reader.songs(rowids: Array(artistRows.rowids)).compactMap { $0 }
        XCTAssertEqual(artistSongs.map(\.id), library.songs(forArtist: artist.id).map(\.id))
        let byName = try await reader.artistSongRowList(names: ["Ben"])
        let byNameSongs = try await reader.songs(rowids: Array(byName.rowids)).compactMap { $0 }
        XCTAssertEqual(byNameSongs.map(\.id), library.trackSongIDs(forArtistNamed: "Ben"))
        // 8. 流派
        let genres = try await reader.genres()
        XCTAssertEqual(genres.map(\.id), library.visibleGenres.map(\.id))
        if let genre = library.visibleGenres.first {
            let genreRows = try await reader.genreSongRowList(genreID: genre.id)
            let genreSongs = try await reader.songs(rowids: Array(genreRows.rowids)).compactMap { $0 }
            XCTAssertEqual(Set(genreSongs.map(\.id)), Set(library.songs(forGenre: genre.id).map(\.id)))
        }
        let top = try await reader.topGenres(limit: 1)
        XCTAssertEqual(top.first?.songCount, library.visibleGenres.map(\.songCount).max())
        // 9. 按 id 取专辑/艺人
        let resolvedAlbums = try await reader.albums(ids: [album.id])
        XCTAssertEqual(resolvedAlbums.first?.id, album.id)
        let resolvedArtists = try await reader.artists(ids: [artist.id])
        XCTAssertEqual(resolvedArtists.first?.name, "Ada")
        // 10/11. 书
        let shelf = try await reader.bookshelf(kind: .spokenWord)
        XCTAssertEqual(shelf.count, Set(library.spokenWordBookIDs.values).count)
        if let book = shelf.first {
            let members = try await reader.bookRowList(bookID: book.id)
            XCTAssertEqual(members.count, library.spokenWordBookIDs.values.filter { $0 == book.id }.count)
        }
        // 12. 排序列表
        let byTitle = try await reader.songRowList(order: .title)
        XCTAssertEqual(byTitle.count, library.musicSongs.count)
        let albumKeys = try await reader.albumKeyList()
        let firstAlbums = try await reader.albums(keys: Array(albumKeys.keys.prefix(3)))
        XCTAssertEqual(firstAlbums.map(\.id), Array(library.visibleAlbums.prefix(3).map(\.id)))
        let artistKeys = try await reader.artistKeyList()
        let firstArtists = try await reader.artists(keys: Array(artistKeys.keys.prefix(3)))
        XCTAssertEqual(firstArtists.map(\.id), Array(library.visibleArtists.prefix(3).map(\.id)))
        // 13. 前 K / 种子随机
        let firstK = try await reader.firstSongs(.visibleMusic, limit: 4)
        XCTAssertEqual(firstK.map(\.id), Array(library.musicSongs.prefix(4).map(\.id)))
        let randomA = try await reader.randomSongs(.visibleMusic, count: 4, seed: 7)
        let randomB = try await reader.randomSongs(.visibleMusic, count: 4, seed: 7)
        XCTAssertEqual(randomA.map(\.id), randomB.map(\.id))
        XCTAssertTrue(Set(randomA.map(\.id)).isSubset(of: Set(library.musicSongs.map(\.id))))
        let withArtwork = try await reader.randomSongs(.visibleMusic, count: 2, seed: 3, requiresArtwork: true)
        XCTAssertTrue(withArtwork.allSatisfy { $0.coverArtFileName?.isEmpty == false })
        // 14. 最近加入
        let recent = try await reader.recentlyAddedSongs(limit: 3)
        let expectedRecent = library.musicSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(3).map(\.id)
        XCTAssertEqual(recent.map(\.id), Array(expectedRecent))
        let recentAlbums = try await reader.recentlyAddedAlbumIDs(limit: 2)
        XCTAssertEqual(recentAlbums.first, library.musicSongs.max { $0.dateAdded < $1.dateAdded }?.albumID)
        // 15. 播放游标
        let playback = try await reader.playbackRowList(excludingSongIDs: [songs[0].id])
        XCTAssertEqual(playback.count, library.musicSongs.filter { $0.isPlayable && $0.id != songs[0].id }.count)
        let shuffled = try await reader.playbackRowList(shuffledWithSeed: 42)
        XCTAssertEqual(Set(shuffled.rowids).count, library.musicSongs.filter(\.isPlayable).count)
        // 16. 搜索
        let found = try await reader.searchSongs("blue b", limit: 10)
        XCTAssertEqual(Set(found.map(\.id)), Set(songs.filter { $0.title.lowercased().contains("blue b") }.map(\.id)))
        // 同名不同艺人的专辑各算一张(内存与目录一样);排名规则不同,按集合比。
        let foundAlbums = try await reader.searchAlbums("mixtape", limit: 5)
        XCTAssertEqual(Set(foundAlbums.map(\.id)), Set(library.searchAlbums(query: "mixtape", limit: 5).map(\.id)))
        XCTAssertFalse(foundAlbums.isEmpty)
        XCTAssertTrue(foundAlbums.allSatisfy { $0.title == "Mixtape" })
        let foundArtists = try await reader.searchArtists("narr", limit: 5)
        XCTAssertTrue(foundArtists.isEmpty, "spoken-word narrators are not music artists")
        // 17. 外部身份匹配
        let matches = try await reader.matchExternal([
            .init(title: "Comp 2", artists: ["Artist 2"], duration: songs[5].duration),
            .init(title: "Nonexistent", artists: ["Nobody"], duration: nil),
        ])
        XCTAssertEqual(matches, [songs[5].id, nil])
        // 18. 文件夹
        let children = try await reader.folderChildren(sourceID: Self.sourceA, path: "/Music")
        XCTAssertEqual(Set(children.map(\.name)), ["Ada", "Mixtape", "Loose", "Live"])
        let folderSongs = try await reader.folderSongRowList(sourceID: Self.sourceA, path: "/Music/Mixtape")
        XCTAssertEqual(folderSongs.count, 3)
        // 19. 维护谓词
        let mp3s = try await reader.rowList(matching: LibraryMaintenancePredicate(formats: [.mp3]))
        XCTAssertEqual(mp3s.count, library.songs.filter { $0.fileFormat == .mp3 }.count)
        let covered = try await reader.rowList(matching: LibraryMaintenancePredicate(hasCoverReference: true))
        XCTAssertEqual(covered.count, library.songs.filter { $0.coverArtFileName?.isEmpty == false }.count)
        // 20. 去重聚合
        let duration = try await reader.totalDuration()
        XCTAssertEqual(duration, library.musicSongs.reduce(0) { $0 + $1.duration }, accuracy: 0.001)
        let covers = try await reader.distinctCoverReferenceCount()
        XCTAssertEqual(covers, Set(library.visibleSongs.compactMap(\.coverArtFileName)).count)
        let names = try await reader.distinctArtistNames(limit: 100)
        XCTAssertEqual(names, library.visibleArtists.map(\.name))
    }

    func testListModelFollowsLibraryMutations() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        let model = host.songList(.sorted(.title, .visibleMusic))
        model.activate()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.count, library.musicSongs.count)

        songs[5].title = "AAA first by title"
        library.replaceSong(songs[5])
        await library.waitForCatalogMirror()
        var first: Song?
        while ContinuousClock.now < deadline + .seconds(5) {
            first = await model.waitForItem(at: 0)
            if first?.id == songs[5].id { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(first?.title, "AAA first by title")
    }

    /// P2:目录跟写内存有一小段滞后。内存里已经有、目录里还没有的歌,按 id 读目录的地方退回内存模型,
    /// 不把它当成「不在曲库里」(恢复的队列少歌、点的歌被挑掉从别的歌开始放)。
    func testReadsByIDFallBackToMemoryWhileTheCatalogLags() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)

        // 目录停下后再加一首:内存里有,目录里还没有。
        await library.stopCatalogMirror()
        let fresh = Song(id: "lag-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/fresh.flac", sourceID: Self.sourceA)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA])
        for _ in 0..<500 where library.visibleSong(id: fresh.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(library.visibleSong(id: fresh.id))
        XCTAssertTrue(host.revisions.isReadable)
        let catalogRows = try await host.reader.songsByID([fresh.id], visibility: .visible)
        XCTAssertNil(catalogRows[fresh.id], "the stopped mirror must not have written the new song")

        let known = songs[0].id
        let caughtUp = await AudioPlayerService.catalogPlayableSongs(ids: [known], library: library, visibility: .visible)
        XCTAssertEqual(caughtUp?.keys.sorted(), [known])
        let lagging = await AudioPlayerService.catalogPlayableSongs(
            ids: [known, fresh.id], library: library, visibility: .visible
        )
        XCTAssertNil(lagging, "restore must use the in-memory library while the catalog misses a playable song")

        let suite = "catalog-lag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionDirectory = directory.appendingPathComponent("player-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let musicMemory = MusicSessionMemoryStore(
            defaults: defaults, url: sessionDirectory.appendingPathComponent("music-memory.json")
        )
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: sessionDirectory.appendingPathComponent("session.json")),
            musicSessionMemoryStore: musicMemory,
            queueBookmarkStore: QueueBookmarkStore(directory: sessionDirectory.appendingPathComponent("bookmarks")),
            activateAudioSession: { _ in XCTFail("Catalog lag tests must not start audio") }
        )
        let handled = await player.playLibraryFromCatalog(
            CatalogLibraryQueueRequest(leadingIDs: [fresh.id], kinds: [.music], excludedIDs: [fresh.id])
        )
        XCTAssertFalse(handled, "a tapped song the catalog has not received yet must go through the in-memory path")
        XCTAssertNil(player.currentSong)
        await musicMemory.waitForPendingPersistence()
    }

    /// 目录跟着旧库写,改动要过一会儿才到目录;这段时间按 id 读「覆盖层 → 目录」与内存模型
    /// 每一刻都相同(含删除、改名、本机移除与恢复、整源移除),目录跟上之后覆盖层清空。
    func testCatalogReadsByIDMatchTheInMemoryLibraryWhileWritesAreInFlight() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertEqual(host.pendingWrites.pendingCount, 0, "every batch is acknowledged once the catalog catches up")
        var ids = Set(songs.map(\.id))
        var stepsWithPendingWrites = 0

        func assertReadsMatch(_ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let lookup = try XCTUnwrap(host.songLookup(), "\(step): the catalog cannot answer", file: file, line: line)
            for id in ids.sorted() {
                XCTAssertEqual(try lookup.song(id: id), library.storedSong(id: id), "\(step): \(id)", file: file, line: line)
            }
        }
        /// 改动进了内存模型(`changed` 为真)之后,目录跟上之前每隔一会儿比一次,跟上之后再比一次。
        func assertReadsMatchUntilCaughtUp(
            _ step: String, file: StaticString = #filePath, line: UInt = #line, changed: () -> Bool = { true }
        ) async throws {
            for _ in 0..<1_000 where !changed() { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(changed(), "\(step): the change never reached the in-memory library", file: file, line: line)
            var sawPending = false
            for _ in 0..<200 {
                sawPending = sawPending || host.pendingWrites.pendingCount > 0
                try assertReadsMatch(step, file: file, line: line)
                if host.pendingWrites.pendingCount == 0 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            if sawPending { stepsWithPendingWrites += 1 }
            await library.waitForCatalogMirror()
            try assertReadsMatch("\(step) (caught up)", file: file, line: line)
            XCTAssertEqual(host.pendingWrites.pendingCount, 0, "\(step): left in the overlay", file: file, line: line)
        }

        songs[0].title = "Blue One (Remaster)"
        library.replaceSong(songs[0])
        try await assertReadsMatchUntilCaughtUp("replaceSong")

        songs[5].albumTitle = "Mixtape Deluxe"
        songs[6].albumTitle = "Mixtape Deluxe"
        library.replaceSongs([songs[5], songs[6]])
        try await assertReadsMatchUntilCaughtUp("replaceSongs")

        library.updateLyricsText([songs[1].id: "la la la"])
        try await assertReadsMatchUntilCaughtUp("updateLyricsText")

        library.updateAssetReferences(songID: songs[2].id, coverRef: "blue-alt.jpg")
        library.updateMusicVideoReference(songID: songs[3].id, mvPath: "/Videos/blue.mp4")
        library.flushPendingAssetReferencePatches()
        try await assertReadsMatchUntilCaughtUp("asset references")

        _ = library.deleteSongs([songs[4]])
        try await assertReadsMatchUntilCaughtUp("deleteSongs")

        XCTAssertFalse(try library.removeSongsFromThisDevice([songs[7], songs[8]]).isEmpty)
        try await assertReadsMatchUntilCaughtUp("removeSongsFromThisDevice")
        _ = try library.restoreSongsRemovedFromThisDevice([songs[7].id])
        try await assertReadsMatchUntilCaughtUp("restoreSongsRemovedFromThisDevice")

        // 只撤销删除记录(歌等下次扫描回来),按 id 读两边都还是没有。
        library.restoreDeletedSong(songs[4])
        try await assertReadsMatchUntilCaughtUp("restoreDeletedSong")

        let renamed = [songs[0].id: songs[0].id + "-v2", songs[9].id: songs[9].id + "-v2"]
        ids.formUnion(renamed.values)
        library.remapSongIDs(renamed)
        try await assertReadsMatchUntilCaughtUp("remapSongIDs")

        let fresh = Song(id: "pending-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/fresh.flac", sourceID: Self.sourceA)
        ids.insert(fresh.id)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA])
        try await assertReadsMatchUntilCaughtUp("addSongs") { library.storedSong(id: fresh.id) != nil }

        await library.removeSongsForSource(Self.sourceB)
        try await assertReadsMatchUntilCaughtUp("removeSongsForSource")
        XCTAssertNil(library.storedSong(id: songs[7].id))

        // 跟写的那一段要真的走过覆盖层(目录在主线程改完之后才写)。
        XCTAssertGreaterThan(stepsWithPendingWrites, 5)
        await assertShadowMatches(library, "after every step")
    }

    /// 写入链上的列表查询:改动刚进内存模型就等目录跟上,再按源列目录里的歌,与那一刻内存里的这个源
    /// 逐首相同(新加的排在后面、删后重加的排到最后、改名的留在原位)。
    func testCatalogCaughtUpListsASourceLikeTheInMemoryLibraryRightAfterAMutation() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")

        func assertSourceListingsMatch(_ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let caughtUp = await library.catalogReaderCaughtUp()
            let reader = try XCTUnwrap(caughtUp, "\(step): catalog did not catch up", file: file, line: line)
            for sourceID in [Self.sourceA, Self.sourceB] {
                let fromCatalog = try await reader.read { catalog in
                    var listed: [Song] = []
                    try catalog.forEachSong(.source(sourceID, includesDisabled: true)) { _, song in
                        listed.append(song)
                        return true
                    }
                    return listed
                }
                let inMemory = library.songs.filter { $0.sourceID == sourceID }
                XCTAssertEqual(fromCatalog, inMemory, "\(step): \(sourceID)", file: file, line: line)
            }
        }

        songs[0].title = "Edited"
        library.replaceSong(songs[0])
        try await assertSourceListingsMatch("replaceSong")

        _ = library.deleteSongs([songs[1]])
        try await assertSourceListingsMatch("deleteSongs")

        let fresh = Song(id: "caught-up-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/fresh.flac", sourceID: Self.sourceA)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA])
        for _ in 0..<500 where library.storedSong(id: fresh.id) == nil { try await Task.sleep(for: .milliseconds(5)) }
        try await assertSourceListingsMatch("addSongs")

        library.remapSongIDs([songs[2].id: songs[2].id + "-moved"])
        try await assertSourceListingsMatch("remapSongIDs")

        // 删掉再加回:排到这个源的最后(同旧库与目录)。
        library.restoreDeletedSong(songs[1])
        var readded = songs[1]
        readded.title = "Back Again"
        library.addSongs([readded], affectedSourceIDs: [Self.sourceA])
        for _ in 0..<500 where library.storedSong(id: readded.id) == nil { try await Task.sleep(for: .milliseconds(5)) }
        try await assertSourceListingsMatch("re-added after deletion")

        // 不再跟写之后给 nil,调用方读内存模型。
        await library.stopCatalogMirror()
        library.updateLyricsText([songs[3].id: "after stop"])
        let stopped = await library.catalogReaderCaughtUp(timeout: .milliseconds(200))
        XCTAssertNil(stopped)
    }

    /// 重复清理在目录上找:等目录跟上刚做的改动后,某首歌在整个资料库(含停用源)里的副本、整库的重复分组,
    /// 与扫内存里的整库相同。
    func testDuplicateCopiesFromTheCaughtUpCatalogMatchTheWholeLibrary() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        var songs: [Song] = []
        for index in 0..<30 {
            let title = ["Blue", "blue ", "Écho", "Echo", "Rain"][index % 5]
            songs.append(Song(
                id: "dup-\(index)", title: title, albumTitle: "Album \(index % 3)",
                artistName: index % 4 == 0 ? nil : ["Ada", "ADA", "Ben"][index % 3],
                albumArtistName: index % 4 == 0 ? "Ada" : nil,
                duration: Double(200 + index % 3), fileFormat: index % 2 == 0 ? .flac : .mp3,
                filePath: "/Music/dup/\(index).flac", sourceID: index % 3 == 0 ? Self.sourceB : Self.sourceA
            ))
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "duplicate fixture")
        var edited = songs[7]
        edited.title = "Rain"
        library.replaceSong(edited)

        let caughtUp = await library.catalogReaderCaughtUp()
        let reader = try XCTUnwrap(caughtUp)
        for song in library.songs {
            let fromCatalog = try await reader.read { catalog in
                try DuplicateDetector.copies(of: song) { body in
                    try catalog.forEachSong(.everything) { _, candidate in
                        try body(candidate)
                        return true
                    }
                }
            }
            XCTAssertEqual(fromCatalog.map(\.id), DuplicateDetector.copies(of: song, in: library.songs).map(\.id), song.id)
        }
        let groups = try await DuplicateCatalogScan.detect(reader: reader, scope: .everything)
        let expected = DuplicateDetector.detect(in: library.songs)
        // 分组按标题排,同标题的几组之间的先后随字典遍历而定(两边都是);比组和组内的次序。
        func membership(_ groups: [DuplicateGroup]) -> [[String]] {
            groups.map { $0.songs.map(\.id) }.sorted { $0.joined(separator: ",") < $1.joined(separator: ",") }
        }
        XCTAssertEqual(membership(groups), membership(expected))
        XCTAssertFalse(expected.isEmpty)
    }

    /// Siri 按名字比对的专辑、艺人、流派清单在目录上建,与按内存里的可见列表建的逐项相同(含停用源、
    /// 按艺人筛专辑、斜杠分隔的流派)。
    func testSiriNamedItemsFromTheCatalogMatchTheInMemoryLists() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        XCTAssertEqual(library.catalogHost?.revisions.isReadable, true)

        func summary(_ items: [SiriNamedMediaItem]) -> [String] {
            items.map { "\($0.id)|\($0.name)|\($0.aliases)" }
        }
        func memoryAlbums(_ artist: String?) -> [SiriNamedMediaItem] {
            library.visibleAlbums.compactMap { album in
                if let artist, !artist.isEmpty, album.artistName?.localizedCaseInsensitiveContains(artist) != true { return nil }
                let name = album.artistName.map { $0.isEmpty ? album.title : "\(album.title) — \($0)" } ?? album.title
                return SiriNamedMediaItem(id: album.id, name: name, aliases: [album.title])
            }
        }
        for artist in [nil, "ada", "Artist 2", "  ", "nobody"] as [String?] {
            let fromCatalog = await SiriLibraryNamedItems.albums(artistName: artist, library: library)
            XCTAssertEqual(summary(fromCatalog), summary(memoryAlbums(artist?.trimmingCharacters(in: .whitespacesAndNewlines))),
                           "artist \(artist ?? "nil")")
        }
        let artists = await SiriLibraryNamedItems.artists(library: library)
        XCTAssertEqual(summary(artists), summary(library.visibleArtists.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }))

        var seenRaw = Set<String>()
        var seen = Set<String>()
        var expectedGenres: [SiriNamedMediaItem] = []
        for song in library.visibleSongs {
            guard let raw = song.genre,
                  seenRaw.insert(GenreSlashConvention.applies(to: song.fileFormat) ? "\u{1}" + raw : raw).inserted else { continue }
            for genre in GenreTagValues.browseNames(for: song) where seen.insert(genre.lowercased()).inserted {
                expectedGenres.append(SiriNamedMediaItem(id: genre, name: genre))
            }
        }
        expectedGenres.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let genres = await SiriLibraryNamedItems.genres(library: library)
        XCTAssertEqual(summary(genres), summary(expectedGenres))
        XCTAssertFalse(genres.isEmpty)
    }

    /// 目录停下(不再跟写)后不登记、不作答,调用方读内存模型。
    func testCatalogReadsByIDStopWhenTheMirrorStopsFollowing() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertNotNil(host.songLookup())
        await library.stopCatalogMirror()
        XCTAssertNil(host.songLookup())
        library.updateLyricsText([songs[1].id: "after stop"])
        XCTAssertEqual(host.pendingWrites.pendingCount, 0)
        XCTAssertEqual(library.storedSong(id: songs[1].id)?.lyricsText, "after stop")
    }

    /// 智能歌单在目录上流式匹配:随机曲库(多个源、停用的源、Apple Music 资料库的歌、播放记录、歌单)
    /// 上的随机规则组、排序与上限,结果与内存匹配逐首相同(随机排序比成员);命中的是目录那条路。
    func testSmartPlaylistsMatchedOnTheCatalogMatchTheInMemoryEngine() async throws {
        let disabledSource = "dual-write-off"
        let library = makeLibrary(disabledSourceIDs: [disabledSource])
        var random = SmartPlaylistParityGenerator(state: 7)
        let titles = ["Blue", "blue moon", "Écho", "Night Ferry", "夜曲", "Harbour", "Rain", "Zebra", "alpha"]
        let artists = ["Ada", "Ada、Ben", "ben", "The Night", "周杰伦", "Carla feat. Ada"]
        let albums = ["Blue Room", "Mixtape", "Harbour Lights", "夜的第七章", "Zero"]
        let genres = ["Pop", "Rock/Pop", "Jazz", "Electronic", "Mandopop"]
        let sources = [Self.sourceA, Self.sourceB, disabledSource, AppleMusicLibraryService.systemSourceID]
        let now = Date()
        var songs: [Song] = []
        for index in 0..<240 {
            let album = random.chance(85) ? random.pick(albums) : nil
            var song = Song(
                id: "smart-\(index)",
                title: random.pick(titles) + (random.chance(30) ? " \(index % 7)" : ""),
                albumTitle: album,
                artistName: random.chance(90) ? random.pick(artists) : nil,
                albumArtistName: random.chance(40) ? random.pick(artists) : nil,
                trackNumber: random.chance(80) ? random.int(14) + 1 : nil,
                discNumber: random.chance(15) ? 2 : 1,
                duration: Double(60 + random.int(400)),
                fileFormat: random.pick([AudioFormat.flac, .mp3, .m4a]),
                filePath: "/Music/\(album ?? "Loose")/\(String(format: "%02d", random.int(20))) \(index).flac",
                sourceID: random.pick(sources),
                genre: random.chance(85) ? random.pick(genres) : nil,
                year: random.chance(80) ? 1990 + random.int(35) : nil
            )
            song.fileSize = Int64(1_000_000 + random.int(40) * 250_000)
            song.bitRate = random.chance(80) ? random.pick([128, 256, 320, 900, 1411]) : nil
            song.dateAdded = now.addingTimeInterval(-Double(random.int(90)) * 86_400 - Double(random.int(80_000)))
            songs.append(song)
        }
        library.addSongs(songs, affectedSourceIDs: Set(sources))
        await assertShadowMatches(library, "smart playlist fixture")
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertTrue(host.revisions.isReadable)

        let history = PlayHistoryStore(storeURL: directory.appendingPathComponent("history.json"))
        for song in songs where random.chance(35) {
            for play in 0..<(1 + random.int(4)) {
                history.record(song: song, startedAt: now.addingTimeInterval(-Double(play * 3_600 + random.int(40) * 86_400)),
                               listenedSec: 120)
            }
        }
        let playlist = library.createPlaylist(name: "Parity", songIDs: songs.filter { _ in random.chance(25) }.map(\.id))

        func rule() -> SmartPlaylistRule {
            let field = random.pick(SmartPlaylistField.allCases)
            let textOps: [SmartPlaylistOperator] = [.equals, .notEquals, .contains, .notContains]
            let numberOps: [SmartPlaylistOperator] = [.equals, .notEquals, .greaterThan, .lessThan, .between]
            switch field {
            case .title: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(titles + ["blue", "e"]))
            case .artistName: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(artists + ["ada"]))
            case .albumTitle: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(albums + ["room"]))
            case .genre: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(genres + ["pop"]))
            case .fileFormat: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(["flac", "mp3", "m4a", "alac"]))
            case .sourceID: return SmartPlaylistRule(field: field, op: random.pick(textOps), value: random.pick(sources))
            case .year:
                let low = 1990 + random.int(30)
                return SmartPlaylistRule(field: field, op: random.pick(numberOps), value: random.chance(50) ? "\(low)|\(low + 8)" : "\(low)")
            case .fileSize:
                return SmartPlaylistRule(field: field, op: random.pick(numberOps), value: random.chance(50) ? "2000000|6000000" : "\(1_000_000 + random.int(40) * 250_000)")
            case .bitRate:
                return SmartPlaylistRule(field: field, op: random.pick(numberOps), value: random.chance(50) ? "200|1000" : "\(random.pick([128, 320, 900]))")
            case .playCount:
                return SmartPlaylistRule(field: field, op: random.pick(numberOps), value: random.chance(50) ? "1|2" : "\(random.int(4))")
            case .durationSec:
                return SmartPlaylistRule(field: field, op: random.pick(numberOps), value: random.chance(50) ? "100.5|300" : "\(60 + random.int(400))")
            case .dateAdded, .lastPlayedAt:
                if random.chance(60) {
                    return SmartPlaylistRule(field: field, op: random.pick([.equals, .notEquals, .greaterThan, .lessThan]), value: "days:\(random.int(60))")
                }
                return SmartPlaylistRule(field: field, op: random.pick([.equals, .greaterThan, .lessThan, .between]),
                                         value: random.chance(50) ? "2026-10-01T00:00:00Z|2026-11-20T00:00:00Z" : "2026-11-10T00:00:00Z")
            case .isInPlaylist:
                return SmartPlaylistRule(field: field, op: random.pick([.equals, .notEquals]), value: playlist.id)
            }
        }

        var viaCatalog = 0
        for step in 0..<150 {
            let groups = (0..<random.int(4)).map { _ in
                SmartPlaylistRuleGroup(
                    rules: (0..<(1 + random.int(3))).map { _ in rule() },
                    combinator: random.chance(50) ? .and : .or,
                    isExcluded: random.chance(20)
                )
            }
            let smart = SmartPlaylist(
                id: "parity-\(step)", name: "Parity \(step)", ruleGroups: groups,
                groupCombinator: random.chance(50) ? .and : .or,
                limit: random.chance(40) ? random.pick([3, 10, 40]) : nil,
                sortField: random.pick(SmartPlaylistSortField.allCases),
                sortDirection: random.chance(50) ? .ascending : .descending
            )
            let fromCatalog = await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: history)
            if library.smartPlaylistCatalogMatchCache[smart.id] != nil { viaCatalog += 1 }
            let context = "step \(step) sort=\(smart.sortField) \(smart.sortDirection) limit=\(smart.limit.map(String.init) ?? "-") groups=\(groups)"
            let summary = SmartPlaylistEngine.summary(smart, in: library, history: history)
            if smart.sortField == .random {
                var unlimited = smart
                unlimited.limit = nil
                let allSongs = SmartPlaylistEngine.match(unlimited, in: library, history: history)
                let all = Set(allSongs.map(\.id))
                XCTAssertEqual(fromCatalog.count, min(smart.limit ?? .max, all.count), context)
                XCTAssertTrue(Set(fromCatalog).isSubset(of: all), context)
                XCTAssertEqual(summary?.count, fromCatalog.count, context)
                XCTAssertEqual(summary?.hasPlayable, allSongs.contains(where: \.isPlayable), context)
            } else {
                let inMemory = SmartPlaylistEngine.match(smart, in: library, history: history)
                XCTAssertEqual(fromCatalog, inMemory.map(\.id), context)
                XCTAssertEqual(summary, SmartPlaylistEngine.MatchSummary(
                    count: inMemory.count, hasPlayable: inMemory.contains(where: \.isPlayable)
                ), context)
            }
            // 规则编辑器的预览:同 `evaluatePreview` 交内存候选的结果。
            let preview = await SmartPlaylistEngine.preview(for: smart, in: library, history: history)
            let inputs = SmartPlaylistEngine.makePreviewInputs(for: smart, in: library, history: history)
            let memoryPreview = SmartPlaylistEngine.evaluatePreview(songs: inputs.songs, plan: inputs.plan)
            XCTAssertEqual(preview.count, memoryPreview.count, context)
            if smart.sortField != .random {
                XCTAssertEqual(preview.totalDuration, memoryPreview.totalDuration, accuracy: 0.001, context)
                XCTAssertEqual(preview.sourceCount, memoryPreview.sourceCount, context)
                XCTAssertEqual(preview.previewCovers.map(\.id), memoryPreview.previewCovers.map(\.id), context)
            }
            // 搜索结果与电视歌单墙读的那份:缓存里刚算好的这一份。
            let current = SmartPlaylistEngine.currentMatchedSongs(smart, in: library, history: history)
            if smart.sortField == .random {
                XCTAssertEqual(current.count, fromCatalog.count, context)
            } else {
                XCTAssertEqual(current.map(\.id), fromCatalog, context)
            }
            // 第二次命中缓存,结果不变。
            if smart.sortField != .random {
                let cached = await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: history)
                XCTAssertEqual(cached, fromCatalog, context)
            }
        }
        XCTAssertEqual(viaCatalog, 150, "every request went through the catalog")

        // 目录变了(改了一首歌名)之后缓存失效,重新匹配读到新值。
        let target = SmartPlaylist(
            id: "parity-title", name: "Title", ruleGroups: [SmartPlaylistRuleGroup(rules: [
                SmartPlaylistRule(field: .title, op: .contains, value: "renamed in place")
            ])], sortField: .title, sortDirection: .ascending
        )
        let before = await SmartPlaylistEngine.matchedSongIDs(target, in: library, history: history)
        XCTAssertEqual(before, [])
        var renamed = try XCTUnwrap(library.storedSong(id: songs.first { $0.sourceID == Self.sourceA }!.id))
        renamed.title = "Renamed In Place"
        library.replaceSong(renamed)
        await library.waitForCatalogMirror()
        var after: [String] = []
        for _ in 0..<200 {
            after = await SmartPlaylistEngine.matchedSongIDs(target, in: library, history: history)
            if !after.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(after, [renamed.id])
    }

    /// 卡片上的曲数:第一次问时在后台到目录上算(先给 nil),算好后改动计数让界面重画;目录变了先给
    /// 上次的数、再重算成新的。
    func testSmartPlaylistSummariesFillInFromTheCatalog() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let history = PlayHistoryStore(storeURL: directory.appendingPathComponent("history.json"))
        let smart = SmartPlaylist(
            name: "Blue", ruleGroups: [SmartPlaylistRuleGroup(rules: [
                SmartPlaylistRule(field: .title, op: .contains, value: "blue")
            ])], sortField: .title, sortDirection: .ascending
        )
        func waitForSummary(_ expected: Int, _ step: String) async throws {
            for _ in 0..<400 where SmartPlaylistEngine.summary(smart, in: library, history: history)?.count != expected {
                try await Task.sleep(for: .milliseconds(5))
            }
            let memory = SmartPlaylistEngine.match(smart, in: library, history: history)
            XCTAssertEqual(memory.count, expected, step)
            XCTAssertEqual(
                SmartPlaylistEngine.summary(smart, in: library, history: history),
                SmartPlaylistEngine.MatchSummary(count: memory.count, hasPlayable: memory.contains(where: \.isPlayable)),
                step
            )
        }

        let revision = library.smartPlaylistCatalogMatchRevision
        XCTAssertNil(SmartPlaylistEngine.summary(smart, in: library, history: history), "the first ask only schedules the catalog match")
        XCTAssertNotNil(library.smartPlaylistCatalogMatchRefreshes[smart.id])
        XCTAssertNil(SmartPlaylistEngine.summary(smart, in: library, history: history))
        let blue = songs.filter { $0.title.localizedCaseInsensitiveContains("blue") }.count
        try await waitForSummary(blue, "first match")
        XCTAssertGreaterThan(library.smartPlaylistCatalogMatchRevision, revision)
        XCTAssertNil(library.smartPlaylistCatalogMatchRefreshes[smart.id])

        songs[5].title = "Blue Comp"
        library.replaceSong(songs[5])
        await library.waitForCatalogMirror()
        try await waitForSummary(blue + 1, "after a catalog change")
    }

    /// 听歌意图在目录上逐首算:点亮的曲数、「查看歌曲」与起播抽样,同交整库音乐数组的结果
    /// (有声、播客、环境音不算进来)。
    func testListeningIntentsReadTheCatalogLikeTheInMemoryLibrary() async throws {
        let library = makeLibrary()
        var random = SmartPlaylistParityGenerator(state: 11)
        let genres = ["Jazz", "Rock", "Pop", "Classical", "Electronic", "华语流行", "Folk"]
        var songs = Self.fixture()
        for index in 0..<160 {
            let lossless = random.chance(50)
            var song = Song(
                id: "intent-\(index)", title: "Intent \(index)",
                albumTitle: "Album \(index % 12)", artistName: "Artist \(index % 9)",
                trackNumber: index % 12 + 1, duration: Double(90 + random.int(400)),
                fileFormat: lossless ? .flac : .mp3, filePath: "/Music/Intent/\(index % 12)/\(index).flac",
                sourceID: random.chance(70) ? Self.sourceA : Self.sourceB,
                sampleRate: lossless ? random.pick([44_100, 96_000]) : 44_100, bitDepth: lossless ? 24 : nil,
                genre: random.pick(genres), year: 1970 + random.int(56),
                coverArtFileName: random.chance(50) ? "intent-\(index % 12).jpg" : nil
            )
            song.dateAdded = Date().addingTimeInterval(-Double(random.int(200)) * 86_400)
            songs.append(song)
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "intent fixture")
        XCTAssertTrue(try XCTUnwrap(library.catalogHost).revisions.isReadable)

        let suite = "catalog-intents-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ListeningIntentService(defaults: defaults)
        service.refresh(library: library)
        for _ in 0..<800 where service.availability == nil { try await Task.sleep(for: .milliseconds(5)) }
        let availability = try XCTUnwrap(service.availability)
        let history = ListeningHistoryIndex(
            events: PlayHistoryStore.shared.musicEntries.map {
                HomeListeningEvent(songID: $0.songID, playedAt: $0.playedAt, listenedSeconds: $0.listenedSec)
            },
            now: availability.computedAt
        )
        let expected = try XCTUnwrap(ListeningIntentEngine.availability(
            librarySongs: library.musicSongs, intents: ListeningIntent.builtIns, history: history, libraryGeneration: 0
        ))
        var lit = 0
        for intent in ListeningIntent.builtIns {
            XCTAssertEqual(availability.songCounts[intent.id], expected.songCounts[intent.id], intent.id)
            XCTAssertEqual(availability.coverSongIDs[intent.id], expected.coverSongIDs[intent.id], intent.id)
            if (expected.songCounts[intent.id] ?? 0) > 0 { lit += 1 }
        }
        XCTAssertGreaterThan(lit, 2)

        for intent in ListeningIntent.builtIns where (expected.songCounts[intent.id] ?? 0) > 0 {
            let memory = try XCTUnwrap(ListeningIntentEngine.matchingSongIDs(
                for: intent, librarySongs: library.musicSongs, history: history, limit: ListeningIntentService.songListLimit
            ))
            let listed = await service.matchingSongIDs(for: intent, library: library)
            XCTAssertEqual(listed.total, memory.total, intent.id)
            XCTAssertEqual(Set(listed.ids), Set(memory.ids), intent.id)

            let queue = await service.queueSongIDs(for: intent, library: library)
            let matching = Set(ListeningIntentEngine.matchingSongIDs(
                for: intent, librarySongs: library.musicSongsExcludingDisliked, history: history, limit: .max
            )?.ids ?? [])
            XCTAssertTrue(Set(queue).isSubset(of: matching), intent.id)
            XCTAssertEqual(queue.count, min(intent.playback.songLimit, matching.count), intent.id)
        }
    }

    /// 专辑推荐在目录上取:候选专辑表、播放记录对应的专辑、推荐专辑的曲目顺序,同交整库音乐数组
    /// 排出来的那一份。
    func testAlbumPicksFromTheCatalogMatchTheInMemoryLibrary() async throws {
        let library = makeLibrary()
        var random = SmartPlaylistParityGenerator(state: 23)
        var songs = Self.fixture()
        for album in 0..<14 {
            for track in 1...(4 + random.int(5)) {
                var song = Song(
                    id: "pick-\(album)-\(track)", title: "Pick \(album) \(track)",
                    albumTitle: "Pick Album \(album)", artistName: "Picker \(album % 5)",
                    trackNumber: random.chance(85) ? track : nil, discNumber: track > 6 ? 2 : 1,
                    duration: random.chance(5) ? 0 : 200, fileFormat: .flac,
                    filePath: "/Music/Picks/\(album)/\(String(format: "%02d", track)) Pick.flac",
                    sourceID: random.chance(80) ? Self.sourceA : Self.sourceB,
                    genre: random.pick(["Jazz", "Rock", "Classical", "Pop"]), year: 1980 + album,
                    coverArtFileName: track == 1 ? "pick-\(album).jpg" : nil
                )
                song.dateAdded = Date().addingTimeInterval(-Double(album) * 86_400)
                songs.append(song)
            }
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "album pick fixture")
        XCTAssertTrue(try XCTUnwrap(library.catalogHost).revisions.isReadable)

        let suite = "catalog-album-picks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AlbumRecommendationService(defaults: defaults)
        let now = Date()
        service.refresh(library: library, now: now)
        for _ in 0..<800 where service.recommendations == nil { try await Task.sleep(for: .milliseconds(5)) }
        let picks = try XCTUnwrap(service.recommendations)
        XCTAssertFalse(picks.picks.isEmpty)

        let index = try XCTUnwrap(AlbumCandidateIndex.build(librarySongs: library.musicSongs, libraryGeneration: 0))
        let favorites = LibraryFavoritesStore.shared
        let ranked = AlbumRecommender.rankedCandidates(
            index: index,
            context: AlbumRecommendationContext(
                moment: picks.moment,
                now: now,
                events: PlayHistoryStore.shared.musicEntries.map { entry in
                    AlbumListeningEvent(songID: entry.songID, albumID: library.visibleSong(id: entry.songID)?.albumID,
                                        artistName: entry.artistName, playedAt: entry.playedAt)
                },
                likedAlbumIDs: Set(favorites.likedAlbums(in: library.visibleAlbums).map(\.id)),
                likedArtistKeys: Set(favorites.likedArtists(in: library.visibleArtists).map { ListeningTextKey.folded($0.name) }),
                dismissedAlbumIDs: []
            ),
            limit: AlbumPickBatchPolicy.poolSize(visibleCount: service.visibleCount) + AlbumRecommendationService.forYouAlbumCount
        )
        let pickCount = AlbumPickBatchPolicy.poolSize(visibleCount: service.visibleCount)
        XCTAssertEqual(picks.picks, Array(ranked.prefix(pickCount)))
        XCTAssertEqual(service.forYouAlbums, Array(ranked.dropFirst(pickCount)))
        for pick in picks.picks + service.forYouAlbums {
            let musicIDs = Set(library.musicSongs.filter { $0.albumID == pick.albumID }.map(\.id))
            let expected = library.songs(forAlbum: pick.albumID).filteredPlayable().filter { musicIDs.contains($0.id) }.map(\.id)
            XCTAssertEqual(service.songsInTrackOrder(albumID: pick.albumID, library: library).map(\.id), expected, pick.albumID)
        }
    }

    /// 首页常听艺人在目录上取:听过的艺人按名字对上可见艺人(去重、按听的先后),不够的按艺人列表补,
    /// 同内存里 `visibleArtists` 那一套。
    func testHomeTopArtistsFromTheCatalogMatchTheInMemoryLibrary() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        var songs = Self.fixture()
        for index in 0..<40 {
            songs.append(Song(
                id: "top-\(index)", title: "Top \(index)", albumTitle: "Top Album \(index % 6)",
                artistName: "Top Artist \(index % 25)", duration: 200, fileFormat: .flac,
                filePath: "/Music/Top/\(index).flac", sourceID: index % 7 == 0 ? Self.sourceB : Self.sourceA
            ))
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "top artist fixture")
        let reader = try XCTUnwrap(library.catalogHost).reader

        func expected(_ names: [String], limit: Int) -> [String] {
            let visible = library.visibleArtists
            guard !names.isEmpty else { return visible.prefix(limit).map(\.id) }
            let byName = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [String] = []
            var seen = Set<String>()
            for name in names {
                if let artist = byName[name], seen.insert(artist.id).inserted { result.append(artist.id) }
            }
            for artist in visible where result.count < limit && seen.insert(artist.id).inserted {
                result.append(artist.id)
            }
            return result
        }
        let histories: [[String]] = [
            [],
            ["Top Artist 3", "Ada", "Nobody", "top artist 4", "Top Artist 3", "Host", "Top Artist 7"],
            (0..<30).map { "Top Artist \($0)" },
        ]
        for names in histories {
            for limit in [5, 20] {
                let fromCatalog = try await HomeView.catalogTopArtists(reader: reader, historyNames: names, limit: limit)
                XCTAssertEqual(fromCatalog.map(\.id), expected(names, limit: limit), "\(names) limit \(limit)")
            }
        }
    }

    /// 离线筛选在目录上算:含离线能放的歌(本机源的、远程源里缓存完整的)的专辑,与按整库算出来的那些
    /// 相同;一组歌里有没有离线能放的,同样的规则。
    func testOfflineAlbumFilterFromTheCatalogMatchesTheWholeLibrary() async throws {
        let library = makeLibrary()
        let local = MusicSource(id: "offline-local", name: "Local", type: .local)
        let remote = MusicSource(id: "offline-remote-\(UUID().uuidString.prefix(6))", name: "Remote", type: .navidrome)
        var songs: [Song] = []
        for album in 0..<4 {
            for track in 1...3 {
                songs.append(Song(id: "off-local-\(album)-\(track)", title: "L\(album)\(track)", albumTitle: "Local \(album)",
                                  artistName: "Ada", trackNumber: track, duration: 200, fileFormat: .flac,
                                  filePath: "/Local/\(album)/\(track).flac", sourceID: local.id, fileSize: 128))
                songs.append(Song(id: "off-remote-\(album)-\(track)", title: "R\(album)\(track)", albumTitle: "Remote \(album)",
                                  artistName: "Ben", trackNumber: track, duration: 200, fileFormat: .flac,
                                  filePath: "/songs/remote-\(album)-\(track).flac", sourceID: remote.id, fileSize: 128))
            }
        }
        // 一首本机源的歌放不了(时长为 0):它所在的专辑只靠它的话不算。
        songs.append(Song(id: "off-local-broken", title: "Broken", albumTitle: "Broken Local", artistName: "Ada",
                          duration: 0, fileFormat: .flac, filePath: "", sourceID: local.id))
        library.addSongs(songs, affectedSourceIDs: [local.id, remote.id])
        await assertShadowMatches(library, "offline fixture")

        let manager = SourceManager(sourcesProvider: { [local, remote] }, songsProvider: { songs })
        let cachedSong = try XCTUnwrap(songs.first { $0.id == "off-remote-2-1" })
        defer { manager.deleteLocalCaches(for: [cachedSong]) }
        let deadline = Date().addingTimeInterval(3)
        while !(await manager.prepareAutomaticOfflineDownload(song: cachedSong, forceRedownload: false)) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = manager.cacheURL(for: cachedSong)
        try Data(repeating: 7, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: remote.id + "/" + url.lastPathComponent)

        let localIDs = SourceManager.localDeviceSourceIDs(in: [local, remote])
        let playable = await manager.offlinePlayableSongIDs(in: library.visibleSongs, localSourceIDs: localIDs)
        let expected = Set(library.visibleSongs.filter { playable.contains($0.id) }.compactMap(\.albumID))
        let albumIDs = await manager.offlinePlayableAlbumIDs(in: library, localSourceIDs: localIDs)
        let fromCatalog = try XCTUnwrap(albumIDs)
        XCTAssertEqual(fromCatalog, expected)
        XCTAssertEqual(fromCatalog.count, 5, "four local albums and the remote album with a cached song")

        let remoteAlbum = songs.filter { $0.albumTitle == "Remote 2" }
        let otherRemote = songs.filter { $0.albumTitle == "Remote 1" }
        let containsCached = await manager.containsOfflinePlayableSong(in: remoteAlbum, localSourceIDs: localIDs)
        let containsNothing = await manager.containsOfflinePlayableSong(in: otherRemote, localSourceIDs: localIDs)
        let containsLocal = await manager.containsOfflinePlayableSong(in: otherRemote + [songs[0]], localSourceIDs: localIDs)
        XCTAssertTrue(containsCached)
        XCTAssertFalse(containsNothing)
        XCTAssertTrue(containsLocal)
    }

    /// Siri「播放音乐」走目录:目录给的整库(可播放的音乐、不含不喜欢的)与内存那一份相同;一首能放的
    /// 都没有、点的那首不在曲库时,目录排队答「没有可放的」,不装队列、不调 `willInstall`(Siri 据此
    /// 答复没找到);目录还没收到点的那首时答「目录不能用」,调用方走内存路径。
    func testWholeLibraryRequestsReportWhatTheCatalogQueueDid() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let disliked = try XCTUnwrap(library.musicSongs.first(where: \.isPlayable)).id
        library.setDisliked(songID: disliked, isDisliked: true)
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertEqual(library.dislikedSongIDs, [disliked])

        let catalogIDs = try await host.reader.playbackSongIDs(excluding: library.dislikedSongIDs)
        let memoryIDs = library.musicSongsExcludingDisliked.compactMap { $0.isPlayable ? $0.id : nil }
        XCTAssertEqual(Set(catalogIDs), Set(memoryIDs))
        XCTAssertEqual(catalogIDs.count, memoryIDs.count)
        XCTAssertFalse(catalogIDs.contains(disliked))

        let suite = "catalog-outcome-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionDirectory = directory.appendingPathComponent("player-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let musicMemory = MusicSessionMemoryStore(
            defaults: defaults, url: sessionDirectory.appendingPathComponent("music-memory.json")
        )
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: sessionDirectory.appendingPathComponent("session.json")),
            musicSessionMemoryStore: musicMemory,
            queueBookmarkStore: QueueBookmarkStore(directory: sessionDirectory.appendingPathComponent("bookmarks")),
            activateAudioSession: { _ in XCTFail("Catalog outcome tests must not start audio") }
        )
        var installs = 0
        let everything = Set(library.musicSongs.map(\.id))
        let empty = await player.queueLibraryFromCatalog(
            CatalogLibraryQueueRequest(order: .shuffled, kinds: [.music], excludedIDs: everything)
        ) { installs += 1 }
        XCTAssertEqual(empty, .nothingToPlay)
        let missing = await player.queueLibraryFromCatalog(
            CatalogLibraryQueueRequest(leadingIDs: ["not-in-the-library"], kinds: nil, requiresFirstLeadingSong: true)
        ) { installs += 1 }
        XCTAssertEqual(missing, .nothingToPlay)
        XCTAssertEqual(installs, 0)
        XCTAssertNil(player.currentSong)

        // 目录停下后再加一首:点它时目录还没有,走内存路径。
        await library.stopCatalogMirror()
        let fresh = Song(id: "outcome-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/outcome-fresh.flac", sourceID: Self.sourceA)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA])
        for _ in 0..<500 where library.visibleSong(id: fresh.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let lagging = await player.queueLibraryFromCatalog(
            CatalogLibraryQueueRequest(leadingIDs: [fresh.id], kinds: [.music], excludedIDs: [fresh.id])
        ) { installs += 1 }
        XCTAssertEqual(lagging, .unavailable)
        XCTAssertEqual(installs, 0)
        await musicMemory.waitForPendingPersistence()
    }

    /// Siri 按名字、按 id 找歌:目录可读时只从目录取候选(主线程外流式挑出),交给各解析入口与交内存里
    /// 整库数组的结果相同 —— 歌名(含错字)、专辑(按组里第一首打分,整组取回)、艺人、流派、点了 id 的。
    func testSiriCandidatesFromTheCatalogResolveLikeTheWholeLibrary() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        XCTAssertEqual(library.catalogHost?.revisions.isReadable, true)

        func summary(_ resolution: SiriMediaSearchResolution?) -> String {
            guard let resolution else { return "nil" }
            return "q=\(resolution.queue.map(\.id)) c=\(resolution.candidates.map(\.id)) d=\(resolution.needsDisambiguation)"
        }
        let blueAlbumID = try XCTUnwrap(library.visibleSongs.first { $0.albumTitle == "Blue Room" }?.albumID)
        let adaArtistID = try XCTUnwrap(library.visibleSongs.first { $0.artistName == "Ada" }?.artistID)
        let cases: [(SiriMediaSearchQuery, [String])] = [
            (SiriMediaSearchQuery(kind: .song, mediaName: "Blue 2"), []),
            (SiriMediaSearchQuery(kind: .song, mediaName: "Blue B"), []),
            (SiriMediaSearchQuery(kind: .music, mediaName: "Blux Room"), []),
            (SiriMediaSearchQuery(kind: .music, mediaName: "play loose track"), []),
            (SiriMediaSearchQuery(kind: .album, albumName: "Blue Room"), []),
            (SiriMediaSearchQuery(kind: .album, artistName: "Artist 1", albumName: "Mixtape"), []),
            (SiriMediaSearchQuery(kind: .artist, artistName: "ada"), []),
            (SiriMediaSearchQuery(kind: .genre, genreNames: ["Pop"]), []),
            (SiriMediaSearchQuery(kind: .music, artistName: "Ada"), []),
            (SiriMediaSearchQuery(kind: .song, mediaName: "Nothing Like This"), []),
            (SiriMediaSearchQuery(kind: .music), [SiriMediaIdentifier.namespaced(songs[0].id, as: "song")]),
            (SiriMediaSearchQuery(kind: .music), [SiriMediaIdentifier.namespaced(blueAlbumID, as: "album")]),
            (SiriMediaSearchQuery(kind: .artist), [SiriMediaIdentifier.namespaced(adaArtistID, as: "artist")]),
            (SiriMediaSearchQuery(kind: .music), [SiriMediaIdentifier.namespaced("Pop", as: "genre"), "song:missing"]),
        ]
        let spokenCases: [(SiriMediaSearchQuery, [String])] = [
            (SiriMediaSearchQuery(kind: .music, mediaName: "Chapter 2"), []),
            (SiriMediaSearchQuery(kind: .music, mediaName: "Episode"), []),
            (SiriMediaSearchQuery(kind: .album, albumName: "Long Story"), []),
            (SiriMediaSearchQuery(kind: .artist, artistName: "Host"), []),
        ]
        for (query, ids) in cases + spokenCases {
            for scope in [SiriLibrarySongs.Scope.music, .visible, .spokenWord] {
                let whole: [Song]
                switch scope {
                case .music: whole = library.musicSongs
                case .visible: whole = library.visibleSongs
                case .spokenWord: whole = library.spokenWordSongs
                }
                guard scope != .spokenWord || ids.isEmpty else { continue }
                let candidates = await SiriLibrarySongs.candidates(
                    for: query, identifiers: ids, in: scope, library: library
                )
                XCTAssertLessThanOrEqual(candidates.count, whole.count)
                for tiers in [SiriSongMatchTiers.strictThenRelaxed, .strictOnly, .relaxedOnly] {
                    XCTAssertEqual(
                        summary(SiriMediaSearchResolver.resolve(query: query, resolvedItemIDs: ids, songs: candidates, songMatching: tiers)),
                        summary(SiriMediaSearchResolver.resolve(query: query, resolvedItemIDs: ids, songs: whole, songMatching: tiers)),
                        "\(query) ids=\(ids) scope=\(scope) tiers=\(tiers)"
                    )
                }
            }
        }
        // 说了名字的只取回可能命中的那几首,不是整库。
        let named = await SiriLibrarySongs.candidates(
            for: SiriMediaSearchQuery(kind: .song, mediaName: "Loose Track"), in: .music, library: library
        )
        XCTAssertEqual(named.map(\.id), songs.filter { $0.title == "Loose Track" }.map(\.id))
        // 有声范围:有声书(同 `spokenWordSongs`,播客单集不算),只取回可能说到的那几章。
        XCTAssertFalse(library.spokenWordSongs.isEmpty)
        let chapters = await SiriLibrarySongs.candidates(
            for: SiriMediaSearchQuery(kind: .music, mediaName: "Chapter 2"), in: .spokenWord, library: library
        )
        let spokenIDs = Set(library.spokenWordSongs.map(\.id))
        XCTAssertTrue(chapters.contains { $0.title == "Chapter 2" })
        XCTAssertTrue(chapters.allSatisfy { spokenIDs.contains($0.id) })
    }

    /// Siri 歌曲快捷指令:在目录上流式挑(只留够格的优先歌与最新的那些)与交内存里整库的结果相同。
    func testSiriSongShortcutsFromTheCatalogMatchTheWholeLibrary() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        for (index, title) in ["晴天", "夜曲", "海", "Hi", "初晴", "山海间"].enumerated() {
            var song = Song(id: "short-\(index)", title: title, albumTitle: "Short", artistName: "Ada", duration: 200,
                            fileFormat: .flac, filePath: "/Music/Short/\(index).flac", sourceID: Self.sourceA)
            song.dateAdded = Date(timeIntervalSince1970: 1_800_000_000 + Double(index % 3))
            songs.append(song)
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let reader = try XCTUnwrap(library.catalogHost?.reader)
        for (priority, limit) in [([String](), 10), (["short-4", "missing", "short-4"], 3), (["short-2"], 1), ([], 0)] {
            let fromCatalog = try await reader.read { catalog in
                try SiriSongCatalog.shortcuts(priorityIDs: priority, limit: limit) { body in
                    try catalog.forEachSong(.visibleMusic) { _, song in body(song) }
                }
            }
            let fromMemory = SiriSongCatalog.shortcuts(from: library.musicSongs, priorityIDs: priority, limit: limit)
            XCTAssertEqual(fromCatalog.map(\.id), fromMemory.map(\.id), "priority \(priority) limit \(limit)")
        }
        let all = try await reader.read { catalog in
            try SiriSongCatalog.shortcuts(priorityIDs: [], limit: 10) { body in
                try catalog.forEachSong(.visibleMusic) { _, song in body(song) }
            }
        }
        XCTAssertTrue(all.contains { $0.id == "short-0" })
        XCTAssertTrue(all.allSatisfy { $0.id.hasPrefix("short-") }, "the fixture's longer titles are not shortcut phrases")
    }
}

/// 智能歌单对照测试用的确定性随机数。
struct SmartPlaylistParityGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
    mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

