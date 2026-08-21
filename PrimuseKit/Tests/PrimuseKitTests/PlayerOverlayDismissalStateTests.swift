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

    @Test("Player artwork can extend the downward dismissal start region")
    func artworkRegionCanDismiss() {
        #expect(
            NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 360,
                translationX: 4,
                translationY: 180,
                predictedEndTranslationY: 260,
                maximumStartY: 480
            )
        )
        #expect(
            !NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                startY: 500,
                translationX: 4,
                translationY: 180,
                predictedEndTranslationY: 260,
                maximumStartY: 480
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

    @Test("Leading-edge translation follows the logical layout direction")
    func leadingEdgeTranslationSupportsRTL() {
        #expect(NowPlayingDismissGesturePolicy.translationTowardCenter(
            translationX: 120,
            layoutIsRightToLeft: false
        ) == 120)
        #expect(NowPlayingDismissGesturePolicy.translationTowardCenter(
            translationX: -120,
            layoutIsRightToLeft: true
        ) == 120)
        #expect(NowPlayingDismissGesturePolicy.distanceFromLeadingEdge(
            startX: 378,
            containerWidth: 390,
            layoutIsRightToLeft: true
        ) == 12)
    }

    @Test("Invalid drag samples do not request an interactive snap-back")
    func invalidInteractiveSamplesAreIgnored() {
        #expect(NowPlayingDismissGesturePolicy.topInteractiveTranslation(
            startY: 70,
            translationX: 90,
            translationY: 40
        ) == nil)
        #expect(NowPlayingDismissGesturePolicy.topInteractiveTranslation(
            startY: 139,
            translationX: 3,
            translationY: 40
        ) == 40)
        #expect(NowPlayingDismissGesturePolicy.leadingInteractiveTranslation(
            startDistanceFromLeadingEdge: 25,
            translationTowardCenter: 80,
            translationY: 2
        ) == nil)
    }

    @Test("A drag resolves to one dominant dismissal axis")
    func dragAxisUsesTheDominantEligibleDirection() {
        #expect(NowPlayingDismissGesturePolicy.recognizedAxis(
            startY: 60,
            startDistanceFromLeadingEdge: 120,
            translationTowardCenter: 8,
            translationY: 40
        ) == .vertical)
        #expect(NowPlayingDismissGesturePolicy.recognizedAxis(
            startY: 220,
            startDistanceFromLeadingEdge: 12,
            translationTowardCenter: 40,
            translationY: 8
        ) == .horizontal)
        #expect(NowPlayingDismissGesturePolicy.recognizedAxis(
            startY: 60,
            startDistanceFromLeadingEdge: 12,
            translationTowardCenter: 20,
            translationY: 20
        ) == nil)
    }
}
