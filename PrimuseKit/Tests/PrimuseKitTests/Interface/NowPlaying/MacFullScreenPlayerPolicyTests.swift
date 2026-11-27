import Foundation
import Testing
@testable import PrimuseKit

@Suite("Mac full-screen player policy")
struct MacFullScreenPlayerPolicyTests {
    private typealias Policy = MacFullScreenPlayerPolicy

    @Test("Effects are offered only for playing music")
    func effectsOnlyForMusic() {
        #expect(Policy.offersEffects(hasCurrentSong: true, isLiveRadio: false, isSpokenWord: false))
        #expect(!Policy.offersEffects(hasCurrentSong: false, isLiveRadio: false, isSpokenWord: false))
        #expect(!Policy.offersEffects(hasCurrentSong: true, isLiveRadio: true, isSpokenWord: false))
        #expect(!Policy.offersEffects(hasCurrentSong: true, isLiveRadio: false, isSpokenWord: true))
    }

    @Test("Music opens the effect picker; everything else enters directly")
    func entryControlAction() {
        let music = Policy.entryControlAction(
            hasCurrentSong: true, isLiveRadio: false, isSpokenWord: false, isPlayingMusicVideo: false
        )
        #expect(music == .presentEffectPicker)

        let musicVideo = Policy.entryControlAction(
            hasCurrentSong: true, isLiveRadio: false, isSpokenWord: false, isPlayingMusicVideo: true
        )
        #expect(musicVideo == .enterDirectly)

        let radio = Policy.entryControlAction(
            hasCurrentSong: true, isLiveRadio: true, isSpokenWord: false, isPlayingMusicVideo: false
        )
        #expect(radio == .enterDirectly)

        let spokenWord = Policy.entryControlAction(
            hasCurrentSong: true, isLiveRadio: false, isSpokenWord: true, isPlayingMusicVideo: false
        )
        #expect(spokenWord == .enterDirectly)

        let empty = Policy.entryControlAction(
            hasCurrentSong: false, isLiveRadio: false, isSpokenWord: false, isPlayingMusicVideo: false
        )
        #expect(empty == .enterDirectly)
    }

    @Test("Toggle exits only while the player fills the full-screen window")
    func toggleAction() {
        #expect(Policy.toggleAction(isWindowFullScreen: true, isPlayerExpanded: true) == .exit)
        #expect(Policy.toggleAction(isWindowFullScreen: true, isPlayerExpanded: false) == .enter)
        #expect(Policy.toggleAction(isWindowFullScreen: false, isPlayerExpanded: true) == .enter)
        #expect(Policy.toggleAction(isWindowFullScreen: false, isPlayerExpanded: false) == .enter)
    }

    @Test("Re-entering inside full screen keeps the original return point")
    func returnPointKeepsEarliestInsideFullScreen() {
        let original = point(windowWasFullScreen: false, playerWasExpanded: false, queue: true)
        let current = point(windowWasFullScreen: true, playerWasExpanded: false)
        let kept = Policy.returnPoint(existing: original, current: current, isWindowFullScreen: true)
        #expect(kept == original)
    }

    @Test("A leftover return point is replaced while windowed")
    func staleReturnPointReplacedWhenWindowed() {
        let stale = point(windowWasFullScreen: false, playerWasExpanded: false)
        let current = point(windowWasFullScreen: false, playerWasExpanded: true)
        let chosen = Policy.returnPoint(existing: stale, current: current, isWindowFullScreen: false)
        #expect(chosen == current)

        let fresh = Policy.returnPoint(existing: nil, current: current, isWindowFullScreen: true)
        #expect(fresh == current)
    }

    @Test("Exit stays in full screen only when the library was already full screen")
    func exitRoute() {
        let fromLibraryFullScreen = point(windowWasFullScreen: true, playerWasExpanded: false)
        #expect(Policy.exitRoute(returnPoint: fromLibraryFullScreen) == .stayInSystemFullScreen)

        let fromWindowedLibrary = point(windowWasFullScreen: false, playerWasExpanded: false)
        #expect(Policy.exitRoute(returnPoint: fromWindowedLibrary) == .leaveSystemFullScreen)

        let fromWindowedPlayer = point(windowWasFullScreen: false, playerWasExpanded: true)
        #expect(Policy.exitRoute(returnPoint: fromWindowedPlayer) == .leaveSystemFullScreen)

        let fromFullScreenPlayer = point(windowWasFullScreen: true, playerWasExpanded: true)
        #expect(Policy.exitRoute(returnPoint: fromFullScreenPlayer) == .leaveSystemFullScreen)

        #expect(Policy.exitRoute(returnPoint: nil) == .leaveSystemFullScreen)
    }

    @Test("Exit collapses the player only when it was not open before")
    func restorationCollapsesPlayer() {
        let fromLibrary = Policy.restoration(for: point(windowWasFullScreen: false, playerWasExpanded: false))
        #expect(fromLibrary.collapsesPlayer)

        let fromPlayer = Policy.restoration(for: point(windowWasFullScreen: false, playerWasExpanded: true))
        #expect(!fromPlayer.collapsesPlayer)
    }

    @Test("Exit restores the side panel that was open, queue first")
    func restorationRestoresSidePanels() {
        let queue = Policy.restoration(for: point(queue: true))
        #expect(queue.showsQueue)
        #expect(!queue.showsRecommendations)

        let recommendations = Policy.restoration(for: point(recommendations: true))
        #expect(!recommendations.showsQueue)
        #expect(recommendations.showsRecommendations)

        let both = Policy.restoration(for: point(queue: true, recommendations: true))
        #expect(both.showsQueue)
        #expect(!both.showsRecommendations)

        let none = Policy.restoration(for: point())
        #expect(!none.showsQueue)
        #expect(!none.showsRecommendations)
    }

    @Test("An entry request only counts for a short while")
    func entryRequestLifetime() {
        let requestedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!Policy.isEntryRequestPending(requestedAt: nil, now: requestedAt))
        #expect(Policy.isEntryRequestPending(requestedAt: requestedAt, now: requestedAt))
        #expect(Policy.isEntryRequestPending(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(Policy.entryRequestLifetime)
        ))
        #expect(!Policy.isEntryRequestPending(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(Policy.entryRequestLifetime + 0.5)
        ))
        // 时钟往回拨时不算数。
        #expect(!Policy.isEntryRequestPending(
            requestedAt: requestedAt,
            now: requestedAt.addingTimeInterval(-1)
        ))
    }

    private func point(
        windowWasFullScreen: Bool = false,
        playerWasExpanded: Bool = false,
        queue: Bool = false,
        recommendations: Bool = false
    ) -> Policy.ReturnPoint {
        Policy.ReturnPoint(
            windowWasFullScreen: windowWasFullScreen,
            playerWasExpanded: playerWasExpanded,
            queueWasPresented: queue,
            recommendationsWerePresented: recommendations
        )
    }
}
