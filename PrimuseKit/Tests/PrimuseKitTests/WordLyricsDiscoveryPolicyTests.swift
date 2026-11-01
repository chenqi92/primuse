import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback word lyrics discovery")
struct WordLyricsDiscoveryPolicyTests {
    private let lineLyrics = [LyricLine(timestamp: 1, text: "Hello")]

    @Test func optInAndPlaybackAreRequired() {
        #expect(!WordLyricsDiscoveryPreferences.enabledByDefault)
        #expect(!eligible(enabled: false))
        #expect(!eligible(playing: false))
        #expect(eligible())
        #expect(eligible(lyrics: []))
    }

    @Test func spokenWordAndManualSelectionsArePreserved() {
        #expect(!eligible(spoken: true))
        #expect(!eligible(pinned: true))
        var edited = lineLyrics
        edited[0].documentIsLocalOverride = true
        #expect(!eligible(lyrics: edited))
    }

    @Test func nativeWordTimingNeedsNoDownload() {
        let native = [LyricLine(timestamp: 1, text: "Hello", syllables: [
            LyricSyllable(text: "Hel", start: 1, end: 1.5),
            LyricSyllable(text: "lo", start: 1.5, end: 2)
        ])]
        #expect(!eligible(lyrics: native))
    }

    @Test func completedSearchesHaveASongSpecificCooldown() {
        var attempts = WordLyricsDiscoveryAttempts()
        let now = Date(timeIntervalSince1970: 100)
        #expect(attempts.allows("a", now: now))
        // A cancelled or offline attempt never calls finish.
        #expect(attempts.allows("a", now: now.addingTimeInterval(1)))
        attempts.finish("a", now: now)
        #expect(!attempts.allows("a", now: now.addingTimeInterval(10)))
        #expect(attempts.allows("b", now: now))
        #expect(attempts.allows("a", now: now.addingTimeInterval(WordLyricsDiscoveryAttempts.cooldown)))
    }

    private func eligible(
        enabled: Bool = true, playing: Bool = true,
        spoken: Bool = false, pinned: Bool = false, lyrics: [LyricLine]? = nil
    ) -> Bool {
        WordLyricsDiscoveryPolicy.shouldExplore(
            enabled: enabled, isPlaying: playing, isSpokenWord: spoken,
            isPinned: pinned, lyrics: lyrics ?? lineLyrics
        )
    }
}
