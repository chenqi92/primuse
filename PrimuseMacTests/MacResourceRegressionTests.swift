import AppKit
import AVFoundation
import SwiftUI
import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class SourceAutomaticScanSchedulingTests: XCTestCase {
    func testAutomaticScansRunSeriallyAndCoalesceRepeatedRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        XCTAssertFalse(fixture.start(1))
        XCTAssertFalse(fixture.start(2))
        try await waitUntil { await fixture.connectors[0].isWaiting }
        let secondStarts = await fixture.connectors[1].starts
        XCTAssertEqual(secondStarts, 0)

        var finished = false
        let drain = Task { await fixture.scan.waitForActiveScansToComplete(); finished = true }
        await fixture.connectors[0].release()
        try await waitUntil { await fixture.connectors[1].isWaiting }
        XCTAssertFalse(finished)
        let thirdStarts = await fixture.connectors[2].starts
        XCTAssertEqual(thirdStarts, 0)
        await fixture.connectors[1].release()
        try await waitUntil { await fixture.connectors[2].isWaiting }
        XCTAssertFalse(finished)
        await fixture.connectors[2].release()
        await drain.value
        XCTAssertTrue(finished)
        for connector in fixture.connectors {
            let starts = await connector.starts
            XCTAssertEqual(starts, 1)
        }
    }

    func testQueuedRefreshRechecksEligibilityWhenItsTurnArrives() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        var enabled = true
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1, eligibility: { enabled }))
        enabled = false
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 0)
    }

    func testCancellingAllScansDoesNotStartQueuedWork() async throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        try await waitUntil { await fixture.connectors[0].isWaiting }
        fixture.scan.cancelAllActiveScans()
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        try await Task.sleep(for: .milliseconds(100))
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(fixture.scan.hasActiveScans)
    }

    func testManualScanSupersedesItsQueuedAutomaticRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        XCTAssertTrue(fixture.start(1, context: .userInitiatedForeground))
        try await waitUntil { await fixture.connectors[1].isWaiting }
        await fixture.connectors[1].release()
        try await waitUntil { fixture.store.source(id: fixture.sources[1].id)?.lastScannedAt != nil }
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 1)
    }

    func testRefreshIntervalsPersistPerSourceAndKeepLegacyDefaults() throws {
        let fixture = try Fixture()
        let suite = "SourceRefreshSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = MusicSource(id: "server", name: "Server", type: .navidrome)
        fixture.store.add(server)
        defaults.set(Data(#"{"disabledSourceIDs":["server"],"markers":{}}"#.utf8),
                     forKey: "primuse.navidrome-auto-refresh.v1")
        let scraper = MusicScraperService(sourceManager: fixture.manager)
        let player = AudioPlayerService(
            sourceManager: fixture.manager, library: fixture.library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: fixture.root.appendingPathComponent("playback.json")),
            activateAudioSession: { _ in }
        )
        func coordinator() -> ServerCatalogAutoRefreshCoordinator {
            ServerCatalogAutoRefreshCoordinator(
                sourceManager: fixture.manager, scanService: fixture.scan, library: fixture.library,
                sourcesStore: fixture.store, scraperService: scraper, player: player, defaults: defaults
            )
        }
        let first = coordinator()
        XCTAssertFalse(first.isEnabled(for: fixture.sources[0].id))
        XCTAssertFalse(first.isEnabled(for: server.id))
        XCTAssertEqual(first.refreshInterval(for: fixture.sources[0].id), .sixHours)
        first.setRefreshInterval(.oneHour, for: fixture.sources[0].id)
        first.setRefreshInterval(.twentyFourHours, for: fixture.sources[1].id)
        first.setEnabled(true, for: fixture.sources[0].id)
        let reopened = coordinator()
        XCTAssertTrue(reopened.isEnabled(for: fixture.sources[0].id))
        XCTAssertFalse(reopened.isEnabled(for: fixture.sources[1].id))
        XCTAssertFalse(reopened.isEnabled(for: server.id))
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[0].id), .oneHour)
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[1].id), .twentyFourHours)
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[2].id), .sixHours)
    }

    func testNativeBackgroundRefreshUsesTheSelectedIntervalAfterFinalCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeriodicRefresh-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var source = MusicSource(id: UUID().uuidString, name: "Drive", type: .dropbox,
                                 extraConfig: "[\"/Music\"]")
        let completedAt = Date(timeIntervalSince1970: 1_000_000)
        source.lastScannedAt = completedAt
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        source = try XCTUnwrap(store.source(id: source.id))
        let state = SourceSyncState(
            sourceID: source.id, scopeFingerprint: ScanService.scopeFingerprint(for: source, directories: ["/Music"]),
            cursors: ["/Music": "committed-cursor"], lastSuccessfulSyncAt: completedAt.addingTimeInterval(-300)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([source.id: state]).write(to: directory.appendingPathComponent("source-sync-states.json"))
        let scan = ScanService(fileManager: AutomaticScanFixtureFileManager(root: root))
        var enabled = false
        scan.automaticRefreshEnabledHandler = { _ in enabled }
        XCTAssertNil(scan.nextPeriodicSyncDate(sourceStore: store))
        enabled = true
        for interval in SourceAutomaticRefreshInterval.allCases {
            scan.automaticRefreshIntervalHandler = { _ in interval }
            XCTAssertEqual(scan.nextPeriodicSyncDate(sourceStore: store), completedAt.addingTimeInterval(interval.timeInterval))
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let sources: [MusicSource]
        let connectors: [AutomaticScanFixtureConnector]
        let store: SourcesStore
        let library: MusicLibrary
        let manager: SourceManager
        let scan: ScanService

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticScan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sources = (0..<3).map {
                MusicSource(id: UUID().uuidString, name: "Source \($0)", type: .webdav,
                            host: "scan.invalid", extraConfig: "[\"/Music\"]")
            }
            let connectors = sources.map { AutomaticScanFixtureConnector(sourceID: $0.id) }
            self.connectors = connectors
            let byID = Dictionary(uniqueKeysWithValues: zip(sources.map(\.id), connectors))
            store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
            for source in sources { store.add(source) }
            library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
            manager = SourceManager(sourcesProvider: { [] })
            scan = ScanService(
                fileManager: AutomaticScanFixtureFileManager(root: root),
                connectorProvider: { byID[$0.id]! },
                diagnosticProvider: { source, _ in
                    SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
                }
            )
        }

        func start(_ index: Int, context: BaiduSnapshotExecutionContext = .foregroundResume,
                   eligibility: (() -> Bool)? = nil) -> Bool {
            scan.scanSource(sources[index], snapshotExecutionContext: context,
                            sourceManager: manager, library: library, sourceStore: store,
                            requestsContinuedProcessing: false, automaticRefreshIsAllowed: eligibility)
        }
    }
}

private actor AutomaticScanFixtureConnector: MusicSourceConnector {
    let sourceID: String
    private(set) var starts = 0
    private(set) var isWaiting = false
    private var released = false
    init(sourceID: String) { self.sourceID = sourceID }
    func release() { released = true }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        starts += 1
        isWaiting = true
        defer { isWaiting = false }
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return []
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private final class AutomaticScanFixtureFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

@MainActor
final class MacResourceRegressionTests: XCTestCase {
    func testLocalDownloadActionsAreHiddenWithoutMarkingOriginalsAsDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourcesStore(storageDirectoryURL: root)
        let local = MusicSource(id: UUID().uuidString, name: "External disk", type: .local,
                                basePath: "/Volumes/External/Music")
        let remote = MusicSource(id: UUID().uuidString, name: "Remote", type: .webdav)
        try store.addDurably(local)
        try store.addDurably(remote)
        let localSong = Song(id: UUID().uuidString, title: "Local", fileFormat: .flac,
                             filePath: "/track.flac", sourceID: local.id)
        var remoteSong = localSong
        remoteSong.id = UUID().uuidString
        remoteSong.sourceID = remote.id
        let manager = SourceManager(sourcesProvider: { [local, remote] })

        func menuHeight(_ song: Song, snapshot: OfflineAudioCacheSnapshot = .notCached) -> CGFloat {
            let host = NSHostingView(rootView: SongOfflineActionButtons(song: song, snapshot: snapshot)
                .environment(store)
                .environment(manager)
                .fixedSize())
            return host.fittingSize.height
        }

        XCTAssertEqual(menuHeight(localSong), 0, "Uncached local originals must not offer Download")
        XCTAssertGreaterThan(menuHeight(remoteSong), 0, "Remote files must retain their Download action")
        var stream = localSong
        stream.filePath = "/remote.strm"
        XCTAssertGreaterThan(menuHeight(stream), 0, "A local descriptor can point to remote audio")
        XCTAssertEqual(store.downloadableSongs(in: [localSong, remoteSong]).map(\.id), [remoteSong.id])
        XCTAssertTrue(store.downloadableSongs(in: [localSong]).isEmpty)
        // Existing explicit copies can still be removed; hiding Download must
        // not relabel or delete local originals or their cache records.
        let pinned = OfflineAudioCacheSnapshot(state: .pinned, progress: nil, byteCount: 128, errorMessage: nil)
        XCTAssertGreaterThan(menuHeight(localSong, snapshot: pinned), 0)
        XCTAssertFalse(manager.offlineAudioSnapshotEntry(for: localSong).snapshot.isDownloaded)
        store.updateLocal(remote.id) { $0.isEnabled = false }
        XCTAssertEqual(menuHeight(remoteSong), 0)
        XCTAssertTrue(store.downloadableSongs(in: [localSong, remoteSong]).isEmpty)
    }

    func testCacheCompletionDoesNotEnumerateLibraryAndUpdatesAllRowsSharingAFile() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Cache fixture", type: .navidrome)
        let first = Song(id: UUID().uuidString, title: "First", fileFormat: .flac,
                         filePath: "/fixture.flac", sourceID: source.id, fileSize: 128)
        var second = first
        second.id = UUID().uuidString
        var libraryReads = 0
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: {
            libraryReads += 1
            return [first, second]
        })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: first, forceRedownload: false) }
        defer { manager.deleteLocalCaches(for: [first, second]) }
        await manager.prepareOfflineAudioSnapshots(for: [first, second])
        let firstEntry = manager.offlineAudioSnapshotEntry(for: first)
        let secondEntry = manager.offlineAudioSnapshotEntry(for: second)
        let url = manager.cacheURL(for: first)
        let path = source.id + "/" + url.lastPathComponent
        let readsBeforeCompletion = libraryReads
        try Data(repeating: 7, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: path)
        try await waitUntilAsync { firstEntry.snapshot.isDownloaded && secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion, "A cache notification must not scan the song library")
        await AudioCacheManager.shared.removeEntry(path: path)
        try await waitUntilAsync { !firstEntry.snapshot.isDownloaded && !secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion)
    }

    func testCacheNotificationsFollowSongRenames() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Rename fixture", type: .navidrome)
        let previous = Song(id: UUID().uuidString, title: "Track", fileFormat: .flac,
                            filePath: "/before.flac", sourceID: source.id, fileSize: 128)
        var current = previous
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: { [current] })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: previous, forceRedownload: false) }
        await manager.ensureOfflineAudioSnapshot(for: previous)
        let entry = manager.offlineAudioSnapshotEntry(for: previous)
        _ = manager.cacheURL(for: previous)
        current.filePath = "/after.flac"
        defer { manager.deleteLocalCaches(for: [previous, current]) }
        NotificationCenter.default.post(name: .primuseSongLocationChanged, object: nil,
                                        userInfo: ["previousSongs": [previous], "songs": [current]])
        try await Task.sleep(for: .milliseconds(100))
        let url = manager.audioCacheTargetURL(for: current)
        try Data(repeating: 9, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: source.id + "/" + url.lastPathComponent)
        try await waitUntilAsync { entry.snapshot.isDownloaded }
    }

    func testUnrelatedCacheNotificationDoesNotReadLibrary() async throws {
        var reads = 0
        let manager = SourceManager(sourcesProvider: { [] }, songsProvider: { reads += 1; return [] })
        // Let initial source validation finish before isolating the notification.
        try await Task.sleep(for: .milliseconds(150))
        let before = reads
        NotificationCenter.default.post(name: .primuseAudioCacheFilesDidChange, object: nil,
                                        userInfo: ["paths": [UUID().uuidString + "/unknown.flac"]])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reads, before)
        withExtendedLifetime(manager) {}
    }

    func testUnavailableBookmarkFailsClosedWithoutFallingBackToBasePath() async throws {
        let sourceID = UUID().uuidString
        let key = "primuse.localBookmark." + sourceID
        UserDefaults.standard.set(Data([0, 1, 2]), forKey: key)
        defer { LocalBookmarkStore.remove(sourceID: sourceID) }
        let connector = LocalFileSource(sourceID: sourceID, basePath: FileManager.default.temporaryDirectory)
        do {
            _ = try await connector.localURL(for: "/")
            XCTFail("A corrupt bookmark cannot grant access through the fallback directory")
        } catch SourceError.credentialUnavailable { }
    }

    func testLocalConnectorLazilyResolvesBeforeListingWithoutAnExplicitConnect() async throws {
        let sourceID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(sourceID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("fixture.txt"))
        defer { try? FileManager.default.removeItem(at: root); LocalBookmarkStore.remove(sourceID: sourceID) }
        try LocalBookmarkStore.save(sourceID: sourceID, url: root)
        let connector = LocalFileSource(sourceID: sourceID, basePath: root.appendingPathComponent("incorrect-fallback"))
        let files = try await connector.listFiles(at: "/")
        XCTAssertEqual(files.map(\.name), ["fixture.txt"])
    }

    func testKaraokeAudioUnitLoadsInsideApplicationSandbox() throws {
        let control = KaraokeRenderControl()
        let node = try XCTUnwrap(KaraokeVocalReducerUnit.makeNode(control: control))
        let unit = try XCTUnwrap(node.auAudioUnit as? KaraokeVocalReducerUnit)
        XCTAssertTrue(unit.control === control)
        try unit.allocateRenderResources()
        unit.deallocateRenderResources()
    }

    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
