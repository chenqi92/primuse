import Testing
@testable import PrimuseKit

@Suite("Artwork fallback attempts")
struct ArtworkFallbackAttemptsTests {
    @Test("A failed song and its shared cover reference are both skipped")
    func recordsSongAndReference() {
        var attempts = ArtworkFallbackAttempts()
        #expect(!attempts.hasFailed(identity: "a#1"))
        attempts.recordFailure(songID: "a", reference: "folder.jpg", identity: "a#1")
        #expect(attempts.hasFailed(identity: "a#1"))
        #expect(!attempts.hasFailed(identity: "a#2"))
        #expect(attempts.songIDs == ["a"])
        #expect(attempts.references == ["folder.jpg"])
    }

    @Test("Songs without a cover reference do not add an empty reference")
    func ignoresMissingReference() {
        var attempts = ArtworkFallbackAttempts()
        attempts.recordFailure(songID: "a", reference: nil, identity: "a")
        attempts.recordFailure(songID: "b", reference: "", identity: "b")
        #expect(attempts.references.isEmpty)
        #expect(attempts.songIDs == ["a", "b"])
    }

    @Test("A card stops trying after the attempt budget")
    func stopsAfterBudget() {
        var attempts = ArtworkFallbackAttempts()
        for index in 0..<ArtworkFallbackAttempts.maximumAttempts {
            #expect(attempts.canTryAnother)
            attempts.recordFailure(songID: "s\(index)", reference: "r\(index)", identity: "s\(index)")
        }
        #expect(!attempts.canTryAnother)
    }
}
