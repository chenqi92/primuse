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

@Suite("Immersive effect entry policy")
struct ImmersiveEffectEntryPolicyTests {
    @Test("Mac quick access appears only for playable songs")
    func macQuickAccessVisibility() {
        #expect(ImmersiveEffectEntryPolicy.showsMacQuickAccess(
            hasCurrentSong: true,
            isLiveRadio: false
        ))
        #expect(!ImmersiveEffectEntryPolicy.showsMacQuickAccess(
            hasCurrentSong: false,
            isLiveRadio: false
        ))
        #expect(!ImmersiveEffectEntryPolicy.showsMacQuickAccess(
            hasCurrentSong: true,
            isLiveRadio: true
        ))
    }

    @Test("Explicit TV entry keeps the saved immersive effect instead of re-asking")
    func tvLaunchKeepsSavedImmersiveEffect() {
        #expect(!ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: true,
            savedEffectIsNative: false
        ))
    }

    @Test("Explicit TV entry preserves the saved native selection")
    func tvLaunchKeepsNativeSelection() {
        #expect(!ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: true,
            savedEffectIsNative: true
        ))
    }

    @Test("Idle TV entry never opens the picker")
    func idleLaunchStaysPassive() {
        #expect(!ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: false,
            savedEffectIsNative: true
        ))
        #expect(!ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: false,
            savedEffectIsNative: false
        ))
    }

    @Test("Explicit entry with a saved effect drives a direct immersive presentation")
    func explicitEntryStartsPresentationDirectly() {
        let presentsPicker = ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: true,
            savedEffectIsNative: false
        )
        let presentation = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: false,
            presentsEffectPicker: presentsPicker
        )
        #expect(!presentation.dismissesPlayer)
        #expect(!presentation.showsEffectPicker)
        #expect(presentation.startsPresentationWork)
    }

    @Test("Explicit native entry returns to the saved player without a picker")
    func explicitNativeEntryKeepsPlayer() {
        let presentsPicker = ImmersiveEffectEntryPolicy.tvLaunchPresentsEffectPicker(
            isUserInitiated: true,
            savedEffectIsNative: true
        )
        let presentation = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: true,
            presentsEffectPicker: presentsPicker
        )
        #expect(presentation.dismissesPlayer)
        #expect(!presentation.showsEffectPicker)
        #expect(!presentation.startsPresentationWork)
    }

    @Test("A requested picker remains visible for native and immersive effects")
    func requestedPickerPresentation() {
        let native = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: true,
            presentsEffectPicker: true
        )
        #expect(!native.dismissesPlayer)
        #expect(native.showsEffectPicker)
        #expect(!native.startsPresentationWork)

        let immersive = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: false,
            presentsEffectPicker: true
        )
        #expect(!immersive.dismissesPlayer)
        #expect(immersive.showsEffectPicker)
        #expect(immersive.startsPresentationWork)
    }

    @Test("Automatic presentation dismisses native mode and starts saved immersive mode")
    func automaticPresentation() {
        let native = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: true,
            presentsEffectPicker: false
        )
        #expect(native.dismissesPlayer)
        #expect(!native.showsEffectPicker)
        #expect(!native.startsPresentationWork)

        let immersive = ImmersiveEffectEntryPolicy.initialPresentation(
            isNativeEffect: false,
            presentsEffectPicker: false
        )
        #expect(!immersive.dismissesPlayer)
        #expect(!immersive.showsEffectPicker)
        #expect(immersive.startsPresentationWork)
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
            "vinylDeck", "mirrorStage", "auroraVeil", "spectrumHorizon", "particleBloom",
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
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "vinyl",
            hasSynchronizedLyrics: true,
            hasArtwork: true
        ) == "vinylDeck")
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "auroraDrift",
            hasSynchronizedLyrics: true,
            hasArtwork: true
        ) == "auroraVeil")
    }

    @Test("Artwork-dependent new groups remain selected without artwork")
    func newArtworkGroupsRemainSelected() {
        for selected in ["vinylDeck", "mirrorStage", "particleBloom"] {
            #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
                selectedRawValue: selected,
                hasSynchronizedLyrics: false,
                hasArtwork: false
            ) == selected)
        }
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

@Suite("Now Playing regular player layout policy")
struct NowPlayingPlayerLayoutPolicyTests {
    @Test("Portrait keeps the vertical composition")
    func portraitLayout() {
        #expect(NowPlayingPlayerLayoutPolicy.mode(
            viewportWidth: 393,
            viewportHeight: 852,
            prefersWideColumns: false
        ) == .portrait)
    }

    @Test("Compact-width landscape uses the short-height composition")
    func compactLandscapeLayout() {
        #expect(NowPlayingPlayerLayoutPolicy.mode(
            viewportWidth: 852,
            viewportHeight: 393,
            prefersWideColumns: false
        ) == .compactLandscape)
        #expect(NowPlayingPlayerLayoutPolicy.mode(
            viewportWidth: 667,
            viewportHeight: 375,
            prefersWideColumns: false
        ) == .compactLandscape)
    }

    @Test("Regular-width landscape keeps the two-column iPad layout")
    func wideLandscapeLayout() {
        #expect(NowPlayingPlayerLayoutPolicy.mode(
            viewportWidth: 1_366,
            viewportHeight: 1_024,
            prefersWideColumns: true
        ) == .wideLandscape)
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
