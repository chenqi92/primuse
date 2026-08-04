import Testing
@testable import PrimuseKit

@Suite("Immersive controls state")
struct ImmersiveControlsStateTests {
    @Test("Present and content taps reveal then hide primary controls")
    func primaryControlsToggle() {
        let presented = ImmersiveControlsState.inactive.applying(.present)
        #expect(presented.showsPrimaryControls)

        let hidden = presented.applying(.contentTap)
        #expect(!hidden.isVisible)
        #expect(!hidden.isLocked)

        #expect(hidden.applying(.contentTap).showsPrimaryControls)
    }

    @Test("Lock prevents primary controls until explicit unlock")
    func lockedSurfaceOnlyRevealsUnlock() {
        let locked = ImmersiveControlsState.presented.applying(.lock)
        #expect(locked.isLocked)
        #expect(!locked.isVisible)

        let revealed = locked.applying(.contentTap)
        #expect(revealed.showsUnlockControl)
        #expect(!revealed.showsPrimaryControls)

        #expect(revealed.applying(.unlock) == .presented)
    }

    @Test("Auto hide preserves the lock and dismiss resets it")
    func automaticHideAndDismiss() {
        let locked = ImmersiveControlsState.presented
            .applying(.lock)
            .applying(.contentTap)
            .applying(.autoHide)
        #expect(locked.isLocked)
        #expect(!locked.isVisible)
        #expect(locked.applying(.dismiss) == .inactive)
    }
}

@Suite("Now Playing landscape policy")
struct NowPlayingLandscapePolicyTests {
    @Test("Normal lyrics stay distinct from immersive lyrics")
    func lyricsModesRemainDistinct() {
        #expect(NowPlayingLandscapePolicy.mode(
            viewportWidth: 844,
            viewportHeight: 390,
            isMusicVideoActive: false,
            areLyricsVisible: true,
            areLyricsImmersive: false
        ) == .standardLyrics)

        #expect(NowPlayingLandscapePolicy.mode(
            viewportWidth: 844,
            viewportHeight: 390,
            isMusicVideoActive: false,
            areLyricsVisible: true,
            areLyricsImmersive: true
        ) == .immersiveLyrics)
    }

    @Test("Landscape music video takes presentation priority")
    func musicVideoWins() {
        #expect(NowPlayingLandscapePolicy.mode(
            viewportWidth: 844,
            viewportHeight: 390,
            isMusicVideoActive: true,
            areLyricsVisible: true,
            areLyricsImmersive: true
        ) == .musicVideo)
    }

    @Test("Portrait never selects a landscape takeover")
    func portraitUsesStandardLayout() {
        #expect(NowPlayingLandscapePolicy.mode(
            viewportWidth: 390,
            viewportHeight: 844,
            isMusicVideoActive: true,
            areLyricsVisible: true,
            areLyricsImmersive: true
        ) == .none)
    }
}
