import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class LifecycleRegressionTests: XCTestCase {
    #if os(iOS)
    @MainActor
    func testBackgroundPlaybackPreservesPendingSceneSettlement() async {
        let coordinator = BackgroundLibraryMaintenanceCoordinator(isApplicationInBackground: { true })
        let settled = expectation(description: "Background publications and persistence are released")
        coordinator.scheduleSceneSettle(after: .milliseconds(20)) {
            settled.fulfill()
        }

        coordinator.cancelMaintenance()

        await fulfillment(of: [settled], timeout: 1)
        coordinator.cancel()
    }

    @MainActor
    func testReturningToForegroundCancelsPendingSceneSettlement() async throws {
        let coordinator = BackgroundLibraryMaintenanceCoordinator(isApplicationInBackground: { true })
        var settlementCount = 0
        coordinator.scheduleSceneSettle(after: .milliseconds(20)) {
            settlementCount += 1
        }

        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(settlementCount, 0)
    }

    @MainActor
    func testSceneSettlementRechecksCurrentApplicationState() async throws {
        var isBackground = true
        let coordinator = BackgroundLibraryMaintenanceCoordinator(isApplicationInBackground: { isBackground })
        var settlementCount = 0
        coordinator.scheduleSceneSettle(after: .milliseconds(20)) {
            settlementCount += 1
        }

        isBackground = false
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(settlementCount, 0)
        coordinator.cancel()
    }
    #endif

    @MainActor
    func testSceneTransitionGateReopensWhenReturningToForeground() {
        let scraper = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [] }))
        let library = MusicLibrary(storageDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLifecycleTests-\(UUID().uuidString)", isDirectory: true))

        XCTAssertFalse(scraper.isGatedForSceneTransition)
        // A cold launch never saw a transition, so nothing may be resumed.
        scraper.resumeAfterSceneTransition(in: library)
        XCTAssertFalse(scraper.isGatedForSceneTransition)

        scraper.pauseForSceneTransition()
        XCTAssertTrue(scraper.isGatedForSceneTransition)
        scraper.pauseForSceneTransition()
        XCTAssertTrue(scraper.isGatedForSceneTransition)

        scraper.resumeAfterSceneTransition(in: library)
        XCTAssertFalse(scraper.isGatedForSceneTransition)
        XCTAssertFalse(scraper.isScraping)
    }

    @MainActor
    func testInvalidRangeResponseIsRetriedWithoutEndpointProbe() {
        let error = MetadataRangeReadError.invalidRangeResponse
        XCTAssertTrue(MetadataBackfillService.isTransientBackfillError(error))
        XCTAssertFalse(MetadataBackfillService.isSourceUnavailableBackfillError(error))
        XCTAssertFalse(MetadataBackfillService.needsSourceEndpointProbe(error))
        // A plain connection failure still asks the endpoint before parking a source.
        XCTAssertTrue(MetadataBackfillService.needsSourceEndpointProbe(SourceError.connectionFailed("offline")))
        XCTAssertFalse(MetadataRangeReadError.invalidRangeResponse.localizedDescription.isEmpty)
    }

    func testCancellingCacheWaiterReturnsWithoutCancellingSharedTransfer() async {
        let gate = AsyncStream<Void>.makeStream()
        let transfer = Task {
            for await _ in gate.stream { break }
        }
        let cancelledWaiterReturned = expectation(description: "Cancelled requester returns before transfer finishes")
        let cancelledWaiter = Task {
            await BackgroundAudioCacheTaskWaiter.wait(for: transfer)
            cancelledWaiterReturned.fulfill()
        }
        let remainingWaiter = Task {
            await BackgroundAudioCacheTaskWaiter.wait(for: transfer)
        }

        await Task.yield()
        cancelledWaiter.cancel()
        await fulfillment(of: [cancelledWaiterReturned], timeout: 1)
        XCTAssertFalse(transfer.isCancelled)
        XCTAssertFalse(remainingWaiter.isCancelled)

        gate.continuation.finish()
        await remainingWaiter.value
        await cancelledWaiter.value
    }

    func testAlreadyCancelledCacheWaiterDoesNotCancelSharedTransfer() async {
        let gate = AsyncStream<Void>.makeStream()
        let transfer = Task {
            for await _ in gate.stream { break }
        }
        let returned = expectation(description: "Already cancelled requester returns immediately")
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await BackgroundAudioCacheTaskWaiter.wait(for: transfer)
            returned.fulfill()
        }

        await fulfillment(of: [returned], timeout: 1)
        XCTAssertFalse(transfer.isCancelled)
        gate.continuation.finish()
        await transfer.value
        await waiter.value
    }

    // MARK: - BGProcessing drain

    /// T6 — Stage 2: a background wake can arrive while the library is still
    /// being prepared off the main actor. The drain must wait for publication
    /// before it asks anything whether there is work: on an empty preparing
    /// model every probe answers "nothing pending", so the drain would finish
    /// immediately and drop the wake.
    @MainActor
    func testBackgroundDrainWaitsForLibraryReadinessBeforeProbingForWork() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.waitForLibraryReady = { recorder.record("waitForLibraryReady") }
        dependencies.isPlaybackActive = {
            recorder.record("isPlaybackActive")
            return false
        }
        dependencies.isApplicationActive = { false }
        dependencies.setBackgroundPlaybackActive = {
            recorder.record("setBackgroundPlaybackActive(\($0))")
        }
        dependencies.setBackfillMode = { recorder.backfillModes.append($0) }
        dependencies.prepareNonPlaybackWork = { recorder.record("prepareNonPlaybackWork") }
        dependencies.hasResumableScanWork = {
            recorder.record("hasResumableScanWork")
            return false
        }
        dependencies.startPeriodicQuickSync = { recorder.record("startPeriodicQuickSync") }
        dependencies.waitForScans = { recorder.record("waitForScans") }
        dependencies.hasPendingScrape = {
            recorder.record("hasPendingScrape")
            return false
        }
        dependencies.backfillHasPendingWork = {
            recorder.record("backfillHasPendingWork")
            return false
        }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        await drain.run()

        XCTAssertEqual(recorder.count(of: "waitForLibraryReady"), 1)
        XCTAssertEqual(
            recorder.events.first,
            "waitForLibraryReady",
            "readiness must be awaited before any other dependency runs"
        )
        // 三个"有没有活儿"的判定都必须排在就绪等待之后。
        for probe in ["hasResumableScanWork", "hasPendingScrape", "backfillHasPendingWork"] {
            guard let probeIndex = recorder.events.firstIndex(of: probe) else {
                XCTFail("\(probe) was never evaluated")
                continue
            }
            XCTAssertGreaterThan(probeIndex, 0, "\(probe) ran before the readiness wait")
        }
        XCTAssertEqual(completion.completionResults, [true])
    }

    /// iOS expires the BGProcessing task while scans are still running: the
    /// task must be completed exactly once, the running work cancelled, and a
    /// replacement request submitted exactly once so the remaining work still
    /// gets a later wake.
    @MainActor
    func testBackgroundDrainExpirationDuringScanWaitCancelsWorkAndRenewsRequest() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        let box = BackgroundDrainBox()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.isPlaybackActive = { false }
        dependencies.isApplicationActive = { false }
        dependencies.hasResumableScanWork = { true }
        dependencies.resumeScans = { recorder.record("resumeScans") }
        dependencies.waitForScans = {
            recorder.record("waitForScans")
            box.drain?.expire()
        }
        dependencies.cancelScans = { recorder.record("cancelScans") }
        dependencies.hasPendingScrape = { true }
        dependencies.resumeScrape = { recorder.record("resumeScrape") }
        dependencies.cancelScrape = { recorder.record("cancelScrape") }
        dependencies.backfillHasPendingWork = { true }
        dependencies.startBackfill = { recorder.record("startBackfill") }
        dependencies.expireBackfill = { recorder.record("expireBackfill") }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        box.drain = drain
        await drain.run()
        // `expire()` completes the task synchronously and hands the teardown
        // to the main actor; yielding lets that already-enqueued job run.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(completion.completionResults, [false])
        XCTAssertEqual(recorder.count(of: "cancelScans"), 1)
        XCTAssertEqual(recorder.count(of: "cancelScrape"), 1)
        XCTAssertEqual(recorder.count(of: "expireBackfill"), 1)
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
        // The expired drain must not start any further stage.
        XCTAssertEqual(recorder.count(of: "resumeScrape"), 0)
        XCTAssertEqual(recorder.count(of: "startBackfill"), 0)
    }

    /// An expiration that arrives after the app has returned to the foreground
    /// must not cancel the newer foreground scan, but still has to renew.
    @MainActor
    func testBackgroundDrainExpirationSkipsCancellationWhileApplicationIsActive() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.isApplicationActive = { true }
        dependencies.cancelScans = { recorder.record("cancelScans") }
        dependencies.cancelScrape = { recorder.record("cancelScrape") }
        dependencies.expireBackfill = { recorder.record("expireBackfill") }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        XCTAssertTrue(completion.complete(success: false))
        drain.finishExpiration()

        XCTAssertEqual(recorder.count(of: "cancelScans"), 0)
        XCTAssertEqual(recorder.count(of: "cancelScrape"), 0)
        XCTAssertEqual(recorder.count(of: "expireBackfill"), 1)
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
    }

    /// Scans keep running on the reduced playback profile while audio plays,
    /// so the BGProcessing task is routinely expired mid-scan. That expiration
    /// must not cancel them: the audio session keeps the process alive and the
    /// per-scan assertion is re-acquired once playback stops. Scraping stays
    /// cancelled and the request is still renewed exactly once.
    @MainActor
    func testBackgroundDrainExpirationDuringPlaybackKeepsScansRunning() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        let box = BackgroundDrainBox()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.isPlaybackActive = { true }
        dependencies.isApplicationActive = { false }
        dependencies.hasResumableScanWork = { true }
        dependencies.resumeScans = { recorder.record("resumeScans") }
        dependencies.waitForScans = {
            recorder.record("waitForScans")
            box.drain?.expire()
        }
        dependencies.cancelScans = { recorder.record("cancelScans") }
        dependencies.cancelScrape = { recorder.record("cancelScrape") }
        dependencies.backfillHasPendingWork = { true }
        dependencies.startBackfill = { recorder.record("startBackfill") }
        dependencies.expireBackfill = { recorder.record("expireBackfill") }
        dependencies.setBackgroundPlaybackActive = {
            recorder.record("setBackgroundPlaybackActive(\($0))")
        }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        box.drain = drain
        await drain.run()
        // `expire()` completes the task synchronously and hands the teardown
        // to the main actor; yielding lets that already-enqueued job run.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(completion.completionResults, [false])
        XCTAssertEqual(recorder.count(of: "setBackgroundPlaybackActive(true)"), 1)
        XCTAssertEqual(recorder.count(of: "cancelScans"), 0)
        XCTAssertEqual(recorder.count(of: "cancelScrape"), 1)
        XCTAssertEqual(recorder.count(of: "expireBackfill"), 1)
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
        XCTAssertEqual(recorder.count(of: "startBackfill"), 0)
    }

    /// Nothing pending: the drain still completes once and renews once (the
    /// renewal call cancels the stale request when there is no work left).
    @MainActor
    func testBackgroundDrainWithoutPendingWorkCompletesAndSchedulesOnce() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.hasResumableScanWork = { false }
        dependencies.hasPendingScrape = { false }
        dependencies.backfillHasPendingWork = { false }
        dependencies.resumeScans = { recorder.record("resumeScans") }
        dependencies.resumeScrape = { recorder.record("resumeScrape") }
        dependencies.startBackfill = { recorder.record("startBackfill") }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        await drain.run()

        XCTAssertEqual(completion.completionResults, [true])
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
        XCTAssertEqual(recorder.count(of: "resumeScans"), 0)
        XCTAssertEqual(recorder.count(of: "resumeScrape"), 0)
        XCTAssertEqual(recorder.count(of: "startBackfill"), 0)
    }

    /// Playback can start from the lock screen while the drain waits. The
    /// remaining stages then run on the playback profile: scans continue,
    /// scraping stays postponed.
    @MainActor
    func testBackgroundDrainSwitchesToPlaybackPathWithoutResumingScraping() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        recorder.hasScanWork = true
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.isPlaybackActive = { recorder.playbackIsActive }
        dependencies.hasResumableScanWork = { recorder.hasScanWork }
        dependencies.resumeScans = {
            recorder.record("resumeScans")
            recorder.hasScanWork = false
        }
        dependencies.waitForScans = {
            recorder.record("waitForScans")
            recorder.playbackIsActive = true
        }
        dependencies.hasPendingScrape = { true }
        dependencies.resumeScrape = { recorder.record("resumeScrape") }
        dependencies.backfillHasPendingWork = { true }
        dependencies.startBackfill = { recorder.record("startBackfill") }
        dependencies.setBackfillMode = { recorder.backfillModes.append($0) }
        dependencies.setBackgroundPlaybackActive = { recorder.playbackProfiles.append($0) }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        await drain.run()

        XCTAssertEqual(recorder.count(of: "resumeScrape"), 0)
        XCTAssertEqual(recorder.count(of: "resumeScans"), 1)
        XCTAssertEqual(recorder.count(of: "startBackfill"), 1)
        XCTAssertEqual(recorder.backfillModes, [.background, .backgroundDuringPlayback])
        XCTAssertEqual(recorder.playbackProfiles, [false, true])
        XCTAssertEqual(completion.completionResults, [true])
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
    }

    /// The undisturbed sequence: scans, then scraping, then backfill, then a
    /// single renewal and a single completion.
    @MainActor
    func testBackgroundDrainNormalCompletionRunsEveryStageOnce() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.hasResumableScanWork = { true }
        dependencies.hasPendingScrape = { true }
        dependencies.backfillHasPendingWork = { true }
        dependencies.prepareNonPlaybackWork = { recorder.record("prepare") }
        dependencies.resumeScans = { recorder.record("resumeScans") }
        dependencies.startPeriodicQuickSync = { recorder.record("periodicQuickSync") }
        dependencies.waitForScans = { recorder.record("waitForScans") }
        dependencies.resumeScrape = { recorder.record("resumeScrape") }
        dependencies.waitForScrape = { recorder.record("waitForScrape") }
        dependencies.startBackfill = { recorder.record("startBackfill") }
        dependencies.waitBackfillIdle = { recorder.record("waitBackfillIdle") }
        dependencies.setBackfillMode = { recorder.backfillModes.append($0) }
        dependencies.setBackgroundPlaybackActive = { recorder.playbackProfiles.append($0) }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        await drain.run()

        XCTAssertEqual(recorder.events, [
            "prepare",
            "resumeScans",
            "periodicQuickSync",
            "waitForScans",
            "resumeScrape",
            "waitForScrape",
            "startBackfill",
            "waitBackfillIdle",
            "scheduleNextRequest"
        ])
        XCTAssertEqual(recorder.backfillModes, [.background])
        XCTAssertEqual(recorder.playbackProfiles, [false])
        XCTAssertEqual(completion.completionResults, [true])
    }

    /// A late expiration for a task that already finished changes nothing —
    /// no second completion, no second request, no cancellation.
    @MainActor
    func testBackgroundDrainExpirationAfterNormalCompletionIsANoOp() async {
        let completion = TestBackgroundTaskCompletion()
        let recorder = BackgroundDrainRecorder()
        var dependencies = BackgroundProcessingDrain.Dependencies()
        dependencies.isApplicationActive = { false }
        dependencies.cancelScans = { recorder.record("cancelScans") }
        dependencies.cancelScrape = { recorder.record("cancelScrape") }
        dependencies.expireBackfill = { recorder.record("expireBackfill") }
        dependencies.scheduleNextRequest = { recorder.record("scheduleNextRequest") }

        let drain = BackgroundProcessingDrain(completion: completion, dependencies: dependencies)
        await drain.run()
        drain.expire()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(completion.completionResults, [true])
        XCTAssertEqual(recorder.count(of: "scheduleNextRequest"), 1)
        XCTAssertEqual(recorder.count(of: "cancelScans"), 0)
        XCTAssertEqual(recorder.count(of: "cancelScrape"), 0)
        XCTAssertEqual(recorder.count(of: "expireBackfill"), 0)
    }

    // MARK: - Bounded scanning during background playback

    func testScanExecutionProfileKeepsForegroundCadenceAndBoundsPlayback() {
        XCTAssertEqual(ScanExecutionProfilePolicy.flushBatchSize(for: .standard), 200)
        XCTAssertEqual(ScanExecutionProfilePolicy.flushInterval(for: .standard), 1.5)
        XCTAssertEqual(ScanExecutionProfilePolicy.progressPublishInterval(for: .standard), 0.75)
        XCTAssertEqual(ScanExecutionProfilePolicy.flushBatchSize(for: .backgroundPlayback), 400)
        XCTAssertEqual(ScanExecutionProfilePolicy.flushInterval(for: .backgroundPlayback), 5)
        XCTAssertEqual(ScanExecutionProfilePolicy.progressPublishInterval(for: .backgroundPlayback), 5)
        // Background playback must always commit less often than the foreground.
        XCTAssertGreaterThan(
            ScanExecutionProfilePolicy.flushBatchSize(for: .backgroundPlayback),
            ScanExecutionProfilePolicy.flushBatchSize(for: .standard)
        )
        XCTAssertGreaterThan(
            ScanExecutionProfilePolicy.flushInterval(for: .backgroundPlayback),
            ScanExecutionProfilePolicy.flushInterval(for: .standard)
        )
        XCTAssertGreaterThan(
            ScanExecutionProfilePolicy.progressPublishInterval(for: .backgroundPlayback),
            ScanExecutionProfilePolicy.progressPublishInterval(for: .standard)
        )
    }

    func testScanExecutionProfilePriorityLeavesForegroundUnchanged() {
        XCTAssertEqual(
            ScanExecutionProfilePolicy.taskPriority(for: .standard, context: .userInitiatedForeground),
            .userInitiated
        )
        XCTAssertEqual(
            ScanExecutionProfilePolicy.taskPriority(for: .standard, context: .foregroundResume),
            .utility
        )
        XCTAssertEqual(
            ScanExecutionProfilePolicy.taskPriority(for: .standard, context: .background),
            .utility
        )
        // Audio always outranks scanning while the app runs on playback time.
        XCTAssertEqual(
            ScanExecutionProfilePolicy.taskPriority(for: .backgroundPlayback, context: .background),
            .background
        )
        XCTAssertEqual(
            ScanExecutionProfilePolicy.taskPriority(for: .backgroundPlayback, context: .userInitiatedForeground),
            .background
        )
    }

    // MARK: - Manual/automatic backfill budget ownership

    /// A registered manual batch owns the shared worker budget only while it
    /// can run. Backgrounded, its own limits closure yields zero workers, so
    /// the automatic budget must apply instead of starving both queues.
    func testManualBatchOwnsAutomaticBudgetOnlyWhileApplicationIsActive() {
        XCTAssertTrue(MetadataBackfillService.manualBatchOwnsAutomaticBudget(
            hasRegisteredManualBatch: true, applicationIsActive: true
        ))
        XCTAssertFalse(MetadataBackfillService.manualBatchOwnsAutomaticBudget(
            hasRegisteredManualBatch: true, applicationIsActive: false
        ))
        XCTAssertFalse(MetadataBackfillService.manualBatchOwnsAutomaticBudget(
            hasRegisteredManualBatch: false, applicationIsActive: true
        ))
        XCTAssertFalse(MetadataBackfillService.manualBatchOwnsAutomaticBudget(
            hasRegisteredManualBatch: false, applicationIsActive: false
        ))
    }

    /// A batch that cannot run still keeps the slots its already-dispatched
    /// reads occupy, so the automatic queue only takes what is left over and
    /// the two queues together stay inside the device worker ceiling.
    func testAutomaticWorkerCountSubtractsManualInFlightWhileBatchCannotRun() {
        XCTAssertEqual(MetadataBackfillService.automaticWorkerCount(
            budgetWorkerCount: 4, hasRegisteredManualBatch: true,
            applicationIsActive: true, manualInFlightCount: 2
        ), 0)
        XCTAssertEqual(MetadataBackfillService.automaticWorkerCount(
            budgetWorkerCount: 4, hasRegisteredManualBatch: true,
            applicationIsActive: false, manualInFlightCount: 3
        ), 1)
        XCTAssertEqual(MetadataBackfillService.automaticWorkerCount(
            budgetWorkerCount: 4, hasRegisteredManualBatch: true,
            applicationIsActive: false, manualInFlightCount: 6
        ), 0)
        XCTAssertEqual(MetadataBackfillService.automaticWorkerCount(
            budgetWorkerCount: 4, hasRegisteredManualBatch: false,
            applicationIsActive: false, manualInFlightCount: 3
        ), 4)
    }

    /// Resuming a checkpoint seeds the rows the library is missing, and also
    /// corrects rows whose locating fields drifted. Without the second half a
    /// resumed scan that dies before its first flush leaves stale
    /// filePath/fileSize/revision behind, and every backfill result for those
    /// rows is discarded by `isStillReadable`.
    func testResumeSeedOnlyRewritesRowsWhoseLocatingFieldsDiffer() {
        func makeSong(
            filePath: String = "Music/a.flac",
            fileSize: Int64 = 1024,
            revision: String? = "etag-1"
        ) -> Song {
            Song(
                id: "song-1",
                title: "A",
                duration: 0,
                fileFormat: .flac,
                filePath: filePath,
                sourceID: "source-1",
                fileSize: fileSize,
                revision: revision
            )
        }

        let checkpointRow = makeSong()
        XCTAssertFalse(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: makeSong()
        ))
        // 同一份元数据只是别的字段(标题/时长)不同时不必重写: 那些仍由首次
        // 增量 flush 提交。
        var enrichedRow = makeSong()
        enrichedRow.title = "A (backfilled)"
        enrichedRow.duration = 212
        XCTAssertFalse(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: enrichedRow
        ))
        XCTAssertTrue(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: makeSong(filePath: "Music/moved/a.flac")
        ))
        XCTAssertTrue(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: makeSong(fileSize: 2048)
        ))
        XCTAssertTrue(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: makeSong(revision: "etag-0")
        ))
        XCTAssertTrue(ScanService.resumeSeedNeedsUpdate(
            checkpointRow: checkpointRow,
            libraryRow: makeSong(revision: nil)
        ))
    }

    // MARK: - Stage 2b: 准备中的资料库不许触发不可逆动作

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLifecycleReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 续刮的"清检查点"判定。库还在 `.preparing` 时 `visibleSongs` 是空的,
    /// 检查点里的歌一首都匹配不上 —— 那是假象。这时清掉检查点会把上一轮批量
    /// 刮削的进度永久丢掉: 没有人会恢复它, 下次启动连 `scrapePending` 都不再
    /// 提交。判定抽成纯函数正是为了在这里盯住它。
    func testScrapeCheckpointIsNeverClearedWhileTheLibraryIsPreparing() {
        XCTAssertFalse(ScrapeResumePolicy.clearsCheckpoint(
            libraryIsReady: false,
            matchedSongs: 0
        ))
        XCTAssertFalse(ScrapeResumePolicy.clearsCheckpoint(
            libraryIsReady: false,
            matchedSongs: 7
        ))
        // 已发布的库上行为与历史版本一致: 一首都没落回库里才清。
        XCTAssertTrue(ScrapeResumePolicy.clearsCheckpoint(
            libraryIsReady: true,
            matchedSongs: 0
        ))
        XCTAssertFalse(ScrapeResumePolicy.clearsCheckpoint(
            libraryIsReady: true,
            matchedSongs: 1
        ))
    }

    /// 歌词纯文本 backfill 的 done-key 是一次性的: 在准备中的空库上跑一遍会把
    /// 迁移永久标记成完成, 那些真正该解析的 .lrc 从此再也进不了 FTS 索引。
    /// 服务没有注入点(done-key 直接读 `UserDefaults.standard`), 所以这里存下
    /// 原值、跑完再恢复。
    @MainActor
    func testLyricsTextBackfillLeavesTheMigrationKeyUnsetWhileTheLibraryIsPreparing() throws {
        // 与 `LyricsTextBackfillService.migrationKey` 保持一致(私有常量)。
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

        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let service = LyricsTextBackfillService(library: library)
        service.startIfNeeded()

        XCTAssertFalse(library.isReady)
        XCTAssertFalse(service.isRunning, "准备中的库上不许起 worker")
        XCTAssertFalse(
            defaults.bool(forKey: migrationKey),
            "空的准备态资料库不许把歌词迁移标记成完成"
        )
    }

    /// 后台唤醒的网络判定会强制对账待办队列。走一遍准备中的空库就会把
    /// "0 条待办" 定下来(`needsRefresh: false` 落进 backfill-queue-state.json),
    /// 而后台唤醒起来的进程里没有 SwiftUI 场景, 没有人会把队列重新标脏 ——
    /// 待办回填就此停摆到下一次前台启动。构造时的 `readingConfigurationChanged`
    /// 走的是同一条对账路径, 所以两处都要保持脏。
    @MainActor
    func testBackgroundWakeDecisionKeepsTheBackfillQueueDirtyWhileTheLibraryIsPreparing() throws {
        // 与 `MetadataBackfillService.queueDirtyDefaultsKey` 保持一致(私有常量)。
        // 置真是为了让判定与磁盘上残留的队列状态无关。
        let dirtyKey = "primuse.metadataBackfill.queueDirty.v1"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: dirtyKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: dirtyKey)
            } else {
                defaults.removeObject(forKey: dirtyKey)
            }
        }
        defaults.set(true, forKey: dirtyKey)

        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let backfill = MetadataBackfillService(
            library: library,
            sourceManager: SourceManager(sourcesProvider: { [MusicSource]() }),
            backfillableSourceIDs: { ["source-1"] }
        )

        XCTAssertFalse(library.isReady)
        XCTAssertTrue(
            backfill.hasPendingWork,
            "构造时的对账不许在准备中的库上把队列算成干净的"
        )
        _ = backfill.backgroundWakeRequiresNetworkConnectivity
        XCTAssertTrue(
            backfill.hasPendingWork,
            "后台唤醒判定不许在准备中的库上把队列对账并落盘成干净的"
        )
    }

    /// 滚动卡顿: 每 5 秒一次的状态对账会推进 `statusRevision`, 而歌曲行以前
    /// 通过 `isDeferredRetry` 订阅了它 —— 于是每次 flush 都让所有可见行重新
    /// 求值 body。行现在只订阅延迟重试集合自己的版本号, 一次没有改变成员
    /// 关系的对账必须让它保持不动。
    @MainActor
    func testStatusReconciliationDoesNotDisturbTheDeferredRetryRevision() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let backfill = MetadataBackfillService(
            library: library,
            sourceManager: SourceManager(sourcesProvider: { [MusicSource]() }),
            backfillableSourceIDs: { ["source-1"] }
        )

        XCTAssertTrue(library.isReady)
        let deferredRevision = backfill.deferredRetryRevision

        // 1) 什么都没变的一轮对账。
        backfill.refreshStatusSnapshot()
        let statusRevisionAfterIdleFlush = backfill.statusRevision
        XCTAssertEqual(backfill.deferredRetryRevision, deferredRevision)

        // 2) 状态确实变了的一轮: 一首待读取详情的歌进了库。
        library.addSongs([
            Song(
                id: "deferred-revision-fixture",
                title: "Fixture",
                duration: 0,
                fileFormat: .flac,
                filePath: "/tmp/fixture.flac",
                sourceID: "source-1"
            )
        ])
        backfill.refreshStatusSnapshot()

        XCTAssertNotEqual(
            backfill.statusRevision,
            statusRevisionAfterIdleFlush,
            "状态快照确实变了, 否则下面的断言没有意义"
        )
        XCTAssertEqual(
            backfill.deferredRetryRevision,
            deferredRevision,
            "延迟重试集合的成员关系没变, 行订阅的版本号就不许前进"
        )
        XCTAssertFalse(backfill.isDeferredRetry(songID: "deferred-revision-fixture"))
    }

    /// 会话快照现在是后台写盘的。写失败时绝对不能把生命周期推进到
    /// `completed`: 那会让随后的空状态发布获准删掉上一次启动留下的、仍然
    /// 有效的快照, 而新的快照从来没有真正落过盘。
    @MainActor
    func testFailedSessionWriteDoesNotUnlockClearingThePreviousSnapshot() throws {
        let containerName = "PrimuseSessionPromotion-\(UUID().uuidString)"
        // 同一个位置的文件形式与目录形式: store 需要目录形式, 占位文件需要
        // 文件形式(带尾斜杠的 URL 无法写入普通文件)。
        let containerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(containerName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(containerName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: containerFile) }
        // 用一个普通文件占住容器目录的位置, 让写盘像磁盘满/只读那样失败。
        try Data().write(to: containerFile)

        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)
        var lifecycle = PlaybackSessionRestoreLifecycle()
        lifecycle.supersedeForPlaybackIntent()
        XCTAssertFalse(lifecycle.permitsEmptySessionClear)

        coordinator.enqueue(.save(Self.makeSessionSnapshot(currentTime: 12)), generation: 1)
        let failedOutcome = coordinator.drain()
        XCTAssertNotNil(failedOutcome.failureDescription)
        XCTAssertFalse(failedOutcome.persisted(generation: 1))
        if failedOutcome.persisted(generation: 1) {
            lifecycle.didPersistCurrentSession()
        }
        XCTAssertFalse(
            lifecycle.permitsEmptySessionClear,
            "写盘失败之后仍然只有旧快照是持久的, 空状态不许清空它"
        )

        // 磁盘恢复可写之后, 同一条通道写成功才解锁清空。
        try FileManager.default.removeItem(at: containerFile)
        coordinator.enqueue(.save(Self.makeSessionSnapshot(currentTime: 34)), generation: 2)
        let successfulOutcome = coordinator.drain()
        XCTAssertNil(successfulOutcome.failureDescription)
        XCTAssertTrue(successfulOutcome.persisted(generation: 2))
        if successfulOutcome.persisted(generation: 2) {
            lifecycle.didPersistCurrentSession()
        }
        XCTAssertTrue(lifecycle.permitsEmptySessionClear)
        let restored = try store.load()
        XCTAssertEqual(restored?.currentTime, 34)
    }

    private static func makeSessionSnapshot(currentTime: TimeInterval) -> PlaybackSessionSnapshot {
        PlaybackSessionSnapshot(
            queueSongIDs: ["a", "b"],
            currentSongID: "a",
            currentIndex: 0,
            currentTime: currentTime,
            duration: 180,
            wasPlaying: true,
            shuffleEnabled: false,
            shuffledIndices: [],
            shufflePosition: 0,
            repeatMode: .off,
            isAtTrackEnd: false
        )
    }
}

/// Records the drain's injected calls in order. `@MainActor` makes it usable
/// from the drain's main-actor `@Sendable` dependency closures.
@MainActor
private final class BackgroundDrainRecorder {
    private(set) var events: [String] = []
    var backfillModes: [MetadataBackfillExecutionMode] = []
    var playbackProfiles: [Bool] = []
    var playbackIsActive = false
    var hasScanWork = false

    func record(_ event: String) {
        events.append(event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

/// Lets a dependency closure reach the drain that owns it, so a test can
/// expire the task from inside one of its awaits.
@MainActor
private final class BackgroundDrainBox {
    var drain: BackgroundProcessingDrain?
}

/// Stand-in for the `BGTask`-backed completion, recording every accepted
/// completion so "exactly once" can be asserted.
private final class TestBackgroundTaskCompletion: BackgroundTaskCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCompletions: [Bool] = []

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !recordedCompletions.isEmpty
    }

    var completionResults: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCompletions
    }

    @discardableResult
    func complete(success: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recordedCompletions.isEmpty else { return false }
        recordedCompletions.append(success)
        return true
    }
}
