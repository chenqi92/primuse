import Testing
@testable import PrimuseKit

struct PlaybackQueueSegmentPolicyTests {
    @Test func retainsBothSidesOfAnEntirePlaylist() {
        #expect(PlaybackQueueSegmentPolicy.indices(traversal: [0, 1, 2, 3], currentIndex: 2) { _ in true } == [0, 1, 2, 3])
    }

    @Test func neverCrossesAnotherProviderOrUnresolvedItem() {
        #expect(PlaybackQueueSegmentPolicy.indices(traversal: [0, 1, 2, 3, 4], currentIndex: 3) { $0 != 1 && $0 != 4 } == [2, 3])
    }

    @Test func followsShuffleAndKeepsDistinctOccurrences() {
        // Rows 0 and 2 may hold the same song; their queue slots stay distinct.
        #expect(PlaybackQueueSegmentPolicy.indices(traversal: [3, 2, 0, 1], currentIndex: 2) { $0 != 1 } == [3, 2, 0])
    }

    @Test func rejectsAStaleOrUnavailableSelection() {
        #expect(PlaybackQueueSegmentPolicy.indices(traversal: [0, 1], currentIndex: 2) { _ in true }.isEmpty)
        #expect(PlaybackQueueSegmentPolicy.indices(traversal: [0, 1], currentIndex: 0) { $0 == 1 }.isEmpty)
    }
}
