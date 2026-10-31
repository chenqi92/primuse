import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class BaiduWriteReplayTests: XCTestCase {
    func testCommittedWriteWithLostResponseIsNotSentAgain() async throws {
        let fixture = BaiduWriteFixture(mode: .lostResponse)
        let error = try await replacementError(fixture)
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertEqual(fixture.createCount, 1, "A lost response does not prove the write failed")
    }

    func testHTTPFailuresDoNotReplayWrites() async throws {
        for status in [408, 429, 500, 503] {
            let fixture = BaiduWriteFixture(mode: .httpFailure(status))
            let error = try await replacementError(fixture)
            guard let cloudError = error as? CloudDriveError,
                  case .apiError(let code, _) = cloudError else {
                XCTFail("Expected HTTP \(status), got \(String(describing: error))"); continue
            }
            XCTAssertEqual(code, status)
            XCTAssertEqual(fixture.createCount, 1)
        }
    }

    func testConflictBeforeCommitPreventsAnyReplacement() async throws {
        let fixture = BaiduWriteFixture(mode: .conflict)
        let error = try await replacementError(fixture)
        XCTAssertEqual(error as? EmbeddedMetadataWritebackSourceError, .conflict)
        XCTAssertEqual(fixture.createCount, 0)
    }

    func testExplicitRateLimitRetryRechecksTheFileRevision() async throws {
        let fixture = BaiduWriteFixture(mode: .limitedThenConflict)
        let error = try await replacementError(fixture)
        XCTAssertEqual(error as? EmbeddedMetadataWritebackSourceError, .conflict)
        XCTAssertEqual(fixture.createCount, 1, "Do not replace a file modified during backoff")
    }

    func testSuccessfulReplacementStillVerifiesTheCommittedFile() async throws {
        let fixture = BaiduWriteFixture(mode: .success)
        let error = try await replacementError(fixture)
        XCTAssertNil(error)
        XCTAssertEqual(fixture.createCount, 1)
        XCTAssertEqual(fixture.listCount, 2)
    }

    func testReadOnlyMetadataRequestsCanStillRetry() async throws {
        let fixture = BaiduWriteFixture(mode: .readRetry)
        let error = try await replacementError(fixture)
        XCTAssertNil(error)
        XCTAssertEqual(fixture.createCount, 1)
        XCTAssertEqual(fixture.listCount, 3)
    }

    private func replacementError(_ fixture: BaiduWriteFixture) async throws -> Error? {
        let id = UUID().uuidString
        BaiduWriteProtocol.fixtures.insert(fixture, for: id)
        defer { BaiduWriteProtocol.fixtures.remove(id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BaiduWriteProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = BaiduPanSource(sourceID: id, session: session, tokenProvider: { "fixture-token" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.flac")
        try Data([1, 2, 3, 4]).write(to: file)
        do {
            try await source.replaceMetadataFile(
                at: BaiduWriteFixture.path, with: file,
                expected: .init(fileSize: 4, modifiedDate: nil, revision: "original")
            )
            return nil
        } catch { return error }
    }
}

final class BaiduMetadataTransportTests: XCTestCase {
    @MainActor
    func testConfiguredBaiduPlaybackBackfillAndConcurrentScans() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_BAIDU_LIVE_QA"] == "1" else {
            throw XCTSkip("Opt-in read-only test using the device's configured Baidu account")
        }
        let services = AppServices.shared
        let readyDeadline = Date().addingTimeInterval(30)
        while !services.musicLibrary.isReady, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let configured = services.sourcesStore.sources.first(where: { $0.type == .baiduPan && $0.isEnabled }) else {
            throw XCTSkip("No enabled Baidu account on this device")
        }
        let candidates = services.musicLibrary.songs.filter {
            $0.sourceID == configured.id && [.m4a, .mp3, .flac].contains($0.fileFormat) && $0.duration > 30
        }
        guard candidates.count >= 6 else { throw XCTSkip("Need six ordinary Baidu songs with known durations") }
        let m4a = candidates.filter { $0.fileFormat == .m4a }
        let selected = Array((m4a + candidates.filter { $0.fileFormat != .m4a }).prefix(12))
        print("LIVE_BAIDU available_m4a=\(m4a.count) sample_m4a=\(selected.filter { $0.fileFormat == .m4a }.count)")
        let productionConnector = services.sourceManager.connector(for: configured)
        try await productionConnector.connect()
        let tokens = CloudTokenManager(sourceID: configured.id)
        let credential: @Sendable () async throws -> String = {
            guard let token = await tokens.getAccessToken() else { throw CloudDriveError.tokenExpired }
            return token
        }
        let scheduler = CloudRequestScheduler()
        let ids = [UUID().uuidString, UUID().uuidString]
        for id in ids { scheduler.register(sourceID: id, accountID: configured.id) }
        let connector = BaiduPanSource(sourceID: ids[0], tokenProvider: credential, requests: scheduler)
        let sibling = BaiduPanSource(sourceID: ids[1], tokenProvider: credential, requests: scheduler)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(ids[0])
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        addTeardownBlock {
            await connector.disconnect()
            await sibling.disconnect()
            for id in ids {
                try? FileManager.default.removeItem(at: CloudDriveHelper(sourceID: id).cacheDirectory.deletingLastPathComponent())
            }
        }
        let wasBackfilling = services.metadataBackfill.isRunning
        services.metadataBackfill.stop(preservingContinuation: true)
        defer { if wasBackfilling { services.metadataBackfill.start() } }
        var source = configured
        source.id = ids[0]
        let testSource = source
        let manager = SourceManager(sourcesProvider: { [testSource] }, connectorFactory: { _ in connector })
        addTeardownBlock { @MainActor in await manager.disconnectAll() }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let songs = selected.map { original in
            var song = original
            song.id = ids[0] + ":" + original.id
            song.sourceID = ids[0]
            return song
        }
        library.addSongs(songs)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ids[0]))
        defer { defaults.removePersistentDomain(forName: ids[0]) }
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.audioCacheEnabled = false
        settings.prewarmQueueCount = 0
        let historySuspended = PlayHistoryStore.shared.isRecordingSuspended
        let scrobbleSuspended = ScrobbleService.shared.isSuspended
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        defer {
            PlayHistoryStore.shared.isRecordingSuspended = historySuspended
            ScrobbleService.shared.isSuspended = scrobbleSuspended
        }
        let player = AudioPlayerService(sourceManager: manager, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")))
        defer { player.stop(); CloudPlaybackSource.cancelSessions(sourceID: ids[0]) }
        player.playbackMetadataSourceType = { _ in .baiduPan }
        player.audioEngine.setVolume(0, persist: false)
        player.setQueue([songs[0]])
        await player.play(song: songs[0])
        let playbackDeadline = Date().addingTimeInterval(45)
        while !player.audioEngine.isActuallyPlaying || player.currentTime < 1 {
            guard Date() < playbackDeadline else { XCTFail("Playback did not start"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let before = player.currentTime
        let monitor = Task { @MainActor in
            var stopped = 0
            var samples = 0
            while !Task.isCancelled {
                if !player.audioEngine.isActuallyPlaying { stopped += 1 }
                samples += 1
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            return (stopped, samples)
        }
        defer { monitor.cancel() }
        let roots = Array(Set(songs.map { ($0.filePath as NSString).deletingLastPathComponent })).sorted()
        let scan = Task { () throws -> Set<String> in
            let scanner = ConnectorScanner(connector: sibling, sourceID: ids[1])
            var paths: Set<String> = []
            for try await update in await scanner.scan(directories: roots) {
                paths.formUnion(update.songs.map(\.filePath))
            }
            return paths
        }
        defer { scan.cancel() }
        let cancelled = Task {
            let scanner = ConnectorScanner(connector: connector, sourceID: ids[0])
            for try await _ in await scanner.scan(directories: roots) { try Task.checkCancellation() }
        }
        try await Task.sleep(for: .milliseconds(80))
        cancelled.cancel()
        _ = await cancelled.result
        let backfill = MetadataBackfillService(library: library, sourceManager: manager,
            backfillableSourceIDs: { [ids[0]] }, directFileSourceIDs: { [ids[0]] },
            playbackIsActive: { player.isPlaying }, storageDirectory: root.appendingPathComponent("metadata"),
            artworkStore: MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork")))
        defer { backfill.stop() }
        await connector.prefetchMetadata(paths: songs.map(\.filePath))
        let started = Date()
        var durations: [Double] = []
        for song in songs {
            let start = Date()
            let result = await backfill.rereadTags(songID: song.id, expectedSourceID: ids[0])
            guard case .completed = result else { XCTFail("Real tag reread did not complete"); return }
            durations.append(Date().timeIntervalSince(start))
        }
        let paths = try await scan.value
        XCTAssertTrue(Set(songs.map(\.filePath)).isSubset(of: paths))
        monitor.cancel()
        let health = await monitor.value
        XCTAssertEqual(health.0, 0)
        XCTAssertGreaterThan(player.currentTime, before + 1)
        XCTAssertEqual(library.songs.count, songs.count)
        XCTAssertTrue(library.songs.allSatisfy { $0.duration > 0 })
        await connector.disconnect()
        let writes = await connector.dlinkPersistWriteCount
        let sorted = durations.sorted()
        print("LIVE_BAIDU songs=\(songs.count) seconds=\(Date().timeIntervalSince(started)) read_p50=\(sorted[sorted.count / 2]) cache_writes=\(writes) listed=\(paths.count) playback_advanced=\(player.currentTime - before) stopped_samples=\(health.0)/\(health.1)")
    }

    func testContinuousBackfillCoalescesWritesWithoutStarvingPersistence() async throws {
        let fixture = BaiduMetadataFixture()
        defer { fixture.close() }
        let clock = BaiduPersistClock()
        defer { clock.advance(120) }
        let source = fixture.source(timing: clock.timing)
        await source.prefetchMetadata(paths: [fixture.path(1)])
        try await eventually { clock.hasWaiter }
        clock.advance(2)
        try await eventually { await source.dlinkPersistWriteCount == 1 }
        for index in 2...7 {
            clock.advance(4)
            await source.prefetchMetadata(paths: [fixture.path(index)])
            let writes = await source.dlinkPersistWriteCount
            XCTAssertEqual(writes, 1, "A slow continuous stream must not save once per song")
        }
        try await eventually { clock.hasWaiter }
        clock.advance(6)
        try await eventually { await source.dlinkPersistWriteCount == 2 }
        let rows = try fixture.persistedRows()
        XCTAssertEqual(rows.count, 7, "The scheduled save includes changes arriving while it waited")
        await source.disconnect()
        let writes = await source.dlinkPersistWriteCount
        XCTAssertEqual(writes, 2, "Disconnect with no changes is a no-op")
    }

    func testDisconnectFlushesPendingChangesAndReloadReusesCDN() async throws {
        let fixture = BaiduMetadataFixture()
        defer { fixture.close() }
        let source = fixture.source()
        let data = try await source.fetchRange(path: fixture.path(1), offset: 0, length: 4)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        await source.disconnect()
        XCTAssertEqual(try fixture.persistedRows().count, 1)
        let next = fixture.source()
        _ = try await next.fetchRange(path: fixture.path(1), offset: 0, length: 4)
        await next.disconnect()
        XCTAssertEqual(fixture.headCount, 1, "A new connector should reuse the persisted CDN URL")
    }

    func testInvalidationRemovesPersistedLinksBeforeAnotherConnectorLoadsThem() async throws {
        let fixture = BaiduMetadataFixture()
        defer { fixture.close() }
        let source = fixture.source()
        _ = try await source.fetchRange(path: fixture.path(1), offset: 0, length: 4)
        await source.disconnect()
        await source.invalidateMetadataWritebackCache(for: fixture.path(1))
        XCTAssertTrue(try fixture.persistedRows().isEmpty)
        let next = fixture.source()
        _ = try await next.fetchRange(path: fixture.path(1), offset: 0, length: 4)
        await next.disconnect()
        XCTAssertEqual(fixture.headCount, 2)
    }

    func testCancellingOneReaderDoesNotCancelSharedResolutionOrSiblingReads() async throws {
        let fixture = BaiduMetadataFixture(headDelay: 0.15)
        defer { fixture.close() }
        let source = fixture.source()
        await source.prefetchMetadata(paths: [fixture.path(1), fixture.path(2)])
        let first = Task { try await source.fetchRange(path: fixture.path(1), offset: 0, length: 4) }
        try await eventually { fixture.headCount == 1 }
        let sibling = Task { try await source.fetchRange(path: fixture.path(1), offset: 0, length: 4) }
        let other = Task { try await source.fetchRange(path: fixture.path(2), offset: 0, length: 4) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled reader must stop") } catch is CancellationError {}
        let siblingBytes = try await sibling.value
        let otherBytes = try await other.value
        XCTAssertEqual(siblingBytes, Data([1, 2, 3, 4]))
        XCTAssertEqual(otherBytes, siblingBytes)
        XCTAssertEqual(fixture.headCount, 2, "Two paths need two HEADs, regardless of reader count")
        _ = try await source.fetchRange(path: fixture.path(3), offset: 0, length: 4)
        XCTAssertEqual(fixture.headCount, 3, "The shared resolution session remains usable")
        await source.disconnect()
    }

    func testCancelledMetadataBatchDoesNotVisitRemainingDirectories() async throws {
        let fixture = BaiduMetadataFixture()
        defer { fixture.close() }
        let source = fixture.source()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await source.prefetchMetadata(paths: (1...8).map { "/Directory\($0)/1.flac" })
        }
        await task.value
        XCTAssertEqual(fixture.requestCount, 0)
        await source.disconnect()
    }

    func testCancellingLaterMetadataBatchStillPersistsCompletedBatch() async throws {
        let fixture = BaiduMetadataFixture(itemCount: 108, laterBatchDelay: 0.2)
        defer { fixture.close() }
        let source = fixture.source()
        let task = Task { await source.prefetchMetadata(paths: (1...108).map(fixture.path)) }
        try await eventually { fixture.metadataRequestCount == 2 }
        task.cancel()
        await task.value
        await source.disconnect()
        XCTAssertEqual(try fixture.persistedRows().count, 100)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
        throw URLError(.timedOut)
    }
}

private final class BaiduPersistClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    var hasWaiter: Bool { lock.withLock { !waiters.isEmpty } }
    var timing: RequestExecutor.Timing {
        .init(now: { self.lock.withLock { self.time } }, sleep: { delay in
            await withCheckedContinuation { continuation in
                self.lock.withLock { self.waiters.append((self.time + delay, continuation)) }
            }
        })
    }
    func advance(_ interval: TimeInterval) {
        let ready = lock.withLock {
            time += interval
            let ready = waiters.filter { $0.0 <= time }
            waiters.removeAll { $0.0 <= time }
            return ready
        }
        ready.forEach { $0.1.resume() }
    }
}

private final class BaiduMetadataFixture: @unchecked Sendable {
    let id = UUID().uuidString
    let session: URLSession
    let headDelay: TimeInterval
    let itemCount: Int
    let laterBatchDelay: TimeInterval
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var headCount: Int { lock.withLock { requests.filter { $0.httpMethod == "HEAD" }.count } }
    var requestCount: Int { lock.withLock { requests.count } }
    var metadataRequestCount: Int {
        lock.withLock { requests.filter { $0.url?.query?.contains("method=filemetas") == true }.count }
    }
    init(headDelay: TimeInterval = 0, itemCount: Int = 8, laterBatchDelay: TimeInterval = 0) {
        self.headDelay = headDelay
        self.itemCount = itemCount
        self.laterBatchDelay = laterBatchDelay
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BaiduMetadataProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Metadata-Fixture": id]
        session = URLSession(configuration: configuration)
        BaiduMetadataProtocol.register(self)
    }
    func path(_ index: Int) -> String { "/Music/\(index).flac" }
    func source(timing: RequestExecutor.Timing = .init()) -> BaiduPanSource {
        BaiduPanSource(sourceID: id, session: session, tokenProvider: { "fixture-token" },
            requests: CloudRequestScheduler(), rangeSession: session, dlinkPersistTiming: timing)
    }
    func persistedRows() throws -> [[String: Any]] {
        let url = CloudDriveHelper(sourceID: id).cacheDirectory.appendingPathComponent("dlink_cache.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
    }
    func close() {
        session.invalidateAndCancel()
        BaiduMetadataProtocol.remove(id)
        try? FileManager.default.removeItem(at: CloudDriveHelper(sourceID: id).cacheDirectory.deletingLastPathComponent())
    }
    func response(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        lock.withLock { requests.append(request) }
        if request.httpMethod == "HEAD" {
            return (302, ["Location": "https://cdn.test\(request.url!.path)"], Data())
        }
        if request.url?.host == "cdn.test" {
            return (206, ["Content-Range": "bytes 0-3/4", "Content-Length": "4"], Data([1, 2, 3, 4]))
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let method = query.first { $0.name == "method" }?.value
        let json: [String: Any]
        if method == "list" {
            json = ["errno": 0, "list": (1...itemCount).map {
                ["fs_id": $0, "path": path($0), "server_filename": "\($0).flac", "isdir": 0, "size": 4] as [String: Any]
            }]
        } else if method == "filemetas" {
            let ids = try JSONDecoder().decode([Int].self,
                from: Data((query.first { $0.name == "fsids" }!.value!).utf8))
            json = ["errno": 0, "list": ids.map {
                ["fs_id": $0, "dlink": "https://d.pcs.baidu.com/file/\($0)"] as [String: Any]
            }]
        } else { throw URLError(.unsupportedURL) }
        return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: json))
    }
}

private final class BaiduMetadataProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: BaiduMetadataFixture] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func register(_ fixture: BaiduMetadataFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    static func remove(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Metadata-Fixture"),
                  let fixture = Self.lock.withLock({ Self.fixtures[id] }) else { throw URLError(.unsupportedURL) }
            let (status, headers, data) = try fixture.response(request)
            let delay = request.httpMethod == "HEAD" ? fixture.headDelay
                : fixture.metadataRequestCount >= 2 ? fixture.laterBatchDelay : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                stateLock.withLock {
                    guard !stopped else { return }
                    let response = HTTPURLResponse(url: request.url!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: headers)!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

private final class BaiduWriteFixture: @unchecked Sendable {
    enum Mode: Equatable { case lostResponse, httpFailure(Int), conflict, limitedThenConflict, success, readRetry }
    static let path = "/Music/song.flac"
    let mode: Mode
    private let lock = NSLock()
    private var creates = 0
    private var lists = 0
    var listCount: Int { lock.withLock { lists } }
    var createCount: Int { lock.withLock { creates } }
    init(mode: Mode) { self.mode = mode }

    func response(to request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            let method = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "method" }?.value
            let json: [String: Any]
            switch method {
            case "precreate":
                json = ["errno": 0, "uploadid": "fixture-upload", "block_list": []]
            case "list":
                lists += 1
                if mode == .readRetry, lists == 1 { return (503, Data()) }
                let revision = mode == .conflict ? "edited-elsewhere"
                    : creates == 0 ? "original" : "changed"
                json = ["errno": 0, "list": [["path": Self.path, "server_filename": "song.flac",
                                               "isdir": 0, "size": 4, "fs_id": 1,
                                               "md5": revision]]]
            case "create":
                creates += 1
                if creates == 1 {
                    switch mode {
                    case .lostResponse: throw URLError(.timedOut)
                    case .httpFailure(let status): return (status, Data("Temporary failure".utf8))
                    case .limitedThenConflict:
                        return (200, try JSONSerialization.data(withJSONObject: ["errno": 31034]))
                    default: break
                    }
                }
                json = ["errno": 0]
            default: throw URLError(.unsupportedURL)
            }
            return (200, try JSONSerialization.data(withJSONObject: json))
        }
    }
}

private final class BaiduWriteFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: BaiduWriteFixture] = [:]
    func insert(_ value: BaiduWriteFixture, for id: String) { lock.withLock { values[id] = value } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> BaiduWriteFixture? { lock.withLock { values[id] } }
}

private final class BaiduWriteProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = BaiduWriteFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID"),
                  let fixture = Self.fixtures.get(id) else { throw URLError(.unsupportedURL) }
            let (status, data) = try fixture.response(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
