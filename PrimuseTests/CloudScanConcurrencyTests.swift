import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudScanConcurrencyTests: XCTestCase {
    func testCancellationStopsActiveListingsAndDoesNotScheduleMore() async throws {
        let ready = expectation(description: "Four listings started")
        let cancelled = expectation(description: "Active listings cancelled")
        cancelled.expectedFulfillmentCount = 4
        let fixture = BlockingListings(ready: ready, cancelled: cancelled)
        let helper = CloudDriveHelper(sourceID: "cancel-scan-\(UUID())")
        let traversal = Task {
            for try await _ in helper.scanAudioFiles(from: "", listFiles: { try await fixture.list($0) }) {}
        }
        await fulfillment(of: [ready], timeout: 5)
        traversal.cancel()
        _ = await traversal.result
        await fulfillment(of: [cancelled], timeout: 5)
        let starts = await fixture.starts
        XCTAssertEqual(starts, 4)
    }

    func testDirectoryFailureCancelsSiblingsAndReachesConsumer() async throws {
        let ready = expectation(description: "Four listings started")
        let cancelled = expectation(description: "Sibling listings cancelled")
        cancelled.expectedFulfillmentCount = 3
        let fixture = BlockingListings(ready: ready, cancelled: cancelled, fail: true)
        let helper = CloudDriveHelper(sourceID: "failed-scan-\(UUID())")
        do {
            for try await _ in helper.scanAudioFiles(from: "", listFiles: { try await fixture.list($0) }) {}
            XCTFail("A failed directory must fail the scan")
        } catch {
            XCTAssertTrue(error is ListingFailure)
        }
        await fulfillment(of: [ready, cancelled], timeout: 5)
        let starts = await fixture.starts
        XCTAssertEqual(starts, 4)
    }

    func testFilesKeepSidecarsProviderIdentityAndRevision() async throws {
        let path = "/artist/record"
        let names = ["song.flac", "song.lrc", "song.mp4", "bonus.mp4", "cover.jpg"]
        let files = names.map {
            RemoteFileItem(name: $0, path: "\(path)/\($0)", isDirectory: false, size: 10,
                           modifiedDate: nil, revision: "revision-\($0)",
                           providerID: "provider-\($0)", parentPath: path)
        }
        let helper = CloudDriveHelper(sourceID: "sidecars-scan-\(UUID())")
        var result: [RemoteFileItem] = []
        for try await item in helper.scanAudioFiles(from: path, listFiles: { _ in files }) {
            result.append(item)
        }
        XCTAssertEqual(Set(result.map(\.name)), ["song.flac", "bonus.mp4"])
        let song = try XCTUnwrap(result.first { $0.name == "song.flac" })
        XCTAssertEqual(song.sidecarHints?.coverPath, "\(path)/cover.jpg")
        XCTAssertEqual(song.sidecarHints?.lyricsPath, "\(path)/song.lrc")
        XCTAssertEqual(song.sidecarHints?.mvPath, "\(path)/song.mp4")
        XCTAssertEqual(song.revision, "revision-song.flac")
        XCTAssertEqual(song.providerID, "provider-song.flac")
        XCTAssertEqual(song.parentPath, path)
        let video = try XCTUnwrap(result.first { $0.name == "bonus.mp4" })
        XCTAssertEqual(video.sidecarHints?.mvPath, video.path)
    }

    func testNestedDirectoriesShareFourListingSlotsWithoutLosingFiles() async throws {
        let ready = expectation(description: "Four leaf listings are waiting")
        let exceeded = expectation(description: "More than four listings are in flight")
        exceeded.isInverted = true
        let fixture = NestedDirectoryFixture(ready: ready, exceeded: exceeded)
        let helper = CloudDriveHelper(sourceID: "scan-fixture-\(UUID())")
        let traversal = Task {
            var paths: [String] = []
            let stream = helper.scanAudioFiles(from: "", listFiles: { path in
                try await fixture.list(path)
            })
            for try await item in stream {
                paths.append(item.path)
            }
            return paths
        }

        await fulfillment(of: [ready], timeout: 5)
        await fulfillment(of: [exceeded], timeout: 0.2)
        await fixture.release()
        let paths = try await traversal.value

        XCTAssertEqual(paths.count, 64)
        XCTAssertEqual(Set(paths).count, 64, "Each leaf file must be yielded exactly once")
        let peak = await fixture.peak
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

private actor NestedDirectoryFixture {
    let ready: XCTestExpectation
    let exceeded: XCTestExpectation
    var peak = 0
    private var active = 0
    private var leafStarts = 0
    private var reportedExcess = false
    private var released = false
    private var blocked: [CheckedContinuation<Void, Never>] = []

    init(ready: XCTestExpectation, exceeded: XCTestExpectation) {
        self.ready = ready
        self.exceeded = exceeded
    }

    func list(_ path: String) async throws -> [RemoteFileItem] {
        try Task.checkCancellation()
        active += 1
        peak = max(peak, active)
        if active > 4, !reportedExcess {
            reportedExcess = true
            exceeded.fulfill()
        }
        defer { active -= 1 }
        if path.count == 3 {
            leafStarts += 1
            if leafStarts == 4 { ready.fulfill() }
            if !released {
                await withCheckedContinuation { blocked.append($0) }
            }
            return [RemoteFileItem(
                name: "song.flac", path: "\(path)/song.flac", isDirectory: false,
                size: 1, modifiedDate: nil
            )]
        }
        await Task.yield()
        return (0..<4).map {
            RemoteFileItem(name: String($0), path: path + String($0),
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
    }

    func release() {
        released = true
        let continuations = blocked
        blocked.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private struct ListingFailure: Error {}

private actor BlockingListings {
    let ready: XCTestExpectation
    let cancelled: XCTestExpectation
    let fail: Bool
    var starts = 0

    init(ready: XCTestExpectation, cancelled: XCTestExpectation, fail: Bool = false) {
        self.ready = ready
        self.cancelled = cancelled
        self.fail = fail
    }

    func list(_ path: String) async throws -> [RemoteFileItem] {
        if path.isEmpty {
            return (0..<12).map {
                RemoteFileItem(name: String($0), path: String($0), isDirectory: true,
                               size: 0, modifiedDate: nil)
            }
        }
        starts += 1
        if starts == 4 {
            ready.fulfill()
            if fail { throw ListingFailure() }
        }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled.fulfill(); throw error }
        return []
    }
}

final class BaiduSnapshotConcurrencyTests: XCTestCase {
    func testCancellingOneSourceLeavesTheOtherSnapshotComplete() async throws {
        let ready = expectation(description: "First source has active requests")
        let blocked = SnapshotHarness(SnapshotListingFixture(mode: .blockChildren, ready: ready))
        let other = SnapshotHarness(SnapshotListingFixture(mode: .normal))
        defer { blocked.close(); other.close() }
        let first = Task { try await blocked.scan { _, _ in } }
        await fulfillment(of: [ready], timeout: 5)
        let second = Task { try await other.scan { _, _ in } }
        first.cancel()
        if case .success = await first.result { XCTFail("Cancelled source must remain unfinished") }
        let result = try await second.value
        XCTAssertEqual(result.reconciledIndex?.count, 12)
        XCTAssertEqual(other.fixture.counts.count, 7)
        XCTAssertTrue(other.fixture.counts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(blocked.fixture.activeCount, 0)
    }

    func testSlowDirectoryDoesNotHoldUpQueuedDirectoriesAndStaysResumable() async throws {
        let progressed = expectation(description: "Queued directory completes while the first is blocked")
        let fixture = SnapshotListingFixture(mode: .slowFirst)
        let harness = SnapshotHarness(fixture)
        let progress = SnapshotProgressRecorder()
        defer { harness.close() }
        let traversal = Task {
            try await harness.scan { state, _ in
                if await progress.recordQueuedProgress(state) {
                    progressed.fulfill()
                }
            }
        }
        await fulfillment(of: [progressed], timeout: 5)
        fixture.release()
        let changes = try await traversal.value
        XCTAssertEqual(changes.reconciledIndex?.count, 12)
        XCTAssertEqual(fixture.counts.count, 7)
        XCTAssertTrue(fixture.counts.values.allSatisfy { $0 == 1 })
        XCTAssertLessThanOrEqual(fixture.peak, 4)
    }

    func testDirectoryBudgetDrainsAdmittedWorkAndResumeDoesNotRelistIt() async throws {
        let fixture = SnapshotListingFixture(mode: .normal)
        let harness = SnapshotHarness(fixture)
        defer { harness.close() }
        let progress = SnapshotProgressRecorder()
        do {
            _ = try await harness.scan(budget: .init(maximumDirectories: 3)) {
                await progress.record($0, $1)
            }
            XCTFail("Expected the directory budget to stop the traversal")
        } catch BaiduSnapshotExecutionError.budgetExhausted(let reason, _) {
            XCTAssertEqual(reason, .directories)
        }
        let latest = await progress.latest
        let checkpoint = try XCTUnwrap(latest)
        XCTAssertEqual(checkpoint.visitedDirectories.count, 3)
        XCTAssertEqual(checkpoint.pendingDirectories.count, 4)
        XCTAssertEqual(fixture.counts.values.reduce(0, +), 3)

        let changes = try await harness.scan(resume: checkpoint) { _, _ in }
        XCTAssertEqual(changes.reconciledIndex?.count, 12)
        XCTAssertTrue(fixture.counts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(changes.telemetry?.resumed, true)
        XCTAssertEqual(changes.telemetry?.directoryCount, 4)
    }

    func testCancellationPreservesActiveAndQueuedDirectories() async throws {
        let ready = expectation(description: "Four listings are active")
        let fixture = SnapshotListingFixture(mode: .blockChildren, ready: ready)
        let harness = SnapshotHarness(fixture)
        defer { harness.close() }
        let progress = SnapshotProgressRecorder()
        let traversal = Task {
            try await harness.scan { await progress.record($0, $1) }
        }
        await fulfillment(of: [ready], timeout: 5)
        traversal.cancel()
        let result = await traversal.result
        if case .success = result { XCTFail("Cancellation must not produce an authoritative snapshot") }
        let latest = await progress.latest
        let checkpoint = try XCTUnwrap(latest)
        XCTAssertEqual(checkpoint.visitedDirectories, ["/"])
        XCTAssertEqual(Set(checkpoint.pendingDirectories), Set((0..<6).map { "/\($0)" }))
        XCTAssertEqual(fixture.counts.values.reduce(0, +), 5)
        XCTAssertEqual(fixture.activeCount, 0)
    }

    func testFailedSecondPageDoesNotCheckpointPartialDirectory() async throws {
        let fixture = SnapshotListingFixture(mode: .failedSecondPage)
        let harness = SnapshotHarness(fixture)
        defer { harness.close() }
        let progress = SnapshotProgressRecorder()
        do {
            _ = try await harness.scan { await progress.record($0, $1) }
            XCTFail("A failed page must fail the snapshot")
        } catch CloudDriveError.apiError(let code, _) {
            XCTAssertEqual(code, 2)
        }
        let latest = await progress.latest
        let checkpoint = try XCTUnwrap(latest)
        XCTAssertTrue(checkpoint.snapshot.isEmpty)
        XCTAssertTrue(checkpoint.visitedDirectories.isEmpty)
        XCTAssertEqual(checkpoint.pendingDirectories, ["/"])
        XCTAssertEqual(fixture.counts["/"], 2)
    }

    func testDuplicateIdentityAcrossDirectoriesDoesNotCommitTheConflictingDirectory() async throws {
        let fixture = SnapshotListingFixture(mode: .duplicateIdentity)
        let harness = SnapshotHarness(fixture)
        defer { harness.close() }
        let progress = SnapshotProgressRecorder()
        do {
            _ = try await harness.scan { await progress.record($0, $1) }
            XCTFail("Duplicate stable identities must fail the snapshot")
        } catch BaiduSnapshotDiffError.duplicateStableKey(let key) {
            XCTAssertEqual(key, "baidu:100")
        }
        let latest = await progress.latest
        let checkpoint = try XCTUnwrap(latest)
        XCTAssertEqual(checkpoint.visitedDirectories.count, 2)
        XCTAssertEqual(checkpoint.pendingDirectories.count, 5)
        XCTAssertEqual(checkpoint.snapshot.count, 7)
    }

    func testDisappearingDescendantIsDiscardedButMissingRootFails() async throws {
        let descendant = SnapshotHarness(SnapshotListingFixture(mode: .missingChild))
        defer { descendant.close() }
        let changes = try await descendant.scan { _, _ in }
        XCTAssertEqual(changes.reconciledIndex?.count, 10)
        XCTAssertNil(changes.reconciledIndex?["baidu:1"])

        let root = SnapshotHarness(SnapshotListingFixture(mode: .missingRoot))
        defer { root.close() }
        do {
            _ = try await root.scan { _, _ in }
            XCTFail("A missing selected root must not become an empty snapshot")
        } catch SourceRootResolutionError.requiresReselection(let path) {
            XCTAssertEqual(path, "/")
        }
    }
}

private actor SnapshotProgressRecorder {
    var latest: BaiduSnapshotResumeState?
    private var reportedQueuedProgress = false
    func record(_ state: BaiduSnapshotResumeState, _ telemetry: SourceSyncTelemetry) {
        latest = state
    }
    func recordQueuedProgress(_ state: BaiduSnapshotResumeState) -> Bool {
        guard !reportedQueuedProgress, state.visitedDirectories.contains("/4"),
              state.pendingDirectories.contains("/0") else { return false }
        reportedQueuedProgress = true
        return true
    }
}

private struct SnapshotHarness: Sendable {
    let id = UUID().uuidString
    let source: BaiduPanSource
    let session: URLSession
    let fixture: SnapshotListingFixture

    init(_ fixture: SnapshotListingFixture) {
        self.fixture = fixture
        SnapshotListingProtocol.fixtures.insert(fixture, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnapshotListingProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        session = URLSession(configuration: configuration)
        source = BaiduPanSource(sourceID: id, session: session, tokenProvider: { "fixture-token" })
    }

    func scan(
        resume: BaiduSnapshotResumeState? = nil,
        budget: BaiduSnapshotRefreshBudget = .init(),
        progress: @escaping @Sendable (BaiduSnapshotResumeState, SourceSyncTelemetry) async -> Void
    ) async throws -> IncrementalSourceChanges {
        try await source.snapshotChanges(
            from: SourceSyncState(sourceID: id, scopeFingerprint: "fixture"),
            roots: ["/"], rootIdentities: [], resumeState: resume, budget: budget, progress: progress
        )
    }

    func close() {
        fixture.release()
        session.invalidateAndCancel()
        SnapshotListingProtocol.fixtures.remove(id)
    }
}

private final class SnapshotListingFixture: @unchecked Sendable {
    enum Mode { case normal, slowFirst, blockChildren, failedSecondPage, duplicateIdentity, missingChild, missingRoot }
    let mode: Mode
    let ready: XCTestExpectation?
    private let lock = NSLock()
    private var requests: [String: Int] = [:]
    private var active: [ObjectIdentifier: SnapshotListingProtocol] = [:]
    private var held: [SnapshotListingProtocol] = []
    private var maximumActive = 0
    private var released = false
    var counts: [String: Int] { lock.withLock { requests } }
    var peak: Int { lock.withLock { maximumActive } }
    var activeCount: Int { lock.withLock { active.count } }

    init(mode: Mode, ready: XCTestExpectation? = nil) {
        self.mode = mode
        self.ready = ready
    }

    func start(_ connection: SnapshotListingProtocol) {
        let path = connection.directory
        let blocked = lock.withLock {
            requests[path, default: 0] += 1
            active[ObjectIdentifier(connection)] = connection
            maximumActive = max(maximumActive, active.count)
            let shouldHold = !released && (mode == .blockChildren && path != "/"
                || mode == .slowFirst && path == "/0")
            if shouldHold {
                held.append(connection)
                if held.count == 4 { ready?.fulfill() }
            }
            return shouldHold
        }
        if !blocked { complete(connection) }
    }

    func stop(_ connection: SnapshotListingProtocol) {
        lock.withLock {
            active[ObjectIdentifier(connection)] = nil
            held.removeAll { $0 === connection }
        }
    }

    func release() {
        let connections = lock.withLock {
            released = true
            let result = held
            held.removeAll()
            return result
        }
        for connection in connections { complete(connection) }
    }

    private func complete(_ connection: SnapshotListingProtocol) {
        let exists = lock.withLock { active.removeValue(forKey: ObjectIdentifier(connection)) != nil }
        guard exists else { return }
        let path = connection.directory
        let json: [String: Any]
        if mode == .failedSecondPage {
            json = connection.offset == 0
                ? ["errno": 0, "list": (0..<1000).map { entry("/\($0).flac", id: $0 + 1) }]
                : ["errno": 2]
        } else if mode == .missingRoot || mode == .missingChild && path == "/0" {
            json = ["errno": -9]
        } else if path == "/" {
            json = ["errno": 0, "list": (0..<6).map { entry("/\($0)", id: $0 + 1, directory: true) }]
        } else {
            let number = Int(path.dropFirst()) ?? 0
            json = ["errno": 0, "list": [entry("\(path)/song.flac", id: mode == .duplicateIdentity ? 100 : 100 + number)]]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: connection.request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            connection.client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            connection.client?.urlProtocol(connection, didLoad: data)
            connection.client?.urlProtocolDidFinishLoading(connection)
        } catch { connection.client?.urlProtocol(connection, didFailWithError: error) }
    }

    private func entry(_ path: String, id: Int, directory: Bool = false) -> [String: Any] {
        ["path": path, "server_filename": (path as NSString).lastPathComponent,
         "isdir": directory ? 1 : 0, "size": directory ? 0 : 100, "fs_id": id, "md5": "revision"]
    }
}

private final class SnapshotListingFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SnapshotListingFixture] = [:]
    func insert(_ fixture: SnapshotListingFixture, id: String) { lock.withLock { values[id] = fixture } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> SnapshotListingFixture? { lock.withLock { values[id] } }
}

private final class SnapshotListingProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = SnapshotListingFixtures()
    private var fixture: SnapshotListingFixture? {
        request.value(forHTTPHeaderField: "X-Fixture-ID").flatMap { Self.fixtures.get($0) }
    }
    private var query: [URLQueryItem] { URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
    var directory: String { query.first { $0.name == "dir" }?.value ?? "" }
    var offset: Int { Int(query.first { $0.name == "start" }?.value ?? "0") ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.start(self)
    }
    override func stopLoading() { fixture?.stop(self) }
}

final class CloudDirectoryPipelineTests: XCTestCase {
    func testEightSlotConnectorKeepsCloudDefaultAtFour() async throws {
        let ready = expectation(description: "Listings admitted")
        let recorder = PipelineCloudConnector(mode: .blockChildren, ready: ready)
        XCTAssertEqual(recorder.directoryListingConcurrency, 4)
        let connector = PipelineFileConnector(recorder: recorder, capacity: 8)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let task = Task { for try await _ in await scanner.scan(directories: ["/"]) {} }
        defer { task.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while await recorder.peak < 6, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let peak = await recorder.peak
        XCTAssertEqual(peak, 6, "All six available children fit within the eight-slot connector budget")
        await recorder.release()
        try await task.value
    }

    func testChildListingsOverlapSlowCueReadAndRemainResumable() async throws {
        let childrenStarted = expectation(description: "Children listed while root CUE is still reading")
        let cueStarted = expectation(description: "CUE read started")
        let connector = SlowCuePipelineConnector(childrenStarted: childrenStarted, cueStarted: cueStarted)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let task = Task {
            var last: ConnectorScanner.ScanUpdate?
            for try await update in await scanner.scan(directories: ["/"]) { last = update }
            return last
        }
        defer { task.cancel() }
        await fulfillment(of: [cueStarted, childrenStarted], timeout: 3)
        await connector.releaseCue()
        let result = try await task.value
        XCTAssertEqual(result?.songs.count, 8)
        XCTAssertEqual(result?.resumeState?.pendingDirectories, [])
        let listed = await connector.listed
        XCTAssertEqual(listed.count, 9)
        XCTAssertEqual(Set(listed).count, 9)
        let peak = await connector.peak
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testNonOAuthConnectorUsesItsDirectoryCapacityThroughAdaptiveRouting() async throws {
        let ready = expectation(description: "HTTP file connector fills directory slots")
        let recorder = PipelineCloudConnector(mode: .slowFirst, ready: ready)
        let connector = PipelineFileConnector(recorder: recorder)
        let routing = SourceConnectionRouter(sourceID: connector.sourceID, candidates: [
            RoutedConnectorCandidate(kind: .localAddress, endpoint: .init(host: "localhost", port: 80, useSsl: false), connector: connector)
        ], routeDidChange: { _ in })
        XCTAssertEqual(routing.directoryListingConcurrency, 4)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let scan = Task {
            var last: ConnectorScanner.ScanUpdate?
            for try await update in await scanner.scan(directories: ["/"]) { last = update }
            return last
        }
        await fulfillment(of: [ready], timeout: 5)
        await recorder.release()
        let last = try await scan.value
        XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        let peak = await recorder.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, connector.directoryListingConcurrency)
        let listed = await recorder.listed
        XCTAssertEqual(Set(listed), Set(["/"] + (0..<6).map { "/\($0)" }))
    }

    func testLibraryScanReplenishesSlotsBeforeTheSlowDirectoryFinishes() async throws {
        let reachedLaterDirectory = expectation(description: "Later directory starts before slow listing ends")
        let connector = PipelineCloudConnector(mode: .slowFirst, ready: reachedLaterDirectory)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let scan = Task {
            var last: ConnectorScanner.ScanUpdate?
            for try await update in await scanner.scan(directories: ["/"]) { last = update }
            return last
        }
        await fulfillment(of: [reachedLaterDirectory], timeout: 5)
        await connector.release()
        let last = try await scan.value
        XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        let listed = await connector.listed
        XCTAssertEqual(listed.count, 7)
        XCTAssertEqual(Set(listed).count, 7)
        let peak = await connector.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testCancellingLibraryScanDrainsAllActiveListings() async throws {
        let ready = expectation(description: "Four cloud listings started")
        let stopped = expectation(description: "All cloud listings stopped")
        let connector = PipelineCloudConnector(mode: .blockChildren, ready: ready, stopped: stopped)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let scan = Task {
            for try await _ in await scanner.scan(directories: ["/"]) {}
        }
        await fulfillment(of: [ready], timeout: 5)
        scan.cancel()
        _ = await scan.result
        await fulfillment(of: [stopped], timeout: 5)
        let listed = await connector.listed
        XCTAssertEqual(listed.count, 5)
    }

    func testQuotaFailureKeepsUnconsumedListingsAndSongsForResume() async throws {
        let connector = PipelineCloudConnector(mode: .rateLimited)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        let song = Song(id: "kept", title: "Kept", fileFormat: .flac,
                        filePath: "/5/kept.flac", sourceID: connector.sourceID)
        var last: ConnectorScanner.ScanUpdate?
        do {
            for try await update in await scanner.scan(directories: ["/"], existingSongs: [song]) {
                last = update
            }
            XCTFail("An exhausted shared quota must stop the directory pipeline")
        } catch let error as HTTPResponseFailure {
            XCTAssertEqual(error.statusCode, 429)
        }
        let checkpoint = try XCTUnwrap(last?.resumeState)
        XCTAssertEqual(Set(checkpoint.pendingDirectories), Set((0..<6).map { "/\($0)" }))
        XCTAssertEqual(last?.songs.map(\.id), [song.id])
        let countBeforeResume = await connector.listed.count
        XCTAssertEqual(countBeforeResume, 5)
        await connector.release()
        for try await update in await scanner.scan(
            directories: ["/"], existingSongs: [song], resumeState: checkpoint
        ) { last = update }
        XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        let listed = await connector.listed
        XCTAssertEqual(Set(listed.dropFirst(countBeforeResume)), Set((0..<6).map { "/\($0)" }))
    }

    func testOrdinaryDirectoryFailureDoesNotCancelOtherListings() async throws {
        let connector = PipelineCloudConnector(mode: .ordinaryFailure)
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        var last: ConnectorScanner.ScanUpdate?
        do {
            for try await update in await scanner.scan(directories: ["/"]) { last = update }
            XCTFail("The failed directory must be reported")
        } catch let error as HTTPResponseFailure { XCTAssertEqual(error.statusCode, 500) }
        XCTAssertEqual(last?.resumeState?.pendingDirectories, ["/2"])
        let listed = await connector.listed
        XCTAssertEqual(Set(listed), Set(["/"] + (0..<6).map { "/\($0)" }))
    }
}

private struct PipelineFileConnector: MusicSourceConnector {
    let recorder: PipelineCloudConnector
    var sourceID: String { recorder.sourceID }
    let directoryListingConcurrency: Int
    init(recorder: PipelineCloudConnector, capacity: Int = 4) {
        self.recorder = recorder
        directoryListingConcurrency = capacity
    }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { try await recorder.listFiles(at: path) }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor PipelineCloudConnector: OAuthCloudSource {
    enum Mode { case normal, slowFirst, blockChildren, rateLimited, ordinaryFailure }
    nonisolated let sourceID = "pipeline-" + UUID().uuidString
    private var mode: Mode
    private let ready: XCTestExpectation?
    private let stopped: XCTestExpectation?
    private let gate = AsyncStream<Void>.makeStream()
    private var active = 0
    private var childStarts = 0
    private(set) var listed: [String] = []
    private(set) var peak = 0

    init(mode: Mode, ready: XCTestExpectation? = nil, stopped: XCTestExpectation? = nil) {
        self.mode = mode
        self.ready = ready
        self.stopped = stopped
    }

    func release() {
        mode = .normal
        gate.continuation.finish()
    }
    func connect() async throws {}
    func disconnect() async {}
    func accountIdentifier() async throws -> String { sourceID }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try Task.checkCancellation()
        listed.append(path)
        if path == "/" {
            return (0..<6).map {
                RemoteFileItem(name: "\($0)", path: "/\($0)", isDirectory: true, size: 0, modifiedDate: nil)
            }
        }
        active += 1
        childStarts += 1
        peak = max(peak, active)
        defer {
            active -= 1
            if active == 0, childStarts >= 4 { stopped?.fulfill() }
        }
        if mode == .slowFirst, path == "/4" { ready?.fulfill() }
        if mode == .blockChildren, childStarts == 4 { ready?.fulfill() }
        if mode == .rateLimited, childStarts == 4 { throw HTTPResponseFailure(statusCode: 429) }
        if mode == .ordinaryFailure, path == "/2" { throw HTTPResponseFailure(statusCode: 500) }
        if mode == .blockChildren || mode == .rateLimited || mode == .slowFirst && path == "/0" {
            for await _ in gate.stream {}
            try Task.checkCancellation()
        }
        return []
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor SlowCuePipelineConnector: MusicSourceConnector {
    nonisolated let sourceID = "slow-cue-" + UUID().uuidString
    nonisolated let directoryListingConcurrency = 4
    let childrenStarted: XCTestExpectation
    let cueStarted: XCTestExpectation
    let gate = AsyncStream<Void>.makeStream()
    private(set) var listed: [String] = []
    private(set) var peak = 0
    private var active = 0
    private var children = 0
    init(childrenStarted: XCTestExpectation, cueStarted: XCTestExpectation) {
        self.childrenStarted = childrenStarted
        self.cueStarted = cueStarted
    }
    func connect() async throws {}
    func disconnect() async {}
    func releaseCue() { gate.continuation.finish() }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listed.append(path)
        if path == "/" {
            return (0..<8).map { RemoteFileItem(name: "\($0)", path: "/\($0)", isDirectory: true, size: 0, modifiedDate: nil) }
                + [RemoteFileItem(name: "slow.cue", path: "/slow.cue", isDirectory: false, size: 10, modifiedDate: nil)]
        }
        active += 1
        peak = max(peak, active)
        children += 1
        if children == 4 { childrenStarted.fulfill() }
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return [RemoteFileItem(name: "song.flac", path: path + "/song.flac", isDirectory: false, size: 100, modifiedDate: nil)]
    }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        cueStarted.fulfill()
        for await _ in gate.stream {}
        try Task.checkCancellation()
        return Data()
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

final class ObservedChildPathIndexTests: XCTestCase {
    func testNestedPathsRetainCaseAndCannotCrossSiblingBoundaries() throws {
        let index = try ConnectorScanner.ObservedChildPathIndex(paths: [
            " /Music/Artist/Album/song.flac ", "/music/Artist/Other/song.mp3",
            "/Musicology/wrong.mp3", "/音乐/歌手/专辑/曲目.flac", "/Music/.hidden/file.mp3"
        ])
        XCTAssertEqual(index.childPaths(in: "/MUSIC/"), ["/MUSIC/Artist", "/MUSIC/.hidden"])
        XCTAssertEqual(index.childPaths(in: "/music/artist"), ["/music/artist/Album", "/music/artist/Other"])
        XCTAssertEqual(index.childPaths(in: "/音乐"), ["/音乐/歌手"])
        XCTAssertTrue(index.childPaths(in: "/Mus").isEmpty)
        XCTAssertTrue(index.childPaths(in: "/Music/Artist/Album/song.flac").isEmpty)
    }

    func testLargeLibraryBuildsOneIndexForAllDirectories() throws {
        let paths = (0..<32_032).map { "/Music/Artist\($0 / 500)/Album\($0 / 50)/Track\($0).m4a" }
        let started = Date()
        let index = try ConnectorScanner.ObservedChildPathIndex(paths: paths)
        let built = Date().timeIntervalSince(started)
        var observed = Set<String>()
        let queried = Date()
        for album in 0...640 {
            observed.formUnion(index.childPaths(in: "/Music/Artist\(album / 10)/Album\(album)"))
        }
        XCTAssertEqual(observed, Set(paths))
        print("SCAN_INDEX_32032 build=\(built)s lookup641=\(Date().timeIntervalSince(queried))s")
    }

    func testCancelledIndexBuildStopsBeforeListing() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ConnectorScanner.ObservedChildPathIndex(paths: ["/Music/a.mp3"])
        }
        do { _ = try await task.value; XCTFail("Cancelled scans must not build or list") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
