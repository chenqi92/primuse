import Foundation
import Testing
@testable import PrimuseKit

@Suite("Track switch cover and lyrics transitions")
struct TrackSwitchTransitionPolicyTests {
    typealias Policy = TrackSwitchTransitionPolicy

    @Test("Directional swap wins when allowed and reduce motion is off")
    func directionalSwapPreferred() {
        let style = ArtworkSwapStyle(direction: .forward, isGentle: false)
        let mode = Policy.artworkTransition(
            outgoingSongID: "a",
            incomingSongID: "b",
            allowsDirectionalSwap: true,
            allowsCrossfadeSwap: true,
            reduceMotion: false,
            directionalStyle: style
        )
        #expect(mode == .directional(style))
    }

    @Test("Falls back to smooth crossfade for non-directional picks, full-bleed, lyrics thumbnail and reduce motion")
    func crossfadeFallbackCases() {
        let style = ArtworkSwapStyle(direction: .forward, isGentle: false)

        // Direct pick from list/queue/search (no directional style)
        #expect(Policy.artworkTransition(
            outgoingSongID: "a", incomingSongID: "b",
            allowsDirectionalSwap: true, allowsCrossfadeSwap: true,
            reduceMotion: false, directionalStyle: nil
        ) == .crossfade)

        // Full-bleed artwork or lyrics-mode thumbnail (allowsDirectionalSwap == false)
        #expect(Policy.artworkTransition(
            outgoingSongID: "a", incomingSongID: "b",
            allowsDirectionalSwap: false, allowsCrossfadeSwap: true,
            reduceMotion: false, directionalStyle: style
        ) == .crossfade)

        // Reduce motion disables sliding directional swap but preserves gentle opacity crossfade
        #expect(Policy.artworkTransition(
            outgoingSongID: "a", incomingSongID: "b",
            allowsDirectionalSwap: true, allowsCrossfadeSwap: true,
            reduceMotion: true, directionalStyle: style
        ) == .crossfade)
    }

    @Test("Same song, missing song, or disallowed surface produces no artwork swap")
    func noSwapWhenSameOrDisallowed() {
        #expect(Policy.artworkTransition(
            outgoingSongID: "a", incomingSongID: "a",
            allowsDirectionalSwap: true, allowsCrossfadeSwap: true,
            reduceMotion: false, directionalStyle: nil
        ) == .none)
        #expect(Policy.artworkTransition(
            outgoingSongID: nil, incomingSongID: "b",
            allowsDirectionalSwap: true, allowsCrossfadeSwap: true,
            reduceMotion: false, directionalStyle: nil
        ) == .none)
        #expect(Policy.artworkTransition(
            outgoingSongID: "a", incomingSongID: "b",
            allowsDirectionalSwap: false, allowsCrossfadeSwap: false,
            reduceMotion: false, directionalStyle: nil
        ) == .none)
    }

    @Test("Crossfade opacity keeps outgoing solid through midpoint while incoming dissolves in")
    func crossfadeOpacityCurve() {
        #expect(Policy.crossfadeLayerOpacity(signedProgress: -1) == 0)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: -0.5) == 0.5)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: 0) == 1)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: 0.5) == 1)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: Policy.crossfadeExitHoldFraction) == 1)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: 1) == 0)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: .nan) == 1)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: 5) == 0)
        #expect(Policy.crossfadeLayerOpacity(signedProgress: -5) == 0)
    }

    @Test("Lyrics transition fades out pending track and fades in when track content settles")
    func lyricsTrackSwitchSequence() {
        let songAReady = Policy.LyricsTransitionSnapshot(songID: "a", loadedSongID: "a", hasLyrics: true, isResolving: false)
        let songBPending = Policy.LyricsTransitionSnapshot(songID: "b", loadedSongID: "a", hasLyrics: true, isResolving: true)
        let songBResolvingEmpty = Policy.LyricsTransitionSnapshot(songID: "b", loadedSongID: "b", hasLyrics: false, isResolving: true)
        let songBReady = Policy.LyricsTransitionSnapshot(songID: "b", loadedSongID: "b", hasLyrics: true, isResolving: false)

        // Slow path: song switches before lyrics load
        #expect(Policy.lyricsTransitionAction(from: songAReady, to: songBPending, isVisible: true) == .fadeOutPendingTrack)
        // Resolving skeleton arrives for song B
        #expect(Policy.lyricsTransitionAction(from: songBPending, to: songBResolvingEmpty, isVisible: true) == .fadeInTrack)
        // Lyrics finish resolving for song B
        #expect(Policy.lyricsTransitionAction(from: songBResolvingEmpty, to: songBReady, isVisible: true) == .fadeInResolvedContent)

        // Fast path: cached lyrics for song B land immediately
        #expect(Policy.lyricsTransitionAction(from: songAReady, to: songBReady, isVisible: true) == .fadeInTrack)
    }

    @Test("Lyrics transition ignores hidden views, initial mounts, and identical playback ticks")
    func lyricsNoSpuriousTransitions() {
        let empty = Policy.LyricsTransitionSnapshot(songID: nil, loadedSongID: nil, hasLyrics: false, isResolving: false)
        let songA = Policy.LyricsTransitionSnapshot(songID: "a", loadedSongID: "a", hasLyrics: true, isResolving: false)
        let songB = Policy.LyricsTransitionSnapshot(songID: "b", loadedSongID: "b", hasLyrics: true, isResolving: false)

        #expect(Policy.lyricsTransitionAction(from: empty, to: songA, isVisible: true) == .none)
        #expect(Policy.lyricsTransitionAction(from: songA, to: songA, isVisible: true) == .none)
        #expect(Policy.lyricsTransitionAction(from: songA, to: songB, isVisible: false) == .none)
    }

    @Test("Reduced motion removes lyrics vertical entrance offset and shortens fade")
    func lyricsReduceMotionAdjustments() {
        #expect(Policy.lyricsEntranceOffset(isRevealed: false, reduceMotion: false) > 0)
        #expect(Policy.lyricsEntranceOffset(isRevealed: true, reduceMotion: false) == 0)
        #expect(Policy.lyricsEntranceOffset(isRevealed: false, reduceMotion: true) == 0)
        #expect(Policy.lyricsFadeInDuration(reduceMotion: true) <= Policy.lyricsFadeInDuration(reduceMotion: false))
    }
}
