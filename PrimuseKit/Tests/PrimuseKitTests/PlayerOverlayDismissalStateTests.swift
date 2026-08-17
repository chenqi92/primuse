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
