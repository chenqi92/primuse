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
        disabledSourceIDs: Set<String> = []
    ) -> MusicLibrary {
        let library = MusicLibrary(
            disabledSourceIDs: disabledSourceIDs,
            storageDirectory: directory,
            artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true },
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
}
