import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata backfill scene transitions")
struct MetadataBackfillSceneTransitionPolicyTests {
    @Test("A temporary overlay pauses instead of cancelling")
    func inactivePauses() {
        #expect(MetadataBackfillSceneTransitionPolicy.disposition(
            phase: .inactive,
            isPlaybackActive: false,
            isSystemBackgroundProcessing: false
        ) == .pause)
        #expect(MetadataBackfillSceneTransitionPolicy.disposition(
            phase: .inactive,
            isPlaybackActive: true,
            isSystemBackgroundProcessing: false
        ) == .pause)
    }

    @Test("Real backgrounding keeps the hard stop")
    func backgroundHardStops() {
        #expect(MetadataBackfillSceneTransitionPolicy.disposition(
            phase: .background,
            isPlaybackActive: false,
            isSystemBackgroundProcessing: false
        ) == .hardStop)
        #expect(MetadataBackfillSceneTransitionPolicy.disposition(
            phase: .background,
            isPlaybackActive: true,
            isSystemBackgroundProcessing: false
        ) == .hardStop)
    }

    @Test("An expired background-processing session overrides the phase")
    func systemBackgroundProcessingHardStops() {
        for phase in [ScenePhaseKind.active, .inactive, .background] {
            #expect(MetadataBackfillSceneTransitionPolicy.disposition(
                phase: phase,
                isPlaybackActive: false,
                isSystemBackgroundProcessing: true
            ) == .hardStop)
        }
    }

    @Test("Returning to the foreground resumes the same queue")
    func activeResumes() {
        #expect(MetadataBackfillSceneTransitionPolicy.disposition(
            phase: .active,
            isPlaybackActive: false,
            isSystemBackgroundProcessing: false
        ) == .resume)
    }

    @Test("A paused queue admits no reader")
    func pausedWorkerCountIsZero() {
        #expect(MetadataBackfillSceneTransitionPolicy.workerCount(base: 6, isPaused: true) == 0)
        #expect(MetadataBackfillSceneTransitionPolicy.workerCount(base: 6, isPaused: false) == 6)
        #expect(MetadataBackfillSceneTransitionPolicy.workerCount(base: 0, isPaused: false) == 0)
        // 上游已经把并发降到 0 (例如显式批次占着预算) 时不能被放大。
        #expect(MetadataBackfillSceneTransitionPolicy.workerCount(base: -1, isPaused: false) == 0)
    }

    @Test("A paused worker accumulates but the last batch still lands")
    func pausedFlushIsAccumulatedExceptTheFinalBatch() {
        #expect(!MetadataBackfillSceneTransitionPolicy.shouldPublishFlush(
            isPaused: true, isFinalFlush: false
        ))
        #expect(MetadataBackfillSceneTransitionPolicy.shouldPublishFlush(
            isPaused: true, isFinalFlush: true
        ))
        #expect(MetadataBackfillSceneTransitionPolicy.shouldPublishFlush(
            isPaused: false, isFinalFlush: false
        ))
    }
}
