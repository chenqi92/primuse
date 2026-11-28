import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// Stage 2 的大库启动基准。回答的是同一个问题的三段: 同步装载在主线程上要
/// 多久、把同样的活儿放到主线程之外要多久、以及留在主线程的那一步(发布)
/// 还剩多少。
///
/// 规模由环境变量 `PRIMUSE_HARNESS_SONGS` 控制(默认 10_000), 两个变体分别
/// 覆盖冷启动(没有启动缓存 / 派生索引缓存)与热启动(两份缓存都在)。
///
/// 只能在 Apple 平台跑:
/// ```
/// xcodebuild test -scheme Primuse \
///   -destination 'platform=iOS Simulator,name=iPhone 16' \
///   -only-testing:PrimuseTests/LibraryStartupHarnessTests \
///   TEST_RUNNER_PRIMUSE_HARNESS_SONGS=20000
/// ```
@MainActor
final class LibraryStartupHarnessTests: XCTestCase {

    func testUnchangedMirrorSkipsRematchingButNewSongsStillResolve() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PendingMatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let sourceID = UUID().uuidString
        let playlistID = ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: "mirror")
        let entry = PlaylistPendingEntry(title: "Orbit Window", artists: ["Paper Satellites"], duration: 180,
                                         origin: "jellyfin", externalID: "target", serverSourceID: sourceID)
        library.addSongs([Song(id: "existing", title: "Quiet Compass", fileFormat: .flac,
                               filePath: "/items/existing.flac", sourceID: sourceID)])
        await library.waitForPendingIndex()
        library.ensurePlaylist(id: playlistID, name: "Mirror")
        library.replaceMirrorPlaylistSongs(playlistID: playlistID, songIDs: [entry.id],
                                           coverArtPath: nil, pendingEntries: [entry])
        await library.waitForPendingPlaylistResolution()
        let passes = library.playlistPendingMatchPassCount
        XCTAssertEqual(passes, 1)
        XCTAssertNotNil(library.pendingEntry(id: entry.id))

        for _ in 0..<3 {
            library.replaceMirrorPlaylistSongs(playlistID: playlistID, songIDs: [entry.id],
                                               coverArtPath: nil, pendingEntries: [entry])
        }
        await library.waitForPendingPlaylistResolution()
        XCTAssertEqual(library.playlistPendingMatchPassCount, passes)

        library.addSongs([Song(id: "arrived", title: entry.title, fileFormat: .flac,
                               filePath: "/items/target.flac", sourceID: sourceID)])
        await library.waitForPendingIndex()
        await library.waitForPendingPlaylistResolution()
        XCTAssertGreaterThan(library.playlistPendingMatchPassCount, passes)
        XCTAssertEqual(library.songIDs(forPlaylist: playlistID), ["arrived"])
        XCTAssertNil(library.pendingEntry(id: entry.id))
        await Self.drainLaunchCacheWrites(library)
    }

    func testInteractionWindowsHoldBackgroundWorkUntilTheyEndWithinTheMaximumHold() async {
        let monitor = UserScrollActivityMonitor.shared
        // 播放页展开这类转场：转场时长加上停稳的一秒都算交互。
        monitor.recordInteraction(lasting: 0.4)
        var startedAt = Date()
        await monitor.waitUntilSettled(maximumHold: 10)
        var waited = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThanOrEqual(waited, 1.2)
        XCTAssertLessThan(waited, 5)

        // 转场期间的一次点按不会把转场的结束时刻提前。
        monitor.recordInteraction(lasting: 1.5)
        monitor.recordInteraction()
        startedAt = Date()
        await monitor.waitUntilSettled(maximumHold: 10)
        waited = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThanOrEqual(waited, 2.3)

        // 一直不停时最多等 `maximumHold`，到点照样往下走。
        monitor.recordInteraction(lasting: 1)
        startedAt = Date()
        await monitor.waitUntilSettled(maximumHold: 0.5)
        waited = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThanOrEqual(waited, 0.45)
        XCTAssertLessThan(waited, 1.5)
        // 别把这段交互留给后面的用例。
        await monitor.waitUntilSettled(maximumHold: 5)
    }

    private final class PlayerRefreshFileManager: FileManager, @unchecked Sendable {
        let root: URL
        init(root: URL) { self.root = root; super.init() }
        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
    }

    func testMirrorRefreshWaitsOutInteractionWindowsWithoutBeingCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerMirror-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = MusicSource(id: UUID().uuidString, name: "Mirror fixture", type: .navidrome,
                                        host: "https://fixture.invalid")
        configuration.songCount = 1
        let source = configuration
        let connector = LocalFileSource(sourceID: source.id, basePath: root)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(source)
        let scanner = ScanService(fileManager: PlayerRefreshFileManager(root: root.appendingPathComponent("Scan")),
                                  connectorProvider: { _ in connector })
        var attempts = 0
        var completedFence: Bool?
        let coordinator = ServerMirrorRefreshCoordinator(
            sourcesStore: store, sourceManager: manager, library: library, scanService: scanner,
            launchDelay: .zero
        ) { _, fence in
            attempts += 1
            completedFence = fence()
        }
        // 播放页正在展开：刷新等转场停稳再开始，开始了就做完，不会被取消。
        UserScrollActivityMonitor.shared.recordInteraction(lasting: 0.5)
        let startedAt = Date()
        coordinator.startColdLaunchRefresh()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(attempts, 0)
        for _ in 0..<400 where completedFence == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(completedFence, true)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 1.3)
        // 冷却期内回到前台不再刷一遍。
        coordinator.applicationDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, 1)
        await Self.drainLaunchCacheWrites(library)
    }

    private actor ClassificationPreparationGate {
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

    private static func folderFixture() async throws -> (URL, [Song], AlbumArtistFolderIndex) {
        let directory = try makeStorageDirectory()
        let sourceID = "folder-fixture-\(UUID().uuidString)"
        let songs = (0..<4).map { index in
            Song(id: "\(sourceID)-\(index)", title: "Track \(index)",
                 albumTitle: index == 3 ? "Another Album" : "Shared Album",
                 artistName: index < 2 ? "North" : "South",
                 duration: 180, fileFormat: .flac, filePath: "item-\(index)", sourceID: sourceID,
                 dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let folders = AlbumArtistFolderIndex(parentsBySource: [sourceID: [
            "item-0": "shared-folder", "item-1": "shared-folder",
            "item-2": "shared-folder", "item-3": "other-folder"
        ]])
        let seed = MusicLibrary(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        seed.addSongs(songs, affectedSourceIDs: [sourceID])
        await seed.waitForPendingIndex()
        guard case .success = await seed.persistNowAndWait() else {
            throw XCTSkip("The folder fixture did not persist")
        }
        await drainLaunchCacheWrites(seed)
        let migrated = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        migrated.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        migrated.updateAlbumArtistFolders(folders)
        await migrated.waitForPendingIndex()
        guard case .success = await migrated.persistNowAndWait() else {
            throw XCTSkip("The folder fixture did not finish its migration")
        }
        await drainLaunchCacheWrites(migrated)
        return (directory, songs, folders)
    }

    func testMatchingCachedFoldersDoNotRebuildAfterColdLaunch() async throws {
        let (directory, songs, folders) = try await Self.folderFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        let generation = library.indexRebuildGenerationForTesting
        library.updateAlbumArtistFolders(folders)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.indexRebuildGenerationForTesting, generation)
        XCTAssertEqual(library.albumArtistFolders, folders)
        XCTAssertEqual(library.albums, MusicLibrary.computeAlbumsAndArtists(songs: songs, folders: folders).albums)
        XCTAssertEqual(Set(library.songs.map(\.id)), Set(songs.map(\.id)))
        await Self.drainLaunchCacheWrites(library)
    }

    func testChangedCachedFoldersRebuildAndPersistTheNewGrouping() async throws {
        let (directory, songs, folders) = try await Self.folderFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changedParents = folders.parentsBySource
        changedParents[songs[0].sourceID]?["item-2"] = "solo-folder"
        let changed = AlbumArtistFolderIndex(parentsBySource: changedParents)
        let expected = MusicLibrary.computeAlbumsAndArtists(songs: songs, folders: changed).albums
        XCTAssertNotEqual(expected, MusicLibrary.computeAlbumsAndArtists(songs: songs, folders: folders).albums)
        let library = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        let generation = library.indexRebuildGenerationForTesting
        library.updateAlbumArtistFolders(changed)
        await library.waitForPendingIndex()
        XCTAssertGreaterThan(library.indexRebuildGenerationForTesting, generation)
        XCTAssertEqual(library.albums, expected)
        // 重开之前等改过专辑的那几行真的进了旧库(写入在后台任务里): 不等的话重开读到的可能还是旧行,
        // 那就不是在验「新的分组存下来了」, 而是在赌写入比重开快。
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The regrouped rows did not persist")
        }
        await Self.drainLaunchCacheWrites(library)

        let reopened = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        reopened.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        let reopenedGeneration = reopened.indexRebuildGenerationForTesting
        reopened.updateAlbumArtistFolders(changed)
        await reopened.waitForPendingIndex()
        XCTAssertEqual(reopened.indexRebuildGenerationForTesting, reopenedGeneration)
        XCTAssertEqual(reopened.albums, expected)
        await Self.drainLaunchCacheWrites(reopened)
    }

    func testChangedSongsCannotReuseAnOldFolderValidation() async throws {
        let (directory, songs, folders) = try await Self.folderFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
        var updated = songs[2]
        updated.albumTitle = "Changed Album"
        try store.apply(upserts: [updated])
        let library = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        let generation = library.indexRebuildGenerationForTesting
        library.updateAlbumArtistFolders(folders)
        await library.waitForPendingIndex()
        XCTAssertGreaterThan(library.indexRebuildGenerationForTesting, generation)
        XCTAssertEqual(library.song(id: updated.id)?.albumTitle, "Changed Album")
        let expected = MusicLibrary.computeAlbumsAndArtists(songs: library.songs, folders: folders).albums
        XCTAssertEqual(library.albums, expected)
        await Self.drainLaunchCacheWrites(library)
    }

    func testMatchingSongSignatureStillUsesNewerFolderIndex() async throws {
        let (directory, songs, folders) = try await Self.folderFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startupURL = directory.appendingPathComponent("library-startup-cache.plist")
        var earlier = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: startupURL), format: nil
        ) as? [String: Any])
        var parents = folders.parentsBySource
        parents[songs[0].sourceID]?["item-2"] = "solo-folder"
        let changed = AlbumArtistFolderIndex(parentsBySource: parents)
        let library = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        library.updateAlbumArtistFolders(changed)
        await library.waitForPendingIndex()
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The updated folder index did not persist")
        }
        await Self.drainLaunchCacheWrites(library)
        let current = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: startupURL), format: nil
        ) as? [String: Any])
        XCTAssertEqual(earlier["derivedIndexSignature"] as? String, current["derivedIndexSignature"] as? String)
        XCTAssertNotEqual(earlier["folderSignature"] as? String, current["folderSignature"] as? String)
        earlier["snapshotFingerprint"] = current["snapshotFingerprint"]
        try PropertyListSerialization.data(fromPropertyList: earlier, format: .binary, options: 0).write(to: startupURL)

        let reopened = MusicLibrary.makePreparing(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        reopened.publish(await MusicLibrary.prepareStartup(storageDirectory: directory, artistNameConfiguration: .defaultValue))
        XCTAssertEqual(reopened.albums, library.albums)
        let generation = reopened.indexRebuildGenerationForTesting
        reopened.updateAlbumArtistFolders(changed)
        await reopened.waitForPendingIndex()
        XCTAssertEqual(reopened.indexRebuildGenerationForTesting, generation)
        await Self.drainLaunchCacheWrites(reopened)
    }

    func testBackgroundClassificationKeepsEditsMadeDuringPreparation() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = Song(id: UUID().uuidString, title: "A Story", duration: 180,
                        fileFormat: .flac, filePath: "/story.flac", sourceID: "classification-fixture")
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        await library.waitForPendingIndex()
        let store = SpokenWordStore.shared
        defer { store.setKind(nil, forSongIDs: [song.id]) }
        store.setKind(.spokenWord, forSongIDs: [song.id])
        let gate = ClassificationPreparationGate()
        library.contentClassificationPreparationForTesting = { await gate.pause() }
        let refresh = Task { await library.refreshContentClassificationInBackground() }
        await gate.waitUntilStarted()
        library.updateLyricsText([song.id: "A paper boat crosses the quiet pond."])
        await gate.release()
        await refresh.value
        XCTAssertEqual(library.spokenWordSongs.map(\.id), [song.id])
        XCTAssertEqual(library.spokenWordSongs.first?.lyricsText, "A paper boat crosses the quiet pond.")
        XCTAssertTrue(library.musicSongs.isEmpty)
        await Self.drainLaunchCacheWrites(library)
    }

    func testExplicitClassificationSupersedesAnOlderBackgroundResult() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = Song(id: UUID().uuidString, title: "A Story", duration: 180,
                        fileFormat: .flac, filePath: "/story.flac", sourceID: "classification-fixture")
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        await library.waitForPendingIndex()
        let store = SpokenWordStore.shared
        defer { store.setKind(nil, forSongIDs: [song.id]) }
        store.setKind(.spokenWord, forSongIDs: [song.id])
        let gate = ClassificationPreparationGate()
        library.contentClassificationPreparationForTesting = { await gate.pause() }
        let refresh = Task { await library.refreshContentClassificationInBackground() }
        await gate.waitUntilStarted()
        store.setKind(.podcast, forSongIDs: [song.id])
        library.refreshContentClassification()
        await gate.release()
        await refresh.value
        XCTAssertTrue(library.spokenWordSongs.isEmpty)
        XCTAssertEqual(library.localPodcastSongs.map(\.id), [song.id])
        XCTAssertEqual(library.songs.map(\.id), [song.id])
        await Self.drainLaunchCacheWrites(library)
    }

    // MARK: - 规模

    /// 默认 10_000。`TEST_RUNNER_` 前缀由 xcodebuild 转交给测试进程。
    private static var songCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_HARNESS_SONGS"],
              let value = Int(raw), value > 0 else { return 10_000 }
        return value
    }

    /// 低于这个规模时比例断言没有意义(装载本身只有几毫秒, 噪声占主导)。
    private static let ratioAssertionMinimumSongs = 10_000
    /// 发布步骤允许占用的主线程时间上限, 相对同步装载。
    private static let publishToSyncRatioCeiling = 0.25

    // MARK: - 夹具

    private static func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryStartupHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func copyDirectory(_ source: URL) throws -> URL {
        let destination = try makeStorageDirectory()
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// N 首合成歌曲, 4 个源, 专辑基数 ≈ N/12, 艺术家基数 ≈ N/40, 外加 20 个
    /// 歌单 —— 与真实中大型库的分组代价同量级。写入走正常的库 API, 所以
    /// 磁盘上的格式(SQLite + 便携快照 + 启动缓存 + 派生索引缓存)与线上一致。
    private static func makeFixture(songCount: Int) async throws -> URL {
        let directory = try makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let sourceIDs = (0..<4).map { "harness-source-\($0)" }
        let albumCount = max(1, songCount / 12)
        let artistCount = max(1, songCount / 40)

        // 真实曲库以中文名为主, 还夹着「、」「/」连写的合唱: 艺术家解析会对
        // 每首歌做分隔符检索, 纯 ASCII 的单一名字量不出这段代价。
        let familyNames = ["周", "林", "陈", "王", "张", "李", "刘", "杨", "黄", "吴"]
        let givenNames = ["杰伦", "俊杰", "奕迅", "菲", "学友", "宇春", "绮贞", "楚生", "鹏", "若昀"]
        func artistName(_ artistIndex: Int) -> String {
            guard artistIndex % 3 != 0 else { return "Artist \(artistIndex)" }
            return familyNames[artistIndex % familyNames.count]
                + givenNames[(artistIndex / familyNames.count) % givenNames.count]
                + "\(artistIndex)"
        }
        let genres = ["流行", "Rock", "Jazz", "古典", "民谣", "Electronic", "R&B", "说唱"]

        var songsBySource: [String: [Song]] = [:]
        for index in 0..<songCount {
            let sourceID = sourceIDs[index % sourceIDs.count]
            let albumIndex = index % albumCount
            let artistIndex = index % artistCount
            let performer: String
            switch index % 10 {
            case 0: performer = artistName(artistIndex) + "、" + artistName((artistIndex + 7) % artistCount)
            case 1: performer = artistName(artistIndex) + "/" + artistName((artistIndex + 3) % artistCount)
            default: performer = artistName(artistIndex)
            }
            let song = Song(
                id: "harness-\(index)",
                title: "Track \(index)",
                albumTitle: "Album \(albumIndex)",
                artistName: performer,
                albumArtistName: artistName(albumIndex % artistCount),
                trackNumber: index % 12 + 1,
                discNumber: 1,
                duration: 180 + Double(index % 120),
                fileFormat: .flac,
                filePath: "/Music/\(sourceID)/\(albumIndex)/\(index).flac",
                sourceID: sourceID,
                genre: genres[albumIndex % genres.count],
                year: 1990 + albumIndex % 35,
                coverArtFileName: index % 12 == 0 ? "cover-\(albumIndex).jpg" : nil
            )
            songsBySource[sourceID, default: []].append(song)
        }
        for sourceID in sourceIDs {
            library.addSongs(songsBySource[sourceID] ?? [], affectedSourceIDs: [sourceID])
        }

        let allIDs = library.songs.map(\.id)
        let playlistSize = max(1, min(allIDs.count, 200))
        for playlistIndex in 0..<20 {
            let start = (playlistIndex * playlistSize) % max(1, allIDs.count)
            let end = min(allIDs.count, start + playlistSize)
            let members = start < end ? Array(allIDs[start..<end]) : []
            _ = library.createPlaylist(name: "Harness \(playlistIndex)", songIDs: members)
        }

        guard case .success = await library.persistNowAndWait() else {
            throw XCTSkip("The harness fixture did not finish persistence")
        }
        return directory
    }

    /// 冷启动变体: 丢掉两份可重建的缓存, 装载必须走 SQLite/JSON + 分组排序。
    private static func makeCold(_ fixture: URL) throws -> URL {
        let directory = try copyDirectory(fixture)
        for name in ["library-startup-cache.plist", "library-derived-index.plist"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return directory
    }

    // MARK: - 单次测量

    private struct Measurement {
        var synchronousMilliseconds: Double
        var prepareMilliseconds: Double
        var publishMilliseconds: Double

        /// 留在主线程上的那一段占同步装载的比例。
        var publishToSyncRatio: Double {
            guard synchronousMilliseconds > 0 else { return 0 }
            return publishMilliseconds / synchronousMilliseconds
        }
    }

    /// 三段都各用一份干净的副本, 互不污染: 同步装载会补写缓存, 发布也会。
    private func measureStartup(
        fixture: URL,
        variant: String,
        cold: Bool,
        songCount: Int
    ) async throws -> Measurement {
        let synchronousDirectory = cold
            ? try Self.makeCold(fixture)
            : try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: synchronousDirectory) }
        let preparedDirectory = cold
            ? try Self.makeCold(fixture)
            : try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }

        // (1) 今天的同步路径: 整库装载全程占用主线程。
        let synchronousStartedAt = ProcessInfo.processInfo.systemUptime
        let synchronous = MusicLibrary(storageDirectory: synchronousDirectory)
        let synchronousFinishedAt = ProcessInfo.processInfo.systemUptime

        // (2) Stage 2 的准备: 同样的读取 / 迁移 / 分组, 但在主线程之外。
        let prepareStartedAt = ProcessInfo.processInfo.systemUptime
        let prepared = await MusicLibrary.prepareStartup(storageDirectory: preparedDirectory)
        let prepareFinishedAt = ProcessInfo.processInfo.systemUptime

        // (3) 唯一留在主线程上的一步。
        let library = MusicLibrary.makePreparing(storageDirectory: preparedDirectory)
        let publishStartedAt = ProcessInfo.processInfo.systemUptime
        library.publish(prepared)
        let publishFinishedAt = ProcessInfo.processInfo.systemUptime

        XCTAssertEqual(synchronous.songs.count, songCount, "同步装载读回的行数不对")
        assertLibraryStartupParity(synchronous: synchronous, prepared: library)

        let measurement = Measurement(
            synchronousMilliseconds: (synchronousFinishedAt - synchronousStartedAt) * 1_000,
            prepareMilliseconds: (prepareFinishedAt - prepareStartedAt) * 1_000,
            publishMilliseconds: (publishFinishedAt - publishStartedAt) * 1_000
        )
        // 与库自己打出的 `🚀 library load …` 同流, 方便在一份日志里对读。
        plog(String(
            format: "🚀 library harness %@ songs=%d sync=%.0fms prepare=%.0fms publish=%.0fms publish/sync=%.1f%%",
            variant,
            songCount,
            measurement.synchronousMilliseconds,
            measurement.prepareMilliseconds,
            measurement.publishMilliseconds,
            measurement.publishToSyncRatio * 100
        ))
        return measurement
    }

    private func assertPublishStaysOffTheCriticalPath(
        _ measurement: Measurement,
        songCount: Int,
        variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard songCount >= Self.ratioAssertionMinimumSongs else { return }
        // 断言的是比例而不是绝对毫秒数: 模拟器 / 设备 / 热度都会整体缩放,
        // 但"主线程只剩发布"这个结论不应该随之改变。
        XCTAssertLessThan(
            measurement.publishToSyncRatio,
            Self.publishToSyncRatioCeiling,
            """
            \(variant): 发布步骤占用的主线程时间 \
            \(String(format: "%.0f", measurement.publishMilliseconds))ms 相对同步装载 \
            \(String(format: "%.0f", measurement.synchronousMilliseconds))ms 超过了 \
            \(Int(Self.publishToSyncRatioCeiling * 100))%
            """,
            file: file,
            line: line
        )
    }

    // MARK: - 冷启动 (没有启动缓存 / 派生索引缓存)

    func testColdStartupMovesTheLoadOffTheMainActor() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let measurement = try await measureStartup(
            fixture: fixture,
            variant: "cold",
            cold: true,
            songCount: songCount
        )
        assertPublishStaysOffTheCriticalPath(measurement, songCount: songCount, variant: "cold")
    }

    /// 冷启动发布出整库时, 依赖 `visibleSongCollectionRevision` 的列表与缓存要看到一次变化,
    /// 沿用装载时建好的下标表也不能把这次变化吞掉。
    func testStartupPublishAdvancesVisibleSongCollectionRevision() async throws {
        let fixture = try await Self.makeFixture(songCount: 48)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let library = MusicLibrary.makePreparing(storageDirectory: fixture)
        let before = library.visibleSongCollectionRevision
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: fixture))
        XCTAssertEqual(library.songs.count, 48)
        XCTAssertNotEqual(library.visibleSongCollectionRevision, before)
    }

    // MARK: - 热启动 (启动缓存命中)

    func testWarmStartupMovesTheLoadOffTheMainActor() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.appendingPathComponent("library-startup-cache.plist").path
            ),
            "热启动变体需要夹具里带着启动缓存"
        )

        let measurement = try await measureStartup(
            fixture: fixture,
            variant: "warm",
            cold: false,
            songCount: songCount
        )
        assertPublishStaysOffTheCriticalPath(measurement, songCount: songCount, variant: "warm")
    }

    // MARK: - 真机常见状态: 两份缓存都命中的重复冷启动

    /// 上面的「热启动」夹具只是刚写完库, 装载日志是 `startupCache=miss
    /// derivedCache=miss`, 还会重跑一次装载迁移。真机上反复启动时的状态是
    /// 两份缓存都命中, 这里先完整走一遍准备→发布→落盘把缓存补齐, 再连测几轮。
    func testRepeatedStartupWithBothCachesHit() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let settle = MusicLibrary.makePreparing(storageDirectory: fixture)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: fixture))
        guard case .success = await settle.persistNowAndWait() else {
            throw XCTSkip("The harness fixture did not settle its launch caches")
        }
        await Self.drainLaunchCacheWrites(settle)

        // 原地连测: 启动缓存的指纹带文件编号, 复制出来的目录一定对不上。
        // 两份缓存都命中时装载不写盘, 每一轮读到的是同一份状态。
        var rounds: [Double] = []
        for round in 1...3 {
            let directory = fixture
            let startedAt = ProcessInfo.processInfo.systemUptime
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            let preparedAt = ProcessInfo.processInfo.systemUptime
            let library = MusicLibrary.makePreparing(storageDirectory: directory)
            library.publish(prepared)
            XCTAssertEqual(library.songs.count, songCount)
            // 发布可能顺手刷新过期的启动缓存, 等它落盘, 下一轮才是真机上的稳态。
            await Self.drainLaunchCacheWrites(library)
            rounds.append((preparedAt - startedAt) * 1_000)
            plog(String(format: "🚀 library harness repeated round=%d songs=%d prepare=%.0fms", round, songCount, rounds.last ?? 0))
        }
        plog(String(format: "🚀 library harness repeated songs=%d average=%.0fms", songCount, rounds.reduce(0, +) / Double(rounds.count)))
    }

    /// 等在途的快照与启动缓存写入落完(外部写入栅栏会等这两条链)。
    private static func drainLaunchCacheWrites(_ library: MusicLibrary) async {
        await library.beginExternalSnapshotWrite()
        library.endExternalSnapshotWrite()
    }

    // MARK: - XCTClockMetric 基线

    /// 热启动夹具上的同步装载基线。重复跑是安全的: 启动缓存命中时装载不会
    /// 再补写缓存, 每一轮读到的都是同一份磁盘状态。
    func testSynchronousWarmStartupClockBaseline() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }

        measure(metrics: [XCTClockMetric()]) {
            let library = MusicLibrary(storageDirectory: directory)
            XCTAssertEqual(library.songs.count, songCount)
        }
    }

    // MARK: - 规模实测: 几十万到上百万首的常驻内存

    /// 两步分在两次 `xcodebuild test` 里跑, 测量进程里没有建夹具留下的垃圾:
    /// ```
    /// TEST_RUNNER_PRIMUSE_SCALE_DIR=/path/scale-400000 TEST_RUNNER_PRIMUSE_SCALE_SONGS=400000 \
    ///   xcodebuild test … -only-testing:PrimuseTests/LibraryStartupHarnessTests/testBuildScaleFixture
    /// TEST_RUNNER_PRIMUSE_SCALE_DIR=/path/scale-400000 \
    ///   xcodebuild test … -only-testing:PrimuseTests/LibraryStartupHarnessTests/testScaleFixtureFootprint
    /// ```
    /// 曲库按真实大库的形状造: 中文歌名、多级目录路径、拼音、封面与艺人图文件名,
    /// 单一服务器源为主再加一个小的本机源, 每张专辑 12 首、每位歌手约 3 张专辑。
    private static var scaleDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func residentFootprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint)
    }

    private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    func testBuildScaleFixture() async throws {
        guard let directory = Self.scaleDirectory,
              let raw = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_SONGS"],
              let songCount = Int(raw), songCount > 0 else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR and PRIMUSE_SCALE_SONGS to build the scale fixture")
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let footprintBeforeScan = Self.residentFootprint()
        let library = MusicLibrary(storageDirectory: directory)
        let serverSource = "scale-server-source"
        // 两个都是服务器源: 本机源记录带设备归属, 拷进别的安装里会被当成
        // 别的设备的源清掉, 连带删掉它的歌。
        let secondSource = "scale-second-source"
        let surnames = ["周", "林", "陈", "王", "张", "李", "刘", "杨", "黄", "吴", "赵", "孙"]
        let given = ["杰伦", "俊杰", "奕迅", "菲", "学友", "宇春", "绮贞", "楚生", "鹏", "若昀", "子棋", "雨生"]
        let words = ["夜曲", "晴天", "稻香", "告白气球", "七里香", "青花瓷", "以父之名", "简单爱", "安静", "彩虹", "说好的幸福呢", "听妈妈的话"]
        let genres = ["流行", "Rock", "Jazz", "古典", "民谣", "Electronic", "R&B", "说唱", "Soundtrack", "Metal"]
        let albumCount = max(1, songCount / 12)
        let artistCount = max(1, albumCount / 3)
        func artist(_ index: Int) -> String {
            index % 4 == 0
                ? "Artist Name \(index)"
                : surnames[index % surnames.count] + given[(index / surnames.count) % given.count] + "\(index)"
        }
        var allIDs: [String] = []
        allIDs.reserveCapacity(songCount)
        var batch: [Song] = []
        batch.reserveCapacity(20_000)
        var batchSource = serverSource
        func flush() {
            guard !batch.isEmpty else { return }
            // 和扫描的中间提交一样不剪枝, 也把整库维护延后到最后。
            library.addSongs(
                batch,
                affectedSourceIDs: [batchSource],
                notifyRemovals: false,
                pruneMissingSongs: false,
                indexMaintenance: .deferredIncremental
            )
            batch.removeAll(keepingCapacity: true)
        }
        for index in 0..<songCount {
            let albumIndex = index / 12
            let artistIndex = albumIndex % artistCount
            let sourceID = index < songCount - songCount / 20 ? serverSource : secondSource
            if sourceID != batchSource { flush(); batchSource = sourceID }
            let artistName = artist(artistIndex)
            let albumTitle = words[albumIndex % words.count] + " 专辑 \(albumIndex)"
            let title = words[(index * 7) % words.count] + "（第\(index)首）" + (index % 3 == 0 ? " Live Version" : "")
            let track = index % 12 + 1
            let duration = 180 + Double(index % 240)
            let bitRate = index % 5 == 0 ? 320 : 1_000
            var song = Song(
                id: String(format: "%016llx%016llx%016llx%016llx", UInt64(index) &* 0x9E3779B97F4A7C15, UInt64(index) ^ 0xA5A5_5A5A_DEAD_BEEF, UInt64(index) &* 31, UInt64(index)),
                title: title,
                albumTitle: albumTitle,
                artistName: index % 10 == 0 ? artistName + "、" + artist((artistIndex + 5) % artistCount) : artistName,
                albumArtistName: artistName,
                trackNumber: track,
                discNumber: 1,
                duration: duration,
                fileFormat: index % 5 == 0 ? .mp3 : .flac,
                filePath: "/music/\(artistName)/\(albumTitle)/\(String(format: "%02d", track)) \(title).\(index % 5 == 0 ? "mp3" : "flac")",
                sourceID: sourceID,
                // 与时长、码率对得上, 否则回填的「截断时长」迁移会把它们当坏数据重置。
                fileSize: Int64(duration * Double(bitRate) * 125) + Int64(index % 4_096),
                bitRate: bitRate,
                sampleRate: 44_100,
                bitDepth: index % 5 == 0 ? nil : 16,
                genre: genres[albumIndex % genres.count],
                year: 1980 + albumIndex % 45,
                lastModified: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                coverArtFileName: "al-\(albumIndex)_\(String(format: "%08x", albumIndex &* 2_654_435_761))",
                artistArtworkFileName: "ar-\(artistIndex)_\(String(format: "%08x", artistIndex &* 40_503))"
            )
            if index % 7 == 0 { song.lyricsFileName = "\(String(format: "%02d", track)) \(title).lrc" }
            if index % 4 == 0 {
                song.replayGainTrackGain = -6.5
                song.replayGainTrackPeak = 0.98
            }
            allIDs.append(song.id)
            batch.append(song)
            if batch.count == 20_000 { flush() }
        }
        flush()
        await library.waitForPendingIndex()
        // 首轮扫描刚入库完的常驻: 和下次启动从增量库装载时应当相当。
        let footprintAfterScan = Self.residentFootprint()
        for playlistIndex in 0..<30 {
            let start = (playlistIndex * 7_919) % max(1, songCount)
            let ids = Array(allIDs[start..<min(allIDs.count, start + 500)])
            _ = library.createPlaylist(name: "Scale \(playlistIndex)", songIDs: ids)
        }
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The scale fixture did not persist")
            return
        }
        await Self.drainLaunchCacheWrites(library)
        // 夹具目录可以整份拷进模拟器里 App 的 Application Support/Primuse 当真实曲库用:
        // 源记录也写进去, 否则启动对账会把找不到来源的歌清掉。服务器指向一个
        // 连不上的地址, 界面照常浏览, 只是不能真的播放。
        let sources = SourcesStore(storageDirectoryURL: directory)
        try sources.addDurably(MusicSource(
            id: serverSource, name: "Scale Navidrome", type: .navidrome,
            host: "127.0.0.1", port: 9, useSsl: false, username: "scale"
        ))
        try sources.addDurably(MusicSource(
            id: secondSource, name: "Scale Navidrome 2", type: .navidrome,
            host: "127.0.0.1", port: 10, useSsl: false, username: "scale"
        ))
        // 再走一遍真机的启动路径, 把启动缓存与派生索引缓存补齐成稳态。
        let settle = MusicLibrary.makePreparing(storageDirectory: directory)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await settle.waitForPendingIndex()
        _ = await settle.persistNowAndWait()
        await Self.drainLaunchCacheWrites(settle)
        let summary = String(
            format: "📏 scale fixture songs=%d built in %.0fs scanResident=%.0fMB scanPeak=%.0fMB dir=%@",
            library.songs.count, ProcessInfo.processInfo.systemUptime - startedAt,
            Self.megabytes(footprintAfterScan.current) - Self.megabytes(footprintBeforeScan.current),
            Self.megabytes(footprintAfterScan.peak), directory.path
        )
        plog(summary)
        print(summary)
        XCTAssertEqual(settle.songs.count, songCount)
    }

    /// 测量前在夹具副本上先走一遍启动: 副本的文件号变了, 启动缓存与派生缓存
    /// 都要按新的快照指纹重写一次, 之后量到的才是日常的二次启动。
    func testSettleScaleFixture() async throws {
        guard let directory = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let settle = MusicLibrary.makePreparing(storageDirectory: directory)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await settle.waitForPendingIndex()
        _ = await settle.persistNowAndWait()
        await Self.drainLaunchCacheWrites(settle)
    }

    func testScaleFixtureSmallStateWritesAndIdleCPU() async throws {
        guard let directory = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await library.waitForPendingIndex()
        let ids = library.songs.map(\.id)
        guard ids.count >= 10 else { return XCTFail("scale fixture is too small") }
        _ = library.createPlaylist(name: "Scale full catalog", songIDs: ids)
        _ = library.createPlaylist(name: "Scale catalog subset", songIDs: Array(ids.prefix(ids.count / 4)))
        _ = await library.persistNowAndWait()
        await Self.drainLaunchCacheWrites(library)
        let baseURL = directory.appendingPathComponent("library-cache.json")
        let cacheURL = directory.appendingPathComponent("library-startup-cache.plist")
        let deltaURL = directory.appendingPathComponent("library-cache.delta.plist")
        let base = try baseURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let cache = try cacheURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let cpu = ImportLoadMatrixTests.cpuSeconds()
        let started = ProcessInfo.processInfo.systemUptime
        var deltaBytes = 0
        for id in ids.prefix(6) {
            library.recordPlayback(of: id)
            guard case .success = await library.persistNowAndWait(materializePortableSnapshot: false) else {
                return XCTFail("scale delta did not persist")
            }
            deltaBytes += try deltaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        XCTAssertEqual(try baseURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       base.contentModificationDate)
        XCTAssertEqual(try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       cache.contentModificationDate)
        print(String(format: "REPORT_SCALE_WRITE songs=%d baseBytes=%d cacheBytes=%d sixDeltaBytes=%d wall=%.3f cpu=%.3f memoryMB=%.1f",
                     ids.count, base.fileSize ?? 0, cache.fileSize ?? 0, deltaBytes,
                     ProcessInfo.processInfo.systemUptime - started, ImportLoadMatrixTests.cpuSeconds() - cpu, Self.megabytes(Self.residentFootprint().current)))
        let idleCPU = ImportLoadMatrixTests.cpuSeconds()
        let idleStarted = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(30))
        print(String(format: "REPORT_SCALE_IDLE wall=%.3f cpu=%.3f memoryMB=%.1f",
                     ProcessInfo.processInfo.systemUptime - idleStarted, ImportLoadMatrixTests.cpuSeconds() - idleCPU,
                     Self.megabytes(Self.residentFootprint().current)))
        library.releaseRebuildableCaches()
        print(String(format: "REPORT_SCALE_PRESSURE memoryMB=%.1f materializedRows=%d", Self.megabytes(Self.residentFootprint().current), library.materializedSongRowCount))
    }

    /// 同一份夹具再开一次曲库目录(首次从 `library-songs.sqlite` 迁移):量内存模型之外,目录本身
    /// 多出来的常驻、迁移的峰值,以及走一遍目录读(计数、排序行号、专辑、按 id 取页)之后的常驻。
    /// 在夹具的副本上跑,目录文件不写进夹具目录(后面纯内存那项测量的输入不变)。
    func testScaleFixtureFootprintWithCatalog() async throws {
        guard let fixture = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = Self.residentFootprint()
        let library: MusicLibrary
        do {
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
            library.publish(prepared)
        }
        await library.waitForPendingIndex()
        try await Task.sleep(for: .seconds(2))
        let memoryModel = Self.residentFootprint()
        let migrationStartedAt = ProcessInfo.processInfo.systemUptime
        await library.waitForCatalogMirror()
        let migrationSeconds = ProcessInfo.processInfo.systemUptime - migrationStartedAt
        let migrated = Self.residentFootprint()
        let host = try XCTUnwrap(library.catalogHost)
        XCTAssertTrue(host.revisions.isReadable, "the catalog is readable after the migration")
        try await Task.sleep(for: .seconds(2))
        let settled = Self.residentFootprint()

        let reader = host.reader
        let readsStartedAt = ProcessInfo.processInfo.systemUptime
        let counts = try await reader.counts()
        var pagedRows = 0
        for order in [LibrarySongSortOrder.title, .artist, .album, .dateAdded] {
            let list = try await reader.songRowList(order: order)
            let page = Array(list.rowids.prefix(200))
            pagedRows += try await reader.songs(rowids: page).count
        }
        let albumKeys = try await reader.read { try $0.albumKeys(visibleOnly: true).keys }
        let albums = try await reader.read { try $0.albums(keys: albumKeys.prefix(200), visibleCounts: true) }
        let readsMilliseconds = (ProcessInfo.processInfo.systemUptime - readsStartedAt) * 1_000
        try await Task.sleep(for: .seconds(2))
        let afterReads = Self.residentFootprint()
        _ = try await reader.read { catalog -> Bool in catalog.releaseMemory(); return true }
        try await Task.sleep(for: .seconds(1))
        let released = Self.residentFootprint()
        let summary = String(
            format: "📏 scale catalog songs=%d memoryModel=%.0fMB migration=%.1fs migrationPeak=%.0fMB catalogResident=%.0fMB "
                + "reads=%.0fms readsResident=%.0fMB released=%.0fMB pagedRows=%d albums=%d/%d visible=%d",
            library.songs.count,
            Self.megabytes(memoryModel.current) - Self.megabytes(before.current),
            migrationSeconds,
            Self.megabytes(migrated.peak) - Self.megabytes(memoryModel.current),
            Self.megabytes(settled.current) - Self.megabytes(memoryModel.current),
            readsMilliseconds,
            Self.megabytes(afterReads.current) - Self.megabytes(settled.current),
            Self.megabytes(released.current) - Self.megabytes(settled.current),
            pagedRows, albums.count, albumKeys.count, counts.visibleSongs
        )
        plog(summary)
        print(summary)
        XCTAssertEqual(counts.visibleSongs, library.visibleSongs.count)
        await library.stopCatalogMirror()
    }

    // MARK: - 歌曲模型不常驻之前的三项测量(P3-design「Route to S1/S2」步骤 0)

    /// 带目录的规模夹具: `PRIMUSE_SCALE_DIR` 旁边的 `<名字>-catalog`, 是规模夹具的副本加上迁移好的
    /// 曲库目录(正好在旧库的修订号上)。各项测量在它的副本上跑, 夹具本身不动。
    private static var scaleCatalogDirectory: URL? {
        scaleDirectory.map {
            $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + "-catalog", isDirectory: true)
        }
    }

    private static func existingScaleCatalogFixture() throws -> URL {
        guard let fixture = scaleCatalogDirectory,
              FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-catalog.sqlite").path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        return fixture
    }

    /// 走真机的启动路径装载曲库并带上目录, 等派生索引与目录都落定、目录可读。
    private static func loadLibraryWithCatalog(_ directory: URL) async throws -> (MusicLibrary, LibraryCatalogHost) {
        let library: MusicLibrary
        do {
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
            library.publish(prepared)
        }
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        let host = try XCTUnwrap(library.catalogHost)
        for _ in 0..<1_000 where !host.revisions.isReadable { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(host.revisions.isReadable, "the catalog is readable once the mirror is idle")
        return (library, host)
    }

    /// malloc 各区里还在用的字节数: 放掉模型之后它降了多少是「释放了多少」, footprint 降了多少是
    /// 「还给系统多少」, 两者之差就是留在空闲表里的碎片。
    private static func mallocBytesInUse() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }

    private static func microseconds(_ body: () throws -> Void) rethrows -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000
    }

    /// 中位数、p95、最大、平均(微秒)。
    private static func distribution(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "n=0" }
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        return String(
            format: "n=%d median=%.1fµs p95=%.1fµs max=%.1fµs mean=%.1fµs",
            sorted.count, at(0.5), at(0.95), sorted[sorted.count - 1], sorted.reduce(0, +) / Double(sorted.count)
        )
    }

    private static func report(_ line: String) {
        plog(line)
        print(line)
    }

    func testBuildScaleCatalogFixture() async throws {
        guard let fixture = Self.scaleDirectory, let directory = Self.scaleCatalogDirectory,
              FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.copyItem(at: fixture, to: directory)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let (library, host) = try await Self.loadLibraryWithCatalog(directory)
        let migrationSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        // 副本的文件号变了: 启动缓存与派生缓存按新的指纹重写一次, 之后在它上面量到的才是日常的二次启动。
        _ = await library.persistNowAndWait()
        await Self.drainLaunchCacheWrites(library)
        await library.waitForCatalogMirror()
        let catalog = try XCTUnwrap(host.mirror.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), library.songs.count)
        let storeRevision = try IncrementalSongStoreScanner(
            path: directory.appendingPathComponent("library-songs.sqlite").path
        ).contentRevision()
        XCTAssertEqual(host.mirror.mirroredStoreRevision, storeRevision, "the fixture's catalog is at the store's revision")
        Self.report(String(
            format: "📏 scale catalog fixture songs=%d loadAndMigrate=%.1fs storeRevision=%lld dir=%@",
            library.songs.count, migrationSeconds, storeRevision, directory.path
        ))
        await library.stopCatalogMirror()
    }

    /// 步骤 0a: 装好的歌曲模型放掉之后, 有多少内存回到系统。先只放歌曲那一层(以后「不常驻」留在
    /// 内存里的是专辑、艺人那一层), 再连专辑、艺人一起放, 最后放目录自己的页缓存。
    func testScaleFixtureReleaseYield() async throws {
        let fixture = try Self.existingScaleCatalogFixture()
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = Self.residentFootprint().current
        let inUseBefore = Self.mallocBytesInUse()
        let (library, host) = try await Self.loadLibraryWithCatalog(directory)
        try await Task.sleep(for: .seconds(2))
        await MusicLibrary.drainDisplacedArraysForMeasurement()
        let songCount = library.songs.count
        let albumCount = library.albums.count
        let loaded = Self.residentFootprint().current
        let inUseLoaded = Self.mallocBytesInUse()
        // 放之前先确认目录这一边答得出来: 之后按 id 读靠它。
        let sampleID = try XCTUnwrap(library.songs.last?.id)
        XCTAssertEqual(try host.songLookup()?.song(id: sampleID)?.id, sampleID)

        func settle() async throws -> (footprint: UInt64, inUse: UInt64) {
            await MusicLibrary.drainDisplacedArraysForMeasurement()
            try await Task.sleep(for: .milliseconds(500))
            await MusicLibrary.returnFreedMemoryToSystem()
            try await Task.sleep(for: .seconds(1))
            return (Self.residentFootprint().current, Self.mallocBytesInUse())
        }

        library.dropSongModelForMeasurement(includingCollections: false)
        await MusicLibrary.drainDisplacedArraysForMeasurement()
        try await Task.sleep(for: .milliseconds(500))
        let droppedBeforeRelief = Self.residentFootprint().current
        let songsDropped = try await settle()
        library.dropSongModelForMeasurement(includingCollections: true)
        let collectionsDropped = try await settle()
        host.mirror.readableCatalog?.live.releaseMemory()
        host.reader.rowCache.removeAll()
        let catalogReleased = try await settle()
        // 放掉之后模型已经不在了, 按 id 读照样有答案: 由目录来答(步骤 1)。
        XCTAssertEqual(try host.songLookup()?.song(id: sampleID)?.id, sampleID)
        XCTAssertEqual(library.storedSong(id: sampleID)?.id, sampleID)
        XCTAssertTrue(library.songs.isEmpty)

        func megabytes(_ bytes: UInt64) -> Double { Self.megabytes(bytes) }
        func delta(_ later: UInt64, _ earlier: UInt64) -> Double { megabytes(later) - megabytes(earlier) }
        let model = delta(loaded, before)
        func returned(_ footprint: UInt64) -> Double { model > 0 ? (megabytes(loaded) - megabytes(footprint)) / model : 0 }
        Self.report(String(
            format: "📏 release yield songs=%d albums=%d before=%lld loaded=%lld modelBytes=%lld perSong=%.0fB | "
                + "songsDropped=%lld (beforeRelief=%lld) returned=%.1fMB fraction=%.3f | "
                + "collectionsDropped=%lld returned=%.1fMB fraction=%.3f | catalogReleased=%lld returned=%.1fMB fraction=%.3f",
            songCount, albumCount, before, loaded, loaded - min(loaded, before), model * 1_048_576 / Double(max(1, songCount)),
            songsDropped.footprint, droppedBeforeRelief, delta(loaded, songsDropped.footprint), returned(songsDropped.footprint),
            collectionsDropped.footprint, delta(loaded, collectionsDropped.footprint), returned(collectionsDropped.footprint),
            catalogReleased.footprint, delta(loaded, catalogReleased.footprint), returned(catalogReleased.footprint)
        ))
        Self.report(String(
            format: "📏 release yield malloc inUse: before=%.1fMB loaded=%.1fMB songsDropped=%.1fMB collectionsDropped=%.1fMB "
                + "catalogReleased=%.1fMB | freed by dropping songs=%.1fMB, of which back to the system=%.1fMB",
            megabytes(inUseBefore), megabytes(inUseLoaded), megabytes(songsDropped.inUse), megabytes(collectionsDropped.inUse),
            megabytes(catalogReleased.inUse), delta(inUseLoaded, songsDropped.inUse), delta(loaded, songsDropped.footprint)
        ))
        XCTAssertGreaterThan(songCount, 0)
        await library.stopCatalogMirror()
    }

    /// 步骤 6d: 经真正的放掉(`releaseSongModelIfIdle`,歌曲与专辑、艺人那一层一起)放掉多少、再放目录的页缓存
    /// 之后剩多少、装回来(只装歌曲模型)要多久;放掉之后删一首歌时,主线程上读目录的那几下(按源剩余数、
    /// 歌单引用到的歌找同名的另一份)要多久。
    func testScaleFixtureResidencyReleaseAndReload() async throws {
        let fixture = try Self.existingScaleCatalogFixture()
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = Self.residentFootprint().current
        let (library, host) = try await Self.loadLibraryWithCatalog(directory)
        try await Task.sleep(for: .seconds(2))
        await library.waitForPendingIndex()
        await MusicLibrary.drainDisplacedArraysForMeasurement()
        let songCount = library.songs.count
        let albumCount = library.albums.count
        let samples = Array(library.visibleSongs.prefix(2))
        XCTAssertEqual(samples.count, 2)
        func settle() async throws -> UInt64 {
            await MusicLibrary.drainDisplacedArraysForMeasurement()
            try await Task.sleep(for: .milliseconds(500))
            await MusicLibrary.returnFreedMemoryToSystem()
            try await Task.sleep(for: .seconds(1))
            return Self.residentFootprint().current
        }
        // 歌单同步那样对整库算一遍匹配键(缓存有上限,看它记了多少、放掉之后还剩多少)。
        _ = PlaylistEntryMatcher(songs: library.visibleSongs, keyCache: library.playlistEntryMatchKeyCache)
        let keyCacheLoaded = library.playlistEntryMatchKeyCache.count
        let loaded = try await settle()
        library.applySongModelResidencySettings(.init(isEnabled: true, foregroundHold: false, playbackBlocksRelease: true))

        // 启动后排的影子校验(开发构建里 10 万首以内是深的那种,拿着整份数组)做完之前放不掉:等它。
        var started = ContinuousClock.now
        var outcome = await library.releaseSongModelIfIdle(trigger: "scale harness")
        for _ in 0..<120 where outcome == .skipped("catalog shadow verification in flight") {
            try await Task.sleep(for: .seconds(1))
            started = ContinuousClock.now
            outcome = await library.releaseSongModelIfIdle(trigger: "scale harness")
        }
        let releaseMs = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
        guard case .released = outcome else { return XCTFail("not released: \(outcome)") }
        await library.songModelReleaseDidReclaimMemory()
        let reclaimed = Self.residentFootprint().current
        let keyCacheReleased = library.playlistEntryMatchKeyCache.count
        let released = try await settle()
        // 挂起之前那一次(19d):目录各连接、跟旧库的只读连接、旧库本身的页缓存,做完才返回。
        await library.releaseDatabaseMemoryAndWait()
        host.reader.rowCache.removeAll()
        let catalogReleased = try await settle()
        XCTAssertEqual(library.storedSong(id: samples[0].id)?.id, samples[0].id, "by-id reads answer from the catalog")

        started = ContinuousClock.now
        let hold = await library.holdSongModel(.legacyPage)
        let loadMs = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
        let statistics = library.songModelResidencyStatistics
        XCTAssertEqual(library.songs.count, songCount)
        XCTAssertEqual(statistics.wholeLibraryLoads, 0, "the fixture's store is one a launch has seen")
        let reloaded = try await settle()
        // CK-b:一张两千首的别的设备的歌单,成员均匀取自整库(只留身份,不留歌曲数组):一张按 id 全认得出,
        // 一张全要按标题认(id 与路径都换掉)。放掉之后再量。
        let (exactIdentities, titleIdentities) = { () -> ([SongIdentity], [SongIdentity]) in
            let all = library.songs
            let sample = stride(from: 0, to: all.count, by: max(1, all.count / 2_000)).prefix(2_000).map { all[$0] }
            let exact = sample.map {
                SongIdentity(songID: $0.id, title: $0.title, artistName: $0.artistName, duration: $0.duration,
                             cloudAccountID: nil, filePath: $0.filePath)
            }
            let byTitle = sample.enumerated().map { offset, song in
                SongIdentity(songID: "remote-\(offset)", title: song.title, artistName: song.artistName,
                             duration: song.duration, cloudAccountID: nil, filePath: "/remote/\(offset).flac")
            }
            return (exact, byTitle)
        }()
        hold.end()

        // 放掉之后删歌:一首没有歌单引用的(只数按源剩余),一首歌单里有的(另外按标题找另一份)。
        let playlist = library.createPlaylist(name: "Scale harness", songIDs: [samples[0].id])
        var second = await library.releaseSongModelIfIdle(trigger: "scale harness delete")
        for _ in 0..<120 where second == .skipped("catalog shadow verification in flight") {
            try await Task.sleep(for: .seconds(1))
            second = await library.releaseSongModelIfIdle(trigger: "scale harness delete")
        }
        guard case .released = second else { return XCTFail("not released again: \(second)") }
        await library.songModelReleaseDidReclaimMemory()
        // CK-b:放掉之后收到那张歌单:身份与候选(主线程外读目录)与落地之前的核对(主线程,不读目录)各要多久。
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
        }
        let loadsBeforeIdentities = library.songModelResidencyStatistics.loads
        var identityStart = ContinuousClock.now
        let exactResolution = await library.prepareCatalogIdentityResolution(for: exactIdentities)
        let exactPrepareMs = milliseconds(since: identityStart)
        identityStart = ContinuousClock.now
        let exactReady = exactResolution.map { library.readyToResolveRemoteIdentities($0) } ?? false
        let exactReadyMs = milliseconds(since: identityStart)
        identityStart = ContinuousClock.now
        let titleResolution = await library.prepareCatalogIdentityResolution(for: titleIdentities)
        let titlePrepareMs = milliseconds(since: identityStart)
        identityStart = ContinuousClock.now
        let titleReady = titleResolution.map { library.readyToResolveRemoteIdentities($0) } ?? false
        let titleReadyMs = milliseconds(since: identityStart)
        XCTAssertTrue(exactReady, "exact ids: answered from the catalog")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, loadsBeforeIdentities, "no load for the identity candidates")

        // 删歌那条路在主线程上读目录的两下,单独量:按源剩余数(整表 GROUP BY),同名的另一份(整表标题一列)。
        let lookup = try XCTUnwrap(host.songLookup(), "the catalog answers right after the release")
        let usableBeforeDelete = library.isUsable
        let queuedBeforeDelete = library.deferredMutationCountForTesting
        var countsAnswered = false
        let countsRead = Self.microseconds {
            countsAnswered = (try? lookup.songCountsBySource(treatingAsRemoved: [samples[1].id])) != nil
        }
        let titleHead = String(samples[0].title.prefix { !"([（【［".contains($0) }.lowercased().filter { !$0.isWhitespace })
        var titleCandidates = -2
        let titleRead = Self.microseconds {
            do {
                titleCandidates = try lookup.songs(titleMatching: { title in
                    String(title.prefix { !"([（【［".contains($0) }.lowercased().filter { !$0.isWhitespace }) == titleHead
                })?.count ?? -1
            } catch {
                titleCandidates = -2
            }
        }
        let plainDelete = Self.microseconds { _ = library.deleteSongs([samples[1]]) }
        let plainQueued = library.deferredMutationCountForTesting
        let referencedDelete = Self.microseconds { _ = library.deleteSongs([samples[0]]) }
        let referencedQueued = library.deferredMutationCountForTesting
        let loadAfterDelete = library.isLoadingSongModelForTesting
        for _ in 0..<600 where !library.isReady && library.isLoadingSongModelForTesting {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(library.rawSongIDs(forPlaylist: playlist.id).contains(samples[0].id))

        func megabytes(_ bytes: UInt64) -> Double { Self.megabytes(bytes) }
        Self.report(String(
            format: "📏 residency yield: matchKeyCache loaded=%d released=%d | footprint right after the library's own reclaim=%.1fMB",
            keyCacheLoaded, keyCacheReleased, Self.megabytes(reclaimed)
        ))
        Self.report(String(
            format: "📏 residency songs=%d albums=%d before=%.1fMB loaded=%.1fMB released=%.1fMB catalogReleased=%.1fMB "
                + "reloaded=%.1fMB | releaseMs=%.0f loadMs=%.0f (library ms=%d derived=%@ journalRows=%d)",
            songCount, albumCount, megabytes(before), megabytes(loaded), megabytes(released), megabytes(catalogReleased),
            megabytes(reloaded), releaseMs, loadMs, statistics.lastLoadMilliseconds,
            statistics.lastLoadUsedDerivedCache ? "cache" : "rebuilt", statistics.lastLoadJournalRows
        ))
        Self.report(String(
            format: "📏 residency delete while released: usable=%@ queuedBefore=%d countsBySource=%.1fms answered=%@ titleProjection=%.1fms "
                + "candidates=%d (-1 = more than the cap) | deleteSongs plain=%.1fms (queued=%d) playlistMember=%.1fms "
                + "(queued=%d, loadStarted=%@)",
            usableBeforeDelete ? "yes" : "no", queuedBeforeDelete, countsRead / 1_000, countsAnswered ? "yes" : "no", titleRead / 1_000,
            titleCandidates, plainDelete / 1_000, plainQueued, referencedDelete / 1_000, referencedQueued,
            loadAfterDelete ? "yes" : "no"
        ))
        Self.report(String(
            format: "📏 CK-b identity candidates while released (%d members): exact ids prepare=%.1fms ready=%.1fms (%@) | "
                + "by title prepare=%.1fms ready=%.1fms rows=%d (%@)",
            exactIdentities.count, exactPrepareMs, exactReadyMs, exactReady ? "answered" : "held",
            titlePrepareMs, titleReadyMs, titleResolution?.candidateCount ?? -1, titleReady ? "answered" : "held"
        ))
        await library.stopCatalogMirror()
    }

    /// 步骤 6e: 不装歌曲模型的启动。构造(准备中)到能用(只装小状态、目录接上读得了)要多久、能用时占多少;
    /// 之后拿占用装上模型要多久、装上之后占多少。整库的歌一首都不从旧库读(计数器)。
    func testScaleFixtureUnloadedLaunch() async throws {
        let fixture = try Self.existingScaleCatalogFixture()
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        func settle() async throws -> UInt64 {
            await MusicLibrary.drainDisplacedArraysForMeasurement()
            try await Task.sleep(for: .milliseconds(500))
            await MusicLibrary.returnFreedMemoryToSystem()
            try await Task.sleep(for: .seconds(1))
            return Self.residentFootprint().current
        }
        let before = try await settle()
        let readsBefore = MusicLibrary.songModelStoreReads.withLock { $0 }
        // 规模夹具在外接盘上,冷开大目录要几秒:这里量的是不装模型时的样子,不是启动条件第 4 条的等待上限。
        let catalogWait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(20)
        defer { MusicLibrary.unloadedLaunchCatalogWait = catalogWait }
        let started = ContinuousClock.now
        let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
        library.applySongModelResidencySettings(.init(
            isEnabled: true, foregroundHold: false, playbackBlocksRelease: true, launchUnloaded: true
        ))
        let classification = SpokenWordStore.shared.classificationSnapshot
        library.startCatalogBeforePublish(spokenWordClassification: classification)
        let prepared = await MusicLibrary.prepareStartup(
            storageDirectory: directory, spokenWordClassification: classification, withoutTheSongModel: true
        )
        await library.publishStartup(prepared) {
            await MusicLibrary.prepareStartup(storageDirectory: directory, spokenWordClassification: classification)
        }
        await library.whenUsable()
        let usableMs = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        XCTAssertTrue(library.isUsable)
        XCTAssertFalse(library.isReady)
        let usable = try await settle()
        let readsAfterLaunch = MusicLibrary.songModelStoreReads.withLock { $0 }
        XCTAssertEqual(readsAfterLaunch, readsBefore, "the launch read no song from the store")
        // 发布时补的有声 / 环境音 id 表:这份夹具里一首都没有(花的时间在 `🧠 residency launch=unloaded … classificationMs=`)。
        // 上限:整库都是有声时要读的那么多 id,拿音乐那一份量。
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        let idSetStarted = ContinuousClock.now
        let everyID = try catalog.songIDSet(LibrarySongScope(kinds: [.music]))
        let idSetMs = Double((ContinuousClock.now - idSetStarted) / .microseconds(1)) / 1_000
        Self.report(String(format: "📏 unloaded launch: reading %d ids of one kind (the upper bound of the spoken-word set) took %.0fms",
                           everyID.count, idSetMs))

        let loadStarted = ContinuousClock.now
        let hold = await library.holdSongModel(.legacyPage)
        let loadMs = Double((ContinuousClock.now - loadStarted) / .microseconds(1)) / 1_000
        let songCount = library.songs.count
        let loaded = try await settle()
        hold.end()
        func megabytes(_ bytes: UInt64) -> Double { Self.megabytes(bytes) }
        Self.report(String(
            format: "📏 unloaded launch songs=%d before=%.1fMB usable=%.1fMB (grew %.1fMB) usableAfter=%.0fms "
                + "(catalog wait %dms) launch=%@ | hold→ready %.0fms derived=%@ loaded=%.1fMB wholeLibraryLoads=%d "
                + "storeReadsDuringLaunch=%d",
            songCount, megabytes(before), megabytes(usable), megabytes(usable) - megabytes(before), usableMs,
            library.songModelResidencyStatistics.launchCatalogMilliseconds, library.songModelLaunch, loadMs,
            library.songModelResidencyStatistics.lastLoadUsedDerivedCache ? "cache" : "rebuilt", megabytes(loaded),
            library.songModelResidencyStatistics.wholeLibraryLoads, readsAfterLaunch - readsBefore
        ))
        XCTAssertGreaterThan(songCount, 0)
        await library.stopCatalogMirror()
    }

    /// 步骤 0b: 主线程上按 id 读一首(待写登记 → 目录)要多久。冷(这一行还没读过)、重复读、经行缓存、
    /// 一屏列表那么多(50 个不同的 id)连着读、读连接都被整库查询占着的时候。
    func testScaleFixtureByIDReadCost() async throws {
        let fixture = try Self.existingScaleCatalogFixture()
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (library, host) = try await Self.loadLibraryWithCatalog(directory)
        let lookup = try XCTUnwrap(host.songLookup())
        let catalog = try XCTUnwrap(host.mirror.readableCatalog)
        let rowCache = host.reader.rowCache
        let allIDs = library.songs.map(\.id)
        let count = allIDs.count
        guard count >= 20_000 else { return XCTFail("scale fixture is too small") }
        // 五组互不相交的 id, 都散在整库各处(步长与库的大小互质, 起点错开)。
        func sample(_ size: Int, offset: Int) -> [String] {
            (0..<size).map { allIDs[(offset + $0 * 7_919) % count] }
        }
        let cold = sample(2_000, offset: 0)
        let cached = sample(2_000, offset: 1)
        let burstSingles = sample(1_000, offset: 2)
        let burstBatched = sample(1_000, offset: 3)
        // 读连接被占着时每读一首可能要等一整趟遍历, 这一组少取一些。
        let contended = sample(200, offset: 4)
        XCTAssertEqual(Set(cold + cached + burstSingles + burstBatched + contended).count, 6_200)

        /// 逐个读并计时(断言不算在里面), 返回各次的微秒数与读到的首数。
        func timeEach(_ ids: [String], _ read: (String) throws -> Song?) rethrows -> (samples: [Double], found: Int) {
            var samples: [Double] = []
            samples.reserveCapacity(ids.count)
            var found = 0
            for id in ids {
                var song: Song?
                samples.append(try Self.microseconds { song = try read(id) })
                if song != nil { found += 1 }
            }
            return (samples, found)
        }

        let memory = timeEach(cold) { library.storedSong(id: $0) }
        XCTAssertEqual(memory.found, cold.count)
        Self.report("📏 by-id memory storedSong \(Self.distribution(memory.samples))")

        // 1. 现成的 `LibraryCatalogSongLookup.song(id:)`: 待写登记 → 目录按 id 查一行(不经行缓存)。
        var timed = try timeEach(cold) { try lookup.song(id: $0) }
        XCTAssertEqual(timed.found, cold.count)
        Self.report("📏 by-id lookup cold first10=\(timed.samples.prefix(10).map { String(format: "%.0f", $0) }.joined(separator: ",")) \(Self.distribution(timed.samples))")
        timed = try timeEach(cold) { try lookup.song(id: $0) }
        XCTAssertEqual(timed.found, cold.count)
        Self.report("📏 by-id lookup repeated \(Self.distribution(timed.samples))")
        timed = try timeEach((0..<2_000).map { "missing-\($0)" }) { try lookup.song(id: $0) }
        XCTAssertEqual(timed.found, 0)
        Self.report("📏 by-id lookup missing \(Self.distribution(timed.samples))")

        // 2. id → 行号, 再经行缓存(现成的接口拼起来): 没缓存、已缓存。
        func throughRowCache(_ id: String) throws -> Song? {
            guard let rowid = try catalog.songRowid(id: id) else { return nil }
            return try rowCache.songs(forRowids: [rowid], in: catalog).first ?? nil
        }
        timed = try timeEach(cached) { try throughRowCache($0) }
        XCTAssertEqual(timed.found, cached.count)
        Self.report("📏 by-id rowid+rowCache miss \(Self.distribution(timed.samples))")
        timed = try timeEach(cached) { try throughRowCache($0) }
        XCTAssertEqual(timed.found, cached.count)
        Self.report("📏 by-id rowid+rowCache hit \(Self.distribution(timed.samples))")
        var rowidSamples: [Double] = []
        for id in cached { rowidSamples.append(try Self.microseconds { _ = try catalog.songRowid(id: id) }) }
        Self.report("📏 by-id rowid only \(Self.distribution(rowidSamples))")

        // 3. 一屏列表: 50 个没读过的 id, 一首一首读 / 一次查完。
        var burstTotals: [Double] = []
        for start in stride(from: 0, to: burstSingles.count, by: 50) {
            let ids = burstSingles[start..<(start + 50)]
            burstTotals.append(try Self.microseconds { for id in ids { _ = try lookup.song(id: id) } })
        }
        Self.report("📏 by-id burst50 one-by-one (per burst) \(Self.distribution(burstTotals))")
        burstTotals = []
        for start in stride(from: 0, to: burstBatched.count, by: 50) {
            let ids = Array(burstBatched[start..<(start + 50)])
            var fetched = 0
            burstTotals.append(try Self.microseconds { fetched = try catalog.songs(ids: ids).count })
            XCTAssertEqual(fetched, 50)
        }
        Self.report("📏 by-id burst50 batched (per burst) \(Self.distribution(burstTotals))")

        // 4. 两个读连接都被整库遍历占着时(排序、计数、流式遍历这类查询在主线程外跑): 主线程上的按 id 读。
        let stop = InteractionFlag()
        let holders = (0..<LibraryScale.maximumReaderCount).map { _ in
            Task.detached(priority: .userInitiated) {
                var passes = 0
                while !stop.isSet {
                    try? catalog.forEachSongIdentity(.everything) { _, _, _ in !stop.isSet }
                    passes += 1
                }
                return passes
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        timed = try timeEach(contended) { try lookup.song(id: $0) }
        stop.set(true)
        var passes = 0
        for holder in holders { passes += await holder.value }
        XCTAssertEqual(timed.found, contended.count)
        Self.report("📏 by-id lookup with both readers busy (whole-table passes=\(passes)) \(Self.distribution(timed.samples))")

        // 5. 模型不在内存里时的各个入口本身(步骤 1): 放掉模型, 按 id 读由「待写登记 → 行缓存 → 目录」来答。
        let albumIDs = Array(library.albums.prefix(400).map(\.id))
        let artistIDs = Array(library.artists.prefix(400).map(\.id))
        let albumSongSampleIDs = Array(albumIDs.prefix(100))
        library.dropSongModelForMeasurement(includingCollections: true)
        host.reader.rowCache.removeAll()
        let facadeCold = sample(1_000, offset: 5)
        let facadeScreens = sample(1_000, offset: 6)
        timed = timeEach(facadeCold) { library.unobservedVisibleSong(id: $0) }
        XCTAssertEqual(timed.found, facadeCold.count)
        Self.report("📏 by-id facade unobservedVisibleSong first read \(Self.distribution(timed.samples))")
        timed = timeEach(facadeCold) { library.unobservedVisibleSong(id: $0) }
        XCTAssertEqual(timed.found, facadeCold.count)
        Self.report("📏 by-id facade unobservedVisibleSong cached \(Self.distribution(timed.samples))")
        timed = timeEach(facadeCold) { library.song(id: $0) }
        Self.report("📏 by-id facade song(id:) cached \(Self.distribution(timed.samples))")
        timed = timeEach(facadeCold) { library.songForSynchronization(id: $0) }
        Self.report("📏 by-id facade songForSynchronization cached \(Self.distribution(timed.samples))")
        timed = timeEach((0..<1_000).map { "absent-\($0)" }) { library.storedSong(id: $0) }
        XCTAssertEqual(timed.found, 0)
        Self.report("📏 by-id facade storedSong absent \(Self.distribution(timed.samples))")
        // 一屏 50 行: 列表先按行号取这一页(行缓存里就有了), 行视图再逐个按 id 读。
        var pageTotals: [Double] = []
        var rowTotals: [Double] = []
        for start in stride(from: 0, to: facadeScreens.count, by: 50) {
            let ids = Array(facadeScreens[start..<(start + 50)])
            let rowids = try catalog.rowids(forIDs: ids).compactMap { $0 }
            pageTotals.append(try Self.microseconds { _ = try rowCache.songs(forRowids: rowids, in: catalog) })
            var found = 0
            rowTotals.append(Self.microseconds { for id in ids where library.unobservedVisibleSong(id: id) != nil { found += 1 } })
            XCTAssertEqual(found, 50)
        }
        Self.report("📏 by-id facade screen of 50: page fetch by rowid (per screen) \(Self.distribution(pageTotals))")
        Self.report("📏 by-id facade screen of 50: 50 row reads after the page fetch (per screen) \(Self.distribution(rowTotals))")
        var albumSamples: [Double] = []
        var albumsFound = 0
        for id in albumIDs {
            albumSamples.append(Self.microseconds { if library.visibleAlbum(id: id) != nil { albumsFound += 1 } })
        }
        Self.report("📏 by-id facade visibleAlbum first read found=\(albumsFound) \(Self.distribution(albumSamples))")
        albumSamples = albumIDs.map { id in Self.microseconds { _ = library.visibleAlbum(id: id) } }
        Self.report("📏 by-id facade visibleAlbum cached \(Self.distribution(albumSamples))")
        var artistsFound = 0
        let artistSamples = artistIDs.map { id in
            Self.microseconds { if library.visibleArtist(id: id) != nil { artistsFound += 1 } }
        }
        Self.report("📏 by-id facade visibleArtist first read found=\(artistsFound) \(Self.distribution(artistSamples))")
        var albumSongCount = 0
        let albumSongSamples = albumSongSampleIDs.map { id in
            Self.microseconds { albumSongCount += library.songs(forAlbum: id).count }
        }
        Self.report("📏 by-id facade songs(forAlbum:) songs=\(albumSongCount) \(Self.distribution(albumSongSamples))")
        await library.stopCatalogMirror()
    }

    /// 步骤 0c / 第 2 步: 目录落在旧库后面一个修订号时(旧库写完、目录还没跟上就被杀), 启动后多久可读。
    ///
    /// 第 2 步之后按旧库的变更流水只补那一行, 量两种启动: 发布时才启动目录(第 2 步之前的时刻), 与构造之后
    /// 立刻启动(App 现在的做法: 装载那几秒里目录已经追上, 发布那一刻就可读)。
    /// `TEST_RUNNER_PRIMUSE_SCALE_DRIFT_RESYNC=1`: 关掉流水、走整库对账, 在同一份数据上量第 2 步之前的开销。
    func testScaleFixtureLaunchDrift() async throws {
        let fixture = try Self.existingScaleCatalogFixture()
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let resyncOnly = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DRIFT_RESYNC"] == "1"
        LibraryCatalogHost.journalCatchUpMaximumRowsForTesting = resyncOnly ? 0 : nil
        defer { LibraryCatalogHost.journalCatchUpMaximumRowsForTesting = nil }
        let songCount = try IncrementalSongStoreScanner(path: storePath).songCount()

        /// 旧库往前走一个修订号: 改一首歌的标题, 目录没跟。
        func drift(_ suffix: String) throws -> String {
            let scanner = try IncrementalSongStoreScanner(path: storePath)
            let revisionBefore = try scanner.contentRevision()
            var song = try XCTUnwrap(scanner.rows(after: nil, limit: 1).first?.song)
            song.title += suffix
            let store = try IncrementalSongStore(path: storePath)
            XCTAssertEqual(try store.apply(upserts: [song]), revisionBefore + 1)
            return song.id
        }
        /// 镜像自己记的那几行(设备日志里看到的也是它们)。
        func mirrorLog(after marker: String) -> [String] {
            let log = FileLogger.shared.recentContent(maxBytes: 400_000)
            return (log.components(separatedBy: marker).last ?? "")
                .split(separator: "\n")
                .filter {
                    $0.contains("📚 catalog open") || $0.contains("📚 catalog drift") || $0.contains("📚 catalog resync")
                        || $0.contains("📚 catalog catch-up") || $0.contains("📚 catalog early start")
                }
                .map { String($0.suffix(170)) }
        }
        func assertRepaired(_ statistics: LibraryCatalogMirrorStatistics, _ step: String) {
            XCTAssertEqual(statistics.resyncs, resyncOnly ? 1 : 0, step)
            XCTAssertEqual(statistics.journalCatchUps, resyncOnly ? 0 : 1, step)
            XCTAssertEqual(statistics.journalCatchUpFallbacks, resyncOnly ? 1 : 0, step)
            XCTAssertEqual(statistics.resyncFallbacksToImport, 0, step)
            XCTAssertEqual(statistics.importRuns, 0, step)
        }

        // (1) 发布时才启动目录。
        do {
            let changedID = try drift(" (drift)")
            let logMarker = "drift-run-\(UUID().uuidString)"
            plog("📏 \(logMarker)")
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
            // 先让装载落定再开目录的计时: 发布那一刻镜像才启动。
            let startedAt = ProcessInfo.processInfo.systemUptime
            library.publish(prepared)
            let host = try XCTUnwrap(library.catalogHost)
            var unreadableUntil = startedAt
            for _ in 0..<600_000 {
                if host.mirror.readableCatalog != nil { break }
                unreadableUntil = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(1))
            }
            let readableAfter = ProcessInfo.processInfo.systemUptime - startedAt
            let statistics = host.mirror.statistics
            assertRepaired(statistics, "started at publish")
            let catalog = try XCTUnwrap(host.mirror.readableCatalog)
            XCTAssertEqual(try catalog.song(id: changedID)?.title.hasSuffix(" (drift)"), true)
            await library.waitForPendingIndex()
            await library.waitForCatalogMirror()
            try await Task.sleep(for: .milliseconds(500))
            Self.report(String(
                format: "📏 launch drift (catalog started at publish, %@) songs=%d readableAfter=%.0fms"
                    + " (unreadable for at least %.0fms after publish) resyncs=%d journalCatchUps=%d rows=%d",
                resyncOnly ? "journal off" : "journal", songCount, readableAfter * 1_000,
                (unreadableUntil - startedAt) * 1_000, statistics.resyncs, statistics.journalCatchUps,
                statistics.journalCatchUpRows
            ))
            for line in mirrorLog(after: logMarker) { Self.report("📏 launch drift mirror log: \(line)") }
            await library.stopCatalogMirror()
        }
        guard !resyncOnly else { return }

        // (2) 构造之后立刻启动目录, 装载在主线程外同时进行(App 冷启动的顺序)。
        do {
            let changedID = try drift(" (again)")
            let logMarker = "drift-run-\(UUID().uuidString)"
            plog("📏 \(logMarker)")
            let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
            let host = try XCTUnwrap(library.catalogHost)
            let startedAt = ProcessInfo.processInfo.systemUptime
            library.startCatalogBeforePublish(spokenWordClassification: .empty)
            let box = PreparedStartupBox()
            let preparation = Task { box.value = await MusicLibrary.prepareStartup(storageDirectory: directory) }
            var caughtUpAfter: TimeInterval?
            var preparedAfter: TimeInterval?
            while caughtUpAfter == nil || preparedAfter == nil {
                let now = ProcessInfo.processInfo.systemUptime - startedAt
                if caughtUpAfter == nil, host.mirror.caughtUpCatalog != nil { caughtUpAfter = now }
                if preparedAfter == nil, box.value != nil { preparedAfter = now }
                // 预估的输入没被采用时目录等发布: 模型装好了它还没追上就不再等。
                if preparedAfter != nil, caughtUpAfter == nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            await preparation.value
            let prepared = try XCTUnwrap(box.value)
            XCTAssertNotNil(caughtUpAfter, "the catalog caught up while the model was loading")
            XCTAssertNil(host.mirror.readableCatalog, "list readers wait for the publish")
            XCTAssertFalse(host.revisions.isReadable)
            let publishStartedAt = ProcessInfo.processInfo.systemUptime
            library.publish(prepared)
            let publishMilliseconds = (ProcessInfo.processInfo.systemUptime - publishStartedAt) * 1_000
            XCTAssertNotNil(host.mirror.readableCatalog, "readable the moment the library is published")
            var observersToldAfter: TimeInterval?
            for _ in 0..<5_000 {
                if host.revisions.isReadable {
                    observersToldAfter = ProcessInfo.processInfo.systemUptime - publishStartedAt
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let statistics = host.mirror.statistics
            assertRepaired(statistics, "started before publish")
            let catalog = try XCTUnwrap(host.mirror.readableCatalog)
            XCTAssertEqual(try catalog.song(id: changedID)?.title.hasSuffix(" (again)"), true)
            await library.waitForPendingIndex()
            await library.waitForCatalogMirror()
            try await Task.sleep(for: .milliseconds(500))
            Self.report(String(
                format: "📏 launch drift (catalog started at construction) songs=%d caughtUpAfter=%.0fms modelPreparedAfter=%.0fms"
                    + " publish=%.0fms readableAtPublish=%@ observersToldAfterPublish=%.0fms journalCatchUps=%d rows=%d",
                songCount, (caughtUpAfter ?? -1) * 1_000, (preparedAfter ?? -1) * 1_000, publishMilliseconds,
                host.mirror.readableCatalog != nil ? "yes" : "no", (observersToldAfter ?? -1) * 1_000,
                statistics.journalCatchUps, statistics.journalCatchUpRows
            ))
            for line in mirrorLog(after: logMarker) { Self.report("📏 launch drift mirror log: \(line)") }
            await library.stopCatalogMirror()
        }
    }

    func testScaleFixtureFootprint() async throws {
        guard let directory = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let before = Self.residentFootprint()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let preparedAt: TimeInterval
        let library: MusicLibrary
        // 装载结果与下面的查找表都收在各自的作用域里: 它们握着整库数组,
        // 活到函数结束会让后面的补丁量到一次 App 里不会发生的整库复制。
        do {
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            preparedAt = ProcessInfo.processInfo.systemUptime
            library = MusicLibrary.makePreparing(storageDirectory: directory)
            library.publish(prepared)
        }
        let publishedAt = ProcessInfo.processInfo.systemUptime
        await library.waitForPendingIndex()
        let indexedAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let after = Self.residentFootprint()
        let songCount = library.songs.count

        var inPlace = ["load=\(library.patchWouldWriteInPlaceForTesting())"]
        let idsStartedAt = ProcessInfo.processInfo.systemUptime
        let musicIDs = library.musicSongs.map(\.id)
        let idsAt = ProcessInfo.processInfo.systemUptime
        let plannedCount: Int?
        do {
            let lookup = library.visibleSongLookup()
            plannedCount = LargeQueueRequestPlanner.plan(
                ids: musicIDs, startIndex: 0, order: .shuffled,
                includes: { lookup.contains(id: $0, playableOnly: true) },
                resolve: { lookup.song(id: $0) }
            )?.items.count
        }
        let plannedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(plannedCount, min(songCount, QueueWindowPolicy.windowLimit))
        inPlace.append("plan=\(library.patchWouldWriteInPlaceForTesting())")

        let resident = Self.megabytes(after.current - min(after.current, before.current))
        let summary = (String(
            format: "📏 scale footprint songs=%d before=%.0fMB after=%.0fMB resident=%.0fMB perSong=%.0fB peak=%.0fMB prepare=%.0fms publish=%.0fms index=%.0fms musicIDs=%.0fms plan=%.0fms",
            songCount,
            Self.megabytes(before.current),
            Self.megabytes(after.current),
            resident,
            resident * 1_048_576 / Double(max(1, songCount)),
            Self.megabytes(after.peak),
            (preparedAt - startedAt) * 1_000,
            (publishedAt - preparedAt) * 1_000,
            (indexedAt - publishedAt) * 1_000,
            (idsAt - idsStartedAt) * 1_000,
            (plannedAt - idsAt) * 1_000
        ))
        plog(summary)
        print(summary)

        // 回填期间最常见的两种补丁: 封面/歌词引用、歌词全文。每批量一次耗时与常驻增量。
        let patchIDs = Array(library.songs.prefix(200).map(\.id))
        let patchBefore = Self.residentFootprint()
        let patchStartedAt = ProcessInfo.processInfo.systemUptime
        for id in patchIDs { library.updateAssetReferences(songID: id, coverRef: "patched-cover-\(id).jpg") }
        library.flushPendingAssetReferencePatches()
        let assetPatchAt = ProcessInfo.processInfo.systemUptime
        library.updateLyricsText(Dictionary(uniqueKeysWithValues: patchIDs.map { ($0, "歌词 \($0)") }))
        let lyricsPatchAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        inPlace.append("patched=\(library.patchWouldWriteInPlaceForTesting())")
        let beforeReplace = Self.residentFootprint()
        print("📏 scale sharing before replace: \(library.storageSharingSummaryForTesting)")
        // 开播时的时长校正: 一首歌的整行替换。
        var corrected = try XCTUnwrap(library.song(id: patchIDs[5]))
        corrected.duration += 7
        let replaceStartedAt = ProcessInfo.processInfo.systemUptime
        library.replaceSong(corrected)
        let replaceAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let afterReplace = Self.residentFootprint()
        print(String(
            format: "📏 scale replaceSong songs=%d main=%.0fms residentGrowth=%.0fMB sharing after: %@",
            songCount, (replaceAt - replaceStartedAt) * 1_000,
            Self.megabytes(afterReplace.current) - Self.megabytes(beforeReplace.current),
            library.storageSharingSummaryForTesting
        ))
        try await Task.sleep(for: .seconds(2))
        inPlace.append("replaced=\(library.patchWouldWriteInPlaceForTesting())")
        print("📏 scale inPlace " + inPlace.joined(separator: " "))
        let patchAfter = Self.residentFootprint()
        let stages = await library.measureIndexRebuildStagesForTesting()
        let patchSummary = String(
            format: "📏 scale patches songs=%d assetPatch=%.0fms lyricsPatch=%.0fms residentGrowth=%.0fMB rebuild: %@",
            songCount,
            (assetPatchAt - patchStartedAt) * 1_000,
            (lyricsPatchAt - assetPatchAt) * 1_000,
            Self.megabytes(patchAfter.current) - Self.megabytes(patchBefore.current),
            stages
        )
        plog(patchSummary)
        print(patchSummary)

        // 点一次「喜欢」或改一次歌单就会武装一次整库快照写: 量它的耗时与常驻增量。
        let snapshotBefore = Self.residentFootprint()
        let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
        let snapshotResult = await library.persistNowAndWait()
        let snapshotAt = ProcessInfo.processInfo.systemUptime
        let snapshotAfter = Self.residentFootprint()
        let snapshotSize = (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("library-cache.json").path
        )[.size] as? Int) ?? 0
        let snapshotSummary = String(
            format: "📏 scale snapshot songs=%d write=%.0fms bytes=%.0fMB residentGrowth=%.0fMB peak=%.0fMB ok=%@",
            songCount,
            (snapshotAt - snapshotStartedAt) * 1_000,
            Double(snapshotSize) / 1_048_576,
            Self.megabytes(snapshotAfter.current) - Self.megabytes(snapshotBefore.current),
            Self.megabytes(snapshotAfter.peak),
            { if case .success = snapshotResult { return "yes" } else { return "no" } }()
        )
        plog(snapshotSummary)
        print(snapshotSummary)
        XCTAssertGreaterThan(songCount, 0)
    }

}


@MainActor
final class ImportLoadMatrixTests: XCTestCase {
    private final class IsolatedFileManager: FileManager, @unchecked Sendable {
        let root: URL
        init(root: URL) { self.root = root; super.init() }
        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
    }

    @MainActor private final class Pulse {
        var maximumGap: TimeInterval = 0
        private var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor [weak self] in
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    let now = ProcessInfo.processInfo.systemUptime
                    self?.maximumGap = max(self?.maximumGap ?? 0, now - last)
                    last = now
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
    }

    fileprivate static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func measured<T>(_ label: String, operation: () async throws -> T) async rethrows -> T {
        let pulse = Pulse()
        pulse.start()
        let started = ProcessInfo.processInfo.systemUptime
        let cpu = Self.cpuSeconds()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        defer {
            pulse.stop()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print(String(format: "LOAD_MATRIX %@ wall=%.3fs cpu=%.3fs mainGap=%.1fms memory=%.1fMB thermal=%d->%d",
                         label, elapsed, Self.cpuSeconds() - cpu, pulse.maximumGap * 1_000,
                         Self.footprintMB(), thermal, ProcessInfo.processInfo.thermalState.rawValue))
        }
        return try await operation()
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportLoadMatrix-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func wave(seed: Int) -> Data {
        let frames = 22_050
        var data = Data()
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
        u32(22_050); u32(44_100); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(frames * 2))
        for index in 0..<frames { u16(UInt16(truncatingIfNeeded: (index * 13 + seed * 97) % 8192)) }
        return data
    }

    private func files(in root: URL, count: Int, offset: Int = 0) throws -> [URL] {
        try (0..<count).map { index in
            let folder = root.appendingPathComponent("Group \(index % 4)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("曲目 \(index + offset).wav")
            try wave(seed: index + offset).write(to: file)
            return file
        }
    }

    private func scan(_ source: MusicSource, connector: any MusicSourceConnector,
                      root: URL, library: MusicLibrary, store: SourcesStore,
                      scan: ScanService, manager: SourceManager) async throws {
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        let deadline = Date().addingTimeInterval(240)
        while scan.scanStates[source.id]?.isScanning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if scan.scanStates[source.id]?.isScanning == true {
            scan.cancelScan(for: source.id, automaticallyResumes: false)
            XCTFail("Source scan did not finish within its test budget")
        }
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        await scan.waitForActiveScansToComplete()
        await library.waitForPendingIndex()
    }

    private func copyFiles(_ files: [URL]) async -> LocalImportService.CopyResult {
        let session = LocalImportService.copySession(files)
        for await event in session.events {
            if case .finished(let result) = event { return result }
        }
        XCTFail("Import session ended without a final result")
        return .init()
    }

    private func exercisePlayback(_ songs: [Song], manager: SourceManager, label: String) async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_LIVE_PLAYBACK"] == "1", !songs.isEmpty else { return }
        let root = try root()
        let suite = "ImportLoadPlayback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        library.addSongs(songs)
        await library.waitForPendingIndex()
        let player = AudioPlayerService(sourceManager: manager, library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("Playback.json")))
        player.audioEngine.setVolume(0, persist: false)
        defer { player.stop() }
        await measured("play-start-\(label)") { await player.play(queue: songs, startingAt: 0) }
        let deadline = Date().addingTimeInterval(30)
        while !player.isPlaying, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(player.isPlaying, "Playback did not start: \(label)")
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(player.currentTime, 0)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        player.resume()
        let resumeDeadline = Date().addingTimeInterval(30)
        while !player.isPlaying, Date() < resumeDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(player.isPlaying)
        let seekTarget = min(5, max(0, player.duration / 2))
        player.seek(to: seekTarget, startPlaying: true)
        let seekDeadline = Date().addingTimeInterval(30)
        while (player.isLoading || !player.isPlaying), Date() < seekDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.currentTime, seekTarget - 1)
        if songs.count > 1 {
            let next = await measured("play-next-\(label)") { await player.next() }
            XCTAssertTrue(next)
            XCTAssertEqual(player.currentSong?.id, songs[1].id)
        }
        player.stop()
        await library.beginExternalSnapshotWrite(); library.endExternalSnapshotWrite()
    }

    func testLocalImportCopyRescanBackfillCancelAndResume() async throws {
        let root = try root()
        let target = root.appendingPathComponent("Imported")
        let key = "PRIMUSE_LOCAL_MUSIC_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        let requestedCount = Int(ProcessInfo.processInfo.environment["PRIMUSE_LOCAL_MATRIX_COUNT"] ?? "32") ?? 32
        let usesInstalledFiles = ProcessInfo.processInfo.environment["PRIMUSE_INSTALLED_LOCAL_IMPORT"] == "1"
        let originals: [URL]
        if let fixturePath = ProcessInfo.processInfo.environment["PRIMUSE_LOCAL_MATRIX_FIXTURE"] {
            let fixtureRoot = fixturePath.hasPrefix("/") ? URL(fileURLWithPath: fixturePath)
                : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fixturePath)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixtureRoot,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
            originals = enumerator.compactMap { $0 as? URL }.filter {
                AudioFormat.from(fileExtension: $0.pathExtension) != nil
            }.sorted { $0.path < $1.path }.prefix(requestedCount).map { $0 }
            XCTAssertFalse(originals.isEmpty)
        } else if usesInstalledFiles {
            let services = AppServices.shared
            let ready = await services.musicLibrary.whenReady(timeout: .seconds(180))
            XCTAssertTrue(ready)
            let originalSource = try XCTUnwrap(services.sourcesStore.sources.first { $0.type == .local && $0.isEnabled })
            let originalConnector = try XCTUnwrap(services.sourceManager.connector(for: originalSource) as? LocalFileSource)
            try await originalConnector.connect()
            var urls: [URL] = []
            for song in services.musicLibrary.songs.lazy.filter({ $0.sourceID == originalSource.id && $0.isPlayable }).prefix(requestedCount) {
                urls.append(try await originalConnector.localURL(for: song.filePath))
            }
            originals = urls
            XCTAssertFalse(originals.isEmpty)
        } else {
            originals = try files(in: root.appendingPathComponent("Input"), count: requestedCount)
        }
        setenv(key, target.path, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let count = originals.count
        let first = await measured("local-copy-\(count)") { await copyFiles(originals) }
        XCTAssertEqual(first.copied + first.duplicateSkipped, count)
        XCTAssertGreaterThan(first.copied, 0)
        XCTAssertEqual(first.failed, 0)
        let duplicate = await measured("local-duplicate-\(count)") {
            await copyFiles(originals)
        }
        XCTAssertEqual(duplicate.copied, 0)
        XCTAssertEqual(duplicate.duplicateSkipped, count)

        let additional = try files(in: root.appendingPathComponent("Additional"), count: 64, offset: 10_000)
        setenv("PRIMUSE_IMPORT_DELAY_MS", "5", 1)
        let session = LocalImportService.copySession(additional)
        var cancelled = false
        for await event in session.events {
            switch event {
            case .progress(let progress): if progress.copied >= 3 { session.cancel() }
            case .finished(let result): cancelled = result.cancelled
            }
        }
        unsetenv("PRIMUSE_IMPORT_DELAY_MS")
        XCTAssertTrue(cancelled)
        let resumed = await copyFiles([root.appendingPathComponent("Additional")])
        XCTAssertEqual(resumed.copied + resumed.duplicateSkipped, 64)
        XCTAssertEqual(resumed.failed, 0)

        let source = MusicSource(id: UUID().uuidString, name: "Local matrix", type: .local, basePath: target.path)
        let connector = LocalFileSource(sourceID: source.id, basePath: target)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(source)
        let scanner = ScanService(fileManager: IsolatedFileManager(root: root.appendingPathComponent("Scan")),
                                  connectorProvider: { _ in connector })
        let importedCount = first.copied + 64
        try await measured("local-first-scan-\(importedCount)") {
            try await scan(source, connector: connector, root: root, library: library,
                           store: store, scan: scanner, manager: manager)
        }
        XCTAssertEqual(library.songs.count, importedCount)
        let ids = Set(library.songs.map(\.id))
        try await measured("local-rescan-\(importedCount)") {
            try await scan(source, connector: connector, root: root, library: library,
                           store: store, scan: scanner, manager: manager)
        }
        XCTAssertEqual(Set(library.songs.map(\.id)), ids)
        let backfill = MetadataBackfillService(library: library, sourceManager: manager,
            backfillableSourceIDs: { [source.id] }, offlineReadableSourceIDs: { [source.id] },
            localFileSourceIDs: { [source.id] }, directFileSourceIDs: { [source.id] },
            storageDirectory: root.appendingPathComponent("Backfill"))
        defer { backfill.stop() }
        backfill.automaticWorkIsAllowed = { true }
        await measured("local-backfill-\(importedCount)") {
            backfill.start()
            print("LOAD_MATRIX local-backfill-mode=\(backfill.readingMode.rawValue)")
            await backfill.waitUntilIdle()
        }
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: source.id), 0)
        XCTAssertEqual(library.songs.filter { $0.duration > 0 }.count, importedCount)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let restarted = MusicLibrary.makePreparing(storageDirectory: root.appendingPathComponent("Library"))
        await measured("local-reopen-\(importedCount)") {
            restarted.publish(await MusicLibrary.prepareStartup(storageDirectory: root.appendingPathComponent("Library")))
        }
        XCTAssertEqual(Set(restarted.songs.map(\.id)), ids)
        XCTAssertEqual(Set(restarted.musicSongIDsExcludingDisliked), Set(library.musicSongIDsExcludingDisliked))
        await connector.disconnect()
        await library.beginExternalSnapshotWrite(); library.endExternalSnapshotWrite()
        await restarted.beginExternalSnapshotWrite(); restarted.endExternalSnapshotWrite()
    }


    func testConfiguredRemoteScanRescanAndAudioReads() async throws {
        guard let path = ProcessInfo.processInfo.environment["PRIMUSE_LIVE_CREDENTIALS_FILE"] else {
            throw XCTSkip("Requires the local test-account file")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var sections: [String: [String: String]] = [:]
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard !line.hasPrefix("#"), let split = line.firstIndex(of: "=") else { continue }
            sections[section, default: [:]][line[..<split].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        let requested = Set((ProcessInfo.processInfo.environment["PRIMUSE_LIVE_SOURCE_KINDS"]
            ?? "fnMusic,jellyfin,ftp,smb,webdav").split(separator: ",").map(String.init))
        for kind in ["fnMusic", "jellyfin", "ftp", "smb", "webdav", "alist"] where requested.contains(kind) {
            let root = try root()
            let id = "load-matrix-\(kind)-\(UUID())"
            let nas = sections["jellyfin_lan_20260928"] ?? [:]
            let config = sections[kind == "fnMusic" ? "fn_music_lan_playlist_20260928" :
                                  kind == "alist" ? "primuse-qa-alist-tv-20261018" : "jellyfin_lan_20260928"] ?? [:]
            let address = URLComponents(string: config["base_url"] ?? config["login_url"] ?? "")
            let host = ["fnMusic", "jellyfin", "alist"].contains(kind) ? (address?.host ?? "") : (nas["fnos_qa_host"] ?? "")
            let type: MusicSourceType = kind == "fnMusic" ? .fnMusic : kind == "jellyfin" ? .jellyfin :
                kind == "ftp" ? .ftp : kind == "smb" ? .smb : .webdav
            let port = kind == "ftp" ? 2121 : kind == "smb" ? 445 : kind == "webdav" ? 3211 : address?.port
            var source = MusicSource(id: id, name: "Load matrix \(kind)", type: type, host: host, port: port,
                                     useSsl: address?.scheme == "https", authType: .none)
            if type == .ftp || type == .webdav {
                source.extraConfig = MusicSource.encodeScannedDirectories(["/"], into: nil, type: type)
            }
            if kind == "smb" {
                source.shareName = "Media"
                source.extraConfig = MusicSource.encodeScannedDirectories(["/Music"], into: nil, type: .smb)
            }
            let configuredSource = source
            let manager = SourceManager(sourcesProvider: { [configuredSource] }, connectorFactory: { _ in
                switch kind {
            case "fnMusic":
                return FnMusicSource(sourceID: id, host: host, port: port, useSSL: configuredSource.useSsl,
                    basePath: nil, connectionMode: .address, accessCode: nil,
                    username: config["username"] ?? "", password: config["password"] ?? "")
            case "jellyfin":
                return MediaServerSource(sourceID: id, kind: .jellyfin, host: host, port: port,
                    useSsl: configuredSource.useSsl, basePath: nil, username: config["username"] ?? "",
                    secret: config["password"] ?? "", authType: .password)
            case "ftp":
                return FTPSource(sourceID: id, host: host, port: port,
                    username: nas["ftp_qa_username"] ?? "", password: nas["ftp_qa_password"] ?? "", encryption: .none)
            case "smb":
                return SMBSource(sourceID: id, host: host, sharePath: "Media",
                    username: nas["fnos_qa_user"] ?? "", password: nas["fnos_qa_password"] ?? "")
            default:
                return WebDAVSource(sourceID: id, host: host, port: port, useSsl: configuredSource.useSsl,
                    basePath: kind == "alist" ? "/dav" : nil,
                    username: kind == "alist" ? (config["username"] ?? "") : "",
                    password: kind == "alist" ? (config["password"] ?? "") : "")
                }
            })
            let connector = manager.connector(for: configuredSource)
            let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
            let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
            store.add(source)
            let scanner = ScanService(fileManager: IsolatedFileManager(root: root.appendingPathComponent("Scan")),
                                      connectorProvider: { _ in connector })
            do {
                try await measured("live-connect-\(kind)") { try await connector.connect() }
                try await measured("live-first-scan-\(kind)") {
                    try await scan(source, connector: connector, root: root, library: library,
                                   store: store, scan: scanner, manager: manager)
                }
                XCTAssertFalse(library.songs.isEmpty, "Live fixture must contain songs: \(kind)")
                let ids = Set(library.songs.map(\.id))
                print("LOAD_MATRIX live-rows \(kind)=\(ids.count)")
                try await measured("live-rescan-\(kind)") {
                    try await scan(source, connector: connector, root: root, library: library,
                                   store: store, scan: scanner, manager: manager)
                }
                XCTAssertEqual(Set(library.songs.map(\.id)), ids)
                try await exercisePlayback(Array(library.songs.filter { $0.isPlayable && $0.duration > 10 }.prefix(2)),
                                           manager: manager, label: kind)
                for (index, song) in library.songs.filter({ $0.isPlayable }).prefix(3).enumerated() {
                    let bytes = try await measured("live-audio-window-\(kind)-\(index)") {
                        try await connector.fetchRange(path: song.filePath, offset: 0, length: 65_536)
                    }
                    XCTAssertFalse(bytes.isEmpty)
                    XCTAssertLessThanOrEqual(bytes.count, 65_536)
                }
                guard case .success = await library.persistNowAndWait() else { return XCTFail("Live fixture persistence failed") }
                let restored = MusicLibrary.makePreparing(storageDirectory: root.appendingPathComponent("Library"))
                await measured("live-reopen-\(kind)") {
                    restored.publish(await MusicLibrary.prepareStartup(storageDirectory: root.appendingPathComponent("Library")))
                }
                XCTAssertEqual(Set(restored.songs.map(\.id)), ids)
                await restored.beginExternalSnapshotWrite(); restored.endExternalSnapshotWrite()
            } catch {
                XCTFail("Live \(kind) failed: \(String(reflecting: Swift.type(of: error)))")
            }
            await connector.disconnect()
            await library.beginExternalSnapshotWrite(); library.endExternalSnapshotWrite()
        }
    }

    func testInstalledLibraryIdleAndSourceReads() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_INSTALLED_LIBRARY_AUDIT"] == "1" else {
            throw XCTSkip("Requires an explicitly selected device library")
        }
        let services = AppServices.shared
        let ready = await services.musicLibrary.whenReady(timeout: .seconds(180))
        XCTAssertTrue(ready)
        let sources = services.sourcesStore.sources
        print("LOAD_MATRIX installed songs=\(services.musicLibrary.songs.count) sources=\(sources.count)")
        try await measured("installed-idle-120s") {
            for interval in 1...4 {
                print("LOAD_MATRIX idle-interval=\(interval) scanning=\(services.scanService.hasActiveScans)")
                try await measured("installed-idle-30s-\(interval)") { try await Task.sleep(for: .seconds(30)) }
            }
        }
        let requested = Set((ProcessInfo.processInfo.environment["PRIMUSE_LIVE_SOURCE_IDS"] ?? "").split(separator: ",").map(String.init))
        for source in sources where requested.contains(source.id) {
            do {
                let connector = services.sourceManager.connector(for: source)
                try await measured("installed-connect-\(source.type.rawValue)") { try await connector.connect() }
                var candidates = Array(services.musicLibrary.songs.lazy.filter {
                    $0.sourceID == source.id && $0.isPlayable && $0.duration > 0
                }.prefix(3))
                if candidates.isEmpty {
                    var directories = source.scannedDirectories.isEmpty ? ["/"] : source.scannedDirectories
                    var visited = Set<String>()
                    while let path = directories.first, candidates.count < 3, visited.count < 64 {
                        directories.removeFirst()
                        guard visited.insert(path).inserted else { continue }
                        for item in try await connector.listFiles(at: path) {
                            if item.isDirectory {
                                if !visited.contains(item.path) { directories.append(item.path) }
                            } else if let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension),
                                      candidates.count < 3 {
                                candidates.append(Song(id: UUID().uuidString, title: item.name,
                                    fileFormat: format, filePath: item.path, sourceID: source.id, fileSize: item.size))
                            }
                        }
                    }
                    print("LOAD_MATRIX installed-browse-\(source.type.rawValue) folders=\(visited.count) files=\(candidates.count)")
                }
                XCTAssertFalse(candidates.isEmpty, "Selected source needs playable fixtures: \(source.type.rawValue)")
                for (index, song) in candidates.enumerated() {
                    let data = try await measured("installed-read-\(source.type.rawValue)-\(index)") {
                        try await connector.fetchRange(path: song.filePath, offset: 0, length: 65_536)
                    }
                    XCTAssertFalse(data.isEmpty)
                    XCTAssertLessThanOrEqual(data.count, 65_536)
                }
                try await exercisePlayback(Array(candidates.prefix(2)), manager: services.sourceManager,
                                           label: source.type.rawValue)
            } catch {
                XCTFail("Installed \(source.type.rawValue) failed: \(String(reflecting: Swift.type(of: error)))")
            }
        }
        XCTAssertEqual(services.sourcesStore.sources.map(\.id), sources.map(\.id))
    }
}

/// 主线程外装好的模型,交回主线程上的测试。
@MainActor
private final class PreparedStartupBox {
    var value: MusicLibrary.PreparedStartup?
}
