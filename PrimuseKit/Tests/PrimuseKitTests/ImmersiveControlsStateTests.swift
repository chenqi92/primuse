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

@Suite("Immersive presentation fallback")
struct ImmersivePresentationFallbackPolicyTests {
    @Test("Kinetic title remains selected without synchronized lyrics")
    func lyricsFallback() {
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "kineticTitle",
            hasSynchronizedLyrics: false,
            hasArtwork: true
        ) == "kineticTitle")
    }

    @Test("Artwork-dependent groups remain selected without artwork")
    func artworkFallback() {
        for selected in ["coverFlow", "coverGallery", "starryNight"] {
            #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
                selectedRawValue: selected,
                hasSynchronizedLyrics: true,
                hasArtwork: false
            ) == selected)
        }
    }

    @Test("Unknown stored values fall back to cover flow")
    func unknownValueFallback() {
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "unknown",
            hasSynchronizedLyrics: false,
            hasArtwork: false
        ) == "coverFlow")
    }

    @Test("Available content preserves the selected group")
    func preservesSelection() {
        for selected in [
            "coverFlow", "coverGallery", "starryNight", "flowingLines",
            "lightRhythm", "kineticTitle", "radialPulse", "liveWaveform",
        ] {
            #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
                selectedRawValue: selected,
                hasSynchronizedLyrics: true,
                hasArtwork: true
            ) == selected)
        }
    }

    @Test("Legacy selections migrate to semantic effects")
    func migratesLegacySelection() {
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "coverWall",
            hasSynchronizedLyrics: true,
            hasArtwork: true
        ) == "coverGallery")
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "radialSpectrum",
            hasSynchronizedLyrics: true,
            hasArtwork: true
        ) == "radialPulse")
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

@Suite("Lyrics background tap policy")
struct LyricsBackgroundTapPolicyTests {
    @Test("Unused lyric space can switch the normal surface")
    func unusedSpaceIsHandled() {
        #expect(LyricsBackgroundTapPolicy.shouldHandle(
            hasLyrics: true,
            isPinching: false,
            rowTapTimeDistance: 1
        ))
    }

    @Test("A lyric row tap is not also treated as a background tap")
    func rowTapIsSuppressed() {
        #expect(!LyricsBackgroundTapPolicy.shouldHandle(
            hasLyrics: true,
            isPinching: false,
            rowTapTimeDistance: 0.04
        ))
    }

    @Test("Pinching and empty lyrics do not switch surfaces")
    func nonTapInteractionsAreIgnored() {
        #expect(!LyricsBackgroundTapPolicy.shouldHandle(
            hasLyrics: true,
            isPinching: true,
            rowTapTimeDistance: 1
        ))
        #expect(!LyricsBackgroundTapPolicy.shouldHandle(
            hasLyrics: false,
            isPinching: false,
            rowTapTimeDistance: 1
        ))
    }
}
