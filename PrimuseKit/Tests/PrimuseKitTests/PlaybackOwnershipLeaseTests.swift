import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback ownership lease")
struct PlaybackOwnershipLeaseTests {
    @Test("The current owner keeps scheduling")
    func currentOwnerContinues() {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 7, isCrossfading: false, outgoingPlayID: nil)
        #expect(lease.mayContinue(7))
        #expect(!lease.mayContinue(8))
    }

    @Test("A handoff retires the previous owner")
    func previousOwnerStopsAfterHandoff() {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 1, isCrossfading: false, outgoingPlayID: nil)
        #expect(lease.mayContinue(1))

        lease.update(currentPlayID: 2, isCrossfading: false, outgoingPlayID: nil)
        #expect(!lease.mayContinue(1))
        #expect(lease.mayContinue(2))
    }

    @Test("The outgoing owner keeps its grace only while the crossfade is live")
    func outgoingOwnerContinuesOnlyWhileCrossfading() {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 2, isCrossfading: true, outgoingPlayID: 1)
        #expect(lease.mayContinue(1))
        #expect(lease.mayContinue(2))
        #expect(!lease.mayContinue(3))

        // Completing, failing or cancelling the transition clears the grace.
        lease.update(currentPlayID: 2, isCrossfading: false, outgoingPlayID: 1)
        #expect(!lease.mayContinue(1))
        #expect(lease.mayContinue(2))
    }

    @Test("No owner means no pump may continue")
    func noOwnerStopsEveryPump() {
        let lease = PlaybackOwnershipLease<Int>()
        #expect(!lease.mayContinue(1))
        lease.update(currentPlayID: nil, isCrossfading: true, outgoingPlayID: nil)
        #expect(!lease.mayContinue(1))
    }

    @Test("Snapshots return the last published state")
    func snapshotReturnsPublishedState() {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 5, isCrossfading: true, outgoingPlayID: 4)
        let state = lease.snapshot()
        #expect(state.currentPlayID == 5)
        #expect(state.isCrossfading)
        #expect(state.outgoingPlayID == 4)
    }

    @Test("Updates from one thread are observed by reads from another")
    func updatesArePublishedAcrossThreads() async {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 0, isCrossfading: false, outgoingPlayID: nil)
        let handoffCount = 500

        let writer = Task.detached {
            for playID in 1...handoffCount {
                lease.update(currentPlayID: playID, isCrossfading: false, outgoingPlayID: nil)
            }
        }
        let reader = Task.detached { () -> Bool in
            var sawRetirement = false
            for _ in 0..<(handoffCount * 4) where !lease.mayContinue(0) {
                sawRetirement = true
            }
            return sawRetirement
        }

        await writer.value
        _ = await reader.value

        // Whatever interleaving occurred, the final published state must win.
        #expect(!lease.mayContinue(0))
        #expect(lease.mayContinue(handoffCount))
    }

    @Test("Concurrent readers never observe a torn tuple")
    func concurrentReadersSeeConsistentState() async {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: 2, isCrossfading: true, outgoingPlayID: 1)

        let queue = DispatchQueue(label: "lease.writer")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            for _ in 0..<2_000 {
                lease.update(currentPlayID: 2, isCrossfading: true, outgoingPlayID: 1)
                lease.update(currentPlayID: 3, isCrossfading: true, outgoingPlayID: 2)
            }
            done.signal()
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var valid = true
                    for _ in 0..<2_000 {
                        let state = lease.snapshot()
                        // Only the two published tuples may ever be observed.
                        let isFirst = state.currentPlayID == 2 && state.outgoingPlayID == 1
                        let isSecond = state.currentPlayID == 3 && state.outgoingPlayID == 2
                        if !(isFirst || isSecond) || !state.isCrossfading { valid = false }
                    }
                    return valid
                }
            }
            for await valid in group { #expect(valid) }
        }
        done.wait()
    }
}
