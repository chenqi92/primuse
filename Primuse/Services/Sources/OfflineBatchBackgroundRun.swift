import Foundation
import PrimuseKit
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// 一轮手动批量离线下载(整源「缓存」、歌单/专辑/多选「下载」)在用户离开 App 之后
/// 还能接着跑的那段时间。
///
/// iOS 上不放歌时离开 App 几秒就被挂起, 几百首无损要一直亮着屏、开着 App 才下得完
/// (#321)。iOS 26 起向系统申请一段 continued processing 时间: 锁屏、切到别的 App 时
/// 照常下载, 系统给一张能看进度、能停止的卡片。系统不给或更早的系统上, 至少拿一条
/// UIKit 断言把手头那一块写完; 断言到期只放开它、不取消下载, 回到前台接着下。
/// macOS 不会挂起 App, 只防 App Nap 把窗口不在前面时的下载节流。
@MainActor
final class OfflineBatchBackgroundRun {
    private let title: String
    private let totalCount: Int
    private var handledCount = 0
    private var ended = false
    private var onExpiredInBackground: (@MainActor () -> Void)?
    #if os(iOS)
    private var assertionID: UIBackgroundTaskIdentifier = .invalid
    #if !targetEnvironment(macCatalyst)
    private var continuedSession: (any OfflineBatchContinuation)?
    #endif
    #elseif os(macOS)
    private var activity: (any NSObjectProtocol)?
    #endif

    init(title: String, totalCount: Int) {
        self.title = title
        self.totalCount = max(0, totalCount)
    }

    /// 批量开始时在前台调用。
    /// - Parameter onExpiredInBackground: 系统收回时间(或用户在系统卡片上点了停止)而
    ///   App 不在前台时调用, 调用方按用户停止处理这一批。
    func begin(onExpiredInBackground: @escaping @MainActor () -> Void) {
        guard !ended else { return }
        self.onExpiredInBackground = onExpiredInBackground
        #if os(iOS)
        guard OfflineBatchBackgroundRunPolicy.requestsSystemTask(
            songCount: totalCount,
            isApplicationActive: UIApplication.shared.applicationState == .active
        ) else { return }
        beginAssertion()
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let session = OfflineBatchContinuedProcessingSession(
                title: title,
                totalCount: totalCount,
                started: { [weak self] in
                    // 时间已经由系统给出, 那条 ~30 秒的断言用不上了。
                    self?.endAssertion()
                },
                expired: { [weak self] isApplicationActive in
                    guard let self else { return }
                    self.continuedSession = nil
                    guard OfflineBatchBackgroundRunPolicy.cancelsBatchOnExpiration(
                        isApplicationActive: isApplicationActive
                    ) else { return }
                    self.onExpiredInBackground?()
                }
            )
            continuedSession = session
            if !session.submit() { continuedSession = nil }
        }
        #endif
        #elseif os(macOS)
        guard totalCount >= 2 else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Downloading songs for offline playback"
        )
        #endif
    }

    /// 一首下完或放弃了。
    func recordSongFinished() {
        guard !ended else { return }
        handledCount += 1
        #if os(iOS) && !targetEnvironment(macCatalyst)
        continuedSession?.update(handledCount: handledCount)
        #endif
    }

    func end(success: Bool) {
        guard !ended else { return }
        ended = true
        onExpiredInBackground = nil
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        continuedSession?.finish(success: success)
        continuedSession = nil
        #endif
        endAssertion()
        #elseif os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }

    #if os(iOS)
    private func beginAssertion() {
        guard assertionID == .invalid else { return }
        assertionID = UIApplication.shared.beginBackgroundTask(withName: "offline-download") { [weak self] in
            // UIKit 在主线程上调。到期只放开断言: 取消会把在途的那一块也丢掉,
            // 挂起后再回到前台, 下载会自己从断点接着下。
            MainActor.assumeIsolated {
                plog("⬇️ Offline batch background assertion expired")
                self?.endAssertion()
            }
        }
    }

    private func endAssertion() {
        guard assertionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertionID)
        assertionID = .invalid
    }
    #endif
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// `BGContinuedProcessingTask` 只在 iOS 26+ 存在, `OfflineBatchBackgroundRun` 依赖这个
/// 协议而不是具体类型。
@MainActor
private protocol OfflineBatchContinuation: AnyObject {
    func update(handledCount: Int)
    func finish(success: Bool)
}

@available(iOS 26.0, *)
@MainActor
private final class OfflineBatchContinuedProcessingSession: OfflineBatchContinuation {
    private let identifier = UUID()
    private let title: String
    private let totalCount: Int
    private var handledCount = 0
    private var task: BGContinuedProcessingTask?
    private var finished = false
    private var lastProgressPublishedAt = Date.distantPast
    private let started: () -> Void
    private let expired: (_ isApplicationActive: Bool) -> Void
    private var taskIdentifier: String { "com.welape.yuanyin.offline-download.\(identifier.uuidString)" }

    init(
        title: String,
        totalCount: Int,
        started: @escaping () -> Void,
        expired: @escaping (_ isApplicationActive: Bool) -> Void
    ) {
        self.title = title
        self.totalCount = totalCount
        self.started = started
        self.expired = expired
    }

    func submit() -> Bool {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, !self.finished,
                      let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.task = task
                plog("⬇️ Offline batch: continued task granted id=\(self.identifier)")
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.finished else { return }
                        // 前台时下载照常继续, 卡片报失败会和应用里还在走的进度对不上。
                        let isActive = UIApplication.shared.applicationState == .active
                        plog("⬇️ Offline batch: continued task expired id=\(self.identifier) foreground=\(isActive)")
                        self.finish(success: isActive, completesProgress: false)
                        self.expired(isActive)
                    }
                }
                self.publishProgress(force: true)
                self.started()
            }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: title,
            subtitle: progressSubtitle
        )
        // 被系统拒绝就退回普通的前台生命周期, 不排队等一个开始时机不定的任务。
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            finished = true
            plog("⬇️ Offline batch: continued processing unavailable: \(error)")
            return false
        }
    }

    func update(handledCount: Int) {
        guard !finished else { return }
        self.handledCount = handledCount
        publishProgress(force: false)
    }

    func finish(success: Bool) {
        finish(success: success, completesProgress: success)
    }

    private var progressSubtitle: String {
        String(
            format: String(localized: "offline_batch_task_progress_format"),
            min(handledCount, totalCount),
            totalCount
        )
    }

    private func publishProgress(force: Bool) {
        guard let task else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressPublishedAt) >= 1 else { return }
        lastProgressPublishedAt = now
        let units = OfflineBatchBackgroundRunPolicy.progressUnits(
            handledCount: handledCount,
            totalCount: totalCount
        )
        task.progress.totalUnitCount = units.total
        task.progress.completedUnitCount = units.completed
        task.updateTitle(title, subtitle: progressSubtitle)
    }

    /// - Parameter completesProgress: 只有整批下完才把进度条补满。
    private func finish(success: Bool, completesProgress: Bool) {
        guard !finished else { return }
        finished = true
        plog("⬇️ Offline batch: continued task finished id=\(identifier) success=\(success) granted=\(task != nil)")
        if let task {
            task.expirationHandler = nil
            if completesProgress {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        }
    }
}
#endif
