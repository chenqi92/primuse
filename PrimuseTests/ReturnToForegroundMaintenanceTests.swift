import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// DL5:真机第 6 轮,从没装过歌曲模型的会话在后台挂起之后回到前台时装回了模型 —— 进后台时排上的两个维护计时(等认领的
/// 云端身份、搜索索引欠着的准备)在恢复的那一刻才到点,拿了 `.launchMaintenance` 占用。这里照真机的顺序走:不装模型的
/// 启动、场景收尾排上计时(`resumePendingIdentityResolution`)、计时在「挂起之后」到点(测试里强制这样判);结果与装着模型的
/// 同一份启动比,并断言没有占用、没有装载、没有读整库数组。
@MainActor
final class ReturnToForegroundMaintenanceTests: LibraryReleasedTwinTestCase {
    override func setUp() async throws {
        try await super.setUp()
        MusicLibrary.songModelHoldRequestsForTesting = []
        MusicLibrary.launchMaintenanceEventsForTesting = []
    }

    override func tearDown() async throws {
        MusicLibrary.songModelHoldRequestsForTesting = nil
        MusicLibrary.launchMaintenanceEventsForTesting = nil
        MusicLibrary.catalogIdentityResolutionUnavailableForTesting = false
        MusicLibrary.BackgroundMaintenanceTimer.delayForTesting = nil
        MusicLibrary.BackgroundMaintenanceTimer.firedAfterSuspensionForTesting = nil
        try await super.tearDown()
    }

    // MARK: Fixture

    private struct Identities {
        let history: [SongIdentity]
        let playlist: [SongIdentity]
        let arriving: [Song]
    }

    private static let playlistID = "dl5-remote-playlist"

    /// 别的设备的最近播放与一张歌单:一首本机有(按 id);两首本机还没扫到 —— 一首之后按 id 认得出,一首之后按标题、
    /// 时长、艺人认得出;一首哪儿都没有(一直等着)。
    private func remoteIdentities(_ songs: [Song], prefix: String) -> Identities {
        func identity(_ id: String, _ title: String, _ artist: String?, _ duration: Double, path: String) -> SongIdentity {
            SongIdentity(songID: id, title: title, artistName: artist, duration: duration, cloudAccountID: nil, filePath: path)
        }
        let present = identity(songs[0].id, songs[0].title, songs[0].artistName, songs[0].duration, path: songs[0].filePath)
        let presentInPlaylist = identity(songs[1].id, songs[1].title, songs[1].artistName, songs[1].duration,
                                         path: songs[1].filePath)
        let arrivingByID = identity("\(prefix)-arrive-1", "Arrive One", "Ada", 201, path: "/Music/Ada/Arrivals/1.flac")
        let arrivingByTitle = identity("remote-arrive-2", "Arrive Two", "Ada", 202.4, path: "/Elsewhere/arrive-2.flac")
        let nowhere = identity("remote-none", "Nowhere", nil, 10, path: "/Elsewhere/none.flac")
        func song(_ id: String, _ title: String, _ duration: Double, _ track: Int) -> Song {
            Song(id: id, title: title, albumTitle: "Arrivals", artistName: "Ada", albumArtistName: "Ada", trackNumber: track,
                 discNumber: 1, duration: duration, fileFormat: .flac, filePath: "/Music/Ada/Arrivals/\(track).flac",
                 sourceID: Self.sourceA, genre: "Pop", year: 2002)
        }
        return Identities(
            history: [present, arrivingByID, arrivingByTitle, nowhere],
            playlist: [presentInPlaylist, arrivingByTitle, nowhere, arrivingByID],
            arriving: [song("\(prefix)-arrive-1", "Arrive One", 201, 1), song("\(prefix)-arrive-2", "Arrive Two", 202, 2)]
        )
    }

    /// 一个装好、落了盘的库,小状态里有等认领的身份。`arrive` 为真时,身份到了之后那两首歌才扫进来、落盘时还没重试过
    /// (下一次重试认得出它们);为假时什么都没变(真机那台的常态:别的设备的歌,本机一直没有)。
    private func pendingIdentityFixture(_ name: String, arrive: Bool) async throws -> (directory: URL, identities: Identities) {
        let songs = Self.fixture(prefix: name)
        let identities = remoteIdentities(songs, prefix: name)
        let (library, storage) = try makeLaunchedTwin(name, songs: songs)
        library.applyRemotePlaybackHistory(songIDs: identities.history.map(\.songID), identities: identities.history)
        library.applyRemotePlaylist(
            Playlist(id: Self.playlistID, name: "From another device"),
            songIDs: identities.playlist.map(\.songID), identities: identities.playlist
        )
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [songs[0].id], "\(name): the present one resolves at once")
        XCTAssertEqual(library.rawSongIDs(forPlaylist: Self.playlistID).first, songs[1].id, name)
        // 只加这两首(不剪掉源 A 上别的歌)。
        if arrive { library.addSongs(identities.arriving, affectedSourceIDs: [Self.sourceA], pruneMissingSongs: false) }
        // 扫进来之后排上的那次重试不让它在夹具里跑:落盘的是「身份还等着、歌已经在」的样子。
        library.suspendPendingIdentityResolution()
        XCTAssertEqual(library.pendingHistoryIdentitiesForTesting.count, 3, "\(name): three history identities wait")
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [songs[0].id], name)
        await assertShadowMatches(library, "\(name) fixture")
        library.markPortableSnapshotDirtyForTesting()
        guard case .success = await library.persistNowAndWait(materializePortableSnapshot: true) else {
            throw XCTSkip("the fixture did not persist")
        }
        await library.waitForCatalogMirror()
        await library.stopCatalogMirror()
        return (storage, identities)
    }

    private struct Outcome: Equatable {
        var members: [String]
        var pending: [String]
        var history: [String]
        var historyPending: [String]
    }

    private func outcome(_ library: MusicLibrary) -> Outcome {
        Outcome(
            members: library.rawSongIDs(forPlaylist: Self.playlistID),
            pending: library.pendingSongIdentities(forPlaylist: Self.playlistID).map(\.songID),
            history: library.recentPlaybackSongIDsForSync,
            historyPending: library.pendingHistoryIdentitiesForTesting.map(\.songID)
        )
    }

    /// 不装模型的启动,等到小状态落得了盘(镜像刷新、iCloud 落地那几样之前的样子)。前台那一刻(`.active`)不重试身份。
    private func neverLoadedLaunch(_ directory: URL, _ name: String) async throws -> MusicLibrary {
        let library = await launch(try copyOfDirectory(directory, name), unloaded: true)
        try await waitUntilUsable(library)
        for _ in 0..<250 where !library.appliesSmallStateWithoutTheModel || library.readableCatalogReader == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.songModelLaunch, "unloaded", name)
        XCTAssertTrue(library.appliesSmallStateWithoutTheModel, name)
        library.suspendPendingIdentityResolution()
        return library
    }

    /// 装着模型的同一份启动;发布时排上的那次(前台,只按 id)重试取消掉,只留进后台那一次,好与不装模型的一次比。
    private func loadedLaunch(_ directory: URL, _ name: String) async throws -> MusicLibrary {
        let library = await launch(try copyOfDirectory(directory, name), unloaded: false)
        library.suspendPendingIdentityResolution()
        XCTAssertTrue(library.isReady, name)
        return library
    }

    private func events(_ site: MusicLibrary.LaunchMaintenanceSite) -> [String] {
        (MusicLibrary.launchMaintenanceEventsForTesting ?? []).filter { $0.site == site }.map(\.event)
    }

    private func waitFor(_ condition: () -> Bool, seconds: Int = 15) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// 搜索索引的准备标记:`clean` 为真时什么都不欠,否则(新的一份偏好,结构升级之后还没整库准备过)欠着。
    private func searchIndexDefaults(clean: Bool) throws -> (defaults: UserDefaults, suite: String) {
        let suite = "dl5-search-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if clean {
            defaults.set(true, forKey: "primuse.librarySearchIndex.reportedPathsPrepared.v1")
            defaults.set(false, forKey: "primuse.librarySearchIndex.preparationPending.v1")
            defaults.set(7, forKey: "primuse.librarySearchIndex.preparationGeneration.v1")
            defaults.set(7, forKey: "primuse.librarySearchIndex.completedPreparationGeneration.v1")
        }
        XCTAssertEqual(LibrarySearchIndex.hasPendingPreparation(defaults: defaults), !clean)
        return (defaults, suite)
    }

    // MARK: The device sequence

    /// 真机第 6 轮的顺序,什么都没变:不装模型的启动 → 进后台(场景收尾排上身份重试与搜索索引的计时)→ 挂起之后恢复,
    /// 计时这时才到点。没有等着的身份时什么都不做;有等着的而本机一直没有那几首(那台手机的常态)时从曲库目录重试一遍,
    /// 结果与装着模型时相同(一首都认不出,一条不丢);搜索索引不欠准备时不等不装,欠着时等场景切换取消。整段没有占用、
    /// 没有装载、没有读整库数组。
    func testANeverLoadedSessionReturnsToTheForegroundWithoutALoadWhenNothingChanged() async throws {
        let plain = try await launchFixture("dl5-plain", songs: Self.fixture(prefix: "dl5-plain"))
        let (directory, _) = try await pendingIdentityFixture("dl5-idle", arrive: false)
        let empty = try await neverLoadedLaunch(plain.directory, "dl5-plain-never")
        let neverLoaded = try await neverLoadedLaunch(directory, "dl5-idle-never")
        let loaded = try await loadedLaunch(directory, "dl5-idle-loaded")
        XCTAssertFalse(empty.hasPendingIdentityResolution)
        XCTAssertTrue(neverLoaded.hasPendingIdentityResolution, "the small state carried the waiting identities")
        let before = outcome(neverLoaded)
        XCTAssertEqual(before, outcome(loaded), "the same launch state")
        let emptyBefore = empty.songModelResidencyStatistics
        let neverBefore = neverLoaded.songModelResidencyStatistics
        MusicLibrary.songModelHoldRequestsForTesting = []

        MusicLibrary.BackgroundMaintenanceTimer.delayForTesting = .milliseconds(200)
        MusicLibrary.BackgroundMaintenanceTimer.firedAfterSuspensionForTesting = true
        // 进后台:场景收尾那一步。
        for library in [empty, neverLoaded, loaded] { library.resumePendingIdentityResolution() }
        // 搜索索引的计时(`BackgroundLibraryMaintenanceCoordinator`)在恢复的那一刻到点:不欠时当场返回,欠着时(测试宿主
        // 的全局标记,两种都可能)先等,场景切换(这里是取消)把它拿掉。
        let late = MusicLibrary.BackgroundMaintenanceTimer(delay: .seconds(3), armedAt: ContinuousClock.now - .seconds(150))
        let clean = try searchIndexDefaults(clean: true)
        defer { clean.defaults.removePersistentDomain(forName: clean.suite) }
        let notOwed = await neverLoaded.holdSongModelForOwedSearchIndexPreparation(timer: late, defaults: clean.defaults)
        XCTAssertNil(notOwed, "nothing owed: no hold")
        let preparation = Task { await neverLoaded.prepareSearchIndexIfNeeded(timer: late) }
        try await Task.sleep(for: .milliseconds(300))
        preparation.cancel()
        await preparation.value

        try await waitFor { self.events(.pendingIdentities).contains("without the song model") }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(events(.pendingIdentities), ["without the song model"], "retried from the catalog once")
        XCTAssertEqual(outcome(neverLoaded), before, "nothing new resolves; nothing is dropped")
        XCTAssertEqual(outcome(neverLoaded), outcome(loaded), "the same as the loaded launch's retry")
        XCTAssertEqual(neverLoaded.pendingHistoryIdentitiesForTesting.map(\.songID),
                       ["dl5-idle-arrive-1", "remote-arrive-2", "remote-none"])
        XCTAssertFalse(events(.searchIndex).contains { $0.hasPrefix("hold") }, "no search-index hold")
        XCTAssertEqual(songModelHolds(of: neverLoaded), [], "no hold")
        XCTAssertEqual(songModelHolds(of: empty), [], "no hold")
        assertNoLoadAndNoArrayRead(neverLoaded, since: neverBefore, "the return to the foreground")
        assertNoLoadAndNoArrayRead(empty, since: emptyBefore, "the return to the foreground without identities")
        XCTAssertFalse(neverLoaded.isReady)
        XCTAssertFalse(empty.isReady)
    }

    // MARK: Real work

    /// 身份到了之后那两首歌扫进来了(真有活):不装模型的会话回到前台时从曲库目录认出它们 —— 一首按 id、一首按标题、
    /// 时长、艺人 —— 歌单成员、等着的身份、最近播放与装着模型的同一份启动走同一个计时的结果逐项相同;没有占用、没有
    /// 装载、没有读整库数组;落盘之后再启动一次(还是不装模型),认领过的不再等。
    func testIdentitiesThatNowResolveAreResolvedFromTheCatalogLikeTheLoadedLibrary() async throws {
        let (directory, identities) = try await pendingIdentityFixture("dl5-arrive", arrive: true)
        let neverLoaded = try await neverLoadedLaunch(directory, "dl5-arrive-never")
        let loaded = try await loadedLaunch(directory, "dl5-arrive-loaded")
        // 开关全关(今天发版的样子):同一个计时、同样当作挂起之后才到点,走的是原来那一支。
        let switchedOff = await launch(try copyOfDirectory(directory, "dl5-arrive-off"), unloaded: false, residency: false)
        switchedOff.suspendPendingIdentityResolution()
        XCTAssertTrue(switchedOff.isReady)
        XCTAssertEqual(outcome(neverLoaded), outcome(loaded), "the same launch state")
        XCTAssertEqual(neverLoaded.pendingHistoryIdentitiesForTesting.count, 3, "the identities still wait at launch")
        let before = neverLoaded.songModelResidencyStatistics
        MusicLibrary.songModelHoldRequestsForTesting = []

        MusicLibrary.BackgroundMaintenanceTimer.delayForTesting = .milliseconds(200)
        MusicLibrary.BackgroundMaintenanceTimer.firedAfterSuspensionForTesting = true
        for library in [neverLoaded, loaded, switchedOff] { library.resumePendingIdentityResolution() }
        try await waitFor { self.events(.pendingIdentities).contains("without the song model") }
        try await waitFor { loaded.pendingHistoryIdentitiesForTesting.count == 1 }
        try await waitFor { switchedOff.pendingHistoryIdentitiesForTesting.count == 1 }

        let expected = outcome(loaded)
        XCTAssertEqual(outcome(switchedOff), expected, "switches off: the same retry as before")
        XCTAssertEqual(songModelHolds(of: switchedOff), [], "switches off: no hold")
        XCTAssertEqual(expected.historyPending, ["remote-none"], "the loaded retry resolves the two that arrived")
        XCTAssertEqual(expected.pending, ["remote-none"])
        XCTAssertEqual(Array(expected.history.prefix(2)), identities.arriving.map(\.id), "promoted into the history")
        XCTAssertEqual(expected.members.count, 4, "the slots are kept")
        XCTAssertEqual(Array(expected.members.prefix(2)), ["dl5-arrive-blue-2", identities.arriving[1].id])
        XCTAssertEqual(outcome(neverLoaded), expected, "resolved from the catalog: the same members, pending and history")
        XCTAssertEqual(events(.pendingIdentities), ["without the song model"])
        XCTAssertEqual(songModelHolds(of: neverLoaded), [], "no hold")
        assertNoLoadAndNoArrayRead(neverLoaded, since: before, "resolving from the catalog")
        XCTAssertFalse(neverLoaded.isReady)

        // 只动了小状态,不装模型照样落盘。整份写(不写增量):增量认的是快照文件的身份(含 inode),拷一份目录就对不上了。
        guard case .success = await neverLoaded.persistNowAndWait(materializePortableSnapshot: true) else {
            return XCTFail("the small state persists without the model")
        }
        assertNoLoadAndNoArrayRead(neverLoaded, since: before, "persisting")
        await neverLoaded.waitForCatalogMirror()
        await neverLoaded.stopCatalogMirror()
        // 不装模型的那一份落在 `dl5-arrive-never`(`neverLoadedLaunch` 拷出来的目录),从它再启动一次。
        let again = try await neverLoadedLaunch(self.directory.appendingPathComponent("dl5-arrive-never"), "dl5-arrive-relaunch")
        XCTAssertEqual(outcome(again), expected, "the resolved state survives a relaunch")
    }

    /// 目录答不了这些身份时(小状态此刻落不了盘之类):计时挂起之后才到点(恢复的那一刻)不装,过一会儿再判;场景切换
    /// (`suspendPendingIdentityResolution`)把这次再判取消掉 —— 没有占用、没有装载,身份一条不丢。系统在后台唤醒时
    /// (计时照常到点)才占用一次、记一行理由,装回来照模型在内存里时那样认领,结果与装着模型时相同。
    func testWhenTheCatalogCannotAnswerTheHoldIsNotTakenAtTheReturnAndIsLoggedWhenTaken() async throws {
        let (directory, _) = try await pendingIdentityFixture("dl5-cannot", arrive: true)
        let neverLoaded = try await neverLoadedLaunch(directory, "dl5-cannot-never")
        let loaded = try await loadedLaunch(directory, "dl5-cannot-loaded")
        let before = neverLoaded.songModelResidencyStatistics
        MusicLibrary.songModelHoldRequestsForTesting = []
        MusicLibrary.catalogIdentityResolutionUnavailableForTesting = true
        MusicLibrary.BackgroundMaintenanceTimer.delayForTesting = .milliseconds(200)
        MusicLibrary.BackgroundMaintenanceTimer.firedAfterSuspensionForTesting = true

        neverLoaded.resumePendingIdentityResolution()
        try await waitFor { self.events(.pendingIdentities).contains("deferred") }
        // 用户回来了:`.inactive` 取消排着的重试。
        neverLoaded.suspendPendingIdentityResolution()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(events(.pendingIdentities).contains { $0.hasPrefix("hold") }, "no hold at the return")
        XCTAssertEqual(songModelHolds(of: neverLoaded), [])
        assertNoLoadAndNoArrayRead(neverLoaded, since: before, "the return to the foreground")
        XCTAssertEqual(neverLoaded.pendingHistoryIdentitiesForTesting.count, 3, "cannot answer is not none: all still wait")

        // 系统在后台唤醒(计时照常到点):占用一次,记下理由,装回来认领。
        MusicLibrary.BackgroundMaintenanceTimer.firedAfterSuspensionForTesting = false
        MusicLibrary.launchMaintenanceEventsForTesting = []
        neverLoaded.resumePendingIdentityResolution()
        loaded.resumePendingIdentityResolution()
        try await waitFor { neverLoaded.pendingHistoryIdentitiesForTesting.count == 1 }
        try await waitFor { loaded.pendingHistoryIdentitiesForTesting.count == 1 }
        XCTAssertEqual(events(.pendingIdentities), ["hold: the catalog cannot answer the identities now"])
        XCTAssertEqual(songModelHolds(of: neverLoaded), [.launchMaintenance], "one hold")
        XCTAssertEqual(neverLoaded.songModelResidencyStatistics.loads, before.loads + 1, "one load")
        XCTAssertEqual(neverLoaded.songModelResidencyStatistics.lastLoadReason, "hold launchMaintenance")
        XCTAssertEqual(outcome(neverLoaded), outcome(loaded), "resolved with the model like the loaded library")
        try await waitFor { !neverLoaded.songModelHoldReasons.contains(.launchMaintenance) }
        XCTAssertFalse(neverLoaded.songModelHoldReasons.contains(.launchMaintenance), "and lets go")
    }

    /// 搜索索引欠着准备、模型不在内存里:进后台排上的计时挂起之后才到点时先等;场景切换取消它就什么都不做(标记留着),
    /// 没有占用、没有装载。系统在后台唤醒时没人取消:等完占用一次、记一行理由。计时照常到点时当场占用(与以前相同)。
    /// 什么都不欠时不等、不占用。
    func testAnOwedSearchIndexPreparationWaitsOutTheReturnAndHoldsOnlyInTheBackground() async throws {
        let fixture = try await launchFixture("dl5-search", songs: Self.fixture(prefix: "dl5-search"))
        let library = try await neverLoadedLaunch(fixture.directory, "dl5-search-never")
        let owed = try searchIndexDefaults(clean: false)
        defer { owed.defaults.removePersistentDomain(forName: owed.suite) }
        let before = library.songModelResidencyStatistics
        MusicLibrary.songModelHoldRequestsForTesting = []
        let late = MusicLibrary.BackgroundMaintenanceTimer(delay: .seconds(3), armedAt: ContinuousClock.now - .seconds(150))
        XCTAssertTrue(late.firedAfterSuspension, "150 s late: suspended in between")
        XCTAssertFalse(MusicLibrary.BackgroundMaintenanceTimer(delay: .seconds(3), armedAt: ContinuousClock.now - .seconds(3)).firedAfterSuspension)

        // 回到前台:等的途中场景切换取消了计时。
        let returning = Task { await library.holdSongModelForOwedSearchIndexPreparation(timer: late, defaults: owed.defaults) }
        try await Task.sleep(for: .milliseconds(300))
        returning.cancel()
        let dropped = await returning.value
        XCTAssertNil(dropped)
        XCTAssertEqual(events(.searchIndex), ["waits", "dropped"])
        XCTAssertEqual(songModelHolds(of: library), [], "no hold at the return")
        assertNoLoadAndNoArrayRead(library, since: before, "an owed preparation at the return")
        XCTAssertTrue(LibrarySearchIndex.hasPendingPreparation(defaults: owed.defaults), "still owed")

        // 系统在后台唤醒:等完占用一次。
        MusicLibrary.launchMaintenanceEventsForTesting = []
        let hold = await library.holdSongModelForOwedSearchIndexPreparation(timer: late, defaults: owed.defaults)
        XCTAssertNotNil(hold)
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(events(.searchIndex), ["waits", "hold: a preparation is owed generation=0"])
        XCTAssertEqual(songModelHolds(of: library), [.launchMaintenance])
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        hold?.end()

        // 模型在内存里、计时照常到点:当场占用,不等、不记(与以前相同)。
        MusicLibrary.launchMaintenanceEventsForTesting = []
        let onTime = MusicLibrary.BackgroundMaintenanceTimer(delay: .seconds(3), armedAt: ContinuousClock.now - .seconds(3))
        let loadedHold = await library.holdSongModelForOwedSearchIndexPreparation(timer: onTime, defaults: owed.defaults)
        XCTAssertNotNil(loadedHold)
        loadedHold?.end()
        XCTAssertEqual(events(.searchIndex), [])
        let clean = try searchIndexDefaults(clean: true)
        defer { clean.defaults.removePersistentDomain(forName: clean.suite) }
        let none = await library.holdSongModelForOwedSearchIndexPreparation(timer: late, defaults: clean.defaults)
        XCTAssertNil(none, "nothing owed: nothing to hold")
        XCTAssertEqual(events(.searchIndex), [])
    }
}
