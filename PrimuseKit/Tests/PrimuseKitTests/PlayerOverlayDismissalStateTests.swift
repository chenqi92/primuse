import Testing
@testable import PrimuseKit

@Suite("Player overlay dismissal state")
struct PlayerOverlayDismissalStateTests {
    @Test("Current dismissal completion closes the overlay")
    func currentCompletionSucceeds() {
        var state = PlayerOverlayDismissalState()
        let generation = state.begin()

        #expect(state.isDismissing)
        let didComplete = state.complete(generation: generation)
        #expect(didComplete)
        #expect(!state.isDismissing)
    }

    @Test("System interruption invalidates an in-flight completion")
    func interruptionInvalidatesCompletion() {
        var state = PlayerOverlayDismissalState()
        let interruptedGeneration = state.begin()

        state.cancelForSystemInterruption()

        #expect(!state.isDismissing)
        let didComplete = state.complete(generation: interruptedGeneration)
        #expect(!didComplete)
    }

    @Test("A new dismissal rejects completion from the previous generation")
    func newerDismissalRejectsOldCompletion() {
        var state = PlayerOverlayDismissalState()
        let firstGeneration = state.begin()
        state.cancelForSystemInterruption()
        let secondGeneration = state.begin()

        let didCompleteFirst = state.complete(generation: firstGeneration)
        let didCompleteSecond = state.complete(generation: secondGeneration)
        #expect(!didCompleteFirst)
        #expect(didCompleteSecond)
    }
}

@Suite("Now Playing dismiss gesture policy")
struct NowPlayingDismissGesturePolicyTests {
    @Test("Downward top swipe dismisses in portrait and landscape coordinates")
    func topSwipeDismisses() {
        #expect(
            NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 76,
                translationX: 4,
                translationY: 420,
                predictedEndTranslationY: 520
            )
        )
        #expect(
            NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 36,
                translationX: -3,
                translationY: 180,
                predictedEndTranslationY: 240
            )
        )
    }

    @Test("Top swipe rejects content scrolling and sideways movement")
    func topSwipeRejectsInvalidStartsAndDirections() {
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 220,
                translationX: 0,
                translationY: 300,
                predictedEndTranslationY: 420
            )
        )
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 70,
                translationX: 180,
                translationY: 80,
                predictedEndTranslationY: 400
            )
        )
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 70,
                translationX: 0,
                translationY: -180,
                predictedEndTranslationY: -260
            )
        )
    }

    @Test("Leading-edge right swipe dismisses without accepting content drags")
    func leadingEdgeSwipeDismisses() {
        #expect(
            NowPlayingDismissGesturePolicy.shouldDismissFromLeadingEdge(
                startX: 12,
                translationX: 130,
                translationY: 8,
                predictedEndTranslationX: 180
            )
        )
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromLeadingEdge(
                startX: 80,
                translationX: 180,
                translationY: 0,
                predictedEndTranslationX: 240
            )
        )
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromLeadingEdge(
                startX: 12,
                translationX: 70,
                translationY: 140,
                predictedEndTranslationX: 360
            )
        )
    }
}
