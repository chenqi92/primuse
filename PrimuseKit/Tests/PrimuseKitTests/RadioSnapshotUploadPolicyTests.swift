import Foundation
import Testing
@testable import PrimuseKit

@Suite("Debounced radio snapshot upload")
struct RadioSnapshotUploadPolicyTests {
    @Test("A running service with the sources channel on arms the debounce")
    func schedulesWhileRunning() {
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: true, isChannelEnabled: true))
    }

    @Test("A stopped service or a disabled channel arms nothing")
    func refusesToScheduleWhenInactive() {
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: false, isChannelEnabled: true) == false)
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: true, isChannelEnabled: false) == false)
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: false, isChannelEnabled: false) == false)
    }

    @Test("The change that armed the debounce uploads once the window elapses")
    func armedUploadRuns() {
        let token = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: false, currentToken: token, taskToken: token
            )
        )
    }

    @Test("A service stopped during the debounce window uploads nothing")
    func stoppedDuringDebounce() {
        let token = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: false, isCancelled: true, currentToken: nil, taskToken: token
            ) == false
        )
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: false, isCancelled: false, currentToken: token, taskToken: token
            ) == false
        )
    }

    @Test("A burst keeps only its last change — earlier tasks are superseded")
    func burstCollapsesToLastChange() {
        let first = UUID()
        let last = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: true, currentToken: last, taskToken: first
            ) == false
        )
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: false, currentToken: last, taskToken: last
            )
        )
    }

    @Test("The debounce window is short enough to stay interactive")
    func debounceWindowIsBounded() {
        #expect(RadioSnapshotUploadPolicy.debounce > .zero)
        #expect(RadioSnapshotUploadPolicy.debounce <= .seconds(5))
    }

    @Test("A long editing session cannot postpone the snapshot past the maximum delay")
    func boundedByMaximumDelay() {
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: nil) == RadioSnapshotUploadPolicy.debounce)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: .seconds(0)) == RadioSnapshotUploadPolicy.debounce)
        let nearCap = RadioSnapshotUploadPolicy.maximumDelay - .seconds(1)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: nearCap) == .seconds(1))
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: RadioSnapshotUploadPolicy.maximumDelay) == .zero)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: .seconds(600)) == .zero)
    }
}
