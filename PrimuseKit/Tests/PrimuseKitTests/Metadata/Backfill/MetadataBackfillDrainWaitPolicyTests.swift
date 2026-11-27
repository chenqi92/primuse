import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata backfill drain wait")
struct MetadataBackfillDrainWaitPolicyTests {
    @Test("A live worker is waited on without a bound")
    func liveWorkerWaitsUnbounded() {
        #expect(MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: true,
            hasDrainingWorker: false,
            elapsedSinceStop: 600,
            callerCancelled: false
        ))
    }

    @Test("A draining worker is waited on up to the grace")
    func drainingWorkerWaitsUpToTheGrace() {
        #expect(MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: false,
            hasDrainingWorker: true,
            elapsedSinceStop: 1,
            callerCancelled: false
        ))
        #expect(!MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: false,
            hasDrainingWorker: true,
            elapsedSinceStop: MetadataBackfillDrainWaitPolicy.drainGrace,
            callerCancelled: false
        ))
        #expect(!MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: false,
            hasDrainingWorker: true,
            elapsedSinceStop: 30,
            callerCancelled: false
        ))
    }

    @Test("A cancelled caller returns immediately")
    func cancelledCallerStopsWaiting() {
        #expect(!MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: true,
            hasDrainingWorker: true,
            elapsedSinceStop: 0,
            callerCancelled: true
        ))
    }

    @Test("Nothing running returns immediately")
    func idleReturnsImmediately() {
        #expect(!MetadataBackfillDrainWaitPolicy.shouldKeepWaiting(
            hasWorker: false,
            hasDrainingWorker: false,
            elapsedSinceStop: 0,
            callerCancelled: false
        ))
    }

    @Test("The drain poll is finer than the interval it replaces")
    func drainPollIsSubFrame() {
        #expect(MetadataBackfillDrainWaitPolicy.drainPollInterval > 0)
        #expect(MetadataBackfillDrainWaitPolicy.drainPollInterval <= 0.1)
        #expect(MetadataBackfillDrainWaitPolicy.drainGrace == 10)
    }
}
