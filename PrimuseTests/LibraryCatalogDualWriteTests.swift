import Foundation
import Observation
import PrimuseKit
import XCTest
@testable import Primuse

/// P1 双写:`MusicLibrary` 每条写进 `library-songs.sqlite` 的变更都跟进目录,
/// 每一步之后用影子校验的深模式拿目录与内存模型逐项比对(专辑、艺人、分类、书、
/// 库内顺序、按源计数、流派)。另有老用户启动迁移、旧版本造成的漂移、读接口与
/// 内存答案的对照。
@MainActor
final class LibraryCatalogDualWriteTests: LibraryReleasedTwinTestCase {

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

        let mirror = try XCTUnwrap(library.catalogHost?.mirror)
        let before = mirror.statistics
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.separators = configuration.separators.filter { $0 != "、" }
        configuration.mergesCollaborativeAlbums.toggle()
        library.updateArtistNameConfiguration(configuration)
        await assertShadowMatches(library, "artist-name configuration")
        // 整库重建分组期间读者读冻结视图(重建前的完整分组),目录不会变得不可读。
        XCTAssertGreaterThan(mirror.statistics.frozenReads, before.frozenReads)
        XCTAssertEqual(mirror.statistics.unreadableSpells, before.unreadableSpells)
        XCTAssertFalse(mirror.readsAreFrozen)
        XCTAssertEqual(mirror.readableCatalog?.isFrozenView, false)

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

    /// 一次不带目录的启动只写了旧库:下次启动目录按旧库的变更流水只补改过的行,不整库对账。
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
        XCTAssertEqual(statistics.journalCatchUps, 1)
        XCTAssertEqual(statistics.resyncs, 0)
        XCTAssertEqual(statistics.importRuns, 0)
    }

    // MARK: - Catalog started before the first publish (cold launch)

    /// 冷启动:库以 `.preparing` 构造,目录不等发布就启动。旧库在目录没开着的时候写过(目录落后两个修订号)。
    /// - 目录追上之前按 id 读答不出,从不给出目录里的旧值;
    /// - 追上之后、发布之前,按 id 的答案与装好的库逐项相同(发版里这条路关着,这里用测试开关打开);
    /// - 列表读者(`readableCatalog`、`revisions.isReadable`)到发布才看得到目录;
    /// - 发布之后目录确认过的修订号告诉旧库,那之前的变更流水在下一次写时剪掉。
    func testCatalogStartedBeforePublishNeverAnswersByIDFromBehindTheStore() async throws {
        let disabled: Set<String> = [Self.sourceB]
        let songs = Self.fixture()
        do {
            let first = makeLibrary(disabledSourceIDs: disabled)
            first.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
            await assertShadowMatches(first, "first launch")
            guard case .success = await first.persistNowAndWait() else { return XCTFail("fixture did not persist") }
            await first.stopCatalogMirror()
        }
        // 一次不带目录的启动:改一首、删一首,只进旧库。
        var edited = songs[2]
        edited.title = "Edited while the catalog was closed"
        let deleted = songs[10]
        let albumIDs: [String], artistIDs: [String], genreIDs: [String]
        do {
            let older = makeLibrary(catalog: .disabled, disabledSourceIDs: disabled)
            older.replaceSong(edited)
            _ = older.deleteSongs([deleted])
            await older.waitForPendingIndex()
            _ = await older.persistIncrementalNowAndWait()
            guard case .success = await older.persistNowAndWait() else { return XCTFail("drift did not persist") }
            albumIDs = older.albums.map(\.id)
            artistIDs = older.artists.map(\.id)
            genreIDs = older.visibleGenres.map(\.id)
        }
        XCTAssertFalse(albumIDs.isEmpty)
        var ids = Set(songs.map(\.id))
        ids.insert("never-in-the-library")

        let classification = SpokenWordStore.shared.classificationSnapshot
        let library = MusicLibrary.makePreparing(
            storageDirectory: directory, disabledSourceIDs: disabled, artistNameConfiguration: .defaultValue,
            catalogMirroring: .enabled(startDelay: .zero)
        )
        libraries.append(library)
        let host = try XCTUnwrap(library.catalogHost)
        library.byIDReadsBeforeFirstPublishForTesting = true
        XCTAssertNil(library.storedSong(id: edited.id), "the catalog has not started")
        library.startCatalogBeforePublish(spokenWordClassification: classification)

        // 追上之前:答不出。第一次答得出时已经是旧库里的那一行,删掉的那首从头到尾都没有。
        var answered = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let answer = library.storedSong(id: edited.id)
            XCTAssertNil(library.storedSong(id: deleted.id), "a row the store deleted must never be answered")
            if let answer {
                XCTAssertEqual(answer.title, edited.title, "the first answer is the store's row, not the catalog's older one")
                answered = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(answered, "the catalog caught up before the publish")
        XCTAssertFalse(library.isReady)
        XCTAssertNil(host.mirror.readableCatalog, "list readers wait for the publish")
        XCTAssertFalse(host.revisions.isReadable)
        XCTAssertNotNil(host.mirror.caughtUpCatalog)
        let caughtUpRevision = try XCTUnwrap(host.mirror.mirroredStoreRevision)
        var statistics = host.mirror.statistics
        XCTAssertEqual(statistics.journalCatchUps, 1)
        XCTAssertEqual(statistics.resyncs, 0)
        XCTAssertEqual(statistics.importRuns, 0)

        // 发版里发布之前这条路关着:照没装好的答法。
        library.byIDReadsBeforeFirstPublishForTesting = false
        XCTAssertNil(library.storedSong(id: edited.id))
        XCTAssertNil(library.song(id: edited.id))
        XCTAssertNil(library.visibleSong(id: edited.id))
        XCTAssertFalse(library.containsVisibleSong(id: edited.id))
        XCTAssertNil(library.visibleAlbum(id: albumIDs[0]))
        XCTAssertTrue(library.songs(forAlbum: albumIDs[0]).isEmpty)
        library.byIDReadsBeforeFirstPublishForTesting = true

        // 追上之后、发布之前的答案。
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, byIDAnswers(library, $0, fromCatalog: false)) })
        let albumsBefore = albumIDs.map { library.visibleAlbum(id: $0) }
        let albumSongsBefore = albumIDs.map { library.songs(forAlbum: $0) }
        let artistsBefore = artistIDs.map { library.visibleArtist(id: $0) }
        let artistSongsBefore = artistIDs.map { library.songs(forArtist: $0) }
        let genreSongsBefore = genreIDs.map { library.songs(forGenre: $0) }
        XCTAssertEqual(before[edited.id]?.stored?.title, edited.title)
        XCTAssertNil(before[deleted.id]?.stored)
        XCTAssertTrue(albumSongsBefore.contains { !$0.isEmpty })

        // 发布:与装好的库逐项相同。
        library.publish(await MusicLibrary.prepareStartup(
            disabledSourceIDs: disabled, storageDirectory: directory, artistNameConfiguration: .defaultValue,
            spokenWordClassification: classification
        ))
        XCTAssertTrue(library.isReady)
        XCTAssertFalse(library.songs.isEmpty)
        XCTAssertNotNil(host.mirror.readableCatalog, "readable the moment the library is published")
        for id in ids.sorted() {
            let expected = byIDAnswers(library, id, fromCatalog: false)
            let earlier = try XCTUnwrap(before[id])
            assertSameSong(earlier.stored, expected.stored, "storedSong \(id)")
            assertSameSong(earlier.song, expected.song, "song(id:) \(id)")
            assertSameSong(earlier.visible, expected.visible, "visibleSong \(id)")
            assertSameSong(earlier.unobserved, expected.unobserved, "unobservedVisibleSong \(id)")
            XCTAssertEqual(earlier.contains, expected.contains, "containsVisibleSong \(id)")
            assertSameSong(earlier.synchronization, expected.synchronization, "songForSynchronization \(id)")
        }
        for (offset, id) in albumIDs.enumerated() {
            XCTAssertEqual(
                albumsBefore[offset].map(LibraryCatalogShadowVerifier.normalized),
                library.visibleAlbum(id: id).map(LibraryCatalogShadowVerifier.normalized), "visibleAlbum \(id)"
            )
            assertSameSongs(albumSongsBefore[offset], library.songs(forAlbum: id), "songs(forAlbum: \(id))")
        }
        for (offset, id) in artistIDs.enumerated() {
            XCTAssertEqual(artistsBefore[offset], library.visibleArtist(id: id), "visibleArtist \(id)")
            assertSameSongs(artistSongsBefore[offset], library.songs(forArtist: id), "songs(forArtist: \(id))")
        }
        for (offset, id) in genreIDs.enumerated() {
            assertSameSongs(genreSongsBefore[offset], library.songs(forGenre: id), "songs(forGenre: \(id))")
        }
        await assertShadowMatches(library, "after the publish")
        XCTAssertTrue(host.revisions.isReadable)
        statistics = host.mirror.statistics
        XCTAssertEqual(statistics.journalCatchUps, 1)
        XCTAssertEqual(statistics.resyncs, 0)
        XCTAssertEqual(statistics.importRuns, 0)
        XCTAssertEqual(statistics.groupingRebuilds, 0)

        // 目录确认过的修订号到了旧库:下一次写的时候,那之前的变更流水剪掉。
        var again = edited
        again.title = "Edited after the publish"
        library.replaceSong(again)
        await library.waitForPendingIndex()
        _ = await library.persistIncrementalNowAndWait()
        await assertShadowMatches(library, "after a write")
        let journal = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
            .changeJournalState()
        XCTAssertGreaterThanOrEqual(journal.floor, caughtUpRevision)
        XCTAssertLessThanOrEqual(journal.entryCount, 2, "only what the catalog has not confirmed yet stays in the journal")
    }

    // MARK: - Consumers made safe for a model that is not loaded (P3 step 3)

    /// 冷启动的那个状态:上一次会话写好了 `songs`(`seed` 在装好的库上再做些事:喜欢、歌单),这一次库以
    /// `.preparing` 构造,目录在发布之前启动并追上,按 id 读从目录答(测试开关;发版里关着)。
    /// `publish` 把装载做完。
    private func makeColdLaunch(
        disabledSourceIDs: Set<String> = [],
        seed: (MusicLibrary, [Song]) -> Void = { _, _ in }
    ) async throws -> (library: MusicLibrary, songs: [Song], publish: () async -> Void) {
        let songs = Self.fixture()
        do {
            let first = makeLibrary(disabledSourceIDs: disabledSourceIDs)
            first.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
            seed(first, songs)
            await assertShadowMatches(first, "previous session")
            guard case .success = await first.persistNowAndWait() else { throw XCTSkip("the fixture did not persist") }
            await first.stopCatalogMirror()
        }
        do {
            // 再启动一次(不带目录,什么都不改):装载检查过旧库里的行,才把启动迁移的版本记上。记上之后的
            // 下一次启动才是「原样装旧库」,目录才敢在发布之前就答。
            let second = makeLibrary(catalog: .disabled, disabledSourceIDs: disabledSourceIDs)
            guard case .success = await second.persistNowAndWait() else { throw XCTSkip("the second launch did not persist") }
        }
        let classification = SpokenWordStore.shared.classificationSnapshot
        let storage = try XCTUnwrap(directory)
        let library = MusicLibrary.makePreparing(
            storageDirectory: storage, disabledSourceIDs: disabledSourceIDs, artistNameConfiguration: .defaultValue,
            catalogMirroring: .enabled(startDelay: .zero)
        )
        libraries.append(library)
        library.byIDReadsBeforeFirstPublishForTesting = true
        library.startCatalogBeforePublish(spokenWordClassification: classification)
        let host = try XCTUnwrap(library.catalogHost)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while host.songLookup() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(host.songLookup(), "the catalog caught up before the publish")
        XCTAssertFalse(library.isReady)
        let publish: () async -> Void = {
            library.publish(await MusicLibrary.prepareStartup(
                disabledSourceIDs: disabledSourceIDs, storageDirectory: storage, artistNameConfiguration: .defaultValue,
                spokenWordClassification: classification
            ))
        }
        return (library, songs, publish)
    }

    /// A 组(状态取反):发布之前「我喜欢」「不喜欢」都是空的,界面上每颗心都没点亮。这时点一下,排队的是
    /// 「设成调用方看见的反面」,不是「装好之后再取反」:本来就喜欢的歌不能被取消喜欢。
    func testLikeAndDislikeTogglesBeforeThePublishAreQueuedAsTheValueTheCallerSaw() async throws {
        let launch = try await makeColdLaunch(seed: { first, songs in
            first.setLiked(songID: songs[0].id, isLiked: true, propagatesServerMutation: false)
            first.setLiked(songID: songs[4].id, isLiked: true, propagatesServerMutation: false)
            first.setDisliked(songID: songs[2].id, isDisliked: true)
            XCTAssertTrue(first.isLiked(songID: songs[0].id))
            XCTAssertTrue(first.isDisliked(songID: songs[2].id))
        })
        let library = launch.library
        let songs = launch.songs
        XCTAssertNotNil(library.song(id: songs[0].id), "the row is answered from the catalog")
        XCTAssertFalse(library.isLiked(songID: songs[0].id), "the liked table is still empty")
        XCTAssertFalse(library.isDisliked(songID: songs[2].id))

        library.toggleLiked(songID: songs[0].id)     // 已经喜欢的歌:点没点亮的心,意思是「喜欢」
        library.toggleLiked(songID: songs[1].id)     // 没喜欢过的歌
        library.toggleDisliked(songID: songs[2].id)  // 已经不喜欢的歌
        library.setLiked(songID: songs[4].id, isLiked: false, propagatesServerMutation: false)  // 明说要取消

        await launch.publish()
        XCTAssertTrue(library.isReady)
        XCTAssertTrue(library.isLiked(songID: songs[0].id), "a like tapped before the publish must not un-like a liked song")
        XCTAssertTrue(library.isLiked(songID: songs[1].id))
        XCTAssertTrue(library.isDisliked(songID: songs[2].id), "a dislike tapped before the publish must not un-dislike")
        XCTAssertFalse(library.isLiked(songID: songs[4].id), "an explicit un-like still lands")
        XCTAssertFalse(library.isLiked(songID: songs[5].id), "untouched songs stay as they were")
    }

    /// B 组(丢改动):发布之前「读一行、改一个字段、整行交回」排队的是改了哪些字段,重放时对着那一刻曲库里的
    /// 行改上去;这期间再读,读得到自己刚交的改动。整行原样重放的话,后一次会把前一次盖回去,装载时
    /// 才出现的差别(这里用绕过镜像直接写旧库来模拟启动迁移)也会被盖回去。
    func testRowReplacementsQueuedBeforeThePublishLandOnTheRowAsItIsAtReplay() async throws {
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let launch = try await makeColdLaunch()
        let library = launch.library
        let songs = launch.songs
        let host = try XCTUnwrap(library.catalogHost)

        // 调用方甲:读一行,改标签,整行交回。
        let id = songs[0].id
        let original = try XCTUnwrap(library.storedSong(id: id))
        var retagged = original
        retagged.title = "Retagged before the publish"
        retagged.year = 1999
        library.replaceSong(retagged)
        // 没写(待写登记是空的,目录没动),但读得到。
        XCTAssertEqual(host.pendingWrites.pendingCount, 0)
        XCTAssertEqual(try host.mirror.caughtUpCatalog?.song(id: id)?.title, original.title)
        XCTAssertEqual(library.storedSong(id: id)?.title, "Retagged before the publish")
        XCTAssertEqual(library.song(id: id)?.year, 1999)
        // 调用方乙:在甲之后读,只改时长(播放时纠正时长就是这样)。
        var timed = try XCTUnwrap(library.storedSong(id: id))
        XCTAssertEqual(timed.title, "Retagged before the publish")
        timed.duration = 321
        library.replaceSong(timed)
        // 一批:两行各改一个字段。
        var first = try XCTUnwrap(library.storedSong(id: songs[1].id))
        first.genre = "Queued Genre"
        var second = try XCTUnwrap(library.storedSong(id: songs[5].id))
        second.duration = 111
        library.replaceSongs([first, second])
        // 调用方丙读到的那一行,在装载时会不一样(启动迁移改了流派):只改时长,流派不能被盖回读到的旧值。
        let migratedID = songs[6].id
        var corrected = try XCTUnwrap(library.storedSong(id: migratedID))
        let staleGenre = corrected.genre
        XCTAssertNotEqual(staleGenre, "Migrated At Launch")
        corrected.duration = 222
        library.replaceSong(corrected)
        var storeRow = try XCTUnwrap(try host.mirror.caughtUpCatalog?.song(id: migratedID))
        storeRow.genre = "Migrated At Launch"
        try IncrementalSongStore(path: storePath).apply(upserts: [storeRow])
        // 不在曲库里的行:没有可比的,照旧整行排队,重放时什么都不做。
        library.replaceSong(Song(id: "never-in-the-library", title: "Ghost", fileFormat: .mp3, filePath: "/g.mp3", sourceID: Self.sourceA))

        await launch.publish()
        let landed = try XCTUnwrap(library.storedSong(id: id))
        XCTAssertEqual(landed.title, "Retagged before the publish", "the later duration write must not revert the earlier tag write")
        XCTAssertEqual(landed.year, 1999)
        XCTAssertEqual(landed.duration, 321)
        XCTAssertEqual(landed.filePath, original.filePath)
        XCTAssertEqual(library.storedSong(id: songs[1].id)?.genre, "Queued Genre")
        XCTAssertEqual(library.storedSong(id: songs[5].id)?.duration, 111)
        let afterMigration = try XCTUnwrap(library.storedSong(id: migratedID))
        XCTAssertEqual(afterMigration.duration, 222)
        XCTAssertEqual(afterMigration.genre, "Migrated At Launch", "the write was read again at replay: \(staleGenre ?? "nil") is not written back")
        XCTAssertNil(library.storedSong(id: "never-in-the-library"))

        // 落盘的也是这些。
        await library.waitForPendingIndex()
        _ = await library.persistIncrementalNowAndWait()
        let stored = Dictionary(uniqueKeysWithValues: try IncrementalSongStore(path: storePath).loadSongs().map { ($0.id, $0) })
        XCTAssertEqual(stored[id]?.title, "Retagged before the publish")
        XCTAssertEqual(stored[id]?.duration, 321)
        XCTAssertEqual(stored[migratedID]?.genre, "Migrated At Launch")
        XCTAssertEqual(stored[migratedID]?.duration, 222)
    }

    /// 曲库自己的破坏性路径在歌曲模型不在内存里时不动手:歌单成员与最近播放的清理、旧库的整份恢复。
    /// 目录答得了的时候,一批 id 一次问回来,答案与内存逐首答的相同;目录也答不了时是「答不了」,不是「都不在」。
    func testCleanupsAndTheStoreRecoveryRefuseALibraryWhoseSongModelIsNotLoaded() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        let playlist = library.createPlaylist(name: "Kept", songIDs: songs.prefix(6).map(\.id))
        library.recordPlayback(of: songs[0].id)
        library.recordPlayback(of: songs[1].id)
        XCTAssertFalse(try library.removeSongsFromThisDevice([songs[8]]).isEmpty)
        await assertShadowMatches(library, "fixture")
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let storeCount = try IncrementalSongStoreScanner(path: storePath).songCount()
        XCTAssertGreaterThan(storeCount, 0)
        let ids = songs.map(\.id) + ["never-in-the-library"]
        let expected = ids.map { library.songForSynchronization(id: $0) }
        XCTAssertNotNil(expected[8], "the row removed from this device is still seen by synchronization")
        let members = library.rawSongIDs(forPlaylist: playlist.id)
        let history = library.recentPlaybackSongIDsForSync
        XCTAssertEqual(members.count, 6)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(library.canAnswerSongLookups)

        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)
        // 目录答得了:一批一起取,与内存逐首答的相同;清理一首都不删。
        XCTAssertTrue(library.canAnswerSongLookups)
        let batch = try XCTUnwrap(library.songsForSynchronization(ids: ids))
        XCTAssertEqual(batch.count, ids.count)
        for (offset, id) in ids.enumerated() {
            assertSameSong(batch[offset], expected[offset], "songsForSynchronization \(id)")
        }
        library.cleanPlaylistAndHistoryEntriesForTesting()
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), members)
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, history)

        // 目录不再跟写:此刻答不了。清理不能把「查不到」当成「不在了」。
        await library.stopCatalogMirror()
        XCTAssertFalse(library.canAnswerSongLookups)
        XCTAssertNil(library.songsForSynchronization(ids: ids), "unanswerable is not the same as absent")
        library.cleanPlaylistAndHistoryEntriesForTesting()
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), members, "a clean-up on an unloaded model must not empty the playlist")
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, history, "…nor the play history")

        // 整份恢复旧库:`songs` 是空的,拿它替换就是清库。
        let recovered = await library.recoverIncrementalSongStoreForTesting()
        XCTAssertFalse(recovered)
        XCTAssertEqual(try IncrementalSongStoreScanner(path: storePath).songCount(), storeCount, "the store was not replaced by the empty model")
    }

    // MARK: - Row writes without the song model (P3 step 5)

    /// 只动歌曲行的按 id 写(歌词文本、封面/歌词/MV 引用、分组输入没变的整行替换),在模型在内存里的库和模型
    /// 被放掉的库上各做一遍:交给 `persistSongChanges` 的改动相同(同样的行、同样的先后、同样的派生字段),
    /// 做完之后两边旧库与目录里的行也相同。库里有停用的源、本机移除的歌、删过的歌(墓碑)、一次已经落定的改名,
    /// 和一次还在路上的改名(内存里改完了,旧库与目录都还没写到,只在待写登记里 —— 放掉模型之后按 id 读写
    /// 都得经登记认出新 id、不认旧 id)。分组输入变了的替换不走这条路,照旧排队等模型。
    func testRowWritesWithoutTheSongModelMatchTheLoadedLibrary() async throws {
        // 第二个库的目录放在测试目录里面:收尾时先停下两个库的目录,再一起删。
        let loadedDirectory = directory.appendingPathComponent("loaded", isDirectory: true)
        let twinDirectory = directory.appendingPathComponent("dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: loadedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: twinDirectory, withIntermediateDirectories: true)
        let songs = Self.fixture(prefix: "twin")
        let renamedID = "twin-renamed"
        func make(in storage: URL) async throws -> MusicLibrary {
            let library = MusicLibrary(
                disabledSourceIDs: [Self.sourceB], storageDirectory: storage, artistNameConfiguration: .defaultValue,
                deferredMaintenanceAllowed: { true }, catalogMirroring: .enabled(startDelay: .zero)
            )
            library.catalogShadowModeOverride = .deep
            libraries.append(library)
            library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
            XCTAssertFalse(try library.removeSongsFromThisDevice([songs[8]]).isEmpty)
            _ = library.deleteSongs([songs[9]])
            library.remapSongIDs([songs[5].id: renamedID])
            await assertShadowMatches(library, "twin fixture")
            return library
        }
        let loaded = try await make(in: loadedDirectory)
        let dropped = try await make(in: twinDirectory)
        // 第二次改名交出去就放掉模型:这一刻它只在待写登记里。从这里到两边的写做完,中间不让出主线程。
        let lateRenamedID = "twin-renamed-late"
        loaded.remapSongIDs([songs[6].id: lateRenamedID])
        dropped.remapSongIDs([songs[6].id: lateRenamedID])
        XCTAssertGreaterThan(try XCTUnwrap(dropped.catalogHost).pendingWrites.pendingCount, 0, "the rename is in flight")
        dropped.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(dropped.isReady)
        XCTAssertTrue(dropped.songs.isEmpty)
        loaded.persistedSongChangeSetsForTesting = []
        dropped.persistedSongChangeSetsForTesting = []

        // 同一串写,两边各做一遍。要改的行各读各的:一边读内存,一边读「待写登记 + 目录」。
        let lyrics = [
            songs[0].id: "la la", songs[1].id: "second verse", lateRenamedID: "renamed a moment ago",
            songs[6].id: "the id it had before", songs[9].id: "a deleted row", "twin-never-in-the-library": "nobody",
        ]
        func mutate(_ library: MusicLibrary) throws {
            library.updateLyricsText(lyrics)
            library.updateAssetReferences(songID: songs[0].id, coverRef: "cover-new.jpg", lyricsRef: "lyrics-new.lrc")
            library.updateMusicVideoReference(songID: songs[1].id, mvPath: "/Videos/one.mp4")
            library.updateAssetReferences(songID: songs[8].id, coverRef: "removed-from-this-device.jpg")
            library.flushPendingAssetReferencePatches()
            var timed = try XCTUnwrap(library.storedSong(id: songs[2].id))
            timed.duration = 321
            library.replaceSong(timed)
            var renamed = try XCTUnwrap(library.storedSong(id: renamedID))
            renamed.bitRate = 999
            var disabled = try XCTUnwrap(library.storedSong(id: songs[7].id))
            disabled.duration = 111
            var recovered = try XCTUnwrap(library.storedSong(id: songs[3].id))
            recovered.coverArtFileName = "replaced-cover.jpg"
            var lateRenamed = try XCTUnwrap(library.storedSong(id: lateRenamedID))
            XCTAssertEqual(lateRenamed.lyricsText, "renamed a moment ago")
            lateRenamed.bitRate = 777
            XCTAssertNil(library.storedSong(id: songs[6].id))
            library.replaceSongs([renamed, disabled, recovered, lateRenamed])
        }
        try mutate(loaded)
        let loadedSets = try XCTUnwrap(loaded.persistedSongChangeSetsForTesting)
        try mutate(dropped)
        let droppedSets = try XCTUnwrap(dropped.persistedSongChangeSetsForTesting)

        XCTAssertEqual(loadedSets.count, 4, "lyrics, asset references, one row, a batch")
        XCTAssertEqual(droppedSets.count, loadedSets.count)
        // 歌词那一批两边走的是同一份字典,先后也相同。资源引用和整批替换在数组那条路上就是按各自的字典 / 集合
        // 的遍历顺序交的(每个实例一个顺序,同一个库跑两次也不保证相同),这两批按 id 排好再比。
        let unordered: Set<Int> = [1, 3]
        XCTAssertEqual(loadedSets.map { $0.upserts.count }, [3, 2, 1, 4])
        for (index, (expected, actual)) in zip(loadedSets, droppedSets).enumerated() {
            if unordered.contains(index) {
                assertSameSongs(
                    actual.upserts.sorted { $0.id < $1.id }, expected.upserts.sorted { $0.id < $1.id }, "change set \(index)"
                )
            } else {
                assertSameSongs(actual.upserts, expected.upserts, "change set \(index)")
            }
            XCTAssertEqual(actual.deletingIDs, expected.deletingIDs, "change set \(index)")
            XCTAssertEqual(actual.renaming, expected.renaming, "change set \(index)")
        }
        XCTAssertEqual(loadedSets[3].upserts.first { $0.id == songs[7].id }?.duration, 111, "a row in a disabled source is written too")
        // 写完当场读得到(待写登记),不用等目录。
        XCTAssertEqual(dropped.storedSong(id: songs[0].id)?.lyricsText, "la la")
        XCTAssertEqual(dropped.storedSong(id: songs[0].id)?.coverArtFileName, "cover-new.jpg")
        XCTAssertEqual(dropped.storedSong(id: songs[2].id)?.duration, 321)
        XCTAssertEqual(dropped.storedSong(id: renamedID)?.bitRate, 999)
        XCTAssertEqual(dropped.storedSong(id: lateRenamedID)?.bitRate, 777)
        XCTAssertNil(dropped.storedSong(id: songs[8].id), "a row removed from this device is not written back")

        // 分组输入变了(改标题):要按目录判专辑艺人、整库重新分组,等模型。之后同一行的技术性替换也跟着排队,
        // 不能越过排在前面的那一次。
        let queued = dropped.deferredMutationCountForTesting
        var retitled = try XCTUnwrap(dropped.storedSong(id: songs[4].id))
        retitled.title = "Needs the model"
        dropped.replaceSong(retitled)
        var timedAgain = try XCTUnwrap(dropped.storedSong(id: songs[4].id))
        XCTAssertEqual(timedAgain.title, "Needs the model")
        timedAgain.duration = 555
        dropped.replaceSong(timedAgain)
        XCTAssertEqual(dropped.persistedSongChangeSetsForTesting?.count, loadedSets.count)
        XCTAssertEqual(dropped.deferredMutationCountForTesting, queued + 2)
        // 排了队的字段改动在范围查询里也看得到,与按 id 读到的同一行一致。这一首自成一张专辑(同目录三首署名各不
        // 相同,推断不出专辑艺人),所以再读一张没有排队改动的专辑:范围查询给的每一行都与按 id 读到的相同。
        let queuedAlbumID = try XCTUnwrap(timedAgain.albumID)
        let albumRows = dropped.songs(forAlbum: queuedAlbumID)
        XCTAssertEqual(albumRows.first { $0.id == songs[4].id }?.title, "Needs the model")
        XCTAssertEqual(albumRows.first { $0.id == songs[4].id }?.duration, 555)
        let untouchedAlbumID = try XCTUnwrap(dropped.storedSong(id: songs[0].id)?.albumID)
        let untouchedRows = dropped.songs(forAlbum: untouchedAlbumID)
        XCTAssertTrue(untouchedRows.contains { $0.id == songs[0].id })
        for row in albumRows + untouchedRows {
            assertSameSong(row, dropped.storedSong(id: row.id), "range row \(row.id)")
        }

        // 两边旧库与目录里的行相同。
        await loaded.waitForCatalogMirror()
        let droppedHost = try XCTUnwrap(dropped.catalogHost)
        let acknowledged = await droppedHost.pendingWrites.waitUntilAcknowledged(
            through: droppedHost.pendingWrites.lastSequence, timeout: .seconds(20)
        )
        XCTAssertTrue(acknowledged, "the catalog caught up with the writes made without the model")
        await droppedHost.mirror.waitUntilIdle()
        func storeRows(_ storage: URL) throws -> [Song] {
            try IncrementalSongStore(path: storage.appendingPathComponent("library-songs.sqlite").path).loadSongs()
        }
        let loadedStore = try storeRows(loadedDirectory)
        let droppedStore = try storeRows(twinDirectory)
        XCTAssertEqual(loadedStore.count, songs.count - 2)
        assertSameSongs(droppedStore, loadedStore, "store rows")
        let ids = loadedStore.map(\.id)
        let loadedCatalog = try XCTUnwrap(loaded.catalogHost?.mirror.caughtUpCatalog).songs(ids: ids)
        let droppedCatalog = try XCTUnwrap(droppedHost.mirror.caughtUpCatalog).songs(ids: ids)
        assertSameSongs(droppedCatalog, loadedCatalog, "catalog rows")
        XCTAssertEqual(droppedCatalog.first { $0.id == songs[2].id }?.duration, 321)
        XCTAssertEqual(droppedCatalog.first { $0.id == lateRenamedID }?.lyricsText, "renamed a moment ago")
        XCTAssertNil(droppedCatalog.first { $0.id == songs[6].id })
        XCTAssertEqual(droppedCatalog.first { $0.id == songs[4].id }?.title, songs[4].title, "the queued replacement is not written")
    }

    /// 模型不在内存里时,要数组的写(这里用整库换 id)照旧排队;排在它们后面到的行写、小状态的写也跟着排队,
    /// 不越到前头。
    /// 排队之前已经攒下、还没落地的资源引用补丁,到点时不对着空数组应用(那样会整批丢掉),跟在后面排队。
    func testRowWritesQueueBehindMutationsThatNeedTheSongModel() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        library.dropSongModelForMeasurement(includingCollections: true)
        library.persistedSongChangeSetsForTesting = []
        let queued = library.deferredMutationCountForTesting

        // 这一条走得通按 id 直接写的路:补丁先攒着(两秒的合批窗口),还没写。
        library.updateAssetReferences(songID: songs[0].id, coverRef: "late.jpg")
        XCTAssertEqual(library.deferredMutationCountForTesting, queued)
        XCTAssertEqual(library.persistedSongChangeSetsForTesting?.count, 0)
        // 整库换 id 要数组(每一行都重写),排队。
        library.remapSongIDs([songs[1].id: "renamed-when-the-model-is-back"])
        XCTAssertEqual(library.deferredMutationCountForTesting, queued + 1)
        // 攒着的补丁到点:前面排着突变,不直接写,也不丢 —— 排在后面。
        library.flushPendingAssetReferencePatches()
        XCTAssertEqual(library.deferredMutationCountForTesting, queued + 2)
        // 之后到的行写同样排队。
        library.updateLyricsText([songs[2].id: "after the queued rename"])
        library.updateMusicVideoReference(songID: songs[3].id, mvPath: "/Videos/later.mp4")
        var timed = try XCTUnwrap(library.storedSong(id: songs[1].id))
        timed.duration = 999
        library.replaceSong(timed)
        XCTAssertEqual(library.deferredMutationCountForTesting, queued + 5)
        XCTAssertEqual(library.persistedSongChangeSetsForTesting?.count, 0, "nothing reached the store out of order")

        let host = try XCTUnwrap(library.catalogHost)
        await host.mirror.waitUntilIdle()
        let stored = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path).loadSongs()
        assertSameSongs(stored, try XCTUnwrap(host.mirror.caughtUpCatalog).songs(ids: stored.map(\.id)), "store and catalog")
        XCTAssertEqual(stored.count, songs.count)
        XCTAssertEqual(stored.first { $0.id == songs[0].id }?.coverArtFileName, songs[0].coverArtFileName)
        XCTAssertNil(stored.first { $0.id == songs[2].id }?.lyricsText)
    }

    // MARK: - Small state without the song model (P3 step 6a)

    /// 小状态的落盘(便携快照的基线 `library-cache.json` 与增量 `library-cache.delta.plist`)在歌曲模型在内存里和
    /// 放掉之后写出来的文件相同:同一个库、同一份状态,先走原来的路(模型在),再放掉模型走新的路,逐字节比。
    /// 库里有停用的源、本机移除的行(随快照走)、墓碑、歌单、喜欢/不喜欢、最近播放、评价。
    /// 兜底歌曲副本在模型放掉时不重写(更不会被空数组盖掉);不带专辑的启动缓存不妨碍下一次装载。
    func testSmallStateFilesAreByteIdenticalWithTheSongModelLoadedOrReleased() async throws {
        func seeded(_ name: String) async throws -> (library: MusicLibrary, storage: URL, songs: [Song]) {
            let storage = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let library = MusicLibrary(
                disabledSourceIDs: [Self.sourceB], storageDirectory: storage, artistNameConfiguration: .defaultValue,
                deferredMaintenanceAllowed: { true }, catalogMirroring: .enabled(startDelay: .zero)
            )
            library.catalogShadowModeOverride = .deep
            libraries.append(library)
            let songs = Self.fixture(prefix: name)
            library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
            _ = library.createPlaylist(name: "Kept", songIDs: songs.prefix(6).map(\.id))
            library.setLiked(songID: songs[0].id, isLiked: true, propagatesServerMutation: false)
            library.setDisliked(songID: songs[1].id, isDisliked: true)
            library.recordPlayback(of: songs[2].id)
            library.updateLibraryReview(for: .song(songs[3].id), rating: 4, comment: "kept")
            XCTAssertFalse(try library.removeSongsFromThisDevice([songs[8]]).isEmpty)
            _ = library.deleteSongs([songs[9]])
            await assertShadowMatches(library, "\(name) fixture")
            return (library, storage, songs)
        }
        func bytes(_ storage: URL, _ file: String) throws -> Data {
            try Data(contentsOf: storage.appendingPathComponent(file))
        }
        func write(_ library: MusicLibrary, materialize: Bool, _ step: String) async {
            library.markPortableSnapshotDirtyForTesting()
            guard case .success = await library.persistNowAndWait(materializePortableSnapshot: materialize) else {
                return XCTFail("\(step): the snapshot was not written")
            }
        }
        let baseFile = "library-cache.json"
        let deltaFile = "library-cache.delta.plist"

        // 1. 整份基线。
        do {
            let (library, storage, songs) = try await seeded("base")
            await write(library, materialize: true, "loaded")
            let loaded = try bytes(storage, baseFile)
            await write(library, materialize: true, "loaded again")
            XCTAssertEqual(try bytes(storage, baseFile), loaded, "the existing path writes the same bytes for an unchanged state")
            let fallback = try bytes(storage, MusicLibrary.songFallbackFileName)
            let albumCount = library.albums.count
            XCTAssertGreaterThan(albumCount, 0)

            library.dropSongModelForMeasurement(includingCollections: true)
            XCTAssertTrue(library.songs.isEmpty)
            await write(library, materialize: true, "released")
            XCTAssertEqual(try bytes(storage, baseFile), loaded, "base written with the model released")
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent(deltaFile).path))
            XCTAssertEqual(try bytes(storage, MusicLibrary.songFallbackFileName), fallback, "the fallback copy is neither rewritten nor emptied")
            // 文件里是今天那份不带歌的快照:只带本机移除后留着的那一行。
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: loaded) as? [String: Any])
            XCTAssertEqual(object["separateSongStore"] as? Bool, true)
            XCTAssertEqual((object["songs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [songs[8].id])
            // 带歌的整库导出(iCloud、Apple TV)要模型:放掉时不导出,不会把空曲库发出去。
            guard case .unavailable = await library.portableSnapshotIncludingSongs(byteLimit: .max) else {
                return XCTFail("a library without its song model must not export a whole-library snapshot")
            }
            // 这次写的启动缓存不带专辑、艺人:从同一个目录再装一次,歌和专辑都齐。
            let reopened = MusicLibrary(
                disabledSourceIDs: [Self.sourceB], storageDirectory: storage, artistNameConfiguration: .defaultValue,
                deferredMaintenanceAllowed: { true }, catalogMirroring: .disabled
            )
            XCTAssertEqual(reopened.songs.count, songs.count - 2)
            XCTAssertEqual(reopened.albums.count, albumCount)
            XCTAssertTrue(reopened.isLiked(songID: songs[0].id))
        }

        // 2. 增量。只改一个字段(最近播放)时属性表里只有一个键,逐字节比;改了几个字段时键的先后原来那条路
        // 两次写也不保证相同(每次新建的字典各有各的遍历顺序),那时比内容,原来的路自己两次相同才比字节。
        func compareDelta(_ name: String, singleField: Bool, _ mutate: (MusicLibrary, [Song]) -> Void) async throws {
            let (library, storage, songs) = try await seeded(name)
            await write(library, materialize: true, "\(name) baseline")
            let base = try bytes(storage, baseFile)
            mutate(library, songs)
            await write(library, materialize: false, "\(name) loaded")
            let loaded = try bytes(storage, deltaFile)
            await write(library, materialize: false, "\(name) loaded again")
            let loadedAgain = try bytes(storage, deltaFile)

            library.dropSongModelForMeasurement(includingCollections: true)
            await write(library, materialize: false, "\(name) released")
            let released = try bytes(storage, deltaFile)
            XCTAssertEqual(try bytes(storage, baseFile), base, "\(name): a delta write leaves the base alone")
            func propertyList(_ data: Data) throws -> NSDictionary {
                try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
            }
            XCTAssertEqual(try propertyList(released), try propertyList(loaded), "\(name): delta content")
            if singleField {
                XCTAssertEqual(loadedAgain, loaded, "\(name): the existing path writes the same bytes for an unchanged state")
                XCTAssertEqual(released, loaded, "\(name): delta written with the model released")
            } else if loadedAgain == loaded {
                XCTAssertEqual(released, loaded, "\(name): delta written with the model released")
            }
            print("REPORT_SMALL_STATE_DELTA \(name) bytes=\(loaded.count) existingPathStable=\(loadedAgain == loaded) releasedSameBytes=\(released == loaded)")
        }
        try await compareDelta("delta-one", singleField: true) { library, songs in
            library.recordPlayback(of: songs[3].id)
        }
        try await compareDelta("delta-many", singleField: false) { library, songs in
            library.recordPlayback(of: songs[3].id)
            library.setLiked(songID: songs[4].id, isLiked: true, propagatesServerMutation: false)
            library.updateLibraryReview(for: .song(songs[5].id), rating: 5, comment: "later")
        }
    }

    /// 歌曲模型放掉之后改的小状态(喜欢/不喜欢、歌单成员与先后、最近播放、评价)不排队等模型,当场生效、照常落盘。
    /// 不做任何收尾 —— 只等武装好的那次防抖写入自己跑完,像进程随后被杀那样 —— 从同一个目录再开一个库,改动都在。
    func testSmallStateChangedWhileTheSongModelIsReleasedSurvivesWithoutACleanShutdown() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        let playlist = library.createPlaylist(name: "Kept", songIDs: songs.prefix(3).map(\.id))
        library.setLiked(songID: songs[0].id, isLiked: true, propagatesServerMutation: false)
        await assertShadowMatches(library, "fixture")
        guard case .success = await library.persistNowAndWait() else { return XCTFail("the fixture did not persist") }

        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)
        let queued = library.deferredMutationCountForTesting
        library.setLiked(songID: songs[4].id, isLiked: true, propagatesServerMutation: true)
        library.setLiked(songID: songs[0].id, isLiked: false, propagatesServerMutation: true)
        library.setDisliked(songID: songs[5].id, isDisliked: true)
        library.setLiked(songID: "never-in-the-library", isLiked: true, propagatesServerMutation: true)
        library.add(songIDs: [songs[6].id, "never-in-the-library"], toPlaylist: playlist.id)
        library.remove(songID: songs[1].id, fromPlaylist: playlist.id)
        library.reorderPlaylistSongs(playlistID: playlist.id, listedOrder: [songs[6].id, songs[2].id, songs[0].id])
        library.recordPlayback(of: songs[3].id)
        library.recordPlayback(of: "never-in-the-library")
        library.updateLibraryReview(for: .song(songs[2].id), rating: 4, comment: "while released")
        XCTAssertEqual(library.deferredMutationCountForTesting, queued, "none of these waits for the song model")

        func assertSmallState(_ library: MusicLibrary, _ step: String) {
            XCTAssertTrue(library.isLiked(songID: songs[4].id), step)
            XCTAssertFalse(library.isLiked(songID: songs[0].id), step)
            XCTAssertFalse(library.isLiked(songID: "never-in-the-library"), step)
            XCTAssertTrue(library.isDisliked(songID: songs[5].id), step)
            XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), [songs[6].id, songs[2].id, songs[0].id], step)
            XCTAssertEqual(library.recentPlaybackSongIDsForSync.first, songs[3].id, step)
            XCTAssertFalse(library.recentPlaybackSongIDsForSync.contains("never-in-the-library"), step)
            XCTAssertEqual(library.libraryReview(for: .song(songs[2].id))?.rating, 4, step)
            XCTAssertEqual(library.libraryReview(for: .song(songs[2].id))?.comment, "while released", step)
        }
        assertSmallState(library, "at once, with the model released")

        // 不调任何落盘入口:评价武装的是 0.2 秒档的防抖写入,等它自己写完。
        let deadline = ContinuousClock.now + .seconds(10)
        while library.hasPendingPortableSnapshotChanges, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(library.hasPendingPortableSnapshotChanges, "the debounced write ran with the model released")

        // 「进程被杀」:原来那个库不再碰,同一个目录再开一个。
        let reopened = makeLibrary(catalog: .disabled)
        XCTAssertEqual(reopened.songs.count, songs.count)
        assertSmallState(reopened, "after reopening")
    }

    // MARK: - Deleting, device removal and launch reconciliation without the song model (P3 step 6b)

    /// 绕过曲库直接改旧库,目录按同一个修订号跟上:另一台设备的快照带回来的行、上一次进程没写完的删除。
    private func writeBehindTheLibrary(
        _ library: MusicLibrary, storage: URL, upserts: [Song] = [], deletingIDs: Set<String> = []
    ) async throws {
        let host = try XCTUnwrap(library.catalogHost)
        let store = try IncrementalSongStore(path: storage.appendingPathComponent("library-songs.sqlite").path)
        let revision = try store.apply(upserts: upserts, deletingIDs: deletingIDs)
        host.mirror.enqueueApply(upserts: upserts, deletingIDs: deletingIDs, storeRevision: revision)
        await host.mirror.waitUntilIdle()
    }

    private func catalogSongIDs(_ library: MusicLibrary) throws -> [String] {
        var ids: [String] = []
        try XCTUnwrap(library.catalogHost?.mirror.caughtUpCatalog).forEachSongIdentity(.everything) { _, id, _ in
            ids.append(id)
            return true
        }
        return ids
    }

    /// 按 id 删歌、「从本机移除」在模型在内存里的库和放掉的库上各做一遍:返回的按源剩余数、交给 `persistSongChanges`
    /// 的改动、发出去的 `.primuseSongsRemoved`、歌单成员(被删的歌换成另一个源里的同一首,没有另一份的去掉)、
    /// 喜欢、最近播放、墓碑、本机移除账本都相同;做完之后两边旧库与目录里的行也相同。
    func testDeletingAndRemovingFromThisDeviceWithoutTheSongModelMatchTheLoadedLibrary() async throws {
        let songs = Self.fixture(prefix: "gone")
        // blue-1 在另一个启用的源里还有一份:歌单里引用它的成员在它被删之后换过去。
        var copy = songs[0]
        copy.id = "gone-blue-1-copy"
        copy.sourceID = "dual-write-c"
        copy.filePath = "/Other/Blue Room/1.flac"
        var playlistIDs: [String] = []
        func make(_ name: String) async throws -> (library: MusicLibrary, storage: URL) {
            let twin = try makeTwin(name, songs: songs, extra: [copy])
            let playlist = twin.library.createPlaylist(
                name: "Kept", songIDs: [songs[0].id, songs[4].id, songs[5].id, songs[15].id, songs[2].id]
            )
            playlistIDs.append(playlist.id)
            twin.library.setLiked(songID: songs[4].id, isLiked: true, propagatesServerMutation: false)
            twin.library.setLiked(songID: songs[2].id, isLiked: true, propagatesServerMutation: false)
            twin.library.recordPlayback(of: songs[2].id)
            twin.library.recordPlayback(of: songs[4].id)
            twin.library.recordPlayback(of: songs[5].id)
            await assertShadowMatches(twin.library, "\(name) fixture")
            return twin
        }
        let loaded = try await make("loaded")
        let dropped = try await make("dropped")
        dropped.library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(dropped.library.isReady)

        struct Outcome {
            var single = 0
            var batch: [String: Int] = [:]
            var device: [String: Int] = [:]
            var removals: [[String]] = []
        }
        func mutate(_ library: MusicLibrary) throws -> Outcome {
            var outcome = Outcome()
            let recorder = RemovedSongIDsRecorder()
            let observer = NotificationCenter.default.addObserver(forName: .primuseSongsRemoved, object: library, queue: nil) { note in
                recorder.record(((note.userInfo?["songIDs"] as? Set<String>) ?? []).sorted())
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            library.persistedSongChangeSetsForTesting = []
            outcome.single = library.deleteSong(songs[5])
            outcome.batch = library.deleteSongs([songs[0], songs[4], songs[7]], sourceFileDeleted: true)
            outcome.device = try library.removeSongsFromThisDevice([songs[15], songs[9]])
            outcome.removals = recorder.all
            return outcome
        }
        let expected = try mutate(loaded.library)
        let queued = dropped.library.deferredMutationCountForTesting
        let actual = try mutate(dropped.library)
        XCTAssertEqual(dropped.library.deferredMutationCountForTesting, queued, "none of these waits for the song model")

        XCTAssertEqual(actual.single, expected.single)
        XCTAssertEqual(actual.batch, expected.batch)
        XCTAssertEqual(actual.device, expected.device)
        XCTAssertEqual(expected.batch[Self.sourceB], 3, "a disabled source is counted too")
        XCTAssertEqual(actual.removals, expected.removals)
        XCTAssertEqual(expected.removals.count, 3)
        let expectedSets = try XCTUnwrap(loaded.library.persistedSongChangeSetsForTesting)
        let actualSets = try XCTUnwrap(dropped.library.persistedSongChangeSetsForTesting)
        XCTAssertEqual(actualSets.map(\.deletingIDs), expectedSets.map(\.deletingIDs))
        XCTAssertEqual(expectedSets.map(\.deletingIDs), [[songs[5].id], [songs[0].id, songs[4].id, songs[7].id], [songs[15].id, songs[9].id]])
        XCTAssertTrue(actualSets.allSatisfy { $0.upserts.isEmpty && $0.renaming.isEmpty })

        // 小状态。
        for (index, twin) in [loaded, dropped].enumerated() {
            let library = twin.library
            let step = index == 0 ? "loaded" : "released"
            XCTAssertEqual(
                library.rawSongIDs(forPlaylist: playlistIDs[index]), [copy.id, songs[15].id, songs[2].id],
                "\(step): the deleted song moves to its other copy, the ones without a copy go, a device removal keeps its place"
            )
            XCTAssertFalse(library.isLiked(songID: songs[4].id), step)
            XCTAssertTrue(library.isLiked(songID: songs[2].id), step)
            XCTAssertEqual(library.recentPlaybackSongIDsForSync, [songs[2].id], step)
            XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: Self.sourceA), [songs[15].id, songs[9].id], step)
            XCTAssertNil(library.storedSong(id: songs[0].id), step)
            XCTAssertNil(library.storedSong(id: songs[15].id), step)
            XCTAssertNotNil(library.songForSynchronization(id: songs[15].id), "\(step): the retained copy is still seen by synchronization")
            XCTAssertNotNil(library.storedSong(id: copy.id), step)
        }
        XCTAssertEqual(dropped.library.deletedSongIdentities, loaded.library.deletedSongIdentities)
        XCTAssertEqual(dropped.library.deletedSongIdentities.count, 4)
        XCTAssertEqual(dropped.library.deviceLocalExcludedSongIdentities, loaded.library.deviceLocalExcludedSongIdentities)

        // 两边旧库与目录里的行相同。
        await loaded.library.waitForCatalogMirror()
        let droppedHost = try XCTUnwrap(dropped.library.catalogHost)
        let acknowledged = await droppedHost.pendingWrites.waitUntilAcknowledged(
            through: droppedHost.pendingWrites.lastSequence, timeout: .seconds(20)
        )
        XCTAssertTrue(acknowledged)
        await droppedHost.mirror.waitUntilIdle()
        func storeRows(_ storage: URL) throws -> [Song] {
            try IncrementalSongStore(path: storage.appendingPathComponent("library-songs.sqlite").path).loadSongs()
        }
        let loadedStore = try storeRows(loaded.storage)
        let droppedStore = try storeRows(dropped.storage)
        // 行本身逐字段相同。留下的行存着的专辑/艺人 id 另看:模型在内存里时删歌之后的派生重建可能给同专辑的
        // 其它行换 id(专辑艺人推断变了),模型不在时没有那次重建,旧库里这两个字段要到下次装模型才重新派生
        // (目录自己那一层照常重新分组)。
        func withoutDerivedIDs(_ rows: [Song]) -> [Song] {
            rows.map { row in
                var copy = row
                copy.albumID = nil
                copy.artistID = nil
                return copy
            }
        }
        assertSameSongs(withoutDerivedIDs(droppedStore), withoutDerivedIDs(loadedStore), "store rows")
        let regrouped = zip(droppedStore, loadedStore)
            .filter { $0.albumID != $1.albumID || $0.artistID != $1.artistID }
            .map { $0.0.id }
        print("REPORT_DELETE_WITHOUT_MODEL storeRows=\(loadedStore.count) rowsWhoseStoredGroupingIDsDiffer=\(regrouped)")
        XCTAssertEqual(loadedStore.count, songs.count + 1 - 6)
        XCTAssertEqual(try catalogSongIDs(dropped.library), try catalogSongIDs(loaded.library))
        XCTAssertEqual(try catalogSongIDs(dropped.library).sorted(), loadedStore.map(\.id).sorted())
    }

    /// 「从本机移除」的账本说不要、目录里却还留着的行(另一台设备的快照带回来的):装载时那一遍排除过滤把它滤掉;
    /// 模型不装时没有人做那一遍,`reconcileDeviceLocalExclusionsWithoutTheModel` 从账本出发把它从旧库删掉,
    /// 目录跟着删,列表看不到它。结果与从同一份磁盘状态装一次相同。
    func testDeviceRemovalLedgerIsAppliedToTheCatalogWithoutTheSongModel() async throws {
        let songs = Self.fixture(prefix: "ledger")
        func make(_ name: String) async throws -> (library: MusicLibrary, storage: URL) {
            let twin = try makeTwin(name, songs: songs)
            XCTAssertFalse(try twin.library.removeSongsFromThisDevice([songs[1], songs[15]]).isEmpty)
            await assertShadowMatches(twin.library, "\(name) fixture")
            guard case .success = await twin.library.persistNowAndWait() else { XCTFail("\(name) did not persist"); return twin }
            // 这两行又回到了旧库和目录里,账本还记着本机不要它们。
            try await writeBehindTheLibrary(twin.library, storage: twin.storage, upserts: [songs[1], songs[15]])
            return twin
        }
        let loaded = try await make("loaded")
        let dropped = try await make("dropped")

        // 放掉模型的那一边:目录里有这两行(列表读得到),按 id 读本来就不给。
        dropped.library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertEqual(try catalogSongIDs(dropped.library).count, songs.count)
        XCTAssertNil(dropped.library.storedSong(id: songs[1].id))
        dropped.library.persistedSongChangeSetsForTesting = []
        XCTAssertEqual(dropped.library.reconcileDeviceLocalExclusionsWithoutTheModel(), 2)
        XCTAssertEqual(dropped.library.persistedSongChangeSetsForTesting?.map(\.deletingIDs), [[songs[1].id, songs[15].id]])
        XCTAssertEqual(dropped.library.reconcileDeviceLocalExclusionsWithoutTheModel(), 0, "nothing is left to remove")
        let host = try XCTUnwrap(dropped.library.catalogHost)
        let acknowledged = await host.pendingWrites.waitUntilAcknowledged(through: host.pendingWrites.lastSequence, timeout: .seconds(20))
        XCTAssertTrue(acknowledged)
        await host.mirror.waitUntilIdle()

        // 另一边:从同一份磁盘状态装一次(装载里的排除过滤)。
        let reloaded = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: loaded.storage, artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true }, catalogMirroring: .disabled
        )
        XCTAssertNil(reloaded.storedSong(id: songs[1].id))
        XCTAssertNil(reloaded.storedSong(id: songs[15].id))
        XCTAssertEqual(try catalogSongIDs(dropped.library).sorted(), reloaded.songs.map(\.id).sorted())
        XCTAssertEqual(reloaded.songs.count, songs.count - 2)
        XCTAssertEqual(
            dropped.library.locallyRemovedSongIDs(forSourceID: Self.sourceA), reloaded.locallyRemovedSongIDs(forSourceID: Self.sourceA)
        )
        XCTAssertEqual(dropped.library.locallyRemovedSongIDs(forSourceID: Self.sourceA), [songs[1].id, songs[15].id])
        let droppedStore = try IncrementalSongStore(
            path: dropped.storage.appendingPathComponent("library-songs.sqlite").path
        ).loadSongs()
        XCTAssertEqual(droppedStore.map(\.id).sorted(), reloaded.songs.map(\.id).sorted())
        // 模型在内存里时这个入口不动(那一遍在装载里做过了)。
        XCTAssertNil(loaded.library.reconcileDeviceLocalExclusionsWithoutTheModel())
    }

    /// 启动时歌单成员与最近播放的清理:装载里那一遍对着装好的歌曲数组滤;模型不装时把要问的 id 交给目录查在不在。
    /// 同一份磁盘状态(有的成员对应的行已经不在旧库里了),放掉模型做一遍与装一次的结果相同。
    func testLaunchCleanupOfPlaylistsAndHistoryWithoutTheSongModelMatchesTheLoad() async throws {
        let songs = Self.fixture(prefix: "stale")
        var playlistIDs: [String] = []
        func make(_ name: String) async throws -> (library: MusicLibrary, storage: URL) {
            let twin = try makeTwin(name, songs: songs)
            let playlist = twin.library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[1].id, songs[2].id, songs[3].id, songs[15].id])
            playlistIDs.append(playlist.id)
            twin.library.setLiked(songID: songs[2].id, isLiked: true, propagatesServerMutation: false)
            twin.library.setLiked(songID: songs[4].id, isLiked: true, propagatesServerMutation: false)
            twin.library.recordPlayback(of: songs[0].id)
            twin.library.recordPlayback(of: songs[1].id)
            // 本机移除后留着的那一份照旧算在:歌单里的位置留着。
            XCTAssertFalse(try twin.library.removeSongsFromThisDevice([songs[15]]).isEmpty)
            await assertShadowMatches(twin.library, "\(name) fixture")
            guard case .success = await twin.library.persistNowAndWait() else { XCTFail("\(name) did not persist"); return twin }
            // 这两行从旧库和目录里没了,歌单、喜欢、最近播放还引用着它们。
            try await writeBehindTheLibrary(twin.library, storage: twin.storage, deletingIDs: [songs[1].id, songs[2].id])
            return twin
        }
        let loaded = try await make("loaded")
        let dropped = try await make("dropped")

        dropped.library.dropSongModelForMeasurement(includingCollections: true)
        let cleaned = await dropped.library.cleanPlaylistAndHistoryEntriesWithoutTheModel()
        XCTAssertEqual(cleaned?.members, 3, "two members of the playlist and one liked song")
        XCTAssertEqual(cleaned?.history, 1)
        let again = await dropped.library.cleanPlaylistAndHistoryEntriesWithoutTheModel()
        XCTAssertEqual(again?.members, 0)
        XCTAssertEqual(again?.history, 0)

        let reloaded = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: loaded.storage, artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true }, catalogMirroring: .disabled
        )
        XCTAssertEqual(dropped.library.rawSongIDs(forPlaylist: playlistIDs[1]), [songs[0].id, songs[3].id, songs[15].id])
        XCTAssertEqual(reloaded.rawSongIDs(forPlaylist: playlistIDs[0]), [songs[0].id, songs[3].id, songs[15].id])
        XCTAssertEqual(dropped.library.recentPlaybackSongIDsForSync, reloaded.recentPlaybackSongIDsForSync)
        XCTAssertEqual(dropped.library.recentPlaybackSongIDsForSync, [songs[0].id])
        XCTAssertEqual(dropped.library.likedSongIDSnapshot(), reloaded.likedSongIDSnapshot())
        XCTAssertEqual(dropped.library.likedSongIDSnapshot(), [songs[4].id])
        // 模型在内存里时这个入口不动。
        let untouched = await loaded.library.cleanPlaylistAndHistoryEntriesWithoutTheModel()
        XCTAssertNil(untouched)
    }

    /// 停用、启用音乐源在歌曲模型放掉之后直接交给目录:目录上的可见范围与模型在内存里的那个库的目录相同,
    /// 按 id 读的可见口径当场就变。
    func testDisablingASourceWithoutTheSongModelReachesTheCatalog() async throws {
        let songs = Self.fixture(prefix: "toggle")
        func make(_ name: String) async throws -> (library: MusicLibrary, storage: URL) {
            let twin = try makeTwin(name, songs: songs)
            await assertShadowMatches(twin.library, "\(name) fixture")
            return twin
        }
        let loaded = try await make("loaded")
        let dropped = try await make("dropped")
        dropped.library.dropSongModelForMeasurement(includingCollections: true)
        let host = try XCTUnwrap(dropped.library.catalogHost)
        func visibleCounts(_ library: MusicLibrary) throws -> [String: Int] {
            try XCTUnwrap(library.catalogHost?.mirror.caughtUpCatalog).songCountsBySource(.visible)
        }
        XCTAssertEqual(try visibleCounts(dropped.library), [Self.sourceA: 14])

        // 停用 A、启用 B。
        loaded.library.updateDisabledSourceIDs([Self.sourceA])
        dropped.library.updateDisabledSourceIDs([Self.sourceA])
        XCTAssertNil(dropped.library.visibleSong(id: songs[0].id), "the by-id path uses the new setting at once")
        XCTAssertNotNil(dropped.library.visibleSong(id: songs[7].id))
        await loaded.library.waitForCatalogMirror()
        await host.mirror.waitUntilIdle()
        XCTAssertEqual(try visibleCounts(loaded.library), [Self.sourceB: 4])
        XCTAssertEqual(try visibleCounts(dropped.library), try visibleCounts(loaded.library))

        // 都启用。
        loaded.library.updateDisabledSourceIDs([])
        dropped.library.updateDisabledSourceIDs([])
        await loaded.library.waitForCatalogMirror()
        await host.mirror.waitUntilIdle()
        XCTAssertEqual(try visibleCounts(dropped.library), try visibleCounts(loaded.library))
        XCTAssertEqual(try visibleCounts(dropped.library), [Self.sourceA: 14, Self.sourceB: 4])
        XCTAssertNotNil(dropped.library.visibleSong(id: songs[0].id))
    }

    /// 6a 没转的那些小状态入口(歌单的建、改名、简介、置顶、整份替换、删除、恢复、彻底删除,智能歌单,撤销墓碑,
    /// 清空最近播放,随机连播标记)在歌曲模型放掉之后不排队,做出来的小状态与模型在内存里的库相同,
    /// 不做任何收尾从同一个目录再开一个库也相同。
    func testPlaylistAndRecordEditsWithoutTheSongModelMatchTheLoadedLibrary() async throws {
        let songs = Self.fixture(prefix: "edits")
        let smart = SmartPlaylist(name: "Smart")
        let removedSmart = SmartPlaylist(name: "Removed smart")
        func make(_ name: String) async throws -> (library: MusicLibrary, storage: URL) {
            let twin = try makeTwin(name, songs: songs)
            _ = twin.library.deleteSongs([songs[9]])
            twin.library.recordPlayback(of: songs[0].id)
            _ = twin.library.createPlaylist(name: "Doomed", songIDs: [songs[0].id])
            _ = twin.library.createPlaylist(name: "Purged", songIDs: [songs[1].id])
            twin.library.saveSmartPlaylist(removedSmart)
            await assertShadowMatches(twin.library, "\(name) fixture")
            return twin
        }
        let loaded = try await make("loaded")
        let dropped = try await make("dropped")
        dropped.library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(dropped.library.isReady)

        func mutate(_ library: MusicLibrary, _ step: String) throws {
            let doomed = try XCTUnwrap(library.allPlaylists.first { $0.name == "Doomed" }).id
            let purged = try XCTUnwrap(library.allPlaylists.first { $0.name == "Purged" }).id
            let made = library.createPlaylist(
                name: "Made", songIDs: [songs[2].id, "never-in-the-library", songs[3].id, songs[2].id]
            )
            XCTAssertEqual(library.rawSongIDs(forPlaylist: made.id), [songs[2].id, songs[3].id], step)
            XCTAssertTrue(library.renamePlaylist(id: made.id, to: "Renamed"), step)
            XCTAssertTrue(library.updatePlaylistDescription(id: made.id, description: "notes"), step)
            library.add(songIDs: [songs[4].id], toPlaylist: made.id)
            XCTAssertTrue(library.pinSongs([songs[3].id], inPlaylist: made.id), step)
            library.replacePlaylistSongs(
                playlistID: made.id, songIDs: [songs[4].id, songs[3].id, "never-in-the-library", songs[2].id]
            )
            XCTAssertEqual(library.rawSongIDs(forPlaylist: made.id), [songs[4].id, songs[3].id, songs[2].id], step)
            library.deletePlaylist(id: doomed)
            library.restorePlaylist(id: doomed)
            library.deletePlaylist(id: purged)
            library.permanentlyDeletePlaylist(id: purged)
            library.saveSmartPlaylist(smart)
            library.deleteSmartPlaylist(id: removedSmart.id)
            library.restoreDeletedSong(songs[9])
            library.clearPlaybackHistory()
            library.setShuffleLinked(songID: songs[5].id, direction: .next, isLinked: true)
            library.setShuffleLinked(songID: "never-in-the-library", direction: .next, isLinked: true)
        }
        try mutate(loaded.library, "loaded")
        let queued = dropped.library.deferredMutationCountForTesting
        try mutate(dropped.library, "released")
        XCTAssertEqual(dropped.library.deferredMutationCountForTesting, queued, "none of these waits for the song model")

        /// 小状态按名字排好的样子(两个库各自生成的歌单 id 不同,按名字比)。
        func describe(_ library: MusicLibrary) -> [String] {
            let playlists = library.allPlaylists.map { playlist in
                "playlist \(playlist.name) deleted=\(playlist.isDeleted) purged=\(playlist.isPurged)"
                    + " description=\(playlist.descriptionText) pinned=\(playlist.pinnedSongIDs)"
                    + " members=\(library.rawSongIDs(forPlaylist: playlist.id))"
            }
            let smartPlaylists = library.allSmartPlaylists.map { "smart \($0.name) deleted=\($0.isDeleted)" }
            return (playlists + smartPlaylists).sorted() + [
                "tombstones \(library.deletedSongIdentities.sorted())",
                "recents \(library.recentPlaybackSongIDsForSync)",
                "linked \(library.isShuffleLinked(songID: songs[5].id, direction: .next))",
            ]
        }
        let expected = describe(loaded.library)
        XCTAssertEqual(describe(dropped.library), expected)
        XCTAssertTrue(expected.contains { $0.hasPrefix("playlist Renamed deleted=false purged=false description=notes pinned=[\"\(songs[3].id)\"]") }, "\(expected)")
        XCTAssertTrue(expected.contains { $0.hasPrefix("playlist Doomed deleted=false") }, "\(expected)")
        XCTAssertTrue(expected.contains { $0.hasPrefix("playlist Purged deleted=true purged=true") }, "\(expected)")
        XCTAssertTrue(expected.contains("smart Smart deleted=false"), "\(expected)")
        XCTAssertTrue(expected.contains("smart Removed smart deleted=true"), "\(expected)")
        XCTAssertTrue(expected.contains("tombstones []"), "\(expected)")
        XCTAssertTrue(expected.contains("recents []"), "\(expected)")
        XCTAssertTrue(expected.contains("linked true"), "\(expected)")

        // 不调任何落盘入口,等武装好的防抖写入自己写完,再从同一个目录开一个库。
        let deadline = ContinuousClock.now + .seconds(10)
        while dropped.library.hasPendingPortableSnapshotChanges, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(dropped.library.hasPendingPortableSnapshotChanges)
        let reopened = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: dropped.storage, artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true }, catalogMirroring: .disabled
        )
        XCTAssertEqual(describe(reopened), expected)
    }

    /// 进后台、内存警告走的那条路把目录各连接的缓存也放掉;放完目录照常答、照常跟写。
    func testReleasingRebuildableCachesAlsoReleasesTheCatalogMemory() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertEqual(host.mirror.statistics.memoryReleases, 0)

        library.releaseRebuildableCaches()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while host.mirror.statistics.memoryReleases == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(host.mirror.statistics.memoryReleases, 1)
        XCTAssertEqual(try XCTUnwrap(host.mirror.readableCatalog).song(id: songs[0].id)?.title, songs[0].title)
        var edited = songs[1]
        edited.title = "Edited after the release"
        library.replaceSong(edited)
        await assertShadowMatches(library, "after the release")
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

    /// 按艺人取歌在目录可读时问目录,整库的按艺人索引不留;答案与没有目录、按内存索引算的同一个库
    /// 逐首相同(多艺人署名、只当过专辑艺人、没有艺人、有声书、停用源)。
    func testArtistSongsFromTheCatalogMatchTheInMemoryIndexWithoutRetainingIt() async throws {
        let songs = Self.fixture()
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        XCTAssertEqual(library.catalogHost?.revisions.isReadable, true)

        let memoryDirectory = directory.appendingPathComponent("memory-only", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let reference = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: memoryDirectory,
            artistNameConfiguration: .defaultValue, catalogMirroring: .disabled
        )
        libraries.append(reference)
        reference.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        for _ in 0..<800 where reference.visibleSongs.count != library.visibleSongs.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reference.visibleSongs.map(\.id), library.visibleSongs.map(\.id))

        let artistIDs = Set(reference.visibleArtists.map(\.id) + reference.visibleAlbumArtists.map(\.id)
            + ["Ada", "Ben", "Host", "Narrator", "Nobody"].map { MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey($0)) })
        var withSongs = 0
        for artistID in artistIDs.sorted() {
            let expected = reference.songs(forArtist: artistID).map(\.id)
            XCTAssertEqual(library.songs(forArtist: artistID).map(\.id), expected, artistID)
            XCTAssertEqual(
                library.scopedAlternateArtworkSong(forArtistID: artistID, excludingSongIDs: [], excludingReferences: [])?.id,
                reference.scopedAlternateArtworkSong(forArtistID: artistID, excludingSongIDs: [], excludingReferences: [])?.id,
                artistID
            )
            if !expected.isEmpty { withSongs += 1 }
        }
        XCTAssertGreaterThan(withSongs, 4)
        for name in ["Ada", "Ben", "Artist 2", "Narrator", "Host", "Nobody"] {
            XCTAssertEqual(library.trackSongIDs(forArtistNamed: name), reference.trackSongIDs(forArtistNamed: name), name)
        }
        XCTAssertFalse(library.retainsArtistSongIndexForTesting, "the catalog answers; the whole-library index is not kept")
        XCTAssertTrue(reference.retainsArtistSongIndexForTesting)

        // 改了一首的艺人:目录提交后,按艺人取歌跟着变。
        var moved = songs[0]
        moved.artistName = "Ben"
        library.replaceSong(moved)
        reference.replaceSong(moved)
        await library.waitForCatalogMirror()
        for _ in 0..<400 where library.songs(forArtist: MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey("Ben"))).map(\.id)
            != reference.songs(forArtist: MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey("Ben"))).map(\.id) {
            try await Task.sleep(for: .milliseconds(5))
        }
        for name in ["Ada", "Ben"] {
            let id = MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey(name))
            XCTAssertEqual(library.songs(forArtist: id).map(\.id), reference.songs(forArtist: id).map(\.id), "after edit: \(name)")
        }
    }

    /// 按流派取歌、取专辑在目录可读时问目录的流派表,整库的按流派索引不留;答案与没有目录、按内存索引
    /// 算的同一个库逐首相同(斜杠惯例只对 ID3 格式、分号分隔、大小写与变音符号写法、停用源、有声书)。
    /// 小组件只要有进度的书:曲库目录里这些条目所在的连通块分出来的书,与内存里整个有声书架分出来的相同。
    func testSpokenWordBookClosureFromTheCatalogMatchesTheShelf() async throws {
        let library = makeLibrary()
        var songs = Self.fixture()
        let books = [("/Books/Novel", "Novel", "Writer"), ("/Books/Series/Vol 1", "Series", "Author"),
                     ("/Books/Series/Vol 2", "Series", "Author"), ("/Books/Loose", nil, nil)]
        for (bookIndex, book) in books.enumerated() {
            for chapter in 1...4 {
                songs.append(Song(
                    id: "chapter-\(bookIndex)-\(chapter)", title: "Chapter \(chapter)",
                    albumTitle: book.1, artistName: book.2, trackNumber: chapter,
                    duration: 600, fileFormat: .m4a, filePath: "\(book.0)/\(String(format: "%02d", chapter)).m4b",
                    sourceID: chapter == 4 && bookIndex == 3 ? Self.sourceB : Self.sourceA
                ))
            }
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "addSongs")
        let shelf = library.spokenWordSongs
        XCTAssertGreaterThanOrEqual(shelf.count, 12)
        let wholeShelf = SpokenWordBookGrouping.books(from: shelf.map { SpokenWordBookItem(song: $0) })
        let reader = try XCTUnwrap(library.readableCatalogReader)
        for seed in shelf.map(\.id) {
            let closure = try await reader.read { try $0.spokenBookClosureSongs(containingSongIDs: [seed]) }
            let closureBooks = SpokenWordBookGrouping.books(from: closure.map { SpokenWordBookItem(song: $0) })
            let expected = try XCTUnwrap(wholeShelf.first { book in book.items.contains { $0.id == seed } })
            // 旧库按整秒存日期,从旧库导入目录的条目比内存里这次会话新加的少了零点几秒(小组件不读加入时间)。
            XCTAssertEqual(closureBooks.first { $0.id == expected.id }.map(BookKey.init), BookKey(expected), "book of \(seed)")
        }
    }

    /// 书的各项,条目的加入时间按整秒。
    private struct BookKey: Equatable {
        let id: String
        let title: String
        let author: String?
        let resumeItemID: String?
        let lastListenedAt: Date?
        let items: [SpokenWordBookItem]

        init(_ book: SpokenWordBook) {
            lastListenedAt = book.lastListenedAt
            id = book.id
            title = book.title
            author = book.author
            resumeItemID = book.resumeItemID
            items = book.items.map { item in
                var item = item
                item.addedAt = item.addedAt.map {
                    Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.rounded(.down))
                }
                return item
            }
        }
    }

    func testGenreSongsFromTheCatalogMatchTheInMemoryIndexWithoutRetainingIt() async throws {
        var songs = Self.fixture()
        let genres = ["Rock/Pop", "rock/pop", "Jazz; Blues", "Électronique", "electronique", "R&B", "Pop", "", "Hip-Hop/Rap"]
        for index in 0..<36 {
            songs.append(Song(
                id: "genre-\(index)", title: "Genre \(index)", albumTitle: "Genre Album \(index % 7)",
                artistName: "Genre Artist \(index % 4)", trackNumber: index % 10 + 1, duration: 180,
                fileFormat: index % 2 == 0 ? .mp3 : .flac, filePath: "/Music/Genre/\(index).flac",
                sourceID: index % 5 == 0 ? Self.sourceB : Self.sourceA, genre: genres[index % genres.count]
            ))
        }
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "genre fixture")
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertTrue(host.revisions.isReadable)

        let memoryDirectory = directory.appendingPathComponent("memory-genres", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let reference = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: memoryDirectory,
            artistNameConfiguration: .defaultValue, catalogMirroring: .disabled
        )
        libraries.append(reference)
        reference.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        for _ in 0..<800 where reference.visibleGenres.count != library.visibleGenres.count || reference.visibleGenres.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reference.visibleGenres.map(\.id), library.visibleGenres.map(\.id))
        XCTAssertGreaterThan(reference.visibleGenres.count, 5)

        for genre in reference.visibleGenres + [LibraryGenre(id: "nothing", name: "Nothing", songCount: 0, albumCount: 0, representativeSongIDs: [])] {
            let expected = reference.songs(forGenre: genre.id).map(\.id)
            XCTAssertEqual(library.songs(forGenre: genre.id).map(\.id), expected, genre.id)
            XCTAssertEqual(library.songIDs(forGenre: genre.id), reference.songIDs(forGenre: genre.id), genre.id)
            XCTAssertEqual(library.albums(forGenre: genre.id).map(\.id), reference.albums(forGenre: genre.id).map(\.id), genre.id)
            let rows = try await host.reader.genreSongRowList(genreID: genre.id)
            let listed = try await host.reader.songs(rowids: Array(rows.rowids)).compactMap { $0?.id }
            XCTAssertEqual(listed, expected, "reader \(genre.id)")
            let albumIDs = try await host.reader.genreAlbumIDs(genreID: genre.id)
            XCTAssertEqual(albumIDs, reference.songs(forGenre: genre.id).reduce(into: [String]()) { ids, song in
                if let albumID = song.albumID, !ids.contains(albumID) { ids.append(albumID) }
            }, "reader albums \(genre.id)")
        }
        for texts in [["rock"], ["jazz", "électronique"], ["nothing"]] {
            XCTAssertEqual(library.recommendationGenreGroups()(texts), reference.recommendationGenreGroups()(texts), "\(texts)")
        }
        XCTAssertFalse(library.retainsGenreIndexForTesting, "the catalog answers; the whole-library genre index is not kept")
        XCTAssertTrue(reference.retainsGenreIndexForTesting)
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

    // MARK: - By-id facade without the song model (pending writes → row cache → catalog)

    /// 一个按 id 的入口在一个 id 上的全部答案。
    private struct ByIDAnswers {
        var stored: Song?
        var song: Song?
        var visible: Song?
        var unobserved: Song?
        var contains: Bool
        var synchronization: Song?
    }

    private func byIDAnswers(_ library: MusicLibrary, _ id: String, fromCatalog: Bool) -> ByIDAnswers {
        library.byIDReadsUseCatalogForTesting = fromCatalog
        defer { library.byIDReadsUseCatalogForTesting = false }
        return ByIDAnswers(
            stored: library.storedSong(id: id),
            song: library.song(id: id),
            visible: library.visibleSong(id: id),
            unobserved: library.unobservedVisibleSong(id: id),
            contains: library.containsVisibleSong(id: id),
            synchronization: library.songForSynchronization(id: id)
        )
    }

    /// 按旧库的精度比(日期只到秒):这次会话里新写的行内存里带着小数秒,从旧库重新装载之后没有。
    private func assertSameSong(
        _ actual: Song?, _ expected: Song?, _ message: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !ScanExistingSongsCatalogShadow.sameAtStorePrecision(actual, expected) else { return }
        XCTFail("\(message()): \(ScanExistingSongsCatalogShadow.difference(catalog: actual, array: expected))", file: file, line: line)
    }

    private func assertSameSongs(
        _ actual: [Song], _ expected: [Song], _ message: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard actual.map(\.id) == expected.map(\.id) else {
            return XCTFail("\(message()): catalog=\(actual.map(\.id)) memory=\(expected.map(\.id))", file: file, line: line)
        }
        for (left, right) in zip(actual, expected) { assertSameSong(left, right, "\(message()) \(left.id)", file: file, line: line) }
    }

    /// 每个按 id 的入口,目录这条路(测试开关强制)与内存各答一遍。`settled`:目录跟上了、内存的派生维护也
    /// 落定了,这时两边必须逐项相同。没落定时(改动刚进内存),「存着的那一行」每一刻都相同;内存的可见集
    /// 要等派生维护才跟上(`addSongs` 之后),这期间目录这条路给的是存着的那一行里不在停用源的 —— 也就是
    /// 可见集落定之后的样子。返回这一刻内存的可见集有没有落在后面。
    @discardableResult
    private func assertByIDFacadeMatches(
        _ library: MusicLibrary, ids: Set<String>, disabledSourceIDs: Set<String>, _ step: String, settled: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Bool {
        let host = try XCTUnwrap(library.catalogHost, file: file, line: line)
        XCTAssertNotNil(host.songLookup(), "\(step): the catalog cannot answer", file: file, line: line)
        var visibleSetBehind = false
        for id in ids.sorted() {
            let memory = byIDAnswers(library, id, fromCatalog: false)
            let catalog = byIDAnswers(library, id, fromCatalog: true)
            assertSameSong(catalog.stored, memory.stored, "\(step): storedSong \(id)", file: file, line: line)
            assertSameSong(catalog.song, memory.stored, "\(step): song(id:) is the stored row \(id)", file: file, line: line)
            let expectedVisible = memory.stored.flatMap { disabledSourceIDs.contains($0.sourceID) ? nil : $0 }
            assertSameSong(catalog.visible, expectedVisible, "\(step): visibleSong \(id)", file: file, line: line)
            assertSameSong(catalog.unobserved, expectedVisible, "\(step): unobservedVisibleSong \(id)", file: file, line: line)
            XCTAssertEqual(catalog.contains, expectedVisible != nil, "\(step): containsVisibleSong \(id)", file: file, line: line)
            let memoryIsCurrent = ScanExistingSongsCatalogShadow.sameAtStorePrecision(memory.visible, expectedVisible)
                && ScanExistingSongsCatalogShadow.sameAtStorePrecision(memory.song, memory.stored)
            if memoryIsCurrent {
                assertSameSong(catalog.song, memory.song, "\(step): song(id:) \(id)", file: file, line: line)
                assertSameSong(catalog.visible, memory.visible, "\(step): visibleSong vs memory \(id)", file: file, line: line)
                assertSameSong(catalog.unobserved, memory.unobserved, "\(step): unobservedVisibleSong vs memory \(id)", file: file, line: line)
                XCTAssertEqual(catalog.contains, memory.contains, "\(step): containsVisibleSong vs memory \(id)", file: file, line: line)
                assertSameSong(catalog.synchronization, memory.synchronization, "\(step): songForSynchronization \(id)", file: file, line: line)
            } else {
                visibleSetBehind = true
                XCTAssertFalse(settled, "\(step): the in-memory visible set still disagrees with the stored row of \(id)", file: file, line: line)
            }
        }
        return visibleSetBehind
    }

    /// 那几种有界的范围查询与按 id 取专辑、艺人:目录这条路与内存各答一遍(目录跟上、内存落定之后)。
    private func assertRangeQueriesMatch(
        _ library: MusicLibrary, playlistIDs: [String], _ step: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func both<T>(_ read: () -> T) -> (memory: T, catalog: T) {
            let memory = read()
            library.byIDReadsUseCatalogForTesting = true
            defer { library.byIDReadsUseCatalogForTesting = false }
            return (memory, read())
        }
        var comparedSongs = 0
        for album in library.albums {
            let found = both { library.visibleAlbum(id: album.id) }
            XCTAssertEqual(
                found.catalog.map(LibraryCatalogShadowVerifier.normalized), found.memory.map(LibraryCatalogShadowVerifier.normalized),
                "\(step): visibleAlbum \(album.title)", file: file, line: line
            )
            let songs = both { library.songs(forAlbum: album.id) }
            assertSameSongs(songs.catalog, songs.memory, "\(step): songs(forAlbum: \(album.title))", file: file, line: line)
            comparedSongs += songs.memory.count
        }
        var artists = library.artists + library.visibleAlbumArtists
        artists.append(Artist(id: "no-such-artist", name: "Nobody", albumCount: 0, songCount: 0, thumbnailPath: nil))
        for artist in artists {
            let found = both { library.visibleArtist(id: artist.id) }
            XCTAssertEqual(found.catalog, found.memory, "\(step): visibleArtist \(artist.name)", file: file, line: line)
            let songs = both { library.songs(forArtist: artist.id) }
            assertSameSongs(songs.catalog, songs.memory, "\(step): songs(forArtist: \(artist.name))", file: file, line: line)
            comparedSongs += songs.memory.count
        }
        for genre in library.visibleGenres {
            let songs = both { library.songs(forGenre: genre.id) }
            assertSameSongs(songs.catalog, songs.memory, "\(step): songs(forGenre: \(genre.name))", file: file, line: line)
            comparedSongs += songs.memory.count
        }
        for playlistID in playlistIDs {
            let visible = both { library.songs(forPlaylist: playlistID) }
            assertSameSongs(visible.catalog, visible.memory, "\(step): songs(forPlaylist: \(playlistID))", file: file, line: line)
            let stored = both { library.storedSongs(forPlaylist: playlistID) }
            assertSameSongs(stored.catalog, stored.memory, "\(step): storedSongs(forPlaylist: \(playlistID))", file: file, line: line)
            comparedSongs += visible.memory.count + stored.memory.count
        }
        XCTAssertNil(both { library.visibleAlbum(id: "no-such-album") }.catalog, file: file, line: line)
        XCTAssertGreaterThan(comparedSongs, 0, "\(step): nothing was compared", file: file, line: line)
    }

    /// 步骤 1:模型不在内存里时按 id 读改由「待写登记 → 行缓存 → 目录」来答。这里模型还在,用测试开关让
    /// 每个入口两条路各答一遍:每一种突变做完之后,目录跟上之前隔一会儿比一次,跟上之后再比一次(连同
    /// 范围查询与按 id 取专辑、艺人)。有一个停用的源,有本机移除又恢复的歌。
    func testByIDFacadeOnTheCatalogMatchesTheInMemoryLibraryThroughEveryMutation() async throws {
        var disabled: Set<String> = [Self.sourceB]
        let library = makeLibrary(disabledSourceIDs: disabled)
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        var ids = Set(songs.map(\.id))
        ids.insert("never-in-the-library")
        let everything = library.createPlaylist(name: "Everything", songIDs: songs.map(\.id) + ["never-in-the-library"])
        library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
        library.setLiked(songID: songs[13].id, isLiked: true, propagatesServerMutation: false)
        let playlistIDs = [everything.id, MusicLibrary.likedSongsPlaylistID]
        var stepsWithPendingWrites = 0
        var stepsWhereTheVisibleSetWasBehind: [String] = []

        func assertMatchesUntilCaughtUp(
            _ step: String, file: StaticString = #filePath, line: UInt = #line, changed: () -> Bool = { true }
        ) async throws {
            for _ in 0..<1_000 where !changed() { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(changed(), "\(step): the change never reached the in-memory library", file: file, line: line)
            var sawPending = false
            var behind = false
            for _ in 0..<200 {
                sawPending = sawPending || host.pendingWrites.pendingCount > 0
                behind = try assertByIDFacadeMatches(
                    library, ids: ids, disabledSourceIDs: disabled, step, settled: false, file: file, line: line
                ) || behind
                if host.pendingWrites.pendingCount == 0 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            if sawPending { stepsWithPendingWrites += 1 }
            if behind { stepsWhereTheVisibleSetWasBehind.append(step) }
            await library.waitForCatalogMirror()
            XCTAssertEqual(host.pendingWrites.pendingCount, 0, "\(step): left in the overlay", file: file, line: line)
            try assertByIDFacadeMatches(
                library, ids: ids, disabledSourceIDs: disabled, "\(step) (caught up)", settled: true, file: file, line: line
            )
            assertRangeQueriesMatch(library, playlistIDs: playlistIDs, "\(step) (caught up)", file: file, line: line)
        }

        try await assertMatchesUntilCaughtUp("fixture")

        songs[0].title = "Blue One (Remaster)"
        library.replaceSong(songs[0])
        try await assertMatchesUntilCaughtUp("replaceSong")

        songs[5].albumTitle = "Mixtape Deluxe"
        songs[6].albumTitle = "Mixtape Deluxe"
        songs[7].title = "Blue B1 (edited in a disabled source)"
        library.replaceSongs([songs[5], songs[6], songs[7]])
        try await assertMatchesUntilCaughtUp("replaceSongs")

        library.updateLyricsText([songs[1].id: "la la la", songs[8].id: "hidden la"])
        try await assertMatchesUntilCaughtUp("updateLyricsText")

        library.updateAssetReferences(songID: songs[2].id, coverRef: "blue-alt.jpg")
        library.updateMusicVideoReference(songID: songs[3].id, mvPath: "/Videos/blue.mp4")
        library.flushPendingAssetReferencePatches()
        try await assertMatchesUntilCaughtUp("asset references")

        _ = library.deleteSongs([songs[4]])
        try await assertMatchesUntilCaughtUp("deleteSongs")

        // 本机移除:一首在启用的源里,两首在停用的源里。同步用的入口照样给留着的那一份。
        XCTAssertFalse(try library.removeSongsFromThisDevice([songs[2], songs[7], songs[8]]).isEmpty)
        try await assertMatchesUntilCaughtUp("removeSongsFromThisDevice")
        XCTAssertNil(library.song(id: songs[2].id))
        library.byIDReadsUseCatalogForTesting = true
        XCTAssertNil(library.song(id: songs[2].id))
        XCTAssertEqual(library.songForSynchronization(id: songs[2].id)?.id, songs[2].id)
        XCTAssertEqual(library.songForSynchronization(id: songs[7].id)?.id, songs[7].id)
        library.byIDReadsUseCatalogForTesting = false

        _ = try library.restoreSongsRemovedFromThisDevice([songs[2].id, songs[7].id])
        try await assertMatchesUntilCaughtUp("restoreSongsRemovedFromThisDevice") { library.storedSong(id: songs[2].id) != nil }

        // 只撤销删除记录(歌等下次扫描回来),按 id 读两边都还是没有。
        library.restoreDeletedSong(songs[4])
        try await assertMatchesUntilCaughtUp("restoreDeletedSong")

        let renamed = [songs[0].id: songs[0].id + "-v2", songs[9].id: songs[9].id + "-v2"]
        ids.formUnion(renamed.values)
        library.remapSongIDs(renamed)
        try await assertMatchesUntilCaughtUp("remapSongIDs")

        let fresh = Song(id: "facade-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/fresh.flac", sourceID: Self.sourceA)
        let hidden = Song(id: "facade-hidden", title: "Hidden", albumTitle: "New", artistName: "Ada", duration: 201,
                          fileFormat: .flac, filePath: "/Share/New/hidden.flac", sourceID: Self.sourceB)
        ids.formUnion([fresh.id, hidden.id])
        // 扫描的中间提交(不剪枝):新歌追加在后面,启用的源与停用的源各一首。
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA], pruneMissingSongs: false)
        library.addSongs([hidden], affectedSourceIDs: [Self.sourceB], pruneMissingSongs: false)
        try await assertMatchesUntilCaughtUp("addSongs") { library.storedSong(id: hidden.id) != nil }

        // 扫描的最终提交(剪枝):这个源里这一轮没交上来的歌从库里去掉。
        let sourceARows = library.songs.filter { $0.sourceID == Self.sourceA }
        XCTAssertGreaterThan(sourceARows.count, 8)
        let pruned = sourceARows.suffix(3).map(\.id)
        library.addSongs(Array(sourceARows.dropLast(3)), affectedSourceIDs: [Self.sourceA])
        try await assertMatchesUntilCaughtUp("addSongs (pruning)") { library.storedSong(id: pruned[0]) == nil }
        XCTAssertNotNil(library.storedSong(id: sourceARows[0].id))

        // 换一换停用的源:可见的口径跟着设置走。
        disabled = [Self.sourceA]
        library.updateDisabledSourceIDs(disabled)
        try await assertMatchesUntilCaughtUp("updateDisabledSourceIDs (A hidden)")
        disabled = []
        library.updateDisabledSourceIDs(disabled)
        try await assertMatchesUntilCaughtUp("updateDisabledSourceIDs (none hidden)")

        await library.removeSongsForSource(Self.sourceB)
        try await assertMatchesUntilCaughtUp("removeSongsForSource")
        XCTAssertNil(library.storedSong(id: songs[8].id))

        // 跟写的那一段要真的走过待写登记(目录在主线程改完之后才写)。
        XCTAssertGreaterThan(stepsWithPendingWrites, 5)
        print("ℹ️ by-id facade: steps where the in-memory visible set was behind its stored rows: \(stepsWhereTheVisibleSetWasBehind)")
        await assertShadowMatches(library, "after every step")

        // 不再跟写之后目录这条路不答,强制开关下也照旧读内存。
        await library.stopCatalogMirror()
        let survivor = try XCTUnwrap(library.songs.first?.id)
        library.byIDReadsUseCatalogForTesting = true
        XCTAssertNil(host.songLookup())
        XCTAssertEqual(library.storedSong(id: survivor)?.id, survivor)
        XCTAssertEqual(library.visibleSong(id: survivor)?.id, survivor)
        library.byIDReadsUseCatalogForTesting = false
    }

    /// 步骤 1 要的那个状态本身:歌曲模型不在内存里(回到 `.preparing`、数组与索引清空)、目录可读。
    /// 不用测试开关,按 id 读、范围查询、按 id 取专辑与艺人都由目录来答,与放掉之前内存的答案相同;
    /// 目录不再跟写之后,回到今天 `.preparing` 的答法(查不到)。
    func testByIDFacadeAnswersFromTheCatalogOnceTheSongModelIsNotLoaded() async throws {
        let disabled: Set<String> = [Self.sourceB]
        let library = makeLibrary(disabledSourceIDs: disabled)
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        let everything = library.createPlaylist(name: "Everything", songIDs: songs.map(\.id))
        XCTAssertFalse(try library.removeSongsFromThisDevice([songs[3], songs[8]]).isEmpty)
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        var ids = Set(songs.map(\.id))
        ids.insert("never-in-the-library")

        // 放掉之前内存的答案。
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, byIDAnswers(library, $0, fromCatalog: false)) })
        let albums = library.albums
        let artists = library.artists
        let genres = library.visibleGenres
        let albumsBefore = albums.map { library.visibleAlbum(id: $0.id) }
        let albumSongsBefore = albums.map { library.songs(forAlbum: $0.id) }
        let artistsBefore = artists.map { library.visibleArtist(id: $0.id) }
        let trackArtists = library.artists
        let artistSongsBefore = trackArtists.map { library.songs(forArtist: $0.id) }
        let genreSongsBefore = genres.map { library.songs(forGenre: $0.id) }
        let playlistBefore = library.songs(forPlaylist: everything.id)
        let storedPlaylistBefore = library.storedSongs(forPlaylist: everything.id)
        XCTAssertFalse(playlistBefore.isEmpty)
        XCTAssertGreaterThan(storedPlaylistBefore.count, playlistBefore.count, "the disabled source's members are stored but not visible")

        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertNotNil(host.songLookup())

        for id in ids.sorted() {
            let expected = try XCTUnwrap(before[id])
            let now = byIDAnswers(library, id, fromCatalog: false)
            assertSameSong(now.stored, expected.stored, "storedSong \(id)")
            assertSameSong(now.song, expected.song, "song(id:) \(id)")
            assertSameSong(now.visible, expected.visible, "visibleSong \(id)")
            assertSameSong(now.unobserved, expected.unobserved, "unobservedVisibleSong \(id)")
            XCTAssertEqual(now.contains, expected.contains, "containsVisibleSong \(id)")
            assertSameSong(now.synchronization, expected.synchronization, "songForSynchronization \(id)")
        }
        XCTAssertNotNil(library.storedSong(id: songs[7].id), "a row of the disabled source is stored")
        XCTAssertNil(library.visibleSong(id: songs[7].id), "and not visible")
        XCTAssertNil(library.song(id: songs[3].id), "a row removed from this device is not in the library")
        XCTAssertEqual(library.songForSynchronization(id: songs[3].id)?.id, songs[3].id, "but synchronization still sees it")
        for (offset, album) in albums.enumerated() {
            XCTAssertEqual(
                library.visibleAlbum(id: album.id).map(LibraryCatalogShadowVerifier.normalized),
                albumsBefore[offset].map(LibraryCatalogShadowVerifier.normalized), "visibleAlbum \(album.title)"
            )
            assertSameSongs(library.songs(forAlbum: album.id), albumSongsBefore[offset], "songs(forAlbum: \(album.title))")
        }
        for (offset, artist) in artists.enumerated() {
            XCTAssertEqual(library.visibleArtist(id: artist.id), artistsBefore[offset], "visibleArtist \(artist.name)")
        }
        for (offset, artist) in trackArtists.enumerated() {
            assertSameSongs(library.songs(forArtist: artist.id), artistSongsBefore[offset], "songs(forArtist: \(artist.name))")
        }
        for (offset, genre) in genres.enumerated() {
            assertSameSongs(library.songs(forGenre: genre.id), genreSongsBefore[offset], "songs(forGenre: \(genre.name))")
        }
        assertSameSongs(library.songs(forPlaylist: everything.id), playlistBefore, "songs(forPlaylist:)")
        assertSameSongs(library.storedSongs(forPlaylist: everything.id), storedPlaylistBefore, "storedSongs(forPlaylist:)")

        // 本机移除的那一行又出现在目录里(别的设备的快照带回来、这台设备还没重新装载时就是这样):
        // 模型装载时会按本机的移除账本把它筛掉,目录这条路也一样不给;同步用的入口照旧给留着的那一份。
        try XCTUnwrap(host.mirror.readableCatalog).live.apply(upserts: [songs[3]])
        host.reader.rowCache.removeAll()
        XCTAssertNotNil(try XCTUnwrap(host.mirror.readableCatalog).song(id: songs[3].id), "the row is in the catalog")
        XCTAssertNil(library.storedSong(id: songs[3].id))
        XCTAssertNil(library.song(id: songs[3].id))
        XCTAssertFalse(library.containsVisibleSong(id: songs[3].id))
        XCTAssertFalse(library.storedSongs(forPlaylist: everything.id).contains { $0.id == songs[3].id })
        XCTAssertEqual(library.songForSynchronization(id: songs[3].id)?.id, songs[3].id)

        // 这个状态下突变照旧排队,不写:待写登记里什么都没有,目录里的行没动。排队的整行替换按字段记着,
        // 这期间按 id 再读,读得到(调用方读回自己刚交的改动)。
        var edited = songs[0]
        edited.title = "queued while not loaded"
        library.replaceSong(edited)
        XCTAssertEqual(host.pendingWrites.pendingCount, 0)
        XCTAssertEqual(try XCTUnwrap(host.mirror.readableCatalog).song(id: songs[0].id)?.title, songs[0].title)
        XCTAssertEqual(library.storedSong(id: songs[0].id)?.title, "queued while not loaded")

        // 目录不再跟写:回到今天 `.preparing` 的答法。
        await library.stopCatalogMirror()
        XCTAssertNil(library.storedSong(id: songs[0].id))
        XCTAssertNil(library.song(id: songs[0].id))
        XCTAssertNil(library.visibleSong(id: songs[0].id))
        XCTAssertFalse(library.containsVisibleSong(id: songs[0].id))
        XCTAssertNil(library.visibleAlbum(id: albums[0].id))
        XCTAssertTrue(library.songs(forAlbum: albums[0].id).isEmpty)
        XCTAssertTrue(library.storedSongs(forPlaylist: everything.id).isEmpty)
    }

    /// DEBUG 里真实使用时的抽样比对:内存答的按 id 读抽出来的 id,目录这条路再答一遍,各种突变之后都相同;
    /// 目录里的行被改得与内存不一样时(这里绕过内存直接写目录)它要报出来。
    func testByIDParitySamplingComparesTheCatalogPathOnRealUse() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        var songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        library.byIDParitySampling.interval = 1

        func readEverything() {
            for song in songs {
                _ = library.song(id: song.id)
                _ = library.storedSong(id: song.id)
            }
            _ = library.song(id: "never-in-the-library")
        }
        readEverything()
        songs[0].title = "Sampled edit"
        library.replaceSong(songs[0])
        readEverything()
        _ = library.deleteSongs([songs[4]])
        readEverything()
        let fresh = Song(id: "sampled-fresh", title: "Fresh", albumTitle: "New", artistName: "Ada", duration: 200,
                         fileFormat: .flac, filePath: "/Music/New/fresh.flac", sourceID: Self.sourceA)
        library.addSongs([fresh], affectedSourceIDs: [Self.sourceA], pruneMissingSongs: false)
        songs.append(fresh)
        readEverything()
        await library.drainByIDParityChecksForTesting()
        await library.waitForCatalogMirror()
        readEverything()
        await library.drainByIDParityChecksForTesting()
        let clean = library.byIDParitySampling
        XCTAssertGreaterThan(clean.matched, 20)
        XCTAssertEqual(clean.mismatches, 0, clean.lastMismatch ?? "")

        // 目录里这一行与内存不同:抽到它时要报(只抽下面那一次读)。
        library.byIDParitySampling.interval = .max
        var corrupted = try XCTUnwrap(library.storedSong(id: songs[1].id))
        corrupted.title = "only in the catalog"
        try XCTUnwrap(host.mirror.readableCatalog).live.apply(upserts: [corrupted])
        host.reader.rowCache.removeAll()
        library.byIDParitySampling.interval = 1
        _ = library.song(id: songs[1].id)
        library.byIDParitySampling.interval = .max
        await library.drainByIDParityChecksForTesting()
        XCTAssertEqual(library.byIDParitySampling.mismatches, 1)
        XCTAssertEqual(library.byIDParitySampling.lastMismatch?.contains("title"), true, library.byIDParitySampling.lastMismatch ?? "")
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

    // MARK: - Usable without the song model (P3 step 6c)

    /// 模型在内存里时「可用」与「已就绪」同真;等可用(`whenUsable`、`onUsable`)不要歌曲模型,占用
    /// (`holdSongModel`、`withSongModel`)才要。模型放掉之后目录答得出就还是可用(「已就绪」为假,观察着的界面
    /// 收到变化);目录也答不了才不可用,等可用的只是等。
    func testUsableDoesNotNeedTheSongModelAndOnlyAHoldAsksForIt() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        XCTAssertTrue(library.isReady)
        XCTAssertTrue(library.isUsable)
        await library.whenUsable()
        let usableInTime = await library.whenUsable(timeout: .milliseconds(50))
        XCTAssertTrue(usableInTime)
        let handled = Tally()
        library.onUsable { handled.count += 1 }
        XCTAssertEqual(handled.count, 1, "already usable: the handler runs at once")
        XCTAssertEqual(songModelHolds(of: library), [], "waiting for usable asks for no song model")

        let hold = await library.holdSongModel(.scan)
        XCTAssertEqual(hold.reason, .scan)
        XCTAssertTrue(library.isReady, "the model is in memory while it is held")
        hold.end()
        hold.end()
        let expectedCount = library.songs.count
        let counted = await library.withSongModel(.export) { library.songs.count }
        XCTAssertEqual(counted, expectedCount)
        XCTAssertEqual(songModelHolds(of: library), [.scan, .export])

        // 放掉歌曲模型:「已就绪」为假,观察着的界面收到变化;目录答得出,所以还是可用。
        let changed = expectation(description: "observers of isUsable are told")
        withObservationTracking { _ = library.isUsable } onChange: { changed.fulfill() }
        library.dropSongModelForMeasurement(includingCollections: true)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.isUsable, "released, and the catalog answers")
        let usableAfterRelease = await library.whenUsable(timeout: .milliseconds(50))
        XCTAssertTrue(usableAfterRelease)
        library.onUsable { handled.count += 1 }
        XCTAssertEqual(handled.count, 2, "usable without the model: the handler runs at once")
        // 目录也答不了:不可用,等可用的只是等。
        await library.stopCatalogMirror()
        XCTAssertFalse(library.isUsable, "released, and nothing can answer")
        let usableWithoutTheCatalog = await library.whenUsable(timeout: .milliseconds(50))
        XCTAssertFalse(usableWithoutTheCatalog)
        library.onUsable { handled.count += 1 }
        XCTAssertEqual(handled.count, 2, "not usable: the handler waits")
        XCTAssertEqual(songModelHolds(of: library), [.scan, .export], "waiting for usable still asks for no song model")
    }

    /// 歌词全文补索引挑候选:目录这条路与整库数组上的写法挑出同样的歌(有歌词文件引用、还没有全文;停用源的
    /// 歌也算,本机移除的不算)。歌曲模型放掉之后目录这时挑出的候选与放掉之前相同;库不可用(模型放掉了、目录也
    /// 答不了)时启动它:只登记等可用,不起 worker、不要歌曲模型、不写「已完成」标记。
    func testLyricsTextBackfillPicksItsCandidatesFromTheCatalogAndWaitsWhileTheSongModelIsReleased() async throws {
        // 与 `LyricsTextBackfillService.migrationKey` 保持一致(私有常量);服务直接读写 `UserDefaults.standard`。
        let migrationKey = "primuse.lyricsTextBackfill.v1_initial"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: migrationKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: migrationKey)
            } else {
                defaults.removeObject(forKey: migrationKey)
            }
        }
        defaults.removeObject(forKey: migrationKey)

        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        var songs = Self.fixture()
        // 0、2 在启用的源里,7、14 在停用的源里,12 之后在本机移除;2 已经有全文,5 的引用是空串。
        for index in [0, 2, 5, 7, 12, 14] { songs[index].lyricsFileName = "\(songs[index].id).lrc" }
        songs[2].lyricsText = "already indexed"
        songs[5].lyricsFileName = ""
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        XCTAssertFalse(try library.removeSongsFromThisDevice([songs[12]]).isEmpty)
        await assertShadowMatches(library, "fixture")

        let service = LyricsTextBackfillService(library: library)
        let fromCatalog = await service.catalogCandidateIDsForTesting()
        let fromMemory = library.songs.compactMap { song -> String? in
            guard song.lyricsText == nil, song.lyricsFileName?.isEmpty == false else { return nil }
            return song.id
        }
        XCTAssertEqual(try XCTUnwrap(fromCatalog).sorted(), fromMemory.sorted())
        XCTAssertEqual(Set(fromMemory), [songs[0].id, songs[7].id, songs[14].id])

        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        library.dropSongModelForMeasurement(includingCollections: true)
        let whileReleased = await service.catalogCandidateIDsForTesting()
        XCTAssertEqual(try XCTUnwrap(whileReleased).sorted(), fromMemory.sorted(), "the catalog answers the same without the model")
        await library.stopCatalogMirror()
        XCTAssertFalse(library.isUsable, "released, and nothing can answer")
        service.startIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isRunning, "no worker on a library that is not usable")
        XCTAssertFalse(defaults.bool(forKey: migrationKey), "the migration is not marked as done")
        XCTAssertEqual(songModelHolds(of: library), [], "it does not ask for the song model")
    }

    // MARK: - Song model residency (P3 step 6d)

    private func artworkCatalog(sourceID: String) throws -> SourceArtistArtworkCatalog {
        let json = """
            {"sourceID":"\(sourceID)","directoryParents":{},"songParentDirectories":{},
             "candidatesByDirectory":{"/Music":[{"normalizedArtistName":"ada","reference":"/Music/ada.jpg","cacheDiscriminator":"1"}]}}
            """
        return try JSONDecoder().decode(SourceArtistArtworkCatalog.self, from: Data(json.utf8))
    }

    private final class ResidencyEventLog {
        var events: [MusicLibrary.SongModelResidencyEvent] = []
    }

    /// 小状态整份落一次盘,返回那份便携快照的字节(放掉前后、装回来之后逐字节比)。
    private func portableSnapshotBytes(_ library: MusicLibrary, storage: URL, _ step: String) async throws -> Data {
        library.markPortableSnapshotDirtyForTesting()
        guard case .success = await library.persistNowAndWait(materializePortableSnapshot: true) else {
            XCTFail("\(step): the snapshot was not written")
            return Data()
        }
        return try Data(contentsOf: storage.appendingPathComponent("library-cache.json"))
    }

    /// 放掉歌曲模型:数组空了,库照样可用(按 id 读、歌单的可见曲数、小状态都答得出),小状态与自动艺人图的目录原样在;
    /// 等可用、登记就绪回调都不引起装载。拿占用装回来:歌曲、可见集、专辑、艺人与放掉之前逐项相同,目录与内存
    /// 对得上;占着就不放。排了队的突变自己把模型装回来,就绪回调排在重放之后。
    func testReleasingTheSongModelAndLoadingItAgainGivesTheSameLibrary() async throws {
        let songs = Self.fixture(prefix: "residency")
        let (library, storage) = try makeLaunchedTwin("residency", songs: songs)
        let playlist = library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[4].id, songs[7].id])
        library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
        library.setDisliked(songID: songs[3].id, isDisliked: true)
        library.recordPlayback(of: songs[2].id)
        library.updateLibraryReview(for: .song(songs[5].id), rating: 4, comment: "kept")
        library.updateAutomaticArtistArtworkCatalog(try artworkCatalog(sourceID: Self.sourceA))
        await assertShadowMatches(library, "fixture")
        // 小状态整份(歌单、喜欢/不喜欢、最近播放、评价、墓碑、自动艺人图……)落盘的字节:放掉之后、装回来之后都相同。
        let smallStateBefore = try await portableSnapshotBytes(library, storage: storage, "loaded")

        let before = modelPicture(library)
        let rowsBefore = library.songs
        let catalogs = library.automaticArtistArtworkCatalogsForTesting
        XCTAssertEqual(catalogs.count, 1)
        let playlistsBefore = library.playlists.map(\.id)
        let hadSpokenWord = library.hasSpokenWordContent
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 2, "the member in the disabled source is not counted")

        // 总开关关着:不放。
        let refused = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(refused, .skipped("residency is off"))
        library.songModelResidencyEnabled = true
        let log = ResidencyEventLog()
        library.songModelResidencyObserver = { log.events.append($0) }

        let outcome = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        guard case .released(let releasedSongs, _) = outcome else { return XCTFail("not released: \(outcome)") }
        XCTAssertEqual(releasedSongs, songs.count)
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.isUsable)
        XCTAssertTrue(library.canAnswerSongLookups)
        library.songModelArrayReadPolicy = .ignore
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.visibleSongs.isEmpty)
        XCTAssertTrue(library.albums.isEmpty)
        XCTAssertTrue(library.visibleAlbums.isEmpty)
        XCTAssertTrue(library.visibleArtists.isEmpty)
        library.songModelArrayReadPolicy = .log
        // 按 id 读、歌单、小状态:与放掉之前相同。
        XCTAssertEqual(library.storedSong(id: songs[0].id)?.title, songs[0].title)
        XCTAssertNil(library.visibleSong(id: songs[7].id), "a song in a disabled source is not visible")
        XCTAssertNotNil(library.storedSong(id: songs[7].id))
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 2, "counted from the catalog")
        XCTAssertEqual(library.songSummary(forPlaylist: playlist.id).first?.id, songs[0].id)
        XCTAssertEqual(
            library.storedSongsIfAnswerable(forPlaylist: playlist.id)?.map(\.id), [songs[0].id, songs[4].id, songs[7].id]
        )
        XCTAssertEqual(library.playlists.map(\.id), playlistsBefore)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), [songs[0].id, songs[4].id, songs[7].id])
        XCTAssertTrue(library.isLiked(songID: songs[1].id))
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [songs[2].id])
        XCTAssertEqual(library.automaticArtistArtworkCatalogsForTesting, catalogs)
        XCTAssertEqual(library.hasSpokenWordContent, hadSpokenWord, "the entry flags stay as they were")
        let smallStateReleased = try await portableSnapshotBytes(library, storage: storage, "released")
        XCTAssertEqual(smallStateReleased, smallStateBefore, "small state is the same, byte for byte, with the model released")

        // 等可用、登记就绪回调:都不引起装载。
        await library.whenUsable()
        let usableInTime = await library.whenUsable(timeout: .milliseconds(50))
        XCTAssertTrue(usableInTime)
        let handled = Tally()
        library.onReady { handled.count += 1 }
        library.onUsable { handled.count += 10 }
        XCTAssertEqual(handled.count, 10, "usable: that handler runs at once; the ready handler waits for a load")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(library.isLoadingSongModelForTesting, "nothing asked for the model: \(library.songModelResidencyStatistics)")
        XCTAssertFalse(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)

        // 拿占用:装回来,与放掉之前逐项相同。
        let waiter = Task { @MainActor in await library.whenReady() }
        let hold = await library.holdSongModel(.legacyPage)
        await waiter.value
        XCTAssertTrue(library.isReady)
        XCTAssertTrue(library.isUsable)
        XCTAssertEqual(handled.count, 11, "the ready handler ran at the load")
        XCTAssertEqual(modelPicture(library), before)
        assertSameSongs(library.songs, rowsBefore, "rows after the load")
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 2)
        XCTAssertEqual(library.playlists.map(\.id), playlistsBefore)
        XCTAssertEqual(library.automaticArtistArtworkCatalogsForTesting, catalogs)
        let smallStateLoaded = try await portableSnapshotBytes(library, storage: storage, "loaded again")
        XCTAssertEqual(smallStateLoaded, smallStateBefore, "the load does not copy small state back from the disk")
        let statistics = library.songModelResidencyStatistics
        XCTAssertEqual(statistics.releases, 1)
        XCTAssertEqual(statistics.loads, 1)
        XCTAssertEqual(statistics.lastLoadJournalRows, 0)
        XCTAssertEqual(statistics.wholeLibraryLoads, 0)
        XCTAssertEqual(statistics.loadRestarts, 0)
        print("REPORT_RESIDENCY_LOAD reason=\(statistics.lastLoadReason ?? "-") ms=\(statistics.lastLoadMilliseconds) derivedCache=\(statistics.lastLoadUsedDerivedCache) arrayReads=\(statistics.arrayReadsWhileUnloaded)")
        XCTAssertEqual(log.events, [.released, .loaded])
        await assertShadowMatches(library, "after the load")

        // 占着就不放;放手之后才放。
        let whileHeld = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(whileHeld, .skipped("hold(legacyPage)"))
        hold.end()
        hold.end()
        XCTAssertEqual(log.events.last, .holdsEnded)
        guard await released(library, "second release") else { return }

        // 排了队的突变自己把模型装回来;就绪回调排在重放之后,看得到重放的结果。
        let seenAtReady = Tally()
        library.onReady { seenAtReady.count = library.songs.count }
        let added = Song(
            id: "residency-added", title: "Blue 5", albumTitle: "Blue Room", artistName: "Ada", albumArtistName: "Ada",
            trackNumber: 5, discNumber: 1, duration: 200, fileFormat: .flac,
            filePath: "/Music/Ada/Blue Room/5.flac", sourceID: Self.sourceA, genre: "Pop", year: 2001
        )
        library.addSongs([added], affectedSourceIDs: [Self.sourceA], notifyRemovals: false, pruneMissingSongs: false)
        XCTAssertEqual(library.deferredMutationCountForTesting, 1, "it waits for the model")
        XCTAssertTrue(library.isLoadingSongModelForTesting, "and asks for it")
        try await waitUntilReady(library)
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songs.count, songs.count + 1)
        XCTAssertEqual(seenAtReady.count, songs.count + 1, "handlers run after the queue was replayed")
        XCTAssertNotNil(library.storedSong(id: added.id))
        XCTAssertTrue(library.songModelResidencyStatistics.lastLoadReason?.hasPrefix("queued") == true)
        await assertShadowMatches(library, "after the queued add")
    }

    /// 每一种占用理由(连同 `withSongModel`):放掉之后拿它,模型装回来;占着的时候不放;放手之后又能放。
    func testEveryHolderKindLoadsTheSongModelAndBlocksTheRelease() async throws {
        let songs = Self.fixture(prefix: "holders")
        let library = try makeLaunchedTwin("holders", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        for reason in MusicLibrary.SongModelHoldReason.allCases {
            guard await released(library, "before \(reason.rawValue)") else { return }
            XCTAssertFalse(library.isReady, reason.rawValue)
            let hold = await library.holdSongModel(reason)
            XCTAssertTrue(library.isReady, reason.rawValue)
            XCTAssertEqual(library.songs.count, songs.count, reason.rawValue)
            XCTAssertEqual(library.songModelHoldReasons, [reason])
            XCTAssertEqual(library.songModelResidencyStatistics.lastLoadReason, "hold \(reason.rawValue)")
            let whileHeld = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
            XCTAssertEqual(whileHeld, .skipped("hold(\(reason.rawValue))"))
            hold.end()
            XCTAssertEqual(library.songModelHoldReasons, [])
        }
        guard await released(library, "before withSongModel") else { return }
        let counted = await library.withSongModel(.export) { () -> Int in
            XCTAssertEqual(library.songModelHoldReasons, [.export])
            let whileHeld = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
            XCTAssertEqual(whileHeld, .skipped("hold(export)"))
            return library.songs.count
        }
        XCTAssertEqual(counted, songs.count)
        XCTAssertEqual(library.songModelHoldReasons, [])
        let statistics = library.songModelResidencyStatistics
        XCTAssertEqual(statistics.loads, MusicLibrary.SongModelHoldReason.allCases.count + 1)
        XCTAssertEqual(statistics.wholeLibraryLoads, 0, "every load read the song model alone")
        await assertShadowMatches(library, "after every holder kind")
        guard await released(library, "after withSongModel") else { return }
    }

    private final class ReleaseRequests {
        var tasks: [Task<MusicLibrary.SongModelReleaseOutcome, Never>] = []
    }

    /// 在后台放歌时放掉的模型(放掉时不整理大堆),队列放到头要接着放而拿的占用把它装回来;占用一结束,
    /// 曲库发出「占用都结束了」,App 那一层照它再放一次(这里由测试代为接上),又放得掉。
    func testAHoldTakenDuringBackgroundPlaybackLoadsAndTheReleaseRunsAgainAfterIt() async throws {
        let songs = Self.fixture(prefix: "playing")
        let library = try makeLaunchedTwin("playing", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        let musicBefore = library.musicSongs.map(\.id)
        let log = ResidencyEventLog()
        let requests = ReleaseRequests()
        library.songModelResidencyObserver = { [weak library] event in
            log.events.append(event)
            guard event == .holdsEnded, let library else { return }
            requests.tasks.append(Task { @MainActor in
                await self.releaseOnceShadowVerificationIsDone(library, trigger: "holds ended", returningFreedMemory: false)
            })
        }
        let first = await releaseOnceShadowVerificationIsDone(library, trigger: "background playback", returningFreedMemory: false)
        guard case .released = first else { return XCTFail("not released: \(first)") }
        await library.songModelReleaseDidReclaimMemory()

        let hold = await library.holdSongModel(.playbackContinuation)
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.musicSongs.map(\.id), musicBefore)
        XCTAssertEqual(library.songModelResidencyStatistics.lastLoadReason, "hold playbackContinuation")
        XCTAssertTrue(requests.tasks.isEmpty, "nothing asks for a release while the hold lasts")
        hold.end()
        XCTAssertEqual(requests.tasks.count, 1)
        let again = await requests.tasks.first?.value
        guard case .released(let releasedSongs, _)? = again else { return XCTFail("not released again: \(String(describing: again))") }
        XCTAssertEqual(releasedSongs, songs.count)
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.isUsable)
        XCTAssertEqual(log.events, [.released, .loaded, .holdsEnded, .released])
        XCTAssertEqual(library.songModelResidencyStatistics.releases, 2)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 1)
        library.songModelResidencyObserver = nil
    }

    /// 模型在内存里时拿占用(`holdSongModel`、`withSongModel`)当场返回,中间不让出主线程:先排进主线程的活
    /// 在拿到占用之后才轮得到。
    func testHoldingTheSongModelWhileItIsLoadedDoesNotSuspend() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        XCTAssertTrue(library.isReady)
        let probe = Tally()
        Task { @MainActor in probe.count += 1 }
        let hold = await library.holdSongModel(.playbackContinuation)
        XCTAssertEqual(probe.count, 0, "no other main-actor work ran while the hold was taken")
        let seenInside = await library.withSongModel(.playbackContinuation) { probe.count }
        XCTAssertEqual(seenInside, 0, "nor before the body of withSongModel")
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(library.songModelHoldReasons, [.playbackContinuation])
        hold.end()
        XCTAssertEqual(library.songModelHoldReasons, [])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(probe.count, 1, "the probe itself runs once the test yields")
    }

    /// 等模型装回来的占用,调用方的任务被取消就当场返回:占用撤掉,令牌的 `end()` 什么都不做。
    /// 已经取消的任务来要占用,不替它请求装载。
    func testACancelledHolderReturnsAtOnceAndAsksForNoLoad() async throws {
        let songs = Self.fixture(prefix: "cancelled")
        let library = try makeLaunchedTwin("cancelled", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        guard await released(library, "release") else { return }

        // 已经取消的任务来要:当场返回,不请求装载。
        let alreadyCancelled = Task { @MainActor () -> MusicLibrary.SongModelHold in
            try? await Task.sleep(for: .seconds(30))
            return await library.holdSongModel(.playbackContinuation)
        }
        alreadyCancelled.cancel()
        let first = await alreadyCancelled.value
        XCTAssertEqual(library.songModelHoldReasons, [], "the hold is not kept")
        first.end()
        first.end()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(library.isLoadingSongModelForTesting, "no load for a task that was already cancelled")
        XCTAssertFalse(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)

        // 取消落在等的途中(测量钩子放掉的库不自己装回来,不取消就一直等下去)。
        let parked = try makeTwin("cancelled-parked", songs: songs).library
        await assertShadowMatches(parked, "parked fixture")
        parked.dropSongModelForMeasurement(includingCollections: true)
        let waiting = Task { @MainActor in await parked.holdSongModel(.playbackContinuation) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(parked.songModelHoldReasons, [.playbackContinuation], "registered while it waits")
        waiting.cancel()
        let second = await waiting.value
        XCTAssertEqual(parked.songModelHoldReasons, [], "withdrawn when the waiter is cancelled")
        XCTAssertFalse(parked.isReady)
        second.end()
        XCTAssertEqual(parked.songModelHoldReasons, [])
    }

    // MARK: - Song model residency: the switches and the app-level hooks (P3 step 6d unit b)

    /// 开关从启动参数(参数域里的字符串)或内部设置读;没设时总开关关,两个过渡期开关开。
    func testResidencySettingsComeFromLaunchArgumentsOrDefaults() throws {
        typealias Settings = MusicLibrary.SongModelResidencySettings
        let suite = "residency-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings.current(defaults, environment: [:]), .off)
        XCTAssertEqual(Settings.off, Settings(isEnabled: false, foregroundHold: true, playbackBlocksRelease: true))
        XCTAssertEqual(
            Settings.off.launchLine,
            "🧠 residency launch=load residency=off foregroundHold=on playbackBlocks=on launchUnloaded=off"
        )
        // 启动参数 `-PrimuseSongModelResidency YES` 进参数域时是字符串。
        defaults.set("YES", forKey: Settings.enabledKey)
        defaults.set("NO", forKey: Settings.foregroundHoldKey)
        defaults.set(false, forKey: Settings.playbackBlocksReleaseKey)
        let settings = Settings.current(defaults, environment: [:])
        XCTAssertEqual(settings, Settings(isEnabled: true, foregroundHold: false, playbackBlocksRelease: false))
        XCTAssertEqual(
            settings.launchLine,
            "🧠 residency launch=load residency=on foregroundHold=off playbackBlocks=off launchUnloaded=off"
        )
        // 不装歌曲模型的启动:总开关开着时也默认关;开着时启动那一行先说要试。
        XCTAssertFalse(settings.launchesUnloaded)
        defaults.set("YES", forKey: Settings.launchUnloadedKey)
        let unloaded = Settings.current(defaults, environment: [:])
        XCTAssertTrue(unloaded.launchUnloaded)
        XCTAssertTrue(unloaded.launchesUnloaded)
        XCTAssertEqual(
            unloaded.launchLine,
            "🧠 residency launch=unloaded-requested residency=on foregroundHold=off playbackBlocks=off launchUnloaded=on"
        )
        XCTAssertFalse(Settings.current(defaults, environment: [Settings.enabledEnvironmentKey: "0"]).launchesUnloaded,
                       "without residency the switch does nothing")
        // 开发构建里启动环境变量优先(设备脚本只能传环境变量)。
        let fromEnvironment = Settings.current(defaults, environment: [
            Settings.enabledEnvironmentKey: "0", Settings.foregroundHoldEnvironmentKey: "1",
            Settings.playbackBlocksReleaseEnvironmentKey: "true", Settings.launchUnloadedEnvironmentKey: "0",
        ])
        XCTAssertEqual(fromEnvironment, .off)
    }

    /// 前台的占用跟着场景走:回到前台拿 `.foreground`(放掉了就装回来),退到后台放手之后才放得掉;
    /// 策略开关关着、总开关关着时从来不拿,总开关关着时也从来不放。
    func testTheForegroundHoldFollowsTheScenePhase() async throws {
        let songs = Self.fixture(prefix: "foreground")
        let library = try makeLaunchedTwin("foreground", songs: songs).library
        await assertShadowMatches(library, "fixture")

        // 总开关关着:前台不拿占用,也从来不放。
        library.applySongModelResidencySettings(.off)
        library.setSongModelForegroundHold(true)
        XCTAssertEqual(library.songModelHoldReasons, [])
        let off = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(off, .skipped("residency is off"))

        library.applySongModelResidencySettings(.init(isEnabled: true, foregroundHold: true, playbackBlocksRelease: true))
        XCTAssertTrue(library.songModelResidencyEnabled)
        library.setSongModelForegroundHold(true)
        library.setSongModelForegroundHold(true)
        XCTAssertEqual(library.songModelHoldReasons, [.foreground], "one hold however often the scene becomes active")
        let held = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(held, .skipped("hold(foreground)"))
        // 退到后台:放手,之后放得掉。
        library.setSongModelForegroundHold(false)
        XCTAssertEqual(library.songModelHoldReasons, [])
        guard await released(library, "in the background") else { return }
        // 回到前台:拿占用,模型自己装回来(不等,界面看 isReady)。
        library.setSongModelForegroundHold(true)
        XCTAssertEqual(library.songModelHoldReasons, [.foreground])
        XCTAssertTrue(library.isLoadingSongModelForTesting || library.isReady)
        try await waitUntilReady(library)
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.lastLoadReason, "hold foreground")
        XCTAssertEqual(library.songs.count, songs.count)

        // 关掉总开关:前台占用一并放下。
        library.applySongModelResidencySettings(.off)
        XCTAssertEqual(library.songModelHoldReasons, [])
        // 前台占用这个开关关着:总开关开着也不拿。
        library.applySongModelResidencySettings(.init(isEnabled: true, foregroundHold: false, playbackBlocksRelease: true))
        library.setSongModelForegroundHold(true)
        XCTAssertEqual(library.songModelHoldReasons, [])
        guard await released(library, "no foreground hold") else { return }
    }

    /// 整份装载之前小状态没能落盘:不装(装了会从磁盘拷回旧的小状态),留在放掉的状态,过一会儿再试;
    /// 等着的占用接着等,落盘成了就装,放掉期间的改动都在。
    func testAWholeLibraryLoadWhoseSaveFailsStaysReleasedAndRetries() async throws {
        let songs = Self.fixture(prefix: "deferred")
        // 这一轮进程里才建起来的旧库:第一次装载走整份装载。
        let library = try makeTwin("deferred", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        guard await released(library, "release") else { return }
        library.setLiked(songID: songs[2].id, isLiked: true, propagatesServerMutation: false)
        library.songModelLoadRetryDelay = .milliseconds(200)
        library.songModelFallbackPersistFailsForTesting = true
        let holder = Task { @MainActor in await library.holdSongModel(.migration) }
        for _ in 0..<100 where library.songModelResidencyStatistics.deferredWholeLibraryLoads == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(library.songModelResidencyStatistics.deferredWholeLibraryLoads, 0)
        XCTAssertFalse(library.isReady, "it stays released while the save fails")
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 0)
        XCTAssertTrue(library.isLiked(songID: songs[2].id))
        library.songModelFallbackPersistFailsForTesting = false
        let hold = await holder.value
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 1)
        XCTAssertTrue(library.songModelResidencyStatistics.lastLoadReason?.hasPrefix("retry") == true)
        XCTAssertTrue(library.isLiked(songID: songs[2].id), "the change made while released survived")
        XCTAssertEqual(library.songs.count, songs.count)
        hold.end()
    }

    // MARK: - Release yield: the playlist match-key cache

    /// 匹配键缓存有上限,放掉歌曲模型、放能重建的缓存时整份清掉;清掉之后照样算得出同样的键。
    func testPlaylistMatchKeyCacheIsBoundedAndGoesWithTheRebuildableCaches() async throws {
        let capacity = PlaylistEntryMatchKeyCache.capacity
        let cache = PlaylistEntryMatchKeyCache()
        let many = (0..<(capacity + 25)).map { index in
            Song(id: "key-\(index)", title: "Song \(index)", artistName: "Artist \(index % 7)", duration: 180,
                 fileFormat: .flac, filePath: "/Music/\(index).flac", sourceID: Self.sourceA)
        }
        for song in many { _ = cache.key(for: song) }
        XCTAssertEqual(cache.count, capacity, "the cache does not grow with the library")
        let beyond = try XCTUnwrap(many.last)
        XCTAssertEqual(cache.key(for: beyond), ExternalTrackMatchPolicy.Key(PlaylistEntryMatcher.subject(of: beyond)))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)

        let songs = Self.fixture(prefix: "keys")
        let library = try makeLaunchedTwin("keys", songs: songs).library
        await assertShadowMatches(library, "fixture")
        _ = PlaylistEntryMatcher(songs: library.visibleSongs, keyCache: library.playlistEntryMatchKeyCache)
        XCTAssertGreaterThan(library.playlistEntryMatchKeyCache.count, 0)
        // 退到后台的那一轮放能重建的缓存(开关关着也是这样)。
        library.releaseRebuildableCaches()
        XCTAssertEqual(library.playlistEntryMatchKeyCache.count, 0)
        // 放掉歌曲模型时也清掉。
        _ = PlaylistEntryMatcher(songs: library.visibleSongs, keyCache: library.playlistEntryMatchKeyCache)
        library.songModelResidencyEnabled = true
        guard await released(library, "release") else { return }
        XCTAssertEqual(library.playlistEntryMatchKeyCache.count, 0)
    }

    /// 缓存是缓存:冷的、热的、只给同歌名主体建索引的匹配器,对同一批条目给出相同的「就是它」;
    /// 冷热两个的「可能是」也相同。带上记号的认领(`matchCarriedMarks`)有没有缓存结果一样。
    func testPlaylistMatchesAreTheSameWithAndWithoutTheKeyCache() throws {
        let songs = Self.fixture(prefix: "match")
        var copy = songs[0]
        copy.id = "match-blue-1-copy"
        copy.sourceID = "dual-write-c"
        copy.filePath = "/Other/Blue Room/1.flac"
        let library = songs + [copy]
        var subjects = library.map { PlaylistEntryMatcher.subject(of: $0) }
        subjects += ExternalPlaylistTrack(title: songs[1].title, artists: ["Ada"], album: nil, duration: songs[1].duration).matchSubjects
        subjects += ExternalPlaylistTrack(title: "Nothing Like It", artists: ["Nobody"], album: nil, duration: 1).matchSubjects
        let cache = PlaylistEntryMatchKeyCache()
        let cold = PlaylistEntryMatcher(songs: library)
        let filling = PlaylistEntryMatcher(songs: library, keyCache: cache)
        let warm = PlaylistEntryMatcher(songs: library, keyCache: cache)
        let narrow = PlaylistEntryMatcher(songs: library, keyCache: cache, matching: subjects)
        for subject in subjects {
            let expected = cold.match(subject)
            for matcher in [filling, warm] {
                XCTAssertEqual(matcher.match(subject).confident.map(\.id), expected.confident.map(\.id))
                XCTAssertEqual(matcher.match(subject).probable.map(\.id), expected.probable.map(\.id))
            }
            XCTAssertEqual(narrow.match(subject).confident.map(\.id), expected.confident.map(\.id))
        }
        let marks = [songs[0], songs[2], songs[5]].map { song in
            CarriedSongMarks(
                id: "gone-\(song.id)", title: song.title, artists: PlaylistEntryMatcher.artists(of: song),
                album: song.albumTitle, duration: song.duration, liked: true, origin: .removedSource
            )
        }
        XCTAssertEqual(
            MusicLibrary.matchCarriedMarks(marks, against: library, keyCache: cache),
            MusicLibrary.matchCarriedMarks(marks, against: library, keyCache: nil)
        )
    }

    // MARK: - Launch without the song model (P3 step 6e)

    /// 启动条件都满足:只装小状态,接上目录就能用 —— 旧库的歌一首都不读;歌单、喜欢、最近播放、按 id 读、歌单曲数、
    /// 入口的标记都在。之后不碰它就一直不装模型(后台启动也是这样);只动小状态的突变当场做,要模型的突变和占用
    /// 把它装回来。
    func testAnUnloadedLaunchIsUsableWithoutReadingTheSongModel() async throws {
        let songs = Self.fixture(prefix: "unloaded")
        let (source, storage) = try await launchFixture("unloaded", songs: songs)
        let flagsBefore = [source.hasSpokenWordContent, source.hasAmbientContent, source.hasMusicVideoContent]
        let spokenWordCount = source.spokenWordSongCount
        let playlistID = try XCTUnwrap(source.allPlaylists.first { $0.name == "Kept" }).id
        let countBefore = source.songCount(forPlaylist: playlistID)
        let directory = try copyOfDirectory(storage, "unloaded-launch")

        let readsBefore = MusicLibrary.songModelStoreReads.withLock { $0 }
        let library = await launch(directory, unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        try await waitUntilUsable(library)
        XCTAssertTrue(library.isUsable)
        XCTAssertFalse(library.isReady)
        XCTAssertEqual(MusicLibrary.songModelStoreReads.withLock { $0 }, readsBefore, "no song was read from the store")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)
        library.songModelArrayReadPolicy = .ignore
        XCTAssertTrue(library.songs.isEmpty)
        library.songModelArrayReadPolicy = .log
        // 小状态、按 id 读、歌单曲数、入口的标记。
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [songs[0].id, songs[4].id, songs[7].id])
        XCTAssertTrue(library.isLiked(songID: songs[1].id))
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [songs[2].id])
        XCTAssertEqual(library.storedSong(id: songs[3].id)?.title, songs[3].title)
        XCTAssertNil(library.visibleSong(id: songs[7].id), "a song in a disabled source is not visible")
        let deadline = ContinuousClock.now + .seconds(5)
        while library.songCount(forPlaylist: playlistID) != countBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.songCount(forPlaylist: playlistID), countBefore)
        XCTAssertEqual([library.hasSpokenWordContent, library.hasAmbientContent, library.hasMusicVideoContent], flagsBefore)
        XCTAssertEqual(library.spokenWordSongCount, spokenWordCount)
        await library.whenUsable()
        let usableInTime = await library.whenUsable(timeout: .milliseconds(50))
        XCTAssertTrue(usableInTime)

        // 不碰它(没有前台占用,像后台启动):不装模型。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(library.isLoadingSongModelForTesting, "nothing asked for the model")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)

        // 启动之后马上的突变:喜欢当场做;加歌排队、把模型装回来。
        library.setLiked(songID: songs[3].id, isLiked: true, propagatesServerMutation: false)
        XCTAssertEqual(library.deferredMutationCountForTesting, 0, "small state is written without the model")
        XCTAssertFalse(library.isLoadingSongModelForTesting)
        var added = songs[0]
        added.id = "unloaded-added"
        added.title = "Blue 9"
        added.trackNumber = 9
        added.filePath = "/Music/Ada/Blue Room/9.flac"
        library.addSongs([added], affectedSourceIDs: [Self.sourceA], notifyRemovals: false, pruneMissingSongs: false)
        XCTAssertTrue(library.isLoadingSongModelForTesting || library.isReady, "a queued mutation asks for the model")
        let hold = await library.holdSongModel(.legacyPage)
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songs.count, songs.count + 1)
        XCTAssertTrue(library.isLiked(songID: songs[3].id))
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 0)
        hold.end()
        await assertShadowMatches(library, "after the load that followed an unloaded launch")
    }

    /// 等可用的在只装小状态的发布(目录读得了之后)放行;等就绪的、`onReady` 的不放行,装模型的那次发布才放行;
    /// 启动窗口里拿的占用让模型在发布之后就开始装。
    func testAnUnloadedLaunchReleasesUsableWaitersAndKeepsReadyWaitersForTheLoad() async throws {
        let songs = Self.fixture(prefix: "waiters")
        let (_, storage) = try await launchFixture("waiters", songs: songs)
        let directory = try copyOfDirectory(storage, "waiters-launch")
        let library = MusicLibrary.makePreparing(
            storageDirectory: directory, disabledSourceIDs: [Self.sourceB], artistNameConfiguration: .defaultValue,
            catalogMirroring: .enabled(startDelay: .zero)
        )
        libraries.append(library)
        library.applySongModelResidencySettings(.init(
            isEnabled: true, foregroundHold: false, playbackBlocksRelease: true, launchUnloaded: true
        ))
        let usable = Tally()
        let ready = Tally()
        library.onUsable { usable.count += 1 }
        library.onReady { ready.count += 1 }
        let usableWaiter = Task { @MainActor in await library.whenUsable(); usable.count += 10 }
        let readyWaiter = Task { @MainActor in await library.whenReady(); ready.count += 10 }
        try await Task.sleep(for: .milliseconds(50))
        let classification = SpokenWordStore.shared.classificationSnapshot
        library.startCatalogBeforePublish(spokenWordClassification: classification)
        let prepared = await MusicLibrary.prepareStartup(
            disabledSourceIDs: [Self.sourceB], storageDirectory: directory, artistNameConfiguration: .defaultValue,
            spokenWordClassification: classification, withoutTheSongModel: true
        )
        await library.publishStartup(prepared) { await MusicLibrary.prepareStartup(storageDirectory: directory) }
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        await usableWaiter.value
        XCTAssertEqual(usable.count, 11, "usable waiters and handlers run once the catalog is readable")
        // 启动窗口里有人 `whenReady()`:只装小状态发布之后,模型为它装回来,装好时等就绪的、`onReady` 的才放行。
        await readyWaiter.value
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(ready.count, 11)
        XCTAssertTrue(library.songModelResidencyStatistics.lastLoadReason?.hasPrefix("whenReady at launch") == true,
                      "\(library.songModelResidencyStatistics)")
    }

    /// 一个不装模型启动、随后装上模型的库,与一个照今天装法启动的库:各份数组、行、小状态、目录都相同。
    func testAnUnloadedLaunchThenALoadMatchesALaunchThatLoaded() async throws {
        let songs = Self.fixture(prefix: "parity")
        let (_, storage) = try await launchFixture("parity", songs: songs)
        let unloaded = await launch(try copyOfDirectory(storage, "parity-unloaded"), unloaded: true)
        let loaded = await launch(try copyOfDirectory(storage, "parity-loaded"), unloaded: false)
        XCTAssertEqual(unloaded.songModelLaunch, "unloaded")
        XCTAssertEqual(loaded.songModelLaunch, "load")
        XCTAssertTrue(loaded.isReady)
        try await waitUntilUsable(unloaded)
        let hold = await unloaded.holdSongModel(.legacyPage)
        XCTAssertTrue(unloaded.isReady)
        XCTAssertEqual(modelPicture(unloaded), modelPicture(loaded))
        assertSameSongs(unloaded.songs, loaded.songs, "rows")
        XCTAssertEqual(unloaded.allPlaylists.map(\.id), loaded.allPlaylists.map(\.id))
        XCTAssertEqual(unloaded.likedSongIDSnapshot(), loaded.likedSongIDSnapshot())
        XCTAssertEqual(unloaded.recentPlaybackSongIDsForSync, loaded.recentPlaybackSongIDsForSync)
        XCTAssertEqual(unloaded.deletedSongIdentities, loaded.deletedSongIdentities)
        hold.end()
        await assertShadowMatches(unloaded, "unloaded launch, then loaded")
        await assertShadowMatches(loaded, "loaded launch")
    }

    /// 启动条件逐条不满足:照今天的装法启动(就绪、模型在内存里),记下的是第一条不满足的。
    func testEachFailingLaunchConditionFallsBackToTodaysLaunch() async throws {
        let songs = Self.fixture(prefix: "fallback")
        let (_, storage) = try await launchFixture("fallback", songs: songs)

        // 开关关着(总开关开着):今天的装法,不试。
        let switchOff = await launch(try copyOfDirectory(storage, "fallback-off"), unloaded: false)
        XCTAssertEqual(switchOff.songModelLaunch, "load")
        XCTAssertTrue(switchOff.isReady)
        // 总开关关着,这个开关开着:同样不试。
        let residencyOff = await launch(try copyOfDirectory(storage, "fallback-residency-off"), unloaded: true, residency: false)
        XCTAssertEqual(residencyOff.songModelLaunch, "load")
        XCTAssertTrue(residencyOff.isReady)

        // 旧库没被哪次启动认过(这一轮进程里才建起来的)。
        let unlaunched = try makeTwin("fallback-unlaunched", songs: songs).library
        _ = await unlaunched.persistNowAndWait()
        await unlaunched.waitForCatalogMirror()
        await unlaunched.stopCatalogMirror()
        let freshStore = await launch(
            try copyOfDirectory(directory.appendingPathComponent("fallback-unlaunched"), "fallback-unlaunched-launch"),
            unloaded: true
        )
        XCTAssertEqual(freshStore.songModelLaunch, "load reason=the store is not what a launch would load as it is")
        XCTAssertTrue(freshStore.isReady)

        // 快照不在。
        let noSnapshot = try copyOfDirectory(storage, "fallback-no-snapshot")
        try FileManager.default.removeItem(at: noSnapshot.appendingPathComponent("library-cache.json"))
        let withoutSnapshot = await launch(noSnapshot, unloaded: true)
        XCTAssertEqual(withoutSnapshot.songModelLaunch, "load reason=no snapshot")
        XCTAssertTrue(withoutSnapshot.isReady)
        XCTAssertEqual(withoutSnapshot.songs.count, songs.count)

        // 快照读不出来。
        let corrupt = try copyOfDirectory(storage, "fallback-corrupt")
        try FileManager.default.removeItem(at: corrupt.appendingPathComponent("library-startup-cache.plist"))
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("library-cache.json"))
        let withCorruptSnapshot = await launch(corrupt, unloaded: true)
        XCTAssertEqual(withCorruptSnapshot.songModelLaunch, "load reason=the snapshot cannot be read")
        XCTAssertTrue(withCorruptSnapshot.isReady)

        // 没有目录(提前启动不了,第 4 条)。
        let withoutCatalog = await launch(try copyOfDirectory(storage, "fallback-no-catalog"), unloaded: true, catalog: .disabled)
        XCTAssertEqual(withoutCatalog.songModelLaunch, "load reason=no catalog")
        XCTAssertTrue(withoutCatalog.isReady)
        XCTAssertEqual(withoutCatalog.songs.count, songs.count)
    }

    /// 放掉之后:按源的歌数从目录来、与放掉之前相同,不读整库数组;没有待认领的身份;搜索索引没有欠着的准备就不装模型,
    /// 欠着才拿占用装回来做。
    func testAReleasedLibraryCountsSourcesAndSkipsIdleMaintenanceWithoutTheModel() async throws {
        let songs = Self.fixture(prefix: "requests")
        let library = try makeLaunchedTwin("requests", songs: songs).library
        await assertShadowMatches(library, "fixture")
        let counts = library.songCountsBySourceID()
        library.songModelResidencyEnabled = true
        guard await released(library, "release") else { return }
        let readsBefore = library.songModelResidencyStatistics.arrayReadsWhileUnloaded
        XCTAssertEqual(library.songCountsBySourceID(), counts)
        XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, readsBefore, "no array was read")
        XCTAssertFalse(library.hasPendingIdentityResolution)
        let preparationOwed = LibrarySearchIndex.hasPendingPreparation(defaults: LibrarySearchIndex.maintenanceDefaults)
        await library.prepareSearchIndexIfNeeded()
        XCTAssertEqual(library.isReady, preparationOwed, "the model comes back only for an owed preparation")
    }

    /// 主线程外的一步停在这里,直到测试放行。
    private actor ResidencyPauseGate {
        private var started = false
        private var released = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }

        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiter = $0 } }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// 放掉之前要满足的条件,逐条破坏:每一条都拦得住,理由记的是第一条不满足的。
    /// 没有在这里破坏的几条(整份替换旧库、快照损坏、目录冻结读、目录落后于旧库、启动时的目录校验、
    /// 写快照失败)见 P3-design.md 19a。
    func testEachIdleCheckRefusesTheRelease() async throws {
        let songs = Self.fixture(prefix: "idle")
        let library = try makeTwin("idle", songs: songs).library
        await assertShadowMatches(library, "fixture")
        func expectSkip(_ expected: String, of target: MusicLibrary? = nil, line: UInt = #line) async {
            let outcome = await releaseOnceShadowVerificationIsDone(target ?? library, trigger: "test")
            XCTAssertEqual(outcome, .skipped(expected), line: line)
        }
        await expectSkip("residency is off")
        library.songModelResidencyEnabled = true

        // 占用(两个理由都点名)。
        let scan = await library.holdSongModel(.scan)
        let export = await library.holdSongModel(.export)
        await expectSkip("hold(export,scan)")
        scan.end()
        await expectSkip("hold(export)")
        export.end()

        // 快照带着歌(小状态离了数组落不了盘)。
        library.separateSongStoreMinimumSongsOverride = 1_000
        await expectSkip("the snapshot carries the songs")
        library.separateSongStoreMinimumSongsOverride = nil

        // 别处正在整份替换快照文件。
        await library.beginExternalSnapshotWrite()
        await expectSkip("external snapshot owner")
        library.endExternalSnapshotWrite()

        // 整库重新分组在后台跑着。
        var regrouped = try XCTUnwrap(library.storedSong(id: songs[4].id))
        regrouped.albumTitle = "Another Mixtape"
        library.replaceSong(regrouped)
        await expectSkip("index rebuild in flight")
        await library.waitForPendingIndex()

        // 扫描的中间一批:整库维护排到了合并窗口里,还没做。
        var deferred = songs[0]
        deferred.id = "idle-deferred"
        deferred.title = "Blue 9"
        deferred.trackNumber = 9
        deferred.filePath = "/Music/Ada/Blue Room/9.flac"
        library.addSongs(
            [deferred], affectedSourceIDs: [Self.sourceA], notifyRemovals: false, pruneMissingSongs: false,
            indexMaintenance: .deferredIncremental
        )
        await expectSkip("deferred maintenance pending")
        await library.waitForPendingIndex()

        // 内容分类(有声 / 音乐)在后台重分。
        let classificationGate = ResidencyPauseGate()
        library.contentClassificationPreparationForTesting = { await classificationGate.pause() }
        SpokenWordStore.shared.setKind(.spokenWord, forSongIDs: [songs[1].id])
        defer { SpokenWordStore.shared.setKind(nil, forSongIDs: [songs[1].id]) }
        let refresh = Task { @MainActor in await library.refreshContentClassificationInBackground() }
        await classificationGate.waitUntilStarted()
        await expectSkip("classification refresh in flight")
        await classificationGate.release()
        await refresh.value
        library.contentClassificationPreparationForTesting = nil
        SpokenWordStore.shared.setKind(nil, forSongIDs: [songs[1].id])
        await library.refreshContentClassificationInBackground()
        await library.waitForPendingIndex()
        // 分类变了,目录要整份重分组,重分组期间读冻结(那时放掉会被 `catalog reads frozen` 拦下):等它做完。
        await library.waitForCatalogMirror()

        // 等写入链落定的那段时间里库又变了。
        library.songModelReleaseDidSettleForTesting = { [weak library] in
            library?.updateLyricsText([songs[0].id: "changed while the release waited"])
        }
        await expectSkip("songs changed during the release")
        // 等的那段时间里来了一条资源补丁(防抖窗口里,还没并进数组)。
        library.songModelReleaseDidSettleForTesting = { [weak library] in
            library?.updateAssetReferences(songID: songs[2].id, coverRef: "cover-while-waiting.jpg")
        }
        await expectSkip("row patches pending")
        // 等的那段时间里小状态又变了,还没落盘。
        library.songModelReleaseDidSettleForTesting = { [weak library] in
            library?.recordPlayback(of: songs[2].id)
        }
        await expectSkip("small state not durable")
        library.songModelReleaseDidSettleForTesting = nil

        // 都满足:放掉。已经放掉的不再放。
        guard await released(library, "all checks pass") else { return }
        await expectSkip("the song model is not loaded")
        XCTAssertEqual(library.storedSong(id: songs[0].id)?.lyricsText, "changed while the release waited")

        // 目录答不了。
        let stopped = try makeTwin("idle-stopped", songs: songs).library
        stopped.songModelResidencyEnabled = true
        await assertShadowMatches(stopped, "fixture")
        await stopped.stopCatalogMirror()
        await expectSkip("the catalog cannot answer", of: stopped)

        // 没有目录;空库。
        let withoutCatalog = makeLibrary(catalog: .disabled)
        withoutCatalog.songModelResidencyEnabled = true
        await expectSkip("the library is empty", of: withoutCatalog)
        withoutCatalog.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await withoutCatalog.waitForPendingIndex()
        await expectSkip("no catalog", of: withoutCatalog)
        XCTAssertTrue(withoutCatalog.isReady)

        // 删一个源的歌正在后台准备;这期间来的突变排在它后面。
        let removing = try makeTwin("idle-removal", songs: songs).library
        await assertShadowMatches(removing, "removal fixture")
        removing.songModelResidencyEnabled = true
        removing.sourceSongRemovalPreparationDelayForTesting = .milliseconds(800)
        let removal = Task { @MainActor in await removing.removeSongsForSource(Self.sourceB) }
        try await Task.sleep(for: .milliseconds(150))
        await expectSkip("source removal in progress", of: removing)
        removing.updateLyricsText([songs[0].id: "queued behind the removal"])
        XCTAssertEqual(removing.deferredMutationCountForTesting, 1)
        await expectSkip("queued mutations", of: removing)
        await removal.value
        XCTAssertEqual(removing.storedSong(id: songs[0].id)?.lyricsText, "queued behind the removal")

        // 旧库打不开(歌只在 JSON 里)。
        let storeless = directory.appendingPathComponent("idle-storeless", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeless.appendingPathComponent("library-songs.sqlite", isDirectory: true), withIntermediateDirectories: true
        )
        let withoutStore = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: storeless, artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true }, catalogMirroring: .enabled(startDelay: .zero)
        )
        libraries.append(withoutStore)
        withoutStore.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await withoutStore.waitForPendingIndex()
        withoutStore.songModelResidencyEnabled = true
        await expectSkip("no song store", of: withoutStore)
        XCTAssertTrue(withoutStore.isReady)
    }

    /// 装回来读完旧库、还没发布的那一刻,旧库又被写了(改一行、删一行):发布之前按变更流水补上,发布出来的模型里
    /// 就是新的那一行、没有删掉的那一行。装载期间来的按 id 写排队,发布之后重放。
    func testRowsWrittenWhileTheSongModelLoadsAreInThePublishedModel() async throws {
        let songs = Self.fixture(prefix: "journal")
        let twin = try makeLaunchedTwin("journal", songs: songs)
        let library = twin.library
        let storage = twin.storage
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        guard await released(library, "release") else { return }

        var edited = songs[1]
        edited.duration = 4_242
        edited.lyricsText = "written behind the load"
        let behind = edited
        library.songModelLoadDidReadForTesting = { [weak library, weak self] in
            guard let library, let self else { return }
            library.songModelLoadDidReadForTesting = nil
            try? await self.writeBehindTheLibrary(library, storage: storage, upserts: [behind], deletingIDs: [songs[3].id])
            library.updateLyricsText([songs[0].id: "queued during the load"])
            XCTAssertEqual(library.deferredMutationCountForTesting, 1, "a row write during a load waits for the publish")
        }
        let hold = await library.holdSongModel(.backfill)
        let statistics = library.songModelResidencyStatistics
        XCTAssertEqual(statistics.lastLoadJournalRows, 2, "\(statistics)")
        XCTAssertEqual(statistics.loadRestarts, 0)
        XCTAssertEqual(statistics.wholeLibraryLoads, 0)
        XCTAssertEqual(library.songs.count, songs.count - 1)
        XCTAssertEqual(library.storedSong(id: songs[1].id)?.duration, 4_242)
        XCTAssertEqual(library.storedSong(id: songs[1].id)?.lyricsText, "written behind the load")
        XCTAssertNil(library.storedSong(id: songs[3].id))
        XCTAssertEqual(library.storedSong(id: songs[0].id)?.lyricsText, "queued during the load")
        XCTAssertEqual(library.deferredMutationCountForTesting, 0)
        hold.end()
        await assertShadowMatches(library, "after a load patched from the journal")
        let stored = try IncrementalSongStoreScanner(path: storage.appendingPathComponent("library-songs.sqlite").path)
        XCTAssertEqual(try stored.songCount(), songs.count - 1)
    }

    /// 每一类突变,在一直装着模型的库上做一遍,在「放掉 → 突变 → 装回来」的库上做一遍:歌曲行、各份数组、歌单与
    /// 喜欢、目录都相同。只动行或小状态的突变放掉期间当场做、不装模型;要数组的排队并自己把模型装回来。
    func testMutationsThroughReleaseAndLoadCyclesMatchALibraryThatStayedLoaded() async throws {
        let songs = Self.fixture(prefix: "cycle")
        var added = Song(
            id: "cycle-added", title: "Blue 5", albumTitle: "Blue Room", artistName: "Ada", albumArtistName: "Ada",
            trackNumber: 5, discNumber: 1, duration: 200, fileFormat: .flac,
            filePath: "/Music/Ada/Blue Room/5.flac", sourceID: Self.sourceA, genre: "Pop", year: 2001
        )
        added.dateAdded = Date(timeIntervalSince1970: 1_700_000_900)
        func make(_ name: String) async throws -> MusicLibrary {
            let library = try makeLaunchedTwin(name, songs: songs).library
            _ = library.createPlaylist(name: "Mix", songIDs: [songs[0].id, songs[4].id, songs[10].id, songs[2].id])
            await assertShadowMatches(library, "\(name) fixture")
            return library
        }
        let loaded = try await make("stays-loaded")
        let cycled = try await make("cycled")
        cycled.songModelResidencyEnabled = true
        func mix(_ library: MusicLibrary) throws -> String {
            try XCTUnwrap(library.allPlaylists.first { $0.name == "Mix" }).id
        }
        func smallState(_ library: MusicLibrary) throws -> [String] {
            let mixID = try mix(library)
            // 找不回来的成员(歌单、喜欢/不喜欢的记录)各自带一个随机的占位 id,两个库里不同,只比它在哪个位置。
            func placeholders(_ ids: [String]) -> [String] { ids.map { $0.hasPrefix("pending:") ? "pending" : $0 } }
            let members = placeholders(library.rawSongIDs(forPlaylist: mixID))
            return [
                "members \(members)", "visible \(library.songCount(forPlaylist: mixID))",
                "liked \(placeholders(library.likedSongIDSnapshot().sorted()))",
                "disliked \(placeholders(library.dislikedSongIDs.sorted()))",
                "recents \(library.recentPlaybackSongIDsForSync)",
                "review \(String(describing: library.libraryReview(for: .song(songs[3].id))?.comment))",
                "tombstones \(library.deletedSongIdentities.sorted())",
                "excluded \(library.deviceLocalExcludedSongIdentities.sorted())",
            ]
        }
        let addedSong = added
        typealias Step = (name: String, needsTheModel: Bool, mutate: @MainActor (MusicLibrary) throws -> Void)
        var steps: [Step] = []
        steps.append(("lyrics text", false, { library in library.updateLyricsText([songs[0].id: "la la"]) }))
        steps.append(("asset references", false, { library in
            library.updateAssetReferences(songID: songs[1].id, coverRef: "cover-new.jpg", lyricsRef: "lyrics-new.lrc")
            library.flushPendingAssetReferencePatches()
        }))
        steps.append(("row replacement", false, { library in
            var timed = try XCTUnwrap(library.storedSong(id: songs[2].id))
            timed.duration = 321
            library.replaceSong(timed)
        }))
        steps.append(("like, dislike, playlist, history, review", false, { library in
            library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
            library.setDisliked(songID: songs[3].id, isDisliked: true)
            library.add(songIDs: [songs[11].id], toPlaylist: try mix(library))
            library.recordPlayback(of: songs[0].id)
            library.updateLibraryReview(for: .song(songs[3].id), rating: 3, comment: "while cycling")
        }))
        steps.append(("playlist remove and reorder", false, { library in
            let mixID = try mix(library)
            library.remove(songID: songs[10].id, fromPlaylist: mixID)
            library.reorderPlaylistSongs(playlistID: mixID, listedOrder: [songs[11].id, songs[2].id, songs[0].id, songs[4].id])
        }))
        steps.append(("delete by id", false, { library in _ = library.deleteSongs([songs[4]]) }))
        steps.append(("remove from this device", false, { library in
            _ = try library.removeSongsFromThisDevice([songs[15]])
        }))
        steps.append(("enable the other source", false, { library in library.updateDisabledSourceIDs([]) }))
        steps.append(("add songs", true, { library in
            library.addSongs([addedSong], affectedSourceIDs: [Self.sourceA], notifyRemovals: false, pruneMissingSongs: false)
        }))
        steps.append(("regrouping edit", true, { library in
            var edited = try XCTUnwrap(library.storedSong(id: songs[5].id))
            edited.albumTitle = "Mixtape Deluxe"
            library.replaceSong(edited)
        }))
        steps.append(("id remap", true, { library in library.remapSongIDs([songs[6].id: "cycle-renamed"]) }))
        steps.append(("restore to this device", true, { library in
            _ = try library.restoreSongsRemovedFromThisDevice([songs[15].id])
        }))
        steps.append(("disable a source", false, { library in library.updateDisabledSourceIDs([Self.sourceA]) }))
        // 一个源扫完(没扫到的歌从库里去掉,歌单里留占位)。
        steps.append(("scan of a source", true, { library in
            library.addSongs([addedSong], affectedSourceIDs: [Self.sourceA])
        }))
        for step in steps {
            try step.mutate(loaded)
            guard await released(cycled, step.name) else { return }
            let loadsBefore = cycled.songModelResidencyStatistics.loads
            try step.mutate(cycled)
            if step.needsTheModel {
                XCTAssertTrue(cycled.isLoadingSongModelForTesting || cycled.isReady, "\(step.name): it asks for the model")
                try await waitUntilReady(cycled)
                XCTAssertTrue(cycled.isReady, "\(step.name): the queued mutation brought the model back")
                XCTAssertTrue(cycled.songModelResidencyStatistics.lastLoadReason?.hasPrefix("queued") == true, step.name)
            } else {
                XCTAssertEqual(cycled.deferredMutationCountForTesting, 0, "\(step.name): done without the model")
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertFalse(cycled.isLoadingSongModelForTesting, "\(step.name): no load was asked for")
                XCTAssertEqual(cycled.songModelResidencyStatistics.loads, loadsBefore, step.name)
                XCTAssertEqual(try smallState(cycled), try smallState(loaded), "\(step.name), still released")
                let hold = await cycled.holdSongModel(.legacyPage)
                hold.end()
            }
            await assertShadowMatches(loaded, "\(step.name), loaded")
            await assertShadowMatches(cycled, "\(step.name), cycled")
            XCTAssertEqual(modelPicture(cycled), modelPicture(loaded), step.name)
            assertSameSongs(cycled.songs, loaded.songs, "\(step.name): rows")
            XCTAssertEqual(try smallState(cycled), try smallState(loaded), step.name)
        }
        XCTAssertEqual(cycled.songModelResidencyStatistics.releases, steps.count)
        XCTAssertEqual(cycled.songModelResidencyStatistics.wholeLibraryLoads, 0)
        print("REPORT_RESIDENCY_CYCLES \(cycled.songModelResidencyStatistics)")
    }

    /// 放掉之后目录不再答得了:库这一刻不可用,同时自己把模型装回来(理由记的是目录答不了,不是等可用的那一方),
    /// 等可用的被放行。
    func testACatalogThatStopsAnsweringBringsTheSongModelBack() async throws {
        let songs = Self.fixture(prefix: "unanswered")
        let library = try makeTwin("unanswered", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        guard await released(library, "release") else { return }
        XCTAssertTrue(library.isUsable)
        await library.stopCatalogMirror()
        XCTAssertFalse(library.isUsable, "nothing can answer at this moment")
        XCTAssertNil(library.storedSongsIfAnswerable(forPlaylist: "any"), "cannot answer")
        let usable = await library.whenUsable(timeout: .seconds(20))
        XCTAssertTrue(usable)
        XCTAssertTrue(library.isReady)
        XCTAssertTrue(library.isUsable)
        XCTAssertEqual(library.songs.count, songs.count)
        XCTAssertEqual(library.songModelResidencyStatistics.lastLoadReason, "the catalog cannot answer")
    }

    /// 只装歌曲模型装不成时改走整份装载:放掉期间改过的小状态先落盘,装完还在。旧库是这一轮进程里才建起来的
    /// (还没被哪次启动认过)时第一次装载就是这样,那次整份装载把旧库标好,之后只装歌曲模型;旧库读不出来时也走整份。
    func testALoadThatCannotReadTheSongModelAloneLoadsTheWholeLibrary() async throws {
        let songs = Self.fixture(prefix: "whole")
        let library = try makeTwin("whole", songs: songs).library
        let playlist = library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[1].id])
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        let rowsBefore = library.songs

        guard await released(library, "release of a library whose store no launch has seen") else { return }
        let first = await library.holdSongModel(.scan)
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 1, "the first load reads the whole library")
        assertSameSongs(library.songs, rowsBefore, "rows after the first whole-library load")
        first.end()
        guard await released(library, "release after the first load") else { return }
        let second = await library.holdSongModel(.scan)
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 1, "from then on the song model alone")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 2)
        assertSameSongs(library.songs, rowsBefore, "rows after the songs-only load")
        second.end()

        guard await released(library, "release") else { return }
        library.setLiked(songID: songs[3].id, isLiked: true, propagatesServerMutation: false)
        library.add(songIDs: [songs[2].id], toPlaylist: playlist.id)
        library.songModelLoadFailsForTesting = true
        let hold = await library.holdSongModel(.migration)
        library.songModelLoadFailsForTesting = false
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.wholeLibraryLoads, 2)
        assertSameSongs(library.songs, rowsBefore, "rows after the whole-library load")
        XCTAssertTrue(library.isLiked(songID: songs[3].id), "small state changed while released is still there")
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), [songs[0].id, songs[1].id, songs[2].id])
        hold.end()
        await assertShadowMatches(library, "after the whole-library load")
        guard await released(library, "release after the whole-library load") else { return }
    }

    /// 模型不在内存里时读整库数组:记数(与日志),装回来之后不记。
    func testArrayReadsWhileTheSongModelIsReleasedAreCounted() async throws {
        let songs = Self.fixture(prefix: "reads")
        let library = try makeTwin("reads", songs: songs).library
        library.songModelResidencyEnabled = true
        await assertShadowMatches(library, "fixture")
        guard await released(library, "release") else { return }
        let afterRelease = library.songModelResidencyStatistics.arrayReadsWhileUnloaded
        print("REPORT_ARRAY_READS_BY_THE_RELEASE_ITSELF count=\(afterRelease)")
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.visibleAlbums.isEmpty)
        XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, afterRelease + 2)
        library.songModelArrayReadPolicy = .ignore
        XCTAssertTrue(library.musicSongs.isEmpty)
        XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, afterRelease + 2)
        library.songModelArrayReadPolicy = .log
        let hold = await library.holdSongModel(.legacyPage)
        let afterLoad = library.songModelResidencyStatistics.arrayReadsWhileUnloaded
        print("REPORT_ARRAY_READS_BY_THE_LOAD count=\(afterLoad - afterRelease - 2)")
        XCTAssertEqual(library.songs.count, songs.count)
        XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, afterLoad)
        hold.end()
    }

    private func makeCloudSync(_ library: MusicLibrary, _ name: String) throws -> CloudKitSyncService {
        let suite = "cloud-receive-\(name)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return CloudKitSyncService(
            library: library,
            sourcesStore: SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources-\(name)")),
            radioStationsStore: RadioStationsStore(storeURL: directory.appendingPathComponent("radio-\(name).json")),
            scraperSettingsStore: ScraperSettingsStore(defaults: defaults)
        )
    }

    /// CK-a:CloudKit 的引擎事件只在带着要整库数组的记录时占用歌曲模型。模型放掉时:存游标(什么都没排着)五次,
    /// 一次也不占用、不装;只动小状态的一批(智能歌单)直接落地、不装;要模型的一批(别的设备的歌单,按成员身份认歌)
    /// 装一次、落地的与模型在内存里的那一台相同、做完放手;再放掉之后存游标仍不装 —— 放掉(和它引起的写)不会
    /// 引出要装模型的事件。
    func testCloudKitEventsTakeTheSongModelOnlyForRecordsThatNeedIt() async throws {
        let songs = Self.fixture(prefix: "ckrecv")
        let sender = try makeLaunchedTwin("ckrecv-sender", songs: songs).library
        await assertShadowMatches(sender, "sender")
        let playlist = sender.createPlaylist(name: "From another device", songIDs: [songs[0].id, songs[4].id, songs[2].id])
        let smart = SmartPlaylist(name: "Remote smart")
        sender.saveSmartPlaylist(smart)
        let senderSync = try makeCloudSync(sender, "sender")
        guard case .built(let playlistRecord) = senderSync.recordBuildOutcomeForTesting(
            recordType: CloudKitSyncService.RecordType.playlist, localID: playlist.id
        ), case .built(let smartRecord) = senderSync.recordBuildOutcomeForTesting(
            recordType: CloudKitSyncService.RecordType.smartPlaylist, localID: smart.id
        ) else { return XCTFail("the sender builds both records") }
        XCTAssertTrue(CloudKitSyncService.recordTypeNeedsSongModel(playlistRecord.recordType))
        XCTAssertFalse(CloudKitSyncService.recordTypeNeedsSongModel(smartRecord.recordType))

        let loaded = try makeLaunchedTwin("ckrecv-loaded", songs: songs).library
        let released = try makeLaunchedTwin("ckrecv-released", songs: songs).library
        await assertShadowMatches(loaded, "loaded")
        await assertShadowMatches(released, "released")
        let loadedSync = try makeCloudSync(loaded, "loaded")
        let releasedSync = try makeCloudSync(released, "released")
        let before = try await releaseForReal(released)
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        let cursorSaves = Tally()
        for _ in 0..<5 { await releasedSync.receiveStateUpdate(isCurrent: { true }) { cursorSaves.count += 1 } }
        XCTAssertEqual(cursorSaves.count, 5, "the cursor is saved each time")
        XCTAssertEqual(songModelHolds(of: released), [], "saving the cursor takes no hold")
        assertNoLoadAndNoArrayRead(released, since: before, "five cursor saves")

        await releasedSync.receiveFetchedRecordsForTesting([smartRecord])
        XCTAssertTrue(released.allSmartPlaylists.contains { $0.id == smart.id }, "the smart playlist is applied without the model")
        XCTAssertEqual(songModelHolds(of: released), [])
        assertNoLoadAndNoArrayRead(released, since: before, "a smart playlist record")

        await loadedSync.receiveFetchedRecordsForTesting([playlistRecord])
        await releasedSync.receiveFetchedRecordsForTesting([playlistRecord])
        XCTAssertEqual(released.songModelResidencyStatistics.loads, before.loads + 1, "the playlist record loads the model once")
        XCTAssertEqual(songModelHolds(of: released), [.cloudKitReceive])
        XCTAssertTrue(released.isReady)
        XCTAssertFalse(released.songModelHoldReasons.contains(.cloudKitReceive), "and lets go")
        XCTAssertEqual(released.songIDs(forPlaylist: playlist.id), loaded.songIDs(forPlaylist: playlist.id))
        XCTAssertEqual(loaded.songIDs(forPlaylist: playlist.id), [songs[0].id, songs[4].id, songs[2].id])

        let again = try await releaseForReal(released)
        for _ in 0..<5 { await releasedSync.receiveStateUpdate(isCurrent: { true }) { cursorSaves.count += 1 } }
        XCTAssertEqual(cursorSaves.count, 10)
        XCTAssertEqual(songModelHolds(of: released), [.cloudKitReceive], "no further hold")
        assertNoLoadAndNoArrayRead(released, since: again, "cursor saves after the second release")
    }

    /// CK-a 第 2 项:模型不在内存里时补读不拿空的歌曲表去比剩余数(以前在这里读一次 `songs`、记一笔数组读;
    /// 拿空表算出的「0 条」会把队列当成做完),队列状态原样留着。
    func testBackfillDoesNotCountFromAnEmptyLibraryWhileTheModelIsReleased() async throws {
        let songs = Self.fixture(prefix: "backfill")
        let library = try makeLaunchedTwin("backfill", songs: songs).library
        await assertShadowMatches(library, "fixture")
        let state = directory.appendingPathComponent("backfill-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let backfill = MetadataBackfillService(
            library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { [Self.sourceA] }, storageDirectory: state
        )
        defer { backfill.stop() }
        let pendingBefore = backfill.hasPendingWork
        let before = try await releaseForReal(library)
        XCTAssertFalse(backfill.applyCachedRemainingCountsForTesting(), "nothing is applied from an empty library")
        XCTAssertEqual(backfill.hasPendingWork, pendingBefore, "the queue state is left as it is")
        assertNoLoadAndNoArrayRead(library, since: before, "remaining counts while released")
    }

    private func makeBackfill(_ library: MusicLibrary, _ name: String) throws -> MetadataBackfillService {
        let state = directory.appendingPathComponent("backfill-\(name)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let backfill = MetadataBackfillService(
            library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { [Self.sourceA, Self.sourceB] }, storageDirectory: state
        )
        return backfill
    }

    /// 19d:重试补读失败的那几首,歌曲模型放掉之后照样做:有被拦下的账才占用(`.userAction`)装回来,重开的与模型
    /// 在内存里的那一台相同,做完放手;一条都没有时什么也不装、不读整库数组。
    func testRetryingFailedBackfillWhileReleasedReopensTheSameRows() async throws {
        let songs = Self.fixture(prefix: "retry")
        let loaded = try makeLaunchedTwin("retry-loaded", songs: songs).library
        let released = try makeLaunchedTwin("retry-released", songs: songs).library
        await assertShadowMatches(loaded, "loaded")
        await assertShadowMatches(released, "released")
        let loadedBackfill = try makeBackfill(loaded, "retry-loaded")
        let releasedBackfill = try makeBackfill(released, "retry-released")
        defer {
            loadedBackfill.stop()
            releasedBackfill.stop()
        }
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let before = try await releaseForReal(released)

        let nothing = await releasedBackfill.retryFailedLoadingTheModelIfNeeded(startImmediately: false)
        XCTAssertEqual(nothing, 0)
        XCTAssertEqual(songModelHolds(of: released), [], "nothing blocked: no hold")
        assertNoLoadAndNoArrayRead(released, since: before, "nothing to retry")

        let failed = [songs[0].id, songs[4].id]
        loadedBackfill.markFailedForTesting(failed)
        releasedBackfill.markFailedForTesting(failed)
        let expected = loadedBackfill.retryFailed(startImmediately: false)
        XCTAssertEqual(expected, failed.count)
        let reopened = await releasedBackfill.retryFailedLoadingTheModelIfNeeded(startImmediately: false)
        XCTAssertEqual(reopened, expected, "the same rows are reopened")
        XCTAssertEqual(released.songModelResidencyStatistics.loads, before.loads + 1, "loaded once for the retry")
        XCTAssertEqual(songModelHolds(of: released), [.userAction])
        XCTAssertFalse(released.songModelHoldReasons.contains(.userAction), "and let go")
        for id in failed {
            XCTAssertFalse(loadedBackfill.isMarkedFailedForTesting(id))
            XCTAssertFalse(releasedBackfill.isMarkedFailedForTesting(id))
        }
    }

    /// 19d:删掉一个源时补读丢掉它那些歌的账,歌曲模型放掉之后照样:这个源的歌从目录按源取 id,不装模型、不读整库
    /// 数组;丢掉的与模型在内存里的那一台相同,别的源的账留着。
    func testDiscardingARemovedSourceWhileReleasedDropsItsBackfillRows() async throws {
        let songs = Self.fixture(prefix: "discard")
        let loaded = try makeLaunchedTwin("discard-loaded", songs: songs).library
        let released = try makeLaunchedTwin("discard-released", songs: songs).library
        await assertShadowMatches(loaded, "loaded")
        await assertShadowMatches(released, "released")
        let loadedBackfill = try makeBackfill(loaded, "discard-loaded")
        let releasedBackfill = try makeBackfill(released, "discard-released")
        defer {
            loadedBackfill.stop()
            releasedBackfill.stop()
        }
        let ofSourceA = try XCTUnwrap(songs.first { $0.sourceID == Self.sourceA }).id
        let ofSourceB = try XCTUnwrap(songs.first { $0.sourceID == Self.sourceB }).id
        loadedBackfill.markFailedForTesting([ofSourceA, ofSourceB])
        releasedBackfill.markFailedForTesting([ofSourceA, ofSourceB])
        let before = try await releaseForReal(released)

        loadedBackfill.discardWork(forSourceID: Self.sourceA)
        releasedBackfill.discardWork(forSourceID: Self.sourceA)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              loadedBackfill.isMarkedFailedForTesting(ofSourceA) || releasedBackfill.isMarkedFailedForTesting(ofSourceA) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(loadedBackfill.isMarkedFailedForTesting(ofSourceA))
        XCTAssertFalse(releasedBackfill.isMarkedFailedForTesting(ofSourceA), "the removed source's row is dropped while released")
        XCTAssertTrue(loadedBackfill.isMarkedFailedForTesting(ofSourceB))
        XCTAssertTrue(releasedBackfill.isMarkedFailedForTesting(ofSourceB), "another source's row stays")
        assertNoLoadAndNoArrayRead(released, since: before, "discarding a removed source's rows")
    }

    /// 19d:挂起之前再放一次各连接的页缓存(目录各连接、跟旧库的只读连接、旧库本身):做完才返回,不装模型,之后照样答;
    /// 后台放掉之后经读接口读目录的,开着记录时一次记一笔。
    func testReleasingTheDatabaseMemoryAndCountingBackgroundCatalogReads() async throws {
        let songs = Self.fixture(prefix: "dbmem")
        let library = try makeLaunchedTwin("dbmem", songs: songs).library
        await assertShadowMatches(library, "fixture")
        let host = try XCTUnwrap(library.catalogHost)
        let before = try await releaseForReal(library)
        let releasesBefore = host.mirror.statistics.memoryReleases
        await library.releaseDatabaseMemoryAndWait()
        // 放掉那一步自己也排了一次(在后台队列上,可能正好在这前后做完):至少多了这一次。
        XCTAssertGreaterThanOrEqual(host.mirror.statistics.memoryReleases, releasesBefore + 1, "done when it returns")
        XCTAssertEqual(library.visibleSong(id: songs[0].id)?.title, songs[0].title, "it still answers by id")
        assertNoLoadAndNoArrayRead(library, since: before, "releasing the page caches")

        LibraryCatalogBackgroundReadWatch.begin()
        _ = try await host.reader.read { try $0.songCount() }
        _ = try await host.reader.read { try $0.songCount(.everything) }
        XCTAssertEqual(LibraryCatalogBackgroundReadWatch.end(), 2)
        XCTAssertFalse(LibraryCatalogBackgroundReadWatch.isActive)
        _ = try await host.reader.read { try $0.songCount() }
        XCTAssertEqual(LibraryCatalogBackgroundReadWatch.end(), 0, "nothing is counted while it is off")
    }

    /// CK-a 第 3 项:不装歌曲模型的启动在发布小状态的那一步就从目录补上有声(含本机播客)与环境音的 id 表 ——
    /// `publishStartup` 返回时已经在,等可用的那些在它之后才放行;与照今天装法启动的库相同,`nonMusicSongIDs` 跟着对。
    func testAnUnloadedLaunchHasTheSpokenWordAndAmbientSetsBeforeItIsUsable() async throws {
        var songs = Self.fixture(prefix: "classes")
        // 夹具里的播客在停用的源 B 里;另放一集到源 A,本机播客才有可见的。
        var episode = try XCTUnwrap(songs.first { $0.id.hasSuffix("-pod-1") })
        episode.id += "-a"
        episode.sourceID = Self.sourceA
        episode.filePath = "/Music/Podcasts/Weekly/1.mp3"
        songs.append(episode)
        let book = try XCTUnwrap(songs.first { $0.id.hasSuffix("-book-1") })
        let rain = try XCTUnwrap(songs.first { $0.id.hasSuffix("-rain") })
        let (_, storage) = try await launchFixture("classes", songs: songs)
        let loaded = await launch(try copyOfDirectory(storage, "classes-loaded"), unloaded: false)
        let unloaded = await launch(try copyOfDirectory(storage, "classes-unloaded"), unloaded: true)
        XCTAssertTrue(loaded.isReady)
        XCTAssertEqual(unloaded.songModelLaunch, "unloaded")
        XCTAssertFalse(unloaded.isReady)
        XCTAssertTrue(loaded.spokenWordSongIDs.isSuperset(of: [book.id, episode.id]))
        XCTAssertEqual(loaded.ambientSongIDs, [rain.id])
        XCTAssertEqual(unloaded.spokenWordSongIDs, loaded.spokenWordSongIDs)
        XCTAssertEqual(unloaded.ambientSongIDs, loaded.ambientSongIDs)
        XCTAssertEqual(unloaded.nonMusicSongIDs, loaded.nonMusicSongIDs)
        XCTAssertFalse(unloaded.isWholeLibraryPlaybackSong(id: book.id))
        XCTAssertFalse(unloaded.isWholeLibraryPlaybackSong(id: rain.id))
        XCTAssertTrue(unloaded.isWholeLibraryPlaybackSong(id: songs[0].id))
        try await waitUntilUsable(unloaded)
        XCTAssertEqual(unloaded.songModelResidencyStatistics.loads, 0, "filling them needs no load")
    }

    /// S8:放掉时一起换成空的、以前读了不记的那几份(三份分类数组、播客预览、两张分书表、节目数、收藏的艺人候选、
    /// 两份查找快照、按源的歌、首选封面表与封面回退),放掉之后每读一次记一笔;模型在内存里时不记。
    func testReadsOfTheOtherDroppedTablesWhileReleasedAreCounted() async throws {
        let songs = Self.fixture(prefix: "silent")
        let library = try makeLaunchedTwin("silent", songs: songs).library
        await assertShadowMatches(library, "fixture")
        let albumID = try XCTUnwrap(library.visibleAlbums.first?.id)
        let artistID = try XCTUnwrap(library.visibleArtists.first?.id)
        let reads: [(String, @MainActor () -> Void)] = [
            ("ambientSongs", { _ = library.ambientSongs }),
            ("musicVideoSongs", { _ = library.musicVideoSongs }),
            ("localPodcastSongs", { _ = library.localPodcastSongs }),
            ("localPodcastPreviewSongs", { _ = library.localPodcastPreviewSongs }),
            ("localPodcastBookIDs", { _ = library.localPodcastBookIDs }),
            ("spokenWordBookIDs", { _ = library.spokenWordBookIDs }),
            ("localPodcastShowCount", { _ = library.localPodcastShowCount }),
            ("favoriteArtistCandidates", { _ = library.favoriteArtistCandidates }),
            ("visibleSongLookup()", { _ = library.visibleSongLookup() }),
            ("historySongLookup()", { _ = library.historySongLookup() }),
            ("visibleSongs(forSourceID:)", { _ = library.visibleSongs(forSourceID: Self.sourceA) }),
            ("playableSongs(forSourceID:)", { _ = library.playableSongs(forSourceID: Self.sourceA) }),
            ("preferredArtworkSong(forAlbumID:)", { _ = library.preferredArtworkSong(forAlbumID: albumID) }),
            ("preferredArtworkSong(forArtistID:)", { _ = library.preferredArtworkSong(forArtistID: artistID) }),
            ("scopedPreferredArtworkSong(forAlbumID:)", { _ = library.scopedPreferredArtworkSong(forAlbumID: albumID) }),
            ("scopedPreferredArtworkSong(forArtistID:)", { _ = library.scopedPreferredArtworkSong(forArtistID: artistID) }),
            ("scopedAlternateArtworkSong(forAlbumID:)", {
                _ = library.scopedAlternateArtworkSong(forAlbumID: albumID, excludingSongIDs: [], excludingReferences: [])
            }),
            ("scopedAlternateArtworkSong(forArtistID:)", {
                _ = library.scopedAlternateArtworkSong(forArtistID: artistID, excludingSongIDs: [], excludingReferences: [])
            }),
        ]
        let whileLoaded = library.songModelResidencyStatistics.arrayReadsWhileUnloaded
        for (_, read) in reads { read() }
        XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, whileLoaded, "nothing counted while loaded")

        let before = try await releaseForReal(library)
        for (name, read) in reads {
            let count = library.songModelResidencyStatistics.arrayReadsWhileUnloaded
            read()
            XCTAssertEqual(library.songModelResidencyStatistics.arrayReadsWhileUnloaded, count + 1, "\(name) is counted once")
        }
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads)
    }

    /// S8:几个读法在模型放掉之后改从目录答,与模型在内存里时逐项相同(同一个库,放掉前后各问一遍):
    /// 最近播放、喜欢的本地播客、「我喜欢」本身、歌单卡片的摘要、艺人卡片的艺人值、「专辑艺术家」里的每一位、
    /// 流派的专辑、按名字找专辑与艺人(歌上的第二位、后面几位艺人也找得到)。
    /// 放掉之后问的这些都不装模型、不读整库数组。
    func testFacadeAnswersWhileReleasedMatchTheLoadedLibrary() async throws {
        let songs = Self.fixture(prefix: "facade")
        // 夹具里的播客在停用的源 B 里;另放两集到源 A,喜欢的本地播客才有可见的。
        let podcasts = songs.filter { $0.id.contains("-pod-") }.map { episode -> Song in
            var copy = episode
            copy.id += "-a"
            copy.sourceID = Self.sourceA
            copy.filePath = "/Music/Podcasts/Weekly/\(copy.title).mp3"
            return copy
        }
        // 一张合辑:专辑艺人「Various Artists」没有自己唱的歌,只在「专辑艺术家」里。
        let compilation = (1...2).map { track in
            Song(
                id: "facade-va-\(track)", title: "VA \(track)", albumTitle: "Hits", artistName: "Solo \(track)",
                albumArtistName: "Various Artists", trackNumber: track, discNumber: 1, duration: 200 + Double(track),
                fileFormat: .flac, filePath: "/Music/Hits/\(track).flac", sourceID: Self.sourceA, genre: "Pop", year: 2002
            )
        }
        let library = try makeLaunchedTwin("facade", songs: songs, extra: podcasts + compilation).library
        func id(_ suffix: String) -> String { "facade-\(suffix)" }
        for liked in [podcasts[1].id, id("blue-1"), podcasts[0].id, id("book-1")] {
            library.setLiked(songID: liked, isLiked: true, propagatesServerMutation: false)
        }
        for played in [id("comp-1"), id("book-2"), id("rain"), id("blueb-1"), podcasts[0].id, id("blue-3"), id("cue-1"),
                       id("loose"), id("blue-2"), id("comp-3")] {
            library.recordPlayback(of: played)
        }
        let playlist = library.createPlaylist(
            name: "Browse", songIDs: [id("blue-1"), id("blueb-2"), id("comp-2"), id("cue-2"), id("blue-4"), id("rain")]
        )
        await assertShadowMatches(library, "fixture")
        let genreIDs = library.visibleGenres.map(\.id) + ["no-such-genre"]
        let artistIDs = library.visibleArtists.map(\.id) + ["no-such-artist"]
        let albumArtistIDs = library.visibleAlbumArtists.map(\.id) + ["no-such-album-artist"]
        XCTAssertTrue(
            library.visibleAlbumArtists.contains { library.visibleArtist(id: $0.id) == nil },
            "the fixture has an artist who is only an album artist"
        )
        let albumNames: [(String, String)] = [
            ("Blue Room", "Ada"), ("blue room", "ADA"), ("Blue Room", ""), ("Mixtape", ""), ("Mixtape", "Nobody"),
            ("Live Set", "dj"), ("Sleep", ""), ("Long Story", "Narrator"), ("Hits", "various artists"), ("No Such Album", ""),
        ]
        // 「Ben」只是「Blue 2」的第二位艺人(「Ada、Ben」)。
        let artistNames = ["Ada", "ada", "Ben", "BEN", "ADA、BEN", "Artist 2", "Solo 2", "Various Artists", "DJ", "Narrator",
                           "Host", "Nobody"]

        func answers() -> [String] {
            var lines: [String] = []
            for limit in [3, 6, 20] {
                lines.append("recent \(limit): " + library.recentlyPlayedSongs(limit: limit).map(\.id).joined(separator: ","))
            }
            lines.append("liked podcasts: " + library.likedLocalPodcastSongs().map(\.id).joined(separator: ","))
            // 「我喜欢」本身只列音乐,播客单集分开列(放掉之后也要分得开)。
            lines.append("liked: " + library.songIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID).joined(separator: ","))
            for limit in [0, 2, 10] {
                let summary = library.playlistBrowseSummary(forPlaylist: playlist.id, artworkCandidateLimit: limit)
                lines.append("browse \(limit): \(summary.count) " + summary.artworkCandidates.map(\.id).joined(separator: ","))
            }
            for artistID in artistIDs {
                let artist = library.scopedVisibleArtist(id: artistID)
                lines.append("artist \(artistID): \(artist.map { "\($0.name) \($0.songCount)" } ?? "nil")")
            }
            for albumArtistID in albumArtistIDs {
                let artist = library.visibleAlbumArtist(id: albumArtistID)
                lines.append("album artist \(albumArtistID): "
                             + (artist.map { "\($0.name) \($0.albumCount) \($0.songCount)" } ?? "nil"))
            }
            for genreID in genreIDs {
                let albums = library.albums(forGenre: genreID)
                lines.append("genre \(genreID): " + albums.map { "\($0.id)/\($0.songCount)" }.joined(separator: ","))
            }
            for (title, artist) in albumNames {
                let album = library.visibleAlbum(titled: title, artistName: artist)
                lines.append("album \(title)|\(artist): \(album.map { "\($0.id) \($0.title) \($0.songCount)" } ?? "nil")")
            }
            for name in artistNames {
                let artist = library.visibleArtist(named: name)
                lines.append("artist named \(name): \(artist.map { "\($0.id) \($0.name)" } ?? "nil")")
            }
            return lines
        }
        let loaded = answers()
        XCTAssertTrue(loaded.contains { $0.hasPrefix("liked podcasts: facade-pod-") }, "the fixture has a liked visible podcast")
        XCTAssertTrue(loaded.contains { $0.hasPrefix("album Blue Room|Ada: ") && !$0.hasSuffix("nil") })
        XCTAssertTrue(loaded.contains { $0.hasPrefix("artist named Ben: ") && !$0.hasSuffix("nil") }, "a second artist is found")

        let before = try await releaseForReal(library)
        let released = answers()
        XCTAssertEqual(released.count, loaded.count)
        for (lhs, rhs) in zip(released, loaded) { XCTAssertEqual(lhs, rhs) }
        assertNoLoadAndNoArrayRead(library, since: before, "the answers while released")
    }

    /// 放掉歌曲模型之后:「随机时连播」的相邻关系还在(放掉缓存之后从目录重算也一样);别的源里的另一份照样找得到;
    /// 有声与环境音的 id 集合原样留着,不会把空集合推给播放历史(那样旧记录会被当成音乐)。
    func testShuffleLinksOtherCopiesAndTheClassificationSetsSurviveARelease() async throws {
        let songs = Self.fixture(prefix: "kept")
        var copy = songs[0]
        copy.id = "kept-blue-1-copy"
        copy.sourceID = "dual-write-c"
        copy.filePath = "/Other/Blue Room/1.flac"
        let library = try makeTwin("kept", songs: songs, extra: [copy]).library
        library.songModelResidencyEnabled = true
        library.setShuffleLinked(songID: songs[1].id, direction: .next, isLinked: true)
        library.setShuffleLinked(songID: songs[2].id, direction: .previous, isLinked: true)
        await assertShadowMatches(library, "fixture")

        func links(_ step: String) -> [Bool] {
            let graph = library.shuffleLinkGraph
            return [graph.isLinked(songs[1].id, to: songs[2].id), graph.isLinked(songs[0].id, to: songs[1].id)]
        }
        func copies() -> [String: [String]] {
            library.otherCopies(of: [songs[0], songs[4]]).mapValues { $0.map(\.id) }
        }
        let linksBefore = links("loaded")
        XCTAssertEqual(linksBefore, [true, false])
        let copiesBefore = copies()
        XCTAssertEqual(copiesBefore, [songs[0].id: [copy.id]])
        let spokenWord = library.spokenWordSongIDs
        let ambient = library.ambientSongIDs
        let historySpokenWord = PlayHistoryStore.shared.spokenWordSongIDs
        let historyAmbient = PlayHistoryStore.shared.ambientSongIDs
        print("REPORT_CLASSIFICATION_SETS spokenWord=\(spokenWord.count) ambient=\(ambient.count) history=\(historySpokenWord.count)+\(historyAmbient.count)")
        XCTAssertFalse(spokenWord.isEmpty, "the fixture has an audiobook")

        guard await released(library, "release") else { return }
        XCTAssertEqual(library.spokenWordSongIDs, spokenWord)
        XCTAssertEqual(library.ambientSongIDs, ambient)
        XCTAssertEqual(
            PlayHistoryStore.shared.spokenWordSongIDs, historySpokenWord,
            "the release does not push an empty set to the play history"
        )
        XCTAssertEqual(PlayHistoryStore.shared.ambientSongIDs, historyAmbient)
        XCTAssertEqual(links("released"), linksBefore)
        XCTAssertEqual(copies(), copiesBefore)
        // 内存警告把能重建的缓存都放了:相邻关系从目录重算,答案相同。
        library.releaseRebuildableCaches()
        XCTAssertEqual(links("released, caches dropped"), linksBefore)
        XCTAssertFalse(library.isLoadingSongModelForTesting, "none of this asked for the model")

        let hold = await library.holdSongModel(.legacyPage)
        XCTAssertEqual(links("loaded again"), linksBefore)
        XCTAssertEqual(copies(), copiesBefore)
        XCTAssertEqual(library.spokenWordSongIDs, spokenWord)
        XCTAssertEqual(library.ambientSongIDs, ambient)
        hold.end()
    }

    /// 歌单的可见曲数与第一首在模型不在内存里时从目录答(停用、启用音乐源当场跟上);整张歌单的读法答不了时
    /// 给 nil,不是空。
    func testPlaylistCountsAndAnswerableReadsWithoutTheSongModel() async throws {
        let songs = Self.fixture(prefix: "counts")
        let library = try makeTwin("counts", songs: songs).library
        let playlist = library.createPlaylist(name: "Both", songIDs: [songs[0].id, songs[7].id, songs[1].id])
        await assertShadowMatches(library, "fixture")
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 2)
        XCTAssertEqual(library.storedSongsIfAnswerable(forPlaylist: playlist.id)?.map(\.id), [songs[0].id, songs[7].id, songs[1].id])

        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertTrue(library.isUsable)
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 2)
        XCTAssertEqual(library.songSummary(forPlaylist: playlist.id).first?.id, songs[0].id)
        XCTAssertEqual(library.storedSongsIfAnswerable(forPlaylist: playlist.id)?.map(\.id), [songs[0].id, songs[7].id, songs[1].id])
        library.updateDisabledSourceIDs([])
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 3)
        library.updateDisabledSourceIDs([Self.sourceA])
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 1)
        XCTAssertEqual(library.songSummary(forPlaylist: playlist.id).first?.id, songs[7].id)
        // 路上删掉的行不算在内。
        _ = library.deleteSongs([songs[7]])
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 0)

        await library.stopCatalogMirror()
        XCTAssertFalse(library.isUsable)
        XCTAssertNil(library.storedSongsIfAnswerable(forPlaylist: playlist.id), "cannot answer is not the same as empty")
        XCTAssertEqual(library.storedSongs(forPlaylist: playlist.id).count, 0, "the older read gives an empty array here")
        XCTAssertEqual(library.songCount(forPlaylist: playlist.id), 0)
    }

    // MARK: - Per-track consumers without the song model (P3 step 6c, unit 2a)

    /// 随机播放的加权(#332):歌曲模型放掉之后再算播放次数,给每首歌、每位歌手的次数与模型在内存里的同一座曲库
    /// 相同 —— 服务器记的次数沿用放掉之前扫出来的那份,本机有次数的歌按 id 问曲库目录(问过的记着)。不要歌曲
    /// 模型。目录也答不了时沿用上一次算好的,不把查不到当成「这些歌都不在了」。
    func testShuffleWeightingCountsAreTheSameOnceTheSongModelIsReleased() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        var songs = Self.fixture()
        songs[1].serverPlayCount = 9
        songs[4].serverPlayCount = 3
        songs[7].serverPlayCount = 5 // 停用源里的:不可见,不计
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let history = PlayHistoryStore(storeURL: directory.appendingPathComponent("shuffle-history.json"))
        let stranger = Song(id: "never-in-the-library", title: "Stranger", fileFormat: .flac,
                            filePath: "/nowhere.flac", sourceID: Self.sourceA)
        for (offset, song) in [songs[0], songs[0], songs[2], songs[5], songs[8], stranger].enumerated() {
            history.record(song: song, startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 400),
                           listenedSec: 120)
        }
        let store = ShufflePlayCountStore.shared
        func answers(_ counts: ShufflePlayCounts) -> [String] {
            var resolver = ShuffleArtistKeyResolver()
            return songs.map { song in
                let candidate = ShuffleWeighting.candidate(for: song, resolver: &resolver)
                return "\(song.id) song=\(counts.songPlayCount(candidate)) artist=\(counts.artistPlayCount(candidate))"
            }
        }
        let loaded = answers(store.playCounts(library: library, history: history))
        XCTAssertTrue(loaded[1].contains("song=9 "), "the server's count: \(loaded[1])")
        XCTAssertTrue(loaded[0].contains("song=2 "), "two local plays: \(loaded[0])")

        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertEqual(answers(store.playCounts(library: library, history: history)), loaded, "the same history, the model released")

        // 又放了一首(听歌记录前进一版,次数重算):与带着模型时多放这一首的结果相同。
        history.record(song: songs[5], startedAt: Date(timeIntervalSince1970: 1_800_010_000), listenedSec: 120)
        let afterOneMore = answers(store.playCounts(library: library, history: history))
        var expected = loaded
        let comp2 = try XCTUnwrap(songs.firstIndex { $0.id == songs[5].id })
        XCTAssertNotEqual(afterOneMore, loaded)
        XCTAssertNotEqual(afterOneMore[comp2], expected[comp2], "the song just played counts one more")
        expected[comp2] = afterOneMore[comp2]
        XCTAssertEqual(afterOneMore, expected, "nothing else moved")
        XCTAssertEqual(songModelHolds(of: library), [], "weighting asks for no song model")

        // 目录不再跟写:按 id 读此刻答不了。再放一首,次数沿用上一次算好的。
        await library.stopCatalogMirror()
        XCTAssertFalse(library.canAnswerSongLookups)
        history.record(song: songs[0], startedAt: Date(timeIntervalSince1970: 1_800_020_000), listenedSec: 120)
        XCTAssertEqual(answers(store.playCounts(library: library, history: history)), afterOneMore,
                       "unanswerable is not the same as absent")
        XCTAssertEqual(songModelHolds(of: library), [])
    }

    /// 「在听」小组件里的本机播客:曲库目录这条路与内存里的 `localPodcastSongs` 给出同样的单集、同样的先后
    /// (停用源里的不算)。歌曲模型放掉之后目录照样答;目录也答不了时是「答不了」(留着上次的快照),不是空的。
    /// 都不要歌曲模型。
    func testListeningWidgetLocalPodcastsFromTheCatalogMatchTheInMemoryList() async throws {
        let hidden = "dual-write-hidden"
        let library = makeLibrary(disabledSourceIDs: [hidden])
        var songs = Self.fixture()
        songs.append(Song(id: "hidden-episode", title: "Hidden Episode", albumTitle: "Weekly Show", artistName: "Host",
                          trackNumber: 3, duration: 900, fileFormat: .mp3, filePath: "/Podcasts/Weekly/3.mp3",
                          sourceID: hidden, genre: "Podcast"))
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB, hidden])
        await assertShadowMatches(library, "fixture")
        let publisher = ListeningWidgetPublisher(library: library, radioStations: { [] })
        let fromMemory = library.localPodcastSongs.map(ListeningWidgetPublisher.LocalEpisode.init)
        XCTAssertEqual(fromMemory.count, 2, "the two episodes of the enabled source")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let fromCatalog = await publisher.localPodcastEpisodes()
        XCTAssertEqual(fromCatalog, fromMemory)

        library.dropSongModelForMeasurement(includingCollections: true)
        let whileReleased = await publisher.localPodcastEpisodes()
        XCTAssertEqual(whileReleased, fromMemory, "the catalog answers the same without the model")
        XCTAssertEqual(songModelHolds(of: library), [], "the widget never asks for the song model")

        // 没有曲库目录的库:歌曲模型在内存里时读那份数组(同样的结果),放掉之后答不了。
        let bare = MusicLibrary(
            disabledSourceIDs: [hidden], storageDirectory: directory.appendingPathComponent("no-catalog"),
            artistNameConfiguration: .defaultValue, catalogMirroring: .disabled
        )
        libraries.append(bare)
        bare.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB, hidden])
        for _ in 0..<500 where bare.localPodcastSongs.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let barePublisher = ListeningWidgetPublisher(library: bare, radioStations: { [] })
        let fromTheArray = await barePublisher.localPodcastEpisodes()
        XCTAssertEqual(fromTheArray, fromMemory)
        bare.dropSongModelForMeasurement(includingCollections: true)
        let unanswerable = await barePublisher.localPodcastEpisodes()
        XCTAssertNil(unanswerable, "neither the catalog nor the model: no answer, not an empty list")
        XCTAssertEqual(songModelHolds(of: bare), [])
    }

    /// 播放器里「这一首属于哪本书、这本书有哪些章节」:歌曲模型在内存里时读内存里的归书表,放掉之后从曲库目录
    /// 按 id 问 —— 书 id、当前这本书的章节与先后、队列里属于这本书的条目都相同(按标签归的书、按文件夹归的书、
    /// 播客节目、音乐;停用源里的条目不算章节,也不从目录认)。不要歌曲模型。目录也答不了时退回只看标签的 id、
    /// 没有「当前这本书」。
    func testPlayerBooksFromTheCatalogMatchTheInMemoryGroupingOnceTheSongModelIsReleased() async throws {
        let hidden = "dual-write-hidden"
        let library = makeLibrary(disabledSourceIDs: [hidden])
        var songs = Self.fixture()
        // 没有专辑标签、靠文件夹归到一起的一本书;第 4 章在停用的源里。
        for chapter in 1...4 {
            songs.append(Song(
                id: "loose-\(chapter)", title: "Chapter \(chapter)", trackNumber: chapter, duration: 600,
                fileFormat: .m4a, filePath: "/Books/Loose/\(String(format: "%02d", chapter)).m4b",
                sourceID: chapter == 4 ? hidden : Self.sourceA
            ))
        }
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB, hidden])
        await assertShadowMatches(library, "fixture")
        let suite = "catalog-player-books-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func makePlayer(_ library: MusicLibrary, _ name: String) -> AudioPlayerService {
            let sessions = directory.appendingPathComponent(name, isDirectory: true)
            let musicMemory = MusicSessionMemoryStore(defaults: defaults, url: sessions.appendingPathComponent("music-memory.json"))
            addTeardownBlock { @MainActor in await musicMemory.waitForPendingPersistence() }
            return AudioPlayerService(
                library: library,
                playbackSettings: PlaybackSettingsStore(defaults: defaults),
                playbackSessionStore: PlaybackSessionStore(url: sessions.appendingPathComponent("session.json")),
                musicSessionMemoryStore: musicMemory,
                queueBookmarkStore: QueueBookmarkStore(directory: sessions.appendingPathComponent("bookmarks")),
                activateAudioSession: { _ in XCTFail("Book lookups must not start audio") }
            )
        }
        let player = makePlayer(library, "player-books")

        let shelf = library.spokenWordSongs
        let podcasts = library.localPodcastSongs
        let hiddenChapter = try XCTUnwrap(songs.first { $0.id == "loose-4" })
        let music = try XCTUnwrap(library.musicSongs.first)
        XCTAssertGreaterThanOrEqual(shelf.count, 6)
        XCTAssertEqual(podcasts.count, 2)
        XCTAssertFalse(shelf.contains { $0.id == hiddenChapter.id })
        let probes = shelf + podcasts + [music, hiddenChapter]
        struct Answer: Equatable {
            var bookIDs: [String] = []
            var currentBooks: [[String]?] = []
            var queueItems: [[String]] = []
        }
        func ask(_ player: AudioPlayerService) -> Answer {
            var answer = Answer()
            answer.bookIDs = probes.map { player.spokenWordBookID(for: $0) }
            player.setQueue(shelf + [music], startAt: 0)
            for song in shelf {
                player.currentSong = song
                player.currentItemIsSpokenWord = true
                answer.currentBooks.append(player.currentSpokenWordBook?.items.map(\.id))
                answer.queueItems.append(player.currentBookItemIDs)
            }
            return answer
        }
        let loaded = ask(player)
        let looseIDs = ["loose-1", "loose-2", "loose-3"]
        XCTAssertTrue(loaded.currentBooks.contains(looseIDs), "the folder book has its three visible chapters: \(loaded.currentBooks)")
        XCTAssertEqual(Set(looseIDs.map { id in loaded.bookIDs[try! XCTUnwrap(probes.firstIndex { $0.id == id })] }).count, 1)

        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertTrue(library.spokenWordBookIDs.isEmpty, "the in-memory grouping is gone")
        let released = ask(player)
        XCTAssertEqual(released.bookIDs, loaded.bookIDs)
        XCTAssertEqual(released.currentBooks, loaded.currentBooks)
        XCTAssertEqual(released.queueItems, loaded.queueItems)
        XCTAssertEqual(songModelHolds(of: library), [], "book lookups ask for no song model")

        // 没有曲库目录的库放掉歌曲模型之后:归书退回只看标签的 id,没有「当前这本书」;仍然不要歌曲模型。
        let bare = MusicLibrary(
            disabledSourceIDs: [hidden], storageDirectory: directory.appendingPathComponent("no-catalog"),
            artistNameConfiguration: .defaultValue, catalogMirroring: .disabled
        )
        libraries.append(bare)
        bare.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB, hidden])
        for _ in 0..<500 where bare.spokenWordSongs.count < shelf.count { try await Task.sleep(for: .milliseconds(10)) }
        let barePlayer = makePlayer(bare, "bare-player-books")
        XCTAssertEqual(ask(barePlayer), loaded, "the same library without a catalog groups the same from memory")
        bare.dropSongModelForMeasurement(includingCollections: true)
        let unanswerable = ask(barePlayer)
        XCTAssertEqual(unanswerable.bookIDs, probes.map { SpokenWordBookGrouping.bookID(for: SpokenWordBookItem(song: $0)) })
        XCTAssertTrue(unanswerable.currentBooks.allSatisfy { $0 == nil })
        XCTAssertEqual(songModelHolds(of: bare), [])
    }

    /// 曲终记不记进本机听歌记录(跟着计入规则时):播放器交来的那一份没有时长(Apple Music 等放了才知道)时,
    /// 看曲库里那一行的时长。歌曲模型放掉之后按 id 问曲库目录,答案与模型在内存里时相同;不要歌曲模型。
    func testListenRuleReadsTheLibraryDurationByIDOnceTheSongModelIsReleased() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let stored = songs[0]
        XCTAssertEqual(stored.duration, 180)
        var handedOver = stored
        handedOver.duration = 0
        let history = PlayHistoryStore(
            storeURL: directory.appendingPathComponent("listen-rule-history.json"),
            localListenRule: { (ListenCountRule(percent: 80, countsAfterFourMinutes: false), true) }
        )
        history.refreshClassification(library: library)
        func recordsListen(after seconds: TimeInterval) -> Bool {
            let before = history.entries.count
            history.beginSession(song: handedOver)
            history.tick(playedDelta: seconds)
            history.endSession()
            return history.entries.count > before
        }
        // 曲库里那一行 180 秒:听 60 秒不到八成,不记;听 150 秒记。
        XCTAssertFalse(recordsListen(after: 60))
        XCTAssertTrue(recordsListen(after: 150))

        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)
        XCTAssertFalse(recordsListen(after: 60), "the library's 180 seconds still count, not an unknown duration")
        XCTAssertTrue(recordsListen(after: 150))
        XCTAssertEqual(songModelHolds(of: library), [], "the listen rule asks for no song model")
    }

    /// 场景切换、后台和系统唤醒时起的活儿(P3 步骤 6c 单元 2b):模型在内存里时当场执行,不问有没有活儿,
    /// 也不占用;放掉之后没有活儿什么也不要(回调等着模型),有活儿才占用一次、请模型装回来,回调仍等发布。
    func testBackgroundWorkAsksForTheSongModelOnlyWhenThereIsWork() async throws {
        let library = makeLibrary()
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let handled = Tally()
        let asked = Tally()

        library.onReady(holding: .scan, ifThereIsWork: {
            asked.count += 1
            return true
        }) { handled.count += 1 }
        library.requestSongModel(for: .backfill, ifThereIsWork: {
            asked.count += 1
            return true
        })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handled.count, 1, "loaded: the work starts at once")
        XCTAssertEqual(asked.count, 0, "loaded: whether there is work is not even asked")
        XCTAssertEqual(songModelHolds(of: library), [])

        library.dropSongModelForMeasurement(includingCollections: true)
        library.onReady(holding: .scan, ifThereIsWork: {
            asked.count += 1
            return false
        }) { handled.count += 1 }
        library.requestSongModel(for: .scraper, ifThereIsWork: { false })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(handled.count, 1, "released: the work waits for the model")
        XCTAssertEqual(songModelHolds(of: library), [], "no work: no song model is asked for")

        library.onReady(holding: .backgroundDrain) { handled.count += 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(songModelHolds(of: library), [.backgroundDrain], "work: one request for the song model")
        XCTAssertEqual(handled.count, 1, "the work still starts only once the model is back")
    }

    /// Spotlight 收录(P3 步骤 6c 单元 2b):专辑、艺人从目录按键分页取,与内存里的整库数组得出同样的条目与签名
    /// (停用源里的不算)。生产路径在歌曲模型在内存里时用它的数组、不从目录另取一层;放掉之后才从目录分页取,
    /// 答出同一份,不要歌曲模型。歌单的歌数这里不比:放掉之后的歌单计数由残留态单元从目录答(这个检出还没有)。
    func testSpotlightItemsFromTheCatalogMatchTheInMemoryGroupsAndNeedNoSongModel() async throws {
        let library = makeLibrary(disabledSourceIDs: [Self.sourceB])
        library.addSongs(Self.fixture(), affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let memoryRecords = await SpotlightIndexService.preparedRecordsForTesting(library: library, catalogGroups: false)
        let catalogRecords = await SpotlightIndexService.preparedRecordsForTesting(library: library, catalogGroups: true)
        let fromMemory = try XCTUnwrap(memoryRecords)
        let fromCatalog = try XCTUnwrap(catalogRecords)
        XCTAssertEqual(fromCatalog, fromMemory)
        XCTAssertTrue(fromCatalog.keys.contains { $0.hasPrefix("album:") })
        XCTAssertTrue(fromCatalog.keys.contains { $0.hasPrefix("artist:") })
        let pagedBefore = SpotlightIndexService.catalogGroupPagingCountForTesting
        let loadedProduction = await SpotlightIndexService.productionRecordsForTesting(library: library)
        XCTAssertEqual(try XCTUnwrap(loadedProduction), fromMemory)
        XCTAssertEqual(SpotlightIndexService.catalogGroupPagingCountForTesting, pagedBefore,
                       "with the model loaded the production path takes its arrays and pages nothing from the catalog")

        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        library.dropSongModelForMeasurement(includingCollections: true)
        let releasedRecords = await SpotlightIndexService.preparedRecordsForTesting(library: library, catalogGroups: true)
        let whileReleased = try XCTUnwrap(releasedRecords)
        // 生产路径:放掉之后目录答得出(曲库仍可用),专辑、艺人从目录分页取一次,发布的条目相同。
        let releasedProduction = await SpotlightIndexService.productionRecordsForTesting(library: library)
        XCTAssertEqual(withoutPlaylists(try XCTUnwrap(releasedProduction)), withoutPlaylists(fromMemory))
        XCTAssertEqual(SpotlightIndexService.catalogGroupPagingCountForTesting, pagedBefore + 1, "paged once")
        func withoutPlaylists(_ records: [String: String]) -> [String: String] {
            records.filter { !$0.key.hasPrefix("playlist:") }
        }
        XCTAssertEqual(withoutPlaylists(whileReleased), withoutPlaylists(fromMemory),
                       "the catalog answers the same songs, albums and artists without the model")
        XCTAssertEqual(songModelHolds(of: library), [])
    }

    /// CloudKit 发送(P3 步骤 6c 单元 2b):歌单记录拼的是小状态与按 id 的歌。拼得出时照常;曲库此刻答不了时这一条
    /// 是「此刻答不了」—— 留在待发里,不发一条只带空身份的记录,也不当成本机已经删了。都不要歌曲模型。
    /// 放掉之后目录答得出时照样拼出来(成员身份与装着时相同,见真放掉的那条测试);目录也答不了时才是「此刻答不了」。
    func testCloudKitSendKeepsARecordThatCannotBeBuiltNowPendingInsteadOfSendingStubIdentities() async throws {
        let library = makeLibrary()
        let songs = Self.fixture()
        library.addSongs(songs, affectedSourceIDs: [Self.sourceA, Self.sourceB])
        await assertShadowMatches(library, "fixture")
        let playlist = library.createPlaylist(name: "Cloud send")
        library.add(songIDs: [songs[0].id, songs[1].id], toPlaylist: playlist.id)
        let suite = "cloud-send-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources")),
            radioStationsStore: RadioStationsStore(storeURL: directory.appendingPathComponent("radio.json")),
            scraperSettingsStore: ScraperSettingsStore(defaults: defaults)
        )
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        guard case .built(let record) = sync.recordBuildOutcomeForTesting(
            recordType: CloudKitSyncService.RecordType.playlist, localID: playlist.id
        ) else { return XCTFail("the loaded library builds the playlist record") }
        XCTAssertEqual(record["songIDs"] as? [String], [songs[0].id, songs[1].id])
        XCTAssertNotNil(record[CloudKitSyncService.songIdentitiesField], "with the members' identities")
        if case .gone = sync.recordBuildOutcomeForTesting(recordType: CloudKitSyncService.RecordType.playlist, localID: "no-such-playlist") {
        } else {
            XCTFail("a playlist that no longer exists is gone")
        }

        library.dropSongModelForMeasurement(includingCollections: true)
        guard case .built = sync.recordBuildOutcomeForTesting(
            recordType: CloudKitSyncService.RecordType.playlist, localID: playlist.id
        ) else { return XCTFail("released but usable: built from the catalog") }
        await library.stopCatalogMirror()
        XCTAssertFalse(library.isUsable)
        guard case .cannotAnswerNow = sync.recordBuildOutcomeForTesting(
            recordType: CloudKitSyncService.RecordType.playlist, localID: playlist.id
        ) else { return XCTFail("cannot answer now: the record stays pending, never a stub") }
        XCTAssertEqual(songModelHolds(of: library), [], "building records asks for no song model")
    }

    // MARK: - P3 step 6c, unit 2c: real releases (the residency machinery, not the measurement hook)

    /// 设备上抓到的读者(6c 单元 2c),歌曲模型真放掉之后:书架的有声条目答「答不了」(不发空书架);盯音乐数组的
    /// 监视器只盯就绪,装回来时回调;系统按 id 要歌从目录答出与装着时相同的歌。都不装模型、不读整库数组。
    func testReadersTheDeviceRunCaughtNeitherLoadTheSongModelNorReadItsArrays() async throws {
        let songs = Self.fixture(prefix: "device-readers")
        let (library, _) = try makeLaunchedTwin("device-readers", songs: songs)
        await assertShadowMatches(library, "fixture")
        let ids = [songs[0].id, songs[4].id, "no-such-song"]
        let loadedSongs = await PrimuseLibrarySongQuery.playableSongs(forIdentifiers: ids, in: library)
        XCTAssertEqual(loadedSongs.map(\.id), [songs[0].id, songs[4].id])
        XCTAssertNotNil(SpokenWordCollection.books.songsIfLoaded(in: library))
        let watcher = LibraryMusicSongsWatcher()
        let fired = Tally()
        watcher.watch(library) { fired.count += 1 }

        let before = try await releaseForReal(library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(SpokenWordCollection.books.songsIfLoaded(in: library), "the shelf cannot answer: the last one stays")
        let releasedSongs = await PrimuseLibrarySongQuery.playableSongs(forIdentifiers: ids, in: library)
        XCTAssertEqual(releasedSongs.map(\.id), loadedSongs.map(\.id), "by id from the catalog, as when loaded")
        assertNoLoadAndNoArrayRead(library, since: before, "readers while released")

        let firedWhileReleased = fired.count
        let hold = await library.holdSongModel(.legacyPage)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(fired.count, firedWhileReleased, "the watcher fires once the model is back")
        hold.end()
    }

    /// 2b 的真放掉测试:歌曲模型放掉、曲库照样可用时,CloudKit 的歌单记录从目录拼出与装着时相同的成员身份;Spotlight
    /// 的生产路径从目录分页取专辑、艺人(只取一次),发布的条目与装着时相同(歌单的歌数也由目录答)。都不装模型、
    /// 不读整库数组。
    func testWithTheSongModelReallyReleasedCloudKitAndSpotlightAnswerTheSameFromTheCatalog() async throws {
        let songs = Self.fixture(prefix: "released-sync")
        let (library, _) = try makeLaunchedTwin("released-sync", songs: songs)
        let playlist = library.createPlaylist(name: "Cloud send", songIDs: [songs[0].id, songs[4].id])
        await assertShadowMatches(library, "fixture")
        let suite = "released-sync-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: SourcesStore(storageDirectoryURL: directory.appendingPathComponent("released-sync-sources")),
            radioStationsStore: RadioStationsStore(storeURL: directory.appendingPathComponent("released-sync-radio.json")),
            scraperSettingsStore: ScraperSettingsStore(defaults: defaults)
        )
        // 身份信封按值比:JSON 里键的先后每次编码可能不同,字节不一定相同。
        func playlistRecord() -> (songIDs: [String]?, identities: [SongIdentity]?)? {
            guard case .built(let record) = sync.recordBuildOutcomeForTesting(
                recordType: CloudKitSyncService.RecordType.playlist, localID: playlist.id
            ) else { return nil }
            let envelope = (record[CloudKitSyncService.songIdentitiesField] as? Data)
                .flatMap { try? JSONDecoder().decode(PlaylistCloudSyncEnvelope.self, from: $0) }
            return (record["songIDs"] as? [String], envelope?.songIdentities)
        }
        let loadedRecord = try XCTUnwrap(playlistRecord())
        XCTAssertEqual(loadedRecord.identities?.map(\.songID), [songs[0].id, songs[4].id])
        let loadedSpotlightRecords = await SpotlightIndexService.productionRecordsForTesting(library: library)
        let loadedSpotlight = try XCTUnwrap(loadedSpotlightRecords)
        let pagedBefore = SpotlightIndexService.catalogGroupPagingCountForTesting

        let before = try await releaseForReal(library)
        let releasedRecord = try XCTUnwrap(playlistRecord(), "built from the catalog, not kept pending")
        XCTAssertEqual(releasedRecord.songIDs, loadedRecord.songIDs)
        XCTAssertEqual(releasedRecord.identities, loadedRecord.identities, "the same member identities")
        let releasedSpotlightRecords = await SpotlightIndexService.productionRecordsForTesting(library: library)
        XCTAssertEqual(SpotlightIndexService.catalogGroupPagingCountForTesting, pagedBefore + 1, "paged once")
        XCTAssertEqual(try XCTUnwrap(releasedSpotlightRecords), loadedSpotlight)
        assertNoLoadAndNoArrayRead(library, since: before, "sync inputs while released")
    }

    /// 2b-1 的真放掉测试:场景切换、系统唤醒起的活儿,歌曲模型放掉之后没活儿时什么也不要、回调等着;有活儿就请模型装回来,
    /// 装回来时回调照常执行(连同先前等着的),请求的那份占用随后放手,模型又放得掉。
    func testABackgroundStartWithWorkLoadsTheReleasedSongModelAndRunsItsHandlers() async throws {
        let songs = Self.fixture(prefix: "wake")
        let (library, _) = try makeLaunchedTwin("wake", songs: songs)
        await assertShadowMatches(library, "fixture")
        let before = try await releaseForReal(library)
        let handled = Tally()
        library.onReady(holding: .scan, ifThereIsWork: { false }) { handled.count += 1 }
        try await Task.sleep(for: .milliseconds(150))
        assertNoLoadAndNoArrayRead(library, since: before, "no work")
        XCTAssertEqual(handled.count, 0, "the handler waits for the model")

        library.onReady(holding: .backgroundDrain) { handled.count += 10 }
        try await waitUntilReady(library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handled.count, 11, "both handlers ran at the load")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        let again = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        if case .skipped(let why) = again {
            XCTAssertFalse(why.hasPrefix("hold("), "the requesting hold has ended: \(why)")
        }
    }

    /// 2b-1 的真放掉测试:一轮扫描跑着时占着歌曲模型,这时放掉被拒(理由是那份占用);扫描连同收尾放手之后就不再因占用而拒。
    func testARunningScanHoldsTheSongModelAndRefusesItsRelease() async throws {
        let songs = Self.fixture(prefix: "scan-hold")
        let (library, _) = try makeLaunchedTwin("scan-hold", songs: songs)
        await assertShadowMatches(library, "fixture")
        library.songModelResidencyEnabled = true
        var source = MusicSource(id: "scan-hold-\(UUID().uuidString)", name: "Gated", type: .webdav)
        source.extraConfig = MusicSource.encodeScannedDirectories(["/Music"], into: nil, type: source.type)
        let root = directory.appendingPathComponent("scan-hold-state", isDirectory: true)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let connector = GatedListingConnector(sourceID: source.id)
        let scan = ScanService(fileManager: RootedTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        defer { scan.cancelAllActiveScans() }
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library,
                                      sourceStore: store, requestsContinuedProcessing: false))
        let deadline = Date().addingTimeInterval(10)
        while await connector.listings == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(songModelHolds(of: library).contains(.scan))
        let refused = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(refused, .skipped("hold(scan)"), "the running scan holds the model")
        XCTAssertTrue(library.isReady)

        await connector.open()
        while scan.scanStates[source.id]?.isScanning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        var outcome = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        while case .skipped(let why) = outcome, why.hasPrefix("hold("), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            outcome = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        }
        if case .skipped(let why) = outcome {
            XCTAssertFalse(why.hasPrefix("hold("), "the scan and its follow-up let go: \(why)")
        }
    }

    /// 2a 的真放掉测试:歌曲模型放掉之后队列放到最后一首,相似续播占用一次、把模型装回来,占用拿到之后照常把相似的歌接上,
    /// 不把这一首记成死胡同。
    func testAutoContinuationAfterARealReleaseLoadsTheModelOnceAndAppends() async throws {
        let songs = Self.fixture(prefix: "continuation")
        let (library, _) = try makeLaunchedTwin("continuation", songs: songs)
        await assertShadowMatches(library, "fixture")
        let suite = "continuation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("continuation-session.json")),
            activateAudioSession: { _ in XCTFail("Queue tests must not start audio") }
        )
        player.shuffleEnabled = false
        player.repeatMode = .off
        let before = try await releaseForReal(library)

        player.setQueue([songs[0]], startAt: 0)
        XCTAssertEqual(player.autoContinuationDecision, .similarSongs)
        if player.autoContinuationTask == nil { player.scheduleAutoContinuationIfNeeded() }
        await player.autoContinuationTask?.value
        XCTAssertTrue(library.isReady, "the continuation's hold loaded the model")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertGreaterThan(player.queueCount, 1, "similar songs appended after the hold returned")
        XCTAssertNil(player.autoContinuationDeadEndEntryID)
        player.resetAutoContinuation()
    }

    // MARK: - P3 step 6c, unit 3: launch reads

    /// 启动时的入口计数与对账(6c 单元 3):MV 条数在目录上数(资料库入口、Mac 侧栏的计数模型),与内存里的
    /// `musicVideoSongs` 相同;启动时按源数歌、找出源已不在的那些,目录数出的与整库数组的相同。歌曲模型真放掉之后
    /// 两样都从目录答出同样的结果,不装模型、不读整库数组。
    func testLaunchCountsComeFromTheCatalogWithTheSameAnswersWhileReleased() async throws {
        var songs = Self.fixture(prefix: "launch-counts")
        songs[0].mvPath = "/Videos/blue-1.mp4"
        songs[4].mvPath = "/Videos/comp-1.mp4"
        let (library, _) = try makeLaunchedTwin("launch-counts", songs: songs)
        await assertShadowMatches(library, "fixture")
        let memoryVideos = library.musicVideoSongs.count
        XCTAssertEqual(memoryVideos, 2)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let catalogVideos = try await reader.read { try $0.musicVideoSongCount() }
        XCTAssertEqual(catalogVideos, memoryVideos)
        let hub = try XCTUnwrap(LibraryHubCatalogCountsModel.shared(for: library))
        for _ in 0..<250 where hub.readableCounts?.musicVideos != memoryVideos {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(hub.readableCounts?.musicVideos, memoryVideos, "the hub and the Mac sidebar read this")

        // 只认得源 A:源 B 的歌是「源不在了」的那一类;源 B 停用着,停用的源也数。
        let sources = [MusicSource(id: Self.sourceA, name: "A", type: .local)]
        let fromArrays = await AppServices.startupReconciliation(library: library, sources: sources)
        let fromCatalog = await AppServices.catalogStartupReconciliation(library: library, sources: sources)
        XCTAssertNotNil(fromArrays)
        XCTAssertEqual(fromCatalog, fromArrays, "the catalog counts every source as the arrays do")
        XCTAssertEqual(fromArrays?.staleSourceIDsWithSongs, [Self.sourceB])

        let before = try await releaseForReal(library)
        let released = await AppServices.startupReconciliation(library: library, sources: sources)
        XCTAssertEqual(released, fromArrays, "released: counted from the catalog")
        let releasedVideos = try await reader.read { try $0.musicVideoSongCount() }
        XCTAssertEqual(releasedVideos, memoryVideos)
        assertNoLoadAndNoArrayRead(library, since: before, "launch counts while released")
    }

    /// 动态封面的孤儿专辑(6c 单元 3b):删歌之后哪些专辑一首都不剩,模型在内存里时看整库数组,真放掉之后问目录
    /// (任一源,含停用源),答案相同,不装模型、不读整库数组。
    func testMotionCoverOrphanAlbumsComeFromTheCatalogWhileReleased() async throws {
        let songs = Self.fixture(prefix: "motion-orphans")
        let (library, _) = try makeLaunchedTwin("motion-orphans", songs: songs)
        await assertShadowMatches(library, "fixture")
        // 曲库给每首歌定的专辑 id(源 B 停用着,它的歌也在里面)。
        let present = Set(songs.compactMap { library.storedSong(id: $0.id)?.albumID })
        XCTAssertFalse(present.isEmpty)
        let candidates = present.union(["motion-orphans-gone"])
        let loaded = await MotionCoverStore.orphanedAlbums(among: candidates, library: library)
        XCTAssertEqual(loaded, ["motion-orphans-gone"])

        let before = try await releaseForReal(library)
        let released = await MotionCoverStore.orphanedAlbums(among: candidates, library: library)
        XCTAssertEqual(released, loaded, "the catalog answers as the arrays did")
        assertNoLoadAndNoArrayRead(library, since: before, "motion-cover orphan check")
    }

    /// 云账号合并时把多余挂载上的歌改挂到留下的那份(6c 单元 3b):真放掉之后多余的挂载上没歌就不装模型;有歌才拿
    /// `.migration` 占用装回来改挂,改完与模型一直在内存里时改出来的相同,目录跟着一致。
    func testCloudAccountMergeRepointsOnlyWithAHoldWhenTheCatalogFindsSongs() async throws {
        let songs = Self.fixture(prefix: "account-merge")
        let movedCount = songs.filter { $0.sourceID == Self.sourceB }.count
        let (loadedLibrary, _) = try makeLaunchedTwin("account-merge-loaded", songs: songs)
        await assertShadowMatches(loadedLibrary, "fixture, loaded")
        let loaded = await CloudAccountMigrationService.repointSongs(from: [Self.sourceB], to: Self.sourceA, library: loadedLibrary)
        XCTAssertEqual(loaded, movedCount)
        func placements(_ library: MusicLibrary) -> [String: String] {
            Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0.sourceID) })
        }
        let loadedPlacements = placements(loadedLibrary)
        XCTAssertFalse(loadedPlacements.values.contains(Self.sourceB))

        let (library, _) = try makeLaunchedTwin("account-merge-released", songs: songs)
        await assertShadowMatches(library, "fixture, released")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let before = try await releaseForReal(library)
        let none = await CloudAccountMigrationService.repointSongs(from: ["account-merge-empty-mount"], to: Self.sourceA, library: library)
        XCTAssertEqual(none, 0, "no songs on that mount: nothing to repoint")
        assertNoLoadAndNoArrayRead(library, since: before, "an empty redundant mount")
        XCTAssertFalse(songModelHolds(of: library).contains(.migration))

        let released = await CloudAccountMigrationService.repointSongs(from: [Self.sourceB], to: Self.sourceA, library: library)
        XCTAssertEqual(released, movedCount)
        XCTAssertTrue(songModelHolds(of: library).contains(.migration), "songs to repoint: the migration hold loads the model")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertEqual(placements(library), loadedPlacements, "the same repoint as with the model loaded")
        await assertShadowMatches(library, "after the repoint")
    }

    /// 手改标签的启动那一轮(6c 单元 3b):模型在内存里时与以前相同,补记上线前手改过的行。真放掉之后记录都套过了就
    /// 不装模型、不读整库数组;有打着标记却没记录的行时拿 `.launchMaintenance` 占用装回来,补记出的与模型在内存里时相同。
    func testTagEditLaunchPassHoldsTheSongModelOnlyWhenThereIsWork() async throws {
        var songs = Self.fixture(prefix: "tag-launch")
        songs[1].title = "Blue Two (edited)"
        songs[1].userMetadataEditedAt = Date(timeIntervalSince1970: 1_700_000_100)
        songs[10].albumTitle = "Long Story (edited)"
        songs[10].userMetadataEditedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let (library, _) = try makeLaunchedTwin("tag-launch", songs: songs)
        await assertShadowMatches(library, "fixture")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        let loadedStore = SongTagEditStore(fileURL: directory.appendingPathComponent("tag-launch-loaded.json"))
        loadedStore.attach(library: library)
        let loadedPass = await loadedStore.launchPass?.value
        XCTAssertEqual(loadedPass, .inTheModel)
        XCTAssertEqual(Set(loadedStore.entries.keys), [songs[1].id, songs[10].id], "the earlier hand edits are recorded")

        let before = try await releaseForReal(library)
        let nothing = await loadedStore.runLaunchPass()
        XCTAssertEqual(nothing, .nothingToDo)
        assertNoLoadAndNoArrayRead(library, since: before, "every record applied")
        XCTAssertFalse(songModelHolds(of: library).contains(.launchMaintenance))

        let releasedStore = SongTagEditStore(fileURL: directory.appendingPathComponent("tag-launch-released.json"))
        releasedStore.attach(library: library)
        let releasedPass = await releasedStore.launchPass?.value
        XCTAssertEqual(releasedPass, .heldTheModel)
        XCTAssertTrue(songModelHolds(of: library).contains(.launchMaintenance))
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertEqual(releasedStore.entries, loadedStore.entries, "the same records as with the model loaded")
    }

    /// 收藏的启动与事件那几样(6c 单元 3b):收藏的书在哪些源上从目录书架答出与整份有声条目相同的;迁移过的
    /// 收藏启动时不要模型;还没迁移而库里有歌时拿 `.migration` 占用做一次;模型不在时到来的喜欢不被空列表吞掉,
    /// 装回来时照常排进收藏。
    func testFavoriteCollectionLaunchWorkWhileReleased() async throws {
        let songs = Self.fixture(prefix: "favorites-launch")
        let (library, _) = try makeLaunchedTwin("favorites-launch", songs: songs)
        await assertShadowMatches(library, "fixture")
        let bookIDs = Set(library.spokenWordBookIDs.values)
        XCTAssertFalse(bookIDs.isEmpty)
        let loadedAnswer = await FavoriteCollectionStore.sourcesByBook(bookIDs, library: library)
        let loadedBooks = try XCTUnwrap(loadedAnswer)
        XCTAssertEqual(Set(loadedBooks.keys), bookIDs)
        let album = try XCTUnwrap(library.visibleAlbums.first)
        func makeDefaults(_ name: String) throws -> UserDefaults {
            let suite = "favorites-launch-\(name)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            return defaults
        }
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }

        let before = try await releaseForReal(library)
        let releasedBooks = await FavoriteCollectionStore.sourcesByBook(bookIDs, library: library)
        XCTAssertEqual(releasedBooks, loadedBooks, "the catalog shelf answers as the arrays did")
        let migratedDefaults = try makeDefaults("migrated")
        migratedDefaults.set(true, forKey: FavoriteCollectionStore.migrationKey)
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("favorites-launch-likes.json"))
        let migrated = FavoriteCollectionStore(defaults: migratedDefaults, favorites: likes,
                                               cloud: CloudKVSSync(store: nil, defaults: migratedDefaults, observing: nil))
        migrated.start(library: library)
        // 模型不在时点上的喜欢:不消化,等装回来。
        likes.setLiked(true, album: album)
        try await Task.sleep(for: .milliseconds(700))
        assertNoLoadAndNoArrayRead(library, since: before, "books, a migrated collection and a like while released")
        XCTAssertFalse(songModelHolds(of: library).contains(.migration))
        let albumPin = QuickAccessPinReference(kind: .album, itemID: album.id)
        func pins(_ defaults: UserDefaults) -> [QuickAccessPinReference] {
            LibraryPinStorage.decode(defaults.string(forKey: LibraryPinStorage.defaultsKey) ?? "")
        }
        XCTAssertFalse(pins(migratedDefaults).contains(albumPin), "the like waits for the model")

        let freshDefaults = try makeDefaults("fresh")
        let fresh = FavoriteCollectionStore(
            defaults: freshDefaults,
            favorites: LibraryFavoritesStore(fileURL: directory.appendingPathComponent("favorites-launch-fresh.json")),
            cloud: CloudKVSSync(store: nil, defaults: freshDefaults, observing: nil)
        )
        fresh.start(library: library)
        let deadline = Date().addingTimeInterval(10)
        while !freshDefaults.bool(forKey: FavoriteCollectionStore.migrationKey), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(freshDefaults.bool(forKey: FavoriteCollectionStore.migrationKey), "the migration ran under its hold")
        XCTAssertTrue(songModelHolds(of: library).contains(.migration))
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        while !pins(migratedDefaults).contains(albumPin), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(pins(migratedDefaults).contains(albumPin), "the waiting like is placed once the model is back")
    }

    /// 本机导入续扫前的时长检查(6c 单元 3b-2):模型在内存里时逐首看整库,真放掉之后问目录(按源,含停用源),答案相同,
    /// 不装模型、不读整库数组。
    func testLocalImportDurationCheckComesFromTheCatalogWhileReleased() async throws {
        var songs = Self.fixture(prefix: "import-durations")
        songs[3].duration = 0
        let (library, _) = try makeLaunchedTwin("import-durations", songs: songs)
        await assertShadowMatches(library, "fixture")
        let loadedA = await AppServices.sourceHasIncompleteDurations(Self.sourceA, library: library)
        let loadedB = await AppServices.sourceHasIncompleteDurations(Self.sourceB, library: library)
        XCTAssertEqual(loadedA, true)
        XCTAssertEqual(loadedB, false)

        let before = try await releaseForReal(library)
        let releasedA = await AppServices.sourceHasIncompleteDurations(Self.sourceA, library: library)
        let releasedB = await AppServices.sourceHasIncompleteDurations(Self.sourceB, library: library)
        XCTAssertEqual(releasedA, loadedA)
        XCTAssertEqual(releasedB, loadedB)
        assertNoLoadAndNoArrayRead(library, since: before, "local-import duration check")
    }

    /// Siri 与快捷指令按名字找歌、进书(6c 单元 3b-2):真放掉之后从目录的候选与分书答出与模型在内存里时相同的歌、
    /// 同一本书与起点,有声条目、环境音也一样;不装模型(45 万首时 8 秒内装不完)、不读整库数组。
    func testSiriLookupsAnswerFromTheCatalogWithTheSameResultsWhileReleased() async throws {
        let songs = Self.fixture(prefix: "siri-lookups")
        let (library, _) = try makeLaunchedTwin("siri-lookups", songs: songs)
        await assertShadowMatches(library, "fixture")
        let chapters = Array(songs[10...12])
        struct Answers: Equatable {
            var named: [String]
            var spokenNamed: [String]
            var ambient: [String]
            var hasSongs: Bool
            var chapterStart: String?
            var chapterItem: String?
            var bookStart: String?
            var bookSongs: [String]
            var bookIndex: Int?
        }
        func answers() async -> Answers {
            let named = await PrimuseLibrarySongQuery.songs(matching: "Blue 2", in: library).map(\.id)
            let spokenNamed = await PrimuseLibrarySongQuery.songs(matching: "Chapter 2", in: library).map(\.id)
            let rainQuery = SiriMediaSearchQuery(kind: .song, mediaName: "Rain")
            let ambientPool = await AppServices.ambientSongsForIntent(rainQuery, library: library)
            let ambient = SiriMediaSearchResolver.resolvePreferringMusic(
                query: rainQuery, musicSongs: ambientPool, spokenWordSongs: []
            )?.queue.map(\.id) ?? []
            let hasSongs = await AppServices.libraryHasVisibleSongsForIntent(library)
            let named2 = await AppServices.siriSpokenWordStartAnswering(forFound: [chapters[1]], namesItem: true, library: library)
            let whole = await AppServices.siriSpokenWordStartAnswering(forFound: chapters, namesItem: false, library: library)
            let start = await AppServices.spokenWordBookStartAnswering(
                bookID: whole?.book.id ?? "", from: chapters[1].id, library: library
            )
            return Answers(named: named, spokenNamed: spokenNamed, ambient: ambient, hasSongs: hasSongs,
                           chapterStart: named2?.book.id, chapterItem: named2?.itemID, bookStart: whole?.book.id,
                           bookSongs: start?.songs.map(\.id) ?? [], bookIndex: start?.index)
        }
        let loaded = await answers()
        XCTAssertEqual(loaded.named.first, songs[1].id)
        XCTAssertEqual(loaded.spokenNamed.first, chapters[1].id)
        // 「Rain」是环境音时由环境音那一路找到;不是时两边都找不到,照样比两边相同。
        XCTAssertEqual(loaded.ambient.isEmpty, library.ambientSongs.isEmpty)
        XCTAssertTrue(loaded.hasSongs)
        XCTAssertNotNil(loaded.chapterStart)
        XCTAssertEqual(loaded.chapterItem, chapters[1].id)
        XCTAssertEqual(loaded.bookStart, loaded.chapterStart)
        XCTAssertEqual(loaded.bookSongs, chapters.map(\.id))
        XCTAssertEqual(loaded.bookIndex, 1)

        let loadedBooks = AppServices.siriSpokenWordBooks(in: library).map { "\($0.id) \($0.items.map(\.id))" }
        XCTAssertFalse(loadedBooks.isEmpty)

        let before = try await releaseForReal(library)
        let released = await answers()
        XCTAssertEqual(released, loaded, "the catalog answers as the arrays did")
        let releasedBooks = await AppServices.siriSpokenWordBooksOutsideTheModel(library: library)
        XCTAssertEqual(releasedBooks?.map { "\($0.id) \($0.items.map(\.id))" }, loadedBooks, "the book listing Siri reads")
        assertNoLoadAndNoArrayRead(library, since: before, "Siri lookups while released")
    }
}

/// 列目录时停在闸门上,直到测试放行(看扫描跑着时的占用)。
private actor GatedListingConnector: MusicSourceConnector {
    let sourceID: String
    private(set) var listings = 0
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(sourceID: String) { self.sourceID = sourceID }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listings += 1
        if !isOpen { await withCheckedContinuation { waiting = $0 } }
        return [RemoteFileItem(name: "gated.mp3", path: "/Music/gated.mp3", isDirectory: false,
                               size: 100, modifiedDate: nil, revision: "v1", providerID: "gated")]
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

/// 把扫描服务的状态文件放进测试目录。
private final class RootedTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root]
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

/// 测试里记 `.primuseSongsRemoved` 带的 id:观察者的闭包不在主 actor 上。
private final class RemovedSongIDsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func record(_ ids: [String]) {
        lock.lock()
        recorded.append(ids)
        lock.unlock()
    }

    var all: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
