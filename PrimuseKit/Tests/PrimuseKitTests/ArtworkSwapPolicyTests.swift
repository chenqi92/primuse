import Testing
@testable import PrimuseKit

@Suite("Artwork swap direction")
struct ArtworkSwapPolicyTests {
    @Test("A fresh manual skip wins and is not gentle")
    func manualIntentWins() {
        let forward = ArtworkSwapPolicy.style(
            newSongID: "b", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: .forward, intentAge: 0.3
        )
        #expect(forward == ArtworkSwapStyle(direction: .forward, isGentle: false))

        let backward = ArtworkSwapPolicy.style(
            newSongID: "z", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: .backward, intentAge: 1
        )
        #expect(backward == ArtworkSwapStyle(direction: .backward, isGentle: false))
    }

    @Test("Reaching the predicted next song on its own is gentle and forward")
    func naturalAdvanceIsGentle() {
        let style = ArtworkSwapPolicy.style(
            newSongID: "b", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: nil, intentAge: nil
        )
        #expect(style == ArtworkSwapStyle(direction: .forward, isGentle: true))
    }

    @Test("A stale manual intent no longer counts")
    func staleIntentIgnored() {
        let style = ArtworkSwapPolicy.style(
            newSongID: "b", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: .backward, intentAge: ArtworkSwapPolicy.intentLifetime + 0.1
        )
        #expect(style == ArtworkSwapStyle(direction: .forward, isGentle: true))
    }

    @Test("Going back to the predicted previous song without intent goes backward")
    func previousWithoutIntent() {
        let style = ArtworkSwapPolicy.style(
            newSongID: "z", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: nil, intentAge: nil
        )
        #expect(style?.direction == .backward)
    }

    @Test("Jumps, new queues and missing songs keep the plain crossfade")
    func unrelatedChangesHaveNoDirection() {
        #expect(ArtworkSwapPolicy.style(
            newSongID: "q", predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: nil, intentAge: nil
        ) == nil)
        #expect(ArtworkSwapPolicy.style(
            newSongID: nil, predictedNextID: "b", predictedPreviousID: "z",
            manualIntent: .forward, intentAge: 0
        ) == nil)
        #expect(ArtworkSwapPolicy.style(
            newSongID: "", predictedNextID: "", predictedPreviousID: nil,
            manualIntent: nil, intentAge: nil
        ) == nil)
    }

    @Test("Exit offsets mirror for direction and right-to-left layouts")
    func offsetsMirror() {
        let ltrForward = ArtworkSwapPolicy.exitOffsetFraction(for: .forward, isRightToLeft: false)
        let ltrBackward = ArtworkSwapPolicy.exitOffsetFraction(for: .backward, isRightToLeft: false)
        let rtlForward = ArtworkSwapPolicy.exitOffsetFraction(for: .forward, isRightToLeft: true)
        #expect(ltrForward < 0)
        #expect(ltrBackward == -ltrForward)
        #expect(rtlForward == -ltrForward)
    }
}
