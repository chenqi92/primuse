import Foundation
import Testing
@testable import PrimuseKit

@Suite("Streaming download retirement policy")
struct StreamingDownloadRetirementPolicyTests {
    @Test("Nothing to finalize without a previous selection")
    func noPreviousSelection() {
        #expect(
            !StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: nil,
                newSongID: "new",
                retiredSongID: nil
            )
        )
    }

    @Test("Replaying the same item never finalizes it")
    func samePreviousAndNewSelection() {
        #expect(
            !StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "same",
                newSongID: "same",
                retiredSongID: nil
            )
        )
    }

    @Test("The retirement task owns the finalize of the song it retired")
    func retiredSongIsLeftToItsRetirement() {
        #expect(
            !StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "previous",
                newSongID: "new",
                retiredSongID: "previous"
            )
        )
    }

    @Test("A distinct previous selection is finalized by the caller")
    func distinctPreviousSelectionIsFinalized() {
        #expect(
            StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "previous",
                newSongID: "new",
                retiredSongID: nil
            )
        )
        // Another song's retirement does not cover this one.
        #expect(
            StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "previous",
                newSongID: "new",
                retiredSongID: "unrelated"
            )
        )
    }

    @Test("Stopping without a replacement still finalizes the previous item")
    func stopWithoutReplacement() {
        #expect(
            StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "previous",
                newSongID: nil,
                retiredSongID: nil
            )
        )
        #expect(
            !StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
                previousSongID: "previous",
                newSongID: nil,
                retiredSongID: "previous"
            )
        )
    }
}
