// Appended to the production session by smoke-test-scan-continuation.sh.
import Foundation

@MainActor
private class BGTask {
    let identifier: String
    var expirationHandler: (@Sendable () -> Void)?
    var completions: [Bool] = []

    init(identifier: String) { self.identifier = identifier }
    func setTaskCompleted(success: Bool) { completions.append(success) }
}

@MainActor
private final class BGContinuedProcessingTask: BGTask {
    let progress = Progress(totalUnitCount: 0)
    func updateTitle(_ title: String, subtitle: String) {}
}

private final class BGContinuedProcessingTaskRequest {
    enum Strategy { case fail }
    let identifier: String
    let title: String
    let subtitle: String
    var strategy: Strategy = .fail

    init(identifier: String, title: String, subtitle: String) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
    }
}

@MainActor
private final class BGTaskScheduler {
    static let shared = BGTaskScheduler()
    var handlers: [String: (BGTask) -> Void] = [:]
    var cancellations: [String] = []
    var rejectsSubmission = false
    var rejectsRegistration = false

    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool {
        guard !rejectsRegistration else { return false }
        precondition(handlers[identifier] == nil, "Duplicate registration")
        handlers[identifier] = launchHandler
        return true
    }

    func submit(_ request: BGContinuedProcessingTaskRequest) throws {
        if rejectsSubmission { throw CocoaError(.userCancelled) }
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancellations.append(identifier)
    }

    func grant(_ identifier: String) -> BGContinuedProcessingTask {
        let task = BGContinuedProcessingTask(identifier: identifier)
        handlers[identifier]!(task)
        return task
    }
}

private func plog(_ message: String) {}

@main
private struct ScanContinuationSmoke {
    @MainActor private static var assertions = 0
    @MainActor private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        if !value {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    @MainActor private static func session(
        scanned: Int = 3,
        total: Int = 10,
        timeout: Duration = .seconds(5),
        started: @escaping () -> Void = {},
        expired: @escaping () -> Void = {}
    ) -> ScanContinuedProcessingSession {
        ScanContinuedProcessingSession(
            identifier: UUID(), sourceName: "Navidrome", scannedCount: scanned,
            totalCount: total, started: started, expired: expired, progressTimeout: timeout
        )
    }

    @MainActor private static func id(_ session: ScanContinuedProcessingSession) -> String {
        "com.welape.yuanyin.source-scan.\(session.identifier.uuidString)"
    }

    @MainActor static func main() async throws {
        let scheduler = BGTaskScheduler.shared

        let failed = session()
        check(failed.submit(), "Failed to submit scan")
        let failedTask = scheduler.grant(id(failed))
        let queuedExpiration = failedTask.expirationHandler
        failed.finish(scanCompleted: false)
        check(failedTask.completions == [true], "Scan failure must release the system UI normally")
        check(failedTask.progress.completedUnitCount == 3, "Failure must not fill scan progress")
        check(!failed.isGranted && failedTask.expirationHandler == nil, "Failed session must release execution")

        let retry = session()
        check(retry.submit(), "Retry must be accepted")
        let retryTask = scheduler.grant(id(retry))
        queuedExpiration?()
        try await Task.sleep(for: .milliseconds(30))
        check(retry.isGranted && retryTask.completions.isEmpty, "Old callback must not finish the retry")
        retry.finish(scanCompleted: true)
        check(id(failed) != id(retry), "Retries need unique system identifiers")
        check(retryTask.completions == [true], "Retry must finish normally")
        check(retryTask.progress.isFinished, "Successful scan must finish progress")

        var lateStarts = 0
        let cancelled = session(started: { lateStarts += 1 })
        check(cancelled.submit(), "Pending scan must submit")
        cancelled.finish(scanCompleted: false)
        check(scheduler.cancellations == [id(cancelled)], "Cancel only this pending request")
        let lateTask = scheduler.grant(id(cancelled))
        check(lateTask.completions == [true] && lateStarts == 0, "Late grant must not revive a cancelled scan")

        var released: ScanContinuedProcessingSession? = session()
        let releasedID = id(released!)
        check(released!.submit(), "Released session must submit")
        released = nil
        check(scheduler.grant(releasedID).completions == [true], "Orphan grant must not create a failure card")

        var expirations = 0
        let expiring = session(expired: { expirations += 1 })
        check(expiring.submit(), "Expiring scan must submit")
        let expiredTask = scheduler.grant(id(expiring))
        expiredTask.expirationHandler?()
        try await Task.sleep(for: .milliseconds(30))
        expiring.finish(scanCompleted: true)
        check(expirations == 1 && expiredTask.completions == [true], "Expiration must finish exactly once")
        check(expiredTask.progress.completedUnitCount == 3, "Expiration must preserve incomplete progress")

        var stalled = 0
        let idle = session(timeout: .milliseconds(180), expired: { stalled += 1 })
        check(idle.submit(), "Stalled scan must submit")
        let idleTask = scheduler.grant(id(idle))
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            idle.update(scannedCount: 3, totalCount: 10)
        }
        check(stalled == 1 && idleTask.completions == [true], "Unchanged updates must not keep a stalled task alive")
        check(idleTask.progress.completedUnitCount == 3, "Watchdog must not fake progress")

        var unknownStalls = 0
        let unknown = session(total: 0, timeout: .milliseconds(180), expired: { unknownStalls += 1 })
        check(unknown.submit(), "Unknown-total scan must submit")
        let unknownTask = scheduler.grant(id(unknown))
        unknown.update(scannedCount: 100, totalCount: 0)
        try await Task.sleep(for: .milliseconds(300))
        check(unknownStalls == 1 && unknownTask.completions == [true], "Indeterminate progress must not evade the watchdog")

        var progressingExpirations = 0
        let progressing = session(timeout: .milliseconds(1600), expired: { progressingExpirations += 1 })
        check(progressing.submit(), "Progressing scan must submit")
        let progressingTask = scheduler.grant(id(progressing))
        try await Task.sleep(for: .milliseconds(1100))
        progressing.update(scannedCount: 4, totalCount: 10)
        try await Task.sleep(for: .milliseconds(700))
        check(progressing.isGranted && progressingExpirations == 0, "Published progress must renew the watchdog")
        progressing.finish(scanCompleted: true)
        try await Task.sleep(for: .milliseconds(1000))
        check(progressingExpirations == 0 && progressingTask.completions == [true], "Finishing must cancel the watchdog")

        scheduler.rejectsSubmission = true
        let rejected = session()
        check(!rejected.submit() && !rejected.isGranted, "Rejected requests must fall back to ordinary scanning")
        check(scheduler.grant(id(rejected)).completions == [true], "Late rejected grant must finish normally")
        scheduler.rejectsSubmission = false
        scheduler.rejectsRegistration = true
        check(!session().submit(), "Registration failure must preserve fallback")

        check(!ScanContinuedProcessingPolicy.cancelsScanOnExpiration(isApplicationActive: true),
              "Foreground scanning must continue after releasing the system task")
        check(ScanContinuedProcessingPolicy.cancelsScanOnExpiration(isApplicationActive: false),
              "Background scanning must pause through the checkpoint callback")
        print("Scan continuation: \(assertions) assertions passed")
    }
}
