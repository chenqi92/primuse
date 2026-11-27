import Testing
@testable import PrimuseKit

@Suite("Playback end identity policy")
struct PlaybackEndIdentityPolicyTests {
    @Test("Only the active player item may advance the queue")
    func acceptsCurrentItem() {
        #expect(PlaybackEndIdentityPolicy.shouldAdvance(
            endedItemID: 2,
            activeItemID: 2,
            currentItemID: 2
        ))
    }

    @Test("A detached item's late notification is ignored")
    func rejectsDetachedItem() {
        #expect(!PlaybackEndIdentityPolicy.shouldAdvance(
            endedItemID: 1,
            activeItemID: 2,
            currentItemID: 2
        ))
    }

    @Test("Cancellation invalidates an already queued notification")
    func rejectsCancelledItem() {
        #expect(!PlaybackEndIdentityPolicy.shouldAdvance(
            endedItemID: 1,
            activeItemID: Optional<Int>.none,
            currentItemID: Optional<Int>.none
        ))
    }

    @Test("A player replacement must match the active generation")
    func rejectsMismatchedCurrentItem() {
        #expect(!PlaybackEndIdentityPolicy.shouldAdvance(
            endedItemID: 1,
            activeItemID: 1,
            currentItemID: 2
        ))
    }
}
