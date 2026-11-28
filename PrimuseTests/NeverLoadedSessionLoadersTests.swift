import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// DL3:真机第 5 轮在「从没装过歌曲模型」的会话里找到的几处装载 —— 场景先于「可用」变成活跃时回前台的两样判断、
/// 服务端镜像刷新那一轮的评分续传与专辑 / 艺人收藏的推送;以及整库快照从目录导出之后放在哪。每一条都与装着模型时
/// 同一份输入的结果比,并断言没有占用、没有装载、没有读整库数组。
@MainActor
final class NeverLoadedSessionLoadersTests: LibraryReleasedTwinTestCase {
    // MARK: A — the launch race

    /// 不装模型的启动里场景先于「可用」变成活跃(真机第 5 轮装新构建后的第一次启动):回前台的续扫、目录拓扑重建
    /// 两样判断等到可用再判 —— 没有要续的扫描时不占用、不装,拓扑重建的细查在目录那一支照跑一次。对照:改之前的判法
    /// (那一刻 `isUsable`、`isReady` 都是假,走 `onReady(holding:)`,启动状态没读完按有活算)在同一个窗口里变成
    /// `hold scan at launch`。
    func testSceneActivationBeforeUsableDecidesOnceUsableWithoutAHold() async throws {
        let songs = Self.fixture(prefix: "act")
        let fixture = try await launchFixture("act", songs: songs)
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        final class Calls { var resumed = 0; var rebuilt = 0; var rebuiltOnTheCatalogBranch = false }
        let calls = Calls()
        let library = await launch(try copyOfDirectory(fixture.directory, "act-race"), unloaded: true) { library in
            XCTAssertTrue(library.isInUnloadedLaunchWindow, "before the publish of a launch without the model")
            XCTAssertFalse(library.isUsable)
            XCTAssertFalse(library.isReady)
            library.resumeScansOnSceneActivation(
                isStartupStateReady: { false }, whenStartupStateReady: {}, hasResumableScanWork: { false },
                resume: { calls.resumed += 1 }
            )
            library.startFolderTopologyRebuildsOnSceneActivation(mayNeedRebuild: { true }) {
                calls.rebuilt += 1
                calls.rebuiltOnTheCatalogBranch = library.isUsable && !library.isReady
            }
            XCTAssertEqual(calls.rebuilt, 0, "nothing is decided before usable")
        }
        try await waitUntilUsable(library)
        for _ in 0..<150 where calls.rebuilt == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        XCTAssertFalse(library.isInUnloadedLaunchWindow)
        XCTAssertEqual(calls.rebuilt, 1, "the rebuild check runs once usable")
        XCTAssertTrue(calls.rebuiltOnTheCatalogBranch, "on the branch for a model that is out")
        XCTAssertEqual(calls.resumed, 0, "no resumable scan: nothing to resume")
        XCTAssertEqual(songModelHolds(of: library), [], "no hold")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0, "no load")
        XCTAssertFalse(library.isLoadingSongModelForTesting)
        XCTAssertFalse(library.isReady)

        MusicLibrary.songModelHoldRequestsForTesting = []
        let raced = await launch(try copyOfDirectory(fixture.directory, "act-before"), unloaded: true) { library in
            // 改之前 `.active` 在这一刻走的那一支。
            library.onReady(holding: .scan, ifThereIsWork: { true }) {}
        }
        try await waitUntilReady(raced)
        XCTAssertEqual(songModelHolds(of: raced), [.scan], "the old decision holds before usable")
        XCTAssertEqual(raced.songModelResidencyStatistics.lastLoadReason, "hold scan at launch")
    }

    /// 同一个窗口里真有要续的扫描:到可用时照旧占用一次、装回模型,装好之后续扫一次(功能不少)。开关关着的启动:
    /// 当场判、发布时执行,与以前相同。
    func testSceneActivationWithResumableWorkStillHoldsAndTheSwitchOffLaunchIsUnchanged() async throws {
        let songs = Self.fixture(prefix: "acw")
        let fixture = try await launchFixture("acw", songs: songs)
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        final class Calls { var resumed = 0; var rebuilt = 0 }
        let calls = Calls()
        let library = await launch(try copyOfDirectory(fixture.directory, "acw-work"), unloaded: true) { library in
            library.resumeScansOnSceneActivation(
                isStartupStateReady: { true }, whenStartupStateReady: {}, hasResumableScanWork: { true },
                resume: { calls.resumed += 1 }
            )
        }
        try await waitUntilReady(library)
        for _ in 0..<150 where calls.resumed == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(calls.resumed, 1, "the scan resumes once the model is back")
        XCTAssertEqual(songModelHolds(of: library), [.scan], "one hold, taken once usable")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 1)

        MusicLibrary.songModelHoldRequestsForTesting = []
        let loaded = await launch(try copyOfDirectory(fixture.directory, "acw-off"), unloaded: false) { library in
            XCTAssertFalse(library.isInUnloadedLaunchWindow, "the switch is off")
            library.startFolderTopologyRebuildsOnSceneActivation(mayNeedRebuild: { true }) { calls.rebuilt += 1 }
        }
        XCTAssertTrue(loaded.isReady)
        for _ in 0..<150 where calls.rebuilt == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(calls.rebuilt, 1, "decided at once and run at the publish, as before")
        XCTAssertEqual(songModelHolds(of: loaded), [.scan], "the hold of the loaded branch, as before")
    }

    // MARK: B — the mirror round: ratings

    /// 镜像刷新那一轮的评分续传,从没装过模型的启动:确认过的评分(条目一直留着)都已经在曲库里时什么都不改、不占用、
    /// 不装 —— 真机上每一轮 +19 s 的 `hold scan`;回执先到、快照没来得及写(曲库里那条比条目旧)时把那条评价补回曲库,
    /// 只动小状态,结果与装着模型的同一份启动逐条相同。两种情形都不上传、不读整库数组。
    func testServerRatingsResumeInTheMirrorRoundWithoutTheSongModel() async throws {
        let fixture = try await ratingFixture("rtg")
        for (step, directory, outbox, expected) in [
            ("confirmed and in the library", fixture.current.directory, fixture.current.outbox, 4),
            ("acknowledged after the last snapshot", fixture.stale.directory, fixture.stale.outbox, 2),
        ] {
            let loaded = await launch(try copyOfDirectory(directory, "\(step.prefix(6))-loaded"), unloaded: false)
            let neverLoaded = await launch(try copyOfDirectory(directory, "\(step.prefix(6))-unloaded"), unloaded: true)
            try await waitUntilUsable(neverLoaded)
            XCTAssertEqual(neverLoaded.songModelLaunch, "unloaded", step)
            // 镜像刷新那一轮在启动 6 秒之后才开始:等启动窗口里的收尾做完、小状态落得了盘。
            for _ in 0..<250 where !neverLoaded.appliesSmallStateWithoutTheModel { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(neverLoaded.appliesSmallStateWithoutTheModel, step)
            XCTAssertEqual(loaded.allLibraryReviews.first { $0.subject == .song(fixture.rated[0]) }?.rating, 4,
                           "\(step): the snapshot on disk")
            let loadedRig = try makeRatingRig(loaded, outbox: outbox, source: fixture.source)
            let neverRig = try makeRatingRig(neverLoaded, outbox: outbox, source: fixture.source)
            XCTAssertTrue(neverRig.service.hasWorkToResume(sourceID: Self.sourceA), "\(step): stored entries (today: a load)")
            MusicLibrary.songModelHoldRequestsForTesting = []
            let before = neverLoaded.songModelResidencyStatistics
            let acquired = Reasons()
            await neverRig.service.resumeInMirrorRound(sourceID: Self.sourceA) { acquired.values.append($0) }
            await neverRig.service.waitForPendingMutations(sourceID: Self.sourceA)
            XCTAssertEqual(acquired.values, [], "\(step): no hold")
            XCTAssertEqual(songModelHolds(of: neverLoaded), [], step)
            assertNoLoadAndNoArrayRead(neverLoaded, since: before, step)
            await loadedRig.service.resumeInMirrorRound(sourceID: Self.sourceA) { _ in XCTFail("loaded: no acquire") }
            await loadedRig.service.waitForPendingMutations(sourceID: Self.sourceA)
            XCTAssertEqual(neverLoaded.allLibraryReviews, loaded.allLibraryReviews, "\(step): the same reviews")
            XCTAssertEqual(neverLoaded.allLibraryReviews.first { $0.subject == .song(fixture.rated[0]) }?.rating,
                           expected, step)
            XCTAssertEqual(neverRig.server.writes + loadedRig.server.writes, 0, "\(step): nothing uploaded")
            for rig in [loadedRig, neverRig] { rig.defaults.removePersistentDomain(forName: rig.suite) }
        }
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }

    // MARK: B — the mirror round: album and artist likes

    /// 本机的专辑 / 艺人喜欢推到服务端,模型放掉之后从目录查「这个源上的那首歌」:在这个源上的推上去、不在的记成
    /// notOnSource(真机上每一轮为它装一次模型的就是这种),与装着模型时同样的服务端调用、同样的基线;没有占用、没有
    /// 装载、没有读整库数组。下一轮什么都不推。
    func testLocalCollectionLikesArePushedFromTheCatalogLikeTheLoadedLibrary() async throws {
        var songs = Self.fixture(prefix: "clf")
        for track in 1...2 {
            songs.append(Song(
                id: "clf-wy-\(track)", title: "Wish \(track)", albumTitle: "Wish You Were Here", artistName: "Floyd",
                albumArtistName: "Floyd", trackNumber: track, discNumber: 1, duration: 300, fileFormat: .mp3,
                filePath: "/songs/clf-wy-\(track).mp3", sourceID: Self.sourceA
            ))
        }
        let loaded = try makeLaunchedTwin("clf-loaded", songs: songs).library
        let released = try makeLaunchedTwin("clf-released", songs: songs).library
        await assertShadowMatches(loaded, "loaded")
        await assertShadowMatches(released, "released")
        let liveSet = try XCTUnwrap(loaded.visibleAlbums.first { $0.title == "Live Set" })
        let floydAlbum = try XCTUnwrap(loaded.visibleAlbums.first { $0.title == "Wish You Were Here" })
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let before = try await releaseForReal(released)
        let source = MusicSource(id: Self.sourceA, name: "Navidrome", type: .navidrome)

        func rounds(_ library: MusicLibrary, _ name: String) async throws -> CollectionRounds {
            let favorites = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-favorites.json"))
            let suite = "dl3-\(name)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let connector = CollectionConnector()
            let service = ServerCollectionFavoriteSyncService(
                sourcesProvider: { [source] }, connectorProvider: { _ in connector },
                songProvider: { entry, sourceID in
                    ServerCollectionFavoriteSyncService.librarySong(
                        for: entry, sourceID: sourceID, library: library, favorites: favorites
                    )
                },
                libraryCanAnswer: { library.isReady },
                catalogSongProvider: ServerCollectionFavoriteSyncService.catalogSongProvider(library: library),
                favorites: favorites, defaults: defaults, localChangeDelay: .seconds(3600)
            )
            let acquired = Reasons()
            await service.refresh(source: source, applyFence: { true }) { acquired.values.append($0) }
            try await Task.sleep(for: .milliseconds(20))
            favorites.setLiked(true, album: floydAlbum)
            favorites.setLiked(true, album: liveSet)
            favorites.setLiked(true, album: Album(id: "nowhere", title: "Not In This Library", artistName: "Nobody"))
            favorites.setLiked(true, artistNamed: "Floyd")
            favorites.setLiked(true, artistNamed: "Ada")
            await service.refresh(source: source, applyFence: { true }) { acquired.values.append($0) }
            let pushed = await connector.setCalls
            let baseline = service.baseline(for: Self.sourceA)?.keys ?? []
            await service.refresh(source: source, applyFence: { true }) { acquired.values.append($0) }
            let afterThird = await connector.setCalls
            return CollectionRounds(pushed: pushed, baseline: baseline, acquired: acquired.values,
                                    thirdRoundCalls: afterThird.count - pushed.count)
        }
        let loadedRounds = try await rounds(loaded, "clf-loaded")
        let releasedRounds = try await rounds(released, "clf-released")
        XCTAssertEqual(loadedRounds.pushed.map(\.itemID).sorted(),
                       ["server-album-of-clf-wy-1", "server-artist-floyd"], "two of the five are on this source")
        XCTAssertEqual(releasedRounds.pushed, loadedRounds.pushed, "the same server calls in the same order")
        XCTAssertEqual(releasedRounds.baseline, loadedRounds.baseline, "the same baseline")
        XCTAssertEqual(releasedRounds.acquired, [], "no hold while released")
        XCTAssertEqual(loadedRounds.acquired, [])
        XCTAssertEqual(releasedRounds.thirdRoundCalls, 0, "nothing left to push")
        XCTAssertEqual(songModelHolds(of: released), [])
        assertNoLoadAndNoArrayRead(released, since: before, "collection likes from the catalog")
    }

    // MARK: C — where the whole-library export goes

    /// 整库快照从目录导出:写进临时文件、映射回来交出去,字节与装着模型时导出的、与照以前那样攒在内存里的逐字节相同;
    /// 交出之后临时文件已经删掉(太大时也不留);iCloud 上传那一步整理出的一份(同样文件背着)与拿内存里那份整理的相同。
    func testTheExportFromTheCatalogIsFileBackedWithTheSameBytes() async throws {
        let songs = Self.fixture(prefix: "exf")
        let library = try makeLaunchedTwin("exf", songs: songs).library
        library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
        _ = library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[4].id])
        await assertShadowMatches(library, "fixture")
        let limit = 64 * 1024 * 1024
        guard case .snapshot(let loadedBytes) = await library.portableSnapshotIncludingSongs(byteLimit: limit) else {
            return XCTFail("the loaded library exports")
        }
        let before = try await releaseForReal(library)
        func exportFiles() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("primuse-library-export-") })
        }
        let filesBefore = exportFiles()
        guard case .snapshot(let fileBacked) = await library.portableSnapshotIncludingSongs(byteLimit: limit) else {
            return XCTFail("the released library exports from the catalog")
        }
        XCTAssertEqual(fileBacked, loadedBytes, "the file-backed export has the loaded export's bytes")
        XCTAssertEqual(exportFiles().subtracting(filesBefore), [], "the temporary file is gone once mapped")
        LibraryCatalogExportOutput.keepsInMemoryForTesting = true
        defer { LibraryCatalogExportOutput.keepsInMemoryForTesting = false }
        guard case .snapshot(let inMemory) = await library.portableSnapshotIncludingSongs(byteLimit: limit) else {
            return XCTFail("the in-memory export")
        }
        LibraryCatalogExportOutput.keepsInMemoryForTesting = false
        XCTAssertEqual(inMemory, fileBacked, "the same bytes as the in-memory export")
        guard case .tooLarge = await library.portableSnapshotIncludingSongs(byteLimit: loadedBytes.count - 1) else {
            return XCTFail("one byte short is too large")
        }
        XCTAssertEqual(exportFiles().subtracting(filesBefore), [], "no file left after a refusal")
        assertNoLoadAndNoArrayRead(library, since: before, "file-backed export")

        let preparedFromFile = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(fileBacked)
        LibraryCatalogExportOutput.keepsInMemoryForTesting = true
        let preparedInMemory = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(inMemory)
        LibraryCatalogExportOutput.keepsInMemoryForTesting = false
        XCTAssertEqual(preparedFromFile?.data, preparedInMemory?.data, "the upload's prepared snapshot is the same")
        XCTAssertNotNil(preparedFromFile)
        let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        XCTAssertEqual(LibraryCatalogExportOutput.fileBacked(big), big, "a large in-memory copy keeps its bytes")
        XCTAssertEqual(exportFiles().subtracting(filesBefore), [])
    }

    // MARK: - Rating fixture

    private struct RatingFixture {
        let source: MusicSource
        let rated: [String]
        let current: (directory: URL, outbox: Data?)
        let stale: (directory: URL, outbox: Data?)
        let defaults: UserDefaults
        let suite: String
    }

    /// 一个装好的库,一个 Navidrome 源上两首评过分、已经上传确认的歌(条目留在评分服务的存储里)。拷两份目录:
    /// 一份快照里就是这两条评分;另一份是又改了一条、回执到了而快照没写(外部写入占着快照)的样子。
    private func ratingFixture(_ name: String) async throws -> RatingFixture {
        var songs = Self.fixture(prefix: name)
        let rated = (1...2).map { "\(name)-rt-\($0)" }
        for (index, id) in rated.enumerated() {
            songs.append(Song(
                id: id, title: "Rated \(index + 1)", albumTitle: "Ratings", artistName: "Rater", albumArtistName: "Rater",
                trackNumber: index + 1, discNumber: 1, duration: 200, fileFormat: .mp3,
                filePath: "/songs/\(id).mp3", sourceID: Self.sourceA
            ))
        }
        let (library, storage) = try makeLaunchedTwin(name, songs: songs)
        let source = MusicSource(id: Self.sourceA, name: "Navidrome", type: .navidrome, host: "ratings.invalid", username: "user")
        let suite = "dl3-ratings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let rig = RatingRig(library: library, source: source, defaults: defaults, suite: suite)
        rig.service.resume()
        library.updateLibraryReview(for: .song(rated[0]), rating: 4, comment: "")
        library.updateLibraryReview(for: .song(rated[1]), rating: 3, comment: "kept")
        await rig.service.waitForPendingMutations(sourceID: source.id)
        XCTAssertEqual(rig.server.writes, 2, "both ratings were uploaded and confirmed")
        await assertShadowMatches(library, "\(name) fixture")
        library.markPortableSnapshotDirtyForTesting()
        guard case .success = await library.persistNowAndWait(materializePortableSnapshot: true) else {
            throw XCTSkip("the fixture did not persist")
        }
        await library.waitForCatalogMirror()
        await library.stopCatalogMirror()
        let current = (try copyOfDirectory(storage, "\(name)-current"), defaults.data(forKey: library.serverRatingStorageKey))
        await library.beginExternalSnapshotWrite()
        library.updateLibraryReview(for: .song(rated[0]), rating: 2, comment: "")
        await rig.service.waitForPendingMutations(sourceID: source.id)
        XCTAssertEqual(rig.server.writes, 3)
        let stale = (try copyOfDirectory(storage, "\(name)-stale"), defaults.data(forKey: library.serverRatingStorageKey))
        library.endExternalSnapshotWrite()
        return RatingFixture(source: source, rated: rated, current: current, stale: stale, defaults: defaults, suite: suite)
    }

    /// 这个库的评分服务,存储里放着 `outbox`(拷来的那一份条目)。
    private func makeRatingRig(_ library: MusicLibrary, outbox: Data?, source: MusicSource) throws -> RatingRig {
        let suite = "dl3-ratings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(outbox, forKey: library.serverRatingStorageKey)
        return RatingRig(library: library, source: source, defaults: defaults, suite: suite)
    }
}

/// 占用的原因,按先后。
@MainActor
private final class Reasons {
    var values: [String] = []
}

private struct CollectionRounds {
    let pushed: [CollectionConnector.SetCall]
    let baseline: [String]
    let acquired: [String]
    let thirdRoundCalls: Int
}

@MainActor
private final class RatingRig {
    let sources = RatingSources()
    let server = RatingServer()
    let service: ServerRatingSyncService
    let defaults: UserDefaults
    let suite: String

    init(library: MusicLibrary, source: MusicSource, defaults: UserDefaults, suite: String) {
        self.defaults = defaults
        self.suite = suite
        sources.items[source.id] = source
        service = ServerRatingSyncService(sourceManager: server, sourcesStore: sources, library: library, defaults: defaults)
        library.serverRatingTargetProvider = { [weak service] in service?.target(for: $0) }
        library.ratingStateMutationHandler = { [weak service] in service?.localRatingDidChange($0) }
    }
}

@MainActor
private final class RatingSources: ServerFavoriteSourcesProviding {
    var items: [String: MusicSource] = [:]
    func source(id: String) -> MusicSource? { items[id] }
}

@MainActor
private final class RatingServer: ServerRatingManaging {
    var values: [ServerSongRatingTarget: Int] = [:]
    var writes = 0

    func fetchServerRating(target: ServerSongRatingTarget, source: MusicSource) async throws -> Int? {
        values[target].flatMap { $0 == 0 ? nil : $0 }
    }

    func setServerRating(target: ServerSongRatingTarget, source: MusicSource, rating: Int?) async throws -> Int? {
        writes += 1
        values[target] = rating ?? 0
        return rating
    }
}

private actor CollectionConnector: ServerCollectionFavoriteConnector {
    struct SetCall: Equatable, Sendable {
        let kind: LibraryFavoriteKind
        let itemID: String
        let isFavorite: Bool
    }

    let sourceID = "dual-write-a"
    private(set) var favorites: [ServerCollectionFavorite] = []
    private(set) var setCalls: [SetCall] = []

    func fetchServerCollectionFavorites() async throws -> [ServerCollectionFavorite] { favorites }

    func serverCollectionMembership(songItemID: String) async throws -> ServerCollectionMembership {
        ServerCollectionMembership(
            albumID: "server-album-of-\(songItemID)",
            artists: [
                ServerArtistReference(id: "server-artist-floyd", name: "Floyd"),
                ServerArtistReference(id: "server-artist-ada", name: "Ada"),
            ]
        )
    }

    func setServerCollectionFavorite(kind: LibraryFavoriteKind, itemID: String, isFavorite: Bool) async throws {
        setCalls.append(SetCall(kind: kind, itemID: itemID, isFavorite: isFavorite))
        if isFavorite {
            // 下一轮读回来的要是同一个名字,否则会被当成服务端换了一条。
            let names: (album: String, artist: String) = switch itemID {
            case "server-artist-floyd": ("", "Floyd")
            case "server-artist-ada": ("", "Ada")
            default: ("Wish You Were Here", "Floyd")
            }
            favorites.append(ServerCollectionFavorite(kind: kind, itemID: itemID, albumTitle: names.album, artistName: names.artist))
        } else {
            favorites.removeAll { $0.itemID == itemID }
        }
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}
