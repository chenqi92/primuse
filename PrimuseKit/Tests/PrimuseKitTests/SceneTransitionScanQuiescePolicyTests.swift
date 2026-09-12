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
