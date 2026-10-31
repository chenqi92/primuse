import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

final class WebDAVLiveScanTests: XCTestCase {
    @MainActor
    func testMultipleSourcesPerformanceAndCancellationIsolation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["PRIMUSE_QA_WEBDAV_URL"], let url = URL(string: address), let host = url.host,
              let username = env["PRIMUSE_QA_WEBDAV_USER"], let password = env["PRIMUSE_QA_WEBDAV_PASSWORD"],
              let rootsJSON = env["PRIMUSE_QA_PERFORMANCE_ROOTS"] else {
            throw XCTSkip("Requires an opt-in read-only multi-directory WebDAV sample")
        }
        let roots = try JSONDecoder().decode([String].self, from: Data(rootsJSON.utf8))
        XCTAssertGreaterThanOrEqual(roots.count, 16)
        let sources = (0..<2).map { index -> MusicSource in
            var source = MusicSource(id: UUID().uuidString, name: "Parallel scan QA \(index)", type: .webdav,
                host: host, port: url.port ?? 80, authType: .none)
            source.extraConfig = MusicSource.encodeScannedDirectories(roots, into: nil, type: .webdav)
            return source
        }
        let bases = sources.map { source in
            WebDAVSource(sourceID: source.id, host: host, port: url.port, useSsl: url.scheme == "https",
                basePath: url.path, username: username, password: password)
        }
        addTeardownBlock {
            for source in sources { try? FileManager.default.removeItem(at: CueSheetScanCache.directory(sourceID: source.id).deletingLastPathComponent()) }
        }
        for base in bases { try await base.connect() }
        addTeardownBlock { for base in bases { await base.disconnect() } }

        func collect(_ index: Int, capacity: Int, probe: LiveListingProbe? = nil) async throws -> (songs: [Song], seconds: Double) {
            let measured = LiveDirectoryConnector(bases[index], sourceID: sources[index].id, capacity: capacity, probe: probe)
            let scanner = ConnectorScanner(connector: measured, sourceID: sources[index].id)
            let start = Date()
            var songs: [Song] = []
            for try await update in await scanner.scan(directories: roots) { if update.carriesFullSnapshot { songs = update.songs } }
            let seconds = Date().timeIntervalSince(start)
            let listed = await measured.listed
            let peak = await measured.peak
            let durations = await measured.durations.sorted()
            XCTAssertEqual(listed.count, Set(listed).count)
            XCTAssertLessThanOrEqual(peak, capacity)
            XCTAssertGreaterThan(songs.count, 0)
            print("SCAN_PERF source=\(index) slots=\(capacity) directories=\(listed.count) songs=\(songs.count) peak=\(peak) seconds=\(seconds) list_p50=\(durations[durations.count / 2]) list_p95=\(durations[min(durations.count - 1, durations.count * 95 / 100)])")
            return (songs, seconds)
        }

        // Warm both sources before alternating the order, so TLS/keep-alive and CUE caches do not favour four slots.
        let reference = try await collect(0, capacity: 4)
        let secondReference = try await collect(1, capacity: 4)
        let expectedPaths = Set(reference.songs.map(\.filePath))
        XCTAssertEqual(expectedPaths, Set(secondReference.songs.map(\.filePath)))
        if env["PRIMUSE_QA_SKIP_DIRECTORY_BENCHMARK"] != "1" {
            var timings: [Int: [Double]] = [:]
            for capacities in [[1, 2, 4, 8], [8, 4, 2, 1], [2, 8, 1, 4]] {
                for capacity in capacities {
                    let run = try await collect(0, capacity: capacity)
                    XCTAssertEqual(Set(run.songs.map(\.id)), Set(reference.songs.map(\.id)))
                    timings[capacity, default: []].append(run.seconds)
                }
            }
            for capacity in [1, 2, 4, 8] {
                print("SCAN_PERF_MEDIAN slots=\(capacity) seconds=\(timings[capacity]!.sorted()[1])")
            }
            for capacity in [4, 8, 8, 4, 4, 8] {
                let start = Date()
                let count = try await withThrowingTaskGroup(of: Int.self) { group in
                    var next = 0
                    var total = 0
                    for _ in 0..<min(capacity, roots.count) {
                        let path = roots[next]
                        next += 1
                        group.addTask { try await bases[0].listFiles(at: path).count }
                    }
                    while let result = try await group.next() {
                        total += result
                        if next < roots.count {
                            let path = roots[next]
                            next += 1
                            group.addTask { try await bases[0].listFiles(at: path).count }
                        }
                    }
                    return total
                }
                print("SCAN_LISTING_CEILING slots=\(capacity) entries=\(count) seconds=\(Date().timeIntervalSince(start))")
            }
            for (round, capacity) in [4, 8, 8, 4, 4, 8].enumerated() {
                let probe = LiveListingProbe()
                let start = Date()
                async let first = collect(0, capacity: capacity, probe: probe)
                async let second = collect(1, capacity: capacity, probe: probe)
                let pair = try await (first, second)
                XCTAssertEqual(Set(pair.0.songs.map(\.id)), Set(reference.songs.map(\.id)))
                XCTAssertEqual(Set(pair.1.songs.map(\.id)), Set(secondReference.songs.map(\.id)))
                let peak = await probe.peak
                let overlap = await probe.overlappingSources
                XCTAssertTrue(overlap)
                XCTAssertLessThanOrEqual(peak, capacity * 2)
                print("SCAN_PERF_PAIR round=\(round) slots=\(capacity) queued_and_active_peak=\(peak) first=\(pair.0.seconds) second=\(pair.1.seconds) total=\(Date().timeIntervalSince(start))")
            }

        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        sources.forEach { store.add($0) }
        let probe = LiveListingProbe()
        let connectors = zip(sources, bases).map { LiveDirectoryConnector($0.1, sourceID: $0.0.id, capacity: $0.1.directoryListingConcurrency, probe: probe) }
        let manager = SourceManager(sourcesProvider: { sources }, connectorFactory: { source in
            connectors[source.id == sources[0].id ? 0 : 1]
        })
        let service = ScanService(fileManager: LiveScanFileManager(root: root.appendingPathComponent("scan")),
            connectorProvider: { source in connectors[source.id == sources[0].id ? 0 : 1] },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        defer { service.cancelAllActiveScans() }
        addTeardownBlock { @MainActor in await manager.disconnectAll() }
        func start(_ index: Int) {
            XCTAssertTrue(service.scanSource(sources[index], sourceManager: manager, library: library,
                sourceStore: store, requestsContinuedProcessing: false))
        }
        func waitForCompletion(_ index: Int) async throws {
            let deadline = Date().addingTimeInterval(90)
            while service.scanStates[sources[index].id]?.isScanning == true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(service.scanStates[sources[index].id]?.isScanning == true)
            XCTAssertFalse(service.scanStates[sources[index].id]?.canResume == true)
            XCTAssertNil(service.scanStates[sources[index].id]?.failureMessage)
            XCTAssertNotNil(store.source(id: sources[index].id)?.lastScannedAt)
        }
        let integratedStart = Date()
        start(0)
        start(1)
        let admissionDeadline = Date().addingTimeInterval(10)
        while !(await probe.overlappingSources), Date() < admissionDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let overlapped = await probe.overlappingSources
        XCTAssertTrue(overlapped)
        service.cancelScan(for: sources[0].id)
        try await waitForCompletion(1)
        let secondSongs = library.songs.filter { $0.sourceID == sources[1].id }
        XCTAssertEqual(Set(secondSongs.map(\.id)), Set(secondReference.songs.map(\.id)))
        XCTAssertTrue(service.scanStates[sources[0].id]?.canResume == true)
        start(0)
        try await waitForCompletion(0)
        XCTAssertEqual(Set(library.songs.filter { $0.sourceID == sources[0].id }.map(\.id)), Set(reference.songs.map(\.id)))
        XCTAssertEqual(Set(library.songs.filter { $0.sourceID == sources[1].id }.map(\.id)), Set(secondSongs.map(\.id)))
        XCTAssertEqual(library.songs.count, reference.songs.count + secondReference.songs.count)
        print("SCAN_PERF_SERVICE cancel_one_other_completed=true resumed=true songs=\(library.songs.count) seconds=\(Date().timeIntervalSince(integratedStart))")
        var rescanCompletions: [String: SourceScanLifecycleCompletion] = [:]
        service.successfulSourceScanHandler = { rescanCompletions[$0] = $1 }
        let rescanStart = Date()
        start(0)
        start(1)
        try await waitForCompletion(0)
        try await waitForCompletion(1)
        XCTAssertEqual(library.songs.count, reference.songs.count + secondReference.songs.count)
        XCTAssertTrue(sources.allSatisfy { rescanCompletions[$0.id] == .committedNoChanges })
        print("SCAN_PERF_SERVICE full_pair_rescan=true songs=\(library.songs.count) seconds=\(Date().timeIntervalSince(rescanStart))")
    }

    @MainActor
    func testRealDirectoryScanBackfillAndConcurrentPlayback() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PRIMUSE_QA_WEBDAV_URL"],
              let url = URL(string: address), let host = url.host,
              let username = environment["PRIMUSE_QA_WEBDAV_USER"],
              let password = environment["PRIMUSE_QA_WEBDAV_PASSWORD"],
              let rootsJSON = environment["PRIMUSE_QA_WEBDAV_ROOTS"] else {
            throw XCTSkip("Requires a read-only QA WebDAV account and ordinary music in multiple directories")
        }
        let roots = try JSONDecoder().decode([String].self, from: Data(rootsJSON.utf8))
        let source = MusicSource(id: UUID().uuidString, name: "Directory scan QA", type: .webdav,
                                 host: host, port: url.port ?? 80, authType: .none)
        let connector = WebDAVSource(sourceID: source.id, host: host, port: url.port,
                                     useSsl: url.scheme == "https", basePath: url.path,
                                     username: username, password: password)
        addTeardownBlock { await connector.disconnect() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(source.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await connector.connect()

        func scan(capacity: Int, existing: [Song] = [], resume: SourceScanResumeState? = nil,
                  stopEarly: Bool = false) async throws -> ConnectorScanner.ScanUpdate {
            let measured = LiveDirectoryConnector(connector, sourceID: source.id, capacity: capacity)
            let scanner = ConnectorScanner(connector: measured, sourceID: source.id)
            let started = Date()
            var last: ConnectorScanner.ScanUpdate?
            for try await update in await scanner.scan(directories: roots, existingSongs: existing, resumeState: resume) {
                last = update
                if stopEarly, let checkpoint = update.resumeState,
                   !checkpoint.pendingDirectories.isEmpty, !checkpoint.encounteredSongIDs.isEmpty { break }
            }
            var result = try XCTUnwrap(last)
            if stopEarly { result.songs = await scanner.takePendingChangedSongs() }
            let deadline = Date().addingTimeInterval(3)
            while await measured.active > 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let active = await measured.active
            let peak = await measured.peak
            let listed = await measured.listed
            XCTAssertEqual(active, 0, "Stopping the stream must drain directory requests")
            XCTAssertLessThanOrEqual(peak, capacity)
            if !stopEarly {
                XCTAssertEqual(result.resumeState?.pendingDirectories, [])
                XCTAssertEqual(Set(listed).count, listed.count, "A completed directory is listed once")
            }
            if capacity > 1, !stopEarly, resume == nil { XCTAssertGreaterThan(peak, 1) }
            print("LIVE_WEBDAV capacity=\(capacity) directories=\(listed.count) peak=\(peak) songs=\(result.songs.count) seconds=\(Date().timeIntervalSince(started)) interrupted=\(stopEarly)")
            return result
        }

        let serial = try await scan(capacity: 1)
        let parallel = try await scan(capacity: connector.directoryListingConcurrency)
        XCTAssertGreaterThan(parallel.songs.count, 0)
        XCTAssertEqual(Set(serial.songs.map(\.id)), Set(parallel.songs.map(\.id)))
        let interrupted = try await scan(capacity: 4, stopEarly: true)
        let checkpoint = try XCTUnwrap(interrupted.resumeState)
        XCTAssertFalse(checkpoint.pendingDirectories.isEmpty)
        XCTAssertFalse(interrupted.songs.isEmpty)
        let resumed = try await scan(capacity: 4, existing: interrupted.songs, resume: checkpoint)
        XCTAssertEqual(Set(resumed.songs.map(\.id)), Set(parallel.songs.map(\.id)))

        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let selected = Array(parallel.songs.filter { $0.fileFormat == .flac }.prefix(5))
        XCTAssertFalse(selected.isEmpty)
        library.addSongs(selected)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        addTeardownBlock { @MainActor in await manager.disconnectAll() }
        let artwork = MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork"))
        let backfill = MetadataBackfillService(library: library, sourceManager: manager,
            backfillableSourceIDs: { [source.id] }, directFileSourceIDs: { [source.id] },
            pooledHTTPRangeSourceIDs: { [source.id] }, storageDirectory: root.appendingPathComponent("metadata"),
            artworkStore: artwork)
        defer { backfill.stop() }
        backfill.sourceScanSucceeded(forSourceID: source.id)
        XCTAssertTrue(backfill.startUserInitiated(sourceID: source.id))
        let metadataDeadline = Date().addingTimeInterval(90)
        while backfill.remainingCount(forSource: source.id) > 0, Date() < metadataDeadline {
            try await Task.sleep(for: .milliseconds(100))
            backfill.refreshStatusSnapshot()
        }
        XCTAssertEqual(backfill.remainingCount(forSource: source.id), 0)
        let tagged = library.songs
        XCTAssertEqual(tagged.count, selected.count)
        XCTAssertTrue(tagged.allSatisfy { $0.duration > 0 })
        XCTAssertTrue(tagged.contains { $0.artistName?.isEmpty == false })
        print("LIVE_WEBDAV backfilled=\(tagged.count) durations=\(tagged.map(\.duration))")

        let suite = "DirectoryPlayback.\(source.id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.prewarmQueueCount = 0
        settings.audioCacheEnabled = false
        let historyWasSuspended = PlayHistoryStore.shared.isRecordingSuspended
        let scrobbleWasSuspended = ScrobbleService.shared.isSuspended
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        defer {
            PlayHistoryStore.shared.isRecordingSuspended = historyWasSuspended
            ScrobbleService.shared.isSuspended = scrobbleWasSuspended
        }
        let player = AudioPlayerService(sourceManager: manager, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")))
        defer {
            player.stop()
            CloudPlaybackSource.cancelSessions(sourceID: source.id)
        }
        player.playbackMetadataSourceType = { _ in .webdav }
        player.audioEngine.setVolume(0, persist: false)
        let song = try XCTUnwrap(tagged.first)
        player.setQueue([song])
        await player.play(song: song)
        let playbackDeadline = Date().addingTimeInterval(30)
        while (!player.audioEngine.isActuallyPlaying || player.currentTime < 1), Date() < playbackDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(player.audioEngine.isActuallyPlaying)
        let before = player.currentTime
        let stressID = UUID().uuidString
        let stressBase = WebDAVSource(sourceID: stressID, host: host, port: url.port, useSsl: url.scheme == "https",
            basePath: url.path, username: username, password: password)
        try await stressBase.connect()
        addTeardownBlock {
            await stressBase.disconnect()
            try? FileManager.default.removeItem(at: CueSheetScanCache.directory(sourceID: stressID).deletingLastPathComponent())
        }
        let stressRoots = try environment["PRIMUSE_QA_PERFORMANCE_ROOTS"].map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        } ?? roots
        let stressConnector = LiveDirectoryConnector(stressBase, sourceID: stressID, capacity: stressBase.directoryListingConcurrency)
        let stress = Task {
            let deadline = Date().addingTimeInterval(5)
            var scans = 0
            while Date() < deadline {
                try Task.checkCancellation()
                let scanner = ConnectorScanner(connector: stressConnector, sourceID: stressID)
                for try await _ in await scanner.scan(directories: stressRoots) {}
                scans += 1
            }
            return scans
        }
        defer { stress.cancel() }
        let rescanned = try await scan(capacity: connector.directoryListingConcurrency, existing: tagged)
        var stalledSamples = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if !player.audioEngine.isActuallyPlaying { stalledSamples += 1 }
        }
        let stressScans = try await stress.value
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(player.audioEngine.isActuallyPlaying)
        XCTAssertGreaterThan(player.currentTime, before + 4)
        XCTAssertEqual(stalledSamples, 0)
        for song in tagged {
            let preserved = try XCTUnwrap(rescanned.songs.first { $0.id == song.id })
            XCTAssertEqual(preserved.duration, song.duration)
            XCTAssertEqual(preserved.title, song.title)
        }
        let stressPeak = await stressConnector.peak
        print("LIVE_WEBDAV playback_advanced=\(player.currentTime - before) metadata_preserved=\(tagged.count) concurrent_scans=\(stressScans) scan_peak=\(stressPeak) stopped_samples=\(stalledSamples)")
    }
}

private actor LiveDirectoryConnector: MusicSourceConnector {
    let sourceID: String
    nonisolated let directoryListingConcurrency: Int
    let base: WebDAVSource
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var listed: [String] = []
    private(set) var durations: [Double] = []
    private let probe: LiveListingProbe?
    init(_ base: WebDAVSource, sourceID: String, capacity: Int, probe: LiveListingProbe? = nil) {
        self.base = base
        self.sourceID = sourceID
        directoryListingConcurrency = capacity
        self.probe = probe
    }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        active += 1
        peak = max(peak, active)
        listed.append(path)
        let started = Date()
        await probe?.begin(sourceID)
        let result: Result<[RemoteFileItem], Error>
        do { result = .success(try await base.listFiles(at: path)) }
        catch { result = .failure(error) }
        await probe?.end(sourceID)
        durations.append(Date().timeIntervalSince(started))
        active -= 1
        return try result.get()
    }
    func localURL(for path: String) async throws -> URL { try await base.localURL(for: path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { try await base.streamData(for: path) }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { try await base.scanAudioFiles(from: path) }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data { try await base.fetchRange(path: path, offset: offset, length: length) }
}

private actor LiveListingProbe {
    private var counts: [String: Int] = [:]
    private(set) var peak = 0
    private(set) var overlappingSources = false
    func begin(_ sourceID: String) {
        counts[sourceID, default: 0] += 1
        peak = max(peak, counts.values.reduce(0, +))
        overlappingSources = overlappingSources || counts.values.filter { $0 > 0 }.count > 1
    }
    func end(_ sourceID: String) { counts[sourceID, default: 0] -= 1 }
}

private final class LiveScanFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

final class WebDAVDirectoryQuotaTests: XCTestCase {
    func testSourcesShareEightSlotsAndCancellingOneAdmitsWaitingSource() async throws {
        let fixture = DirectoryQuotaFixture { request in
            request.url!.path.contains("held-") ? nil : DirectoryQuotaFixture.listing(request)
        }
        let host = UUID().uuidString + ".invalid"
        let sources = (0..<3).map { _ in makeSource(fixture, host: host) }
        for source in sources { try await source.connect() }
        func start(_ index: Int) -> Task<Int, Error> {
            Task {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for directory in 0..<4 {
                        group.addTask {
                            try await sources[index].listFiles(at: "/held-\(index)-\(directory)").count
                        }
                    }
                    var completed = 0
                    for try await _ in group { completed += 1 }
                    return completed
                }
            }
        }
        let first = start(0)
        defer { first.cancel() }
        try await fixture.waitForRequests(7)
        let second = start(1)
        defer { second.cancel() }
        try await fixture.waitForRequests(11)
        let waiting = start(2)
        defer { waiting.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.requests.count, 11, "Three sources share eight transport admissions")
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        try await fixture.waitForRequests(15)
        for index in 1...2 {
            for directory in 0..<4 { fixture.releaseHeld(path: "/Music/held-\(index)-\(directory)") }
        }
        let completedSecond = try await second.value
        let completedWaiting = try await waiting.value
        XCTAssertEqual(completedSecond, 4)
        XCTAssertEqual(completedWaiting, 4)
    }

    func testDirectoryRecoveryAndDeletionConfirmationDoNotCancelSiblingRequests() async throws {
        for action in ["retry", "confirm", "cancel"] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/held") { return nil }
                if request.url!.path.contains("/retry") { return (503, [:], Data()) }
                return DirectoryQuotaFixture.listing(request)
            }
            let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
            try await source.connect()
            let sibling = Task { try await source.listFiles(at: "/held-sibling") }
            defer { sibling.cancel() }
            try await fixture.waitForRequests(2)
            switch action {
            case "retry":
                do { _ = try await source.listFiles(at: "/retry"); XCTFail("Expected failure") }
                catch SourceError.connectionFailed { }
            case "confirm":
                _ = try await source.listFiles(at: "/empty", confirmingPreviouslyObservedPaths: ["/empty/old.flac"])
            default:
                let cancelled = Task { try await source.listFiles(at: "/held-cancel") }
                try await fixture.waitForRequests(3)
                cancelled.cancel()
                do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
                catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
            }
            fixture.releaseHeld(path: "/Music/held-sibling/")
            let files = try await sibling.value
            XCTAssertTrue(files.isEmpty, action)
        }
    }

    func testDisconnectCancelsRequestsOnRetiredDirectorySessions() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/held") { return nil }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let finished = expectation(description: "Disconnected directory request finishes promptly")
        let pending = Task {
            defer { finished.fulfill() }
            return try await source.listFiles(at: "/held")
        }
        defer { pending.cancel() }
        try await fixture.waitForRequests(2)
        _ = try await source.listFiles(at: "/empty", confirmingPreviouslyObservedPaths: ["/empty/old.flac"])
        await source.disconnect()
        await fulfillment(of: [finished], timeout: 2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Disconnect must cancel the retired session") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        try await source.connect()
        _ = try await source.listFiles(at: "/healthy")
    }

    func testLongCooldownSurvivesAnotherDirectoryAndConnector() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let host = UUID().uuidString + ".invalid"
        let first = makeSource(fixture, host: host)
        let second = makeSource(fixture, host: host)
        try await first.connect()
        try await second.connect()
        for (source, path) in [(first, "/A"), (first, "/B"), (second, "/C")] {
            do { _ = try await source.listFiles(at: path); XCTFail("A shared directory cooldown must stop this call") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, 429)
                XCTAssertTrue(error.isRateLimited)
                XCTAssertGreaterThan(error.retryAfter ?? 0, 3590)
            }
        }
        XCTAssertEqual(fixture.requests.count, 3, "Only two connects and the initial limited PROPFIND may reach transport")
        fixture.clock.advance(to: 3599)
        let nearDeadline = Task { try await second.listFiles(at: "/B") }
        defer { nearDeadline.cancel() }
        try await fixture.clock.waitForSleep(at: 3600)
        XCTAssertEqual(fixture.requests.count, 3, "No PROPFIND may send before the complete server deadline")
        fixture.clock.advance(to: 3600)
        let files = try await nearDeadline.value
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testExplicit503SecondsAndDateSurviveReconnectAndCredentialRotation() async throws {
        for header in ["3600", "Tue, 14 Nov 2023 23:13:20 GMT"] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/A") { return (503, ["Retry-After": header], Data()) }
                return DirectoryQuotaFixture.listing(request)
            }
            let host = UUID().uuidString + ".invalid"
            let source = makeSource(fixture, host: host)
            try await source.connect()
            do { _ = try await source.listFiles(at: "/A"); XCTFail("Expected explicit service cooldown") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, 503)
                XCTAssertTrue(error.isRateLimited)
                XCTAssertEqual(error.retryAfter, 3600)
            }
            await source.disconnect()
            let replacement = makeSource(fixture, host: host.uppercased(), password: "rotated-fixture")
            for candidate in [source, replacement] {
                do { try await candidate.connect(); XCTFail("Reconnection must retain the account deadline") }
                catch let error as RemoteDirectoryHTTPStatusError {
                    XCTAssertEqual(error.statusCode, 503)
                    XCTAssertEqual(error.retryAfter, 3600)
                }
            }
            XCTAssertEqual(fixture.requests.count, 2)
        }
    }

    func testOtherAccountsEndpointsAndRangeReadsRemainUsable() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.httpMethod == "GET" {
                return (206, ["Content-Type": "audio/flac", "Content-Range": "bytes 0-3/100", "Content-Length": "4"], Data("fLaC".utf8))
            }
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let host = UUID().uuidString + ".invalid"
        let source = makeSource(fixture, host: host)
        try await source.connect()
        _ = try? await source.listFiles(at: "/A")
        let data = try await source.fetchRange(path: "/song.flac", offset: 0, length: 4)
        XCTAssertEqual(data, Data("fLaC".utf8))
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("reader:fixture".utf8).base64EncodedString())
        for other in [makeSource(fixture, host: host, username: "other"),
                      makeSource(fixture, host: host, port: 8443),
                      makeSource(fixture, host: "other." + host)] {
            try await other.connect()
        }
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testHeaderless429HasFiniteWaitsAndCancellationDoesNotResetCooldown() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, [:], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let limited = Task { try await source.listFiles(at: "/A") }
        defer { limited.cancel() }
        for deadline: TimeInterval in [2, 7, 17] {
            try await fixture.clock.waitForSleep(at: deadline)
            fixture.clock.advance(to: deadline)
        }
        do { _ = try await limited.value; XCTFail("A fourth wait must not be scheduled") }
        catch let error as RemoteDirectoryHTTPStatusError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.retryAfter, 10)
        }
        XCTAssertEqual(fixture.requests.count, 5, "One connect plus exactly four attempts, without nested executor retries")
        let next = Task { try await source.listFiles(at: "/B") }
        defer { next.cancel() }
        try await fixture.clock.waitForSleep(at: 27)
        XCTAssertEqual(fixture.requests.count, 5)
        next.cancel()
        do { _ = try await next.value; XCTFail("Waiting directory cancellation must finish") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        fixture.clock.advance(to: 27)
        _ = try await source.listFiles(at: "/B")
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testOrdinary503DoesNotBlockAnotherDirectoryOrAddNestedRetries() async throws {
        for headers in [[:], ["Retry-After": "malformed"]] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/slow") { return (503, headers, Data()) }
                return DirectoryQuotaFixture.listing(request)
            }
            let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
            try await source.connect()
            do { _ = try await source.listFiles(at: "/slow"); XCTFail("The directory must still fail") }
            catch SourceError.connectionFailed { }
            _ = try await source.listFiles(at: "/healthy")
            XCTAssertEqual(fixture.requests.count, 4, "One connect, two transient attempts, one healthy directory")
        }
    }

    func testCancellingAnInflightDirectoryReleasesItsAdmission() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/held") { return nil }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let pending = Task { try await source.listFiles(at: "/held") }
        defer { pending.cancel() }
        try await fixture.waitForRequests(2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled transport must complete promptly") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        _ = try await source.listFiles(at: "/healthy")
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testFreshEmptyConfirmationPreservesListingAndHTTPContracts() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/missing") { return (404, [:], Data()) }
            if request.url!.path.contains("/denied") { return (403, [:], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let files = try await source.listFiles(at: "/empty", confirmingPreviouslyObservedPaths: ["/empty/old.flac"])
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/Music/empty" || $0.url?.path == "/Music/empty/" }.count, 2)
        do { _ = try await source.listFiles(at: "/missing"); XCTFail("Missing directory must retain its path error") }
        catch SourceError.pathNotFound(let path) { XCTAssertEqual(path, "/missing") }
        do { _ = try await source.listFiles(at: "/denied"); XCTFail("Permission failure must not become a quota") }
        catch SourceError.authenticationFailed { }
        _ = try await source.listFiles(at: "/healthy")
        XCTAssertEqual(fixture.requests.count, 6)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "PROPFIND" && $0.value(forHTTPHeaderField: "Depth") == "1" })
    }

    func testDirectoryBodyLimitAndMalformedXMLRemainFailures() async throws {
        for body in [Data(repeating: 32, count: 16 * 1024 * 1024 + 1), Data("<broken>".utf8)] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/invalid") { return (207, [:], body) }
                return DirectoryQuotaFixture.listing(request)
            }
            let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
            try await source.connect()
            do { _ = try await source.listFiles(at: "/invalid"); XCTFail("Invalid data must never become an authoritative empty listing") }
            catch {
                if body.count > 16 * 1024 * 1024 {
                    XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
                } else if case SourceError.connectionFailed = error { }
                else { XCTFail("Unexpected XML failure: \(error)") }
            }
            _ = try await source.listFiles(at: "/healthy")
        }
    }

    func testPopulatedDirectoryRetainsPathScopeAndProperties() async throws {
        let fixture = DirectoryQuotaFixture { request in
            let response = DirectoryQuotaFixture.listing(request)
            let prefix = request.url!.path.hasSuffix("/") ? request.url!.path : request.url!.path + "/"
            let child = """
            <D:response><D:href>\(prefix)track%20%26%20song.flac</D:href><D:propstat><D:prop>
            <D:displayname>Track &amp; Song</D:displayname><D:getcontentlength>123</D:getcontentlength>
            <D:getetag>fixture</D:getetag><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            """
            let xml = String(decoding: response.2, as: UTF8.self).replacingOccurrences(of: "</D:multistatus>", with: child + "</D:multistatus>")
            return (207, response.1, Data(xml.utf8))
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let files = try await source.listFiles(at: "/日本語")
        XCTAssertEqual(files.map(\.path), ["/日本語/track & song.flac"])
        XCTAssertEqual(files.first?.name, "Track & Song")
        XCTAssertEqual(files.first?.size, 123)
        XCTAssertEqual(files.first?.revision, "fixture")
    }

    private func makeSource(_ fixture: DirectoryQuotaFixture, host: String, port: Int? = nil,
                            username: String = "reader", password: String = "fixture") -> WebDAVSource {
        let id = "webdav-quota-" + UUID().uuidString
        let source = WebDAVSource(sourceID: id, host: host, port: port, useSsl: true, basePath: "/Music",
                                  username: username, password: password, sessionConfiguration: { fixture.configuration() },
                                  quotaRegistry: fixture.registry, directoryTiming: fixture.clock.timing)
        addTeardownBlock {
            await source.disconnect()
            fixture.close()
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(id)
            try? FileManager.default.removeItem(at: cache)
        }
        return source
    }
}

private final class DirectoryQuotaFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)?
    let id = UUID().uuidString
    let clock = DirectoryQuotaClock()
    let registry: RequestQuotaRegistry
    private let handler: Handler
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var held: [DirectoryQuotaProtocol] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(_ handler: @escaping Handler) {
        self.handler = handler
        registry = RequestQuotaRegistry(timing: clock.timing)
        DirectoryQuotaProtocol.register(self)
    }
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectoryQuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Directory-Fixture": id]
        return config
    }
    func close() { DirectoryQuotaProtocol.remove(id) }
    func hold(_ request: DirectoryQuotaProtocol) { lock.withLock { held.append(request) } }
    func releaseHeld(path: String) {
        let requests = lock.withLock {
            let matches = held.filter { $0.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            held.removeAll { candidate in matches.contains { $0 === candidate } }
            return matches
        }
        for request in requests { request.complete(Self.listing(request.request)) }
    }
    func response(_ request: URLRequest) -> (Int, [String: String], Data)? {
        lock.withLock { captured.append(request) }
        return handler(request)
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<2000 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    static func listing(_ request: URLRequest) -> (Int, [String: String], Data) {
        var path = request.url!.path
        if !path.hasSuffix("/") { path += "/" }
        return (207, ["Content-Type": "application/xml"], Data("""
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(path)</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """.utf8))
    }
}

private final class DirectoryQuotaProtocol: URLProtocol, @unchecked Sendable {
    private let completionLock = NSLock()
    private var finished = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: DirectoryQuotaFixture] = [:]
    static func register(_ fixture: DirectoryQuotaFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    static func remove(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.lock.withLock({ Self.fixtures[request.value(forHTTPHeaderField: "X-Directory-Fixture") ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        guard let response = fixture.response(request) else { fixture.hold(self); return }
        complete(response)
    }
    func complete(_ response: (Int, [String: String], Data)) {
        guard completionLock.withLock({
            if finished { return false }
            finished = true
            return true
        }), let url = request.url else { return }
        let (status, headers, body) = response
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { completionLock.withLock { finished = true } }
}

private final class DirectoryQuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock {
            instant = value
            let ready = sleepers.filter { $0.value.0 <= value }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for (_, continuation) in ready { continuation.resume() }
    }
    private func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sleepers[id] = (instant + interval, continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func waitForSleep(at deadline: TimeInterval) async throws {
        for _ in 0..<2000 {
            if lock.withLock({ sleepers.values.contains { abs($0.0 - deadline) < 0.00001 } }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_700_000_000 + self.now) },
              sleep: { try await self.sleep($0) })
    }
}
