import Foundation
import Testing
@testable import PrimuseKit

@Suite("Batch scrape foreground resume")
struct BatchScrapeForegroundResumePolicyTests {
    private func decision(
        hasCheckpoint: Bool = true,
        isBatchRunning: Bool = false,
        isSingleRunning: Bool = false,
        isApplicationActive: Bool = true,
        isSafeModeActive: Bool = false,
        fromPreviousProcess: Bool = false,
        resumeIndex: Int = 120,
        lastLaunchResumeIndex: Int? = nil
    ) -> BatchScrapeForegroundResumePolicy.Decision {
        BatchScrapeForegroundResumePolicy.decision(
            hasCheckpoint: hasCheckpoint,
            isBatchRunning: isBatchRunning,
            isSingleRunning: isSingleRunning,
            isApplicationActive: isApplicationActive,
            isSafeModeActive: isSafeModeActive,
            checkpointFromPreviousProcess: fromPreviousProcess,
            resumeIndex: resumeIndex,
            lastLaunchResumeIndex: lastLaunchResumeIndex
        )
    }

    @Test("A batch the system stopped in this launch resumes in the foreground")
    func systemStopInThisLaunchResumes() {
        #expect(decision() == .resume)
        // 同一进程里没往前走（比如源一时不可用）也照常续：进程还活着，不是闪退。
        #expect(decision(resumeIndex: 120, lastLaunchResumeIndex: 120) == .resume)
    }

    @Test("A user stop clears the checkpoint, so nothing resumes")
    func userStopNeverResumes() {
        #expect(decision(hasCheckpoint: false) == .skip(.noCheckpoint))
    }

    @Test("A running batch, a leaving scene, safe mode and a single scrape all wait")
    func busyOrLeavingWaits() {
        #expect(decision(isBatchRunning: true) == .skip(.alreadyRunning))
        #expect(decision(isApplicationActive: false) == .skip(.leavingForeground))
        #expect(decision(isSafeModeActive: true) == .skip(.safeMode))
        #expect(decision(isSingleRunning: true) == .skip(.singleScrapeRunning))
    }

    @Test("A checkpoint left by an earlier launch resumes after a system kill")
    func earlierLaunchCheckpointResumes() {
        #expect(decision(fromPreviousProcess: true) == .resume)
        // 上次打开时从 100 续过、之后刮到了 120：有进展，接着续。
        #expect(decision(fromPreviousProcess: true, resumeIndex: 120, lastLaunchResumeIndex: 100) == .resume)
    }

    @Test("An earlier launch that died without progress is not retried in the foreground")
    func noProgressSinceEarlierLaunchIsSkipped() {
        #expect(
            decision(fromPreviousProcess: true, resumeIndex: 120, lastLaunchResumeIndex: 120)
                == .skip(.noProgressSinceLastLaunch)
        )
    }

    @Test("The resume waits a moment after the scene returns, but not long")
    func delayStaysShort() {
        #expect(BatchScrapeForegroundResumePolicy.foregroundResumeDelay > 0)
        #expect(BatchScrapeForegroundResumePolicy.foregroundResumeDelay <= 5)
    }
}
