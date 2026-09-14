import Foundation
import Testing
@testable import PrimuseKit

@Suite("Scene transition scan quiescence")
struct SceneTransitionScanQuiescePolicyTests {
    @Test("A control-center flip never cancels the scan")
    func activeWithinDebounceSkipsTheCancel() {
        #expect(
            SceneTransitionScanQuiescePolicy.cancelDisposition(nextPhaseWithinDebounce: .active)
                == .skip
        )
    }

    @Test("Real backgrounding and a silent window both cancel")
    func backgroundOrTimeoutCancels() {
        // 挂起就在眼前: 检查点必须在这一刻落地。
        #expect(
            SceneTransitionScanQuiescePolicy.cancelDisposition(nextPhaseWithinDebounce: .background)
                == .cancelNow
        )
        // 窗口到期都没回到前台。
        #expect(
            SceneTransitionScanQuiescePolicy.cancelDisposition(nextPhaseWithinDebounce: nil)
                == .cancelNow
        )
        #expect(
            SceneTransitionScanQuiescePolicy.cancelDisposition(nextPhaseWithinDebounce: .inactive)
                == .cancelNow
        )
    }

    @Test("The debounce is shorter than a perceptible interruption")
    func debounceStaysShort() {
        #expect(SceneTransitionScanQuiescePolicy.inactiveCancelDebounce > 0)
        #expect(SceneTransitionScanQuiescePolicy.inactiveCancelDebounce <= 1)
    }

    @Test("Background audio makes the window unbounded")
    func backgroundPlaybackAlwaysResumes() {
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: 5,
            isBackgroundPlaybackActive: true,
            hasScheduledProcessingWake: true
        ))
        // `UIApplication.backgroundTimeRemaining` 在有后台音频时给的就是这个值。
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: .greatestFiniteMagnitude,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: true
        ))
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: .infinity,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: true
        ))
    }

    @Test("A window too small for the preflight defers to the scheduled wake")
    func narrowWindowWithScheduledWakeDefers() {
        #expect(!SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: 8,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: true
        ))
        // 窗口装得下预检就照常续扫。
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: 25,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: true
        ))
    }

    @Test("Without a scheduled wake the work is never stranded")
    func narrowWindowWithoutScheduledWakeStillResumes() {
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: 8,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: false
        ))
        #expect(SceneTransitionScanQuiescePolicy.shouldResumeInFiniteBackgroundWindow(
            secondsRemaining: 0,
            isBackgroundPlaybackActive: false,
            hasScheduledProcessingWake: false
        ))
    }
}

@Suite("Scan continued processing")
struct ScanContinuedProcessingPolicyTests {
    private func disposition(
        context: BaiduSnapshotExecutionContext = .userInitiatedForeground,
        isForegroundOnlySource: Bool = false,
        isApplicationActive: Bool = true,
        hasUserInitiatedIntent: Bool = false,
        hasExistingSession: Bool = false
    ) -> ScanContinuedProcessingPolicy.Disposition {
        ScanContinuedProcessingPolicy.requestDisposition(
            context: context,
            isForegroundOnlySource: isForegroundOnlySource,
            isApplicationActive: isApplicationActive,
            hasUserInitiatedIntent: hasUserInitiatedIntent,
            hasExistingSession: hasExistingSession
        )
    }

    @Test("A user-started foreground scan asks the system for background time")
    func userInitiatedForegroundSubmits() {
        #expect(disposition() == .submit)
        #expect(disposition(hasExistingSession: true) == .keepExisting)
    }

    @Test("Only a foreground user action may ask")
    func backgroundAndInactiveNeverSubmit() {
        #expect(disposition(isApplicationActive: false) == .skip)
        #expect(disposition(context: .background, hasUserInitiatedIntent: true) == .skip)
    }

    @Test("A foreground resume renews the session only for the user's own intent")
    func foregroundResumeNeedsTheIntent() {
        // 冷启动的自动续扫: 没有这份意图, 不该弹出系统任务卡片。
        #expect(disposition(context: .foregroundResume) == .skip)
        #expect(
            disposition(context: .foregroundResume, hasUserInitiatedIntent: true) == .submit
        )
        #expect(
            disposition(
                context: .foregroundResume,
                hasUserInitiatedIntent: true,
                hasExistingSession: true
            ) == .keepExisting
        )
    }

    @Test("A foreground-only source is never pushed into the background")
    func foregroundOnlySourceSkips() {
        #expect(disposition(isForegroundOnlySource: true) == .skip)
        #expect(
            disposition(
                context: .foregroundResume,
                isForegroundOnlySource: true,
                hasUserInitiatedIntent: true
            ) == .skip
        )
    }

    @Test("Expiration stops the scan only once the app is really gone")
    func expirationCancelsOnlyInBackground() {
        #expect(ScanContinuedProcessingPolicy.cancelsScanOnExpiration(isApplicationActive: false))
        #expect(!ScanContinuedProcessingPolicy.cancelsScanOnExpiration(isApplicationActive: true))
    }

    @Test("An unknown total reports indeterminate progress")
    func unknownTotalStaysIndeterminate() {
        let units = ScanContinuedProcessingPolicy.progressUnits(scannedCount: 1234, totalCount: 0)
        #expect(units.completed == 0)
        #expect(units.total == 0)
        #expect(
            ScanContinuedProcessingPolicy.progressSubtitle(
                sourceName: "WebDAV", scannedCount: 1234, totalCount: 0
            ) == "WebDAV · 1234"
        )
    }

    @Test("A known total is clamped and reported as a fraction")
    func knownTotalIsClamped() {
        let units = ScanContinuedProcessingPolicy.progressUnits(scannedCount: 30, totalCount: 40)
        #expect(units.completed == 30)
        #expect(units.total == 40)
        // 目录还没走完时计数可以短暂超过已知总数。
        let clamped = ScanContinuedProcessingPolicy.progressUnits(
            scannedCount: 90, totalCount: 40
        )
        #expect(clamped.completed == 40)
        let negative = ScanContinuedProcessingPolicy.progressUnits(
            scannedCount: -5, totalCount: 40
        )
        #expect(negative.completed == 0)
        #expect(
            ScanContinuedProcessingPolicy.progressSubtitle(
                sourceName: "WebDAV", scannedCount: 30, totalCount: 40
            ) == "WebDAV · 30 / 40"
        )
        #expect(
            ScanContinuedProcessingPolicy.progressSubtitle(
                sourceName: "", scannedCount: 30, totalCount: 40
            ) == "30 / 40"
        )
    }
}
