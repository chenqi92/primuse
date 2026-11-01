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
        expired: @escaping (ScanContinuedProcessingPolicy.Interruption) -> Void = { _ in }
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
        check(failedTask.progress.isFinished, "Released system session must finish its progress")
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
        check(lateTask.progress.isFinished, "Late grant must not leave unfinished system progress")

        var released: ScanContinuedProcessingSession? = session()
        let releasedID = id(released!)
        check(released!.submit(), "Released session must submit")
        released = nil
        check(scheduler.grant(releasedID).completions == [true], "Orphan grant must not create a failure card")

        var expirations = 0
        let expiring = session(expired: { reason in
            check(reason == .systemExpiration, "System cancellation must be distinguished from a stall")
            expirations += 1
        })
        check(expiring.submit(), "Expiring scan must submit")
        let expiredTask = scheduler.grant(id(expiring))
        expiredTask.expirationHandler?()
        try await Task.sleep(for: .milliseconds(30))
        expiring.finish(scanCompleted: true)
        check(expirations == 1 && expiredTask.completions == [true], "Expiration must finish exactly once")
        check(expiredTask.progress.isFinished, "Expiration must finish the system session")

        var stalled = 0
        let idle = session(timeout: .milliseconds(180), expired: { reason in
            check(reason == .stalled, "Watchdog must report a stall")
            stalled += 1
        })
        check(idle.submit(), "Stalled scan must submit")
        let idleTask = scheduler.grant(id(idle))
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            idle.update(scannedCount: 3, totalCount: 10)
        }
        check(stalled == 1 && idleTask.completions == [true], "Unchanged updates must not keep a stalled task alive")
        check(idleTask.progress.isFinished, "Watchdog must close the system progress")

        var unknownStalls = 0
        let unknown = session(total: 0, timeout: .milliseconds(180), expired: { _ in unknownStalls += 1 })
        check(unknown.submit(), "Unknown-total scan must submit")
        let unknownTask = scheduler.grant(id(unknown))
        unknown.update(scannedCount: 100, totalCount: 0)
        try await Task.sleep(for: .milliseconds(300))
        check(unknownStalls == 1 && unknownTask.completions == [true], "Indeterminate progress must not evade the watchdog")

        var progressingExpirations = 0
        let progressing = session(timeout: .milliseconds(1600), expired: { _ in progressingExpirations += 1 })
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
        scheduler.rejectsRegistration = false

        var unknownProgressExpirations = 0
        let unknownProgress = session(total: 0, timeout: .milliseconds(180), expired: { _ in unknownProgressExpirations += 1 })
        check(unknownProgress.submit(), "Unknown-total progress must submit")
        let unknownProgressTask = scheduler.grant(id(unknownProgress))
        for count in 4...9 {
            try await Task.sleep(for: .milliseconds(60))
            unknownProgress.update(scannedCount: count, totalCount: 0)
        }
        check(unknownProgress.isGranted && unknownProgressExpirations == 0,
              "Real discovered rows must keep indeterminate scanning alive")
        check(unknownProgressTask.progress.totalUnitCount == 0,
              "Unknown-total scans must not invent a total while running")
        unknownProgress.finish(scanCompleted: false)
        check(unknownProgressTask.progress.isFinished, "Unknown-total cancellation must close progress")

        check(ScanContinuedProcessingPolicy.Interruption.systemExpiration.pausesScan(isApplicationActive: true),
              "System UI cancellation must stop foreground scanning")
        check(!ScanContinuedProcessingPolicy.Interruption.stalled.pausesScan(isApplicationActive: true),
              "Foreground scanning can continue without a stalled system session")
        check(ScanContinuedProcessingPolicy.Interruption.stalled.pausesScan(isApplicationActive: false),
              "Background stalls must pause through the checkpoint callback")
        print("Scan continuation: \(assertions) assertions passed")
    }
}
